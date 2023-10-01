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

contract RandaoExecuteResolverTest is TestHelperRandao {
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

  function testRdResolverSlashingOk() public {
    job = new SimpleCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);

    assertEq(agent.jobNextKeeperId(jobKey), 3);

    (, uint256 pendingWithdrawalTimeoutSeconds_, , uint256 feePpm_, ) = agent.getConfig();
    vm.prank(owner);
    agent.setAgentParams(5_000 ether, pendingWithdrawalTimeoutSeconds_, feePpm_);

    // first execution
    vm.prevrandao(bytes32(uint256(41)));
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);

    assertEq(job.current(), 1);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    // time: 11, block: 43. Slashing not initiated
    vm.roll(62);
    vm.warp(1600000000 + 11 + 8 hours);
    assertEq(block.number, 62);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    vm.prevrandao(bytes32(uint256(42)));
    (ok, cd) = job.myResolver("myPass");

    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.SlashingNotInitiated.selector));
    _executeJob(1, cd);

    // time: 11, block: 43. Initiate slashing
    assertEq(agent.jobReservedSlasherId(jobKey), 0);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 0);

    vm.prank(bob, bob);
    agent.initiateKeeperSlashing(address(job), jobId, kid3, false, cd);
    assertEq(agent.jobReservedSlasherId(jobKey), kid3);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 1600000026 + 8 hours);

    // time: 26, block: 63. Too early for slashing
    vm.expectRevert(abi.encodeWithSelector(
      PPAgentV2Randao.TooEarlyForSlashing.selector, 1600000011 + 8 hours, 1600000026 + 8 hours
    ));
    _executeJob(kid3, cd);

    vm.roll(73);
    vm.warp(1600000000 + 26 + 8 hours);
    assertEq(block.number, 73);
    assertEq(agent.getCurrentSlasherId(jobKey), 1);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.jobReservedSlasherId(jobKey), 3);

    // kid1 attempt should fail
    vm.expectRevert(abi.encodeWithSelector(
        PPAgentV2Randao.OnlyReservedSlasher.selector, 3
      ));
    _executeJob(kid1, cd);

    // time: 26, block: 63. Should allow slashing

    assertEq(_keeperIsActive(kid1), true);
    assertEq(_keeperIsActive(kid2), true);
    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 5_000 ether);

    vm.prank(bob, bob);
    (ok, cd) = job.myResolver("myPass");
    vm.prevrandao(bytes32(uint256(41)));

    _executeJob(kid3, cd);

    // 50 + 5000 * 0.03 = 200
    assertEq(_keeperIsActive(kid1), true);
    assertEq(_keeperIsActive(kid2), false);
    assertEq(_stakeOf(kid3), 5_050.3 ether);
    assertEq(_stakeOf(kid2), 4_949.7 ether);
  }

  function testRdResolverSlashingKeeperCanExecuteAfterInitiated() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.prevrandao(bytes32(uint256(41)));
    vm.roll(42);
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);
    assertEq(job.current(), 1);

    // resolver false
    vm.prank(alice, alice);
    agent.initiateKeeperSlashing(address(job), jobId, kid1, false, cd);

    // time: 11, block: 43. Slashing not initiated
    vm.roll(63);
    vm.warp(1600000000 + 11 + 8 hours);
    assertEq(job.current(), 1);
    assertEq(block.number, 63);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.jobReservedSlasherId(jobKey), 1);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 1600000015 + 8 hours);

    _executeJob(2, cd);

    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 5_000 ether);
    assertEq(_stakeOf(kid3), 5_000 ether);
    assertEq(job.current(), 2);
    assertEq(agent.jobReservedSlasherId(jobKey), 0);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 0);
  }

  function testRdResolverSelectorNotMatchError() public {
    job = new SimpleCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment2.selector, true);

    (, bytes memory cd) = job.myResolver("myPass");

    vm.roll(42);
    vm.prank(alice);
    vm.expectRevert(PPAgentV2.SelectorCheckFailed.selector);
    agent.initiateKeeperSlashing(address(job), jobId, kid1, false, cd);
  }

  function testRdResolverSelectorSlashingReentrancyLock() public {
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
      PPAgentV2Randao.JobCheckCanNotBeExecuted.selector,
      abi.encodePacked(PPAgentV2.ExecutionReentrancyLocked.selector)
    ));
    agent.initiateKeeperSlashing(address(topupJob), jobId, kid1, false, cd);
  }

  function testRdResolverSelectorMatchCheckIgnored() public {
    job = new SimpleCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment2.selector, false);

    (, bytes memory cd) = job.myResolver("myPass");

    vm.roll(42);
    vm.prank(alice);
    agent.initiateKeeperSlashing(address(job), jobId, kid1, false, cd);
  }

  function testRdResolverSlashingResolverReject() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.prevrandao(bytes32(uint256(41)));
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);

    SimpleCustomizableCalldataTestJob(address(job)).setResolverReturnFalse(true);

    // resolver false
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.JobCheckResolverReturnedFalse.selector));
    vm.prank(bob, bob);
    agent.initiateKeeperSlashing(address(job), jobId, kid3, true, cd);

    SimpleCustomizableCalldataTestJob(address(job)).setResolverReturnFalse(false);
    SimpleCustomizableCalldataTestJob(address(job)).setRevertResolver(true);

    // resolver revert
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.JobCheckCanNotBeExecuted.selector,
      abi.encodeWithSelector(0x08c379a0, "forced resolver revert")
      ));
    vm.prank(bob, bob);
    agent.initiateKeeperSlashing(address(job), jobId, kid3, true, cd);
  }

  function testRdResolverExecutionRevertSlashingNotInitiated() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.prevrandao(bytes32(uint256(41)));
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);
    assertEq(job.current(), 1);

    SimpleCustomizableCalldataTestJob(address(job)).setRevertExecution(true);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(SimpleCustomizableCalldataTestJob(address(job)).revertResolver(), false);
    assertEq(SimpleCustomizableCalldataTestJob(address(job)).revertExecution(), true);

    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.SlashingNotInitiatedExecutionReverted.selector));
    _executeJob(2, cd);
  }

  function testRdResolverExecutionRevertSlashingInitiated() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.prevrandao(bytes32(uint256(41)));
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);
    assertEq(job.current(), 1);

    SimpleCustomizableCalldataTestJob(address(job)).setRevertExecution(true);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(SimpleCustomizableCalldataTestJob(address(job)).revertResolver(), false);
    assertEq(SimpleCustomizableCalldataTestJob(address(job)).revertExecution(), true);

    // initialize slashing
    vm.prank(bob, bob);
    agent.initiateKeeperSlashing(address(job), jobId, kid3, true, cd);
    assertEq(agent.jobReservedSlasherId(jobKey), kid3);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 1600000015 + 8 hours);

    // resolver false
    vm.expectEmit(true, true, false, true, address(agent));
    emit JobKeeperChanged(jobKey, 2, 0);

    uint256 workerBalanceBefore = keeperWorker.balance;
    vm.prevrandao(bytes32(uint256(52)));
    _executeJob(2, cd);
    assertEq(agent.jobNextKeeperId(jobKey), 0);
    assertEq(job.current(), 1);
    assertEq(agent.jobReservedSlasherId(jobKey), 0);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 0);
    assertApproxEqAbs(keeperWorker.balance - workerBalanceBefore, 0.00355945 ether, 0.00005 ether);
  }
}
