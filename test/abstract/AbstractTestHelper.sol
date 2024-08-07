// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/PPAgentV2Flags.sol";
import { ConfigFlags } from "../../contracts/PPAgentV2Based.sol";
import "../../lib/forge-std/src/Test.sol";
import "./../mocks/MockCVP.sol";
import "../../contracts/PPAgentV2Interfaces.sol";

abstract contract AbstractTestHelper is Test, PPAgentV2Flags {
  address constant internal owner = address(0x8888888888888888888888888888888888888888);
  address constant internal slasher = address(0x9999999999999999999999999999999999999999);

  address payable constant internal alice = payable(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
  address payable constant internal bob = payable(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
  address constant internal charlie = address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC);
  address constant internal keeperWorker = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
  address constant internal keeperAdmin = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

  bytes4 internal constant AGENT_EXEC = 0x00000000;
  bytes4 internal constant ZERO_SELECTOR = 0x00000000;
  bytes4 internal constant NON_ZERO_SELECTOR = 0x12345678;

  uint8 internal constant CALLDATA_SOURCE_SELECTOR = 0;
  uint8 internal constant CALLDATA_SOURCE_PRE_DEFINED = 1;
  uint8 internal constant CALLDATA_SOURCE_RESOLVER = 2;
  uint8 internal constant CALLDATA_SOURCE_OFFCHAIN = 3;

  uint256 internal constant MIN_DEPOSIT_3000_CVP = 3_000 ether;
  uint256 internal constant CVP_TOTAL_SUPPLY = 100_000_000 ether;

  MockCVP internal cvp;

  function _agentViewer() internal virtual view returns(IPPAgentV2Viewer);

  function setUp() public virtual {}

  function _config(
    bool acceptMaxBaseFeeLimit,
    bool accrueReward
  ) internal pure returns (uint256 cfg){
    cfg = 0;
    if (acceptMaxBaseFeeLimit) cfg = cfg ^ FLAG_ACCEPT_MAX_BASE_FEE_LIMIT;
    if (accrueReward) cfg = cfg ^ FLAG_ACCRUE_REWARD;
  }

  function _keeperCount() internal view returns (uint256) {
    (,,,,uint256 lastKeeperId) = _agentViewer().getConfig();
    return lastKeeperId;
  }

  function _stakeOf(uint256 keeperId_) internal view returns (uint256) {
    (,,,uint256 stake,,,,) = _agentViewer().getKeeper(keeperId_);
    return stake;
  }

  function _slashedStakeOf(uint256 keeperId_) internal view returns (uint256) {
    (,,,,uint256 slashedStake,,,) = _agentViewer().getKeeper(keeperId_);
    return slashedStake;
  }

  function _compensationOf(uint256 keeperId_) internal view returns (uint256) {
    (,,,,,uint256 compensation,,) = _agentViewer().getKeeper(keeperId_);
    return compensation;
  }

  function _pendingWithdrawalAmountOf(uint256 keeperId_) internal view returns (uint256) {
    (,,,,,,uint256 amount,) = _agentViewer().getKeeper(keeperId_);
    return amount;
  }

  function _pendingWithdrawalEndsAt(uint256 keeperId_) internal view returns (uint256) {
    (,,,,,,,uint256 endsAt) = _agentViewer().getKeeper(keeperId_);
    return endsAt;
  }

  function _workerOf(uint256 keeperId_) internal view returns (address) {
    (,address worker,,,,,,) = _agentViewer().getKeeper(keeperId_);
    return worker;
  }

  function _keeperIsActive(uint256 keeperId_) internal view returns (bool) {
    (,,bool isActive,,,,,) = _agentViewer().getKeeper(keeperId_);
    return isActive;
  }

  function _jobLastExecutionAt(bytes32 jobKey_) internal view returns (uint256) {
    (,,,IPPAgentV2Viewer.Job memory details,,) = _agentViewer().getJob(jobKey_);
    require(details.intervalSeconds > 0, "Not an interval job");
    return uint256(details.lastExecutionAt);
  }

  function _jobNextExecutionAt(bytes32 jobKey_) internal view returns (uint256) {
    (,,,IPPAgentV2Viewer.Job memory details,,) = _agentViewer().getJob(jobKey_);
    require(details.intervalSeconds > 0, "Not an interval job");
    return (uint256(details.lastExecutionAt) + uint256(details.intervalSeconds));
  }

  function _jobOwner(bytes32 jobKey_) internal view returns (address) {
    (address jobOwner,,,,,) = _agentViewer().getJob(jobKey_);
    return jobOwner;
  }

  function _jobPendingOwner(bytes32 jobKey_) internal view returns (address) {
    (,address pendingOwner,,,,) = _agentViewer().getJob(jobKey_);
    return pendingOwner;
  }

  function _jobMinKeeperCvp(bytes32 jobKey_) internal view returns (uint256) {
    (,,uint256 jobMinKeeperCvp,,,) = _agentViewer().getJob(jobKey_);
    return jobMinKeeperCvp;
  }

  function _jobDetails(bytes32 jobKey_) internal view returns (IPPAgentV2Viewer.Job memory) {
    (,,,IPPAgentV2Viewer.Job memory details,,) = _agentViewer().getJob(jobKey_);
    return details;
  }

  function _jobIsActive(bytes32 jobKey_) internal view returns (bool) {
    (,,,IPPAgentV2Viewer.Job memory details,,) = _agentViewer().getJob(jobKey_);
    return ConfigFlags.check(details.config, CFG_ACTIVE);
  }

  function _jobCredits(bytes32 jobKey_) internal view returns (uint256) {
    (,,,IPPAgentV2Viewer.Job memory details,,) = _agentViewer().getJob(jobKey_);
    return details.credits;
  }

  function _jobPreDefinedCalldata(bytes32 jobKey_) internal view returns (bytes memory) {
    (,,,,bytes memory preDefinedCalldata,) = _agentViewer().getJob(jobKey_);
    return preDefinedCalldata;
  }

  function _jobResolver(bytes32 jobKey_) internal view returns (IPPAgentV2Viewer.Resolver memory) {
    (,,,,,IPPAgentV2Viewer.Resolver memory resolver) = _agentViewer().getJob(jobKey_);
    return resolver;
  }

  function _globalMinKeeperCvp() internal view returns (uint256) {
    (uint256 minKeeperCvp,,,,) = _agentViewer().getConfig();
    return minKeeperCvp;
  }

  function _callExecuteHelper(
    IPPAgentV2Executor agent_,
    address jobAddress_,
    uint256 jobId_,
    uint256 cfg_,
    uint256 keeperId_,
    bytes memory cd_
  ) internal {
    _callExecuteHelperWithGas(agent_, jobAddress_, jobId_, cfg_, keeperId_, gasleft(), cd_);
  }

  function _encodeExecuteCalldata(
    address jobAddress_,
    uint256 jobId_,
    uint256 cfg_,
    uint256 keeperId_,
    bytes memory cd_
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(
      AGENT_EXEC,
      jobAddress_,
      uint24(jobId_),
      uint8(cfg_),
      uint24(keeperId_),
      cd_
    );
  }

  function _callExecuteHelperWithGas(
    IPPAgentV2Executor agent_,
    address jobAddress_,
    uint256 jobId_,
    uint256 cfg_,
    uint256 keeperId_,
    uint256 gasAmount_,
    bytes memory cd_
  ) internal {
    bytes memory fullCalldata = _encodeExecuteCalldata(
      jobAddress_,
      jobId_,
      cfg_,
      keeperId_,
      cd_
    );

    assembly {
      // selector(bytes4)+(address(uint160/bytes20)+id(uint24/bytes3))+cfg(uint8/bytes1)+keeperId(uint24/bytes3)
      //         = uint248/bytes31
      let cdSize := add(31, mload(cd_))
      let out := call(gasAmount_, agent_, 0, add(fullCalldata, 32), cdSize, 0, 0)
      switch iszero(out)
      case 1 {
        let len := returndatasize()
        returndatacopy(0, 0, len)
        revert(0, len)
      }
    }
  }
}
