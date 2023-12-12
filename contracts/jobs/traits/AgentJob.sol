// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../../lib/forge-std/src/console.sol";

abstract contract AgentJob {
  address public agent;
  bytes32 public lastExecuteByJobKey;

  modifier onlyAgent() {
    require(msg.sender == agent);
    _;
  }

  constructor(address agent_) {
    agent = agent_;
  }

  function _setJobKeyFromCalldata() internal {
    bytes32 jobFromCalldata;
    assembly ("memory-safe") {
      jobFromCalldata := calldataload(sub(calldatasize(), 32))
    }
    lastExecuteByJobKey = jobFromCalldata;
  }
}
