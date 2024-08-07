// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface VRFAgentCoordinatorInterface {
    struct Proof {
        uint256[2] pk;
        uint256[2] gamma;
        uint256 c;
        uint256 s;
        uint256 seed;
        address uWitness;
        uint256[2] cGammaWitness;
        uint256[2] sHashWitness;
        uint256 zInv;
    }

    struct RequestCommitment {
        uint64 blockNum;
        uint64 subId;
        uint32 callbackGasLimit;
        uint32 numWords;
        address sender;
    }

    /**
     * @notice Get configuration relevant for making requests
     * @return minimumRequestConfirmations global min for request confirmations
     * @return maxGasLimit global max for request gas limit
     * @return s_agentProviders list of registered agents
     */
    function getRequestConfig() external view returns (uint16, uint32, address[] memory);

    /**
     * @notice Request a set of random words.
     * @param agent - Corresponds to a agent provider address
     * @param subId  - The ID of the VRF subscription. Must be funded
     * with the minimum subscription balance required for the selected keyHash.
     * @param minimumRequestConfirmations - How many blocks you'd like the
     * oracle to wait before responding to the request. See SECURITY CONSIDERATIONS
     * for why you may want to request more. The acceptable range is
     * [minimumRequestBlockConfirmations, 200].
     * @param callbackGasLimit - How much gas you'd like to receive in your
     * fulfillRandomWords callback. Note that gasleft() inside fulfillRandomWords
     * may be slightly less than this amount because of gas used calling the function
     * (argument decoding etc.), so you may need to request slightly more than you expect
     * to have inside fulfillRandomWords. The acceptable range is
     * [0, maxGasLimit]
     * @param numWords - The number of uint256 random values you'd like to receive
     * in your fulfillRandomWords callback. Note these numbers are expanded in a
     * secure way by the VRFCoordinator from a single random value supplied by the oracle.
     * @return requestId - A unique identifier of the request. Can be used to match
     * a request to a response in fulfillRandomWords.
     */
    function requestRandomWords(
        address agent,
        uint64 subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);

    function fulfillRandomWords(Proof memory proof, RequestCommitment memory rc) external returns (uint256 requestId, uint256[] calldata randomWords);

    /**
     * @notice Create a VRF subscription.
     * @return subId - A unique subscription id.
     * @return consumer - An consumer address.
     */
    function createSubscriptionWithConsumer() external returns (uint64 subId, address consumer);

    /**
     * @notice Get a VRF subscription.
     * @param subId - ID of the subscription
     * @return owner - owner of the subscription.
     * @return consumers - list of consumer address which are able to use this subscription.
     */
    function getSubscription(uint64 subId) external view returns (address owner, address[] memory consumers);

    /**
     * @notice Request subscription owner transfer.
     * @param subId - ID of the subscription
     * @param newOwner - proposed new owner of the subscription
     */
    function requestSubscriptionOwnerTransfer(uint64 subId, address newOwner) external;

    /**
     * @notice Request subscription owner transfer.
     * @param subId - ID of the subscription
     * @dev will revert if original owner of subId has
     * not requested that msg.sender become the new owner.
     */
    function acceptSubscriptionOwnerTransfer(uint64 subId) external;

    /**
     * @notice Cancel a subscription
     * @param subId - ID of the subscription
     */
    function cancelSubscription(uint64 subId) external;

    /*
     * @notice Check to see if there exists a request commitment consumers
     * for all consumers and keyhashes for a given sub.
     * @param subId - ID of the subscription
     * @return true if there exists at least one unfulfilled request for the subscription, false
     * otherwise.
     */
    function pendingRequestExists(uint64 subId) external view returns (bool);

    function fulfillRandomnessOffchainResolver(address consumer, uint64 _subId) external view returns (bool, bytes calldata);

    /*
     * @notice Get last pending request id
     */
    function lastPendingRequestId(address consumer, uint64 subId) external view returns (uint256);

    /*
     * @notice Get current nonce
     */
    function getCurrentNonce(address consumer, uint64 subId) external view returns (uint64);
}
