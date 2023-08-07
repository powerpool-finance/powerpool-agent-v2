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

  function _afterExecute(uint256 actualKeeperId_, uint256 gasCompensated_) internal override {
    // Even if this call is reverted it should not affect the job execution.
    (bool ok,) = compensationTracker.call(
      abi.encodeWithSelector(IPPCompensationTracker.notify.selector, actualKeeperId_, gasCompensated_)
    );
    // Silence compiler warning about ignoring low-level call return value.
    ok;
  }
}
