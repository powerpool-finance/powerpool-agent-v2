// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./PPAgentV2Flags.sol";
import { PPAgentV2 } from "./PPAgentV2.sol";
import "../lib/forge-std/src/console.sol";

/**
 * @title PPAgentV2
 * @author PowerPool
 */
contract PPAgentV2Randao is PPAgentV2 {
  using EnumerableSet for EnumerableSet.Bytes32Set;

  error SetRdConfigInvalidSlashingPeriod();
  error KeeperIsAssignedToJobs(uint256 amountOfJobs);
  error OnlyNextKeeper(uint256 expectedKeeperId, uint256 lastExecutedAt, uint256 interval, uint256 slashingInterval, uint256 _now);
  error OnlyCurrentSlasher(uint256 expectedSlasherId);
  error KeeperIsAlreadyActive();
  error KeeperIsAlreadyInactive();
  error InsufficientKeeperStakeToSlash(
    bytes32 jobKey,
    uint256 expectedKeeperId,
    uint256 keeperCurrentStake,
    uint256 amountToSlash
  );

  event SlashIntervalJob(
    bytes32 indexed jobKey,
    uint256 indexed expectedKeeperId,
    uint256 indexed actualKeeperId,
    uint256 fixedSlashAmount,
    uint256 dynamicSlashAmount
  );
  event KeeperJobLock(uint256 indexed keeperId, bytes32 indexed jobKey);
  event KeeperJobUnlock(uint256 indexed expectedkeeperId, uint256 indexed actualKeeperId, bytes32 indexed jobKey);
  event SetKeeperActiveStatus(uint256 indexed keeperId, bool isActive);

  struct RandaoConfig {
    // max: 2^8 - 1 = 255 blocks
    uint8 slashingEpochBlocks;
    // max: 2^24 - 1 = 16777215 hours ~ 194 days
    uint24 intervalJobSlashingDelaySeconds;
    // in 1 CVP. max: 16_777_215 CVP. The value here is multiplied by 1e18 in calculations.
    uint24 slashingFeeFixedCVP; // should be lte MIN_CVP_STAKE / 2
    // In BPS
    uint16 slashingFeeBps;
  }

  RandaoConfig public rdConfig;

  // keccak256(jobAddress, id) => nextKeeperId
  mapping(bytes32 => uint256) public jobNextKeeperId;
  // keccak256(jobAddress, id) => timestamp
  mapping(bytes32 => uint256) internal jobCreatedAt;
  // keeperId => (pending jobs)
  mapping(uint256 => EnumerableSet.Bytes32Set) internal keeperLocksByJob;

  constructor(
    address owner_,
    address cvp_,
    uint256 minKeeperCvp_,
    uint256 pendingWithdrawalTimeoutSeconds_,
    RandaoConfig memory rdConfig_)
    PPAgentV2(owner_, cvp_, minKeeperCvp_, pendingWithdrawalTimeoutSeconds_) {
    _setRdConfig(rdConfig_);
  }

  /*** AGENT OWNER METHODS ***/
  function setRdConfig(RandaoConfig calldata rdConfig_) external onlyOwner {
    _setRdConfig(rdConfig_);
  }

  function _setRdConfig(RandaoConfig memory rdConfig_) internal {
    if (rdConfig_.slashingEpochBlocks < 3) {
      revert SlashingEpochBlocksTooLow();
    }
    if (rdConfig_.intervalJobSlashingDelaySeconds < 15 seconds) {
      revert InvalidSlashingPeriod();
    }
    if (rdConfig.slashingFeeFixedCVP > (minKeeperCvp / 2)) {
      revert InvalidSlashingFeeFixedCVP();
    }
    if (rdConfig.slashingFeeBps > 5000) {
      revert SlashingBpsGt5000Bps();
    }

    rdConfig = rdConfig_;
  }
  error SlashingEpochBlocksTooLow();
  error InvalidSlashingPeriod();
  error InvalidSlashingFeeFixedCVP();
  error SlashingBpsGt5000Bps();

  /*** KEEPER METHODS ***/
  function setKeeperActiveStatus(uint256 keeperId_, bool isActive_) external {
    _assertOnlyKeeperAdmin(keeperId_);

    bool prev = keepers[keeperId_].isActive;
    if (prev && isActive_) {
      revert KeeperIsAlreadyActive();
    }
    if (!prev && !isActive_) {
      revert KeeperIsAlreadyInactive();
    }

    if (isActive_) {
      _ensureCanReleaseKeeper(keeperId_);
    }

    keepers[keeperId_].isActive = isActive_;

    emit SetKeeperActiveStatus(keeperId_, isActive_);
  }

  /*** GETTERS ***/

  function getKeeperLocksByJob(uint256 keeperId_) external view returns (bytes32[] memory jobKeys) {
    return keeperLocksByJob[keeperId_].values();
  }

  function getCurrentSlasherId() public view returns (uint256) {
    return getSlasherIdByBlock(block.number);
  }

  function getSlasherIdByBlock(uint256 blockNumber_) public view returns (uint256) {
    return ((blockNumber_ / rdConfig.slashingEpochBlocks) % lastKeeperId) + 1;
  }

  /*** OVERRIDES ***/
  function registerJob(
    RegisterJobParams calldata params_,
    Resolver calldata resolver_,
    bytes calldata preDefinedCalldata_
  ) public payable override returns (bytes32 jobKey, uint256 jobId){
    (jobKey, jobId) = super.registerJob(params_, resolver_, preDefinedCalldata_);
    jobCreatedAt[jobKey] = block.timestamp;
  }

  /*** HOOKS ***/
  function _beforeExecute(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal view override {
    uint256 nextKeeper = jobNextKeeperId[jobKey_];
    uint256 intervalSeconds = (binJob_ << 32) >> 232;
    uint256 lastExecutionAt = binJob_ >> 224;

    // if interval task is called by a slasher
    if (intervalSeconds > 0 && jobNextKeeperId[jobKey_] != actualKeeperId_) {
      uint256 nextExecutionTimeoutAt;
      uint256 _lastExecutionAt = lastExecutionAt;
      if (_lastExecutionAt == 0) {
        _lastExecutionAt = jobCreatedAt[jobKey_];
      }
      unchecked {
        nextExecutionTimeoutAt = _lastExecutionAt + intervalSeconds + rdConfig.intervalJobSlashingDelaySeconds;
      }
      // if it is to early to slash this job
      if (block.timestamp < nextExecutionTimeoutAt) {
        revert OnlyNextKeeper(nextKeeper, lastExecutionAt, intervalSeconds, rdConfig.intervalJobSlashingDelaySeconds, block.timestamp);
      }

      uint256 currentSlasherId = getCurrentSlasherId();
      if (actualKeeperId_ != currentSlasherId) {
        revert OnlyCurrentSlasher(currentSlasherId);
      }
    // if non-interval task is called by a slasher
    } else  if (intervalSeconds == 0 && jobNextKeeperId[jobKey_] != actualKeeperId_) {

    }
  }

  function _beforeInitiateRedeem(uint256 keeperId_) internal view override {
    _ensureCanReleaseKeeper(keeperId_);
  }

  function _ensureCanReleaseKeeper(uint256 keeperId_) internal view {
    uint256 len = keeperLocksByJob[keeperId_].length();
    if (len > 0) {
      revert KeeperIsAssignedToJobs(len);
    }
  }

  function _afterExecute(bytes32 jobKey_, uint256 actualKeeperId_) internal override {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
    keeperLocksByJob[expectedKeeperId].remove(jobKey_);
    emit KeeperJobUnlock(expectedKeeperId, actualKeeperId_, jobKey_);

    // if slashing
    if (jobNextKeeperId[jobKey_] != actualKeeperId_) {
      Keeper memory eKeeper = keepers[expectedKeeperId];
      uint256 dynamicSlashAmount = eKeeper.cvpStake * uint256(rdConfig.slashingFeeBps) / 10000;
      uint256 fixedSlashAmount = uint256(rdConfig.slashingFeeFixedCVP) * 1 ether;
      // NOTICE: totalSlashAmount can't be >= uint88
      uint88 totalSlashAmount = uint88(fixedSlashAmount + dynamicSlashAmount);
      if (totalSlashAmount > eKeeper.cvpStake) {
        // Actually this block should not be reached, so this is just in case
        revert InsufficientKeeperStakeToSlash(jobKey_, expectedKeeperId, eKeeper.cvpStake, totalSlashAmount);
      }
      keepers[expectedKeeperId].cvpStake -= totalSlashAmount;
      keepers[actualKeeperId_].cvpStake += totalSlashAmount;
      emit SlashIntervalJob(jobKey_, expectedKeeperId, actualKeeperId_, fixedSlashAmount, dynamicSlashAmount);
    }

    _assignNextKeeper(jobKey_);
  }

  function _afterRegisterJob(bytes32 jobKey_) internal override {
    _assignNextKeeper(jobKey_);
  }

  function _getPseudoRandom() internal view returns (uint256) {
    return block.difficulty;
  }

  function _assignNextKeeper(bytes32 _jobKey) internal {
    uint256 pseudoRandom = _getPseudoRandom();
    uint256 _lastKeeperId = lastKeeperId;
    uint256 _jobMinKeeperCvp = jobMinKeeperCvp[_jobKey];
    uint256 _nextExecutionKeeperId;
    unchecked {
      _nextExecutionKeeperId = ((pseudoRandom + uint256(_jobKey)) % _lastKeeperId);
    }

    // TODO: in the case when the loop repeats more than one cycle return an explicit error
    while (true) {
      _nextExecutionKeeperId += 1;
      // TODO: pay attention to activity flag
      if (_nextExecutionKeeperId  > _lastKeeperId) {
        _nextExecutionKeeperId = 1;
      }

      uint256 requiredStake = _jobMinKeeperCvp > 0 ? _jobMinKeeperCvp : minKeeperCvp;

      if (keepers[_nextExecutionKeeperId].cvpStake >= requiredStake) {
        jobNextKeeperId[_jobKey] = _nextExecutionKeeperId;
        break;
      }
    }

    keeperLocksByJob[_nextExecutionKeeperId].add(_jobKey);
    emit KeeperJobLock(_nextExecutionKeeperId, _jobKey);
  }

  function _getJobGasOverhead() internal pure override returns (uint256) {
    return 55_000;
  }
}
