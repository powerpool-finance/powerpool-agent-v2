// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PPAgentV2.sol";

contract PPAgentV2Lens is PPAgentV2Based {
  constructor(address cvp_) PPAgentV2Based(cvp_) {
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
