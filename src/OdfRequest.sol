// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { CborWriter } from "./CborWriter.sol";

////////////////////////////////////////////////////////////////////////////////////////

// Requests are represented as a CBOR-encoded flat array that carries all the parameters:
//
// [
//   version,
//   "ds", "alias1", "did:odf:...",
//   "ds", "alias2", "did:odf:...",
//   "sql", "select ...",
//   ...
// ]
//
// The `dataset` method MUST be used to associate all intput aliases with their IDs to
// both avoid the risks of getting wrong data is dataset is renamed, and to allow
// providers quickly test in they have necessary data to satisfy the request.
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

    // Associates an alias used in the query with a specific ODF dataset ID
    function dataset(Req memory self, string memory _alias, string memory _did) internal pure {
        self._buf.writeString("ds");
        self._buf.writeString(_alias);
        self._buf.writeString(_did);
    }
}

////////////////////////////////////////////////////////////////////////////////////////
