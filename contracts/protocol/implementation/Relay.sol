// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./Finalisation.sol";

// import "hardhat/console.sol";

contract Relay {
    uint256 public constant FIRST_REWARD_EPOCH_VOTING_ROUND_ID = 1000;
    uint256 public constant REWARD_EPOCH_DURATION_IN_EPOCHS = 3360;
    uint256 public constant FIRST_VOTING_ROUND_START_SEC = 1636070400;
    uint256 public constant VOTING_ROUND_DURATION_SEC = 90;
    uint256 public constant THRESHOLD_INCREASE = 120;
    uint256 public constant THRESHOLD_SHARES = 100;
    uint256 public constant SELECTOR_BYTES = 4;

    // Signing policy byte encoding structure
    // 2 bytes - size (numberOfVoters)
    // 3 bytes - rewardEpochId
    // 4 bytes - startingVotingRoundId
    // 2 bytes - threshold
    // 32 bytes - randomSeed
    // array of 'size':
    // - 20 bytes address
    // - 2 bytes weight
    // Total 43 + size * (20 + 2) bytes
    // metadataLength = 11 bytes (size, rewardEpochId, startingVotingRoundId, threshold)

    uint256 public constant NUMBER_OF_VOTERS_BYTES = 2;
    uint256 public constant NUMBER_OF_VOTERS_MASK = 0xffff;
    uint256 public constant METADATA_BYTES = 11;
    uint256 public constant NUMBER_OF_VOTERS_RIGHT_SHIFT_BITS = 72; // 8 * (3 rewardEpochId + 4 startingVotingRoundId + 2 threshold) = 72
    uint256 public constant REWARD_EPOCH_ID_MASK = 0xffffff;
    // uint256 public constant REWARD_EPOCH_ID_RIGHT_OFFSET_BYTES = 6; // 4 bytes startingVotingRoundId + 2 bytes threshold
    uint256 public constant REWARD_EPOCH_ID_RIGHT_SHIFT_BITS = 48; // 8*(4 bytes startingVotingRoundId + 2 bytes threshold)

    uint256 public constant STARTING_VOTING_ROUND_ID_MASK = 0xffffffff;
    uint256 public constant STARTING_VOTING_ROUND_ID_RIGHT_SHIFT_BITS = 16; // 2 threshold * 8
    uint256 public constant THRESHOLD_MASK = 0xffff;
    uint256 public constant THRESHOLD_RIGHT_SHIFT_BITS = 0; // 0 bytes
    uint256 public constant RANDOM_SEED_BYTES = 32;
    uint256 public constant ADDRESS_BYTES = 20;
    uint256 public constant WEIGHT_BYTES = 2;
    uint256 public constant ADDRESS_AND_WEIGHT_BYTES = 22; // ADDRESS_BYTES + WEIGHT_BYTES;
    uint256 public constant SIGNING_POLICY_PREFIX_BYTES = 43; //METADATA_BYTES + RANDOM_SEED_BYTES;

    uint256 public constant M_0 = 0;
    uint256 public constant M_1 = 32;
    uint256 public constant M_2 = 64;
    uint256 public constant M_3 = 96;
    uint256 public constant M_4 = 128;
    uint256 public constant ADDRESS_OFFSET = 12;

    // Protocol message merkle root structure
    // 1 byte - protocolId
    // 4 bytes - votingRoundId
    // 1 byte - randomQualityScore
    // 32 bytes - merkleRoot
    // Total 38 bytes
    // if loaded into a memory slot, these are right shifts and masks
    uint256 public constant PROTOCOL_ID_BYTES = 1;
    uint256 public constant PROTOCOL_ID_MASK = 0xff;
    uint256 public constant PROTOCOL_ID_RIGHT_SHIFT_BITS = 248; // (>> 256 - (1 protocolID)*8 = 248)
    uint256 public constant VOTING_ROUND_ID_BYTES = 4;
    uint256 public constant VOTING_ROUND_ID_MASK = 0xffffffff;
    uint256 public constant VOTING_ROUND_ID_RIGHT_SHIFT_BITS = 216; // (>> 256 - (1 protocolID + 4 votingRoundId)*8 = 216)
    uint256 public constant RANDOM_QUALITY_SCORE_BYTES = 1;
    uint256 public constant RANDOM_QUALITY_SCORE_MASK = 0xff;
    uint256 public constant RANDOM_QUALITY_SCORE_RIGHT_SHIFT_BITS = 208; // (>> 256 - (1 protocolID + 4 votingRoundId + 1 randomQualityScore)*8 = 208)

    uint256 public constant MESSAGE_BYTES = 38;

    // IMPORTANT: if you change this, you have to adapt the assembly writing into this in the relay() function
    struct StateData {
        uint8 randomNumberProtocolId;
        uint32 randomTimestamp;
        uint32 randomVotingRoundId;
        bool randomNumberQualityScore;
    }

    uint256 public constant RANDOM_TIMESTAMP_MASK = 0xffffffff;
    uint256 public constant RANDOM_TIMESTAMP_LEFT_SHIFT_BITS = 8; // 8 * 1 randomNumberProtocolId = 8
    uint256 public constant RANDOM_VOTING_ROUND_ID_MASK = 0xffffffff;
    uint256 public constant RANDOM_VOTING_ROUND_ID_LEFT_SHIFT_BITS = 40; // 8 * (1 randomNumberProtocolId + 4 randomTimestamp) = 40
    uint256 public constant RANDOM_NUMBER_QUALITY_SCORE_MASK = 0xff;
    uint256 public constant RANDOM_NUMBER_QUALITY_SCORE_LEFT_SHIFT_BITS = 72; // 8 * (1 randomNumberProtocolId + 4 randomTimestamp + 4 randomVotingRoundId) = 72

    // Signature with index structure
    // 1 byte - v
    // 32 bytes - r
    // 32 bytes - s
    // 2 byte - index in signing policy
    // Total 67 bytes

    uint256 public constant SIGNATURE_WITH_INDEX_BYTES = 67; // 1 v + 32 r + 32 s + 2 index
    uint256 public constant SIGNATURE_V_BYTES = 1;
    uint256 public constant SIGNATURE_INDEX_RIGHT_SHIFT_BITS = 240; // 256 - 2*8 = 240

    uint256 public lastInitializedRewardEpoch;
    // rewardEpochId => signingPolicyHash
    mapping(uint256 => bytes32) public toSigningPolicyHash;
    // protocolId => votingRoundId => merkleRoot
    mapping(uint256 => mapping(uint256 => bytes32)) public merkleRoots;

    address public signingPolicySetter;

    StateData public stateData;

    /// Only signingPolicySetter address/contract can call this method.
    modifier onlySigningPolicySetter() {
        require(msg.sender == signingPolicySetter, "only sign policy setter");
        _;
    }

    constructor(
        address _signingPolicySetter,
        uint256 _rewardEpochId,
        bytes32 _signingPolicyHash,
        uint8 _randomNumberProtocolId // TODO - we may want to be able to change this through governance
    ) {
        signingPolicySetter = _signingPolicySetter;
        lastInitializedRewardEpoch = _rewardEpochId;
        toSigningPolicyHash[_rewardEpochId] = _signingPolicyHash;
        stateData.randomNumberProtocolId = _randomNumberProtocolId;
    }

    function setSigningPolicy(
        // using memory instead of calldata as called from another contract where signing policy is already in memory
        Finalisation.SigningPolicy memory _signingPolicy
    ) external onlySigningPolicySetter returns (bytes32) {
        require(
            lastInitializedRewardEpoch + 1 == _signingPolicy.rewardEpochId,
            "not next reward epoch"
        );
        require(_signingPolicy.voters.length > 0, "must be non-trivial");
        require(
            _signingPolicy.voters.length == _signingPolicy.weights.length,
            "size mismatch"
        );
        // bytes32 currentHash;
        bytes memory toHash = bytes.concat(
            bytes2(uint16(_signingPolicy.voters.length)),
            bytes3(_signingPolicy.rewardEpochId),
            bytes4(_signingPolicy.startVotingRoundId),
            bytes2(_signingPolicy.threshold),
            bytes32(_signingPolicy.seed),
            bytes20(_signingPolicy.voters[0]),
            bytes1(uint8(_signingPolicy.weights[0] >> 8))
        );
        bytes32 currentHash = keccak256(toHash);
        uint256 weightIndex = 0;
        uint256 weightPos = 1;
        uint256 voterIndex = 1;
        uint256 voterPos = 0;
        uint256 count;
        uint256 bytesToTake;
        bytes32 nextSlot;
        uint256 pos;
        uint256 hashCount = 1;

        while (weightIndex < _signingPolicy.voters.length) {
            count = 0;
            nextSlot = bytes32(uint256(0));
            while (count < 32 && weightIndex < _signingPolicy.voters.length) {
                if (weightIndex < voterIndex) {
                    bytesToTake = 2 - weightPos;
                    pos = weightPos;
                    bytes32 weightData = bytes32(
                        uint256(uint16(_signingPolicy.weights[weightIndex])) <<
                            (30 * 8)
                    );
                    if (count + bytesToTake > 32) {
                        bytesToTake = 32 - count;
                        weightPos += bytesToTake;
                    } else {
                        weightPos = 0;
                        weightIndex++;
                    }
                    nextSlot =
                        nextSlot |
                        bytes32(((weightData << (8 * pos)) >> (8 * count)));
                } else {
                    bytesToTake = 20 - voterPos;
                    pos = voterPos;
                    bytes32 voterData = bytes32(
                        uint256(uint160(_signingPolicy.voters[voterIndex])) <<
                            (12 * 8)
                    );
                    if (count + bytesToTake > 32) {
                        bytesToTake = 32 - count;
                        voterPos += bytesToTake;
                    } else {
                        voterPos = 0;
                        voterIndex++;
                    }
                    nextSlot =
                        nextSlot |
                        bytes32(((voterData << (8 * pos)) >> (8 * count)));
                }
                count += bytesToTake;
            }
            if (count > 0) {
                currentHash = keccak256(bytes.concat(currentHash, nextSlot));
                hashCount++;
            }
        }
        toSigningPolicyHash[_signingPolicy.rewardEpochId] = currentHash;
        lastInitializedRewardEpoch = _signingPolicy.rewardEpochId;
        return currentHash;
    }

    /**
     * ECDSA signature relay
     * Can be called in two modes.
     * (2) Relaying signing policy. The structure of the calldata is:
     *        function signature (4 bytes) + active signing policy (2209 bytes) + 0 (1 byte) + new signing policy (2209 bytes),
     *     total of exactly 4423 bytes.
     * (2) Relaying signed message. The structure of the calldata is:
     *        function signature (4 bytes) + signing policy (2209 bytes) + signed message (38 bytes) + ECDSA signatures with indices (66 bytes each),
     *     total of 2251 + 66 * N bytes, where N is the number of signatures.
     */
    //
    // (1) Initializing with signing policy. This can be done only once, usually after deployment. The calldata should include only signature and signing policy.
    function relay() external {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Helper function to revert with a message
            // Since string length cannot be determined in assembly easily, the matching length of the message string must be provided.
            function revertWithMessage(memPtr, message, msgLength) {
                mstore(
                    memPtr,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(add(memPtr, 0x04), 0x20) // String offset
                mstore(add(memPtr, 0x24), msgLength) // Revert reason length
                mstore(add(memPtr, 0x44), message)
                revert(memPtr, 0x64) // Revert data length is 4 bytes for selector and 3 slots of 0x20 bytes
            }

            function revertWithValue(memPtr, val) {
                mstore(memPtr, val)
                revert(memPtr, 0x20)
            }

            // Helper function to calculate the matching reward epoch id from voting round id
            // Here the constants should be set properly
            function rewardEpochIdFromVotingRoundId(votingRoundId)
                -> rewardEpochId
            {
                rewardEpochId := div(
                    sub(votingRoundId, FIRST_REWARD_EPOCH_VOTING_ROUND_ID),
                    REWARD_EPOCH_DURATION_IN_EPOCHS
                )
            }

            // Helper function to calculate the end time of the voting roujnd
            // Here the constants should be set properly
            function votingRoundEndTime(votingRoundId) -> timeStamp {
                timeStamp := add(
                    FIRST_VOTING_ROUND_START_SEC,
                    mul(add(votingRoundId, 1), VOTING_ROUND_DURATION_SEC)
                )
            }

            // Helper function to calculate the signing policy hash while trying to minimize the usage of memory
            // Uses slots 0 and 32
            function calculateSigningPolicyHash(
                memPos,
                calldataPos,
                policyLength
            ) -> policyHash {
                // first byte
                calldatacopy(memPos, calldataPos, 32)
                // all but last 32-byte word
                let endPos := add(calldataPos, mul(div(policyLength, 32), 32))
                for {
                    let pos := add(calldataPos, 32)
                } lt(pos, endPos) {
                    pos := add(pos, 32)
                } {
                    calldatacopy(add(memPos, M_1), pos, 32)
                    mstore(memPos, keccak256(memPos, 64))
                }

                // handle the remaining bytes
                mstore(add(memPos, M_1), 0)
                calldatacopy(add(memPos, M_1), endPos, mod(policyLength, 32)) // remaining bytes
                mstore(memPos, keccak256(memPos, 64))
                policyHash := mload(memPos)
            }

            // Constants
            let memPtr := mload(0x40) // free memory pointer

            // Variables
            let pos := 4 // Calldata position
            let signatureStart := 0 // First index of signatures in calldata

            ///////////// Extracting signing policy metadata /////////////
            if lt(calldatasize(), add(SELECTOR_BYTES, METADATA_BYTES)) {
                revertWithMessage(memPtr, "Invalid sign policy metadata", 28)
            }

            calldatacopy(memPtr, pos, METADATA_BYTES)
            // shift to right of bytes32
            let metadata := shr(sub(256, mul(8, METADATA_BYTES)), mload(memPtr))
            let numberOfVoters := and(
                shr(NUMBER_OF_VOTERS_RIGHT_SHIFT_BITS, metadata),
                NUMBER_OF_VOTERS_MASK
            )
            let rewardEpochId := and(
                shr(REWARD_EPOCH_ID_RIGHT_SHIFT_BITS, metadata),
                REWARD_EPOCH_ID_MASK
            )

            let threshold := and(
                shr(THRESHOLD_RIGHT_SHIFT_BITS, metadata),
                THRESHOLD_MASK
            )

            let signingPolicyLength := add(
                SIGNING_POLICY_PREFIX_BYTES,
                mul(numberOfVoters, ADDRESS_AND_WEIGHT_BYTES)
            )

            // The calldata must be of length at least 4 function selector + signingPolicyLength + 1 protocolId
            if lt(
                calldatasize(),
                add(SELECTOR_BYTES, add(signingPolicyLength, PROTOCOL_ID_BYTES))
            ) {
                revertWithMessage(memPtr, "Invalid sign policy length", 26)
            }

            ///////////// Verifying signing policy /////////////
            // signing policy hash
            let signingPolicyHash := calculateSigningPolicyHash(
                memPtr,
                SELECTOR_BYTES,
                signingPolicyLength
            )

            //  toSigningPolicyHash[rewardEpochId] = existingSigningPolicyHash
            mstore(memPtr, rewardEpochId) // key (rewardEpochId)
            mstore(add(memPtr, M_1), toSigningPolicyHash.slot)
            let existingSigningPolicyHash := sload(keccak256(memPtr, 64))

            // From here on we have calldatasize() > 4 + signingPolicyLength

            ///////////// Verifying signing policy /////////////
            if iszero(eq(signingPolicyHash, existingSigningPolicyHash)) {
                revertWithMessage(memPtr, "Signing policy hash mismatch", 28)
            }
            // jump to protocol message Merkle root
            pos := add(SELECTOR_BYTES, signingPolicyLength)

            // Extracting protocolId, votingRoundId and randomQualityScore
            // 1 bytes - protocolId
            // 4 bytes - votingRoundId
            // 1 bytes - randomQualityScore
            // 32 bytes - merkleRoot
            // message length: 38

            calldatacopy(memPtr, pos, PROTOCOL_ID_BYTES)

            let protocolId := shr(
                sub(256, mul(8, PROTOCOL_ID_BYTES)), // move to the rightmost position
                mload(memPtr)
            )

            let votingRoundId := 0

            ///////////// Preparation of message hash /////////////
            // protocolId > 0 means we are relaying (Mode 2)
            // The signed hash is the message hash and it gets prepared into slot 32
            if gt(protocolId, 0) {
                signatureStart := add(
                    SELECTOR_BYTES,
                    add(signingPolicyLength, MESSAGE_BYTES)
                )
                if lt(calldatasize(), signatureStart) {
                    revertWithMessage(memPtr, "Too short message", 17)
                }
                calldatacopy(memPtr, pos, MESSAGE_BYTES)

                votingRoundId := and(
                    shr(VOTING_ROUND_ID_RIGHT_SHIFT_BITS, mload(memPtr)),
                    VOTING_ROUND_ID_MASK
                )
                // the usual reward epoch id
                let messageRewardEpochId := rewardEpochIdFromVotingRoundId(
                    votingRoundId
                )
                let startingVotingRoundId := and(
                    shr(STARTING_VOTING_ROUND_ID_RIGHT_SHIFT_BITS, metadata),
                    STARTING_VOTING_ROUND_ID_MASK
                )
                // in case the reward epoch id start gets delayed -> signing policy for earlier reward epoch must be provided
                if and(
                    eq(messageRewardEpochId, rewardEpochId),
                    lt(votingRoundId, startingVotingRoundId)
                ) {
                    revertWithMessage(memPtr, "Delayed sign policy", 19)
                }

                // Given a signing policy for reward epoch R one can sign either messages in reward epochs R and R+1 only
                if or(
                    gt(messageRewardEpochId, add(rewardEpochId, 1)),
                    lt(messageRewardEpochId, rewardEpochId)
                ) {
                    revertWithMessage(
                        memPtr,
                        "Wrong sign policy reward epoch",
                        30
                    )
                }

                // When signing with previous reward epoch's signing policy, use higher threshold
                if eq(sub(messageRewardEpochId, 1), rewardEpochId) {
                    threshold := div(
                        mul(threshold, THRESHOLD_INCREASE),
                        THRESHOLD_SHARES
                    )
                }

                // Prepera the message hash into slot 32
                mstore(add(memPtr, M_1), keccak256(memPtr, MESSAGE_BYTES))
            }
            // protocolId == 0 means we are relaying new signing policy (Mode 1)
            // The signed hash is the signing policy hash and it gets prepared into slot 32
            if eq(protocolId, 0) {
                if lt(
                    calldatasize(),
                    add(
                        SELECTOR_BYTES,
                        add(
                            signingPolicyLength,
                            add(PROTOCOL_ID_BYTES, METADATA_BYTES)
                        )
                    )
                ) {
                    revertWithMessage(memPtr, "No new sign policy size", 23)
                }

                // New metadata
                calldatacopy(
                    memPtr,
                    add(
                        SELECTOR_BYTES,
                        add(PROTOCOL_ID_BYTES, signingPolicyLength)
                    ),
                    METADATA_BYTES
                )

                let newMetadata := shr(
                    sub(256, mul(8, METADATA_BYTES)),
                    mload(memPtr)
                )

                let newNumberOfVoters := and(
                    shr(NUMBER_OF_VOTERS_RIGHT_SHIFT_BITS, newMetadata),
                    NUMBER_OF_VOTERS_MASK
                )

                let newSigningPolicyLength := add(
                    SIGNING_POLICY_PREFIX_BYTES,
                    mul(newNumberOfVoters, ADDRESS_AND_WEIGHT_BYTES)
                )

                signatureStart := add(
                    SELECTOR_BYTES,
                    add(
                        signingPolicyLength,
                        add(PROTOCOL_ID_BYTES, newSigningPolicyLength)
                    )
                )

                if lt(calldatasize(), signatureStart) {
                    revertWithMessage(
                        memPtr,
                        "Wrong size for new sign policy",
                        30
                    )
                }

                let newSigningPolicyRewardEpochId := and(
                    shr(REWARD_EPOCH_ID_RIGHT_SHIFT_BITS, newMetadata),
                    REWARD_EPOCH_ID_MASK
                )

                let tmpLastInitializedRewardEpochId := sload(
                    lastInitializedRewardEpoch.slot
                )
                // let nextRewardEpochId := add(tmpLastInitializedRewardEpochId, 1)
                if iszero(
                    eq(
                        add(1, tmpLastInitializedRewardEpochId),
                        newSigningPolicyRewardEpochId
                    )
                ) {
                    revertWithMessage(memPtr, "Not next reward epoch", 21)
                }

                let newSigningPolicyHash := calculateSigningPolicyHash(
                    memPtr,
                    add(
                        SELECTOR_BYTES,
                        add(signingPolicyLength, PROTOCOL_ID_BYTES)
                    ),
                    newSigningPolicyLength
                )
                // Write to storage - if signature weight is not sufficient, this will be reverted
                sstore(
                    lastInitializedRewardEpoch.slot,
                    newSigningPolicyRewardEpochId
                )
                // toSigningPolicyHash[newSigningPolicyRewardEpochId] = newSigningPolicyHash
                mstore(memPtr, newSigningPolicyRewardEpochId)
                mstore(add(memPtr, M_1), toSigningPolicyHash.slot)
                sstore(keccak256(memPtr, 64), newSigningPolicyHash)
                // Prepare the hash on slot 32 for signature verification
                mstore(add(memPtr, M_1), newSigningPolicyHash)
            }

            // Assumptions here:
            // - memPtr (slot 0) contains either protocol message merkle root hash or new signing policy hash
            // - signatureStart points to the first signature in calldata
            // - We are sure that calldatasize() >= signatureStart

            // There need to be exactly multiple of 66 bytes for signatures
            if mod(
                sub(calldatasize(), signatureStart),
                SIGNATURE_WITH_INDEX_BYTES
            ) {
                revertWithMessage(memPtr, "Wrong signatures length", 23)
            }

            // Prefixed hash calculation
            // 4-bytes padded prefix into slot 0
            mstore(memPtr, "0000\x19Ethereum Signed Message:\n32")
            // Prefixed hash into slot 0, skipping 4-bytes of 0-prefix
            mstore(memPtr, keccak256(add(memPtr, 4), 60))

            // Processing signatures. Memory map:
            // memPtr (slot 0)  | prefixedHash
            // M_1              | v  // first 31 bytes always 0
            // M_2              | r, signer
            // M_3              | s, expectedSigner
            // M_4              | index, weight
            mstore(add(memPtr, M_1), 0) // clear v - only the lowest byte will change

            for {
                let i := 0
                // accumulated weight of signatures
                let weight := 0
                // enforces increasing order of indices in signatures
                let nextUnusedIndex := 0
                // number of signatures
                let numberOfSignatures := div(
                    sub(calldatasize(), signatureStart),
                    SIGNATURE_WITH_INDEX_BYTES
                )
            } lt(i, numberOfSignatures) {
                i := add(i, 1)
            } {
                // signature position
                pos := add(signatureStart, mul(i, SIGNATURE_WITH_INDEX_BYTES))
                // overriding only the last byte of 'v' and setting r, s
                calldatacopy(
                    add(memPtr, add(M_1, sub(32, SIGNATURE_V_BYTES))),
                    pos,
                    SIGNATURE_WITH_INDEX_BYTES
                ) // 63 ... last byte of slot +32
                // Note that those things get set
                // - slot M_1 - the rightmost byte of 'v' gets set
                // - slot M_2    - r
                // - slot M_3    - s
                // - slot M_4   - index (only the top 2 bytes)
                let index := shr(
                    SIGNATURE_INDEX_RIGHT_SHIFT_BITS,
                    mload(add(memPtr, M_4))
                )

                // Index sanity checks in regard to signing policy
                if gt(index, sub(numberOfVoters, 1)) {
                    revertWithMessage(memPtr, "Index out of range", 18)
                }

                if lt(index, nextUnusedIndex) {
                    revertWithMessage(memPtr, "Index out of order", 18)
                }
                nextUnusedIndex := add(index, 1)

                // ecrecover call. Address goes to slot 64, it is 0 padded
                if iszero(
                    staticcall(not(0), 0x01, memPtr, 0x80, add(memPtr, M_2), 32)
                ) {
                    revertWithMessage(memPtr, "ecrecover error", 15)
                }
                // extract expected signer address to slot no 96
                mstore(add(memPtr, M_3), 0) // zeroing slot for expected address

                // position of address on 'index': 4 + 20 + index x 22 (expectedSigner)
                let addressPos := add(
                    add(SELECTOR_BYTES, SIGNING_POLICY_PREFIX_BYTES),
                    mul(index, ADDRESS_AND_WEIGHT_BYTES)
                )

                calldatacopy(
                    add(memPtr, add(M_3, ADDRESS_OFFSET)),
                    addressPos,
                    ADDRESS_BYTES
                )

                // Check if the recovered signer is the expected signer
                if iszero(
                    eq(mload(add(memPtr, M_2)), mload(add(memPtr, M_3)))
                ) {
                    revertWithMessage(memPtr, "Wrong signature", 15)
                }

                // extract weight, reuse field for r (slot 64)
                mstore(add(memPtr, M_2), 0) // clear r field
                
                calldatacopy(
                    add(memPtr, add(M_2, sub(32, WEIGHT_BYTES))), // weight copied to the right of slot M2
                    add(addressPos, ADDRESS_BYTES),
                    WEIGHT_BYTES
                )
                weight := add(weight, mload(add(memPtr, M_2)))

                if gt(weight, threshold) {
                    // jump over fun selector, signing policy and 17 bytes of protocolId, votingRoundId and randomQualityScore
                    pos := add(
                        add(SELECTOR_BYTES, signingPolicyLength),
                        sub(MESSAGE_BYTES, 32)
                    ) // last 32 bytes are merkleRoot
                    calldatacopy(memPtr, pos, 32)
                    let merkleRoot := mload(memPtr)
                    // writing into the map
                    mstore(memPtr, protocolId) // key 1 (protocolId)
                    mstore(add(memPtr, M_1), merkleRoots.slot) // merkleRoot slot

                    mstore(add(memPtr, M_1), keccak256(memPtr, 64)) // parent map location in slot for next hashing
                    mstore(memPtr, votingRoundId) // key 2 (votingRoundId)
                    sstore(keccak256(memPtr, 64), merkleRoot) // merkleRoot stored at merkleRoots[protocolId][votingRoundId]

                    // stateData
                    let stateDataTemp := sload(stateData.slot)
                    // NOTE: the struct is packed in reverse order of bytes

                    // stateData.randomVotingRoundId = votingRoundId
                    // 8*(1 randomNumberProtocolId + 4 randomTimestamp) = 40
                    stateDataTemp := or(
                        and(    // zeroing the field
                            stateDataTemp,
                            not(   // zero ion mask
                                shl(
                                    RANDOM_VOTING_ROUND_ID_LEFT_SHIFT_BITS,
                                    RANDOM_VOTING_ROUND_ID_MASK
                                )
                            )
                        ),
                        shl(  // new value
                            RANDOM_VOTING_ROUND_ID_LEFT_SHIFT_BITS,
                            votingRoundId
                        )
                    )

                    // Message:
                    // 1 byte - protocolId
                    // 4 bytes - votingRoundId
                    // 1 byte - randomQualityScore
                    // 32 bytes - merkleRoot
                    // Total 38 bytes

                    // stateData.randomNumberQualityScore = votingRoundId
                    pos := add(SELECTOR_BYTES, signingPolicyLength)
                    calldatacopy(memPtr, pos, sub(MESSAGE_BYTES, 32))
                    stateDataTemp := or(
                        and(    // zeroing the field
                            stateDataTemp,
                            not( // zeroing mask
                                shl(
                                    RANDOM_NUMBER_QUALITY_SCORE_LEFT_SHIFT_BITS,
                                    RANDOM_NUMBER_QUALITY_SCORE_MASK
                                )
                            )
                        ),                        
                        shl(  // new value - shifting to position in struct
                            RANDOM_NUMBER_QUALITY_SCORE_LEFT_SHIFT_BITS, 
                            and(  // extracting value from message
                                shr(
                                    RANDOM_QUALITY_SCORE_RIGHT_SHIFT_BITS,
                                    mload(memPtr)
                                ),
                                RANDOM_QUALITY_SCORE_MASK
                            )
                        ) // shr(248, mload(memPtr)) - move the byte to the rightmost position
                    )

                    // stateData.randomTimestamp = end of the votingRoundId timestamp
                    stateDataTemp := or(
                        and( // zeroing the field
                            stateDataTemp,
                            not( // zeroing mask
                                shl(
                                    RANDOM_TIMESTAMP_LEFT_SHIFT_BITS,
                                    RANDOM_TIMESTAMP_MASK
                                )
                            )
                        ),
                        shl( // new value, shifting to position in struct
                            RANDOM_TIMESTAMP_LEFT_SHIFT_BITS,
                            votingRoundEndTime(votingRoundId)
                        )
                    )

                    sstore(stateData.slot, stateDataTemp)
                    return(0, 0) // all done
                }
            }
        }
        revert("Not enough weight");
    }

    function getRandomNumber()
        external
        view
        returns (
            uint256 _randomNumber,
            bool _randomNumberQualityScore,
            uint32 _randomTimestamp
        )
    {
        _randomNumber = uint256(
            merkleRoots[stateData.randomNumberProtocolId][
                stateData.randomVotingRoundId
            ]
        );
        _randomNumberQualityScore = stateData.randomNumberQualityScore;
        _randomTimestamp = stateData.randomTimestamp;
    }
}
