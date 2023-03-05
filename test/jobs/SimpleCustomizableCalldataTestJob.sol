// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../contracts/jobs/traits/AgentJob.sol";
import "./ICounter.sol";

contract SimpleCustomizableCalldataTestJob is ICounter, AgentJob {
  event Increment(address pokedBy, uint256 newCurrent);

  uint256 public current;
  bool public returnFalse;
  bool public revertResolver;
  bool public revertExecution;
  bool public revertExecutionWithEmptyReturndata;

  constructor(address agent_) AgentJob (agent_) {
  }

  function setResolverReturnFalse(bool returnFalse_) external {
    returnFalse = returnFalse_;
  }

  function setRevertResolver(bool revertResolver_) external {
    revertResolver = revertResolver_;
  }

  function setRevertExecution(bool revertExecution_) external {
    revertExecution = revertExecution_;
  }

  function setRevertExecutionWithEmptyReturndata(bool revertExecutionWithEmptyReturndata_) external {
    revertExecutionWithEmptyReturndata = revertExecutionWithEmptyReturndata_;
  }

  function myResolver(string calldata pass) external view returns (bool, bytes memory) {
    require(keccak256(abi.encodePacked(pass)) == keccak256(abi.encodePacked("myPass")), "invalid pass");
    if (returnFalse) {
      return (false, bytes(""));
    } else if (revertResolver) {
      revert("forced resolver revert");
    }

    return (true, abi.encodeWithSelector(
      SimpleCustomizableCalldataTestJob.increment.selector,
      5, true, uint24(42), "d-value"
    ));
  }

  function increment(uint256 a, bool b, uint24 c, string calldata d) external onlyAgent {
    if (revertExecutionWithEmptyReturndata) {
      revert();
    }
    if (revertExecution) {
      revert("forced execution revert");
    }
    require(a == 5, "invalid a");
    require(b == true, "invalid b");
    require(c == uint24(42), "invalid c");
    require(keccak256(abi.encodePacked(d)) == keccak256(abi.encodePacked("d-value")), "invalid d");
    current += 1;
    emit Increment(msg.sender, current);
  }

  function increment2() external pure {
    revert("unexpected increment2");
  }
}
