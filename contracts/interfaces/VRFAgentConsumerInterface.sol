// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface VRFAgentConsumerInterface {

    function setVrfConfig(
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint64 vrfSubscriptionId_,
        uint16 vrfRequestConfirmations_,
        uint32 vrfCallbackGasLimit_,
        uint256 vrfRequestPeriod_
    ) external;

    function setOffChainIpfsHash(string calldata _ipfsHash) external;

    function getPseudoRandom() external returns (uint256);

}
