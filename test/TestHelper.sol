// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./abstract/AbstractTestHelper.sol";
import "../contracts/PPAgentV2.sol";

contract TestHelper is AbstractTestHelper {
  PPAgentV2Based internal agent;

  function _agentViewer() internal override view returns(IPPAgentV2Viewer) {
    return IPPAgentV2Viewer(address(agent));
  }
}
