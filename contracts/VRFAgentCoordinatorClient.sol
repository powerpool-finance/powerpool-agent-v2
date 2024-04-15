// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/VRFAgentCoordinatorInterface.sol";

/**
 * @title VRFAgentConsumer
 * @author PowerPool
 */
contract VRFAgentCoordinatorClient is Ownable {
    VRFAgentCoordinatorInterface public immutable vrfCoordinator;
    uint64 public immutable subscriptionId;
    address public immutable agent;

    mapping(address => bool) public clientConsumers;

    event AddClientConsumer(address consumer);

    error InvalidConsumer(uint64 subId, address consumer);

    constructor(VRFAgentCoordinatorInterface _vrfCoordinator, uint64 _subscriptionId, address _agent) {
        vrfCoordinator = _vrfCoordinator;
        subscriptionId = _subscriptionId;
        agent = _agent;
    }

    /*** AGENT OWNER METHODS ***/
    function requestRandomWords(
        bytes32 /* keyHash */,
        uint64 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external {
        if (!clientConsumers[msg.sender]) {
            revert InvalidConsumer(subscriptionId, msg.sender);
        }
        vrfCoordinator.requestRandomWords(agent, subId, requestConfirmations, callbackGasLimit, numWords);
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
