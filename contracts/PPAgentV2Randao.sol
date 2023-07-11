// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { PPAgentV2, ConfigFlags } from "./PPAgentV2.sol";
import "./PPAgentV2Flags.sol";
import "./PPAgentV2Interfaces.sol";

/**
 * @title PPAgentV2Randao
 * @author PowerPool
 */
contract PPAgentV2Randao is IPPAgentV2RandaoViewer, PPAgentV2 {
  using EnumerableSet for EnumerableSet.Bytes32Set;
  using EnumerableSet for EnumerableSet.UintSet;

  error JobHasKeeperAssigned(uint256 keeperId);
  error SlashingEpochBlocksTooLow();
  error InvalidPeriod1();
  error InvalidPeriod2();
  error InvalidSlashingFeeFixedCVP();
  error SlashingBpsGt5000Bps();
  error InvalidStakeDivisor();
  error InactiveKeeper();
  error KeeperIsAssignedToJobs(uint256 amountOfJobs);
  error OnlyCurrentSlasher(uint256 expectedSlasherId);
  error OnlyReservedSlasher(uint256 reservedSlasherId);
  error TooEarlyForSlashing(uint256 now_, uint256 possibleAfter);
  error SlashingNotInitiated();
  error SlashingNotInitiatedExecutionReverted();
  error AssignedKeeperCantSlash();
  error KeeperIsAlreadyActive();
  error KeeperIsAlreadyInactive();
  error CantAssignKeeper();
  error UnexpectedCodeBlock();
  error InitiateSlashingUnexpectedError();
  error UnableToDecodeResolverResponse();
  error NonIntervalJob();
  error JobCheckResolverReturnedFalse();
  error TooEarlyToReinitiateSlashing();
  error JobCheckCanBeExecuted(bytes returndata);
  error JobCheckCanNotBeExecuted(bytes errReason);
  error TooEarlyToRelease(bytes32 jobKey, uint256 period2End);
  error TooEarlyForActivationFinalization(uint256 now, uint256 availableAt);
  error CantRelease();
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

  event DisableKeeper(uint256 indexed keeperId);
  event InitiateKeeperActivation(uint256 indexed keeperId, uint256 canBeFinalizedAt);
  event FinalizeKeeperActivation(uint256 indexed keeperId);
  event InitiateKeeperSlashing(
    bytes32 indexed jobKey,
    uint256 indexed slasherKeeperId,
    bool useResolver,
    uint256 jobSlashingPossibleAfter
  );
  event ExecutionReverted(
    bytes32 indexed jobKey,
    uint256 indexed actualKeeperId,
    bytes executionReturndata,
    uint256 compensation
  );
  event SlashJob(
    bytes32 indexed jobKey,
    uint256 indexed expectedKeeperId,
    uint256 indexed actualKeeperId,
    uint256 fixedSlashAmount,
    uint256 dynamicSlashAmount,
    uint256 slashAmountMissing
  );
  event SetRdConfig(RandaoConfig rdConfig);
  event JobKeeperChanged(bytes32 indexed jobKey, uint256 indexed keeperFrom, uint256 indexed keeperTo);

  IPPAgentV2RandaoViewer.RandaoConfig internal rdConfig;

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
  // keeperId => timestamp
  mapping(uint256 => uint256) public keeperActivationCanBeFinalizedAt;

  EnumerableSet.UintSet internal activeKeepers;

  function getStrategy() public pure override returns (string memory) {
    return "randao";
  }

  function _getJobGasOverhead() internal pure override returns (uint256) {
    return 55_000;
  }

  constructor(address cvp_) PPAgentV2(cvp_) {
  }

  function initializeRandao(
    address owner_,
    uint256 minKeeperCvp_,
    uint256 pendingWithdrawalTimeoutSeconds_,
    RandaoConfig memory rdConfig_) external {
    PPAgentV2.initialize(owner_, minKeeperCvp_, pendingWithdrawalTimeoutSeconds_);
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
    if (rdConfig_.period1 < 15 seconds) {
      revert InvalidPeriod1();
    }
    if (rdConfig_.period2 < 15 seconds) {
      revert InvalidPeriod2();
    }
    if (rdConfig_.slashingFeeFixedCVP > (minKeeperCvp / 2)) {
      revert InvalidSlashingFeeFixedCVP();
    }
    if (rdConfig_.slashingFeeBps > 5000) {
      revert SlashingBpsGt5000Bps();
    }
    if (rdConfig_.stakeDivisor == 0) {
      revert InvalidStakeDivisor();
    }
    emit SetRdConfig(rdConfig_);

    rdConfig = rdConfig_;
  }

  /*** JOB OWNER METHODS ***/
  function assignKeeper(bytes32[] calldata jobKeys_) external {
    _assertExecutionNotLocked();
    for (uint256 i = 0; i < jobKeys_.length; i++) {
      bytes32 jobKey = jobKeys_[i];
      uint256 assignedKeeperId = jobNextKeeperId[jobKey];
      if (assignedKeeperId != 0) {
        revert JobHasKeeperAssigned(assignedKeeperId);
      }
      _assertOnlyJobOwner(jobKey);

      if (!_assignNextKeeperIfRequiredAndUpdateLastExecutedAt(jobKey, 0)) {
        revert CantAssignKeeper();
      }
    }
  }

  /*** KEEPER METHODS ***/
  function releaseJob(bytes32 jobKey_) external {
    uint256 assignedKeeperId = jobNextKeeperId[jobKey_];

    // Job owner can unassign a keeper without any restriction
    if (msg.sender == jobOwners[jobKey_]) {
      _assertExecutionNotLocked();
      _releaseKeeper(jobKey_, assignedKeeperId);
      return;
    }
    // Otherwise this is a keeper's call

    _assertOnlyKeeperAdminOrWorker(assignedKeeperId);

    uint256 binJob = getJobRaw(jobKey_);
    uint256 intervalSeconds = (binJob << 32) >> 232;

    // 1. Release if insufficient credits
    if (_releaseKeeperIfRequired(jobKey_, assignedKeeperId)) {
      return;
    }

    // 2. Check interval timeouts otherwise
    // 2.1 If interval job
    if (intervalSeconds != 0) {
      uint256 lastExecutionAt = binJob >> 224;
      if (lastExecutionAt == 0) {
        lastExecutionAt = jobCreatedAt[jobKey_];
      }
      uint256 period2EndsAt = lastExecutionAt + rdConfig.period1 + rdConfig.period2;
      if (period2EndsAt > block.timestamp) {
        revert TooEarlyToRelease(jobKey_, period2EndsAt);
      } // else can release
    // 2.2 If resolver job
    } else {
      // if slashing process initiated
      uint256 _jobSlashingPossibleAfter = jobSlashingPossibleAfter[jobKey_];
      if (_jobSlashingPossibleAfter != 0) {
        uint256 period2EndsAt = _jobSlashingPossibleAfter + rdConfig.period2;
        if (period2EndsAt > block.timestamp) {
          revert TooEarlyToRelease(jobKey_, period2EndsAt);
        }
      // if no slashing initiated
      } else {
        revert CantRelease();
      }
    }

    _releaseKeeper(jobKey_, assignedKeeperId);
  }

  function disableKeeper(uint256 keeperId_) external {
    _assertOnlyKeeperAdmin(keeperId_);

    if (!keepers[keeperId_].isActive) {
      revert KeeperIsAlreadyInactive();
    }

    _ensureCanReleaseKeeper(keeperId_);
    activeKeepers.remove(keeperId_);
    keepers[keeperId_].isActive = false;

    emit DisableKeeper(keeperId_);
  }

  function initiateKeeperActivation(uint256 keeperId_) external {
    _assertOnlyKeeperAdmin(keeperId_);

    if (keepers[keeperId_].isActive) {
      revert KeeperIsAlreadyActive();
    }

    uint256 canBeFinalizedAt = block.timestamp + rdConfig.keeperActivationTimeoutHours * 1 hours;
    keeperActivationCanBeFinalizedAt[keeperId_] = canBeFinalizedAt;

    emit InitiateKeeperActivation(keeperId_, canBeFinalizedAt);
  }

  function finalizeKeeperActivation(uint256 keeperId_) external {
    _assertOnlyKeeperAdmin(keeperId_);

    uint256 availableAt = keeperActivationCanBeFinalizedAt[keeperId_];
    if (availableAt > block.timestamp) {
      revert TooEarlyForActivationFinalization(block.timestamp, availableAt);
    }

    activeKeepers.add(keeperId_);
    keepers[keeperId_].isActive = true;
    keeperActivationCanBeFinalizedAt[keeperId_] = 0;

    emit FinalizeKeeperActivation(keeperId_);
  }

  function _afterExecutionReverted(
    bytes32 jobKey_,
    CalldataSourceType calldataSource_,
    uint256 actualKeeperId_,
    bytes memory executionResponse_,
    uint256 compensation_
  ) internal override {
    if (calldataSource_ == CalldataSourceType.RESOLVER &&
      jobReservedSlasherId[jobKey_] == 0 && jobSlashingPossibleAfter[jobKey_] == 0) {
      revert SlashingNotInitiatedExecutionReverted();
    }

    _releaseKeeper(jobKey_, actualKeeperId_);

    emit ExecutionReverted(jobKey_, actualKeeperId_, executionResponse_, compensation_);
  }

  function initiateKeeperSlashing(
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
      if (!keeper.isActive) {
        revert InactiveKeeper();
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
      revert AssignedKeeperCantSlash();
    }

    // 5. current slasher
    {
      uint256 currentSlasherId = getCurrentSlasherId(jobKey);
      if (slasherKeeperId_ != currentSlasherId) {
        revert OnlyCurrentSlasher(currentSlasherId);
      }
    }

    // 6. Slashing not initiated yet
    uint256 _jobSlashingPossibleAfter = jobSlashingPossibleAfter[jobKey];
    // if is already initiated
    if (_jobSlashingPossibleAfter != 0 &&
      // but not overdue yet
      (_jobSlashingPossibleAfter + rdConfig.period2) > block.timestamp
      ) {
      revert TooEarlyToReinitiateSlashing();
    }

    // 7. check if could be executed
    if (useResolver_) {
      IPPAgentV2Viewer.Resolver memory resolver = resolvers[jobKey];
      (bool ok, bytes memory result) = address(this).call(
        abi.encodeWithSelector(PPAgentV2Randao.checkCouldBeExecuted.selector, resolver.resolverAddress, resolver.resolverCalldata)
      );
      if (ok) {
        revert UnexpectedCodeBlock();
      }

      bytes4 selector = bytes4(result);

      if (selector == PPAgentV2Randao.JobCheckCanNotBeExecuted.selector) {
        assembly ("memory-safe") {
          revert(add(32, result), mload(result))
        }
      } else if (selector != PPAgentV2Randao.JobCheckCanBeExecuted.selector) {
        revert InitiateSlashingUnexpectedError();
      } // else resolver was executed

      uint256 len;
      assembly ("memory-safe") {
        len := mload(result)
      }
      // We need at least canExecute flag. 32 * 4 + 4.
      if (len < 132) {
        revert UnableToDecodeResolverResponse();
      }

      uint256 canExecute;
      assembly ("memory-safe") {
        canExecute := mload(add(result, 100))
      }
      if (canExecute != 1) {
        revert JobCheckResolverReturnedFalse();
      }
    } else {
      _assertJobCalldataMatchesSelector(binJob, jobCalldata_);
      (bool ok, bytes memory result) = address(this).call(
        abi.encodeWithSelector(PPAgentV2Randao.checkCouldBeExecuted.selector, jobAddress_, jobCalldata_)
      );
      if (ok) {
        revert UnexpectedCodeBlock();
      }
      bytes4 selector = bytes4(result);
      if (selector == PPAgentV2Randao.JobCheckCanNotBeExecuted.selector) {
        assembly ("memory-safe") {
            revert(add(32, result), mload(result))
        }
      } else if (selector != PPAgentV2Randao.JobCheckCanBeExecuted.selector) {
        revert InitiateSlashingUnexpectedError();
      } // else can be executed
    }

    jobReservedSlasherId[jobKey] = slasherKeeperId_;
    _jobSlashingPossibleAfter = block.timestamp + rdConfig.period1;
    jobSlashingPossibleAfter[jobKey] = _jobSlashingPossibleAfter;

    emit InitiateKeeperSlashing(jobKey, slasherKeeperId_, useResolver_, _jobSlashingPossibleAfter);
  }

  /*** OVERRIDES ***/
  function registerAsKeeper(address worker_, uint256 initialDepositAmount_) public override returns (uint256 keeperId) {
    keeperId = super.registerAsKeeper(worker_, initialDepositAmount_);
    activeKeepers.add(keeperId);
  }

  function setJobConfig(
    bytes32 jobKey_,
    bool isActive_,
    bool useJobOwnerCredits_,
    bool assertResolverSelector_
  ) public override {
    uint256 rawJobBefore = getJobRaw(jobKey_);
    super.setJobConfig(jobKey_, isActive_, useJobOwnerCredits_, assertResolverSelector_);
    bool wasActiveBefore = ConfigFlags.check(rawJobBefore, CFG_ACTIVE);
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];

    // inactive => active: assign if required
    if(!wasActiveBefore && isActive_)  {
      _assignNextKeeperIfRequiredAndUpdateLastExecutedAt(jobKey_, expectedKeeperId);
    }

    // job was and remain active, but the credits source has changed: assign or release if required
    if (wasActiveBefore && isActive_ &&
      (ConfigFlags.check(rawJobBefore, CFG_USE_JOB_OWNER_CREDITS) != useJobOwnerCredits_)) {

      if (!_assignNextKeeperIfRequiredAndUpdateLastExecutedAt(jobKey_, expectedKeeperId)) {
        _releaseKeeperIfRequired(jobKey_, expectedKeeperId);
      }
    }

    // active => inactive: unassign
    if (wasActiveBefore && !isActive_) {
      _releaseKeeper(jobKey_, expectedKeeperId);
    }
  }

  /*** HOOKS ***/
  function _beforeExecute(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal view override {
    uint256 nextKeeperId = jobNextKeeperId[jobKey_];
    uint256 intervalSeconds = (binJob_ << 32) >> 232;
    uint256 lastExecutionAt = binJob_ >> 224;

    // if interval task is called by a slasher
    if (intervalSeconds > 0 && nextKeeperId != actualKeeperId_) {
      uint256 nextExecutionTimeoutAt;
      uint256 _lastExecutionAt = lastExecutionAt;
      if (_lastExecutionAt == 0) {
        _lastExecutionAt = jobCreatedAt[jobKey_];
      }
      unchecked {
        nextExecutionTimeoutAt = _lastExecutionAt + intervalSeconds + rdConfig.period1;
      }
      // if it is to early to slash this job
      if (block.timestamp < nextExecutionTimeoutAt) {
        revert OnlyNextKeeper(nextKeeperId, lastExecutionAt, intervalSeconds, rdConfig.period1, block.timestamp);
      }

      uint256 currentSlasherId = getCurrentSlasherId(jobKey_);
      if (actualKeeperId_ != currentSlasherId) {
        revert OnlyCurrentSlasher(currentSlasherId);
      }
    // if a resolver job is called by a slasher
    } else  if (intervalSeconds == 0 && nextKeeperId != actualKeeperId_) {
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

  function _afterDepositJobCredits(bytes32 jobKey_) internal override {
    _assignNextKeeperIfRequiredAndUpdateLastExecutedAt(jobKey_, jobNextKeeperId[jobKey_]);
  }

  function _afterWithdrawJobCredits(bytes32 jobKey_) internal override {
    _releaseKeeperIfRequired(jobKey_, jobNextKeeperId[jobKey_]);
  }

  function _afterExecutionSucceeded(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal override {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];

    uint256 intervalSeconds = (binJob_ << 32) >> 232;

    if (intervalSeconds == 0) {
      jobReservedSlasherId[jobKey_] = 0;
      jobSlashingPossibleAfter[jobKey_] = 0;
    }

    // if slashing
    if (expectedKeeperId != actualKeeperId_) {
      Keeper memory eKeeper = keepers[expectedKeeperId];
      uint256 dynamicSlashAmount = eKeeper.cvpStake * uint256(rdConfig.slashingFeeBps) / 10_000;
      uint256 fixedSlashAmount = uint256(rdConfig.slashingFeeFixedCVP) * 1 ether;
      // NOTICE: totalSlashAmount can't be >= uint88
      uint88 totalSlashAmount = uint88(fixedSlashAmount + dynamicSlashAmount);
      uint256 slashAmountMissing = 0;
      if (totalSlashAmount > eKeeper.cvpStake) {
        unchecked {
          slashAmountMissing = totalSlashAmount - eKeeper.cvpStake;
        }
        totalSlashAmount = eKeeper.cvpStake;
      }
      keepers[expectedKeeperId].cvpStake -= totalSlashAmount;
      keepers[actualKeeperId_].cvpStake += totalSlashAmount;
      emit SlashJob(
        jobKey_, expectedKeeperId, actualKeeperId_, fixedSlashAmount, dynamicSlashAmount, slashAmountMissing
      );
    }

    if (shouldAssignKeeper(jobKey_)) {
      _unassignKeeper(jobKey_, expectedKeeperId);
      _assignNextKeeper(jobKey_, expectedKeeperId);
    } else {
      _releaseKeeper(jobKey_, expectedKeeperId);
    }
  }

  function _beforeInitiateRedeem(uint256 keeperId_) internal view override {
    _ensureCanReleaseKeeper(keeperId_);
  }

  function _afterRegisterJob(bytes32 jobKey_) internal override {
    jobCreatedAt[jobKey_] = block.timestamp;
    _assignNextKeeperIfRequired(jobKey_, 0);
  }

  function _afterAcceptJobTransfer(bytes32 jobKey_) internal override {
    uint256 binJob = getJobRaw(jobKey_);
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];

    if (ConfigFlags.check(binJob, CFG_ACTIVE) && ConfigFlags.check(binJob, CFG_USE_JOB_OWNER_CREDITS)) {
      if (!_assignNextKeeperIfRequiredAndUpdateLastExecutedAt(jobKey_, expectedKeeperId)) {
        _releaseKeeperIfRequired(jobKey_, expectedKeeperId);
      }
    }
  }

  /*** HELPERS ***/
  function _releaseKeeper(bytes32 jobKey_, uint256 keeperId_) internal {
    _unassignKeeper(jobKey_, keeperId_);

    emit JobKeeperChanged(jobKey_, keeperId_, 0);
  }

  // Assumes another keeper will be assigned later within the same transaction
  function _unassignKeeper(bytes32 jobKey_, uint256 keeperId_) internal {
    keeperLocksByJob[keeperId_].remove(jobKey_);

    jobNextKeeperId[jobKey_] = 0;
    jobSlashingPossibleAfter[jobKey_] = 0;
    jobReservedSlasherId[jobKey_] = 0;
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

  function _releaseKeeperIfRequired(bytes32 jobKey_, uint256 keeperId_) internal returns (bool released) {
    uint256 binJob = getJobRaw(jobKey_);
    return _releaseKeeperIfRequiredBinJob(jobKey_, keeperId_, binJob, false);
  }

  function _releaseKeeperIfRequiredBinJob(
    bytes32 jobKey_,
    uint256 keeperId_,
    uint256 binJob_,
    bool checkAlreadyReleased
  ) internal returns (bool released) {
    if ((!checkAlreadyReleased || jobNextKeeperId[jobKey_] != 0) && !_shouldAssignKeeperBin(jobKey_, binJob_)) {
      _releaseKeeper(jobKey_, keeperId_);
      return true;
    }

    return false;
  }

  function _assignNextKeeperIfRequiredAndUpdateLastExecutedAt(
    bytes32 jobKey_,
    uint256 currentKeeperId_
  ) internal returns (bool assigned) {
    assigned = _assignNextKeeperIfRequired(jobKey_, currentKeeperId_);
    if (assigned) {
      uint256 binJob = getJobRaw(jobKey_);
      uint256 intervalSeconds = (binJob << 32) >> 232;
      if (intervalSeconds > 0) {
        uint256 lastExecutionAt = uint32(block.timestamp);
        binJob = binJob & BM_CLEAR_LAST_UPDATE_AT | (lastExecutionAt << 224);
        _updateRawJob(jobKey_, binJob);
      }
    }
  }

  function _assignNextKeeperIfRequired(bytes32 jobKey_, uint256 currentKeeperId_) internal returns (bool assigned) {
    if (currentKeeperId_ == 0 && shouldAssignKeeper(jobKey_)) {
      _assignNextKeeper(jobKey_, currentKeeperId_);
      return true;
    }
    return false;
  }

  function shouldAssignKeeper(bytes32 jobKey_) public view returns (bool) {
    return _shouldAssignKeeperBin(jobKey_, getJobRaw(jobKey_));
  }

  function _shouldAssignKeeperBin(bytes32 jobKey_, uint256 binJob_) internal view returns (bool) {
    uint256 credits;

    if (!ConfigFlags.check(binJob_, CFG_ACTIVE)) {
      return false;
    }

    if (ConfigFlags.check(binJob_, CFG_USE_JOB_OWNER_CREDITS)) {
      credits = jobOwnerCredits[jobOwners[jobKey_]];
    } else {
      credits = (binJob_ << 128) >> 168;
    }

    if (credits >= (uint256(rdConfig.jobMinCreditsFinney) * 0.001 ether)) {
      return true;
    }

    return false;
  }

  function _assignNextKeeper(bytes32 jobKey_, uint256 previousKeeperId_) internal {
    uint256 pseudoRandom = _getPseudoRandom();
    uint256 totalActiveKeepers = activeKeepers.length();
    uint256 _jobMinKeeperCvp = jobMinKeeperCvp[jobKey_];
    uint256 index;
    unchecked {
      index = ((pseudoRandom + uint256(jobKey_)) % totalActiveKeepers);
    }

    while (true) {
      if (index  >= totalActiveKeepers) {
        index = 0;
      }
      uint256 _nextExecutionKeeperId = activeKeepers.at(index);

      uint256 requiredStake = _jobMinKeeperCvp > 0 ? _jobMinKeeperCvp : minKeeperCvp;
      Keeper memory keeper = keepers[_nextExecutionKeeperId];

      if (keeper.isActive && keeper.cvpStake >= requiredStake) {
        jobNextKeeperId[jobKey_] = _nextExecutionKeeperId;

        keeperLocksByJob[_nextExecutionKeeperId].add(jobKey_);
        emit JobKeeperChanged(jobKey_, previousKeeperId_, _nextExecutionKeeperId);
        return;
      }
      index += 1;
    }
  }

  function _checkBaseFee(uint256 binJob_, uint256 cfg_) internal pure override returns (uint256) {
    binJob_;
    cfg_;

    return type(uint256).max;
  }

  function _assertJobCalldataMatchesSelector(uint256 binJob_, bytes memory jobCalldata_) internal pure {
    assembly ("memory-safe") {
      // CFG_ASSERT_RESOLVER_SELECTOR = 0x04 from PPAgentLiteFlags
      if and(binJob_, 0x04) {
        if iszero(eq(
          // actual
          shl(224, shr(224, mload(add(jobCalldata_, 32)))),
          // expected
          shl(224, shr(8, binJob_))
        )) {
          // revert SelectorCheckFailed()
          mstore(0, 0x74ab678100000000000000000000000000000000000000000000000000000000)
          revert(0, 4)
        }
      }
    }
  }

  function _calculateCompensation(
    bool ok_,
    uint256 job_,
    uint256 keeperId_,
    uint256 gasPrice_,
    uint256 gasUsed_
  ) internal view override returns (uint256) {
    if (!ok_) {
      return gasUsed_ * gasPrice_;
    }

    job_; // silence unused param warning
    RandaoConfig memory _rdConfig = rdConfig;

    uint256 stake = keepers[keeperId_].cvpStake;
    // fixedReward field for randao jobs contains _jobMaxCvpStake
    uint256 _jobMaxCvpStake = ((job_ << 64) >> 224) * 1 ether;
    if (_jobMaxCvpStake > 0  && _jobMaxCvpStake < stake) {
      stake = _jobMaxCvpStake;
    }
    if (_rdConfig.agentMaxCvpStake > 0 && _rdConfig.agentMaxCvpStake < stake) {
      stake = _rdConfig.agentMaxCvpStake;
    }

    return (gasPrice_ * gasUsed_ * _rdConfig.jobCompensationMultiplierBps / 10_000) +
      (stake / _rdConfig.stakeDivisor);
  }

  /*** GETTERS ***/

  function getJobsAssignedToKeeper(uint256 keeperId_) external view returns (bytes32[] memory jobKeys) {
    return keeperLocksByJob[keeperId_].values();
  }

  function getJobsAssignedToKeeperLength(uint256 keeperId_) external view returns (uint256) {
    return keeperLocksByJob[keeperId_].length();
  }

  function getCurrentSlasherId(bytes32 jobKey_) public view returns (uint256) {
    return getSlasherIdByBlock(block.number, jobKey_);
  }

  function getActiveKeepersLength() external view returns (uint256) {
    return activeKeepers.length();
  }

  function getActiveKeepers() external view returns (uint256[] memory) {
    return activeKeepers.values();
  }

  function getRdConfig() external view returns (RandaoConfig memory) {
    return rdConfig;
  }

  function getSlasherIdByBlock(uint256 blockNumber_, bytes32 jobKey_) public view returns (uint256) {
    uint256 totalActiveKeepers = activeKeepers.length();
    uint256 index = ((blockNumber_ / rdConfig.slashingEpochBlocks + uint256(jobKey_)) % totalActiveKeepers);
    return activeKeepers.at(index);
  }

  // The function that always reverts
  function checkCouldBeExecuted(address jobAddress_, bytes memory jobCalldata_) external {
    // 1. LOCK
    minKeeperCvp = minKeeperCvp | EXECUTION_IS_LOCKED_FLAG;
    // 2. EXECUTE
    (bool ok, bytes memory result) = jobAddress_.call(jobCalldata_);
    // 3. UNLOCK
    minKeeperCvp = minKeeperCvp ^ EXECUTION_IS_LOCKED_FLAG;

    if (ok) {
      revert JobCheckCanBeExecuted(result);
    } else {
      revert JobCheckCanNotBeExecuted(result);
    }
  }
}
