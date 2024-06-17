// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
// import { console2 } from "forge-std/src/console2.sol";

import { TestConsumer } from "../src/TestConsumer.sol";
import { OdfResponse } from "../src/Odf.sol";
import { OdfOracle } from "../src/OdfOracle.sol";

contract ConsumerTest is Test {
    OdfOracle internal oracle;
    TestConsumer internal consumer;

    function setUp() public virtual {
        oracle = new OdfOracle({ logConsumerErrorData: false });
        consumer = new TestConsumer(address(oracle));
    }

    function testOnResultOnlyOracleRevert() public {
        vm.expectRevert();

        consumer.onResult(OdfResponse.empty(1));
    }

    function testOnResultOnlyOracleOk() public {
        vm.prank(address(oracle));

        // CBOR:
        // [
        //   1,
        //   true,
        //   [["ON", 100500]],
        //   "data-hash",
        //   ["did:odf:1", "block-hash"]
        // ]
        consumer.onResult(
            OdfResponse.fromBytes(
                1,
                hex"8501F58182624F4E1A0001889469646174612D6861736882696469643A6F64663A316A626C6F636B2D68617368"
            )
        );

        assertEq(consumer.province(), "ON");
        assertEq(consumer.totalCases(), 100_500);
    }
}
