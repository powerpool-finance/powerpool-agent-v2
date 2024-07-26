// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/VRFAgentConsumer.sol";
import "../../contracts/VRFAgentCoordinator.sol";
import "../../lib/forge-std/src/console.sol";

contract MockVRFCoordinator is VRFAgentCoordinator {
  address public requestedByConsumer;
  uint256 public requestedNumWords;

  uint256 public lastRequestId;
  mapping(address => uint256) public lastRequestIdByConsumer;

  constructor(VRFAgentConsumerFactoryInterface _consumerFactory) VRFAgentCoordinator(_consumerFactory) {

  }

  function requestRandomWords(
    address /*agent*/,
    uint64 /*subId*/,
    uint16 /*minimumRequestConfirmations*/,
    uint32 /*callbackGasLimit*/,
    uint32 numWords
  ) external override returns (uint256 requestId) {
    requestedByConsumer = msg.sender;
    requestId = ++lastRequestId;
    lastRequestIdByConsumer[requestedByConsumer] = requestId;
    requestedNumWords = numWords;
    s_requestCommitments[requestId] = bytes32(uint256(1));
    return lastRequestIdByConsumer[requestedByConsumer];
  }

  function fulfillRandomWords(Proof memory proof, RequestCommitment memory rc) external override returns (uint256 requestId, uint256[] memory randomWords) {
    randomWords = new uint256[](requestedNumWords);
    requestId = lastRequestIdByConsumer[requestedByConsumer];
    for (uint256 i = 0; i < randomWords.length; i++) {
      randomWords[i] = i + requestId + 95;
    }
    delete s_requestCommitments[requestId];
  }

  function _computeRequestId(
    address /*agent*/,
    address consumer,
    uint64 /*subId*/,
    uint64 /*nonce*/
  ) internal override view returns (uint256, uint256) {
    return (lastRequestIdByConsumer[consumer], 0);
  }
}
