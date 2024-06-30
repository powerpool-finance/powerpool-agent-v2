// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/VRFAgentCoordinatorInterface.sol";
import "./interfaces/VRFAgentConsumerInterface.sol";
import "./interfaces/VRFChainlinkCoordinatorInterface.sol";

/**
 * @title VRFAgentConsumer
 * @author PowerPool
 */
contract VRFAgentConsumer is VRFAgentConsumerInterface, Ownable {
    uint32 public constant VRF_NUM_RANDOM_WORDS = 10;

    address public agent;
    address public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint64 public vrfSubscriptionId;
    uint16 public vrfRequestConfirmations;
    uint32 public vrfCallbackGasLimit;

    uint256 public vrfRequestPeriod;
    uint256 public lastVrfFulfillAt;
    uint256 public lastVrfRequestAtBlock;

    uint256 public pendingRequestId;
    uint256[] public lastVrfNumbers;

    string public offChainIpfsHash;
    bool public useLocalIpfsHash;

    event SetVrfConfig(address vrfCoordinator, bytes32 vrfKeyHash, uint64 vrfSubscriptionId, uint16 vrfRequestConfirmations, uint32 vrfCallbackGasLimit, uint256 vrfRequestPeriod);
    event ClearPendingRequestId();
    event SetOffChainIpfsHash(string ipfsHash);

    constructor(address agent_) {
        agent = agent_;
    }

    /*** AGENT OWNER METHODS ***/
    function setVrfConfig(
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint64 vrfSubscriptionId_,
        uint16 vrfRequestConfirmations_,
        uint32 vrfCallbackGasLimit_,
        uint256 vrfRequestPeriod_
    ) external onlyOwner {
        vrfCoordinator = vrfCoordinator_;
        vrfKeyHash = vrfKeyHash_;
        vrfSubscriptionId = vrfSubscriptionId_;
        vrfRequestConfirmations = vrfRequestConfirmations_;
        vrfCallbackGasLimit = vrfCallbackGasLimit_;
        vrfRequestPeriod = vrfRequestPeriod_;
        emit SetVrfConfig(vrfCoordinator_, vrfKeyHash_, vrfSubscriptionId_, vrfRequestConfirmations_, vrfCallbackGasLimit_, vrfRequestPeriod_);
    }

    function clearPendingRequestId() external onlyOwner {
        pendingRequestId = 0;
        emit ClearPendingRequestId();
    }

    function setOffChainIpfsHash(string calldata _ipfsHash) external onlyOwner {
        offChainIpfsHash = _ipfsHash;
        useLocalIpfsHash = bytes(offChainIpfsHash).length > 0;
        emit SetOffChainIpfsHash(_ipfsHash);
    }

    function rawFulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) external {
        require(msg.sender == address(vrfCoordinator), "sender not vrfCoordinator");
        require(_requestId == pendingRequestId, "request not found");
        lastVrfNumbers = _randomWords;
        pendingRequestId = 0;
        if (vrfRequestPeriod != 0) {
            lastVrfFulfillAt = block.timestamp;
        }
    }

    function isPendingRequestOverdue() public view returns (bool) {
        return pendingRequestId != 0 && block.number - lastVrfRequestAtBlock >= 256;
    }

    function isReadyForRequest() public view returns (bool) {
        return (isPendingRequestOverdue() || pendingRequestId == 0)
            && (vrfRequestPeriod == 0 || lastVrfFulfillAt + vrfRequestPeriod < block.timestamp);
    }

    function getLastBlockHash() public virtual view returns (uint256) {
        return uint256(blockhash(block.number - 1));
    }

    function getPseudoRandom() external returns (uint256) {
        if (msg.sender == agent && isReadyForRequest()) {
            pendingRequestId = _requestRandomWords();
            lastVrfRequestAtBlock = block.number;
        }
        uint256 blockHashNumber = getLastBlockHash();
        if (lastVrfNumbers.length > 0) {
            uint256 vrfNumberIndex = uint256(keccak256(abi.encodePacked(agent.balance))) % uint256(VRF_NUM_RANDOM_WORDS);
            blockHashNumber = uint256(keccak256(abi.encodePacked(blockHashNumber, lastVrfNumbers[vrfNumberIndex])));
        }
        return blockHashNumber;
    }

    function _requestRandomWords() internal virtual returns (uint256) {
        if (vrfKeyHash == bytes32(0)) {
            return VRFAgentCoordinatorInterface(vrfCoordinator).requestRandomWords(
                agent,
                vrfSubscriptionId,
                vrfRequestConfirmations,
                vrfCallbackGasLimit,
                VRF_NUM_RANDOM_WORDS
            );
        } else {
            return VRFChainlinkCoordinatorInterface(vrfCoordinator).requestRandomWords(
                vrfKeyHash,
                vrfSubscriptionId,
                vrfRequestConfirmations,
                vrfCallbackGasLimit,
                VRF_NUM_RANDOM_WORDS
            );
        }
    }

    function getLastVrfNumbers() external view returns (uint256[] memory) {
        return lastVrfNumbers;
    }

    function fulfillRandomnessResolver() external view returns (bool, bytes memory) {
        if (isPendingRequestOverdue() || (lastVrfFulfillAt != 0 && pendingRequestId == 0) || block.number == lastVrfRequestAtBlock) {
            return (false, bytes(""));
        }
        if (useLocalIpfsHash) {
            return (lastPendingRequestId() != 0, bytes(offChainIpfsHash));
        } else {
            return VRFAgentCoordinatorInterface(vrfCoordinator).fulfillRandomnessResolver(vrfSubscriptionId);
        }
    }

    function lastPendingRequestId() public view returns (uint256) {
        return VRFAgentCoordinatorInterface(vrfCoordinator).lastPendingRequestId(address(this), vrfSubscriptionId);
    }

    function getRequestData() external view returns (
        uint256 subscriptionId,
        uint256 requestAtBlock,
        bytes32 requestAtBlockHash,
        uint256 requestId,
        uint64 requestNonce,
        uint32 numbRandomWords,
        uint32 callbackGasLimit
    ) {
        return (
            vrfSubscriptionId,
            lastVrfRequestAtBlock,
            blockhash(lastVrfRequestAtBlock),
            pendingRequestId,
            VRFAgentCoordinatorInterface(vrfCoordinator).getCurrentNonce(address(this), vrfSubscriptionId),
            VRF_NUM_RANDOM_WORDS,
            vrfCallbackGasLimit
        );
    }
}
