// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/PPAgentV2Interfaces.sol";

contract MockCompensationTracker is IPPGasUsedTracker {
  bool public doRevert;
  mapping(uint256 => uint256) public accumulatedGasUsed;

  function setDoRevert(bool doRevert_) external {
    doRevert = doRevert_;
  }

  function notify(uint256 keeperId_, uint256 gasUsed_) external {
    if (doRevert) {
      revert("doRevert set to true");
    }
    unchecked {
      accumulatedGasUsed[keeperId_] += gasUsed_;
    }
  }
}
