// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PPAgentV2VRFBased} from "./PPAgentV2VRFBased.sol";
import { IPPAgentV2JobOwner, IPPAgentV2Viewer } from "./PPAgentV2Interfaces.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/VRFAgentConsumerInterface.sol";

/**
 * @title VRFAgentManager
 * @author PowerPool
 */
contract VRFAgentManager is Ownable {

  uint256 internal constant CFG_ACTIVE = 0x01;

  PPAgentV2VRFBased public agent;
  VRFAgentCoordinatorInterface public coordinator;
  VRFAgentConsumerInterface public consumer;
  uint256 public subId;

  bytes32 public vrfJobKey;
  uint256 public vrfJobMinBalance; // balance for 3 executes
  uint256 public vrfJobMaxDeposit; // balance for 9 executes

  bytes32 public autoDepositJobKey;
  uint256 public autoDepositJobMinBalance;
  uint256 public autoDepositJobMaxDeposit;

  error MinMoreThanMax();
  error JobDepositNotRequired();
  error DepositBalanceIsNotEnough();

  constructor(PPAgentV2VRFBased agent_, VRFAgentCoordinatorInterface coordinator_) {
    agent = agent_;
    coordinator = coordinator_;
  }

  receive() external payable { }

  function processVrfJobDeposit() external payable {
    (uint256 requiredBalance, uint256 vrfAmountIn, uint256 autoDepositAmountIn) = getBalanceRequiredToDeposit();

    bool jobAssignSuccess = false;
    if (getAssignedKeeperToJob(vrfJobKey) == 0 && vrfAmountIn == 0) {
      _assignKeeperToJob(vrfJobKey);
      jobAssignSuccess = true;
    }

    if (requiredBalance == 0) {
      if (jobAssignSuccess) {
        return;
      } else {
        revert JobDepositNotRequired();
      }
    }

    agent.withdrawFees(payable(address(this)));
    uint256 availableBalance = address(this).balance;

    if (availableBalance < requiredBalance) {
      if (jobAssignSuccess) {
        return;
      } else {
        revert DepositBalanceIsNotEnough();
      }
    }

    if (vrfAmountIn != 0) {
      agent.depositJobCredits{value: vrfAmountIn}(vrfJobKey);
    }
    if (autoDepositAmountIn != 0) {
      agent.depositJobCredits{value: autoDepositAmountIn}(autoDepositJobKey);
    }
  }

  /*** AGENT OWNER METHODS ***/

  function setVrfJobKey(bytes32 vrfJobKey_) public onlyOwner {
    vrfJobKey = vrfJobKey_;
  }
  function setAutoDepositJobKey(bytes32 autoDepositJobKey_) public onlyOwner {
    autoDepositJobKey = autoDepositJobKey_;
  }

  function setVrfConfig(uint256 minBalance_, uint256 maxDeposit_) public onlyOwner {
    vrfJobMinBalance = minBalance_;
    vrfJobMaxDeposit = maxDeposit_;
    if (minBalance_ > maxDeposit_) {
      revert MinMoreThanMax();
    }
  }
  function setAutoDepositConfig(uint256 minBalance_, uint256 maxDeposit_) public onlyOwner {
    autoDepositJobMinBalance = minBalance_;
    autoDepositJobMaxDeposit = maxDeposit_;
    if (minBalance_ > maxDeposit_) {
      revert MinMoreThanMax();
    }
  }

  function registerVrfJob(
    uint16 maxBaseFeeGwei_,
    uint16 rewardPct_,
    uint32 fixedReward_,
    uint256 jobMinCvp_,
    bool activateJob
  ) external payable onlyOwner returns(bytes32 jobKey, uint256 jobId) {
    (uint64 subId_, address consumer_) = coordinator.createSubscriptionWithConsumer();
    subId = subId_;
    consumer = VRFAgentConsumerInterface(consumer_);
    agent.setVRFConsumer(address(consumer));

    IPPAgentV2JobOwner.RegisterJobParams memory params = IPPAgentV2JobOwner.RegisterJobParams({
      jobAddress: address(consumer),
      jobSelector: VRFAgentConsumerInterface.fulfillRandomWords.selector,
      useJobOwnerCredits: false,
      assertResolverSelector: true,
      maxBaseFeeGwei: maxBaseFeeGwei_,
      rewardPct: rewardPct_,
      fixedReward: fixedReward_,
      jobMinCvp: jobMinCvp_,
      calldataSource: 3,
      intervalSeconds: 0
    });
    (jobKey, jobId) = agent.registerJob{value: msg.value}(params, getVrfResolverStruct(), new bytes(0));
    vrfJobKey = jobKey;
    agent.setJobConfig(vrfJobKey, activateJob, false, true, true);
    if (activateJob && getAssignedKeeperToJob(jobKey) == 0) {
      _assignKeeperToJob(vrfJobKey);
    }
  }

  function registerAutoDepositJob(
    uint16 maxBaseFeeGwei_,
    uint16 rewardPct_,
    uint32 fixedReward_,
    uint256 jobMinCvp_,
    bool activateJob_
  ) external payable onlyOwner returns(bytes32 jobKey, uint256 jobId) {
    return _registerAutoDepositJob(maxBaseFeeGwei_, rewardPct_, fixedReward_, jobMinCvp_, activateJob_, msg.value);
  }

  function _registerAutoDepositJob(
    uint16 maxBaseFeeGwei_,
    uint16 rewardPct_,
    uint32 fixedReward_,
    uint256 jobMinCvp_,
    bool activateJob_,
    uint256 depositBalance_
  ) internal returns(bytes32 jobKey, uint256 jobId) {
    IPPAgentV2JobOwner.RegisterJobParams memory params = IPPAgentV2JobOwner.RegisterJobParams({
      jobAddress: address(this),
      jobSelector: VRFAgentManager.processVrfJobDeposit.selector,
      useJobOwnerCredits: false,
      assertResolverSelector: true,
      maxBaseFeeGwei: maxBaseFeeGwei_,
      rewardPct: rewardPct_,
      fixedReward: fixedReward_,
      jobMinCvp: jobMinCvp_,
      calldataSource: 2,
      intervalSeconds: 0
    });
    (jobKey, jobId) = agent.registerJob{value: depositBalance_}(params, getAutoDepositResolverStruct(), new bytes(0));
    autoDepositJobKey = jobKey;
    if (activateJob_ && getAssignedKeeperToJob(jobKey) == 0) {
      agent.setJobConfig(autoDepositJobKey, true, false, true, true);
      _assignKeeperToJob(autoDepositJobKey);
    }
  }

  function setJobResolver(bytes32 jobKey_, PPAgentV2VRFBased.Resolver calldata resolver_) external onlyOwner {
    agent.setJobResolver(jobKey_, resolver_);
  }

  function setAutoDepositJobResolver() public onlyOwner {
    agent.setJobResolver(autoDepositJobKey, getAutoDepositResolverStruct());
  }

  function acceptJobTransfer(bytes32 jobKey_) external onlyOwner {
    agent.acceptJobTransfer(jobKey_);
  }

  function initiateJobTransfer(bytes32 jobKey_, address to_) public onlyOwner {
    agent.initiateJobTransfer(jobKey_, to_);
  }

  function setJobConfig(
    bytes32 jobKey_,
    bool isActive_,
    bool useJobOwnerCredits_,
    bool assertResolverSelector_,
    bool callResolverBeforeExecute_
  ) public onlyOwner {
    agent.setJobConfig(jobKey_, isActive_, useJobOwnerCredits_, assertResolverSelector_, callResolverBeforeExecute_);
  }

  function updateJob(
    bytes32 jobKey_,
    uint16 maxBaseFeeGwei_,
    uint16 rewardPct_,
    uint32 fixedReward_,
    uint256 jobMinCvp_,
    uint24 intervalSeconds_
  ) external onlyOwner {
    agent.updateJob(jobKey_, maxBaseFeeGwei_, rewardPct_, fixedReward_, jobMinCvp_, intervalSeconds_);
  }

  function withdrawJobCredits(bytes32 jobKey_, address payable to_, uint256 amount_) external onlyOwner {
    agent.withdrawJobCredits(jobKey_, to_, amount_);
  }

  function setRdConfig(PPAgentV2VRFBased.RandaoConfig calldata rdConfig_) external onlyOwner {
    agent.setRdConfig(rdConfig_);
  }

  function setAgentParams(
    uint256 minKeeperCvp_,
    uint256 timeoutSeconds_,
    uint256 feePpm_
  ) external onlyOwner {
    agent.setAgentParams(minKeeperCvp_, timeoutSeconds_, feePpm_);
  }

  function setVRFConsumer(address VRFConsumer_) external onlyOwner {
    consumer = VRFAgentConsumerInterface(VRFConsumer_);
    agent.setVRFConsumer(VRFConsumer_);

    IPPAgentV2Viewer.Resolver memory vrfJobResolver = getVrfFullfillJobResolver();
    vrfJobResolver.resolverAddress = VRFConsumer_;
    agent.setJobResolver(vrfJobKey, vrfJobResolver);
  }

  function setConsumerVrfConfig(
    uint16 vrfRequestConfirmations_,
    uint32 vrfCallbackGasLimit_,
    uint256 vrfRequestPeriod_
  ) external onlyOwner {
    consumer.setVrfConfig(
      vrfRequestConfirmations_,
      vrfCallbackGasLimit_,
      vrfRequestPeriod_
    );
  }

  function setConsumerOffChainIpfsHash(string calldata _ipfsHash) external onlyOwner {
    consumer.setOffChainIpfsHash(_ipfsHash);
  }

  function consumerTransferOwnership(address _newOwner) external onlyOwner {
    Ownable(address(consumer)).transferOwnership(_newOwner);
  }

  function assignKeeperToJob(bytes32 _jobKey) external onlyOwner {
    _assignKeeperToJob(_jobKey);
  }

  function assignKeeperToAllJobs() external onlyOwner {
    if (getAssignedKeeperToJob(vrfJobKey) == 0 && !isJobActive(vrfJobKey)) {
        agent.setJobConfig(vrfJobKey, true, false, true, true);
    }
    if (getAssignedKeeperToJob(vrfJobKey) == 0) {
      _assignKeeperToJob(vrfJobKey);
    }
    if (getAssignedKeeperToJob(autoDepositJobKey) == 0 && !isJobActive(autoDepositJobKey)) {
        agent.setJobConfig(autoDepositJobKey, true, false, true, true);
    }
    if (getAssignedKeeperToJob(autoDepositJobKey) == 0) {
      _assignKeeperToJob(autoDepositJobKey);
    }
  }

  function ownerSlash(uint256 keeperId_, address to_, uint256 currentAmount_, uint256 pendingAmount_) external onlyOwner {
    agent.ownerSlash(keeperId_, to_, currentAmount_, pendingAmount_);
  }

  function ownerSlashDisable(
    uint256 keeperId_,
    address to_,
    uint256 currentAmount_,
    uint256 pendingAmount_,
    bool disable_
  ) external onlyOwner {
    agent.ownerSlashDisable(keeperId_, to_, currentAmount_, pendingAmount_, disable_);
  }

  function withdrawFeesFromAgent(address payable to_) external onlyOwner {
    agent.withdrawFees(to_);
  }

  function withdrawExcessBalance(address payable to_, uint256 amount_) public onlyOwner {
    to_.transfer(amount_);
  }

  function migrateToNewManager(address newVrfAgentManager_) external onlyOwner {
    agent.transferOwnership(newVrfAgentManager_);
    if (getJobOwner(vrfJobKey) == address(this)) {
      initiateJobTransfer(vrfJobKey, newVrfAgentManager_);
    }
    if (getJobOwner(autoDepositJobKey) == address(this)) {
      initiateJobTransfer(autoDepositJobKey, newVrfAgentManager_);
    }
    if (address(this).balance > 0) {
      withdrawExcessBalance(payable(newVrfAgentManager_), address(this).balance);
    }
  }

  function migrateFromOldManager(VRFAgentManager oldVrfAgentManager_) external onlyOwner {
    consumer = oldVrfAgentManager_.consumer();
    setVrfJobKey(oldVrfAgentManager_.vrfJobKey());
    setAutoDepositJobKey(oldVrfAgentManager_.autoDepositJobKey());

    acceptAllJobsTransfer();

    (, , uint256 jobMinKeeperCvp, PPAgentV2VRFBased.Job memory details, , ) = agent.getJob(autoDepositJobKey);

    uint256 autoDepositJobBalance = deactivateJob(autoDepositJobKey);
    _registerAutoDepositJob(details.maxBaseFeeGwei, details.rewardPct, details.fixedReward, jobMinKeeperCvp, true, autoDepositJobBalance);

    setVrfConfig(oldVrfAgentManager_.vrfJobMinBalance(), oldVrfAgentManager_.vrfJobMaxDeposit());
    setAutoDepositConfig(oldVrfAgentManager_.autoDepositJobMinBalance(), oldVrfAgentManager_.autoDepositJobMaxDeposit());
  }

  function deactivateJob(bytes32 jobKey_) public onlyOwner returns(uint256 jobBalance) {
    jobBalance = getAutoDepositJobBalance();

    setJobConfig(jobKey_, false, false, false, false);
    agent.withdrawJobCredits(jobKey_, payable(address(this)), jobBalance);
  }

  function acceptAllJobsTransfer() public onlyOwner {
    if (getJobPendingOwner(vrfJobKey) == address(this)) {
      agent.acceptJobTransfer(vrfJobKey);
    }
    if (getJobPendingOwner(autoDepositJobKey) == address(this)) {
      agent.acceptJobTransfer(autoDepositJobKey);
    }
  }

  /*** GETTER ***/

  function getVrfFullfillJobResolver() public view returns(IPPAgentV2Viewer.Resolver memory) {
    (, , , , , IPPAgentV2Viewer.Resolver memory resolver) = agent.getJob(vrfJobKey);
    return resolver;
  }

  function getVrfFullfillJobBalance() public view returns(uint256) {
    return getJobBalance(vrfJobKey);
  }

  function getAutoDepositJobBalance() public view returns(uint256) {
    return getJobBalance(autoDepositJobKey);
  }

  function getJobBalance(bytes32 jobKey_) public view returns(uint256) {
    (, , , PPAgentV2VRFBased.Job memory details, , ) = agent.getJob(jobKey_);
    return details.credits;
  }

  function isVrfJobDepositRequired() public view returns(bool) {
    return getVrfFullfillJobBalance() <= vrfJobMinBalance;
  }

  function isAutoDepositJobDepositRequired() public view returns(bool) {
    return getAutoDepositJobBalance() <= autoDepositJobMinBalance;
  }

  function getAssignedKeeperToJob(bytes32 jobKey_) public view returns(uint256) {
    return agent.jobNextKeeperId(jobKey_);
  }

  function getAgentFeeTotal() public view returns(uint256) {
    (, , uint256 feeTotal, , ) = agent.getConfig();
    return feeTotal;
  }

  function getJobOwner(bytes32 jobKey_) public view returns(address) {
    (address owner, , , , , ) = agent.getJob(jobKey_);
    return owner;
  }

  function isJobActive(bytes32 jobKey_) public view returns (bool) {
    return isJobActivePure(IPPAgentV2Viewer(address(agent)).getJobRaw(jobKey_));
  }

  function isJobActivePure(uint256 config_) public pure returns (bool) {
    return (config_ & CFG_ACTIVE) != 0;
  }

  function getJobPendingOwner(bytes32 jobKey_) public view returns(address) {
    (, address pendingOwner, , , , ) = agent.getJob(jobKey_);
    return pendingOwner;
  }

  function getAvailableBalance() public view returns(uint256) {
    return getAgentFeeTotal() + address(this).balance;
  }

  function getBalanceRequiredToDeposit() public view returns(uint256 amountToDeposit, uint256 vrfAmountIn, uint256 autoDepositAmountIn) {
    uint256 vrfFullfillJobBalance = getVrfFullfillJobBalance();
    if (vrfFullfillJobBalance <= vrfJobMinBalance) {
      vrfAmountIn = vrfJobMaxDeposit - vrfFullfillJobBalance;
      amountToDeposit += vrfAmountIn;
    }

    uint256 autoDepositJobBalance = getAutoDepositJobBalance();
    if (autoDepositJobBalance <= autoDepositJobMinBalance) {
      autoDepositAmountIn = autoDepositJobMaxDeposit - autoDepositJobBalance;
      amountToDeposit += autoDepositAmountIn;
    }

    uint256 availableBalance = getAvailableBalance();
    if (amountToDeposit > availableBalance) {
      uint256 balanceRatio = availableBalance * 1 ether / amountToDeposit;
      vrfAmountIn = vrfAmountIn * balanceRatio / 1 ether;
      autoDepositAmountIn = autoDepositAmountIn * balanceRatio / 1 ether;
    }
    if (
      (vrfAmountIn < (vrfJobMaxDeposit - vrfJobMinBalance) / 3) &&
      vrfAmountIn < vrfJobMinBalance / 3
    ) {
      vrfAmountIn = 0;
    }
    if (
      (autoDepositAmountIn < (autoDepositJobMaxDeposit - autoDepositJobMinBalance) / 3) &&
      autoDepositAmountIn < autoDepositJobMinBalance / 3
    ) {
      autoDepositAmountIn = 0;
    }
    amountToDeposit = vrfAmountIn + autoDepositAmountIn;
    return (amountToDeposit, vrfAmountIn, autoDepositAmountIn);
  }

  function vrfAutoDepositJobsResolver() external view returns(bool, bytes memory) {
    (uint256 amountToDeposit, ,) = getBalanceRequiredToDeposit();

    return (
      amountToDeposit > 0 || getAssignedKeeperToJob(vrfJobKey) == 0,
      abi.encodeWithSelector(VRFAgentManager.processVrfJobDeposit.selector)
    );
  }

  function getVrfResolverStruct() public view returns(PPAgentV2VRFBased.Resolver memory) {
    return IPPAgentV2Viewer.Resolver({
      resolverAddress: address(consumer),
      resolverCalldata: abi.encodeWithSelector(VRFAgentConsumerInterface.fulfillRandomnessOffchainResolver.selector)
    });
  }

  function getAutoDepositResolverStruct() public view returns(PPAgentV2VRFBased.Resolver memory) {
    return IPPAgentV2Viewer.Resolver({
      resolverAddress: address(this),
      resolverCalldata: abi.encodeWithSelector(VRFAgentManager.vrfAutoDepositJobsResolver.selector)
    });
  }

  /*** INTERNAL METHODS ***/

  function _assignKeeperToJob(bytes32 jobKey_) internal {
    bytes32[] memory assignJobKeys = new bytes32[](1);
    assignJobKeys[0] = jobKey_;
    agent.assignKeeper(assignJobKeys);
  }
}
