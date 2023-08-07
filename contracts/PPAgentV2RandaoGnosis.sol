// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { PPAgentV2Randao } from "./PPAgentV2Randao.sol";
import { IPPCompensationTracker } from "./PPAgentV2Interfaces.sol";

/**
 * @title PPAgentV2RandaoGnosis
 * @author PowerPool
 */
contract PPAgentV2RandaoGnosis is PPAgentV2Randao {
  address public immutable compensationTracker;

  constructor(address compensationTracker_, address cvp_) PPAgentV2Randao(cvp_) {
    compensationTracker = compensationTracker_;
  }

  function _afterExecute(uint256 actualKeeperId_, uint256 compensation_) internal override {
    IPPCompensationTracker(compensationTracker).notify(actualKeeperId_, compensation_);
  }
}
