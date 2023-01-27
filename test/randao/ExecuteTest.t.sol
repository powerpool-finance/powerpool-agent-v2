// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";

contract RandaoExecuteSelectorThreeKeepersTest is TestHelperRandao {
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
      intervalJobSlashingDelaySeconds: 15,
      slashingFeeFixedCVP: 50,
      slashingFeeBps: 300
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

    IPPAgentV2Viewer.Resolver memory resolver = IPPAgentV2Viewer.Resolver({
      resolverAddress: address(counter),
      resolverCalldata: new bytes(0)
    });
    IPPAgentV2JobOwner.RegisterJobParams memory params = IPPAgentV2JobOwner.RegisterJobParams({
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

  function testRdExecWithSelector1() public {
    bytes32[] memory jobKeys = agent.getKeeperLocksByJob(kid1);
    assertEq(jobKeys.length, 0);

    jobKeys = agent.getKeeperLocksByJob(kid2);
    assertEq(jobKeys.length, 1);
    assertEq(jobKeys[0], jobKey);

    vm.prank(keeperWorker, keeperWorker);
    vm.difficulty(41);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );

    {
      jobKeys = agent.getKeeperLocksByJob(kid1);
      assertEq(jobKeys.length, 1);
      assertEq(jobKeys[0], jobKey);

      jobKeys = agent.getKeeperLocksByJob(kid2);
      assertEq(jobKeys.length, 0);
    }

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(counter.current(), 1);
  }

  function testRdExecWithSelector2() public {
    vm.prank(keeperWorker, keeperWorker);
    vm.difficulty(42);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );

    assertEq(agent.jobNextKeeperId(jobKey), 2);
    assertEq(counter.current(), 1);
  }

  function testRdExecWrongKeeper() public {
    // Problem: 1st execution could be slashed
    assertEq(_keeperCount(), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    vm.difficulty(40);
    vm.expectRevert(
      abi.encodeWithSelector(
        PPAgentV2Randao.OnlyNextKeeper.selector, 2, 0, 10, 15, 1600000000
      )
    );
    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );
  }

  function testRdCantRedeem() public {
    assertEq(_keeperCount(), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    bytes32[] memory lockedJobs = agent.getKeeperLocksByJob(kid2);
    assertEq(lockedJobs.length, 1);
    assertEq(lockedJobs[0], jobKey);

    // the first attempt should fail
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.KeeperIsAssignedToJobs.selector, 1));
    vm.prank(keeperAdmin, keeperAdmin);
    agent.initiateRedeem(kid2, 5_000 ether);

    // execute to reassign another keeper
    vm.difficulty(41);
    vm.prank(keeperWorker, keeperWorker);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );

    // the second attempt should succeed
    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(_stakeOf(kid2), 5_000 ether);

    vm.prank(keeperAdmin, keeperAdmin);
    agent.initiateRedeem(kid2, 5_000 ether);
    lockedJobs = agent.getKeeperLocksByJob(kid2);
    assertEq(lockedJobs.length, 0);
    assertEq(_stakeOf(kid2), 0);
  }

  function testRdCanBeSlashed() public {
    // first execution
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    vm.prank(keeperWorker, keeperWorker);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );

    // time: 11, block: 43. kid1 is not the keeper assigned to the task, slashing is not started yet.
    vm.roll(52);
    vm.warp(1600000000 + 11);
    assertEq(block.number, 52);
    assertEq(_jobNextExecutionAt(jobKey), 1600000010);
    assertEq(agent.getCurrentSlasherId(), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    vm.prank(alice, alice);
    vm.difficulty(42);
    vm.expectRevert(
      abi.encodeWithSelector(
        PPAgentV2Randao.OnlyNextKeeper.selector, 2, 1600000000, 10, 15, 1600000011
      )
    );
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    // time: 26, block: 63. Should allow slashing
    vm.roll(63);
    vm.warp(1600000000 + 26);
    assertEq(block.number, 63);
    assertEq(_jobNextExecutionAt(jobKey), 1600000010);
    assertEq(agent.getCurrentSlasherId(), 1);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    // kid3 attempt should fail
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.OnlyCurrentSlasher.selector, 1));
    vm.prank(bob, bob);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid3,
      new bytes(0)
    );

    assertEq(_stakeOf(kid1), 5_000 ether);
    assertEq(_stakeOf(kid2), 5_000 ether);

    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(counter),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    // 50 + 5000 * 0.03 = 200
    assertEq(_stakeOf(kid1), 5_200 ether);
    assertEq(_stakeOf(kid2), 4_800 ether);
  }
}
