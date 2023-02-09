// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IPPAgentV2Executor {
  function execute_44g58pv() external;
}

interface IPPAgentV2Viewer {
  struct Job {
    uint8 config;
    bytes4 selector;
    uint88 credits;
    uint16 maxBaseFeeGwei;
    uint16 rewardPct;
    uint32 fixedReward;
    uint8 calldataSource;

    // For interval jobs
    uint24 intervalSeconds;
    uint32 lastExecutionAt;
  }

  struct Resolver {
    address resolverAddress;
    bytes resolverCalldata;
  }

  function getConfig() external view returns (
    uint256 minKeeperCvp_,
    uint256 pendingWithdrawalTimeoutSeconds_,
    uint256 feeTotal_,
    uint256 feePpm_,
    uint256 lastKeeperId_
  );
  function getKeeper(uint256 keeperId_) external view returns (
    address admin,
    address worker,
    bool isActive,
    uint256 currentStake,
    uint256 slashedStake,
    uint256 compensation,
    uint256 pendingWithdrawalAmount,
    uint256 pendingWithdrawalEndAt
  );
  function getKeeperWorkerAndStake(uint256 keeperId_) external view returns (
    address worker,
    uint256 currentStake,
    bool isActive
  );
  function getJob(bytes32 jobKey_) external view returns (
    address owner,
    address pendingTransfer,
    uint256 jobLevelMinKeeperCvp,
    Job memory details,
    bytes memory preDefinedCalldata,
    Resolver memory resolver
  );
  function getJobRaw(bytes32 jobKey_) external view returns (uint256 rawJob);
  function jobOwnerCredits(address owner_) external view returns (uint256 credits);
}

interface IPPAgentV2JobOwner {
  struct RegisterJobParams {
    address jobAddress;
    bytes4 jobSelector;
    bool useJobOwnerCredits;
    bool assertResolverSelector;
    uint16 maxBaseFeeGwei;
    uint16 rewardPct;
    uint32 fixedReward;
    uint256 jobMinCvp;
    uint8 calldataSource;
    uint24 intervalSeconds;
  }
}
