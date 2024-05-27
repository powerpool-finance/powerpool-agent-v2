// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PPAgentV2VRF } from "./PPAgentV2VRF.sol";
import { IPPAgentV2JobOwner, IPPAgentV2Viewer } from "./PPAgentV2Interfaces.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PPAgentV2Randao
 * @author PowerPool
 */
contract VRFAgentManager is Ownable {

  PPAgentV2VRF public agent;

  bytes32 public vrfJobKey;
  uint256 public vrfJobMinBalance; // balance for 3 executes
  uint256 public vrfJobMaxDeposit; // balance for 9 executes

  bytes32 public autoDepositJobKey;
  uint256 public autoDepositJobMinBalance;
  uint256 public autoDepositJobMaxDeposit;

  error MinMoreThanMax();
  error JobDepositNotRequired();
  error DepositBalanceIsNotEnough();

  constructor(PPAgentV2VRF agent_) {
    agent = agent_;
  }

  receive() external payable { }

  function setVrfConfig(bytes32 vrfJobKey_, uint256 minBalance_, uint256 maxDeposit_) external onlyOwner {
    vrfJobKey = vrfJobKey_;
    vrfJobMinBalance = minBalance_;
    vrfJobMaxDeposit = maxDeposit_;
    if (minBalance_ > maxDeposit_) {
      revert MinMoreThanMax();
    }
  }

  function setAutoDepositConfig(bytes32 autoDepositJobKey_, uint256 minBalance_, uint256 maxDeposit_) external onlyOwner {
    autoDepositJobKey = autoDepositJobKey_;
    autoDepositJobMinBalance = minBalance_;
    autoDepositJobMaxDeposit = maxDeposit_;
    if (minBalance_ > maxDeposit_) {
      revert MinMoreThanMax();
    }
  }

  function registerAutoDepositJob(
    uint16 maxBaseFeeGwei_,
    uint16 rewardPct_,
    uint32 fixedReward_,
    uint256 jobMinCvp_
  ) external payable onlyOwner returns(bytes32 jobKey, uint256 jobId) {
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
    (jobKey, jobId) = agent.registerJob{value: msg.value}(params, getAutoDepositResolverStruct(), new bytes(0));
    autoDepositJobKey = jobKey;
  }

  function processVrfJobDeposit() external {
    (uint256 requiredBalance, uint256 vrfAmountIn, uint256 autoDepositAmountIn) = getBalanceRequiredToDeposit();
    if (requiredBalance == 0) {
      revert JobDepositNotRequired();
    }

    agent.withdrawFees(payable(address(this)));
    uint256 availableBalance = address(this).balance;

    if (availableBalance < requiredBalance) {
      revert DepositBalanceIsNotEnough();
    }

    if (vrfAmountIn != 0) {
      agent.depositJobCredits{value: vrfAmountIn}(vrfJobKey);
    }
    if (autoDepositAmountIn != 0) {
      agent.depositJobCredits{value: autoDepositAmountIn}(autoDepositJobKey);
    }
  }

  function getVrfFullfillJobBalance() public view returns(uint256) {
    (, , , PPAgentV2VRF.Job memory details, , ) = agent.getJob(vrfJobKey);
    return details.credits;
  }

  function getAutoDepositJobBalance() public view returns(uint256) {
    (, , , PPAgentV2VRF.Job memory details, , ) = agent.getJob(autoDepositJobKey);
    return details.credits;
  }

  function isVrfJobDepositRequired() public view returns(bool) {
    return getVrfFullfillJobBalance() <= vrfJobMinBalance;
  }

  function isAutoDepositJobDepositRequired() public view returns(bool) {
    return getAutoDepositJobBalance() <= vrfJobMinBalance;
  }

  function getAgentFeeTotal() public view returns(uint256) {
    (, , uint256 feeTotal, , ) = agent.getConfig();
    return feeTotal;
  }

  function getAvailableBalance() public view returns(uint256) {
    return getAgentFeeTotal() + address(this).balance;
  }

  function getBalanceRequiredToDeposit() public view returns(uint256 amountToDeposit, uint256 vrfAmountIn, uint256 autoDepositAmountIn) {
    uint256 availableBalance = getAvailableBalance();
    if (isVrfJobDepositRequired()) {
      vrfAmountIn = vrfJobMaxDeposit - vrfJobMinBalance;
      amountToDeposit += vrfAmountIn;
    }
    if (isAutoDepositJobDepositRequired()) {
      autoDepositAmountIn = autoDepositJobMaxDeposit - autoDepositJobMinBalance;
      amountToDeposit += autoDepositAmountIn;
    }
    if (amountToDeposit > availableBalance) {
      uint256 balanceRatio = availableBalance * 1 ether / amountToDeposit;
      vrfAmountIn = vrfAmountIn * balanceRatio / 1 ether;
      autoDepositAmountIn = autoDepositAmountIn * balanceRatio / 1 ether;
    }
    if (vrfAmountIn < vrfJobMinBalance / 3) {
      vrfAmountIn = 0;
    }
    if (autoDepositAmountIn < autoDepositJobMinBalance / 3) {
      autoDepositAmountIn = 0;
    }
    amountToDeposit = vrfAmountIn + autoDepositAmountIn;
    return (amountToDeposit, vrfAmountIn, autoDepositAmountIn);
  }

  function vrfAutoDepositJobsResolver() external view returns(bool, bytes memory) {
    (uint256 amountToDeposit, ,) = getBalanceRequiredToDeposit();

    return (
      amountToDeposit > 0,
      abi.encodeWithSelector(VRFAgentManager.processVrfJobDeposit.selector)
    );
  }

  function getAutoDepositResolverStruct() public returns(PPAgentV2VRF.Resolver memory){
    return IPPAgentV2Viewer.Resolver({
      resolverAddress: address(this),
      resolverCalldata: abi.encodeWithSelector(VRFAgentManager.vrfAutoDepositJobsResolver.selector)
    });
  }

  function setAutoDepositJobResolver(bytes32 jobKey_, PPAgentV2VRF.Resolver calldata resolver_) external {
    agent.setJobResolver(autoDepositJobKey, getAutoDepositResolverStruct());
  }

  function acceptAutoDepositJobTransfer() external {
    agent.acceptJobTransfer(autoDepositJobKey);
  }
  
  function initiateAutoDepositJobTransfer(address to_) external {
    agent.initiateJobTransfer(autoDepositJobKey, to_);
  }

  function setAutoDepositJobConfig(
    bool isActive_,
    bool useJobOwnerCredits_,
    bool assertResolverSelector_,
    bool callResolverBeforeExecute_
  ) external {
    agent.setJobConfig(autoDepositJobKey, isActive_, useJobOwnerCredits_, assertResolverSelector_, callResolverBeforeExecute_);
  }

  /*** AGENT OWNER METHODS ***/

  function setRdConfig(PPAgentV2VRF.RandaoConfig calldata rdConfig_) external onlyOwner {
    agent.setRdConfig(rdConfig_);
  }

  function setAgentParams(
    uint256 minKeeperCvp_,
    uint256 timeoutSeconds_,
    uint256 feePpm_
  ) external onlyOwner {
    agent.setAgentParams(minKeeperCvp_, timeoutSeconds_, feePpm_);
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

  function withdrawExcessBalance(address payable to_, uint256 amount_) external onlyOwner {
    to_.transfer(amount_);
  }

  function migrateToNewManager(address newVrfAgentManager_) external onlyOwner {
    agent.transferOwnership(newVrfAgentManager_);
  }
}