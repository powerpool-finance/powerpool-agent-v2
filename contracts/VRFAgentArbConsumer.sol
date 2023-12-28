// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./VRFAgentConsumer.sol";

interface ArbSys {
    /**
    * @notice Get Arbitrum block number (distinct from L1 block number; Arbitrum genesis block has block number 0)
    * @return block number as int
     */
    function arbBlockNumber() external view returns (uint);
    /**
     * @notice Get Arbitrum block hash (reverts unless currentBlockNum-256 <= arbBlockNum < currentBlockNum)
     * @return block hash
     */
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}

/**
 * @title VRFAgentArbConsumer
 * @author PowerPool
 */
contract VRFAgentArbConsumer is VRFAgentConsumer {
    constructor(address agent_) VRFAgentConsumer(agent_) {
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
