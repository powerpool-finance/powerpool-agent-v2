// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PPAgentV2Based} from "./PPAgentV2Based.sol";

/**
 * @title PPAgentV2
 * @author PowerPool
 */
contract PPAgentV2 is PPAgentV2Based {

  constructor(address cvp_) PPAgentV2Based(cvp_) {

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
