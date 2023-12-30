// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/VRFAgentConsumer.sol";

contract MockVRFCoordinator is VRFCoordinatorV2Interface {
  address public requestedByContract;
  uint256 public requestedNumWords;
  uint256 public lastRequestId;

  function requestRandomWords(
    bytes32 /*keyHash*/,
    uint64 /*subId*/,
    uint16 /*minimumRequestConfirmations*/,
    uint32 /*callbackGasLimit*/,
    uint32 numWords
  ) external returns (uint256 requestId) {
    requestedByContract = msg.sender;
    lastRequestId++;
    requestedNumWords = numWords;
    return lastRequestId;
  }

  function callFulfill() external {
    uint256[] memory words = new uint256[](requestedNumWords);
    for (uint256 i = 0; i < words.length; i++) {
      words[i] = i + lastRequestId + 10;
    }
    VRFAgentConsumer(requestedByContract).rawFulfillRandomWords(lastRequestId, words);
  }
}
