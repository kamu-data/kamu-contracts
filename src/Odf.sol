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
    // It also defines the version of the response the consumer is expecting to receive
    // from a provider.
    uint64 public constant VERSION = 1;

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
// The structure is as follows:
//
// {
//   "data": [
//     [<row1-col1>, <row1-col2>, ...],
//     [<row2-col1>, <row2-col2>, ...],
//     ...
//   ],
//   "dataHash": "<data-logical-multihash>",
//   "state": [
//     "odf:did:...", "<dataset1-block-multihash>",
//     "odf:did:...", "<dataset2-block-multihash>",
//     ...
//   ]
// }
//
library OdfResponse {
    using CborReader for CborReader.CBOR;

    struct Res {
        uint64 _requestId;
        CborReader.CBOR[] _data;
    }

    function empty(uint64 reqId) internal pure returns (Res memory) {
        Res memory res;
        res._requestId = reqId;
        // NOTE: witnet library adds extra item to the end
        res._data = new CborReader.CBOR[](1);
        return res;
    }

    function fromBytes(uint64 reqId, bytes memory data) internal pure returns (Res memory) {
        Res memory res;
        res._requestId = reqId;
        CborReader.CBOR[] memory root = CborReader.fromBytes(data).readMap();
        // NOTE: witnet library adds extra item to the end
        assert(root.length == 2 + 1);

        assert(keccak256(bytes(root[0].readString())) == keccak256("data"));
        res._data = root[1].readArray();
        return res;
    }

    function requestId(Res memory self) internal pure returns (uint64) {
        return self._requestId;
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
}

////////////////////////////////////////////////////////////////////////////////////////

// Interface used by client contracts
interface IOdfClient {
    // Called by the clients to request off-chain data
    // TODO: payable?
    // TODO: memory vs calldata?
    function sendRequest(
        OdfRequest.Req memory request,
        function(OdfResponse.Res memory) external callback
    )
        external
        returns (uint64);
}

////////////////////////////////////////////////////////////////////////////////////////

// Interface used by data providers
interface IOdfProvider {
    // Emitted when client request was made and awaits a response
    event SendRequest(uint64 indexed requestId, address indexed consumerAddr, bytes request);

    // Emitted when a provider fulfills a pending request
    event ProvideResult(
        uint64 indexed requestId,
        address indexed consumerAddr,
        address indexed providerAddr,
        bytes result,
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
