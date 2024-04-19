// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { WitnetCBOR as CborReader } from "witnet-solidity-bridge/contracts/libs/WitnetCBOR.sol";
// TODO: Replace this library as it pulls in an absurd number of dependencies
import { CBOR as CborWriter } from "solidity-cborutils/contracts/CBOR.sol";

////////////////////////////////////////////////////////////////////////////////////////

// Requests are represented as a CBOR-encoded object that carry all
// parameters:
//
// {
//   "sql": "select ...",
//   ...
// }
//
library OdfRequest {
    using CborWriter for CborWriter.CBORBuffer;

    struct Req {
        CborWriter.CBORBuffer _buf;
    }

    function init() internal pure returns (Req memory) {
        CborWriter.CBORBuffer memory buf = CborWriter.create(1024);
        buf.startMap();
        return Req(buf);
    }

    function intoBytes(Req memory self) internal pure returns (bytes memory) {
        self._buf.endSequence();
        return self._buf.data();
    }

    function sql(Req memory self, string memory _sql) internal pure {
        self._buf.writeKVString("sql", _sql);
    }
}

////////////////////////////////////////////////////////////////////////////////////////

// Responses are deserialized from CBOR of the following structure:
//
// {
//   "data": [
//     [r1c1, r1c2, ...],
//     [r2c1, r2c2, ...],
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

// Interface used by executors
interface IOdfProvider {
    // Emitted when client request was made and awaits a response
    event SendRequest(uint64 indexed requestId, address indexed consumerAddr, bytes request);

    // Emitted when an executor fulfills a pending request
    event ProvideResult(
        uint64 indexed requestId,
        address indexed consumerAddr,
        address indexed executorAddr,
        bytes result,
        bool consumerError,
        bytes consumerErrorData
    );

    // Returned when executor was not registered to provide results to the oracle
    error UnauthorizedExecutor(address executorAddr);

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
    // Emitted when executor is authorized
    event AddExecutor(address indexed executorAddr);

    // Emitted when executor authorization is revoked
    event RemoveExecutor(address indexed executorAddr);

    // Register an authorized executor
    function addExecutor(address _addr) external;

    // Revoke the authorization from an executor to supply results
    function removeExecutor(address _addr) external;
}
