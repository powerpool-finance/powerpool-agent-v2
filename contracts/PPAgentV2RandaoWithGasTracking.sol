// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PPAgentV2RandaoBased} from "./PPAgentV2Randao.sol";
import { IPPGasUsedTracker } from "./PPAgentV2Interfaces.sol";

/**
 * @title PPAgentV2RandaoWithGasTracking
 * @author PowerPool
 */
contract PPAgentV2RandaoWithGasTracking is PPAgentV2RandaoBased {
  address public immutable gasUsedTracker;

  constructor(address gasUsedTracker_, address cvp_) PPAgentV2RandaoBased(cvp_) {
    gasUsedTracker = gasUsedTracker_;
  }

  function _afterExecute(uint256 actualKeeperId_, uint256 gasUsed_) internal override {
    // Even if this call is reverted it should not affect the job execution.
    (bool ok,) = gasUsedTracker.call(
      abi.encodeWithSelector(IPPGasUsedTracker.notify.selector, actualKeeperId_, gasUsed_)
    );
    // Silence compiler warning about ignoring low-level call return value.
    ok;
  }
}
