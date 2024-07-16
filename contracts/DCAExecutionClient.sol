// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./DCASidechainAgent.sol";

/**
 * @title DCAExecutionClient
 * @author PowerPool
 */
contract DCAExecutionClient is Ownable {

    address public agent;
    DCASidechainAgent public dcaAgent;

    constructor(address agent_, address dcaAgent_) {
        agent = agent_;
        dcaAgent = DCASidechainAgent(dcaAgent_);
    }

    function makeOrderToBuy(
        address _owner,
        address _destination,
        DCASidechainAgent.OrderTokenData memory _tokenData,
        uint256 _buyPeriod,
        uint256 _marketChainId,
        uint256 _deactivateOn
    ) external onlyOwner {
        dcaAgent.makeOrderToBuy(owner(), _destination, _tokenData, _buyPeriod, _marketChainId, _deactivateOn);
    }

    function executeOrderResolver() external view returns (bool, bytes memory) {
        return dcaAgent.clientResolver(address(this));
    }

    function getOrdersToExecute(uint256 _offset, uint256 _limit) external view returns(uint256[] memory orderIds, DCASidechainAgent.Order[] memory resultOrders) {
        return dcaAgent.getOrdersToExecute(address(this), _offset, _limit);
    }

    function initiateOrderExecution(
        uint256 _orderId,
        address _swapRouterAddress,
        bytes calldata _dataToCall,
        address _dlnSource,
        bytes calldata _dlnSourceData
    ) external {
        //TODO: check jobKey as first argument
        dcaAgent.initiateOrderExecution(_orderId, _swapRouterAddress, _dataToCall, _dlnSource, _dlnSourceData);
    }
}
