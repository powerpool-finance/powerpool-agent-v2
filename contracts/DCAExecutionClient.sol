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
        dcaAgent = dcaAgent_;
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

    function initiateOrderExecution(
        uint256 _orderId,
        address _swapRouterAddress,
        bytes calldata _dataToCall,
        address _dlnSource,
        bytes calldata _dlnSourceData
    ) external {
        dcaAgent.initiateOrderExecution(_orderId, _swapRouterAddress, _dataToCall, _dlnSource, _dlnSourceData);
    }
}
