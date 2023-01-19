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

  error InvalidSlashingPeriod();
  error KeeperIsAssignedToJobs(uint256 amountOfJobs);
  error OnlyNextKeeper(uint256 expectedKeeper, uint256 lastExecutedAt, uint256 interval, uint256 slashingInterval, uint256 _now);

  event KeeperJobLock(uint256 indexed keeperId, bytes32 indexed jobKey);
  event KeeperJobUnlock(uint256 indexed keeperId, bytes32 indexed jobKey);

  uint256 public intervalJobSlashingPeriodSeconds;

  // keccak256(jobAddress, id) => nextKeeperId
  mapping(bytes32 => uint256) public jobNextKeeperId;
  // keeperId => (pending jobs)
  mapping(uint256 => EnumerableSet.Bytes32Set) internal keeperLocksByJob;

  constructor(
    address owner_,
    address cvp_,
    uint256 minKeeperCvp_,
    uint256 pendingWithdrawalTimeoutSeconds_,
    uint256 intervalJobSlashingPeriodSeconds_)
    PPAgentV2(owner_, cvp_, minKeeperCvp_, pendingWithdrawalTimeoutSeconds_) {
    _setIntervalJobSlashingPeriodSeconds(intervalJobSlashingPeriodSeconds_);
  }

  /*** AGENT OWNER METHODS ***/
  function setIntervalJobSlashingPeriodSeconds(uint256 seconds_) external onlyOwner {
    _setIntervalJobSlashingPeriodSeconds(seconds_);
  }

  function _setIntervalJobSlashingPeriodSeconds(uint256 seconds_) internal {
    if (seconds_ < 15 seconds || seconds_ > type(uint64).max) {
      revert InvalidSlashingPeriod();
    }
    intervalJobSlashingPeriodSeconds = seconds_;
  }

  /*** GETTERS ***/

  function getKeeperLocksByJob(uint256 keeperId_) external view returns (bytes32[] memory jobKeys) {
    return keeperLocksByJob[keeperId_].values();
  }

  /*** HOOKS ***/
  function _beforeExecute(bytes32 jobKey_, uint256 calleeKeeperId_, uint256 binJob_) internal view override {
    uint256 nextKeeper = jobNextKeeperId[jobKey_];
    uint256 intervalSeconds = (binJob_ << 32) >> 232;

    if (intervalSeconds > 0 && jobNextKeeperId[jobKey_] != calleeKeeperId_) {
      uint256 lastExecutionAt = binJob_ >> 224;
      uint256 nextExecutionTimeoutAt;
      unchecked {
        nextExecutionTimeoutAt = lastExecutionAt + intervalSeconds + intervalJobSlashingPeriodSeconds;
      }
      if (nextExecutionTimeoutAt < block.timestamp) {
        revert OnlyNextKeeper(nextKeeper, lastExecutionAt, intervalSeconds, intervalJobSlashingPeriodSeconds, block.timestamp);
      }
    }
  }

  function _beforeInitiateRedeem(uint256 keeperId_) internal view override {
    uint256 len = keeperLocksByJob[keeperId_].length();
    if (len > 0) {
      revert KeeperIsAssignedToJobs(len);
    }
  }

  function _afterExecute(bytes32 jobKey_, uint256 keeperId_) internal override {
    keeperLocksByJob[keeperId_].remove(jobKey_);
    emit KeeperJobUnlock(keeperId_, jobKey_);

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
}
