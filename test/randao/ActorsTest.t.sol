// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";

contract RandaoActorsTest is TestHelperRandao {
  event Execute(bytes32 indexed jobKey, address indexed job, bool indexed success, uint256 gasUsed, uint256 baseFee, uint256 gasPrice, uint256 compensation);

  OnlySelectorTestJob internal counter;

  bytes32 internal jobKey;
  uint256 internal jobId;
  uint256 internal defaultFlags;
  uint256 internal accrueFlags;
  uint256 internal kid1;
  uint256 internal kid2;
  uint256 internal kid3;
  uint256 internal latestKeeperStub;
  IPPAgentV2Viewer.Resolver resolver;
  IPPAgentV2JobOwner.RegisterJobParams params;
  PPAgentV2Randao.RandaoConfig rdConfig;

  function setUp() public override {
    defaultFlags = _config({
      acceptMaxBaseFeeLimit: false,
      accrueReward: false
    });
    accrueFlags = _config({
      acceptMaxBaseFeeLimit: false,
      accrueReward: true
    });
    cvp = new MockCVP();
    rdConfig = IPPAgentV2RandaoViewer.RandaoConfig({
      slashingEpochBlocks: 10,
      period1: 15,
      period2: 30,
      slashingFeeFixedCVP: 50,
      slashingFeeBps: 300,
      jobMinCreditsFinney: 100,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 10_000,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8,
      jobFixedRewardFinney: 3
    });
    agent = new PPAgentV2Randao(address(cvp));
    agent.initializeRandao(owner, 3_000 ether, 3 days, rdConfig);
    counter = new OnlySelectorTestJob(address(agent));

    {
      cvp.transfer(keeperAdmin, 15_000 ether);

      vm.startPrank(keeperAdmin);
      cvp.approve(address(agent), 15_000 ether);
      kid1 = agent.registerAsKeeper(alice, 5_000 ether);
      kid2 = agent.registerAsKeeper(keeperWorker, 5_000 ether);
      kid3 = agent.registerAsKeeper(bob, 5_000 ether);
      vm.stopPrank();

      assertEq(counter.current(), 0);
    }

    resolver = IPPAgentV2Viewer.Resolver({
      resolverAddress: address(counter),
      resolverCalldata: new bytes(0)
    });
    params = IPPAgentV2JobOwner.RegisterJobParams({
      jobAddress: address(counter),
      jobSelector: OnlySelectorTestJob.increment.selector,
      maxBaseFeeGwei: 100,
      rewardPct: 35,
      fixedReward: 10,
      useJobOwnerCredits: false,
      assertResolverSelector: false,
      jobMinCvp: 0,

      // For interval jobs
      calldataSource: CALLDATA_SOURCE_SELECTOR,
      intervalSeconds: 10
    });
    vm.prank(alice);
    vm.deal(alice, 10 ether);
    (jobKey,jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function testRdOwnerCanSetRdConfig() public {
    assertEq(agent.owner(), owner);
    IPPAgentV2RandaoViewer.RandaoConfig memory config = IPPAgentV2RandaoViewer.RandaoConfig({
      slashingEpochBlocks: 20,
      period1: 25,
      period2: 40,
      slashingFeeFixedCVP: 60,
      slashingFeeBps: 400,
      jobMinCreditsFinney: 0 ether,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 12_000,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8,
      jobFixedRewardFinney: 3
    });
    vm.prank(owner, owner);
    agent.setRdConfig(config);
    IPPAgentV2RandaoViewer.RandaoConfig memory agentConfig = agent.getRdConfig();
    assertEq(agentConfig.slashingEpochBlocks, 20);
    assertEq(agentConfig.period1, 25);
    assertEq(agentConfig.period2, 40);
    assertEq(agentConfig.slashingFeeFixedCVP, 60);
    assertEq(agentConfig.slashingFeeBps, 400);
    assertEq(agentConfig.jobMinCreditsFinney, 0);
    assertEq(agentConfig.agentMaxCvpStake, 50_000);
    assertEq(agentConfig.jobCompensationMultiplierBps, 12_000);
    assertEq(agentConfig.stakeDivisor, 50_000_000);
    assertEq(agentConfig.keeperActivationTimeoutHours, 8);
  }

  function testRdJobOwnerDisableJob() public {
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, false, false, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, false, false, false);
  }

  function testRdJobOwnerEnableJobWithJobCreditSource() public {
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, false, false, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
    assertEq(_jobLastExecutionAt(jobKey), 0);

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, true, false, false);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(_jobLastExecutionAt(jobKey), 1600000000);
  }

  function testRdKeeperSetActiveInactive() public {
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
    assertEq(_keeperIsActive(3), true);

    vm.prank(keeperAdmin, keeperAdmin);
    agent.disableKeeper(kid3);
    assertEq(_keeperIsActive(3), false);

    vm.prank(keeperAdmin, keeperAdmin);
    agent.initiateKeeperActivation(kid3);
    assertEq(_keeperIsActive(3), false);

    vm.warp(block.timestamp + 9 hours);
    vm.prank(keeperAdmin, keeperAdmin);
    agent.finalizeKeeperActivation(kid3);
    assertEq(_keeperIsActive(3), true);
  }

  function testRdKeeperCantSetActiveAgain() public {
    assertEq(_keeperIsActive(3), true);

    vm.expectRevert(PPAgentV2Randao.KeeperIsAlreadyActive.selector);
    vm.prank(keeperAdmin, keeperAdmin);
    agent.initiateKeeperActivation(kid3);
    vm.roll(9 hours);
    vm.prank(keeperAdmin, keeperAdmin);
    agent.finalizeKeeperActivation(kid3);
    assertEq(_keeperIsActive(3), true);
  }

  function testRdKeeperCantSetInactiveAgain() public {
    vm.prank(keeperAdmin, keeperAdmin);
    agent.disableKeeper(kid3);

    vm.expectRevert(PPAgentV2Randao.KeeperIsAlreadyInactive.selector);
    vm.prank(keeperAdmin, keeperAdmin);
    agent.disableKeeper(kid3);
  }

  function testRdKeeperAssignedAfterJobCreditsTopupZero() public {
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
  }

  function testRdKeeperNotAssignedAfterJobCreationLowJobCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 500;
    agent.setRdConfig(rdConfig);

    (jobKey,jobId) = agent.registerJob{ value: 0.4 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperNotAssignedAfterJobCreationLowJobOwnerCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 500;
    agent.setRdConfig(rdConfig);

    params.useJobOwnerCredits = true;

    (jobKey,jobId) = agent.registerJob{ value: 0.4 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobCreationSufficientJobCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 500;
    agent.setRdConfig(rdConfig);

    (jobKey,jobId) = agent.registerJob{ value: 0.5 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobCreationSufficientJobOwnerCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 500;
    agent.setRdConfig(rdConfig);

    params.useJobOwnerCredits = true;

    (jobKey,jobId) = agent.registerJob{ value: 0.5 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperKeptAfterJobCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 1500;
    agent.setRdConfig(rdConfig);
    assertEq(_jobLastExecutionAt(jobKey), 0);

    vm.prank(alice);
    agent.depositJobCredits{value: 1.5 ether }(jobKey);

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 1500;
    agent.setRdConfig(rdConfig);

    vm.prank(keeperAdmin);
    agent.releaseJob(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
    assertEq(_jobLastExecutionAt(jobKey), 0);

    vm.prank(alice);
    agent.depositJobCredits{value: 1.5 ether }(jobKey);

    assertEq(_jobLastExecutionAt(jobKey), 1600000000);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperNotAssignedAfterInactiveJobCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 1500;
    agent.setRdConfig(rdConfig);

    vm.prank(keeperAdmin);
    agent.releaseJob(jobKey);

    vm.prank(alice);
    agent.setJobConfig(jobKey, false, false, true);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
    assertEq(_jobLastExecutionAt(jobKey), 0);

    vm.prank(alice);
    agent.depositJobCredits{value: 1.5 ether }(jobKey);

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobOwnerCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 1500;
    agent.setRdConfig(rdConfig);

    params.useJobOwnerCredits = true;
    assertEq(_jobLastExecutionAt(jobKey), 0);

    vm.deal(bob, 10 ether);
    vm.prank(bob);
    (jobKey,jobId) = agent.registerJob{ value: 0.5 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);

    vm.prank(bob);
    agent.depositJobOwnerCredits{value: 1 ether }(bob);

    bytes32[] memory jobKeys = new bytes32[](1);
    jobKeys[0] = jobKey;
    vm.prank(bob);
    agent.assignKeeper(jobKeys);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperNotChangedAfterJobCreditsWithdrawal() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 500;
    agent.setRdConfig(rdConfig);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);

    vm.prank(alice);
    agent.withdrawJobCredits(jobKey, alice, 0.50 ether);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperUnassignedAfterJobCreditsWithdrawal() public {
    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 500;
    agent.setRdConfig(rdConfig);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);

    vm.prank(alice);
    agent.withdrawJobCredits(jobKey, alice, 0.51 ether);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }
}
