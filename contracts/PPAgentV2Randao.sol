// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PPAgentV2RandaoBased} from "./PPAgentV2RandaoBased.sol";

/**
 * @title PPAgentV2Randao
 * @author PowerPool
 */
contract PPAgentV2Randao is PPAgentV2RandaoBased {

  constructor(address cvp_) PPAgentV2RandaoBased(cvp_) {

  }

  function _assertExecutionNotLocked() internal override view {
    bytes32 lockKey = EXECUTION_LOCK_KEY;
    assembly ("memory-safe") {
      let isLocked := tload(lockKey)
      if isLocked {
        mstore(0x1c, 0x0815283600000000000000000000000000000000000000000000000000000000)
        revert(0x1c, 4)
      }
    }
  }

  function _setExecutionLock(uint value_) internal override {
    bytes32 lockKey = EXECUTION_LOCK_KEY;
    assembly ("memory-safe") {
      tstore(lockKey, value_)
    }
  }
}
