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
    rdConfig = PPAgentV2Randao.RandaoConfig({
      slashingEpochBlocks: 10,
      period1: 15,
      period2: 30,
      slashingFeeFixedCVP: 50,
      slashingFeeBps: 300,
      jobMinCredits: 0.1 ether
    });
    agent = new PPAgentV2Randao(owner, address(cvp), 3_000 ether, 3 days, rdConfig);
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
    PPAgentV2Randao.RandaoConfig memory config = PPAgentV2Randao.RandaoConfig({
      slashingEpochBlocks: 20,
      period1: 25,
      period2: 40,
      slashingFeeFixedCVP: 60,
      slashingFeeBps: 400,
      jobMinCredits: 0 ether
    });
    vm.prank(owner, owner);
    agent.setRdConfig(config);
    (
      uint8 slashingEpochBlocks,
      uint24 period1,
      uint16 period2,
      uint24 slashingFeeFixedCVP,
      uint16 slashingFeeBps,
      uint96 jobMinCredits
    ) = agent.rdConfig();
    assertEq(slashingEpochBlocks, 20);
    assertEq(period1, 25);
    assertEq(period2, 40);
    assertEq(slashingFeeFixedCVP, 60);
    assertEq(slashingFeeBps, 400);
    assertEq(jobMinCredits, 0);
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

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, true, false, false);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
  }

  function testRdJobOwnerEnableJobWithJobOwnerCreditSource() public {
    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, false, false, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);

    vm.prank(alice, alice);
    agent.setJobConfig(jobKey, true, false, false);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
  }

  function testRdKeeperSetActiveInactive() public {
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
    assertEq(_keeperIsActive(3), true);

    vm.prank(keeperAdmin, keeperAdmin);
    agent.setKeeperActiveStatus(kid3, false);
    assertEq(_keeperIsActive(3), false);

    vm.prank(keeperAdmin, keeperAdmin);
    agent.setKeeperActiveStatus(kid3, true);
    assertEq(_keeperIsActive(3), true);
  }

  function testRdKeeperCantSetActiveAgain() public {
    assertEq(_keeperIsActive(3), true);

    vm.expectRevert(PPAgentV2Randao.KeeperIsAlreadyActive.selector);
    vm.prank(keeperAdmin, keeperAdmin);
    agent.setKeeperActiveStatus(kid3, true);
  }

  function testRdKeeperCantSetInactiveAgain() public {
    vm.prank(keeperAdmin, keeperAdmin);
    agent.setKeeperActiveStatus(kid3, false);

    vm.expectRevert(PPAgentV2Randao.KeeperIsAlreadyInactive.selector);
    vm.prank(keeperAdmin, keeperAdmin);
    agent.setKeeperActiveStatus(kid3, false);
  }

  function testRdKeeperAssignedAfterJobCreditsTopupZero() public {
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
  }

  function testRdKeeperNotAssignedAfterJobCreationLowJobCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 0.5 ether;
    agent.setRdConfig(rdConfig);

    (jobKey,jobId) = agent.registerJob{ value: 0.4 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperNotAssignedAfterJobCreationLowJobOwnerCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 0.5 ether;
    agent.setRdConfig(rdConfig);

    params.useJobOwnerCredits = true;

    (jobKey,jobId) = agent.registerJob{ value: 0.4 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobCreationSufficientJobCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 0.5 ether;
    agent.setRdConfig(rdConfig);

    (jobKey,jobId) = agent.registerJob{ value: 0.5 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobCreationSufficientJobOwnerCredits() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 0.5 ether;
    agent.setRdConfig(rdConfig);

    params.useJobOwnerCredits = true;

    (jobKey,jobId) = agent.registerJob{ value: 0.5 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperKeptAfterJobCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 1.5 ether;
    agent.setRdConfig(rdConfig);

    vm.prank(alice);
    agent.depositJobCredits{value: 1.5 ether }(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 1.5 ether;
    agent.setRdConfig(rdConfig);

    vm.prank(keeperAdmin);
    agent.releaseJob(kid2, jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);

    vm.prank(alice);
    agent.depositJobCredits{value: 1.5 ether }(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 0);
  }

  function testRdKeeperAssignedAfterJobOwnerCreditsTopup() public {
    vm.prank(owner);
    rdConfig.jobMinCredits = 1.5 ether;
    agent.setRdConfig(rdConfig);

    params.useJobOwnerCredits = true;

    vm.deal(bob, 10 ether);
    vm.prank(bob);
    (jobKey,jobId) = agent.registerJob{ value: 0.5 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

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
}