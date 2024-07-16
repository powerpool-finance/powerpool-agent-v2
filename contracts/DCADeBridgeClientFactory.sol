// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./DCADeBridgeExecutionClient.sol";

/**
 * @title DCAClientFactory
 * @author PowerPool
 */
contract DCADeBridgeClientFactory is Ownable {
    constructor() {

    }

    function createClient(address agent_, address owner_) external onlyOwner returns (address client) {
        address dcaAgent = msg.sender;
        client = address(new DCADeBridgeExecutionClient(agent_, dcaAgent));
        Ownable(client).transferOwnership(owner_);
        return client;
    }
}
