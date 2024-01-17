// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./EntityManager.sol";
import "./FlareSystemManager.sol";
import "./FlareSystemCalculator.sol";
import "../../utils/implementation/AddressUpdatable.sol";
import "../../governance/implementation/Governed.sol";
import "../../utils/lib/SafePct.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * Only addresses registered in this contract can vote.
 */
contract VoterRegistry is Governed, AddressUpdatable {
    using SafePct for uint256;

    struct VotersAndWeights {
        address[] voters;
        mapping (address => uint256) weights;
        uint128 weightsSum;
        uint16 normalisedWeightsSum;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    uint256 internal constant UINT16_MAX = type(uint16).max;
    uint256 internal constant UINT256_MAX = type(uint256).max;

    /// Maximum number of voters in the register.
    uint256 public maxVoters;

    /// In case of providing bad votes (e.g. ftso collusion), the voter can be chilled for a few reward epochs.
    /// A voter can register again from a returned reward epoch onwards.
    mapping(address => uint256) public chilledUntilRewardEpochId;

    // mapping: rewardEpochId => list of registered voters and their weights
    mapping(uint256 => VotersAndWeights) internal register;

    // mapping: rewardEpochId => block number of new signing policy initialisation start
    mapping(uint256 => uint256) public newSigningPolicyInitializationStartBlockNumber;

    // Addresses of the external contracts.
    FlareSystemManager public flareSystemManager;
    EntityManager public entityManager;
    FlareSystemCalculator public flareSystemCalculator;

    string public systemRegistrationContractName;
    address public systemRegistrationContractAddress;

    event VoterChilled(address voter, uint256 untilRewardEpochId);
    event VoterRemoved(address voter, uint256 rewardEpochId);
    event VoterRegistered(
        address voter,
        uint24 rewardEpochId,
        address signingPolicyAddress,
        address delegationAddress,
        address submitAddress,
        address submitSignaturesAddress,
        uint256 registrationWeight
    );

    /// Only FlareSystemManager contract can call this method.
    modifier onlyFlareSystemManager {
        require(msg.sender == address(flareSystemManager), "only flare system manager");
        _;
    }

    modifier onlySystemRegistrationContract {
        require(msg.sender == systemRegistrationContractAddress, "only system registration contract");
        _;
    }

    constructor(
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address _addressUpdater,
        uint256 _maxVoters,
        uint256 _firstRewardEpochId,
        address[] memory _initialVoters,
        uint16[] memory _initialNormalisedWeights
    )
        Governed(_governanceSettings, _initialGovernance) AddressUpdatable(_addressUpdater)
    {
        require(_maxVoters <= UINT16_MAX, "_maxVoters too high");
        maxVoters = _maxVoters;

        uint256 length = _initialVoters.length;
        require(length > 0 && length <= _maxVoters, "_initialVoters length invalid");
        require(length == _initialNormalisedWeights.length, "array lengths do not match");
        VotersAndWeights storage votersAndWeights = register[_firstRewardEpochId];
        uint16 weightsSum = 0;
        for (uint256 i = 0; i < length; i++) {
            votersAndWeights.voters.push(_initialVoters[i]);
            votersAndWeights.weights[_initialVoters[i]] = _initialNormalisedWeights[i];
            weightsSum += _initialNormalisedWeights[i];
        }
        votersAndWeights.weightsSum = weightsSum;
        votersAndWeights.normalisedWeightsSum = weightsSum;
    }

    /**
     * Register voter
     */
    function registerVoter(address _voter, Signature calldata _signature) external {
        (uint24 rewardEpochId, EntityManager.VoterAddresses memory voterAddresses) = _getRegistrationData(_voter);
        // check signature
        bytes32 messageHash = keccak256(abi.encode(rewardEpochId, _voter));
        bytes32 signedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signingPolicyAddress = ECDSA.recover(signedMessageHash, _signature.v, _signature.r, _signature.s);
        require(signingPolicyAddress == voterAddresses.signingPolicyAddress, "invalid signature");
        // register voter
        _registerVoter(_voter, rewardEpochId, voterAddresses);
    }

    /**
     * Enables automatic voter registration triggered by system registration contract.
     */
    function systemRegistration(address _voter) external onlySystemRegistrationContract {
        (uint24 rewardEpochId, EntityManager.VoterAddresses memory voterAddresses) = _getRegistrationData(_voter);
        // register voter
        _registerVoter(_voter, rewardEpochId, voterAddresses);
    }

    /**
     * @dev Only governance can call this method.
     */
    function chillVoter(
        address _voter,
        uint256 _noOfRewardEpochIds
    )
        external onlyGovernance
        returns(
            uint256 _untilRewardEpochId
        )
    {
        uint256 currentRewardEpochId = flareSystemManager.getCurrentRewardEpochId();
        _untilRewardEpochId = currentRewardEpochId + _noOfRewardEpochIds;
        chilledUntilRewardEpochId[_voter] = _untilRewardEpochId;
        emit VoterChilled(_voter, _untilRewardEpochId);
    }

    /**
     * Sets the max number of voters.
     * @dev Only governance can call this method.
     */
    function setMaxVoters(uint256 _maxVoters) external onlyGovernance {
        require(_maxVoters <= UINT16_MAX, "_maxVoters too high");
        maxVoters = _maxVoters;
    }

    /**
     * Sets system registration contract.
     * @dev Only governance can call this method.
     */
    function setSystemRegistrationContractName(string memory _contractName) external onlyGovernance {
        systemRegistrationContractName = _contractName;
        if (keccak256(abi.encode(_contractName)) == keccak256(abi.encode(""))) {
            systemRegistrationContractAddress = address(0);
        }
    }

    /**
     * Sets new signing policy initialisation start block number
     */
    function setNewSigningPolicyInitializationStartBlockNumber(uint256 _rewardEpochId)
        external onlyFlareSystemManager
    {
        // this is only called once from FlareSystemManager
        assert(newSigningPolicyInitializationStartBlockNumber[_rewardEpochId] == 0);
        newSigningPolicyInitializationStartBlockNumber[_rewardEpochId] = block.number;
    }

    /**
     * Creates signing policy snapshot and returns the list of registered signing policy addresses
     * and normalised weights for a given reward epoch
     */
    function createSigningPolicySnapshot(uint256 _rewardEpochId)
        external onlyFlareSystemManager
        returns (
            address[] memory _signingPolicyAddresses,
            uint16[] memory _normalisedWeights,
            uint16 _normalisedWeightsSum
        )
    {
        VotersAndWeights storage votersAndWeights = register[_rewardEpochId];
        uint256 length = votersAndWeights.voters.length;
        assert(length > 0);
        address[] memory voters = new address[](length);
        uint256[] memory weights = new uint256[](length);
        uint256 weightsSum = 0;
        for (uint256 i = 0; i < length; i++) {
            voters[i] = votersAndWeights.voters[i];
            weights[i] = votersAndWeights.weights[voters[i]];
            weightsSum += weights[i];
        }

        // get signing policy addresses
        _signingPolicyAddresses = entityManager.getSigningPolicyAddresses(voters,
            newSigningPolicyInitializationStartBlockNumber[_rewardEpochId]);

        _normalisedWeights = new uint16[](length);
        // normalisation of weights
        for (uint256 i = 0; i < length; i++) {
            _normalisedWeights[i] = uint16(weights[i] * UINT16_MAX / weightsSum); // weights[i] <= weightsSum
            _normalisedWeightsSum += _normalisedWeights[i];
        }

        votersAndWeights.weightsSum = uint128(weightsSum);
        votersAndWeights.normalisedWeightsSum = _normalisedWeightsSum;
    }

    /**
     * Returns the list of registered voters for a given reward epoch
     */
    function getRegisteredVoters(uint256 _rewardEpochId) external view returns (address[] memory) {
        return register[_rewardEpochId].voters;
    }

    /**
     * Returns the list of registered voters' data provider addresses for a given reward epoch
     */
    function getRegisteredSubmitAddresses(
        uint256 _rewardEpochId
    )
        external view
        returns (address[] memory)
    {
        return entityManager.getSubmitAddresses(register[_rewardEpochId].voters,
            newSigningPolicyInitializationStartBlockNumber[_rewardEpochId]);
    }

    /**
     * Returns the list of registered voters' deposit signatures addresses for a given reward epoch
     */
    function getRegisteredSubmitSignaturesAddresses(
        uint256 _rewardEpochId
    )
        external view
        returns (address[] memory _signingPolicyAddresses)
    {
        return entityManager.getSubmitSignaturesAddresses(register[_rewardEpochId].voters,
            newSigningPolicyInitializationStartBlockNumber[_rewardEpochId]);
    }

    /**
     * Returns the list of registered voters' signing policy addresses for a given reward epoch
     */
    function getRegisteredSigningPolicyAddresses(
        uint256 _rewardEpochId
    )
        external view
        returns (address[] memory _signingPolicyAddresses)
    {
        return entityManager.getSigningPolicyAddresses(register[_rewardEpochId].voters,
            newSigningPolicyInitializationStartBlockNumber[_rewardEpochId]);
    }

    /**
     * Returns the number of registered voters for a given reward epoch
     */
    function getNumberOfRegisteredVoters(uint256 _rewardEpochId) external view returns (uint256) {
        return register[_rewardEpochId].voters.length;
    }

    /**
     * Returns voter's address and normalised weight for a given reward epoch and signing policy address
     */
    function getVoterWithNormalisedWeight(
        uint256 _rewardEpochId,
        address _signingPolicyAddress
    )
        external view
        returns (
            address _voter,
            uint16 _normalisedWeight
        )
    {
        uint256 weightsSum = register[_rewardEpochId].weightsSum;
        require(weightsSum > 0, "reward epoch id not supported");
        _voter = entityManager.getVoterForSigningPolicyAddress(_signingPolicyAddress,
            newSigningPolicyInitializationStartBlockNumber[_rewardEpochId]);
        uint256 weight = register[_rewardEpochId].weights[_voter];
        require(weight > 0, "voter not registered");
        _normalisedWeight = uint16(weight * UINT16_MAX / weightsSum);
    }

    /**
     * Returns voter's public key and normalised weight for a given reward epoch and signing policy address
     */
    function getPublicKeyAndNormalisedWeight(
        uint256 _rewardEpochId,
        address _signingPolicyAddress
    )
        external view
        returns (
            bytes32 _publicKeyPart1,
            bytes32 _publicKeyPart2,
            uint16 _normalisedWeight
        )
    {
        uint256 weightsSum = register[_rewardEpochId].weightsSum;
        require(weightsSum > 0, "reward epoch id not supported");
        uint256 initBlock = newSigningPolicyInitializationStartBlockNumber[_rewardEpochId];
        address voter = entityManager.getVoterForSigningPolicyAddress(_signingPolicyAddress, initBlock);
        uint256 weight = register[_rewardEpochId].weights[voter];
        require(weight > 0, "voter not registered");
        _normalisedWeight = uint16(weight * UINT16_MAX / weightsSum);
        (_publicKeyPart1, _publicKeyPart2) = entityManager.getPublicKeyOfAt(voter, initBlock);
    }

    function isVoterRegistered(address _voter, uint256 _rewardEpochId) external view returns(bool) {
        return register[_rewardEpochId].weights[_voter] > 0;
    }

    /**
     * @inheritdoc AddressUpdatable
     */
    function _updateContractAddresses(
        bytes32[] memory _contractNameHashes,
        address[] memory _contractAddresses
    )
        internal override
    {
        flareSystemManager = FlareSystemManager(
            _getContractAddress(_contractNameHashes, _contractAddresses, "FlareSystemManager"));
        entityManager = EntityManager(_getContractAddress(_contractNameHashes, _contractAddresses, "EntityManager"));
        flareSystemCalculator = FlareSystemCalculator(
            _getContractAddress(_contractNameHashes, _contractAddresses, "FlareSystemCalculator"));

        if (keccak256(abi.encode(systemRegistrationContractName)) != keccak256(abi.encode(""))) {
            systemRegistrationContractAddress =
                _getContractAddress(_contractNameHashes, _contractAddresses, systemRegistrationContractName);
        }
    }

    /**
     * Request to register `_voter` account - implementation.
     */
    function _registerVoter(
        address _voter,
        uint24 _rewardEpochId,
        EntityManager.VoterAddresses memory _voterAddresses
    )
        internal
    {
        (uint256 votePowerBlock, bool enabled) = flareSystemManager.getVoterRegistrationData(_rewardEpochId);
        require(votePowerBlock != 0, "vote power block zero");
        require(enabled, "voter registration not enabled");
        uint256 weight = flareSystemCalculator
            .calculateRegistrationWeight(_voter, _voterAddresses.delegationAddress, _rewardEpochId, votePowerBlock);
        require(weight > 0, "voter weight zero");

        VotersAndWeights storage votersAndWeights = register[_rewardEpochId];

        // check if _voter already registered
        if (votersAndWeights.weights[_voter] > 0) {
            revert("already registered");
        }

        uint256 length = votersAndWeights.voters.length;

        if (length < maxVoters) {
            // we can just add a new one
            votersAndWeights.voters.push(_voter);
            votersAndWeights.weights[_voter] = weight;
        } else {
            // find minimum to kick out (if needed)
            uint256 minIndex = 0;
            uint256 minIndexWeight = UINT256_MAX;

            for (uint256 i = 0; i < length; i++) {
                address voter = votersAndWeights.voters[i];
                uint256 voterWeight = votersAndWeights.weights[voter];
                if (minIndexWeight > voterWeight) {
                    minIndexWeight = voterWeight;
                    minIndex = i;
                }
            }

            if (minIndexWeight >= weight) {
                // _voter has the lowest weight among all
                revert("vote power too low");
            }

            // kick the minIndex out and replace it with _voter
            address removedVoter = votersAndWeights.voters[minIndex];
            delete votersAndWeights.weights[removedVoter];
            votersAndWeights.voters[minIndex] = _voter;
            votersAndWeights.weights[_voter] = weight;
            emit VoterRemoved(removedVoter, _rewardEpochId);
        }

        emit VoterRegistered(
            _voter,
            _rewardEpochId,
            _voterAddresses.signingPolicyAddress,
            _voterAddresses.delegationAddress,
            _voterAddresses.submitAddress,
            _voterAddresses.submitSignaturesAddress,
            weight
        );
    }

    function _getRegistrationData(address _voter)
        internal view
        returns(
            uint24 _rewardEpochId,
            EntityManager.VoterAddresses memory _voterAddresses
        )
    {
        _rewardEpochId = flareSystemManager.getCurrentRewardEpochId() + 1;
        uint256 untilRewardEpochId = chilledUntilRewardEpochId[_voter];
        require(untilRewardEpochId == 0 || untilRewardEpochId <= _rewardEpochId, "voter chilled");
        uint256 initBlock = newSigningPolicyInitializationStartBlockNumber[_rewardEpochId];
        require(initBlock != 0, "registration not available yet");
        _voterAddresses = entityManager.getVoterAddresses(_voter, initBlock);
    }
}
