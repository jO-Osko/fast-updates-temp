import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { config, contract, ethers, web3 } from "hardhat";
import { HardhatNetworkAccountConfig } from "hardhat/types";
import { ECDSASignatureWithIndex } from "../../../../scripts/libs/protocol/ECDSASignatureWithIndex";
import { IProtocolMessageMerkleRoot, ProtocolMessageMerkleRoot } from "../../../../scripts/libs/protocol/ProtocolMessageMerkleRoot";
import { ISigningPolicy, SigningPolicy } from "../../../../scripts/libs/protocol/SigningPolicy";
import {
  IPayloadMessage,
  PayloadMessage
} from "../../../../scripts/libs/protocol/PayloadMessage";
import { getTestFile } from "../../../utils/constants";
import { defaultTestSigningPolicy } from "./coding-helpers";

contract(`Coding; ${getTestFile(__filename)}`, async () => {
  let signers: SignerWithAddress[];
  let accountAddresses: string[];
  const accountPrivateKeys = (config.networks.hardhat.accounts as HardhatNetworkAccountConfig[]).map(x => x.privateKey);
  const N = 100;
  const singleWeight = 500;
  const firstRewardEpochVotingRoundId = 1000;
  const rewardEpochDurationInEpochs = 3360; // 3.5 days
  const votingRoundId = 4111;
  const rewardEpochId = Math.floor((votingRoundId - firstRewardEpochVotingRoundId) / rewardEpochDurationInEpochs);
  let signingPolicyData: ISigningPolicy;

  before(async () => {
    accountAddresses = (await ethers.getSigners()).map(x => x.address);
    signingPolicyData = defaultTestSigningPolicy(
      accountAddresses,
      N,
      singleWeight
    );
    signingPolicyData.rewardEpochId = rewardEpochId;
  });

  it("Should encode and decode signing policy", async () => {
    const encoded = SigningPolicy.encode(signingPolicyData);
    const decoded = SigningPolicy.decode(encoded);
    expect(decoded).to.deep.equal(signingPolicyData);
  });

  it("Should encode and decode ECDSA signature", async () => {
    const messageHash = "0x1122334455667788990011223344556677889900112233445566778899001122";
    const signature = await ECDSASignatureWithIndex.signMessageHash(messageHash, accountPrivateKeys[0], 0);
    const encoded = ECDSASignatureWithIndex.encode(signature);
    const decoded = ECDSASignatureWithIndex.decode(encoded);
    expect(decoded).to.deep.equal(signature);
  });

  it("Should encode and decode protocol message merkle root", async () => {
    const messageData = {
      protocolId: 15,
      votingRoundId: 1234,
      randomQualityScore: true,
      merkleRoot: "0x1122334455667788990011223344556677889900112233445566778899001122",
    } as IProtocolMessageMerkleRoot;
    const encoded = ProtocolMessageMerkleRoot.encode(messageData);
    const decoded = ProtocolMessageMerkleRoot.decode(encoded);
    expect(decoded).to.deep.equal(messageData);
  });

  it("Should encode and decode signature payloads", async () => {
    let payloads: IPayloadMessage<string>[] = [];
    const N = 10;
    let encoded = "0x";    
    for (let i = 0; i < N; i++) {
      let payload = {
        protocolId: i,
        votingRoundId: 10 * i,
        payload: web3.utils.randomHex(2 * (N - i)),
      } as IPayloadMessage<string>;
      payloads.push(payload);
      encoded += PayloadMessage.encode(payload).slice(2);
    }
    const decoded = PayloadMessage.decode(encoded);
    expect(decoded).to.deep.equal(payloads);
  });

});
