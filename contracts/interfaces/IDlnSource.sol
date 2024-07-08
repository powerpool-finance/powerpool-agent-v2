// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../utils/DlnOrderLib.sol";

interface IDlnSource {
    function validateCreationOrder(DlnOrderLib.OrderCreation calldata _orderCreation, address _signer)
        external
        view
        returns (DlnOrderLib.Order calldata order);

    function getOrderId(DlnOrderLib.Order calldata _order) external pure returns (bytes32);
}