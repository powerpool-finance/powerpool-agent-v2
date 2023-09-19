// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2.sol";
import "../mocks/MockCVP.sol";
import "../TestHelperRandao.sol";
import "../../contracts/PPAgentV2Randao.sol";

contract RandaoOwnerStakingTest is TestHelperRandao {
  uint256 internal kid;

  event OwnerSlash(uint256 indexed keeperId, address indexed to, uint256 currentAmount, uint256 pendingAmount);

  function setUp() public override {
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
    agent.initializeRandao(owner, MIN_DEPOSIT_3000_CVP, 3 days, rdConfig);
    cvp.transfer(keeperAdmin, 16_000 ether);
    vm.startPrank(keeperAdmin);
    cvp.approve(address(agent), MIN_DEPOSIT_3000_CVP * 2);
    agent.registerAsKeeper(address(1), MIN_DEPOSIT_3000_CVP);
    kid = agent.registerAsKeeper(keeperWorker, MIN_DEPOSIT_3000_CVP);

    vm.warp(block.timestamp + 8 hours);
    agent.finalizeKeeperActivation(kid);
    vm.stopPrank();
  }

  function testRdCanDisableKeeperOnOwnerSlashOnlyOwner() public {
    vm.expectRevert(PPAgentV2.OnlyOwner.selector);
    agent.ownerSlashDisable(kid, bob, 1, 0, true);
  }

  function testRdCanDisableKeeperOnOwnerSlashKeeperAlreadyInactive() public {
    vm.prank(keeperAdmin);
    agent.disableKeeper(kid);

    vm.prank(owner);
    vm.expectRevert(PPAgentV2Randao.KeeperIsAlreadyInactive.selector);
    agent.ownerSlashDisable(kid, bob, 1, 0, true);
  }

  function testRdCanDisableKeeperOnOwnerSlashDisabledOk() public {
    vm.prank(owner);
    agent.ownerSlashDisable(kid, bob, 1, 0, true);
    assertEq(_keeperIsActive(kid), false);
  }

  function testRdCanDisableKeeperOnOwnerSlashNotDisabledOk() public {
    vm.prank(owner);
    agent.ownerSlashDisable(kid, bob, 1, 0, false);
    assertEq(_keeperIsActive(kid), true);
  }
}
