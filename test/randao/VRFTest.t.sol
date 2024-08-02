// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Based.sol";
import "../../contracts/PPAgentV2VRF.sol";
import "../TestHelperRandao.sol";
import "../mocks/MockCVP.sol";
import "../jobs/OnlySelectorTestJob.sol";
import "../mocks/MockCompensationTracker.sol";
import "../mocks/MockVRFCoordinator.sol";
import "../../contracts/VRFAgentManager.sol";
import "../../contracts/VRFAgentConsumerFactory.sol";
import "../../lib/forge-std/src/console.sol";

contract VRFTest is AbstractTestHelper {
  ICounter internal job;

  OnlySelectorTestJob internal counter;
  MockVRFCoordinator internal coordinator;
  VRFAgentConsumer internal consumer;

  bytes32 internal jobKey;
  uint256 internal jobId;
  uint256 internal defaultFlags;
  uint256 internal accrueFlags;
  uint256 internal kid1;
  uint256 internal kid2;
  uint256 internal kid3;
  uint256 internal latestKeeperStub;

  PPAgentV2VRFBased internal agent;

  function _agentViewer() internal override view returns(IPPAgentV2Viewer) {
    return IPPAgentV2Viewer(address(agent));
  }

  function _rdGlobalMaxCvpStake() internal view returns (uint256) {
    IPPAgentV2RandaoViewer.RandaoConfig memory rdConfig = agent.getRdConfig();
    return uint256(rdConfig.agentMaxCvpStake) * 1 ether;
  }

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
      jobMinCreditsFinney: 1,
      agentMaxCvpStake: 50_000,
      jobCompensationMultiplierBps: 10_000,
      stakeDivisor: 50_000_000,
      keeperActivationTimeoutHours: 8,
      jobFixedRewardFinney: 30
    });

    VRFAgentConsumerFactory consumerFactory = new VRFAgentConsumerFactory();
    coordinator = new MockVRFCoordinator(consumerFactory);
    consumerFactory.transferOwnership(address(coordinator));
    agent = new PPAgentV2VRF(address(cvp));
    counter = new OnlySelectorTestJob(address(agent));
    agent.initializeRandao(owner, 3_000 ether, 3 days, rdConfig);
    coordinator.registerAgent(address(agent));
    (uint64 subId, address consumerAddress) = coordinator.createSubscriptionWithConsumer();
    consumer = VRFAgentConsumer(consumerAddress);
    consumer.setVrfConfig(1, 1e6, 30);

    vm.prank(owner);
    agent.setAgentParams(1, 10, 1e4);
    vm.prank(owner);
    agent.setVRFConsumer(consumerAddress);

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

  function _setupJob(address job_, bytes4 selector_, bool assertSelector_, bool jobConsumerOffchainType_) internal {
    PPAgentV2Based.Resolver memory resolver = IPPAgentV2Viewer.Resolver({
      resolverAddress: job_,
      resolverCalldata: jobConsumerOffchainType_ ? bytes("") : abi.encodeWithSelector(VRFAgentConsumer.fulfillRandomWords.selector)
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
      calldataSource: jobConsumerOffchainType_ ? CALLDATA_SOURCE_OFFCHAIN : CALLDATA_SOURCE_SELECTOR,
      intervalSeconds: jobConsumerOffchainType_ ? 0 : 15
    });
    vm.prank(alice);
    vm.deal(alice, 1 ether);
    vm.roll(10);
    (jobKey, jobId) = agent.registerJob{ value: 1 ether }({
      params_: params,
      resolver_: resolver,
      preDefinedCalldata_: new bytes(0)
    });
  }

  function _getMockProof() internal view returns(VRFAgentCoordinatorInterface.Proof memory) {
    uint256[2] memory emptyArr;
    return VRFAgentCoordinatorInterface.Proof({
      pk: emptyArr,
      gamma: emptyArr,
      c: 0,
      s: 0,
      seed: 0,
      uWitness: address(0),
      cGammaWitness: emptyArr,
      sHashWitness: emptyArr,
      zInv: 0
    });
  }

  function _getMockCommitment() internal view returns(VRFAgentCoordinatorInterface.RequestCommitment memory) {
    return VRFAgentCoordinatorInterface.RequestCommitment({
      blockNum: uint64(0),
      subId: uint64(0),
      callbackGasLimit: uint32(0),
      numWords: uint32(0),
      sender: address(0)
    });
  }

  function testVrfNumbersShouldBeSet() public {
    job = new OnlySelectorTestJob(address(agent));
    assertEq(job.current(), 0);
    _setupJob(address(job), OnlySelectorTestJob.increment.selector, true, false);
    assertEq(coordinator.lastRequestIdByConsumer(address(consumer)), 1);
    assertEq(consumer.pendingRequestId(), coordinator.lastRequestIdByConsumer(address(consumer)));
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    assertEq(consumer.getPseudoRandom(), uint256(blockhash(block.number - 1)));
    uint256 fulfillAt = block.timestamp;

    vm.expectRevert(abi.encodeWithSelector(VRFAgentConsumer.OnlyAgent.selector));
    consumer.fulfillRandomWords(_getMockProof(), _getMockCommitment());
    vm.prank(address(agent));
    consumer.fulfillRandomWords(_getMockProof(), _getMockCommitment());

    assertNotEq(consumer.getPseudoRandom(), uint256(blockhash(block.number - 1)));
    assertEq(consumer.pendingRequestId(), 0);
    assertEq(coordinator.lastRequestIdByConsumer(address(consumer)), 1);
    assertEq(consumer.lastVrfFulfillAt(), fulfillAt);

    (bool needFulfill, ) = coordinator.fulfillRandomnessOffchainResolver(address(consumer), 1);
    assertEq(needFulfill, false);

    vm.prank(keeperWorker, keeperWorker);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid2,
      new bytes(0)
    );
    assertEq(coordinator.lastRequestIdByConsumer(address(consumer)), 1);
    assertEq(consumer.pendingRequestId(), 0);

    consumer.setVrfConfig(uint16(0), uint32(0), 30);

    assertEq(consumer.pendingRequestId(), consumer.coordinatorPendingRequestId());
    (needFulfill, ) = coordinator.fulfillRandomnessOffchainResolver(address(consumer), 1);
    assertEq(needFulfill, false);

//    consumer = new VRFAgentConsumer(address(agent));
//    coordinator.addConsumer(coordinator.createSubscription(), address(consumer));

    vm.roll(25);
    uint256 fulfillTimestamp = block.timestamp + 15;
    vm.warp(fulfillTimestamp);
    vm.expectRevert(abi.encodeWithSelector(VRFAgentConsumer.RequestNotFound.selector, 1, 0));
    vm.prank(address(agent));
    consumer.fulfillRandomWords(_getMockProof(), _getMockCommitment());
    assertEq(consumer.pendingRequestId(), 0);
    assertEq(consumer.lastVrfFulfillAt(), fulfillAt);

    (needFulfill, ) = coordinator.fulfillRandomnessOffchainResolver(address(consumer), 1);
    assertEq(needFulfill, false);

    coordinator.requestRandomWords(address(0), 1, 1, 1, 10);

    (needFulfill, ) = coordinator.fulfillRandomnessOffchainResolver(address(consumer), 1);
    assertEq(needFulfill, false);

    vm.roll(30);
    vm.warp(fulfillTimestamp + 15);

    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(consumer.isReadyForRequest(), false);
    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    assertEq(consumer.pendingRequestId(), 0);
    assertEq(coordinator.lastRequestIdByConsumer(address(consumer)), 1);

    vm.roll(40);
    vm.warp(fulfillTimestamp + 31);
    assertEq(agent.jobNextKeeperId(jobKey), 1);
    assertEq(consumer.isReadyForRequest(), true);
    vm.prank(alice, alice);
    _callExecuteHelper(
      agent,
      address(job),
      jobId,
      defaultFlags,
      kid1,
      new bytes(0)
    );

    assertEq(consumer.pendingRequestId(), 3);
    assertEq(coordinator.lastRequestIdByConsumer(address(consumer)), 3);

    uint256 timestampBefore = block.timestamp;
    assertEq(consumer.isReadyForRequest(), false);
    vm.roll(296);
    assertEq(block.number - consumer.lastVrfRequestAtBlock() >= 256, true);
    assertEq(consumer.isReadyForRequest(), true);
    assertEq(timestampBefore, block.timestamp);
  }

  function testAutoDepositJobShouldDoTheThing() public {
    _setupJob(address(consumer), consumer.fulfillRandomWords.selector, true, true);
    assertEq(agent.jobNextKeeperId(jobKey), 2);

    consumer.setVrfConfig(uint16(0), uint32(0), 30);
    (, , uint256 feeTotal, , ) = agent.getConfig();
    assertEq(feeTotal, 1e16);

    VRFAgentManager agentManager = new VRFAgentManager(agent, coordinator);
    agentManager.setVrfJobKey(jobKey);
    agentManager.setVrfConfig(1.5e16, 1e17);
    agentManager.setAutoDepositConfig(1 ether, 2 ether);
    vm.prank(alice);
    agent.initiateJobTransfer(jobKey, address(agentManager));
    agentManager.acceptAllJobsTransfer();
    vm.prank(owner);
    agent.transferOwnership(address(agentManager));

    (, , feeTotal, , ) = agent.getConfig();
    assertEq(feeTotal, 1e16);

    (
      bytes32 autoDepositJobKey,
      uint256 autoDepositJobId
    ) = agentManager.registerAutoDepositJob{value: 1e16}(100, 35, 10, 0, false);

    assertNotEq(agentManager.autoDepositJobKey(), bytes32(0));
    assertEq(agentManager.autoDepositJobKey(), autoDepositJobKey);

    assertEq(consumer.pendingRequestId(), 1);

    vm.prank(keeperWorker, keeperWorker);
    vm.roll(20);
    uint256 fulfillTimestamp = block.timestamp;
    _callExecuteHelper(
      agent,
      address(consumer),
      jobId,
      defaultFlags,
      kid2,
      abi.encodeWithSelector(VRFAgentConsumer.fulfillRandomWords.selector, _getMockProof(), _getMockCommitment())
    );
    assertEq(consumer.lastVrfFulfillAt(), fulfillTimestamp);

    (
      uint256 amountToDeposit,
      uint256 vrfAmountIn,
      uint256 autoDepositAmountIn
    ) = agentManager.getBalanceRequiredToDeposit();
    assertEq(amountToDeposit, 0);
    assertEq(vrfAmountIn, 0);
    assertEq(autoDepositAmountIn, 0);

    (bool isCallAutoDeposit, bytes memory autoDepositCalldata) = agentManager.vrfAutoDepositJobsResolver();
    assertEq(isCallAutoDeposit, false);

    agentManager.setAutoDepositJobKey(autoDepositJobKey);
    agentManager.setAutoDepositConfig(1e16, 1e17);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertApproxEqAbs(amountToDeposit, 1.01e16, 1);
    assertEq(vrfAmountIn, 0);
    assertApproxEqAbs(autoDepositAmountIn, 1.01e16, 1);
    (isCallAutoDeposit, autoDepositCalldata) = agentManager.vrfAutoDepositJobsResolver();
    assertEq(isCallAutoDeposit, true);

    uint256 autoDepositBalanceBefore = agentManager.getAutoDepositJobBalance();

    assertEq(agent.jobNextKeeperId(autoDepositJobKey), 2);
    vm.prank(keeperWorker, keeperWorker);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(agentManager),
      autoDepositJobId,
      defaultFlags,
      kid2,
      autoDepositCalldata
    );

    uint256 autoDepositBalanceAfter = agentManager.getAutoDepositJobBalance();
    assertGt(autoDepositBalanceAfter, autoDepositBalanceBefore);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertEq(amountToDeposit, 0);
    assertEq(vrfAmountIn, 0);
    assertEq(autoDepositAmountIn, 0);

    (isCallAutoDeposit, autoDepositCalldata) = agentManager.vrfAutoDepositJobsResolver();
    assertEq(isCallAutoDeposit, false);

    (address jobOwner, , , , ,) = agent.getJob(jobKey);
    assertEq(jobOwner, address(agentManager));
    agentManager.withdrawJobCredits(jobKey, payable(alice), agentManager.getVrfFullfillJobBalance());
    assertEq(agentManager.getVrfFullfillJobBalance(), 0);

    agent.depositJobCredits{value: 100 ether}(autoDepositJobKey);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertApproxEqAbs(amountToDeposit, 1e17, 1);
    assertApproxEqAbs(vrfAmountIn, 1e17, 1);
    assertEq(autoDepositAmountIn, 0);

    agentManager.setVrfJobKey(jobKey);
    agentManager.setVrfConfig(1 ether, 2 ether);

    (amountToDeposit, vrfAmountIn, autoDepositAmountIn) = agentManager.getBalanceRequiredToDeposit();
    assertApproxEqAbs(amountToDeposit, 1.000101e18, 1);
    assertApproxEqAbs(vrfAmountIn, 1.000101e18, 1);
    assertEq(autoDepositAmountIn, 0);

    uint256 vrfJobBalanceBefore = agentManager.getVrfFullfillJobBalance();
    assertEq(agent.jobNextKeeperId(autoDepositJobKey), 1);
    vm.prank(alice, alice);
    vm.roll(20);
    _callExecuteHelper(
      agent,
      address(agentManager),
      autoDepositJobId,
      defaultFlags,
      kid1,
      autoDepositCalldata
    );
    uint256 vrfJobBalanceAfter = agentManager.getVrfFullfillJobBalance();
    assertGt(vrfJobBalanceAfter, vrfJobBalanceBefore);
  }
}
