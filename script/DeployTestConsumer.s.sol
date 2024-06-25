// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { OdfOracle } from "../src/OdfOracle.sol";
import { TestConsumer } from "../src/TestConsumer.sol";

import { BaseScript } from "./Base.s.sol";

contract DeployTestConsumer is BaseScript {
    function run() public broadcast {
        OdfOracle oracle = OdfOracle(vm.envAddress("ORACLE_CONTRACT_ADDR"));
        new TestConsumer(address(oracle));
    }
}
