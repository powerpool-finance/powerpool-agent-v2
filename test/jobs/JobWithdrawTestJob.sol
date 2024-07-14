// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../contracts/jobs/traits/AgentJob.sol";
import "../../contracts/PPAgentV2.sol";
import "./ICounter.sol";

contract JobWithdrawTestJob is AgentJob {
  constructor(address agent_) AgentJob (agent_) {
  }

  function myResolver(bytes32 jobKey_) external pure returns (bool, bytes memory) {
    return (true, abi.encodeWithSelector(this.execute.selector, jobKey_));
  }

  function execute(bytes32 jobKey_) external onlyAgent {
    PPAgentV2Based(agent).withdrawJobCredits(jobKey_, payable(this), type(uint256).max);
  }

  function acceptJobTransfer(bytes32 jobKey_) external {
    PPAgentV2Based(agent).acceptJobTransfer(jobKey_);
  }

  receive() external payable {
  }
}
