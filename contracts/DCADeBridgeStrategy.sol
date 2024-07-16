// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICrosschainForwarder.sol";
import "./interfaces/IDlnSource.sol";
import "./utils/Flags.sol";
import "./utils/CustomizedEnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/DCAClientFactoryInterface.sol";

contract DCADeBridgeStrategy is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct OrderTokenData {
        address tokenToSell;
        uint256 amountToSell;
        address tokenToBuy;
        uint256 minPrice;
        uint256 maxPrice;
    }
    struct Order {
        bool active;
        address owner;
        address client;
        address recipient;
        OrderTokenData tokenData;
        uint256 buyPeriod;
        uint256 marketChainId;
        uint256 createdAt;
        uint256 deactivateOn;
        uint256 executedAt;
        bytes32 lastDlnId;
    }
    uint256 public lastOrderId;
    mapping(uint256 => Order) public orders;
    mapping(address => address) public clientByOwner;
    mapping(address => bool) public tokenToSellWhitelist;
    address public agent;
    ICrosschainForwarder public crosschainForwarder;

    mapping(address => EnumerableSet.UintSet) internal activeOrdersByClient;

    uint256 public checkOrdersCountOnExecute;
    string public offChainIpfsHash;
    DCAClientFactoryInterface public clientFactory;

    error OrderTooLong();
    error AmountNotEqualsMsgValue();
    error CallerNotTheClient();

    constructor(address _agent, ICrosschainForwarder _crosschainForwarder) {
        agent = _agent;
        crosschainForwarder = _crosschainForwarder;
    }

    function setConfig(uint256 _checkOrdersCountOnExecute) external onlyOwner {
        checkOrdersCountOnExecute = _checkOrdersCountOnExecute;
    }

    function setOffchainIpfsHash(string calldata _ipfsHash) external onlyOwner {
        offChainIpfsHash = _ipfsHash;
    }

    function setClientFactory(DCAClientFactoryInterface _clientFactory) external onlyOwner {
        clientFactory = _clientFactory;
    }

    function createClient() external {
        clientByOwner[msg.sender] = clientFactory.createClient(agent, msg.sender);
    }

    function makeOrderToBuy(
        address _owner,
        address _recipient,
        OrderTokenData memory _tokenData,
        uint256 _buyPeriod,
        uint256 _marketChainId,
        uint256 _deactivateOn
    ) payable external {
        if (clientByOwner[_owner] != msg.sender) {
            revert CallerNotTheClient();
        }
        if (_deactivateOn > block.timestamp + 7 days) {
            revert OrderTooLong();
        }
        if (_tokenData.tokenToSell == address(1)) {
            if (_tokenData.amountToSell != msg.value) {
                revert AmountNotEqualsMsgValue();
            }
        } else {
            IERC20(_tokenData.tokenToSell).safeTransferFrom(msg.sender, address(this), _tokenData.amountToSell);
        }

        lastOrderId++;
        orders[lastOrderId] = Order({
            active: true,
            owner: _owner,
            client: msg.sender,
            recipient: _recipient,
            tokenData: _tokenData,
            buyPeriod:  _buyPeriod,
            marketChainId: _marketChainId,
            createdAt : block.timestamp,
            deactivateOn: _deactivateOn,
            executedAt : 0,
            lastDlnId : bytes32(0)
        });

        activeOrdersByClient[msg.sender].add(lastOrderId);
    }

    function getOrdersToExecute(address _client, uint256 _offset, uint256 _limit) external view returns(uint256[] memory orderIds, Order[] memory resultOrders) {
        uint256 totalOrders = activeOrdersByClient[_client].length();
        uint256 untilOrderIndex = _offset + _limit > totalOrders ? totalOrders : _offset + _limit;
        uint256 totalResults = untilOrderIndex - _offset;
        orderIds = new uint256[](totalResults);
        resultOrders = new Order[](totalResults);
        for (uint256 i = _offset; i < untilOrderIndex; i++) {
            orderIds[i] = activeOrdersByClient[_client].at(i);
            resultOrders[i] = orders[orderIds[i]];
        }
    }

    function doesClientHaveOrderReadyToExecute(address _client) public view returns(bool) {
        uint256 totalOrders = activeOrdersByClient[_client].length();
        for (uint256 i = 0; i < totalOrders; i++) {
            Order storage order = orders[activeOrdersByClient[_client].at(i)];
            if (order.deactivateOn <= block.timestamp) {
                continue;
            }
            if (order.executedAt + order.buyPeriod < block.timestamp) {
                return true;
            }
        }
        return false;
    }

    function clientResolver(address _client) external view returns(bool, bytes memory data) {
        return (doesClientHaveOrderReadyToExecute(_client), bytes(offChainIpfsHash));
    }

    function initiateOrderExecution(
        uint256 _orderId,
        address _swapRouterAddress,
        bytes calldata _dataToCall,
        address _dlnSource,
        bytes calldata _dlnSourceData
    ) external {
        Order memory order = orders[lastOrderId];
        if (order.client != msg.sender) {
            revert CallerNotTheClient();
        }

        bytes memory permitSig;
        IERC20(order.tokenData.tokenToSell).approve(address(crosschainForwarder), order.tokenData.amountToSell);
        crosschainForwarder.strictlySwapAndCall(
            order.tokenData.tokenToSell,
            order.tokenData.amountToSell,
            permitSig,
            _swapRouterAddress,
            _dataToCall,
            order.tokenData.tokenToBuy,
            order.tokenData.amountToSell * order.tokenData.minPrice / 1 ether,
            order.recipient,
            _dlnSource,
            _dlnSourceData
        );
        (
            DlnOrderLib.OrderCreation memory _orderCreation,
            bytes memory _affiliateFee,
            uint32 _referralCode,
            bytes memory _permitEnvelope
        ) = abi.decode(_dlnSourceData[4:], (
            DlnOrderLib.OrderCreation,
            bytes,
            uint32,
            bytes
        ));
        DlnOrderLib.Order memory dlnOrder = IDlnSource(_dlnSource).validateCreationOrder(_orderCreation, tx.origin);
        order.lastDlnId = IDlnSource(_dlnSource).getOrderId(dlnOrder);
        order.executedAt = block.timestamp;
        if (order.executedAt + order.buyPeriod >= order.deactivateOn) {
            order.active = false;
            activeOrdersByClient[order.client].remove(_orderId);
        }

        uint256 totalOrders = activeOrdersByClient[msg.sender].length();
        for (uint256 i = 0; i < checkOrdersCountOnExecute; i++) {
            uint256 orderId = activeOrdersByClient[msg.sender].at(i);
            Order storage o = orders[orderId];
            if (o.deactivateOn <= block.timestamp) {
                o.active = false;
                activeOrdersByClient[o.client].remove(orderId);
            }
        }

    }
}