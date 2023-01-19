// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Randao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/JobTopupTestJob.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../TestHelperRandao.sol";

contract RandaoExecuteSelectorTest is TestHelperRandao {
  event Execute(bytes32 indexed jobKey, address indexed job, bool indexed success, uint256 gasUsed, uint256 baseFee, uint256 gasPrice, uint256 compensation);

  OnlySelectorTestJob internal counter;

  bytes32 internal jobKey;
  uint256 internal jobId;
  uint256 internal defaultFlags;
  uint256 internal accrueFlags;
  uint256 internal kid1;
  uint256 internal kid2;

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
    agent = new PPAgentV2Randao(owner, address(cvp), 3_000 ether, 3 days, 2 minutes);
    counter = new OnlySelectorTestJob(address(agent));

    {
      cvp.transfer(keeperAdmin, 10_000 ether);

      vm.startPrank(keeperAdmin);
      cvp.approve(address(agent), 10_000 ether);
      kid1 = agent.registerAsKeeper(alice, 5_000 ether);
      kid2 = agent.registerAsKeeper(keeperWorker, 5_000 ether);
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
    assertEq(_keeperCount(), 2);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    vm.prank(alice, alice);
    vm.difficulty(40);
    vm.expectRevert(
      abi.encodeWithSelector(
        PPAgentV2Randao.OnlyNextKeeper.selector, 2, 0, 10, 120, 1600000000
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
  }

  function testRdCantRedeem() public {
    assertEq(_keeperCount(), 2);
    assertEq(agent.jobNextKeeperId(jobKey), 2);
    vm.expectRevert(abi.encodeWithSelector(PPAgentV2Randao.KeeperIsAssignedToJobs.selector, 1));

    vm.prank(keeperAdmin, keeperAdmin);
    agent.initiateRedeem(kid2, 5_000 ether);
  }

  // TODO: cant withdraw when assigned to 1 job
  // TODO: could be slashed within
  // TODO: can't be slashed
}
