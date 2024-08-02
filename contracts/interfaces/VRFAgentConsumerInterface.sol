// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./VRFAgentCoordinatorInterface.sol";

interface VRFAgentConsumerInterface {

    function setInitialConfig(
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint64 vrfSubscriptionId_
    ) external;

    function setVrfConfig(
        uint16 vrfRequestConfirmations_,
        uint32 vrfCallbackGasLimit_,
        uint256 vrfRequestPeriod_
    ) external;

    function setOffChainIpfsHash(string calldata _ipfsHash) external;

    function fulfillRandomnessOffchainResolver() external view returns (bool, bytes memory);

    function getPseudoRandom() external returns (uint256);

    function fulfillRandomWords(VRFAgentCoordinatorInterface.Proof calldata proof, VRFAgentCoordinatorInterface.RequestCommitment calldata rc) external;
}
