// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
// import { console2 } from "forge-std/src/console2.sol";

import {
    OdfRequest,
    OdfResponse,
    IOdfClient,
    IOdfProvider,
    IOdfAdmin,
    CborReader
} from "../src/Odf.sol";
import { OdfOracle } from "../src/OdfOracle.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract OdfOracleTest is Test {
    using OdfRequest for OdfRequest.Req;
    using OdfResponse for OdfResponse.Res;
    using CborReader for CborReader.CBOR;

    OdfOracle internal oracle;

    function setUp() public virtual {
        oracle = new OdfOracle({ logConsumerErrorData: false });
    }

    function testOwnerCanAddProvider() public {
        vm.expectEmit(true, true, true, true);
        emit IOdfAdmin.AddProvider(address(0x123));

        oracle.addProvider(address(0x123));
    }

    function testNonOwnerCantAddProvider() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x1))
        );
        vm.prank(address(0x1));
        oracle.addProvider(address(0x123));
    }

    function testProvideResultUnauthorizedProvider() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOdfProvider.UnauthorizedProvider.selector, address(this))
        );
        oracle.provideResult(1, OdfResponse.empty(1).intoBytes());
    }

    function testProvideResultRequestNotFound() public {
        oracle.addProvider(address(this));
        vm.expectRevert(abi.encodeWithSelector(IOdfProvider.RequestNotFound.selector, 1));
        oracle.provideResult(1, OdfResponse.empty(1).intoBytes());
    }

    function testProvideResultSuccess() public {
        oracle.addProvider(address(this));

        HappyConsumer consumer = new HappyConsumer(address(oracle));

        vm.expectEmit(true, true, true, false);
        emit IOdfProvider.SendRequest(1, address(consumer), "");
        consumer.makeReuqest();

        // CBOR:
        // [
        //   1,
        //   true,
        //   [["test"]],
        //   "data-hash",
        //   ["did:odf:1", "block-hash"]
        // ]
        bytes memory response = hex"8501F58181647465737469646174612D"
            hex"6861736882696469643A6F64663A316A626C6F636B2D68617368";

        vm.expectEmit(true, true, true, true);
        emit IOdfProvider.ProvideResult(
            1, address(consumer), address(this), response, false, false, ""
        );

        oracle.provideResult(1, response);
        assertEq(consumer.value(), "test");
    }

    function testProvideResultSqlError() public {
        oracle.addProvider(address(this));

        HappyConsumer consumer = new HappyConsumer(address(oracle));

        vm.expectEmit(true, true, true, false);
        emit IOdfProvider.SendRequest(1, address(consumer), "");
        consumer.makeReuqest();

        // CBOR:
        // [
        //   1,
        //   false,
        //   "Invalid SQL"
        // ]
        bytes memory response = hex"8301F46B496E76616C69642053514C";

        vm.expectEmit(true, true, true, true);
        emit IOdfProvider.ProvideResult(
            1, address(consumer), address(this), response, true, false, ""
        );

        oracle.provideResult(1, response);
        assertEq(consumer.value(), "Invalid SQL");
    }

    function commonProvideResultConsumerSideError(ConsumerBase consumer) public {
        oracle.addProvider(address(this));

        consumer.makeReuqest();

        // CBOR:
        // {
        //   "ok": true,
        //   "data": [["test"]],
        //   "dataHash": "data-hash",
        //   "state": [
        //     "did:odf:1", "block-hash"
        //   ]
        // }
        bytes memory response = hex"8501F58181647465737469646174612D"
            hex"6861736882696469643A6F64663A316A626C6F636B2D68617368";

        vm.expectEmit(true, true, true, true);
        emit IOdfProvider.ProvideResult(
            1, address(consumer), address(this), response, false, true, ""
        );

        oracle.provideResult(1, response);
    }

    function testProvideResultConsumerSideAssertion() public {
        commonProvideResultConsumerSideError(new FaultyConsumerAssertion(address(oracle)));
    }

    function testProvideResultConsumerSideRevertString() public {
        commonProvideResultConsumerSideError(new FaultyConsumerRevertString(address(oracle)));
    }

    function testProvideResultConsumerSideRevertCustomError() public {
        commonProvideResultConsumerSideError(new FaultyConsumerRevertCustomError(address(oracle)));
    }
}

abstract contract ConsumerBase {
    using OdfRequest for OdfRequest.Req;

    IOdfClient private oracle;
    string public value;

    constructor(address oracleAddr) {
        oracle = IOdfClient(oracleAddr);
    }

    modifier onlyOracle() {
        // solhint-disable-next-line custom-errors
        require(msg.sender == address(oracle), "Called by non oracle");
        _;
    }

    function makeReuqest() public {
        OdfRequest.Req memory req = OdfRequest.init();
        req.sql("select value from x");
        oracle.sendRequest(req, this.onResult);
    }

    function onResult(OdfResponse.Res memory result) external virtual;
}

contract HappyConsumer is ConsumerBase {
    using OdfResponse for OdfResponse.Res;
    using CborReader for CborReader.CBOR;

    constructor(address oracleAddr) ConsumerBase(oracleAddr) { }

    function onResult(OdfResponse.Res memory result) external override onlyOracle {
        if (result.ok()) {
            // solhint-disable-next-line custom-errors
            require(result.numRecords() == 1, "Expected one record");
            value = result.record(0)[0].readString();
        } else {
            value = result.errorMessage();
        }
    }
}

contract FaultyConsumerAssertion is ConsumerBase {
    constructor(address oracleAddr) ConsumerBase(oracleAddr) { }

    function onResult(OdfResponse.Res memory) external view override onlyOracle {
        // solhint-disable-next-line custom-errors
        require(0 == 100_500, "Unexpected result");
    }
}

contract FaultyConsumerRevertString is ConsumerBase {
    constructor(address oracleAddr) ConsumerBase(oracleAddr) { }

    function onResult(OdfResponse.Res memory) external view override onlyOracle {
        // solhint-disable-next-line custom-errors
        revert("Don't want it");
    }
}

contract FaultyConsumerRevertCustomError is ConsumerBase {
    error Err(string reason);

    constructor(address oracleAddr) ConsumerBase(oracleAddr) { }

    function onResult(OdfResponse.Res memory) external view override onlyOracle {
        revert Err("Just 'cause");
    }
}
