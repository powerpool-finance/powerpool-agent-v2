// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";
import "../jobs/SimpleCalldataTestJob.sol";

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
      intervalJobSlashingDelaySeconds: 15,
      nonIntervalJobSlashingValiditySeconds: 30,
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
  }

  function _setupJob(address job_, bytes4 selector_, bool assertSelector_) internal {
    PPAgentV2.Resolver memory resolver = IPPAgentV2Viewer.Resolver({
      resolverAddress: job_,
      resolverCalldata: abi.encode("myPass")
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

  function testRdResolverSlashing() public {
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
    vm.roll(52);
    vm.warp(1600000000 + 11);
    assertEq(block.number, 52);
    assertEq(agent.getCurrentSlasherId(), 3);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    vm.difficulty(42);
    (ok, cd) = job.myResolver("myPass");

    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.SlashingNotInitiated.selector));
    _executeJob(1, cd);

    // time: 11, block: 43. Initiate slashing
    vm.prank(bob, bob);
    agent.initiateSlashing(address(counter), );
    return;

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
