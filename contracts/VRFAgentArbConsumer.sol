// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ChainlinkVRFAgentConsumer.sol";
import { ArbSys } from "./interfaces/ArbSys.sol";

/**
 * @title VRFAgentArbConsumer
 * @author PowerPool
 */
contract VRFAgentArbConsumer is ChainlinkVRFAgentConsumer {
    constructor(address agent_) ChainlinkVRFAgentConsumer(agent_) {
    }

    function getLastBlockHash() public override view returns (uint256) {
        uint256 blockNumber = ArbSys(address(100)).arbBlockNumber();
        if (blockNumber == 0) {
            blockNumber = block.number;
            return uint256(blockhash(blockNumber - 1));
        }
        return uint256(ArbSys(address(100)).arbBlockHash(blockNumber - 1));
    }
}
