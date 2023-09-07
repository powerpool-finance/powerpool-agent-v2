// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./../mocks/MockCVP.sol";
import "../../contracts/PPAgentV2Randao.sol";
import "../TestHelperRandao.sol";
import "../mocks/MockExposedAgent.sol";

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
      jobCompensationMultiplierBps: 11_000,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8,
      jobFixedRewardFinney: 3
    });
    agent = new MockExposedAgent(address(cvp));
    agent.initializeRandao(bob, 3_000 ether, 3 days, rdConfig);
  }

  function testGasCompensationRandaoOk() public {
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
      // jobFixedReward
      // + baseFee_ * (gasUsed_ + fixedOverhead) * _rdConfig.jobCompensationMultiplierBps / 10_000
      // + (stake | maxStake) / _rdConfig.stakeDivisor
      0.003 ether + uint256(45 gwei * (150_000 + 136_000) * 11_000 / 10_000) + (40_000 ether / 50_000_000)
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
      // jobFixedReward
      // + baseFee_ * (gasUsed_ + fixedOverhead) * _rdConfig.jobCompensationMultiplierBps / 10_000
      // + (stake | maxStake) / _rdConfig.stakeDivisor
      0.003 ether + uint256(45 gwei * (150_000 + 136_000) * 11_000 / 10_000) + (50_000 ether / 50_000_000)
    );
  }

  function testGetKeeperLimitedStakeTheSame() public {
    assertEq(MockExposedAgent(address(agent)).getKeeperLimitedStake({
      keeperCurrentStake_: 1 ether,
      agentMaxCvpStakeCvp_: 1,
      job_: _job(1)
    }), 1 ether);
  }

  function testGetKeeperNotLimited() public {
    assertEq(MockExposedAgent(address(agent)).getKeeperLimitedStake({
      keeperCurrentStake_: 10 ether,
      agentMaxCvpStakeCvp_: 0,
      job_: _job(0)
    }), 10 ether);
  }

  function testGetKeeperLimitedStakeByAgentOnly() public {
    assertEq(MockExposedAgent(address(agent)).getKeeperLimitedStake({
      keeperCurrentStake_: 10 ether,
      agentMaxCvpStakeCvp_: 5,
      job_: _job(0)
    }), 5 ether);
  }

  function testGetKeeperLimitedStakeByAgentIgnoringJob() public {
    assertEq(MockExposedAgent(address(agent)).getKeeperLimitedStake({
      keeperCurrentStake_: 10 ether,
      agentMaxCvpStakeCvp_: 5,
      job_: _job(7)
    }), 5 ether);
  }

  function testGetKeeperLimitedStakeByJobOnly() public {
    assertEq(MockExposedAgent(address(agent)).getKeeperLimitedStake({
      keeperCurrentStake_: 10 ether,
      agentMaxCvpStakeCvp_: 0,
      job_: _job(7)
    }), 7 ether);
  }

  function testGetKeeperLimitedStakeByJobIgnoringAgent() public {
    assertEq(MockExposedAgent(address(agent)).getKeeperLimitedStake({
      keeperCurrentStake_: 10 ether,
      agentMaxCvpStakeCvp_: 7,
      job_: _job(5)
    }), 5 ether);
  }

  function testGetKeeperLimitedStakeJobHelper() public {
    assertEq(_jobBytes(10),               0x0000000000000a000000000a002300640000000de0b6b3a7640000d09de08a01);
    assertEq(_jobBytes(0),                0x0000000000000a0000000000002300640000000de0b6b3a7640000d09de08a01);
    assertEq(_jobBytes(type(uint32).max), 0x0000000000000a00ffffffff002300640000000de0b6b3a7640000d09de08a01);
  }

  function _job(uint256 maxKeeperCvp_) internal pure returns (uint256) {
    return uint256(_jobBytes(maxKeeperCvp_));
  }

  function _jobBytes(uint256 maxKeeperCvp_) internal pure returns (bytes32) {
    require(maxKeeperCvp_ <= type(uint32).max, "uint32 overflow");
    return bytes32(maxKeeperCvp_ << 160) ^ 0x0000000000000a0000000000002300640000000de0b6b3a7640000d09de08a01;
  }
}
