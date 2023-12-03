// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PPAgentV2Randao } from "./PPAgentV2Randao.sol";
import { VRFAgentConsumer } from "./VRFAgentConsumer.sol";

/**
 * @title PPAgentV2VRF
 * @author PowerPool
 */
contract PPAgentV2VRF is PPAgentV2Randao {

  address VRFConsumer;

  event SetVRFConsumer(address consumer);

  error PseudoRandomError();

  constructor(address cvp_) PPAgentV2Randao(cvp_) {

  }

  function setVRFConsumer(address VRFConsumer_) external onlyOwner {
    VRFConsumer = VRFConsumer_;
    emit SetVRFConsumer(VRFConsumer_);
  }

  function _afterExecutionReverted(
    bytes32 jobKey_,
    CalldataSourceType calldataSource_,
    uint256 actualKeeperId_,
    bytes memory executionResponse_,
    uint256 compensation_
  ) internal override {
    super._afterExecutionReverted(jobKey_, calldataSource_, actualKeeperId_, executionResponse_, compensation_);
    VRFAgentConsumer(VRFConsumer).checkAndSendVrfRequest();
  }

  function _afterExecutionSucceeded(bytes32 jobKey_, uint256 actualKeeperId_, uint256 binJob_) internal override {
    super._afterExecutionSucceeded(jobKey_, actualKeeperId_, binJob_);
    VRFAgentConsumer(VRFConsumer).checkAndSendVrfRequest();
  }

  function _getPseudoRandom() internal override view returns (uint256) {
    return VRFAgentConsumer(VRFConsumer).getPseudoRandom();
  }
}
