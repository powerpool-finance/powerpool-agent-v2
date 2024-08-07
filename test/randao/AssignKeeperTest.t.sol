// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";
import "../jobs/SimpleCalldataTestJob.sol";
import "../jobs/SimpleCustomizableCalldataTestJob.sol";
import "../mocks/MockExposedAgent.sol";

contract RandaoAssignKeeperTest is TestHelperRandao {
  ICounter internal job;

  event Execute(bytes32 indexed jobKey, address indexed job, bool indexed success, uint256 gasUsed, uint256 baseFee, uint256 gasPrice, uint256 compensation);

  OnlySelectorTestJob internal counter;

  address payable constant internal a1 = payable(0x1111111111111111111111111111111111111101);
  address payable constant internal a2 = payable(0x1111111111111111111111111111111111111102);
  address payable constant internal a3 = payable(0x1111111111111111111111111111111111111103);
  address payable constant internal a4 = payable(0x1111111111111111111111111111111111111104);
  address payable constant internal a5 = payable(0x1111111111111111111111111111111111111105);
  address payable constant internal w1 = payable(0x1111111111111111111111111111111111111201);
  address payable constant internal w2 = payable(0x1111111111111111111111111111111111111202);
  address payable constant internal w3 = payable(0x1111111111111111111111111111111111111203);
  address payable constant internal w4 = payable(0x1111111111111111111111111111111111111204);
  address payable constant internal w5 = payable(0x1111111111111111111111111111111111111205);

  bytes32 internal jobKey;
  uint256 internal jobId;
  uint256 internal kid1;
  uint256 internal kid2;
  uint256 internal kid3;
  uint256 internal kid4;
  uint256 internal kid5;

  MockExposedAgent _agent;
  PPAgentV2Randao.RandaoConfig rdConfig;
  PPAgentV2.Resolver resolver;
  IPPAgentV2JobOwner.RegisterJobParams params;

  function setUp() public override {
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
      jobFixedRewardFinney: 30
    });
    agent = new MockExposedAgent(address(cvp));
    agent.initializeRandao(owner, 3_000 ether, 3 days, rdConfig);

    {
      cvp.transfer(a1, 5_000 ether);
      cvp.transfer(a2, 5_000 ether);
      cvp.transfer(a3, 5_000 ether);
      cvp.transfer(a4, 5_000 ether);
      cvp.transfer(a5, 5_000 ether);

      vm.startPrank(a1);
      cvp.approve(address(agent), 5_000 ether);
      kid1 = agent.registerAsKeeper(w1, 5_000 ether);
      vm.stopPrank();

      vm.startPrank(a2);
      cvp.approve(address(agent), 5_000 ether);
      kid2 = agent.registerAsKeeper(w2, 5_000 ether);
      vm.stopPrank();

      vm.startPrank(a3);
      cvp.approve(address(agent), 5_000 ether);
      kid3 = agent.registerAsKeeper(w3, 5_000 ether);
      vm.stopPrank();

      vm.startPrank(a4);
      cvp.approve(address(agent), 5_000 ether);
      kid4 = agent.registerAsKeeper(w4, 5_000 ether);
      vm.stopPrank();

      vm.startPrank(a5);
      cvp.approve(address(agent), 5_000 ether);
      kid5 = agent.registerAsKeeper(w5, 5_000 ether);
      vm.stopPrank();

      vm.warp(block.timestamp + 8 hours);
      vm.prank(a1);
      agent.finalizeKeeperActivation(1);
      vm.prank(a2);
      agent.finalizeKeeperActivation(2);
      vm.prank(a3);
      agent.finalizeKeeperActivation(3);
      vm.prank(a4);
      agent.finalizeKeeperActivation(4);
      vm.prank(a5);
      agent.finalizeKeeperActivation(5);
    }

    _agent = MockExposedAgent(address(agent));
    job = new SimpleCalldataTestJob(address(agent));

    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
  }

  function _setupJob(address job_, bytes4 selector_, bool assertSelector_) internal {
    resolver = IPPAgentV2Viewer.Resolver({
      resolverAddress: job_,
      resolverCalldata: abi.encodeWithSelector(SimpleCustomizableCalldataTestJob.myResolver.selector, "myPass")
    });
    params = IPPAgentV2JobOwner.RegisterJobParams({
      jobAddress: job_,
      jobSelector: selector_,
      maxBaseFeeGwei: 100,
      rewardPct: 35,
      fixedReward: 10,
      useJobOwnerCredits: false,
      assertResolverSelector: assertSelector_,
      jobMinCvp: 0,

      // For interval jobs
      calldataSource: CALLDATA_SOURCE_RESOLVER,
      intervalSeconds: 0
    });
    vm.deal(alice, 2 ether);
    vm.prank(alice);
    (jobKey,jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function _setDifficultyExpectKid(uint256 difficulty_, uint256 expectedKid_) internal {
    vm.prevrandao(bytes32(uint256(difficulty_)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), expectedKid_);
  }

  function testRdAssignKeeperCircle() public {
    assertEq(agent.getActiveKeepersLength(), 5);
    assertEq(_keeperCount(), 5);
    assertEq(agent.jobNextKeeperId(jobKey), 1);

    _setDifficultyExpectKid(10, 1);
    _setDifficultyExpectKid(11, 2);
    _setDifficultyExpectKid(12, 3);
    _setDifficultyExpectKid(13, 4);
    _setDifficultyExpectKid(14, 5);
    _setDifficultyExpectKid(15, 1);
  }

  function testRdAssignKeeperEdgeDifficulty() public {
    _setDifficultyExpectKid(0, 1);
    _setDifficultyExpectKid(type(uint256).max, 5);
  }

  function testRdAssignKeeperEdgeThreeActive() public {
    // release kid1
    _setDifficultyExpectKid(2, 3);
    assertEq(agent.getJobsAssignedToKeeperLength(3), 1);

    vm.prank(a1);
    agent.disableKeeper(kid1);
    vm.prank(a5);
    agent.disableKeeper(kid5);

    assertEq(agent.getActiveKeepersLength(), 3);
    assertEq(_keeperCount(), 5);

    _setDifficultyExpectKid(10, 3);
    _setDifficultyExpectKid(11, 4);
    _setDifficultyExpectKid(12, 2);
    _setDifficultyExpectKid(13, 3);
  }

  function testRdAssignKeeper1Disabled2InsufficientDeposit() public {
    // release kid1
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(owner);
    _agent.setAgentParams(1_000 ether, 10, 10);
    _updateMinJobCvp(3_000 ether);

    assertEq(_globalMinKeeperCvp(), 1_000 ether);
    assertEq(_jobMinKeeperCvp(jobKey), 3_000 ether);

    vm.prank(a5);
    agent.disableKeeper(kid5);
    vm.prank(a4);
    agent.initiateRedeem(kid4, 3_000 ether);
    vm.prank(a3);
    agent.initiateRedeem(kid3, 3_000 ether);

    assertEq(agent.getActiveKeepersLength(), 4);
    assertEq(_keeperCount(), 5);

    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 5_000 ether);
    assertEq(_stakeOf(kid3), 2_000 ether);
    assertEq(_stakeOf(kid4), 2_000 ether);
    assertEq(_stakeOf(kid5), 5_000 ether);

    _setDifficultyExpectKid(10, 2);
    _setDifficultyExpectKid(11, 1);
    _setDifficultyExpectKid(12, 1);
    _setDifficultyExpectKid(13, 1);
    _setDifficultyExpectKid(14, 2);
    _setDifficultyExpectKid(15, 1);
    _setDifficultyExpectKid(16, 1);
    _setDifficultyExpectKid(17, 1);
    _setDifficultyExpectKid(18, 2);
  }

  function testRdAssignKeeper2Disabled1InsufficientDeposit() public {
    // release kid1
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(owner);
    _agent.setAgentParams(1_000 ether, 10, 10);
    _updateMinJobCvp(3_000 ether);

    assertEq(_globalMinKeeperCvp(), 1_000 ether);
    assertEq(_jobMinKeeperCvp(jobKey), 3_000 ether);

    vm.prank(a5);
    agent.disableKeeper(kid5);
    vm.prank(a4);
    agent.disableKeeper(kid4);
    vm.prank(a3);
    agent.initiateRedeem(kid3, 3_000 ether);

    assertEq(agent.getActiveKeepersLength(), 3);
    assertEq(_keeperCount(), 5);

    _setDifficultyExpectKid(10, 1);
    _setDifficultyExpectKid(11, 1);
    _setDifficultyExpectKid(12, 2);
    _setDifficultyExpectKid(13, 1);
    _setDifficultyExpectKid(14, 1);
    _setDifficultyExpectKid(15, 2);
  }

  function testRdAssignKeeper3Disabled1InsufficientDeposit() public {
    // release kid1
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);

    vm.prank(owner);
    _agent.setAgentParams(1_000 ether, 10, 10);
    _updateMinJobCvp(3_000 ether);

    assertEq(_globalMinKeeperCvp(), 1_000 ether);
    assertEq(_jobMinKeeperCvp(jobKey), 3_000 ether);

    vm.prank(a5);
    agent.initiateRedeem(kid5, 3_000 ether);
    vm.prank(a4);
    agent.disableKeeper(kid4);
    vm.prank(a3);
    agent.disableKeeper(kid3);
    vm.prank(a1);
    agent.initiateRedeem(kid1, 3_000 ether);

    assertEq(agent.getActiveKeepersLength(), 3);
    assertEq(_keeperCount(), 5);

    _setDifficultyExpectKid(10, 2);
    _setDifficultyExpectKid(11, 2);
    _setDifficultyExpectKid(12, 2);
    _setDifficultyExpectKid(13, 2);
    _setDifficultyExpectKid(14, 2);
    _setDifficultyExpectKid(15, 2);
    _setDifficultyExpectKid(16, 2);
  }

  function testRdReleaseAssignKeeperIfJobActivitySwitch() public {
    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(_jobIsActive(jobKey), true);

    vm.prank(alice);
    agent.setJobConfig(jobKey, false, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(0), 0);
    assertEq(_jobIsActive(jobKey), false);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdNotAssignKeeperIfUseOwnerBalanceAfter() public {
    vm.prank(alice);
    agent.setJobConfig(jobKey, false, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(0), 0);
    assertEq(agent.jobOwnerCredits(alice), 0);
    assertEq(_jobIsActive(jobKey), false);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdNotAssignKeeperIfInsufficientCredits() public {
    vm.prank(alice);
    agent.setJobConfig(jobKey, false, false, true, false);
    vm.prank(alice);
    agent.withdrawJobCredits(jobKey, alice, 0.95 ether);

    assertEq(_jobIsActive(jobKey), false);
    assertEq(_jobCredits(jobKey), 0.05 ether);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdSwitchCSJobToJobOwnerSufficient() public {
    vm.prank(alice);
    agent.depositJobOwnerCredits{ value: 0.1 ether }(alice);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdSwitchCSJobToJobOwnerInsufficient() public {
    vm.prank(alice);
    agent.depositJobOwnerCredits{ value: 0.09 ether }(alice);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
    assertEq(agent.jobOwnerCredits(alice), 0.09 ether);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdSwitchFromInsufficientCSJobOwnerToJobSufficient() public {
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
  }

  function testRdSwitchFromInsufficientCSJobOwnerToJobInsufficient() public {
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
  }

  function testRdSwitchFromSufficientCSJobOwnerToJobSufficient() public {
    vm.prank(alice);
    agent.depositJobOwnerCredits{value: 0.1 ether }(alice);
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
  }

  function testRdSwitchFromSufficientCSJobOwnerToJobInsufficient() public {
    vm.prank(alice);
    agent.depositJobOwnerCredits{value: 0.1 ether }(alice);
    vm.prank(alice);
    agent.withdrawJobCredits(jobKey, alice, 0.91 ether);
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 0);
  }

  function testRdNotChangedJobCredits() public {
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, false, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
  }

  function testRdNotChangedJobOwnerCredits() public {
    vm.prank(alice);
    agent.depositJobOwnerCredits{value: 0.1 ether }(alice);
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.getJobsAssignedToKeeperLength(1), 1);
  }

  function testRdJobOwnerCanReleaseKeeper() public {
    // release kid1
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice);
    _agent.releaseJob(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
  }

  function testRdAgentOwnerCanReleaseKeeper() public {
    // release kid1
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(_agent.owner());
    _agent.releaseJob(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 0);
  }

  function testRdOtherAddressCantRelease() public {
    // release kid1
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(bob);
    vm.expectRevert(PPAgentV2Based.OnlyKeeperAdminOrWorker.selector);
    _agent.releaseJob(jobKey);
  }

  function testRdAssignKeeperAlreadyAssigned() public {
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    bytes32[] memory list = new bytes32[](1);
    list[0] = jobKey;

    vm.expectRevert(abi.encodeWithSelector(PPAgentV2RandaoBased.JobHasKeeperAssigned.selector, 2));
    _agent.assignKeeper(list);
  }

  function testRdAssignKeeperCantAssign() public {
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice);
    _agent.releaseJob(jobKey);

    vm.prank(owner);
    rdConfig.jobMinCreditsFinney = 5000;
    agent.setRdConfig(rdConfig);

    bytes32[] memory list = new bytes32[](1);
    list[0] = jobKey;

    assertEq(_agent.shouldAssignKeeper(jobKey), false);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2RandaoBased.CantAssignKeeper.selector));
    _agent.assignKeeper(list);
  }

  function testRdAssignKeeperIntervalJob() public {
    vm.prank(alice);
    params.calldataSource = CALLDATA_SOURCE_SELECTOR;
    params.intervalSeconds = 180;
    resolver.resolverAddress = address(0);
    resolver.resolverCalldata = new bytes(0);

    (jobKey,jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });

    vm.prevrandao(bytes32(uint256(2)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice);
    _agent.releaseJob(jobKey);

    bytes32[] memory list = new bytes32[](1);
    list[0] = jobKey;

    assertEq(_jobLastExecutionAt(jobKey), 0);
    assertEq(_agent.shouldAssignKeeper(jobKey), true);
    vm.prank(alice);
    _agent.assignKeeper(list);

    assertEq(_jobLastExecutionAt(jobKey), 1600000000 + 8 hours);
  }

  function testRdAssignKeeperResolverJob() public {
    vm.prevrandao(bytes32(uint256(1)));
    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.getJobsAssignedToKeeperLength(2), 1);

    vm.prank(alice);
    _agent.releaseJob(jobKey);

    bytes32[] memory list = new bytes32[](1);
    list[0] = jobKey;

    assertEq(_agent.shouldAssignKeeper(jobKey), true);
    vm.prank(alice);
    _agent.assignKeeper(list);
  }

  function testRdJobTransferOwnerCSActiveBothInsufficient() public {
    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.jobOwnerCredits(alice), 0);
    assertEq(agent.jobOwnerCredits(bob), 0);
    assertEq(_jobIsActive(jobKey), true);

    vm.prank(alice);
    agent.initiateJobTransfer(jobKey, bob);
    vm.prank(bob);
    agent.acceptJobTransfer(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdJobTransferOwnerCSActiveSufficient2Insufficient() public {
    agent.depositJobOwnerCredits{ value: 10 ether }(alice);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(agent.jobOwnerCredits(alice), 10 ether);
    assertEq(agent.jobOwnerCredits(bob), 0);
    assertEq(_jobIsActive(jobKey), true);

    vm.prank(alice);
    agent.initiateJobTransfer(jobKey, bob);
    vm.prank(bob);
    agent.acceptJobTransfer(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdJobTransferOwnerCSActiveInsufficient2Sufficient() public {
    agent.depositJobOwnerCredits{ value: 10 ether }(bob);

    vm.prank(alice);
    agent.setJobConfig(jobKey, true, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.jobOwnerCredits(alice), 0);
    assertEq(agent.jobOwnerCredits(bob), 10 ether);
    assertEq(_jobIsActive(jobKey), true);

    vm.prank(alice);
    agent.initiateJobTransfer(jobKey, bob);
    vm.prank(bob);
    agent.acceptJobTransfer(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(_jobIsActive(jobKey), true);
  }

  function testRdJobTransferOwnerCSNotActiveInsufficientToSufficient() public {
    agent.depositJobOwnerCredits{ value: 10 ether }(bob);

    vm.prank(alice);
    agent.setJobConfig(jobKey, false, true, true, false);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(agent.jobOwnerCredits(alice), 0);
    assertEq(agent.jobOwnerCredits(bob), 10 ether);
    assertEq(_jobIsActive(jobKey), false);

    vm.prank(alice);
    agent.initiateJobTransfer(jobKey, bob);
    vm.prank(bob);
    agent.acceptJobTransfer(jobKey);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(_jobIsActive(jobKey), false);
  }

  function _setupVariableDeposits() internal {
    cvp.approve(address(agent), 50_000 ether);
    agent.stake(kid2, 5_000 ether);
    agent.stake(kid3, 10_000 ether);
    agent.stake(kid4, 15_000 ether);
    agent.stake(kid5, 20_000 ether);

    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 10_000 ether);
    assertEq(_stakeOf(kid3), 15_000 ether);
    assertEq(_stakeOf(kid4), 20_000 ether);
    assertEq(_stakeOf(kid5), 25_000 ether);
  }

  function _updateMinJobCvp(uint256 minJobCvp_) public {
    vm.prank(alice);
    agent.updateJob(jobKey, 100, 35, 10, minJobCvp_, 0);
    assertEq(_jobMinKeeperCvp(jobKey), minJobCvp_);
  }

  function testRdAssignKeeperSufficient() public {
    _setupVariableDeposits();

    _updateMinJobCvp(1_000 ether);
    assertEq(_globalMinKeeperCvp(), 3_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), kid1);
  }

  function testRdAssignKeeperInsufficientJobLevel() public {
    _setupVariableDeposits();

    _updateMinJobCvp(12_000 ether);
    assertEq(_globalMinKeeperCvp(), 3_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), kid3);
  }

  function testRdAssignKeeperInsufficientGlobalLevel() public {
    _setupVariableDeposits();
    vm.prank(owner);
    _agent.setAgentParams(21_000 ether, 10, 10);

    _updateMinJobCvp(12_000 ether);
    assertEq(_globalMinKeeperCvp(), 21_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), kid5);
  }

  function testRdAssignKeeperNobodyMatchesAscendingKeepers() public {
    _setupVariableDeposits();

    _updateMinJobCvp(30_000 ether);
    assertEq(_globalMinKeeperCvp(), 3_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), kid5);
  }

  function testRdAssignKeeperNobodyMatchesDescendingKeepers() public {
    cvp.approve(address(agent), 50_000 ether);
    agent.stake(kid1, 20_000 ether);
    agent.stake(kid2, 15_000 ether);
    agent.stake(kid3, 10_000 ether);
    agent.stake(kid4, 5_000 ether);

    assertEq(_stakeOf(kid1), 25_000 ether);
    assertEq(_stakeOf(kid2), 20_000 ether);
    assertEq(_stakeOf(kid3), 15_000 ether);
    assertEq(_stakeOf(kid4), 10_000 ether);
    assertEq(_stakeOf(kid5), 5_000 ether);

    _updateMinJobCvp(30_000 ether);
    assertEq(_globalMinKeeperCvp(), 3_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), kid1);
  }

  function testRdAssignKeeperNobodyMatchesDescendingNonOrdered() public {
    cvp.approve(address(agent), 50_000 ether);
    agent.stake(kid3, 20_000 ether);
    agent.stake(kid1, 15_000 ether);
    agent.stake(kid5, 10_000 ether);
    agent.stake(kid2, 5_000 ether);

    assertEq(_stakeOf(kid1), 20_000 ether);
    assertEq(_stakeOf(kid2), 10_000 ether);
    assertEq(_stakeOf(kid3), 25_000 ether);
    assertEq(_stakeOf(kid4), 5_000 ether);
    assertEq(_stakeOf(kid5), 15_000 ether);

    _updateMinJobCvp(30_000 ether);
    assertEq(_globalMinKeeperCvp(), 3_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), kid3);
  }

  function testRdAssignKeeperNoKeepersWithDeposit() public {
    vm.prank(owner);
    agent.releaseJob(jobKey);

    vm.prank(a1);
    agent.disableKeeper(kid1);
    vm.prank(a1);
    agent.initiateRedeem(kid1, 5_000 ether);

    vm.prank(a2);
    agent.disableKeeper(kid2);
    vm.prank(a2);
    agent.initiateRedeem(kid2, 4_000 ether);

    vm.prank(a3);
    agent.disableKeeper(kid3);
    vm.prank(a3);
    agent.initiateRedeem(kid3, 5_000 ether);

    vm.prank(a4);
    agent.disableKeeper(kid4);
    vm.prank(a4);
    agent.initiateRedeem(kid4, 4_000 ether);

    vm.prank(a5);
    agent.disableKeeper(kid5);
    vm.prank(a5);
    agent.initiateRedeem(kid5, 5_000 ether);

    assertEq(_stakeOf(kid1), 0 ether);
    assertEq(_stakeOf(kid2), 1_000 ether);
    assertEq(_stakeOf(kid3), 0 ether);
    assertEq(_stakeOf(kid4), 1_000 ether);
    assertEq(_stakeOf(kid5), 0 ether);

    _updateMinJobCvp(30_000 ether);
    assertEq(_globalMinKeeperCvp(), 3_000 ether);

    _agent.assignNextKeeper(jobKey);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
  }
}
