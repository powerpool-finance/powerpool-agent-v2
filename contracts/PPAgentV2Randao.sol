// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { PPAgentV2, ConfigFlags } from "./PPAgentV2.sol";
import "./PPAgentV2Flags.sol";
import "./PPAgentV2Interfaces.sol";
import "../lib/forge-std/src/console.sol";

/**
 * @title PPAgentV2Randao
 * @author PowerPool
 */
contract PPAgentV2Randao is PPAgentV2 {
  using EnumerableSet for EnumerableSet.Bytes32Set;

  error SlashingEpochBlocksTooLow();
  error InvalidSlashingPeriod();
  error InvalidSlashingValidityPeriod();
  error InvalidSlashingFeeFixedCVP();
  error SlashingBpsGt5000Bps();
  error SetRdConfigInvalidSlashingPeriod();
  error KeeperIsAssignedToJobs(uint256 amountOfJobs);
  error OnlyCurrentSlasher(uint256 expectedSlasherId);
  error OnlyReservedSlasher(uint256 reservedSlasherId);
  error TooEarlyForSlashing(uint256 now_, uint256 possibleAfter);
  error SlashingNotInitiated();
  error KeeperCantSlash();
  error KeeperIsAlreadyActive();
  error KeeperIsAlreadyInactive();
  error UnexpectedBlock();
  error InitiateSlashingUnexpectedError();
  error NonIntervalJob();
  error JobCheckResolverError(bytes errReason);
  error JobCheckResolverReturnedFalse();
  error TooEarlyToReinitiateSlashing();
  error JobCheckCanBeExecuted();
  error JobCheckCanNotBeExecuted(bytes errReason);
  error JobCanNotBeExecuted(bytes errReason);
  event InitiateSlashing(
    bytes32 indexed jobKey,
    uint256 indexed slasherKeeperId,
    bool useResolver,
    uint256 jobSlashingPossibleAfter
  );
  error OnlyNextKeeper(
    uint256 expectedKeeperId,
    uint256 lastExecutedAt,
    uint256 interval,
    uint256 slashingInterval,
    uint256 _now
  );
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
  event SetRdConfig(RandaoConfig rdConfig);
  event KeeperJobLock(uint256 indexed keeperId, bytes32 indexed jobKey);
  event KeeperJobUnlock(uint256 indexed expectedkeeperId, uint256 indexed actualKeeperId, bytes32 indexed jobKey);
  event SetKeeperActiveStatus(uint256 indexed keeperId, bool isActive);

  struct RandaoConfig {
    // max: 2^8 - 1 = 255 blocks
    uint8 slashingEpochBlocks;
    // max: 2^24 - 1 = 16777215 seconds ~ 194 days
    uint24 intervalJobSlashingDelaySeconds;
    // max: 2^16 - 1 = 65535 seconds ~ 18 hours
    uint16 nonIntervalJobSlashingValiditySeconds;
    // in 1 CVP. max: 16_777_215 CVP. The value here is multiplied by 1e18 in calculations.
    uint24 slashingFeeFixedCVP; // should be lte MIN_CVP_STAKE / 2
    // In BPS
    uint16 slashingFeeBps;
  }

  RandaoConfig public rdConfig;

  // keccak256(jobAddress, id) => nextKeeperId
  mapping(bytes32 => uint256) public jobNextKeeperId;
  // keccak256(jobAddress, id) => nextSlasherId
  mapping(bytes32 => uint256) public jobReservedSlasherId;
  // keccak256(jobAddress, id) => timestamp, for non-interval jobs
  mapping(bytes32 => uint256) public jobSlashingPossibleAfter;
  // keccak256(jobAddress, id) => timestamp
  mapping(bytes32 => uint256) public jobCreatedAt;
  // keeperId => (pending jobs)
  mapping(uint256 => EnumerableSet.Bytes32Set) internal keeperLocksByJob;

  function _assertOnlyKeeperWorker(uint256 keeperId_) internal view {
    if (msg.sender != keeperAdmins[keeperId_]) {
      revert OnlyKeeperAdmin();
    }
  }

  function _getJobGasOverhead() internal pure override returns (uint256) {
    return 55_000;
  }

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
    if (rdConfig_.nonIntervalJobSlashingValiditySeconds < rdConfig_.intervalJobSlashingDelaySeconds) {
      revert InvalidSlashingValidityPeriod();
    }
    if (rdConfig.slashingFeeFixedCVP > (minKeeperCvp / 2)) {
      revert InvalidSlashingFeeFixedCVP();
    }
    if (rdConfig.slashingFeeBps > 5000) {
      revert SlashingBpsGt5000Bps();
    }
    emit SetRdConfig(rdConfig);

    rdConfig = rdConfig_;
  }

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

  function initiateSlashing(
    address jobAddress_,
    uint256 jobId_,
    uint256 slasherKeeperId_,
    bool useResolver_,
    bytes memory jobCalldata_
  ) external {
    bytes32 jobKey = getJobKey(jobAddress_, jobId_);
    uint256 binJob = getJobRaw(jobKey);

    // 0. Keeper has sufficient stake
    {
      Keeper memory keeper = keepers[slasherKeeperId_];
      if (keeper.worker != msg.sender) {
        revert KeeperWorkerNotAuthorized();
      }
      if (keeper.cvpStake < minKeeperCvp) {
        revert InsufficientKeeperStake();
      }
    }

    // 1. Assert the job is active
    {
      if (!ConfigFlags.check(binJob, CFG_ACTIVE)) {
        revert InactiveJob(jobKey);
      }
    }

    // 2. Assert job-scoped keeper's minimum CVP deposit
    if (ConfigFlags.check(binJob, CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT) &&
      keepers[slasherKeeperId_].cvpStake < jobMinKeeperCvp[jobKey]) {
      revert InsufficientJobScopedKeeperStake();
    }

    // 3. Not an interval job
    {
      uint256 intervalSeconds = (binJob << 32) >> 232;
      if (intervalSeconds != 0) {
        revert NonIntervalJob();
      }
    }

    // 4. keeper can't slash
    if (jobNextKeeperId[jobKey] == slasherKeeperId_) {
      revert KeeperCantSlash();
    }

    // 5. current slasher
    {
      uint256 currentSlasherId = getCurrentSlasherId();
      if (slasherKeeperId_ != currentSlasherId) {
        revert OnlyCurrentSlasher(currentSlasherId);
      }
    }

    // 6. Slashing not initiated yet
    uint256 _jobSlashingPossibleAfter = jobSlashingPossibleAfter[jobKey];
    // if is already initiated
    if (_jobSlashingPossibleAfter != 0 &&
      // but not overdue yet
      (_jobSlashingPossibleAfter + rdConfig.nonIntervalJobSlashingValiditySeconds) > block.timestamp
      ) {
      revert TooEarlyToReinitiateSlashing();
    }

    // 7. check if could be executed
    if (useResolver_) {
      IPPAgentV2Viewer.Resolver memory resolver = resolvers[jobKey];
      (bool ok, bytes memory result) = resolver.resolverAddress.call(resolver.resolverCalldata);
      if (!ok) {
        revert JobCheckResolverError(result);
      }
      (bool canExecute,) = abi.decode(result, (bool, bytes));
      if (!canExecute) {
        revert JobCheckResolverReturnedFalse();
      } // else can be executed
    } else {
      (bool ok, bytes memory result) = address(this).call(
        abi.encodeWithSelector(PPAgentV2Randao.checkCouldBeExecuted.selector, jobAddress_, jobCalldata_)
      );
      if (ok) {
        revert UnexpectedBlock();
      }
      bytes4 selector = bytes4(result);
      if (selector == PPAgentV2Randao.JobCheckCanNotBeExecuted.selector) {
        assembly {
            revert(add(32, result), mload(result))
        }
      } else if (selector != PPAgentV2Randao.JobCheckCanBeExecuted.selector) {
        revert InitiateSlashingUnexpectedError();
      } // else can be executed
    }

    jobReservedSlasherId[jobKey] = slasherKeeperId_;
    _jobSlashingPossibleAfter = block.timestamp + rdConfig.intervalJobSlashingDelaySeconds;
    jobSlashingPossibleAfter[jobKey] = _jobSlashingPossibleAfter;

    emit InitiateSlashing(jobKey, slasherKeeperId_, useResolver_, _jobSlashingPossibleAfter);
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
    // if a resolver job is called by a slasher
    } else  if (intervalSeconds == 0 && jobNextKeeperId[jobKey_] != actualKeeperId_) {
      uint256 _jobSlashingPossibleAfter = jobSlashingPossibleAfter[jobKey_];
      if (_jobSlashingPossibleAfter == 0) {
        revert SlashingNotInitiated();
      }
      if (_jobSlashingPossibleAfter > block.timestamp) {
        revert TooEarlyForSlashing(block.timestamp, jobSlashingPossibleAfter[jobKey_]);
      }

      uint256 _jobReservedSlasherId = jobReservedSlasherId[jobKey_];
      if (_jobReservedSlasherId != actualKeeperId_) {
        revert OnlyReservedSlasher(_jobReservedSlasherId);
      }
    }
  }

  function _afterExecute(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal override {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
    keeperLocksByJob[expectedKeeperId].remove(jobKey_);
    emit KeeperJobUnlock(expectedKeeperId, actualKeeperId_, jobKey_);

    uint256 intervalSeconds = (binJob_ << 32) >> 232;

    if (intervalSeconds == 0) {
      jobReservedSlasherId[jobKey_] = 0;
      jobSlashingPossibleAfter[jobKey_] = 0;
    }

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

  function _beforeInitiateRedeem(uint256 keeperId_) internal view override {
    _ensureCanReleaseKeeper(keeperId_);
  }

  function _afterRegisterJob(bytes32 jobKey_) internal override {
    _assignNextKeeper(jobKey_);
  }

  function _ensureCanReleaseKeeper(uint256 keeperId_) internal view {
    uint256 len = keeperLocksByJob[keeperId_].length();
    if (len > 0) {
      revert KeeperIsAssignedToJobs(len);
    }
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
      if (_nextExecutionKeeperId  > _lastKeeperId) {
        _nextExecutionKeeperId = 1;
      }

      uint256 requiredStake = _jobMinKeeperCvp > 0 ? _jobMinKeeperCvp : minKeeperCvp;
      Keeper memory keeper = keepers[_nextExecutionKeeperId];

      if (keeper.isActive && keeper.cvpStake >= requiredStake) {
        jobNextKeeperId[_jobKey] = _nextExecutionKeeperId;
        break;
      }
    }

    keeperLocksByJob[_nextExecutionKeeperId].add(_jobKey);
    emit KeeperJobLock(_nextExecutionKeeperId, _jobKey);
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

  // The function that always reverts
  function checkCouldBeExecuted(address jobAddress_, bytes memory jobCalldata_) external {
    (bool ok, bytes memory result) = jobAddress_.call(jobCalldata_);
    if (ok) {
      revert JobCheckCanBeExecuted();
    } else {
      revert JobCheckCanNotBeExecuted(result);
    }
  }
}
