// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./VRFAgentConsumerInterface.sol";

interface DCAClientFactoryInterface {

    function createClient(address agent_, address owner_) external returns (address);

}
