// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PPAgentV2RandaoBased} from "./PPAgentV2RandaoBased.sol";

import "./interfaces/VRFAgentConsumerInterface.sol";

/**
 * @title PPAgentV2VRFBased
 * @author PowerPool
 */
contract PPAgentV2VRFBased is PPAgentV2RandaoBased {

  address public VRFConsumer;

  event SetVRFConsumer(address consumer);

  error PseudoRandomError();

  constructor(address cvp_) PPAgentV2RandaoBased(cvp_) {

  }

  function setVRFConsumer(address VRFConsumer_) external onlyOwner {
    VRFConsumer = VRFConsumer_;
    emit SetVRFConsumer(VRFConsumer_);
  }

  function _getPseudoRandom() internal override returns (uint256) {
    if (address(VRFConsumer) == address(0)) {
      return super._getPseudoRandom();
    }
    return VRFAgentConsumerInterface(VRFConsumer).getPseudoRandom();
  }
}
