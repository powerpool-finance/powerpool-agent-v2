// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2RandaoWithGasTracking.sol";
import "../TestHelperRandao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../mocks/MockCompensationTracker.sol";

contract RandaoGasUsedTest is TestHelperRandao {
  ICounter internal job;

  OnlySelectorTestJob internal counter;
  MockCompensationTracker internal tracker;

  bytes32 internal jobKey;
  uint256 internal jobId;
  uint256 internal defaultFlags;
  uint256 internal accrueFlags;
  uint256 internal kid1;
  uint256 internal kid2;
  uint256 internal kid3;
  uint256 internal latestKeeperStub;

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
    tracker = new MockCompensationTracker();
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
      keeperActivationTimeoutHours: 8
    });

    agent = new PPAgentV2RandaoWithGasTracking(address(tracker), address(cvp));
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
    (jobKey,jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function testGasTrackingShouldBeNotified() public {
    job = new OnlySelectorTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), OnlySelectorTestJob.increment.selector, true);
    assertEq(agent.jobNextKeeperId(jobKey), 1);

    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    assertGt(tracker.accumulatedGasUsed(kid1), 0);
  }

  function testGasTrackingCanSafelyRevert() public {
    job = new OnlySelectorTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), OnlySelectorTestJob.increment.selector, true);
    assertEq(agent.jobNextKeeperId(jobKey), 1);

    tracker.setDoRevert(true);

    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    assertEq(tracker.accumulatedGasUsed(kid1), 0);
  }
}
