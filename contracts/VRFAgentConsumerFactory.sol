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

    function createConsumer(address agent_, address owner_) external onlyOwner returns (VRFAgentConsumerInterface consumer) {
        consumer = new VRFAgentConsumer(agent_);
        Ownable(address(consumer)).transferOwnership(owner_);
        return consumer;
    }
}
