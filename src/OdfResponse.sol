// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { CborReader } from "./CborReader.sol";
import { CborWriter } from "./CborWriter.sol";

////////////////////////////////////////////////////////////////////////////////////////

// Responses are deserialized from CBOR with data using the Array-of-Arrays
// representation. State information is included that makes requests reproducible
// and verifiable.
//
// The successful response structure is as follows:
//
// [
//   1, // version
//   true, // success
//   [
//     [<row1-col1>, <row1-col2>, ...],
//     [<row2-col1>, <row2-col2>, ...],
//     ...
//   ],
//   b"<deprecated>",
//   [
//     b"odf:did:x", b"block1-multihash",
//     b"odf:did:y", b"block2-multihash",
//     ...
//   ]
// ]
//
// The unsuccessful response structure is:
//
// [
//   1, // version
//   false, // error
//   "SQL query error ..." // error message
// ]
//
// Note that DIDs and Multihashes are encoded as binaries to save space.
//
library OdfResponse {
    using CborReader for CborReader.CBOR;
    using CborWriter for CborWriter.CBORBuffer;

    uint16 public constant VERSION = 1;

    struct Res {
        uint64 _requestId;
        bool _ok;
        CborReader.CBOR[] _data;
        string _errorMessage;
    }

    // solhint-disable custom-errors
    function fromBytes(uint64 reqId, bytes memory data) internal pure returns (Res memory) {
        Res memory res;
        res._requestId = reqId;
        CborReader.CBOR[] memory root = CborReader.fromBytes(data).readArray();

        // NOTE: witnet library adds extra item to the end
        require(root.length == 5 + 1 || root.length == 3 + 1, "Invalid length");

        uint256 version = root[0].readUint();
        require(version == VERSION, "Unsupported response version");

        res._ok = root[1].readBool();
        if (res._ok) {
            res._data = root[2].readArray();
        } else {
            res._errorMessage = root[2].readString();
        }

        return res;
    }

    function requestId(Res memory self) internal pure returns (uint64) {
        return self._requestId;
    }

    // Tells whether result was successful and contains data or an error
    function ok(Res memory self) internal pure returns (bool) {
        return self._ok;
    }

    // Error message associated with unsuccessful response
    function errorMessage(Res memory self) internal pure returns (string memory) {
        return self._errorMessage;
    }

    function numRecords(Res memory self) internal pure returns (uint64) {
        // NOTE: witnet library adds extra item to the end
        return uint64(self._data.length - 1);
    }

    function records(Res memory self) internal pure returns (CborReader.CBOR[] memory) {
        return self._data;
    }

    function record(Res memory self, uint64 i) internal pure returns (CborReader.CBOR[] memory) {
        return self._data[i].readArray();
    }

    // For testing: constructs an empty successful response
    function empty(uint64 reqId) internal pure returns (Res memory) {
        Res memory res;
        res._requestId = reqId;
        res._ok = true;
        // NOTE: witnet library adds extra item to the end
        res._data = new CborReader.CBOR[](1);
        return res;
    }

    // For testing: constructs an unsuccessful response with specified error message
    function error(uint64 reqId, string memory errMessage) internal pure returns (Res memory) {
        Res memory res;
        res._requestId = reqId;
        res._ok = false;
        res._errorMessage = errMessage;
        return res;
    }

    // For testing: converts a response to bytes
    function intoBytes(Res memory self) internal pure returns (bytes memory) {
        CborWriter.CBORBuffer memory buf = CborWriter.create(1024);
        buf.startArray();
        buf.writeBool(self._ok);
        if (self._ok) {
            // Only supports empty data, hash, and state
            buf.startArray();
            buf.endSequence();
            buf.writeString("");
            buf.startArray();
            buf.endSequence();
        } else {
            buf.writeString(self._errorMessage);
        }
        buf.endSequence();
        return buf.data();
    }
}

////////////////////////////////////////////////////////////////////////////////////////
