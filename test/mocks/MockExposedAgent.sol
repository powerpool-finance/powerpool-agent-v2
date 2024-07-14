// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../contracts/PPAgentV2RandaoBased.sol";

contract MockExposedAgent is PPAgentV2RandaoBased {
  constructor(address cvp_) PPAgentV2RandaoBased(cvp_) {
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

  function shouldAssignKeeper(bytes32 jobKey_) public view returns (bool) {
    return _shouldAssignKeeperBin(jobKey_, getJobRaw(jobKey_));
  }
}
