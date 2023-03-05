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
contract PPAgentV2Randao is PPAgentV2 {
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
  error KeeperNotAssignedToJob(uint256 assignedKeeperId);
  error OnlyCurrentSlasher(uint256 expectedSlasherId);
  error OnlyReservedSlasher(uint256 reservedSlasherId);
  error TooEarlyForSlashing(uint256 now_, uint256 possibleAfter);
  error SlashingNotInitiated();
  error KeeperCantSlash();
  error KeeperIsAlreadyActive();
  error KeeperIsAlreadyInactive();
  error UnexpectedCodeBlock();
  error InitiateSlashingUnexpectedError();
  error NonIntervalJob();
  error JobCheckResolverError(bytes errReason);
  error JobCheckResolverReturnedFalse();
  error TooEarlyToReinitiateSlashing();
  error JobCheckCanBeExecuted();
  error JobCheckCanNotBeExecuted(bytes errReason);
  error TooEarlyToRelease(bytes32 jobKey, uint256 period2End);
  error TooEarlyForActivationFinalization(uint256 now, uint256 availableAt);
  error CantRelease();
  error ExecutionRevertedOnlyNextKeeper(uint256 expectedKeeperId);
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

  event DisableKeeper(uint256 keeperId);
  event InitiateKeeperActivation(uint256 keeperId, uint256 canBeFinalizedAt);
  event FinalizeKeeperActivation(uint256 keeperId);
  event InitiateSlashing(
    bytes32 indexed jobKey,
    uint256 indexed slasherKeeperId,
    bool useResolver,
    uint256 jobSlashingPossibleAfter
  );
  event ExecutionReverted(
    bytes32 indexed jobKey,
    uint256 indexed keeperId,
    bytes executionReturndata,
    bytes resolverReturndata
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
  event JobKeeperUnassigned(bytes32 indexed jobKey);
  event KeeperJobUnlock(uint256 indexed keeperId, bytes32 indexed jobKey);

  // 8+24+16+24+16+16+40+16+32 = 192
  struct RandaoConfig {
    // max: 2^8 - 1 = 255 blocks
    uint8 slashingEpochBlocks;
    // max: 2^24 - 1 = 16777215 seconds ~ 194 days
    uint24 period1;
    // max: 2^16 - 1 = 65535 seconds ~ 18 hours
    uint16 period2;
    // in 1 CVP. max: 16_777_215 CVP. The value here is multiplied by 1e18 in calculations.
    uint24 slashingFeeFixedCVP;
    // In BPS
    uint16 slashingFeeBps;
    // max: 2^16 - 1 = 65535, in calculations is multiplied by 0.001 ether (1 finney),
    // thus the min is 0.001 ether and max is 65.535 ether
    uint16 jobMinCreditsFinney;
    // max 2^40 ~= 1.1e12, in calculations is multiplied by 1 ether
    uint40 agentMaxCvpStake;
    // max: 2^16 - 1 = 65535, where 10_000 is 100%
    uint16 jobCompensationMultiplierBps;
    // max: 2^32 - 1 = 4_294_967_295
    uint32 stakeDivisor;
    // max: 2^8 - 1 = 255 hours, or ~10.5 days
    uint8 keeperActivationTimeoutHours;
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
  // keeperId => timestamp
  mapping(uint256 => uint256) public keeperActivationCanBeFinalizedAt;

  EnumerableSet.UintSet internal activeKeepers;

  function _assertOnlyKeeperWorker(uint256 keeperId_) internal view {
    if (msg.sender != keeperAdmins[keeperId_]) {
      revert OnlyKeeperAdmin();
    }
  }

  function getStrategy() public pure override returns (string memory) {
    return "randao";
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
    emit SetRdConfig(rdConfig);

    rdConfig = rdConfig_;
  }

  /*** JOB OWNER METHODS ***/
  function assignKeeper(bytes32[] calldata jobKeys_) external {
    for (uint256 i = 0; i < jobKeys_.length; i++) {
      bytes32 jobKey = jobKeys_[i];
      uint256 assignedKeeperId = jobNextKeeperId[jobKey];
      if (assignedKeeperId != 0) {
        revert JobHasKeeperAssigned(assignedKeeperId);
      }
      _assertOnlyJobOwner(jobKey);

      _assignNextKeeper(jobKey);
    }
  }

  /*** KEEPER METHODS ***/
  function releaseJob(uint256 keeperId_, bytes32 jobKey_) external {
    _assertOnlyKeeperAdmin(keeperId_);
    uint256 assignedKeeperId = jobNextKeeperId[jobKey_];
    if (assignedKeeperId != keeperId_) {
      revert KeeperNotAssignedToJob(assignedKeeperId);
    }

    uint256 binJob = getJobRaw(jobKey_);
    uint256 intervalSeconds = (binJob << 32) >> 232;

    // 1. Release if insufficient credits
    if (_releaseKeeperIfRequired(jobKey_, keeperId_)) {
      return;
    }

    // 2. Check interval timeouts otherwise
    // 2.1 If interval job
    if (intervalSeconds != 0) {
      uint256 lastExecutionAt = binJob >> 224;
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

    _releaseKeeper(jobKey_, keeperId_);
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

  function _beforeExecutionPayout(
    bool ok_,
    bytes32 jobKey_,
    CalldataSourceType calldataSource_
  ) internal view override returns (bytes memory) {
    // Verify resolver returns true
    if (!ok_ && calldataSource_ == CalldataSourceType.RESOLVER) {
      bytes memory resolverResponse;
      IPPAgentV2Viewer.Resolver memory resolver = resolvers[jobKey_];
      (ok_, resolverResponse) = resolver.resolverAddress.staticcall(resolver.resolverCalldata);
      if (!ok_) {
        revert JobCheckResolverError(resolverResponse);
      }
      (bool canExecute,bytes memory cd) = abi.decode(resolverResponse, (bool, bytes));
      if (!canExecute) {
        revert JobCheckResolverReturnedFalse();
      } // resolver claims else can be executed
      return cd;
    }
    return bytes("");
  }

  function _afterExecutionReverted(
    bytes32 jobKey_,
    uint256 keeperId_,
    ExecutionResponsesData memory eData_
  ) internal override {
    _releaseKeeper(jobKey_, keeperId_);

    emit ExecutionReverted(jobKey_, keeperId_, eData_.executionResponse, eData_.resolverResponse);
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
      revert KeeperCantSlash();
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
        revert UnexpectedCodeBlock();
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
    _jobSlashingPossibleAfter = block.timestamp + rdConfig.period1;
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

    // inactive => active: assign if required
    if(!wasActiveBefore && isActive_)  {
      _assignNextKeeperIfRequired(jobKey_);
    }

    // job was and remain active, but the credits source has changed: assign or release if requried
    if (wasActiveBefore && isActive_ &&
      (ConfigFlags.check(rawJobBefore, CFG_USE_JOB_OWNER_CREDITS) != useJobOwnerCredits_)) {

      if (!_assignNextKeeperIfRequired(jobKey_)) {
        uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
        _releaseKeeperIfRequired(jobKey_, expectedKeeperId);
      }
    }

    // active => inactive: unassign
    if (wasActiveBefore && !isActive_) {
      uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
      _releaseKeeper(jobKey_, expectedKeeperId);
    }
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
        nextExecutionTimeoutAt = _lastExecutionAt + intervalSeconds + rdConfig.period1;
      }
      // if it is to early to slash this job
      if (block.timestamp < nextExecutionTimeoutAt) {
        revert OnlyNextKeeper(nextKeeper, lastExecutionAt, intervalSeconds, rdConfig.period1, block.timestamp);
      }

      uint256 currentSlasherId = getCurrentSlasherId(jobKey_);
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

  function _afterDepositJobCredits(bytes32 jobKey_) internal override {
    _assignNextKeeperIfRequired(jobKey_);
  }

  function _afterWithdrawJobCredits(bytes32 jobKey_) internal override {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
    _releaseKeeperIfRequired(jobKey_, expectedKeeperId);
  }

  function _afterExecutionSucceeded(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal override {
    uint256 expectedKeeperId = jobNextKeeperId[jobKey_];
    _releaseKeeper(jobKey_, expectedKeeperId);

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

  /*** HELPERS ***/
  function _releaseKeeper(bytes32 jobKey_, uint256 keeperId_) internal {
    keeperLocksByJob[keeperId_].remove(jobKey_);

    jobNextKeeperId[jobKey_] = 0;
    jobSlashingPossibleAfter[jobKey_] = 0;
    jobReservedSlasherId[jobKey_] = 0;

    emit KeeperJobUnlock(keeperId_, jobKey_);
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
    uint256 credits = (binJob_ << 128) >> 168;
    if (ConfigFlags.check(binJob_, CFG_USE_JOB_OWNER_CREDITS)) {
      credits = jobOwnerCredits[jobOwners[jobKey_]];
    }

    if ((!checkAlreadyReleased || jobNextKeeperId[jobKey_] != 0) && credits < (uint256(rdConfig.jobMinCreditsFinney) * 0.001 ether)) {
      _releaseKeeper(jobKey_, keeperId_);
      return true;
    }

    return false;
  }

  function _assignNextKeeperIfRequired(bytes32 jobKey_) internal returns (bool assigned) {
    uint256 binJob = getJobRaw(jobKey_);
    uint256 credits = (binJob << 128) >> 168;
    if (ConfigFlags.check(binJob, CFG_USE_JOB_OWNER_CREDITS)) {
      credits = jobOwnerCredits[jobOwners[jobKey_]];
    }

    if (jobNextKeeperId[jobKey_] == 0 && credits >= (uint256(rdConfig.jobMinCreditsFinney) * 0.001 ether)) {
      _assignNextKeeper(jobKey_);
      return true;
    }

    return false;
  }

  function _assignNextKeeper(bytes32 jobKey_) internal {
    if (_releaseKeeperIfRequiredBinJob(jobKey_, jobNextKeeperId[jobKey_], getJobRaw(jobKey_), false)) {
      return;
    }

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
        emit KeeperJobLock(_nextExecutionKeeperId, jobKey_);
        return;
      }
      index += 1;
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

  function getActiveKeepersLength() public view returns (uint256) {
    return activeKeepers.length();
  }

  function getActiveKeepers() public view returns (uint256[] memory) {
    return activeKeepers.values();
  }

  function getSlasherIdByBlock(uint256 blockNumber_, bytes32 jobKey_) public view returns (uint256) {
    uint256 totalActiveKeepers = activeKeepers.length();
    uint256 index = ((blockNumber_ / rdConfig.slashingEpochBlocks + uint256(jobKey_)) % totalActiveKeepers);
    return activeKeepers.at(index);
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
