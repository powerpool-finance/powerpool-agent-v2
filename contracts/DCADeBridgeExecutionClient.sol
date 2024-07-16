// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./DCADeBridgeStrategy.sol";

/**
 * @title DCAExecutionClient
 * @author PowerPool
 */
contract DCADeBridgeExecutionClient is Ownable {

    address public agent;
    DCADeBridgeStrategy public dcaStrategy;

    constructor(address agent_, address dcaAgent_) {
        agent = agent_;
        dcaStrategy = DCADeBridgeStrategy(dcaAgent_);
    }

    function makeOrderToBuy(
        address _owner,
        address _destination,
        DCADeBridgeStrategy.OrderTokenData memory _tokenData,
        uint256 _buyPeriod,
        uint256 _marketChainId,
        uint256 _deactivateOn
    ) external onlyOwner {
        dcaStrategy.makeOrderToBuy(owner(), _destination, _tokenData, _buyPeriod, _marketChainId, _deactivateOn);
    }

    function executeOrderResolver() external view returns (bool, bytes memory) {
        return dcaStrategy.clientResolver(address(this));
    }

    function getOrdersToExecute(uint256 _offset, uint256 _limit) external view returns(uint256[] memory orderIds, DCADeBridgeStrategy.Order[] memory resultOrders) {
        return dcaStrategy.getOrdersToExecute(address(this), _offset, _limit);
    }

    function initiateOrderExecution(
        uint256 _orderId,
        address _swapRouterAddress,
        bytes calldata _dataToCall,
        address _dlnSource,
        bytes calldata _dlnSourceData
    ) external {
        //TODO: check jobKey as first argument

        DCADeBridgeStrategy.Order order = dcaStrategy.orders(_orderId);

        IERC20(order.tokenData.tokenToSell).safeTransferFrom(msg.sender, address(this), order.tokenData.amountToSell);
        IERC20(order.tokenData.tokenToSell).safeApprove(address(dcaStrategy), order.tokenData.amountToSell);

        dcaStrategy.initiateOrderExecution(_orderId, _swapRouterAddress, _dataToCall, _dlnSource, _dlnSourceData);
    }
}
