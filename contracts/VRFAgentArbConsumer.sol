// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./VRFAgentConsumer.sol";

interface ArbSys {
    /**
    * @notice Get Arbitrum block number (distinct from L1 block number; Arbitrum genesis block has block number 0)
    * @return block number as int
     */
    function arbBlockNumber() external view returns (uint);
}

/**
 * @title VRFAgentArbConsumer
 * @author PowerPool
 */
contract VRFAgentArbConsumer is VRFAgentConsumer {
    constructor(address agent_) VRFAgentConsumer(agent_) {
    }

    function getLastBlockHash() public override view returns (uint256) {
        return uint256(blockhash(ArbSys(address(100)).arbBlockNumber() - 1));
    }
}
