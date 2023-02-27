// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";
import "../jobs/SimpleCalldataTestJob.sol";
import "../jobs/SimpleCustomizableCalldataTestJob.sol";

contract RandaoExecuteResolverTest is TestHelperRandao {
  ICounter internal job;

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
    PPAgentV2Randao.RandaoConfig memory rdConfig = PPAgentV2Randao.RandaoConfig({
      slashingEpochBlocks: 10,
      period1: 15,
      period2: 30,
      slashingFeeFixedCVP: 50,
      slashingFeeBps: 300,
      jobMinCreditsFinney: 100,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 1,
      stakeDivisor: 50_000_000
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

    // first execution
    vm.difficulty(41);
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);

    assertEq(job.current(), 1);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    // time: 11, block: 43. Slashing not initiated
    vm.roll(62);
    vm.warp(1600000000 + 11);
    assertEq(block.number, 62);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    vm.difficulty(42);
    (ok, cd) = job.myResolver("myPass");

    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.SlashingNotInitiated.selector));
    _executeJob(1, cd);

    // time: 11, block: 43. Initiate slashing
    assertEq(agent.jobReservedSlasherId(jobKey), 0);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 0);

    vm.prank(bob, bob);
    agent.initiateSlashing(address(job), jobId, kid3, false, cd);
    assertEq(agent.jobReservedSlasherId(jobKey), kid3);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 1600000026);

    // time: 26, block: 63. Too early for slashing
    vm.expectRevert(abi.encodeWithSelector(
      PPAgentV2Randao.TooEarlyForSlashing.selector, 1600000011, 1600000026
    ));
    _executeJob(kid3, cd);

    vm.roll(73);
    vm.warp(1600000000 + 26);
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
    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 5_000 ether);

    vm.prank(bob, bob);
    (ok, cd) = job.myResolver("myPass");
    vm.difficulty(41);

    _executeJob(kid3, cd);

    // 50 + 5000 * 0.03 = 200
    assertEq(_stakeOf(kid3), 5_200 ether);
    assertEq(_stakeOf(kid2), 4_800 ether);
  }

  function testRdResolverSlashingKeeperCanExecuteAfterInitiated() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.difficulty(41);
    vm.roll(42);
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);
    assertEq(job.current(), 1);

    // resolver false
    vm.prank(alice, alice);
    agent.initiateSlashing(address(job), jobId, kid1, false, cd);

    // time: 11, block: 43. Slashing not initiated
    vm.roll(63);
    vm.warp(1600000000 + 11);
    assertEq(job.current(), 1);
    assertEq(block.number, 63);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(agent.jobReservedSlasherId(jobKey), 1);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 1600000015);

    _executeJob(2, cd);

    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 5_000 ether);
    assertEq(_stakeOf(kid3), 5_000 ether);
    assertEq(job.current(), 2);
    assertEq(agent.jobReservedSlasherId(jobKey), 0);
    assertEq(agent.jobSlashingPossibleAfter(jobKey), 0);
  }

  function testRdResolverSlashingResolverReject() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.difficulty(41);
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);

    SimpleCustomizableCalldataTestJob(address(job)).setResolverReturnFalse(true);

    // resolver false
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.JobCheckResolverReturnedFalse.selector));
    vm.prank(bob, bob);
    agent.initiateSlashing(address(job), jobId, kid3, true, cd);

    SimpleCustomizableCalldataTestJob(address(job)).setResolverReturnFalse(false);
    SimpleCustomizableCalldataTestJob(address(job)).setRevertResolver(true);

    // resolver revert
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.JobCheckResolverError.selector,
      abi.encodeWithSelector(0x08c379a0, "forced resolver revert")
      ));
    vm.prank(bob, bob);
    agent.initiateSlashing(address(job), jobId, kid3, true, cd);
  }

  function testRdResolverSlashingExecutionRevert() public {
    job = new SimpleCustomizableCalldataTestJob(address(agent));
    _setupJob(address(job), SimpleCalldataTestJob.increment.selector, true);
    // first execution
    vm.difficulty(41);
    (bool ok, bytes memory cd) = job.myResolver("myPass");
    assertEq(ok, true);
    _executeJob(3, cd);
    assertEq(job.current(), 1);

    SimpleCustomizableCalldataTestJob(address(job)).setRevertExecution(true);
    assertEq(agent.getCurrentSlasherId(jobKey), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    // resolver false
    vm.expectRevert(
      abi.encodeWithSelector(PPAgentV2Randao.JobCheckCanNotBeExecuted.selector,
        abi.encodeWithSelector(0x08c379a0, "forced execution revert")
      )
    );
    vm.prank(bob, bob);
    agent.initiateSlashing(address(job), jobId, kid3, false, cd);
    assertEq(job.current(), 1);
  }
}
