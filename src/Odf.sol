// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { OdfRequest, CborWriter } from "./OdfRequest.sol";
import { OdfResponse, CborReader } from "./OdfResponse.sol";

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
    function provideResult(uint64 requestId, bytes calldata result) external;
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

////////////////////////////////////////////////////////////////////////////////////////
