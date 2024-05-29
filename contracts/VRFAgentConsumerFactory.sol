// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VRFAgentConsumer.sol";
import "./interfaces/VRFAgentConsumerFactoryInterface.sol";

/**
 * @title VRFAgentConsumer
 * @author PowerPool
 */
contract VRFAgentConsumerFactory is VRFAgentConsumerFactoryInterface, Ownable {
    constructor() {

    }

    function createConsumer(address agent_, address owner_, uint64 subId_) external onlyOwner returns (VRFAgentConsumerInterface consumer) {
        address coordinator = msg.sender;
        consumer = new VRFAgentConsumer(agent_);
        consumer.setVrfConfig(coordinator, bytes32(0), subId_, 1, 1500000, 10);
        Ownable(address(consumer)).transferOwnership(owner_);
        return consumer;
    }
}
