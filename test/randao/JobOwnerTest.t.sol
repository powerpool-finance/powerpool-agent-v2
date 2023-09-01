// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";
import "../jobs/SimpleCalldataTestJob.sol";
import "../jobs/SimpleCustomizableCalldataTestJob.sol";
import "../jobs/JobWithdrawTestJob.sol";

contract RandaoJobOwnerTest is TestHelperRandao {
  ICounter internal job;

  OnlySelectorTestJob internal counter;

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
      jobFixedReward: 3
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
      resolverAddress: job_,
      resolverCalldata: abi.encodeWithSelector(SimpleCustomizableCalldataTestJob.myResolver.selector, "myPass")
    });
    IPPAgentV2JobOwner.RegisterJobParams memory params = IPPAgentV2JobOwner.RegisterJobParams({
      jobAddress: job_,
      jobSelector: selector_,
      maxBaseFeeGwei: 100,
      rewardPct: 35,
      fixedReward: 10,
      useJobOwnerCredits: true,
      assertResolverSelector: assertSelector_,
      jobMinCvp: 0,

      // For interval jobs
      calldataSource: CALLDATA_SOURCE_RESOLVER,
      intervalSeconds: 0
    });
    vm.prank(alice);
    vm.deal(alice, 1 ether);
    (jobKey,jobId) = agent.registerJob{ value: 0 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function testJobOwnerDepositAndAssignKeepersOk() public {
    job = new SimpleCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(_jobOwner(jobKey), alice);

    bytes32[] memory jobKeys = new bytes32[](1);
    jobKeys[0] = jobKey;

    vm.prank(alice);
    agent.depositJobOwnerCreditsAndAssignKeepers{ value: 1 ether }(alice, jobKeys);
    assertEq(agent.jobNextKeeperId(jobKey), 3);
  }

  function testJobOwnerDepositAndAssignKeepersNonJobOwner() public {
    job = new SimpleCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(_jobOwner(jobKey), alice);

    bytes32[] memory jobKeys = new bytes32[](1);
    jobKeys[0] = jobKey;

    vm.deal(bob, 2 ether);
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(PPAgentV2.OnlyJobOwner.selector)
    );
    agent.depositJobOwnerCreditsAndAssignKeepers{ value: 1 ether }(alice, jobKeys);

    assertEq(agent.jobNextKeeperId(jobKey), 0);
  }
}
