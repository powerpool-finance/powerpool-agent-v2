// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VRFAgentCoordinatorClient.sol";

/**
 * @title VRFAgentCoordinatorClientFactory
 * @author PowerPool
 */
contract VRFAgentCoordinatorClientFactory is Ownable {
    constructor() {
    }

    /*** OWNER METHODS ***/
    function createCoordinatorClient(
        address owner,
        VRFAgentCoordinatorInterface coordinator,
        uint64 subscriptionId,
        address agent
    ) external onlyOwner returns (VRFAgentCoordinatorClient client) {
        client = new VRFAgentCoordinatorClient(coordinator, subscriptionId, agent);
        client.transferOwnership(owner);
    }
}
