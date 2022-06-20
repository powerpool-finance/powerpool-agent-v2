// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./PPAgentLite.sol";

contract PPAgentLiteLens is PPAgentLite  {
  constructor(address owner_, address cvp_, uint256 minOperatorCvp_, uint256 pendingWithdrawalTimeoutSeconds_)
  PPAgentLite(owner_, cvp_, minOperatorCvp_, pendingWithdrawalTimeoutSeconds_) {
  }

  function isJobActive(bytes32 jobKey_) external view returns (bool) {
    return isJobActivePure(getJobRaw(jobKey_));
  }

  function isJobActivePure(uint256 config_) public pure returns (bool) {
    return (config_ & CFG_ACTIVE) != 0;
  }

  function parseConfig(bytes32 jobKey_) external view returns (
    bool isActive,
    bool useJobOwnerCredits,
    bool assertResolverSelector,
    bool checkKeeperMinCvpDeposit
  ) {
    return parseConfigPure(getJobRaw(jobKey_));
  }

  function parseConfigPure(uint256 config_) public pure returns (
    bool isActive,
    bool useJobOwnerCredits,
    bool assertResolverSelector,
    bool checkKeeperMinCvpDeposit
  ) {
    return (
      (config_ & CFG_ACTIVE) != 0,
      (config_ & CFG_USE_JOB_OWNER_CREDITS) != 0,
      (config_ & CFG_ASSERT_RESOLVER_SELECTOR) != 0,
      (config_ & CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT) != 0
    );
  }
}
