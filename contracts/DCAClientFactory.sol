// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./DCAExecutionClient.sol";

/**
 * @title DCAClientFactory
 * @author PowerPool
 */
contract DCAClientFactory is Ownable {
    constructor() {

    }

    function createClient(address agent_, address owner_) external onlyOwner returns (address client) {
        address dcaAgent = msg.sender;
        client = address(new DCAExecutionClient(agent_, dcaAgent));
        Ownable(client).transferOwnership(owner_);
        return client;
    }
}
