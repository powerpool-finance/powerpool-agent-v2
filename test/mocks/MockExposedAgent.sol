// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../contracts/PPAgentV2Randao.sol";

contract MockExposedAgent is PPAgentV2Randao {
  constructor(address cvp_) PPAgentV2Randao(cvp_) {
  }

  function assignNextKeeper(bytes32 jobKey_) external {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
    if (expectedKeeperId != 0) {
      _unassignKeeper(jobKey_, expectedKeeperId);
    }
    _assignNextKeeper(jobKey_, expectedKeeperId);
  }
}
