// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PPAgentV2Randao } from "./PPAgentV2Randao.sol";

import "./interfaces/VRFAgentConsumerInterface.sol";

/**
 * @title PPAgentV2VRF
 * @author PowerPool
 */
contract PPAgentV2VRF is PPAgentV2Randao {

  address public VRFConsumer;

  event SetVRFConsumer(address consumer);

  error PseudoRandomError();

  constructor(address cvp_) PPAgentV2Randao(cvp_) {

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
