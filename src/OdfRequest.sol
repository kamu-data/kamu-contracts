// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { CborWriter } from "./CborWriter.sol";

////////////////////////////////////////////////////////////////////////////////////////

// ODF Oracle request builder.
//
// Example use:
//
//   using OdfRequest for OdfRequest.Req;
//
//   OdfRequest.Req memory req = OdfRequest.init();
//   req.dataset(
//       "my_temp_sensor",
//       "did:odf:fed014895afeb476d5d94c1af0668f30ab661c8561760bba6744e43225ba52e099595"
//   );
//   req.sql(
//       "select event_time, value "
//       "from my_temp_sensor "
//       "order by offset desc "
//       "limit 1"
//   );
//   oracle.sendRequest(req, this.callback);
//
// Requests are represented as a CBOR-encoded flat array that carries all the parameters:
//
//   [
//     version,
//     "ds", "alias1", b"did:odf:x",
//     "ds", "alias2", b"did:odf:y",
//     "sql", "select ...",
//     ...
//   ]
//
// The `dataset` method MUST be used to associate all intput aliases with their IDs to
// both avoid the risks of getting wrong data is dataset is renamed, and to allow
// providers quickly test in they have necessary data to satisfy the request.
//
// Note that DIDs are encoded as binaries to save space.
//
library OdfRequest {
    using CborWriter for CborWriter.CBORBuffer;

    // Protocol version - always written as the first element of the CBOR array.
    uint16 public constant VERSION = 1;

    struct Req {
        CborWriter.CBORBuffer _buf;
    }

    // Creates a new empty request with protocol version set
    function init() internal pure returns (Req memory) {
        CborWriter.CBORBuffer memory buf = CborWriter.create(1024);
        buf.startArray();
        buf.writeUInt64(VERSION);
        return Req(buf);
    }

    // Finishes construction of the request returning the bytes representation
    function intoBytes(Req memory self) internal pure returns (bytes memory) {
        self._buf.endSequence();
        return self._buf.data();
    }

    // Specifies the SQL query (only one query is allowed per request)
    function sql(Req memory self, string memory _sql) internal pure {
        self._buf.writeString("sql");
        self._buf.writeString(_sql);
    }

    // Associates an alias used in the query with a specific ODF dataset ID.
    //
    // Example:
    //
    //   req.dataset(
    //      "foo",
    //      "did:odf:fed014895afeb476d5d94c1af0668f30ab661c8561760bba6744e43225ba52e099595"
    //   )
    //
    // If you don't want to pay for the cost of DID parsing - use `datasetRaw()` function.
    function dataset(Req memory self, string memory _alias, string memory _did) internal pure {
        bytes memory didBin = didToBytes(_did);
        datasetRaw(self, _alias, didBin);
    }

    // Associates an alias used in the query with a specific ODF dataset ID given in binary form.
    //
    // Example:
    //
    //   req.datasetRaw(
    //      "foo",
    //      hex"ed014895afeb476d5d94c1af0668f30ab661c8561760bba6744e43225ba52e099595"
    //   )
    //
    // If you don't want to pay for the cost of DID parsing - use `datasetRaw()` function.
    function datasetRaw(Req memory self, string memory _alias, bytes memory _did) internal pure {
        self._buf.writeString("ds");
        self._buf.writeString(_alias);
        self._buf.writeBytes(_did);
    }

    // solhint-disable custom-errors
    function didToBytes(string memory _did) private pure returns (bytes memory) {
        bytes memory bin = bytes(_did);

        require(bin.length == 77, "Invalid DID");
        require(bytes9(bin) == "did:odf:f", "Invalid DID");

        bytes memory result = new bytes(34);

        for (uint16 i = 0; i < 34; i++) {
            uint16 s = i * 2 + 9;
            result[i] = bytes1((hexToInt(bin[s]) << 4) + hexToInt(bin[s + 1]));
        }

        return result;
    }

    // solhint-disable custom-errors
    function hexToInt(bytes1 c) public pure returns (uint8) {
        if (c >= bytes1("0") && c <= bytes1("9")) {
            return uint8(c) - uint8(bytes1("0"));
        }
        if (bytes1(c) >= bytes1("a") && bytes1(c) <= bytes1("f")) {
            return 10 + uint8(c) - uint8(bytes1("a"));
        }
        if (bytes1(c) >= bytes1("A") && bytes1(c) <= bytes1("F")) {
            return 10 + uint8(c) - uint8(bytes1("A"));
        }
        revert("Not a hex char");
    }
}

////////////////////////////////////////////////////////////////////////////////////////
