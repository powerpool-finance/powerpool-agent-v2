// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VRFAgentArbConsumer.sol";
import "./interfaces/VRFAgentConsumerFactoryInterface.sol";

/**
 * @title VRFAgentArbConsumerFactory
 * @author PowerPool
 */
contract VRFAgentArbConsumerFactory is VRFAgentConsumerFactoryInterface, Ownable {
    constructor() {

    }

    function createConsumer(address agent_, address owner_) external onlyOwner returns (VRFAgentConsumerInterface consumer) {
        consumer = new VRFAgentArbConsumer(agent_);
        Ownable(address(consumer)).transferOwnership(owner_);
        return consumer;
    }
}
