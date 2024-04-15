// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ChainlinkVRFCoordinatorV2Interface.sol";
import "./VRFAgentConsumer.sol";

/**
 * @title VRFAgentConsumer
 * @author PowerPool
 */
contract ChainlinkVRFAgentConsumer is VRFAgentConsumer {

    constructor(address agent_) VRFAgentConsumer(agent_) {}

    function _requestRandomWords() internal override returns (uint256) {
        return ChainlinkVRFCoordinatorV2Interface(vrfCoordinator).requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            vrfRequestConfirmations,
            vrfCallbackGasLimit,
            VRF_NUM_RANDOM_WORDS
        );
    }
}
