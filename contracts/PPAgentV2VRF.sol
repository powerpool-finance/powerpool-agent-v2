// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PPAgentV2Randao } from "./PPAgentV2Randao.sol";

interface VRFAgentConsumerInterface {
  function getPseudoRandom() external returns (uint256);
}

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

  function _getPseudoRandom() internal override returns (uint256) {
    return VRFAgentConsumerInterface(VRFConsumer).getPseudoRandom();
  }
}
