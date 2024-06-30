// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/VRFAgentConsumer.sol";
import "../../contracts/VRFAgentCoordinator.sol";
import "../../lib/forge-std/src/console.sol";

contract MockVRFCoordinator is VRFAgentCoordinator {
  address public requestedByConsumer;
  uint256 public requestedNumWords;

  mapping(address => uint256) public lastRequestIdByConsumer;

  constructor(VRFAgentConsumerFactoryInterface _consumerFactory) VRFAgentCoordinator(_consumerFactory) {

  }

  function fulfillRandomnessResolver(uint64 _subId) external override view returns (bool, bytes memory) {
    return (false, bytes(""));
  }

  function requestRandomWords(
    address /*agent*/,
    uint64 /*subId*/,
    uint16 /*minimumRequestConfirmations*/,
    uint32 /*callbackGasLimit*/,
    uint32 numWords
  ) external override returns (uint256 requestId) {
    requestedByConsumer = msg.sender;
    lastRequestIdByConsumer[requestedByConsumer]++;
    requestedNumWords = numWords;
    s_requestCommitments[requestId] = bytes32(uint256(1));
    return lastRequestIdByConsumer[requestedByConsumer];
  }

  function callFulfill() external {
    uint256[] memory words = new uint256[](requestedNumWords);
    uint256 lastRequestId = lastRequestIdByConsumer[requestedByConsumer];
    for (uint256 i = 0; i < words.length; i++) {
      words[i] = i + lastRequestId + 54;
    }
    VRFAgentConsumer(requestedByConsumer).rawFulfillRandomWords(lastRequestId, words);
    delete s_requestCommitments[lastRequestId];
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
