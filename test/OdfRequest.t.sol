// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
import { OdfRequest } from "../src/Odf.sol";

contract OdfOracleTest is Test {
    using OdfRequest for OdfRequest.Req;

    function testRequestEncoding() public pure {
        OdfRequest.Req memory req = OdfRequest.init();
        req.dataset(
            "my_temp_sensor",
            "did:odf:fed014895afeb476d5d94c1af0668f30ab661c8561760bba6744e43225ba52e099595"
        );
        req.sql(
            "select event_time, value " "from my_temp_sensor " "order by offset desc " "limit 1"
        );
        // CBOR (use https://cbor.me/):
        // [
        //   1,
        //   "ds",
        //   "my_temp_sensor",
        //   h'ED014895AFEB476D5D94C1AF0668F30AB661C8561760BBA6744E43225BA52E099595',
        //   "sql",
        //   "select event_time, value from my_temp_sensor order by offset desc limit 1"
        // ]
        assertEq(
            req.intoBytes(),
            hex"9f016264736e6d795f74656d705f73656e736f725822ed014895afeb476d5d94c1af0668f30ab661c8561760bba6744e43225ba52e0995956373716c784973656c656374206576656e745f74696d652c2076616c75652066726f6d206d795f74656d705f73656e736f72206f72646572206279206f66667365742064657363206c696d69742031ff"
        );
    }
}
