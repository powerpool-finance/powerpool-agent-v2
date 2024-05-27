// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/VRFAgentConsumer.sol";
import "../../lib/forge-std/src/console.sol";

contract MockVRFCoordinator is VRFAgentCoordinatorInterface {
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

  function requestRandomWords(
    address /*agent*/,
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
      words[i] = i + lastRequestId + 54;
    }
    VRFAgentConsumer(requestedByContract).rawFulfillRandomWords(lastRequestId, words);
  }

  function getRequestConfig() external view returns (uint16, uint32, address[] memory) {

  }

  function createSubscription() external returns (uint64 subId) {

  }

  function getSubscription(
    uint64 subId
  ) external view returns (address owner, address[] memory consumers) {

  }

  function requestSubscriptionOwnerTransfer(uint64 subId, address newOwner) external {

  }

  function acceptSubscriptionOwnerTransfer(uint64 subId) external {

  }

  function addConsumer(uint64 subId, address consumer) external {

  }

  function removeConsumer(uint64 subId, address consumer) external {

  }

  function cancelSubscription(uint64 subId) external {

  }

  function pendingRequestExists(uint64 subId) external view returns (bool) {

  }

  function lastPendingRequestId(address consumer, uint64 subId) public view returns (uint256) {

  }

  function createSubscriptionWithConsumer() external override returns (uint64, address) {

  }

  function fulfillRandomnessResolver(uint64 _subId) external view returns (bool, bytes memory) {

  }

  function getCurrentNonce(address consumer, uint64 subId) public view returns (uint64) {

  }
}
