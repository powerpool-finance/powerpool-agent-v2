// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VRFAgentCoordinatorClient.sol";

/**
 * @title VRFAgentConsumer
 * @author PowerPool
 */
contract VRFAgentCoordinatorClientFactory is Ownable {
    constructor() {
    }

    /*** AGENT OWNER METHODS ***/
    function createCoordinatorClient(
        address owner,
        VRFCoordinatorV2Interface coordinator,
        uint64 subscriptionId
    ) external onlyOwner returns (VRFAgentCoordinatorClient client) {
        client = new VRFAgentCoordinatorClient(coordinator, subscriptionId);
        client.transferOwnership(owner);
    }
}
