// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/VRFAgentCoordinatorInterface.sol";
import {VRF} from "./VRF.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./VRFAgentConsumer.sol";
import "./utils/ChainSpecificUtil.sol";

contract VRFAgentCoordinator is VRF, Ownable, VRFAgentCoordinatorInterface {
  // solhint-disable-next-line chainlink-solidity/prefix-immutable-variables-with-i
  IERC20 public immutable CVP;
  using SafeERC20 for IERC20;

  // We need to maintain a list of consuming addresses.
  // This bound ensures we are able to loop over them as needed.
  // Should a user require more consumers, they can use multiple subscriptions.
  uint16 public constant MAX_CONSUMERS = 100;
  error TooManyConsumers();
  error InvalidConsumer(uint64 subId, address consumer);
  error InvalidSubscription();
  error OnlyCallableFromCvp();
  error InvalidCalldata();
  error MustBeSubOwner(address owner);
  error PendingRequestExists();
  error MustBeRequestedOwner(address proposedOwner);
  event FundsRecovered(address token, address to, uint256 amount);
  // We use the config for the mgmt APIs
  struct SubscriptionConfig {
    address owner; // Owner can fund/withdraw/cancel the sub.
    address requestedOwner; // For safely transferring sub ownership.
    // Maintains the list of keys in s_consumers.
    // We do this for 2 reasons:
    // 1. To be able to clean up all keys from s_consumers when canceling a subscription.
    // 2. To be able to return the list of all consumers in getSubscription.
    // Note that we need the s_consumers map to be able to directly check if a
    // consumer is valid without reading all the consumers from storage.
    address[] consumers;
  }
  // Note a nonce of 0 indicates an the consumer is not assigned to that subscription.
  mapping(address => mapping(uint64 => uint64)) /* consumer */ /* subId */ /* nonce */ private s_consumers;
  mapping(uint64 => SubscriptionConfig) /* subId */ /* subscriptionConfig */ private s_subscriptionConfigs;
  // We make the sub count public so that its possible to
  // get all the current subscriptions via getSubscription.
  uint64 private s_currentSubId;

  event SubscriptionCreated(uint64 indexed subId, address owner);
  event SubscriptionConsumerAdded(uint64 indexed subId, address consumer);
  event SubscriptionConsumerRemoved(uint64 indexed subId, address consumer);
  event SubscriptionCanceled(uint64 indexed subId);
  event SubscriptionOwnerTransferRequested(uint64 indexed subId, address from, address to);
  event SubscriptionOwnerTransferred(uint64 indexed subId, address from, address to);

  // Set this maximum to 200 to give us a 56 block window to fulfill
  // the request before requiring the block hash feeder.
  uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;
  uint32 public constant MAX_NUM_WORDS = 500;
  // 5k is plenty for an EXTCODESIZE call (2600) + warm CALL (100)
  // and some arithmetic operations.
  uint256 private constant GAS_FOR_CALL_EXACT_CHECK = 5_000;
  error InvalidRequestConfirmations(uint16 have, uint16 min, uint16 max);
  error GasLimitTooBig(uint32 have, uint32 want);
  error NumWordsTooBig(uint32 have, uint32 want);
  error AgentProviderAlreadyRegistered();
  error NoSuchProvingKey(bytes32 keyHash);
  error InvalidCvpWeiPrice(int256 cvpWei);
  error InsufficientGasForConsumer(uint256 have, uint256 want);
  error InvalidProvider();
  error InvalidTxOrigin();
  error NoCorrespondingRequest();
  error IncorrectCommitment();
  error BlockhashNotInStore(uint256 blockNum);
  error PaymentTooLarge();
  error Reentrant();
  struct RequestCommitment {
    uint64 blockNum;
    uint64 subId;
    uint32 callbackGasLimit;
    uint32 numWords;
    address sender;
  }
  mapping(address => bool) /* keyHash */ /* oracle */ private s_agentProviders;
  address[] private s_agentProvidersList;
  mapping(uint256 => bytes32) /* requestID */ /* commitment */ private s_requestCommitments;
  event AgentProviderRegistered(address indexed agent);
  event AgentProviderDeregistered(address indexed agent);
  event RandomWordsRequested(
    address indexed keyHash,
    uint256 indexed requestId,
    uint256 preSeed,
    uint64 indexed subId,
    uint16 minimumRequestConfirmations,
    uint32 callbackGasLimit,
    uint32 numWords,
    address sender
  );
  event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, bool success);

  struct Config {
    uint16 minimumRequestConfirmations;
    uint32 maxGasLimit;
    // Reentrancy protection.
    bool reentrancyLock;
  }
  int256 private s_fallbackWeiPerUnitCvp;
  Config private s_config;
  event ConfigSet(
    uint16 minimumRequestConfirmations,
    uint32 maxGasLimit
  );

  constructor(IERC20 _cvp) Ownable() {
    CVP = _cvp;
  }

  /**
   * @notice Registers an agent as provider
   * @param agent address of the agent
   */
  function registerAgent(address agent) external onlyOwner {
    if (s_agentProviders[agent]) {
      revert AgentProviderAlreadyRegistered();
    }
    s_agentProviders[agent] = true;
    s_agentProvidersList.push(agent);
    emit AgentProviderRegistered(agent);
  }

  /**
   * @notice Deregisters an agent as provider
   * @param agent address of the agent
   */
  function deregisterAgent(address agent) external onlyOwner {
    delete s_agentProviders[agent];
    for (uint256 i = 0; i < s_agentProvidersList.length; i++) {
      if (s_agentProvidersList[i] == agent) {
        address last = s_agentProvidersList[s_agentProvidersList.length - 1];
        // Copy last element and overwrite kh to be deleted with it
        s_agentProvidersList[i] = last;
        s_agentProvidersList.pop();
      }
    }
    emit AgentProviderDeregistered(agent);
  }

  /**
   * @notice Sets the configuration of the vrfv2 coordinator
   * @param minimumRequestConfirmations global min for request confirmations
   * @param maxGasLimit global max for request gas limit
   */
  function setConfig(
    uint16 minimumRequestConfirmations,
    uint32 maxGasLimit
  ) external onlyOwner {
    if (minimumRequestConfirmations > MAX_REQUEST_CONFIRMATIONS) {
      revert InvalidRequestConfirmations(
        minimumRequestConfirmations,
        minimumRequestConfirmations,
        MAX_REQUEST_CONFIRMATIONS
      );
    }
    s_config = Config({
      minimumRequestConfirmations: minimumRequestConfirmations,
      maxGasLimit: maxGasLimit,
      reentrancyLock: false
    });
    emit ConfigSet(minimumRequestConfirmations, maxGasLimit);
  }

  function getConfig()
    external
    view
    returns (
      uint16 minimumRequestConfirmations,
      uint32 maxGasLimit
    )
  {
    return (
      s_config.minimumRequestConfirmations,
      s_config.maxGasLimit
    );
  }

  /**
   * @notice Owner cancel subscription, sends remaining cvp directly to the subscription owner.
   * @param subId subscription id
   * @dev notably can be called even if there are pending requests, outstanding ones may fail onchain
   */
  function ownerCancelSubscription(uint64 subId) external onlyOwner {
    if (s_subscriptionConfigs[subId].owner == address(0)) {
      revert InvalidSubscription();
    }
    _cancelSubscriptionHelper(subId, s_subscriptionConfigs[subId].owner);
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function getRequestConfig() external view override returns (uint16, uint32, address[] memory) {
    return (s_config.minimumRequestConfirmations, s_config.maxGasLimit, s_agentProvidersList);
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function requestRandomWords(
    address agent,
    uint64 subId,
    uint16 requestConfirmations,
    uint32 callbackGasLimit,
    uint32 numWords
  ) external override nonReentrant returns (uint256) {
    // Input validation using the subscription storage.
    if (s_subscriptionConfigs[subId].owner == address(0)) {
      revert InvalidSubscription();
    }
    // A nonce of 0 indicates consumer is not allocated to the sub.
    uint64 currentNonce = s_consumers[msg.sender][subId];
    if (currentNonce == 0) {
      revert InvalidConsumer(subId, msg.sender);
    }
    // Input validation using the config storage word.
    if (
      requestConfirmations < s_config.minimumRequestConfirmations || requestConfirmations > MAX_REQUEST_CONFIRMATIONS
    ) {
      revert InvalidRequestConfirmations(
        requestConfirmations,
        s_config.minimumRequestConfirmations,
        MAX_REQUEST_CONFIRMATIONS
      );
    }
    // No lower bound on the requested gas limit. A user could request 0
    // and they would simply be billed for the proof verification and wouldn't be
    // able to do anything with the random value.
    if (callbackGasLimit > s_config.maxGasLimit) {
      revert GasLimitTooBig(callbackGasLimit, s_config.maxGasLimit);
    }
    if (numWords > MAX_NUM_WORDS) {
      revert NumWordsTooBig(numWords, MAX_NUM_WORDS);
    }
    // Note we do not check whether the keyHash is valid to save gas.
    // The consequence for users is that they can send requests
    // for invalid keyHashes which will simply not be fulfilled.
    uint64 nonce = currentNonce + 1;
    (uint256 requestId, uint256 preSeed) = _computeRequestId(agent, msg.sender, subId, nonce);

    s_requestCommitments[requestId] = keccak256(
      abi.encode(requestId, ChainSpecificUtil._getBlockNumber(), subId, callbackGasLimit, numWords, msg.sender)
    );
    emit RandomWordsRequested(
      agent,
      requestId,
      preSeed,
      subId,
      requestConfirmations,
      callbackGasLimit,
      numWords,
      msg.sender
    );
    s_consumers[msg.sender][subId] = nonce;

    return requestId;
  }

  /**
   * @notice Get request commitment
   * @param requestId id of request
   * @dev used to determine if a request is fulfilled or not
   */
  function getCommitment(uint256 requestId) external view returns (bytes32) {
    return s_requestCommitments[requestId];
  }

  function _computeRequestId(
    address agent,
    address sender,
    uint64 subId,
    uint64 nonce
  ) private pure returns (uint256, uint256) {
    uint256 preSeed = uint256(keccak256(abi.encode(agent, sender, subId, nonce)));
    return (uint256(keccak256(abi.encode(agent, preSeed))), preSeed);
  }

  /**
   * @dev calls target address with exactly gasAmount gas and data as calldata
   * or reverts if at least gasAmount gas is not available.
   */
  function _callWithExactGas(uint256 gasAmount, address target, bytes memory data) private returns (bool success) {
    assembly {
      let g := gas()
      // Compute g -= GAS_FOR_CALL_EXACT_CHECK and check for underflow
      // The gas actually passed to the callee is min(gasAmount, 63//64*gas available).
      // We want to ensure that we revert if gasAmount >  63//64*gas available
      // as we do not want to provide them with less, however that check itself costs
      // gas.  GAS_FOR_CALL_EXACT_CHECK ensures we have at least enough gas to be able
      // to revert if gasAmount >  63//64*gas available.
      if lt(g, GAS_FOR_CALL_EXACT_CHECK) {
        revert(0, 0)
      }
      g := sub(g, GAS_FOR_CALL_EXACT_CHECK)
      // if g - g//64 <= gasAmount, revert
      // (we subtract g//64 because of EIP-150)
      if iszero(gt(sub(g, div(g, 64)), gasAmount)) {
        revert(0, 0)
      }
      // solidity calls check that a contract actually exists at the destination, so we do the same
      if iszero(extcodesize(target)) {
        revert(0, 0)
      }
      // call and return whether we succeeded. ignore return data
      // call(gas,addr,value,argsOffset,argsLength,retOffset,retLength)
      success := call(gasAmount, target, 0, add(data, 0x20), mload(data), 0, 0)
    }
    return success;
  }

  function publicKeyToAddress(uint[2] memory publicKey) public pure returns (address) {
    bytes32 hash = keccak256(abi.encodePacked(publicKey));
    return ecrecover(0, 0, hash, bytes32(publicKey[0] > 0 ? publicKey[0] : 1)); // recovering address
  }

  function _getRandomnessFromProof(
    Proof memory proof,
    RequestCommitment memory rc
  ) private view returns (bytes32 keyHash, uint256 requestId, uint256 randomness) {
    if (!s_agentProviders[msg.sender]) {
      revert InvalidProvider();
    }
//    if (publicKeyToAddress(proof.pk) != tx.origin) {
//      revert InvalidTxOrigin();
//    }
    requestId = uint256(keccak256(abi.encode(msg.sender, proof.seed)));
    bytes32 commitment = s_requestCommitments[requestId];
    if (commitment == 0) {
      revert NoCorrespondingRequest();
    }
    if (
      commitment != keccak256(abi.encode(requestId, rc.blockNum, rc.subId, rc.callbackGasLimit, rc.numWords, rc.sender))
    ) {
      revert IncorrectCommitment();
    }

    bytes32 blockHash = ChainSpecificUtil._getBlockhash(rc.blockNum);
    if (blockHash == bytes32(0)) {
      revert BlockhashNotInStore(rc.blockNum);
    }

    // The seed actually used by the VRF machinery, mixing in the blockhash
    keyHash = hashOfKey(proof.pk);
    uint256 actualSeed = uint256(keccak256(abi.encodePacked(proof.seed, blockHash, keyHash)));
    randomness = VRF._randomValueFromVRFProof(proof, actualSeed); // Reverts on failure
    return (keyHash, requestId, randomness);
  }

  /*
   * @notice Fulfill a randomness request
   * @param proof contains the proof and randomness
   * @param rc request commitment pre-image, committed to at request time
   */
  function fulfillRandomWords(Proof memory proof, RequestCommitment memory rc) external nonReentrant {
    uint256 startGas = gasleft();
    (bytes32 keyHash, uint256 requestId, uint256 randomness) = _getRandomnessFromProof(proof, rc);

    uint256[] memory randomWords = new uint256[](rc.numWords);
    for (uint256 i = 0; i < rc.numWords; i++) {
      randomWords[i] = uint256(keccak256(abi.encode(randomness, i)));
    }

    delete s_requestCommitments[requestId];
    VRFAgentConsumer v;
    bytes memory resp = abi.encodeWithSelector(v.rawFulfillRandomWords.selector, requestId, randomWords);
    // Call with explicitly the amount of callback gas requested
    // Important to not let them exhaust the gas budget and avoid oracle payment.
    // Do not allow any non-view/non-pure coordinator functions to be called
    // during the consumers callback code via reentrancyLock.
    // Note that _callWithExactGas will revert if we do not have sufficient gas
    // to give the callee their requested amount.
    s_config.reentrancyLock = true;
    bool success = _callWithExactGas(rc.callbackGasLimit, rc.sender, resp);
    s_config.reentrancyLock = false;

    emit RandomWordsFulfilled(requestId, randomness, success);
  }

  function getCurrentSubId() external view returns (uint64) {
    return s_currentSubId;
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function getSubscription(uint64 subId) external view override returns (address owner, address[] memory consumers) {
    if (s_subscriptionConfigs[subId].owner == address(0)) {
      revert InvalidSubscription();
    }
    return (
      s_subscriptionConfigs[subId].owner,
      s_subscriptionConfigs[subId].consumers
    );
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function createSubscription() external override nonReentrant returns (uint64) {
    s_currentSubId++;
    uint64 subId = s_currentSubId;

    address agent = s_agentProvidersList[s_agentProvidersList.length - 1];

    address[] memory consumers = new address[](1);
    s_subscriptionConfigs[subId] = SubscriptionConfig({
      owner: msg.sender,
      requestedOwner: address(0),
      consumers: consumers
    });

    emit SubscriptionCreated(subId, msg.sender);
    return subId;
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function requestSubscriptionOwnerTransfer(
    uint64 subId,
    address newOwner
  ) external override onlySubOwner(subId) nonReentrant {
    // Proposing to address(0) would never be claimable so don't need to check.
    if (s_subscriptionConfigs[subId].requestedOwner != newOwner) {
      s_subscriptionConfigs[subId].requestedOwner = newOwner;
      emit SubscriptionOwnerTransferRequested(subId, msg.sender, newOwner);
    }
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function acceptSubscriptionOwnerTransfer(uint64 subId) external override nonReentrant {
    if (s_subscriptionConfigs[subId].owner == address(0)) {
      revert InvalidSubscription();
    }
    if (s_subscriptionConfigs[subId].requestedOwner != msg.sender) {
      revert MustBeRequestedOwner(s_subscriptionConfigs[subId].requestedOwner);
    }
    address oldOwner = s_subscriptionConfigs[subId].owner;
    s_subscriptionConfigs[subId].owner = msg.sender;
    s_subscriptionConfigs[subId].requestedOwner = address(0);
    emit SubscriptionOwnerTransferred(subId, oldOwner, msg.sender);
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function removeConsumer(uint64 subId, address consumer) external override onlySubOwner(subId) nonReentrant {
    if (pendingRequestExists(subId)) {
      revert PendingRequestExists();
    }
    if (s_consumers[consumer][subId] == 0) {
      revert InvalidConsumer(subId, consumer);
    }
    // Note bounded by MAX_CONSUMERS
    address[] memory consumers = s_subscriptionConfigs[subId].consumers;
    uint256 lastConsumerIndex = consumers.length - 1;
    for (uint256 i = 0; i < consumers.length; i++) {
      if (consumers[i] == consumer) {
        address last = consumers[lastConsumerIndex];
        // Storage write to preserve last element
        s_subscriptionConfigs[subId].consumers[i] = last;
        // Storage remove last element
        s_subscriptionConfigs[subId].consumers.pop();
        break;
      }
    }
    delete s_consumers[consumer][subId];
    emit SubscriptionConsumerRemoved(subId, consumer);
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function addConsumer(uint64 subId, address consumer) external override onlySubOwner(subId) nonReentrant {
    _addConsumer(subId, consumer);
  }

  function _addConsumer(uint64 subId, address consumer) internal {
    // Already maxed, cannot add any more consumers.
    if (s_subscriptionConfigs[subId].consumers.length == MAX_CONSUMERS) {
      revert TooManyConsumers();
    }
    if (s_consumers[consumer][subId] != 0) {
      // Idempotence - do nothing if already added.
      // Ensures uniqueness in s_subscriptionConfigs[subId].consumers.
      return;
    }
    // Initialize the nonce to 1, indicating the consumer is allocated.
    s_consumers[consumer][subId] = 1;
    s_subscriptionConfigs[subId].consumers.push(consumer);

    emit SubscriptionConsumerAdded(subId, consumer);
}

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   */
  function cancelSubscription(uint64 subId, address to) external override onlySubOwner(subId) nonReentrant {
    if (pendingRequestExists(subId)) {
      revert PendingRequestExists();
    }
    _cancelSubscriptionHelper(subId, to);
  }

  function _cancelSubscriptionHelper(uint64 subId, address to) private nonReentrant {
    SubscriptionConfig memory subConfig = s_subscriptionConfigs[subId];
    // Note bounded by MAX_CONSUMERS;
    // If no consumers, does nothing.
    for (uint256 i = 0; i < subConfig.consumers.length; i++) {
      delete s_consumers[subConfig.consumers[i]][subId];
    }
    delete s_subscriptionConfigs[subId];
    emit SubscriptionCanceled(subId);
  }

  /**
   * @notice Recover token sent mistakenly.
   * @param token address of token to send
   * @param to address to send token to
   */
  function recoverFunds(address token, address to) external onlyOwner {
    uint256 amount = IERC20(token).balanceOf(address(this));
    IERC20(token).transfer(to, amount);
    emit FundsRecovered(token, to, amount);
  }

  /**
   * @notice Returns the proving key hash key associated with this public key
   * @param publicKey the key to return the hash of
   */
  function hashOfKey(uint256[2] memory publicKey) public pure returns (bytes32) {
    return keccak256(abi.encode(publicKey));
  }

  /**
   * @inheritdoc VRFAgentCoordinatorInterface
   * @dev Looping is bounded to MAX_CONSUMERS*(number of keyhashes).
   * @dev Used to disable subscription canceling while outstanding request are present.
   */
  function pendingRequestExists(uint64 subId) public view override returns (bool) {
    SubscriptionConfig memory subConfig = s_subscriptionConfigs[subId];
    for (uint256 i = 0; i < subConfig.consumers.length; i++) {
      uint256 reqId = lastPendingRequestId(subId, subConfig.consumers[i]);
      if (s_requestCommitments[reqId] != 0) {
        return true;
      }
    }
    return false;
  }

  function lastPendingRequestId(uint64 subId, address consumer) public view returns (uint256) {
    for (uint256 i = 0; i < s_agentProvidersList.length; i++) {
      (uint256 reqId, ) = _computeRequestId(s_agentProvidersList[i], consumer, subId, s_consumers[consumer][subId]);
      if (s_requestCommitments[reqId] != 0) {
        return reqId;
      }
    }
    return 0;
  }

  function fulfillResolver(uint64 subscriptionId) external view returns (bool, bytes memory) {
    return (pendingRequestExists(subscriptionId), bytes(""));
  }

  modifier onlySubOwner(uint64 subId) {
    address owner = s_subscriptionConfigs[subId].owner;
    if (owner == address(0)) {
      revert InvalidSubscription();
    }
    if (msg.sender != owner) {
      revert MustBeSubOwner(owner);
    }
    _;
  }

  modifier nonReentrant() {
    if (s_config.reentrancyLock) {
      revert Reentrant();
    }
    _;
  }

  /**
   * @notice The type and version of this contract
   * @return Type and version string
   */
  function typeAndVersion() external pure virtual returns (string memory) {
    return "VRFAgentCoordinator 1.0.0";
  }
}