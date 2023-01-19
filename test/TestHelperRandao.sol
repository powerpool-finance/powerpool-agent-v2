// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./abstract/AbstractTestHelper.sol";
import "../contracts/PPAgentV2Randao.sol";

contract TestHelperRandao is AbstractTestHelper {
  PPAgentV2Randao internal agent;

  function _agentViewer() internal override view returns(IPPAgentV2Viewer) {
    return IPPAgentV2Viewer(address(agent));
  }
}
