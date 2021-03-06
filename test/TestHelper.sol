// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../contracts/PPAgentV2Flags.sol";
import "../lib/forge-std/src/Test.sol";
import "../contracts/PPAgentV2.sol";

contract TestHelper is Test, PPAgentV2Flags {
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

  uint256 internal constant MIN_DEPOSIT_3000_CVP = 3_000 ether;
  uint256 internal constant CVP_TOTAL_SUPPLY = 100_000_000 ether;

  function setUp() public virtual {}

  function _config(
    bool checkCredits,
    bool acceptMaxBaseFeeLimit,
    bool accrueReward
  ) internal pure returns (uint256 cfg){
    cfg = 0;
    if (checkCredits) cfg = cfg ^ FLAG_CHECK_CREDITS;
    if (acceptMaxBaseFeeLimit) cfg = cfg ^ FLAG_ACCEPT_MAX_BASE_FEE_LIMIT;
    if (accrueReward) cfg = cfg ^ FLAG_ACCRUE_REWARD;
  }

  function _callExecuteHelper(
    IPPAgentV2 agent_,
    address jobAddress_,
    uint256 jobId_,
    uint256 cfg_,
    uint256 keeperId_,
    bytes memory cd_
  ) internal {
    bytes memory fullCalldata = abi.encodePacked(
      AGENT_EXEC,
      jobAddress_,
      uint24(jobId_),
      uint8(cfg_),
      uint24(keeperId_),
      cd_
    );

    assembly {
      // selector(bytes4)+(address(uint160/bytes20)+id(uint24/bytes3))+cfg(uint8/bytes1)+keeperId(uint24/bytes3)
      //         = uint248/bytes31
      let cdSize := add(31, mload(cd_))
      let out := call(gas(), agent_, 0, add(fullCalldata, 32), cdSize, 0, 0)
      switch iszero(out)
      case 1 {
        let len := returndatasize()
        returndatacopy(0, 0, len)
        revert(0, len)
      }
    }
  }
}
