// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./../mocks/MockCVP.sol";
import "../../contracts/PPAgentV2Randao.sol";
import "../TestHelperRandao.sol";

contract RandaoCompensationTest is TestHelperRandao {
  uint256 internal constant CVP_LIMIT = 100_000_000 ether;

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
      jobCompensationMultiplierBps: 1,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8
    });
    agent = new PPAgentV2Randao(address(cvp));
    agent.initializeRandao(bob, 3_000 ether, 3 days, rdConfig);
  }

  function testGasCompensationRandao() public {
    cvp.transfer(bob, 40_000 ether);

    vm.prank(bob);
    cvp.approve(address(agent), 40_000 ether);
    vm.prank(bob);
    agent.registerAsKeeper(bob, 40_000 ether);

    assertEq(
      agent.calculateCompensation({
        ok_: true,
        job_: 0,
        keeperId_: 1,
        baseFee_: 45 gwei,
        gasUsed_: 150_000
      }),
      // baseFee_ * gasUsed_ * _rdConfig.jobCompensationMultiplierBps / 10_000 + (stake | maxStake) / _rdConfig.stakeDivisor
      uint256(45 gwei * 150_000 * 1 / 10_000) + (40_000 ether / 50_000_000)
    );
  }

  function testGasCompensationRandaoIsLimitedByAgentMaxCvpStake() public {
    cvp.transfer(bob, 60_000 ether);

    vm.prank(bob);
    cvp.approve(address(agent), 60_000 ether);
    vm.prank(bob);
    agent.registerAsKeeper(bob, 60_000 ether);

    assertEq(
      agent.calculateCompensation({
        ok_: true,
        job_: 0,
        keeperId_: 1,
        baseFee_: 45 gwei,
        gasUsed_: 150_000
      }),
      // baseFee_ * gasUsed_ * _rdConfig.jobCompensationMultiplierBps / 10_000 + (stake | maxStake) / _rdConfig.stakeDivisor
      uint256(45 gwei * 150_000 * 1 / 10_000) + (50_000 ether / 50_000_000)
    );
  }
}
