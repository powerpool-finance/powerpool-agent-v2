// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2VRF.sol";
import "../TestHelperRandao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../mocks/MockCompensationTracker.sol";
import "../mocks/MockVRFCoordinator.sol";
import "../../contracts/VRFAgentManager.sol";

contract VRFTest is AbstractTestHelper {
  ICounter internal job;

  OnlySelectorTestJob internal counter;
  MockVRFCoordinator internal coordinator;
  VRFAgentConsumer internal consumer;

  bytes32 internal jobKey;
  uint256 internal jobId;
  uint256 internal defaultFlags;
  uint256 internal accrueFlags;
  uint256 internal kid1;
  uint256 internal kid2;
  uint256 internal kid3;
  uint256 internal latestKeeperStub;

  PPAgentV2VRF internal agent;

  function _agentViewer() internal override view returns(IPPAgentV2Viewer) {
    return IPPAgentV2Viewer(address(agent));
  }

  function _rdGlobalMaxCvpStake() internal view returns (uint256) {
    IPPAgentV2RandaoViewer.RandaoConfig memory rdConfig = agent.getRdConfig();
    return uint256(rdConfig.agentMaxCvpStake) * 1 ether;
  }

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
    IPPAgentV2RandaoViewer.RandaoConfig memory rdConfig = IPPAgentV2RandaoViewer.RandaoConfig({
      slashingEpochBlocks: 10,
      period1: 15,
      period2: 30,
      slashingFeeFixedCVP: 50,
      slashingFeeBps: 300,
      jobMinCreditsFinney: 1,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 10_000,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8,
      jobFixedRewardFinney: 30
    });

    coordinator = new MockVRFCoordinator();
    agent = new PPAgentV2VRF(address(cvp));
    consumer = new VRFAgentConsumer(address(agent));
    counter = new OnlySelectorTestJob(address(agent));
    agent.initializeRandao(owner, 3_000 ether, 3 days, rdConfig);
    consumer.setVrfConfig(address(coordinator), bytes32(0), uint64(0), uint16(0), uint32(0), 0);

    vm.prank(owner);
    agent.setAgentParams(1, 10, 1e4);
    vm.prank(owner);
    agent.setVRFConsumer(address(consumer));

    {
      cvp.transfer(keeperAdmin, 15_000 ether);

      vm.startPrank(keeperAdmin);
      cvp.approve(address(agent), 15_000 ether);
      kid1 = agent.registerAsKeeper(alice, 5_000 ether);
      kid2 = agent.registerAsKeeper(keeperWorker, 5_000 ether);
      kid3 = agent.registerAsKeeper(bob, 5_000 ether);

      vm.warp(block.timestamp + 8 hours);

      agent.finalizeKeeperActivation(1);
      agent.finalizeKeeperActivation(2);
      agent.finalizeKeeperActivation(3);
      vm.stopPrank();

      assertEq(counter.current(), 0);
    }
  }

  function _setupJob(address job_, bytes4 selector_, bool assertSelector_) internal {
    PPAgentV2.Resolver memory resolver = IPPAgentV2Viewer.Resolver({
      resolverAddress: address(0),
      resolverCalldata: bytes("")
    });
    IPPAgentV2JobOwner.RegisterJobParams memory params = IPPAgentV2JobOwner.RegisterJobParams({
      jobAddress: job_,
      jobSelector: selector_,
      maxBaseFeeGwei: 100,
      rewardPct: 35,
      fixedReward: 10,
      useJobOwnerCredits: false,
      assertResolverSelector: assertSelector_,
      jobMinCvp: 0,

      // For interval jobs
      calldataSource: CALLDATA_SOURCE_SELECTOR,
      intervalSeconds: 15
    });
    vm.prank(alice);
    vm.deal(alice, 1 ether);
    vm.roll(10);
    (jobKey, jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function testVrfNumbersShouldBeSet() public {
    job = new OnlySelectorTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), OnlySelectorTestJob.increment.selector, true);
    assertEq(coordinator.lastRequestId(), 1);
    assertEq(consumer.pendingRequestId(), coordinator.lastRequestId());
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    assertEq(consumer.getPseudoRandom(), uint256(blockhash(block.number - 1)));
    coordinator.callFulfill();
    assertNotEq(consumer.getPseudoRandom(), uint256(blockhash(block.number - 1)));
    assertEq(consumer.pendingRequestId(), 0);
    assertEq(coordinator.lastRequestId(), 1);
    assertEq(consumer.lastVrfFulfillAt(), 0);

    vm.prank(keeperWorker, keeperWorker);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );
    assertEq(coordinator.lastRequestId(), 2);
    assertEq(consumer.pendingRequestId(), coordinator.lastRequestId());

    consumer.setVrfConfig(address(coordinator), bytes32(0), uint64(0), uint16(0), uint32(0), 30);

    vm.roll(25);
    uint256 fulfillTimestamp = block.timestamp + 15;
    vm.warp(fulfillTimestamp);
    coordinator.callFulfill();
    assertEq(consumer.pendingRequestId(), 0);
    assertEq(consumer.lastVrfFulfillAt(), fulfillTimestamp);

    vm.roll(30);
    vm.warp(fulfillTimestamp + 15);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(consumer.isReadyForRequest(), false);
    vm.prank(keeperWorker, keeperWorker);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );

    assertEq(consumer.pendingRequestId(), 0);
    assertEq(coordinator.lastRequestId(), 2);

    vm.roll(40);
    vm.warp(fulfillTimestamp + 31);
    assertEq(agent.jobNextKeeperId(jobKey), 3);
    assertEq(consumer.isReadyForRequest(), true);
    vm.prank(bob, bob);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid3,
      new bytes(0)
    );

    assertEq(consumer.pendingRequestId(), 3);
    assertEq(coordinator.lastRequestId(), 3);

    uint256 timestampBefore = block.timestamp;
    assertEq(consumer.isReadyForRequest(), false);
    vm.roll(296);
    assertEq(block.number - consumer.lastVrfRequestAtBlock() >= 256, true);
    assertEq(consumer.isReadyForRequest(), true);
    assertEq(timestampBefore, block.timestamp);
  }

  function testAutoDepositJobShouldDoTheThing() public {
    _setupJob(address(coordinator), coordinator.callFulfill.selector, true);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    consumer.setVrfConfig(address(coordinator), bytes32(0), uint64(0), uint16(0), uint32(0), 30);
    (, , uint256 feeTotal, , ) = agent.getConfig();
    assertEq(feeTotal, 1e16);

    VRFAgentManager agentManager = new VRFAgentManager(agent);
    agentManager.setVrfConfig(jobKey, 1.5e16, 1e17);
    agentManager.setAutoDepositConfig(bytes32(0), 1 ether, 2 ether);
    vm.prank(owner);
    agent.transferOwnership(address(agentManager));

    (, , feeTotal, , ) = agent.getConfig();
    assertEq(feeTotal, 1e16);

    (
      bytes32 autoDepositJobKey,
      uint256 autoDepositJobId
    ) = agentManager.registerAutoDepositJob{value: 1e16}(100, 35, 10, 0, false);

    assertNotEq(agentManager.autoDepositJobKey(), bytes32(0));
    assertEq(agentManager.autoDepositJobKey(), autoDepositJobKey);

    vm.prank(keeperWorker, keeperWorker);
    vm.roll(20);
    uint256 fulfillTimestamp = block.timestamp;
    _callExecuteHelper(
      agent,
      address(coordinator),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );
    assertEq(consumer.lastVrfFulfillAt(), fulfillTimestamp);

    (
      uint256 amountToDeposit,
      uint256 vrfAmountIn,
      uint256 autoDepositAmountIn
    ) = agentManager.getBalanceRequiredToDeposit();
    assertEq(amountToDeposit, 0);
    assertEq(vrfAmountIn, 0);
    assertEq(autoDepositAmountIn, 0);

    (bool isCallAutoDeposit, bytes memory autoDepositCalldata) = agentManager.vrfAutoDepositJobsResolver();
    assertEq(isCallAutoDeposit, false);

    agentManager.setAutoDepositConfig(autoDepositJobKey, 1e16, 1e17);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertApproxEqAbs(amountToDeposit, 1.01e16, 1);
    assertEq(vrfAmountIn, 0);
    assertApproxEqAbs(autoDepositAmountIn, 1.01e16, 1);
    (isCallAutoDeposit, autoDepositCalldata) = agentManager.vrfAutoDepositJobsResolver();
    assertEq(isCallAutoDeposit, true);

    uint256 autoDepositBalanceBefore = agentManager.getAutoDepositJobBalance();

    assertEq(agent.jobNextKeeperId(autoDepositJobKey), 2);
    vm.prank(keeperWorker, keeperWorker);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(agentManager),
      autoDepositJobId,
      defaultFlags,
      kid2,
      autoDepositCalldata
    );

    uint256 autoDepositBalanceAfter = agentManager.getAutoDepositJobBalance();
    assertGt(autoDepositBalanceAfter, autoDepositBalanceBefore);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertEq(amountToDeposit, 0);
    assertEq(vrfAmountIn, 0);
    assertEq(autoDepositAmountIn, 0);

    (isCallAutoDeposit, autoDepositCalldata) = agentManager.vrfAutoDepositJobsResolver();
    assertEq(isCallAutoDeposit, false);

    (address jobOwner, , , , ,) = agent.getJob(jobKey);
    assertEq(jobOwner, alice);
    vm.startPrank(alice);
    agent.withdrawJobCredits(jobKey, payable(alice), agentManager.getVrfFullfillJobBalance());
    vm.stopPrank();
    assertEq(agentManager.getVrfFullfillJobBalance(), 0);

    agent.depositJobCredits{value: 100 ether}(autoDepositJobKey);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertApproxEqAbs(amountToDeposit, 8.5e16, 1);
    assertApproxEqAbs(vrfAmountIn, 8.5e16, 1);
    assertEq(autoDepositAmountIn, 0);

    agentManager.setVrfConfig(jobKey, 1 ether, 2 ether);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertApproxEqAbs(amountToDeposit, 1 ether, 1);
    assertApproxEqAbs(vrfAmountIn, 1 ether, 1);
    assertEq(autoDepositAmountIn, 0);

    uint256 vrfJobBalanceBefore = agentManager.getVrfFullfillJobBalance();
    assertEq(agent.jobNextKeeperId(autoDepositJobKey), 1);
    vm.prank(alice, alice);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(agentManager),
      autoDepositJobId,
      defaultFlags,
      kid1,
      autoDepositCalldata
    );
    uint256 vrfJobBalanceAfter = agentManager.getVrfFullfillJobBalance();
    assertGt(vrfJobBalanceAfter, vrfJobBalanceBefore);
  }
}
