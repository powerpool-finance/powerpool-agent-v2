// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../contracts/interfaces/ICrosschainForwarder.sol";
import "../contracts/interfaces/IDlnSource.sol";
import "../contracts/utils/Flags.sol";

contract DCASidechainAgent {
    using SafeERC20 for IERC20;

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
        address destination;
        OrderTokenData tokenData;
        uint256 buyPeriod;
        uint256 marketChainId;
        uint256 createdAt;
        uint256 deactivateOn;
        uint256 executedAt;
        bytes32 dlnId;
    }
    uint256 public lastOrderId;
    mapping(uint256 => Order) public orders;
    mapping(address => bool) public tokenToSellWhitelist;
    ICrosschainForwarder public crosschainForwarder;

    error AmountNotEqualsMsgValue();

    constructor(ICrosschainForwarder _crosschainForwarder) {
        crosschainForwarder = _crosschainForwarder;
    }

    function makeOrderToBuy(
        address _owner,
        address _destination,
        OrderTokenData memory _tokenData,
        uint256 _buyPeriod,
        uint256 _marketChainId,
        uint256 _deactivateOn
    ) payable external {
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
            destination: _destination,
            tokenData: _tokenData,
            buyPeriod:  _buyPeriod,
            marketChainId: _marketChainId,
            createdAt : block.timestamp,
            deactivateOn: _deactivateOn,
            executedAt : 0,
            dlnId : bytes32(0)
        });
    }

    function initiateOrderExecution(
        uint256 _orderId,
        address _swapRouterAddress,
        bytes calldata _dataToCall,
        address _dlnSource,
        bytes calldata _dlnSourceData
    ) external {
        Order memory order = orders[lastOrderId];

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
            order.destination,
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
        order.dlnId = IDlnSource(_dlnSource).getOrderId(dlnOrder);
    }
}