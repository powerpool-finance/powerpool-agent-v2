// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./utils/InitializableOptimized.sol";
import "./utils/OwnableOptimized.sol";
import "./PPAgentV2Flags.sol";
import "./PPAgentV2Interfaces.sol";

library ConfigFlags {
  function check(uint256 cfg, uint256 flag) internal pure returns (bool) {
    return (cfg & flag) != 0;
  }
}

/**
 * @title PPAgentV2Based
 * @author PowerPool
 */
contract PPAgentV2Based is IPPAgentV2Executor, IPPAgentV2Viewer, IPPAgentV2JobOwner, PPAgentV2Flags, InitializableOptimized, OwnableOptimized {
  error NonEOASender();
  error InsufficientKeeperStake();
  error InsufficientJobScopedKeeperStake();
  error KeeperWorkerNotAuthorized();
  error InsufficientJobCredits(uint256 actual, uint256 wanted);
  error InsufficientJobOwnerCredits(uint256 actual, uint256 wanted);
  error InactiveJob(bytes32 jobKey);
  error JobIdOverflow();
  error OnlyJobOwner();
  error JobWithoutOwner();
  error MissingJobAddress();
  error MissingMaxBaseFeeGwei();
  error NoFixedNorPremiumPctReward();
  error CreditsDepositOverflow();
  error StakeAmountOverflow();
  error CreditsWithdrawalUnderflow();
  error MissingDeposit();
  error IntervalNotReached(uint256 lastExecutedAt, uint256 interval, uint256 _now);
  error BaseFeeGtGasPrice(uint256 baseFee, uint256 jobMaxBaseFeeGwei);
  error InvalidCalldataSource();
  error MissingInputCalldata();
  error SelectorCheckFailed();
  error JobCallRevertedWithoutDetails();
  error InsufficientAmountToCoverSlashedStake(uint256 wanted, uint256 actual);
  error AmountGtStake(uint256 wanted, uint256 actualStake, uint256 actualSlashedStake);
  error WithdrawalTimoutNotReached();
  error NoPendingWithdrawal();
  error MissingAmount();
  error WithdrawAmountExceedsAvailable(uint256 wanted, uint256 actual);
  error JobShouldHaveInterval();
  error JobDoesNotSupposedToHaveInterval();
  error InvalidJobAddress();
  error InvalidKeeperId();
  error MissingResolverAddress();
  error NotSupportedByJobCalldataSource();
  error OnlyKeeperAdmin();
  error OnlyKeeperAdminOrJobOwner();
  error OnlyKeeperAdminOrWorker();
  error InvalidMinKeeperCvp();
  error TimeoutTooBig();
  error FeeTooBig();
  error InsufficientAmount();
  error OnlyPendingOwner();
  error WorkerAlreadyAssigned();
  error ExecutionReentrancyLocked();
  error JobCheckResolverReturnedFalse();
  error UnableToDecodeResolverResponse();
  error UnexpectedCodeBlock();
  error JobCheckCanBeExecuted(bytes returndata);
  error JobCheckCanNotBeExecuted(bytes errReason);
  error JobCheckUnexpectedError();
  error JobCheckCalldataError();

  string public constant VERSION = "2.5.0";
  uint256 internal constant MAX_PENDING_WITHDRAWAL_TIMEOUT_SECONDS = 30 days;
  uint256 internal constant MAX_FEE_PPM = 5e4;
  uint256 internal constant FIXED_PAYMENT_MULTIPLIER = 1e12;
  bytes32 internal constant EXECUTION_LOCK_KEY = keccak256("executionLock");

  enum CalldataSourceType {
    SELECTOR,
    PRE_DEFINED,
    RESOLVER,
    OFFCHAIN
  }

  address public immutable CVP;

  event Execute(
    bytes32 indexed jobKey,
    address indexed job,
    uint256 indexed keeperId,
    uint256 gasUsed,
    uint256 baseFee,
    uint256 gasPrice,
    uint256 compensation,
    bytes32 binJobAfter
  );
  event WithdrawFees(address indexed to, uint256 amount);
  event OwnerSlash(uint256 indexed keeperId, address indexed to, uint256 currentAmount, uint256 pendingAmount);
  event RegisterAsKeeper(uint256 indexed keeperId, address indexed keeperAdmin, address indexed keeperWorker);
  event SetWorkerAddress(uint256 indexed keeperId, address indexed prev, address indexed worker);
  event Stake(uint256 indexed keeperId, uint256 amount, address staker);
  event InitiateRedeem(uint256 indexed keeperId, uint256 redeemAmount, uint256 stakeAmount, uint256 slashedStakeAmount);
  event FinalizeRedeem(uint256 indexed keeperId, address indexed beneficiary, uint256 amount);
  event WithdrawCompensation(uint256 indexed keeperId, address indexed to, uint256 amount);
  event DepositJobCredits(bytes32 indexed jobKey, address indexed depositor, uint256 amount, uint256 fee);
  event WithdrawJobCredits(bytes32 indexed jobKey, address indexed owner, address indexed to, uint256 amount);
  event DepositJobOwnerCredits(address indexed jobOwner, address indexed depositor, uint256 amount, uint256 fee);
  event WithdrawJobOwnerCredits(address indexed jobOwner, address indexed to, uint256 amount);
  event InitiateJobTransfer(bytes32 indexed jobKey, address indexed from, address indexed to);
  event AcceptJobTransfer(bytes32 indexed jobKey_, address indexed to_);
  event SetJobConfig(bytes32 indexed jobKey, bool isActive_, bool useJobOwnerCredits_, bool assertResolverSelector_, bool callResolverBeforeExecute_);
  event SetJobResolver(bytes32 indexed jobKey, address resolverAddress, bytes resolverCalldata);
  event SetJobPreDefinedCalldata(bytes32 indexed jobKey, bytes preDefinedCalldata);
  event SetAgentParams(uint256 minKeeperCvp_, uint256 timeoutSeconds_, uint256 feePpm_);
  event RegisterJob(
    bytes32 indexed jobKey,
    address indexed jobAddress,
    uint256 indexed jobId,
    address owner,
    RegisterJobParams params
  );
  event JobUpdate(
    bytes32 indexed jobKey,
    uint256 maxBaseFeeGwei,
    uint256 rewardPct,
    uint256 fixedReward,
    uint256 jobMinCvp,
    uint256 intervalSeconds
  );

  struct Keeper {
    address worker;
    uint88 cvpStake;
    bool isActive;
  }

  struct ExecutionResponsesData {
    bytes resolverResponse;
    bytes executionResponse;
  }

  // WARNING: the minKeeperCvp slot is also used as a non-reentrancy lock
  uint256 internal minKeeperCvp;
  uint256 internal pendingWithdrawalTimeoutSeconds;
  uint256 internal feeTotal;
  uint256 internal feePpm;
  uint256 internal lastKeeperId;

  // keccak256(jobAddress, id) => ethBalance
  mapping(bytes32 => Job) internal jobs;
  // keccak256(jobAddress, id) => customCalldata
  mapping(bytes32 => bytes) internal preDefinedCalldatas;
  // keccak256(jobAddress, id) => minKeeperCvpStake
  mapping(bytes32 => uint256) internal jobMinKeeperCvp;
  // keccak256(jobAddress, id) => owner
  mapping(bytes32 => address) internal jobOwners;
  // keccak256(jobAddress, id) => resolver(address,calldata)
  mapping(bytes32 => Resolver) internal resolvers;
  // keccak256(jobAddress, id) => pendingAddress
  mapping(bytes32 => address) internal jobPendingTransfers;

  // jobAddress => lastIdRegistered(actually uint24)
  mapping(address => uint256) public jobLastIds;

  // keeperId => (worker,CVP stake)
  mapping(uint256 => Keeper) internal keepers;
  // keeperId => admin
  mapping(uint256 => address) internal keeperAdmins;
  // keeperId => the slashed CVP amount
  mapping(uint256 => uint256) internal slashedStakeOf;
  // keeperId => native token compensation
  mapping(uint256 => uint256) internal compensations;

  // keeperId => pendingWithdrawalCVP amount
  mapping(uint256 => uint256) internal pendingWithdrawalAmounts;
  // keeperId => pendingWithdrawalEndsAt timestamp
  mapping(uint256 => uint256) internal pendingWithdrawalEndsAt;

  // owner => credits
  mapping(address => uint256) public jobOwnerCredits;

  // worker => keeperIs
  mapping(address => uint256) public workerKeeperIds;

  bool internal reentrancyLock;

  /*** PSEUDO-MODIFIERS ***/

  function _assertExecutionNotLocked() internal virtual view {
    if (reentrancyLock) {
      revert ExecutionReentrancyLocked();
    }
  }

  function _setExecutionLock(uint value_) internal virtual {
    reentrancyLock = value_ == 1;
  }

  function _assertOnlyJobOwner(bytes32 jobKey_) internal view {
    if (msg.sender != jobOwners[jobKey_]) {
      revert OnlyJobOwner();
    }
  }

  function _assertOnlyKeeperAdmin(uint256 keeperId_) internal view {
    if (msg.sender != keeperAdmins[keeperId_]) {
      revert OnlyKeeperAdmin();
    }
  }

  function _assertOnlyKeeperAdminOrWorker(uint256 keeperId_) internal view {
    if (msg.sender != keeperAdmins[keeperId_] && msg.sender != keepers[keeperId_].worker) {
      revert OnlyKeeperAdminOrWorker();
    }
  }

  function _assertKeeperIdExists(uint256 keeperId_) internal view {
    if (keeperId_ > lastKeeperId) {
      revert InvalidKeeperId();
    }
  }

  function _assertJobParams(uint256 maxBaseFeeGwei_, uint256 fixedReward_, uint256 rewardPct_) internal pure {
    if (maxBaseFeeGwei_ == 0) {
      revert MissingMaxBaseFeeGwei();
    }

    if (fixedReward_ == 0 && rewardPct_ == 0) {
      revert NoFixedNorPremiumPctReward();
    }
  }

  function _assertInterval(uint256 interval_, CalldataSourceType cdSource_) internal pure {
    if (interval_ == 0 &&
      (cdSource_ == CalldataSourceType.SELECTOR || cdSource_ == CalldataSourceType.PRE_DEFINED)) {
      revert JobShouldHaveInterval();
    }
    if (interval_ != 0 && (cdSource_ == CalldataSourceType.RESOLVER || cdSource_ == CalldataSourceType.OFFCHAIN)) {
      revert JobDoesNotSupposedToHaveInterval();
    }
  }

  constructor(address cvp_) {
    CVP = cvp_;
  }

  function initialize(
    address owner_,
    uint256 minKeeperCvp_,
    uint256 pendingWithdrawalTimeoutSeconds_
  ) public initializer {
    _setAgentParams(minKeeperCvp_, pendingWithdrawalTimeoutSeconds_, 0);
    _transferOwnership(owner_);
  }

  /*** HOOKS ***/
  function _beforeExecute(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal view virtual {}
  function _beforeInitiateRedeem(uint256 keeperId_) internal view virtual {}

  function _afterExecute(uint256 actualKeeperId_, uint256 gasUsed_) internal virtual {}
  function _afterExecutionSucceeded(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal virtual {}
  function _afterInitiateRedeem(uint256 keeperId_) internal view virtual {}
  function _afterRegisterJob(bytes32 jobKey_) internal virtual {}
  function _afterDepositJobCredits(bytes32 jobKey_) internal virtual {}
  function _afterWithdrawJobCredits(bytes32 jobKey_) internal virtual {}
  function _afterAcceptJobTransfer(bytes32 jobKey_) internal virtual {}
  function _afterRegisterAsKeeper(uint256 keeperId_) internal virtual {}

  /*** CONSTANT GETTERS ***/
  function getStrategy() public pure virtual returns (string memory) {
    return "basic";
  }

  function _getJobGasOverhead() internal pure virtual returns (uint256) {
    return 40_000;
  }

  /*** UPKEEP INTERFACE ***/

  /**
   * Executes a job.
   * The method arguments a tightly coupled with a custom layout in order to save some gas.
   * The calldata has the following layout :
   *  0x      00000000 1b48315d66ba5267aac8d0ab63c49038b56b1dbc 0000f1 03     00001a    402b2eed11
   *  name    selector jobContractAddress                       jobId  config keeperId  calldata (optional)
   *  size b  bytes4   bytes20                                  uint24 uint8  uint24    any
   *  size u  uint32   uint160                                  bytes3 bytes1 bytes3    any
   *  bits    0-3      4-23                                     24-26  27-27  28-30     31+
   */
  function execute_44g58pv() external {
    uint256 gasStart = gasleft();
    bytes32 jobKey;

    assembly ("memory-safe") {
      // size of (address(bytes20)+id(uint24/bytes3))
      let size := 23

      // keccack256(address+id(uint24)) to memory to generate jobKey
      calldatacopy(0, 4, size)
      jobKey := keccak256(0, size)
    }

    address jobAddress;
    uint256 actualKeeperId;
    uint256 cfg;

    assembly ("memory-safe") {
      // load jobAddress, cfg, and keeperId from calldata to the stack
      jobAddress := shr(96, calldataload(4))
      cfg := shr(248, calldataload(27))
      actualKeeperId := shr(232, calldataload(28))
    }

    uint256 binJob = getJobRaw(jobKey);

    _beforeExecute(jobKey, actualKeeperId, binJob);

    // 0. Keeper has sufficient stake
    {
      uint256 minKeeperCvp_ = minKeeperCvp;
      if (keepers[actualKeeperId].worker != msg.sender) {
        revert KeeperWorkerNotAuthorized();
      }
      if (keepers[actualKeeperId].cvpStake < minKeeperCvp_) {
        revert InsufficientKeeperStake();
      }

      // Execution LOCK
      _setExecutionLock(1);
    }

    // 1. Assert the job is active
    {
      if (!ConfigFlags.check(binJob, CFG_ACTIVE)) {
        revert InactiveJob(jobKey);
      }
    }

    // 2. Assert job-scoped keeper's minimum CVP deposit
    if (ConfigFlags.check(binJob, CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT) && keepers[actualKeeperId].cvpStake < jobMinKeeperCvp[jobKey]) {
      revert InsufficientJobScopedKeeperStake();
    }

    // 3. For interval job ensure the interval has passed
    {
      uint256 intervalSeconds = (binJob << 32) >> 232;

      if (intervalSeconds > 0) {
        uint256 lastExecutionAt = binJob >> 224;
        if (lastExecutionAt > 0) {
          uint256 nextExecutionAt;
          unchecked {
            nextExecutionAt = lastExecutionAt + intervalSeconds;
          }
          if (nextExecutionAt > block.timestamp) {
            revert IntervalNotReached(lastExecutionAt, intervalSeconds, block.timestamp);
          }
        }
      }
    }

    // 4. Ensure gas price fits base fee
    uint256 maxBaseFee = _checkBaseFee(binJob, cfg);

    // 5. Ensure msg.sender is EOA
    if (msg.sender != tx.origin) {
      revert NonEOASender();
    }

    bool ok;

    // Source: Selector
    CalldataSourceType calldataSource = CalldataSourceType((binJob << 56) >> 248);
    if (calldataSource == CalldataSourceType.SELECTOR) {
      bytes4 selector;
      assembly ("memory-safe") {
        selector := shl(224, shr(8, binJob))
      }
      (ok,) = jobAddress.call{ gas: gasleft() - 50_000 }(bytes.concat(abi.encode(selector), jobKey));
    // Source: Bytes
    } else if (calldataSource == CalldataSourceType.PRE_DEFINED) {
      (ok,) = jobAddress.call{ gas: gasleft() - 50_000 }(bytes.concat(preDefinedCalldatas[jobKey], jobKey));
    // Source: Resolver
    } else if (calldataSource == CalldataSourceType.RESOLVER || calldataSource == CalldataSourceType.OFFCHAIN) {
      bytes32 cdataHash;
      if (ConfigFlags.check(binJob, CFG_CALL_RESOLVER_BEFORE_EXECUTE)) {
        cdataHash = _checkJobResolverCall(jobKey);
      }
      assembly ("memory-safe") {
        let cdInCdSize := calldatasize()
        // calldata offset is 31
        let beforeCdSize := 31
        let ptr := mload(0x40)
        if lt(cdInCdSize, beforeCdSize) {
          // revert MissingInputCalldata()
          mstore(ptr, 0x47a0bafb00000000000000000000000000000000000000000000000000000000)
          revert(ptr, 4)
        }
        let cdSize := sub(cdInCdSize, beforeCdSize)
        mstore(0x40, add(add(ptr, cdSize), 0x20))
        calldatacopy(ptr, beforeCdSize, cdSize)
        mstore(add(ptr, cdSize), jobKey)
        // CFG_ASSERT_RESOLVER_SELECTOR = 0x04 from PPAgentLiteFlags
        if and(binJob, 0x04) {
          if iszero(eq(
            // actual
            shl(224, shr(224, calldataload(31))),
            // expected
            shl(224, shr(8, binJob))
          )) {
            // revert SelectorCheckFailed()
            mstore(ptr, 0x74ab678100000000000000000000000000000000000000000000000000000000)
            revert(ptr, 4)
          }
        }
        if and(binJob, 0x10) {
          if eq(calldataSource, 2) {
            let hash := keccak256(ptr, cdSize)
            if iszero(eq(hash, cdataHash)) {
            // revert JobCheckCalldataError()
              mstore(ptr, 0x428ac18600000000000000000000000000000000000000000000000000000000)
              revert(ptr, 4)
            }
          }
        }
        // The remaining gas could not be less than 50_000
        ok := call(sub(gas(), 50000), jobAddress, 0, ptr, add(cdSize, 0x20), 0x0, 0x0)
      }
    } else {
      // Should never be reached
      revert InvalidCalldataSource();
    }

    // Load returned response only if the job call had failed
    bytes memory executionResponse;
    if (!ok) {
      assembly ("memory-safe") {
        let size := returndatasize()
        if gt(size, 0) {
          executionResponse := mload(0x40)
          mstore(executionResponse, size)
          let p := add(executionResponse, 0x20)
          returndatacopy(p, 0, size)
          mstore(0x40, add(executionResponse, add(32, size)))
        }
      }
    }

    // Payout block
    uint256 compensation;
    uint256 gasUsed;
    {
      binJob = getJobRaw(jobKey);
      unchecked {
        gasUsed = gasStart - gasleft();
      }

      {
        uint256 min = block.basefee;
        if (maxBaseFee < min) {
          min = maxBaseFee;
        }

        compensation = calculateCompensation(ok, binJob, actualKeeperId, min, gasUsed);
      }
      {
        bool jobChanged;

        if (ConfigFlags.check(binJob, CFG_USE_JOB_OWNER_CREDITS)) {
          // use job owner credits
          _useJobOwnerCredits(ok, jobKey, compensation);
        } else {
          // use job credits
          uint256 creditsBefore = (binJob << 128) >> 168;
          if (creditsBefore < compensation) {
            if (ok) {
              revert InsufficientJobCredits(creditsBefore, compensation);
            } else {
              compensation = creditsBefore;
            }
          }

          uint256 creditsAfter;
          unchecked {
            creditsAfter = creditsBefore - compensation;
          }
          // update job credits
          binJob = binJob & BM_CLEAR_CREDITS | (creditsAfter << 40);
          jobChanged = true;
        }

        if (ConfigFlags.check(cfg, FLAG_ACCRUE_REWARD)) {
          compensations[actualKeeperId] += compensation;
        } else {
          payable(msg.sender).transfer(compensation);
        }

        // Update lastExecutionAt for interval jobs
        {
          uint256 intervalSeconds = (binJob << 32) >> 232;
          if (intervalSeconds > 0) {
            uint256 lastExecutionAt = uint32(block.timestamp);
            binJob = binJob & BM_CLEAR_LAST_UPDATE_AT | (lastExecutionAt << 224);
            jobChanged = true;
          }
        }

        if (jobChanged) {
          _updateRawJob(jobKey, binJob);
        }
      }
    }

    // Execution UNLOCK
    _setExecutionLock(0);

    if (ok) {
      // Transaction succeeded
      emit Execute(
        jobKey,
        jobAddress,
        actualKeeperId,
        gasUsed,
        block.basefee,
        tx.gasprice,
        compensation,
        bytes32(binJob)
      );

      _afterExecutionSucceeded(jobKey, actualKeeperId, binJob);
    } else {
      // Tx reverted
      _afterExecutionReverted(jobKey, calldataSource, actualKeeperId, executionResponse, compensation);
    }

    _afterExecute(actualKeeperId, gasUsed);
  }

  function _checkJobResolverCall(bytes32 jobKey_) internal returns (bytes32 hash) {
    (bool ok, bytes memory result) = address(this).call(
      abi.encodeWithSelector(PPAgentV2Based.checkCouldBeExecuted.selector, resolvers[jobKey_].resolverAddress, resolvers[jobKey_].resolverCalldata)
    );
    if (ok) {
      revert UnexpectedCodeBlock();
    }

    bytes4 selector = bytes4(result);
    if (selector == PPAgentV2Based.JobCheckCanNotBeExecuted.selector) {
      assembly ("memory-safe") {
        revert(add(32, result), mload(result))
      }
    } else if (selector != PPAgentV2Based.JobCheckCanBeExecuted.selector) {
      revert JobCheckUnexpectedError();
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
      // 5 * 32 + 4
      let dataLen := mload(add(result, 164))
      // starts from 6 * 32 + 4
      hash := keccak256(add(result, 196), dataLen)
    }

    if (canExecute != 1) {
      revert JobCheckResolverReturnedFalse();
    }
    return hash;
  }

  function _getBaseFee(uint256 binJob_) internal pure returns (uint256 maxBaseFee) {
    unchecked {
      maxBaseFee = ((binJob_ << 112) >> 240) * 1 gwei;
    }
  }

  function _checkBaseFee(uint256 binJob_, uint256 cfg_) internal view virtual returns (uint256) {
    uint256 maxBaseFee = _getBaseFee(binJob_);
    if (block.basefee > maxBaseFee && !ConfigFlags.check(cfg_, FLAG_ACCEPT_MAX_BASE_FEE_LIMIT)) {
      revert BaseFeeGtGasPrice(block.basefee, maxBaseFee);
    }
    return maxBaseFee;
  }

  function _afterExecutionReverted(
    bytes32 jobKey_,
    CalldataSourceType cdSource_,
    uint256 actualKeeperId_,
    bytes memory executionResponse_,
    uint256
  ) internal virtual {
    jobKey_;
    actualKeeperId_;
    cdSource_;

    if (executionResponse_.length == 0) {
      revert JobCallRevertedWithoutDetails();
    } else {
      assembly ("memory-safe") {
        revert(add(32, executionResponse_), mload(executionResponse_))
      }
    }
  }

  function calculateCompensation(
    bool ok_,
    uint256 job_,
    uint256 keeperId_,
    uint256 baseFee_,
    uint256 gasUsed_
  ) public view virtual returns (uint256) {
    ok_; // silence unused param warning
    keeperId_; // silence unused param warning
    uint256 fixedReward = (job_ << 64) >> 224;
    uint256 rewardPct = (job_ << 96) >> 240;
    return calculateCompensationPure(rewardPct, fixedReward, baseFee_, gasUsed_);
  }

  function _useJobOwnerCredits(bool ok_, bytes32 jobKey_, uint256 compensation_) internal {
    uint256 jobOwnerCreditsBefore = jobOwnerCredits[jobOwners[jobKey_]];
    if (jobOwnerCreditsBefore < compensation_) {
      if (ok_) {
        revert InsufficientJobOwnerCredits(jobOwnerCreditsBefore, compensation_);
      } else {
        compensation_ = jobOwnerCreditsBefore;
      }
    }

    unchecked {
      jobOwnerCredits[jobOwners[jobKey_]] = jobOwnerCreditsBefore - compensation_;
    }
  }

  /*** JOB OWNER INTERFACE ***/

  /**
   * Registers a new job.
   *
   * Job id is unique counter for a given job address. Up to 2**24-1 jobs per address.
   * Job key is a keccak256(address, jobId).
   * The following options are immutable:
   *  - `params_.jobaddress`
   *  - `params_.calldataSource`
   * If you need to modify one of the immutable options above later consider creating a new job.
   *
   * @param params_ Job-specific params
   * @param resolver_ Resolver details(address, calldata), required only for CALLDATA_SOURCE_RESOLVER
   *                  job type. Use empty values for the other job types.
   * @param preDefinedCalldata_ Calldata to call a job with, required only for CALLDATA_SOURCE_PRE_DEFINED
   *              job type. Keep empty for the other job types.
   */
  function registerJob(
    RegisterJobParams calldata params_,
    Resolver calldata resolver_,
    bytes calldata preDefinedCalldata_
  ) external payable virtual returns (bytes32 jobKey, uint256 jobId){
    jobId = jobLastIds[params_.jobAddress] + 1;

    if (jobId > type(uint24).max) {
      revert JobIdOverflow();
    }

    if (msg.value > type(uint88).max) {
      revert CreditsDepositOverflow();
    }

    if (params_.jobAddress == address(0)) {
      revert MissingJobAddress();
    }

    if (params_.calldataSource > 3) {
      revert InvalidCalldataSource();
    }

    if (params_.jobAddress == address(CVP) || params_.jobAddress == address(this)) {
      revert InvalidJobAddress();
    }

    _assertInterval(params_.intervalSeconds, CalldataSourceType(params_.calldataSource));
    _assertJobParams(params_.maxBaseFeeGwei, params_.fixedReward, params_.rewardPct);
    jobKey = getJobKey(params_.jobAddress, jobId);

    emit RegisterJob(
      jobKey,
      params_.jobAddress,
      jobId,
      msg.sender,
      params_
    );

    if (CalldataSourceType(params_.calldataSource) == CalldataSourceType.PRE_DEFINED) {
      _setJobPreDefinedCalldata(jobKey, preDefinedCalldata_);
    } else if (
      CalldataSourceType(params_.calldataSource) == CalldataSourceType.RESOLVER ||
      CalldataSourceType(params_.calldataSource) == CalldataSourceType.OFFCHAIN
    ) {
      _setJobResolver(jobKey, resolver_);
    }

    {
      bytes4 selector = 0x00000000;
      if (CalldataSourceType(params_.calldataSource) != CalldataSourceType.PRE_DEFINED) {
        selector = params_.jobSelector;
      }

      uint256 config = CFG_ACTIVE;
      if (params_.useJobOwnerCredits) {
        config = config | CFG_USE_JOB_OWNER_CREDITS;
      }
      if (params_.assertResolverSelector) {
        config = config | CFG_ASSERT_RESOLVER_SELECTOR;
      }
      if (params_.jobMinCvp > 0) {
        config = config | CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT;
      }

      jobs[jobKey] = Job({
        config: uint8(config),
        selector: selector,
        credits: 0,
        maxBaseFeeGwei: params_.maxBaseFeeGwei,
        fixedReward: params_.fixedReward,
        rewardPct: params_.rewardPct,
        calldataSource: params_.calldataSource,

        // For interval jobs
        intervalSeconds: params_.intervalSeconds,
        lastExecutionAt: 0
      });
      jobMinKeeperCvp[jobKey] = params_.jobMinCvp;
    }

    jobLastIds[params_.jobAddress] = jobId;
    jobOwners[jobKey] = msg.sender;

    if (msg.value > 0) {
      if (params_.useJobOwnerCredits) {
        _processJobOwnerCreditsDeposit(msg.sender);
      } else {
        _processJobCreditsDeposit(jobKey);
      }
    }

    _afterRegisterJob(jobKey);
  }

  /**
   * Updates a job details.
   *
   * The following options are immutable:
   *  - `jobAddress`
   *  - `job.selector`
   *  - `job.calldataSource`
   * If you need to modify one of the immutable options above later consider creating a new job.
   *
   * @param jobKey_ The job key
   * @param maxBaseFeeGwei_ The maximum basefee in gwei to use for a job compensation
   * @param rewardPct_ The reward premium in pct, where 1 == 1%
   * @param fixedReward_ The fixed reward divided by FIXED_PAYMENT_MULTIPLIER
   * @param jobMinCvp_ The keeper minimal CVP stake to be eligible to execute this job
   * @param intervalSeconds_ The interval for a job execution
   */
  function updateJob(
    bytes32 jobKey_,
    uint16 maxBaseFeeGwei_,
    uint16 rewardPct_,
    uint32 fixedReward_,
    uint256 jobMinCvp_,
    uint24 intervalSeconds_
  ) external {
    _assertOnlyJobOwner(jobKey_);
    _assertExecutionNotLocked();
    _assertJobParams(maxBaseFeeGwei_, fixedReward_, rewardPct_);
    _assertInterval(intervalSeconds_, CalldataSourceType(jobs[jobKey_].calldataSource));

    uint256 cfg = jobs[jobKey_].config;

    if (jobMinCvp_ > 0 && !ConfigFlags.check(jobs[jobKey_].config, CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT)) {
      cfg = cfg | CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT;
    }
    if (jobMinCvp_ == 0 && ConfigFlags.check(jobs[jobKey_].config, CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT)) {
      cfg = cfg ^ CFG_CHECK_KEEPER_MIN_CVP_DEPOSIT;
    }

    jobs[jobKey_].config = uint8(cfg);
    jobMinKeeperCvp[jobKey_] = jobMinCvp_;

    jobs[jobKey_].maxBaseFeeGwei = maxBaseFeeGwei_;
    jobs[jobKey_].rewardPct = rewardPct_;
    jobs[jobKey_].fixedReward = fixedReward_;
    jobs[jobKey_].intervalSeconds = intervalSeconds_;

    emit JobUpdate(jobKey_, maxBaseFeeGwei_, rewardPct_, fixedReward_, jobMinCvp_, intervalSeconds_);
  }

  /**
   * A job owner updates job resolver details.
   *
   * @param jobKey_ The jobKey
   * @param resolver_ The new job resolver details
   */
  function setJobResolver(bytes32 jobKey_, Resolver calldata resolver_) external {
    _assertOnlyJobOwner(jobKey_);
    _assertExecutionNotLocked();

    if (
      CalldataSourceType(jobs[jobKey_].calldataSource) != CalldataSourceType.RESOLVER &&
      CalldataSourceType(jobs[jobKey_].calldataSource) != CalldataSourceType.OFFCHAIN
    ) {
      revert NotSupportedByJobCalldataSource();
    }

    _setJobResolver(jobKey_, resolver_);
  }

  function _setJobResolver(bytes32 jobKey_, Resolver calldata resolver_) internal {
    if (resolver_.resolverAddress == address(0)) {
      revert MissingResolverAddress();
    }
    resolvers[jobKey_] = resolver_;
    emit SetJobResolver(jobKey_, resolver_.resolverAddress, resolver_.resolverCalldata);
  }

  /**
   * A job owner updates pre-defined calldata.
   *
   * @param jobKey_ The jobKey
   * @param preDefinedCalldata_ The new job pre-defined calldata
   */
  function setJobPreDefinedCalldata(bytes32 jobKey_, bytes calldata preDefinedCalldata_) external {
    _assertOnlyJobOwner(jobKey_);
    _assertExecutionNotLocked();

    if (CalldataSourceType(jobs[jobKey_].calldataSource) != CalldataSourceType.PRE_DEFINED) {
      revert NotSupportedByJobCalldataSource();
    }

    _setJobPreDefinedCalldata(jobKey_, preDefinedCalldata_);
  }

  function _setJobPreDefinedCalldata(bytes32 jobKey_, bytes calldata preDefinedCalldata_) internal {
    preDefinedCalldatas[jobKey_] = preDefinedCalldata_;
    emit SetJobPreDefinedCalldata(jobKey_, preDefinedCalldata_);
  }

  /**
   * A job owner updates a job config flag.
   *
   * @param jobKey_ The jobKey
   * @param isActive_ Whether the job is active or not
   * @param useJobOwnerCredits_ The useJobOwnerCredits flag
   * @param assertResolverSelector_ The assertResolverSelector flag
   */
  function setJobConfig(
    bytes32 jobKey_,
    bool isActive_,
    bool useJobOwnerCredits_,
    bool assertResolverSelector_,
    bool callResolverBeforeExecute_
  ) public virtual {
    _assertOnlyJobOwner(jobKey_);
    _assertExecutionNotLocked();
    uint256 newConfig = 0;

    if (isActive_) {
      newConfig = newConfig | CFG_ACTIVE;
    }
    if (useJobOwnerCredits_) {
      newConfig = newConfig | CFG_USE_JOB_OWNER_CREDITS;
    }
    if (assertResolverSelector_) {
      newConfig = newConfig | CFG_ASSERT_RESOLVER_SELECTOR;
    }
    if (callResolverBeforeExecute_) {
      newConfig = newConfig | CFG_CALL_RESOLVER_BEFORE_EXECUTE;
    }

    uint256 job = getJobRaw(jobKey_) & BM_CLEAR_CONFIG | newConfig;
    _updateRawJob(jobKey_, job);

    emit SetJobConfig(jobKey_, isActive_, useJobOwnerCredits_, assertResolverSelector_, callResolverBeforeExecute_);
  }

  function _updateRawJob(bytes32 jobKey_, uint256 job_) internal {
    Job storage job = jobs[jobKey_];
    assembly ("memory-safe") {
      sstore(job.slot, job_)
    }
  }

  /**
   * A job owner initiates the job transfer to a new owner.
   * The actual owner doesn't update until the pending owner accepts the transfer.
   *
   * @param jobKey_ The jobKey
   * @param to_ The new job owner
   */
  function initiateJobTransfer(bytes32 jobKey_, address to_) external {
    _assertOnlyJobOwner(jobKey_);
    _assertExecutionNotLocked();
    jobPendingTransfers[jobKey_] = to_;
    emit InitiateJobTransfer(jobKey_, msg.sender, to_);
  }

  /**
   * A pending job owner accepts the job transfer.
   *
   * @param jobKey_ The jobKey
   */
  function acceptJobTransfer(bytes32 jobKey_) external {
    _assertExecutionNotLocked();

    if (msg.sender != jobPendingTransfers[jobKey_]) {
      revert OnlyPendingOwner();
    }

    jobOwners[jobKey_] = msg.sender;
    delete jobPendingTransfers[jobKey_];

    _afterAcceptJobTransfer(jobKey_);

    emit AcceptJobTransfer(jobKey_, msg.sender);
  }

  /**
   * Top-ups the job credits in NATIVE tokens.
   *
   * @param jobKey_ The jobKey to deposit for
   */
  function depositJobCredits(bytes32 jobKey_) external virtual payable {
    if (msg.value == 0) {
      revert MissingDeposit();
    }

    if (jobOwners[jobKey_] == address(0)) {
      revert JobWithoutOwner();
    }

    _processJobCreditsDeposit(jobKey_);

    _afterDepositJobCredits(jobKey_);
  }

  function _processJobCreditsDeposit(bytes32 jobKey_) internal {
    (uint256 fee, uint256 amount) = _calculateDepositFee();
    uint256 creditsAfter = jobs[jobKey_].credits + amount;
    if (creditsAfter > type(uint88).max) {
      revert CreditsDepositOverflow();
    }

    unchecked {
      feeTotal += fee;
    }
    jobs[jobKey_].credits = uint88(creditsAfter);

    emit DepositJobCredits(jobKey_, msg.sender, amount, fee);
  }

  function _calculateDepositFee() internal view returns (uint256 fee, uint256 amount) {
    fee = msg.value * feePpm / 1e6 /* 100% in ppm */;
    amount = msg.value - fee;
  }

  /**
   * A job owner withdraws the job credits in NATIVE tokens.
   *
   * @param jobKey_ The jobKey
   * @param to_ The address to send NATIVE tokens to
   * @param amount_ The amount to withdraw. Use type(uint256).max for the total available credits withdrawal.
   */
  function withdrawJobCredits(
    bytes32 jobKey_,
    address payable to_,
    uint256 amount_
  ) external {
    uint88 creditsBefore = jobs[jobKey_].credits;
    if (amount_ == type(uint256).max) {
      amount_ = creditsBefore;
    }

    _assertOnlyJobOwner(jobKey_);
    _assertExecutionNotLocked();
    if (amount_ == 0) {
      revert MissingAmount();
    }

    if (creditsBefore < amount_) {
      revert CreditsWithdrawalUnderflow();
    }

    unchecked {
      jobs[jobKey_].credits = creditsBefore - uint88(amount_);
    }

    to_.transfer(amount_);

    emit WithdrawJobCredits(jobKey_, msg.sender, to_, amount_);

    _afterWithdrawJobCredits(jobKey_);
  }

  /**
   * Top-ups the job owner credits in NATIVE tokens.
   *
   * @param for_ The job owner address to deposit for
   */
  function depositJobOwnerCredits(address for_) external payable {
    if (msg.value == 0) {
      revert MissingDeposit();
    }

    _processJobOwnerCreditsDeposit(for_);
  }

  function _processJobOwnerCreditsDeposit(address for_) internal {
    (uint256 fee, uint256 amount) = _calculateDepositFee();

    unchecked {
      feeTotal += fee;
      jobOwnerCredits[for_] += amount;
    }

    emit DepositJobOwnerCredits(for_, msg.sender, amount, fee);
  }

  /**
   * A job owner withdraws the job owner credits in NATIVE tokens.
   *
   * @param to_ The address to send NATIVE tokens to
   * @param amount_ The amount to withdraw. Use type(uint256).max for the total available credits withdrawal.
   */
  function withdrawJobOwnerCredits(address payable to_, uint256 amount_) external {
    uint256 creditsBefore = jobOwnerCredits[msg.sender];
    if (amount_ == type(uint256).max) {
      amount_ = creditsBefore;
    }

    _assertExecutionNotLocked();
    if (amount_ == 0) {
      revert MissingAmount();
    }

    if (creditsBefore < amount_) {
      revert CreditsWithdrawalUnderflow();
    }

    unchecked {
      jobOwnerCredits[msg.sender] = creditsBefore - amount_;
    }

    to_.transfer(amount_);

    emit WithdrawJobOwnerCredits(msg.sender, to_, amount_);
  }

  /*** KEEPER INTERFACE ***/

  /**
   * Actor registers as a keeper.
   * One keeper address could have multiple keeper IDs. Requires at least `minKeepCvp` as an initial CVP deposit.
   *
   * @dev Overflow-safe only for CVP which total supply is less than type(uint96).max
   * @dev Maximum 2^24-1 keepers supported. There is no explicit check for overflow, but the keepers with ID >= 2^24
   *         won't be able to perform upkeep operations.
   *
   * @param worker_ The worker address
   * @param initialDepositAmount_ The initial CVP deposit. Should be no less than `minKeepCvp`
   * @return keeperId The registered keeper ID
   */
  function registerAsKeeper(address worker_, uint256 initialDepositAmount_) public virtual returns (uint256 keeperId) {
    if (workerKeeperIds[worker_] != 0) {
      revert WorkerAlreadyAssigned();
    }
    if (initialDepositAmount_ < minKeeperCvp) {
      revert InsufficientAmount();
    }

    keeperId = ++lastKeeperId;
    keeperAdmins[keeperId] = msg.sender;
    keepers[keeperId] = Keeper(worker_, 0, false);
    workerKeeperIds[worker_] = keeperId;
    emit RegisterAsKeeper(keeperId, msg.sender, worker_);

    _afterRegisterAsKeeper(keeperId);

    _stake(keeperId, initialDepositAmount_);
  }

  /**
   * A keeper updates a keeper worker address
   *
   * @param keeperId_ The keeper ID
   * @param worker_ The new worker address
   */
  function setWorkerAddress(uint256 keeperId_, address worker_) external {
    _assertOnlyKeeperAdmin(keeperId_);
    if (workerKeeperIds[worker_] != 0) {
      revert WorkerAlreadyAssigned();
    }

    address prev = keepers[keeperId_].worker;
    delete workerKeeperIds[prev];
    workerKeeperIds[worker_] = keeperId_;
    keepers[keeperId_].worker = worker_;

    emit SetWorkerAddress(keeperId_, prev, worker_);
  }

  /**
   * A keeper withdraws NATIVE token rewards.
   *
   * @param keeperId_ The keeper ID
   * @param to_ The address to withdraw to
   * @param amount_ The amount to withdraw. Use type(uint256).max for the total available compensation withdrawal.
   */
  function withdrawCompensation(uint256 keeperId_, address payable to_, uint256 amount_) external {
    uint256 available = compensations[keeperId_];
    if (amount_ == type(uint256).max) {
      amount_ = available;
    }

    if (amount_ == 0) {
      revert MissingAmount();
    }
    _assertOnlyKeeperAdminOrWorker(keeperId_);

    if (amount_ > available) {
      revert WithdrawAmountExceedsAvailable(amount_, available);
    }

    unchecked {
      compensations[keeperId_] = available - amount_;
    }

    to_.transfer(amount_);

    emit WithdrawCompensation(keeperId_, to_, amount_);
  }

  /**
   * Deposits CVP for the given keeper ID. The beneficiary receives a derivative erc20 token in exchange of CVP.
   *   Accounts the staking amount on the beneficiary's stakeOf balance.
   *
   * @param keeperId_ The keeper ID
   * @param amount_ The amount to stake
   */
  function stake(uint256 keeperId_, uint256 amount_) external {
    if (amount_ == 0) {
      revert MissingAmount();
    }
    _assertKeeperIdExists(keeperId_);
    _stake(keeperId_, amount_);
  }

  function _stake(uint256 keeperId_, uint256 amount_) internal {
    uint256 amountAfter = keepers[keeperId_].cvpStake + amount_;
    if (amountAfter > type(uint88).max) {
      revert StakeAmountOverflow();
    }
    IERC20(CVP).transferFrom(msg.sender, address(this), amount_);
    keepers[keeperId_].cvpStake += uint88(amount_);

    emit Stake(keeperId_, amount_, msg.sender);
  }

  /**
   * A keeper initiates CVP withdrawal.
   * The given CVP amount needs to go through the cooldown stage. After the cooldown is complete this amount could be
   * withdrawn using `finalizeRedeem()` method.
   * The msg.sender burns the paCVP token in exchange of the corresponding CVP amount.
   * Accumulates the existing pending for withdrawal amounts and re-initiates cooldown period.
   * If there is any slashed amount for the msg.sender, it should be compensated within the first initiateRedeem transaction
   * by burning the equivalent amount of paCVP tokens. The remaining CVP tokens won't be redeemed unless the slashed
   * amount is compensated.
   *
   * @param keeperId_ The keeper ID
   * @param amount_ The amount to cooldown
   * @return pendingWithdrawalAfter The total pending for withdrawal amount
   */
  function initiateRedeem(uint256 keeperId_, uint256 amount_) external returns (uint256 pendingWithdrawalAfter) {
    _assertOnlyKeeperAdmin(keeperId_);
    if (amount_ == 0) {
      revert MissingAmount();
    }
    _beforeInitiateRedeem(keeperId_);

    uint256 stakeOfBefore = keepers[keeperId_].cvpStake;
    uint256 slashedStakeOfBefore = slashedStakeOf[keeperId_];
    uint256 totalStakeBefore = stakeOfBefore + slashedStakeOfBefore;

    // Should burn at least the total slashed stake
    if (amount_ < slashedStakeOfBefore) {
      revert InsufficientAmountToCoverSlashedStake(amount_, slashedStakeOfBefore);
    }

    if (amount_ > totalStakeBefore) {
      revert AmountGtStake(amount_, stakeOfBefore, slashedStakeOfBefore);
    }

    slashedStakeOf[keeperId_] = 0;
    uint256 stakeOfToReduceAmount;
    unchecked {
      stakeOfToReduceAmount = amount_ - slashedStakeOfBefore;
      keepers[keeperId_].cvpStake = uint88(stakeOfBefore - stakeOfToReduceAmount);
      pendingWithdrawalAmounts[keeperId_] += stakeOfToReduceAmount;
    }

    pendingWithdrawalAfter = block.timestamp + pendingWithdrawalTimeoutSeconds;
    pendingWithdrawalEndsAt[keeperId_] = pendingWithdrawalAfter;

    _afterInitiateRedeem(keeperId_);

    emit InitiateRedeem(keeperId_, amount_, stakeOfToReduceAmount, slashedStakeOfBefore);
  }

  /**
   * A keeper finalizes CVP withdrawal and receives the staked CVP tokens.
   *
   * @param keeperId_ The keeper ID
   * @param to_ The address to transfer CVP to
   * @return redeemedCvp The redeemed CVP amount
   */
  function finalizeRedeem(uint256 keeperId_, address to_) external returns (uint256 redeemedCvp) {
    _assertOnlyKeeperAdmin(keeperId_);

    if (pendingWithdrawalEndsAt[keeperId_] > block.timestamp) {
      revert WithdrawalTimoutNotReached();
    }

    redeemedCvp = pendingWithdrawalAmounts[keeperId_];
    if (redeemedCvp == 0) {
      revert NoPendingWithdrawal();
    }

    pendingWithdrawalAmounts[keeperId_] = 0;
    IERC20(CVP).transfer(to_, redeemedCvp);

    emit FinalizeRedeem(keeperId_, to_, redeemedCvp);
  }

  /*** CONTRACT OWNER INTERFACE ***/
  /**
   * Slashes any keeper_ for an amount within keeper's deposit.
   * Penalises a keeper for malicious behaviour like sandwitching upkeep transactions.
   *
   * @param keeperId_ The keeper ID to slash
   * @param to_ The address to send the slashed CVP to
   * @param currentAmount_ The amount to slash from the current keeper.cvpStake balance
   * @param pendingAmount_ The amount to slash from the pendingWithdrawals balance
   */
  function ownerSlash(uint256 keeperId_, address to_, uint256 currentAmount_, uint256 pendingAmount_) public {
    _checkOwner();
    uint256 totalAmount = currentAmount_ + pendingAmount_;
    if (totalAmount == 0) {
      revert MissingAmount();
    }

    if (currentAmount_ > 0) {
      keepers[keeperId_].cvpStake -= uint88(currentAmount_);
      slashedStakeOf[keeperId_] += currentAmount_;
    }

    if (pendingAmount_ > 0) {
      pendingWithdrawalAmounts[keeperId_] -= pendingAmount_;
    }

    IERC20(CVP).transfer(to_, totalAmount);

    emit OwnerSlash(keeperId_, to_, currentAmount_, pendingAmount_);
  }

  /**
   * Owner withdraws all the accrued rewards in native tokens to the provided address.
   *
   * @param to_ The address to send rewards to
   */
  function withdrawFees(address payable to_) external {
    _checkOwner();

    uint256 amount = feeTotal;
    feeTotal = 0;

    to_.transfer(amount);

    emit WithdrawFees(to_, amount);
  }

  /**
   * Owner updates minKeeperCVP value
   *
   * @param minKeeperCvp_ The new minKeeperCVP value
   */
  function setAgentParams(
    uint256 minKeeperCvp_,
    uint256 timeoutSeconds_,
    uint256 feePpm_
  ) external {
    _checkOwner();
    _assertExecutionNotLocked();
    _setAgentParams(minKeeperCvp_, timeoutSeconds_, feePpm_);
  }

  function _setAgentParams(
    uint256 minKeeperCvp_,
    uint256 timeoutSeconds_,
    uint256 feePpm_
  ) internal {
    if (minKeeperCvp_ == 0) {
      revert InvalidMinKeeperCvp();
    }
    if (timeoutSeconds_ > MAX_PENDING_WITHDRAWAL_TIMEOUT_SECONDS) {
      revert TimeoutTooBig();
    }
    if (feePpm_ > MAX_FEE_PPM) {
      revert FeeTooBig();
    }

    minKeeperCvp = minKeeperCvp_;
    pendingWithdrawalTimeoutSeconds = timeoutSeconds_;
    feePpm = feePpm_;

    emit SetAgentParams(minKeeperCvp_, timeoutSeconds_, feePpm_);
  }

  /*** GETTERS ***/

  /**
   * Pure method that calculates keeper compensation based on a dynamic and a fixed multipliers.
   * DANGER: could overflow when used externally
   *
   * @param rewardPct_ The fixed percent. uint16. 0 == 0%, 100 == 100%, 500 == 500%, max 56535 == 56535%
   * @param fixedReward_ The fixed reward. uint32. Always multiplied by 1e15 (FIXED_PAYMENT_MULTIPLIER).
   *                     For ex. 2 == 2e15, 1_000 = 1e18, max 4294967295 == 4_294_967.295e18
   * @param blockBaseFee_ The block.basefee value.
   * @param gasUsed_ The gas used in wei.
   *
   */
  function calculateCompensationPure(
    uint256 rewardPct_,
    uint256 fixedReward_,
    uint256 blockBaseFee_,
    uint256 gasUsed_
  ) public pure returns (uint256) {
    unchecked {
      return (gasUsed_ + _getJobGasOverhead()) * blockBaseFee_ * rewardPct_ / 100
             + fixedReward_ * FIXED_PAYMENT_MULTIPLIER;
    }
  }

  function getKeeperWorkerAndStake(uint256 keeperId_)
    external view returns (
      address worker,
      uint256 currentStake,
      bool isActive
    )
  {
    return (
      keepers[keeperId_].worker,
      keepers[keeperId_].cvpStake,
      keepers[keeperId_].isActive
    );
  }

  function getConfig()
    external view returns (
      uint256 minKeeperCvp_,
      uint256 pendingWithdrawalTimeoutSeconds_,
      uint256 feeTotal_,
      uint256 feePpm_,
      uint256 lastKeeperId_
    )
  {
    return (
      minKeeperCvp,
      pendingWithdrawalTimeoutSeconds,
      feeTotal,
      feePpm,
      lastKeeperId
    );
  }

  function getKeeper(uint256 keeperId_)
    external view returns (
      address admin,
      address worker,
      bool isActive,
      uint256 currentStake,
      uint256 slashedStake,
      uint256 compensation,
      uint256 pendingWithdrawalAmount,
      uint256 pendingWithdrawalEndAt
    )
  {
    pendingWithdrawalEndAt = pendingWithdrawalEndsAt[keeperId_];
    pendingWithdrawalAmount = pendingWithdrawalAmounts[keeperId_];
    compensation = compensations[keeperId_];
    slashedStake = slashedStakeOf[keeperId_];

    currentStake = keepers[keeperId_].cvpStake;
    isActive = keepers[keeperId_].isActive;
    worker = keepers[keeperId_].worker;

    admin = keeperAdmins[keeperId_];
  }

  function getJob(bytes32 jobKey_)
    external view returns (
      address owner,
      address pendingTransfer,
      uint256 jobLevelMinKeeperCvp,
      Job memory details,
      bytes memory preDefinedCalldata,
      Resolver memory resolver
    )
  {
    return (
      jobOwners[jobKey_],
      jobPendingTransfers[jobKey_],
      jobMinKeeperCvp[jobKey_],
      jobs[jobKey_],
      preDefinedCalldatas[jobKey_],
      resolvers[jobKey_]
    );
  }

  /**
   * Returns the principal job data stored in a single EVM slot.
   * @notice To get parsed job data use `getJob()` method instead.
   *
   * The job slot data layout:
   *  0x0000000000000a000000000a002300640000000de0b6b3a7640000d09de08a01
   *  0x      00000000   00000a   00             0000000a    0023      0064           0000000de0b6b3a7640000 d09de08a 01
   *  name    lastExecAt interval calldataSource fixedReward rewardPct maxBaseFeeGwei nativeCredits          selector config bitmask
   *  size b  bytes4     bytes3   bytes4         bytes4      bytes2    bytes2         bytes11                bytes4   bytes1
   *  size u  uint32     uint24   uint8          uint32      uint16    uint16         uint88                 uint32   uint8
   *  bits    0-3        4-6      7-7            8-11        12-13     14-15          16-26                  27-30    31-31
   */
  function getJobRaw(bytes32 jobKey_) public view returns (uint256 rawJob) {
    Job storage job = jobs[jobKey_];
    assembly ("memory-safe") {
      rawJob := sload(job.slot)
    }
  }

  function getJobKey(address jobAddress_, uint256 jobId_) public pure returns (bytes32 jobKey) {
    assembly ("memory-safe") {
      mstore(0, shl(96, jobAddress_))
      mstore(20, shl(232, jobId_))
      jobKey := keccak256(0, 23)
    }
  }

  // The function that always reverts
  function checkCouldBeExecuted(address jobAddress_, bytes memory jobCalldata_) external {
    // 1. LOCK
    _setExecutionLock(1);
    // 2. EXECUTE
    (bool ok, bytes memory result) = jobAddress_.call(jobCalldata_);
    // 3. UNLOCK
    _setExecutionLock(0);

    if (ok) {
      revert JobCheckCanBeExecuted(result);
    } else {
      revert JobCheckCanNotBeExecuted(result);
    }
  }
}
