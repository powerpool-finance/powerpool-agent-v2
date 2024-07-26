// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VRFAgentConsumer.sol";
import "./interfaces/VRFAgentConsumerFactoryInterface.sol";

/**
 * @title VRFAgentConsumerFactory
 * @author PowerPool
 */
contract VRFAgentConsumerFactory is VRFAgentConsumerFactoryInterface, Ownable {
    constructor() {

    }

    function createConsumer(address agent_, address owner_, uint64 subId_) external virtual onlyOwner returns (VRFAgentConsumerInterface consumer) {
        address coordinator = msg.sender;
        consumer = new VRFAgentConsumer(agent_);
        consumer.setInitialConfig(coordinator, bytes32(0), subId_);
        consumer.setVrfConfig(1, 1500000, 600);
        Ownable(address(consumer)).transferOwnership(owner_);
        return consumer;
    }
}
