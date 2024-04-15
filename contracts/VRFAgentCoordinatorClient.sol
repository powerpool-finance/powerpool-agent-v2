// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import {VRFCoordinatorV2Interface} from "./interfaces/VRFCoordinatorV2Interface.sol";

/**
 * @title VRFAgentConsumer
 * @author PowerPool
 */
contract VRFAgentCoordinatorClient is Ownable {
    VRFCoordinatorV2Interface public immutable vrfCoordinator;
    uint64 public immutable subscriptionId;

    mapping(address => bool) public clientConsumers;

    event AddClientConsumer(address consumer);

    constructor(VRFCoordinatorV2Interface _vrfCoordinator, uint64 _subscriptionId) {
        vrfCoordinator = _vrfCoordinator;
        subscriptionId = _subscriptionId;
    }

    /*** AGENT OWNER METHODS ***/
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external {
        require(clientConsumers[msg.sender], "sender should be consumer");
        vrfCoordinator.requestRandomWords(keyHash, subId, requestConfirmations, callbackGasLimit, numWords);
    }

    function syncConsumers(address _consumer) external onlyOwner {
        clientConsumers[_consumer] = true;
        emit AddClientConsumer(_consumer);
    }

    function removeConsumer(address _consumer) external onlyOwner {
        clientConsumers[_consumer] = false;
        emit AddClientConsumer(_consumer);
    }

    function requestSubscriptionOwnerTransfer(address _newOwner) external onlyOwner {
        vrfCoordinator.requestSubscriptionOwnerTransfer(subscriptionId, _newOwner);
    }

    function fulfillResolver() external view returns (bool, bytes memory) {
        return (vrfCoordinator.pendingRequestExists(subscriptionId), bytes(""));
    }
}
