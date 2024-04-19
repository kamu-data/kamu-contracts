// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { OdfOracle } from "../src/OdfOracle.sol";
import { Consumer } from "../src/Consumer.sol";

import { BaseScript } from "./Base.s.sol";

/// @dev See the Solidity Scripting tutorial:
/// https://book.getfoundry.sh/tutorials/solidity-scripting
contract Deploy is BaseScript {
    function run() public broadcast {
        OdfOracle oracle = new OdfOracle({ logConsumerErrorData: true });
        new Consumer(address(oracle));
    }
}
