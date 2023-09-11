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
    _chooseNextKeeper(jobKey_, expectedKeeperId);
  }

  function getKeeperLimitedStake(
    uint256 keeperCurrentStake_,
    uint256 agentMaxCvpStakeCvp_,
    uint256 job_
  ) public pure returns (uint256) {
    return _getKeeperLimitedStake(keeperCurrentStake_, agentMaxCvpStakeCvp_, job_);
  }
}
