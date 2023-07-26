// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../mocks/MockCVP.sol";
import "../TestHelperRandao.sol";

contract RandaoAgentOwnerTest is TestHelperRandao {
  uint256 internal kid;

  event SetAgentParams(uint256 minKeeperCvp_, uint256 timeoutSeconds_, uint256 feePct_);
  event WithdrawFees(address indexed to, uint256 amount);

  PPAgentV2Randao.RandaoConfig rdConfig;

  function setUp() public override {
    cvp = new MockCVP();
  }

  function testOwnerCantInitAgentWithJobMultiplierLt10000() public {
    cvp = new MockCVP();
    rdConfig = IPPAgentV2RandaoViewer.RandaoConfig({
      slashingEpochBlocks: 10,
      period1: 15,
      period2: 30,
      slashingFeeFixedCVP: 50,
      slashingFeeBps: 300,
      jobMinCreditsFinney: 100,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 9999,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8
    });
    PPAgentV2Randao rAgent = new PPAgentV2Randao(address(cvp));

    vm.expectRevert(PPAgentV2Randao.JobCompensationMultiplierBpsLT10000.selector);
    rAgent.initializeRandao(owner, 3_000 ether, 3 days, rdConfig);
  }
}
