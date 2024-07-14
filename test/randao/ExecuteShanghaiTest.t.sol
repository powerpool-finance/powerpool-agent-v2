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

contract ExecuteShanghaiTest is TestHelperRandao {
  ICounter internal job;

  event Execute(bytes32 indexed jobKey, address indexed job, bool indexed success, uint256 gasUsed, uint256 baseFee, uint256 gasPrice, uint256 compensation);
  event JobKeeperChanged(bytes32 indexed jobKey, uint256 indexed keeperFrom, uint256 indexed keeperTo);
  event ExecutionReverted(
    bytes32 indexed jobKey,
    uint256 indexed assignedKeeperId,
    uint256 indexed actualKeeperId,
    bytes executionReturndata,
    uint256 compensation
  );

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
      jobFixedRewardFinney: 30
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
      useJobOwnerCredits: false,
      assertResolverSelector: assertSelector_,
      jobMinCvp: 0,

      // For interval jobs
      calldataSource: CALLDATA_SOURCE_RESOLVER,
      intervalSeconds: 0
    });
    vm.prank(alice);
    vm.deal(alice, 1 ether);
    (jobKey,jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function _executeJob(uint256 kid, bytes memory cd) internal {

    if (kid == 1) {
      vm.prank(alice, alice);
    } else if (kid == 2) {
      vm.prank(keeperWorker, keeperWorker);
    } else if (kid == 3) {
      vm.prank(bob, bob);
    } else {
      revert("invalid id");
    }
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid,
      cd
    );
  }

  function testRdResolverSelectorSlashingReentrancyLockInShanghai() public {
    JobWithdrawTestJob topupJob = new JobWithdrawTestJob(address(agent));
    job = new SimpleCalldataTestJob(address(agent));
    _setupJob(address(topupJob), JobWithdrawTestJob.execute.selector, true);

    (, bytes memory cd) = topupJob.myResolver(jobKey);

    vm.prank(alice);
    agent.initiateJobTransfer(jobKey, address(topupJob));
    topupJob.acceptJobTransfer(jobKey);

    vm.roll(42);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(
      PPAgentV2Based.JobCheckCanNotBeExecuted.selector,
      abi.encodePacked(PPAgentV2Based.ExecutionReentrancyLocked.selector)
    ));
    agent.initiateKeeperSlashing(address(topupJob), jobId, kid1, false, cd);
  }
}
