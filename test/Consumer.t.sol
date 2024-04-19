// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
// import { console2 } from "forge-std/src/console2.sol";

import { Consumer } from "../src/Consumer.sol";
import { OdfResponse } from "../src/Odf.sol";
import { OdfOracle } from "../src/OdfOracle.sol";

contract ConsumerTest is Test {
    OdfOracle internal oracle;
    Consumer internal consumer;

    function setUp() public virtual {
        oracle = new OdfOracle({ logConsumerErrorData: false });
        consumer = new Consumer(address(oracle));
    }

    function testOnResultOnlyOracleRevert() public {
        vm.expectRevert();

        consumer.onResult(OdfResponse.empty(1));
    }

    function testOnResultOnlyOracleOk() public {
        vm.prank(address(oracle));

        // CBOR: {"data": [["ON", 100500]]}
        consumer.onResult(OdfResponse.fromBytes(1, hex"A164646174618182624F4E1A00018894"));

        assertEq(consumer.province(), "ON");
        assertEq(consumer.totalCases(), 100_500);
    }
}
