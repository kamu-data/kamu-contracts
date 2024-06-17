// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { WitnetCBOR as CborReader } from "witnet-solidity-bridge/contracts/libs/WitnetCBOR.sol";
// TODO: Replace this library as it pulls in an absurd number of dependencies
import { CBOR as CborWriter } from "solidity-cborutils/contracts/CBOR.sol";

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
//   "<data-logical-multihash>",
//   [
//     "odf:did:...", "<dataset1-block-multihash>",
//     "odf:did:...", "<dataset2-block-multihash>",
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

// Interface used by client contracts
interface IOdfClient {
    // Current contract was disabled and you need to upgrade to a new one
    error ContractDisabled();

    // Called by the clients to request off-chain data
    function sendRequest(
        OdfRequest.Req memory request,
        function(OdfResponse.Res memory) external callback
    )
        external
        payable
        returns (uint64);
}

////////////////////////////////////////////////////////////////////////////////////////

// Interface used by data providers
interface IOdfProvider {
    // Emitted when client request was made and awaits a response
    event SendRequest(uint64 indexed requestId, address indexed consumerAddr, bytes request);

    // Emitted when a provider fulfills a pending request.
    //
    // Fields:
    // - requestId - unique identifier of the request
    // - consumerAddr - address of the contract that sent request and awaits the response
    // - providerAddr - address of the provider that fulfilled the request
    // - response - response data, see `OdfResponse`
    // - requestError - indicates that response contained an unrecoverable error instead of data
    // - consumerError - indicates that consumer callback has failed when processing the result
    // - consumerErrorData - will contain the details of consumer-side error
    event ProvideResult(
        uint64 indexed requestId,
        address indexed consumerAddr,
        address indexed providerAddr,
        bytes response,
        bool requestError,
        bool consumerError,
        bytes consumerErrorData
    );

    // Returned when provider was not registered to provide results to the oracle
    error UnauthorizedProvider(address providerAddr);

    // Returned when pending request by this ID is not found
    error RequestNotFound(uint64 requestId);

    // Returns true/false whether `addr` is authorized to provide results to this oracle
    function canProvideResults(address addr) external view returns (bool);

    // Called to fulfill a pending request
    // See `OdfResponse` for explanation of the `result`
    function provideResult(uint64 requestId, bytes memory result) external;
}

////////////////////////////////////////////////////////////////////////////////////////

// Interface used by oracle admins
interface IOdfAdmin {
    // Emitted when a provider is authorized
    event AddProvider(address indexed providerAddr);

    // Emitted when a provider authorization is revoked
    event RemoveProvider(address indexed providerAddr);

    // Authorizes a provider to supply results
    function addProvider(address providerAddr) external;

    // Revoke the authorization from a provider to supply results
    function removeProvider(address providerAddr) external;
}
