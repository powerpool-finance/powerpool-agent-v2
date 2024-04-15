// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2VRF.sol";
import "../TestHelperRandao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../mocks/MockCompensationTracker.sol";
import "../mocks/MockVRFCoordinator.sol";

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
      jobMinCreditsFinney: 100,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 10_000,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8,
      jobFixedRewardFinney: 3
    });

    coordinator = new MockVRFCoordinator();
    agent = new PPAgentV2VRF(address(cvp));
    consumer = new VRFAgentConsumer(address(agent));
    counter = new OnlySelectorTestJob(address(agent));
    agent.initializeRandao(owner, 3_000 ether, 3 days, rdConfig);
    consumer.setVrfConfig(address(coordinator), bytes32(0), uint64(0), uint16(0), uint32(0), 0);

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
    (jobKey,jobId) = agent.registerJob{ value: 1 ether }({
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
    assertEq(agent.jobNextKeeperId(jobKey), 3);

    assertEq(consumer.getPseudoRandom(), uint256(blockhash(block.number - 1)));
    coordinator.callFulfill();
    assertNotEq(consumer.getPseudoRandom(), uint256(blockhash(block.number - 1)));
    assertEq(consumer.pendingRequestId(), 0);
    assertEq(coordinator.lastRequestId(), 1);
    assertEq(consumer.lastVrfRequestAt(), 0);

    vm.prank(bob, bob);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid3,
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
    assertEq(consumer.lastVrfRequestAt(), fulfillTimestamp);

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
    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(consumer.isReadyForRequest(), true);
    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    assertEq(consumer.pendingRequestId(), 3);
    assertEq(coordinator.lastRequestId(), 3);
  }
}
