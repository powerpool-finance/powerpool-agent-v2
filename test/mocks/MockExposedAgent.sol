// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../contracts/PPAgentV2Randao.sol";

contract MockExposedAgent is PPAgentV2Randao {
  constructor(
    address owner_,
    address cvp_,
    uint256 minKeeperCvp_,
    uint256 pendingWithdrawalTimeoutSeconds_,
    RandaoConfig memory rdConfig_)
    PPAgentV2Randao(owner_, cvp_, minKeeperCvp_, pendingWithdrawalTimeoutSeconds_, rdConfig_) {
  }

  function assignNextKeeper(bytes32 jobKey_) external {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
    _releaseJob(jobKey_, expectedKeeperId);
    _assignNextKeeper(jobKey_);
  }
}
