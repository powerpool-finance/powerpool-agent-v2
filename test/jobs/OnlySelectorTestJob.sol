// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../contracts/jobs/traits/AgentJob.sol";
import "./ICounter.sol";

contract OnlySelectorTestJob is ICounter, AgentJob {
  event Increment(address pokedBy, uint256 newCurrent);

  uint256 public current;
  bool public revertExecution;
  bool public revertExecutionWithEmptyReturndata;

  constructor(address agent_) AgentJob (agent_) {
  }

  function setRevertExecution(bool revertExecution_) external {
    revertExecution = revertExecution_;
  }

  function setRevertExecutionWithEmptyReturndata(bool revertExecutionWithEmptyReturndata_) external {
    revertExecutionWithEmptyReturndata = revertExecutionWithEmptyReturndata_;
  }

  function myResolver(string calldata pass) external pure returns (bool, bytes memory) {
    require(keccak256(abi.encodePacked(pass)) == keccak256(abi.encodePacked("myPass")), "invalid pass");

    return (true, abi.encode(OnlySelectorTestJob.increment.selector));
  }

  function increment() external onlyAgent {
    if (revertExecutionWithEmptyReturndata) {
      revert();
    }
    if (revertExecution) {
      revert("forced execution revert");
    }
    current += 1;
    emit Increment(msg.sender, current);
  }

  function increment2() external pure {
    revert("unexpected increment2");
  }
}
