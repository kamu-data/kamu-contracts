// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { OdfRequest, OdfResponse, IOdfClient, IOdfProvider, IOdfAdmin } from "./Odf.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
// import { console2 } from "forge-std/src/console2.sol";

////////////////////////////////////////////////////////////////////////////////////////

// TODO: Interface for consumer
contract OdfOracle is IOdfClient, IOdfProvider, IOdfAdmin, Ownable {
    using OdfRequest for OdfRequest.Req;
    using OdfResponse for OdfResponse.Res;

    struct PendingRequest {
        uint64 requestId;
        function(OdfResponse.Res memory) external callback;
    }

    struct ProviderInfo {
        address providerAddr;
    }

    bool private immutable LOG_CONSUMER_ERROR_DATA;
    uint64 private sLastRequestId = 0;

    mapping(address providerAddress => ProviderInfo providerInfo) private sProviders;
    mapping(uint64 requestId => PendingRequest pendingRequest) private sRequests;

    constructor(bool logConsumerErrorData) Ownable(msg.sender) {
        LOG_CONSUMER_ERROR_DATA = logConsumerErrorData;
    }

    modifier onlyAuthorizedProvider() {
        if (sProviders[msg.sender].providerAddr != msg.sender) {
            revert UnauthorizedProvider(msg.sender);
        }
        _;
    }

    // IOdfClient

    function sendRequest(
        OdfRequest.Req memory _request,
        function(OdfResponse.Res memory) external _callback
    )
        external
        returns (uint64)
    {
        sLastRequestId += 1;
        sRequests[sLastRequestId] = PendingRequest(sLastRequestId, _callback);

        bytes memory requestData = _request.intoBytes();
        emit SendRequest(sLastRequestId, _callback.address, requestData);

        return sLastRequestId;
    }

    // IOdfProvider

    function canProvideResults(address providerAddr) external view returns (bool) {
        return sProviders[providerAddr].providerAddr == providerAddr;
    }

    function provideResult(uint64 requestId, bytes memory result) external onlyAuthorizedProvider {
        PendingRequest memory req = sRequests[requestId];
        if (req.requestId != requestId) {
            revert RequestNotFound(requestId);
        }
        delete sRequests[requestId];

        OdfResponse.Res memory res = OdfResponse.fromBytes(requestId, result);

        // TODO: Trap errors, as failure of a consumer contract doesn't mean that the oracle failed
        // to provide a valid result
        try req.callback(res) {
            emit ProvideResult(requestId, req.callback.address, msg.sender, result, false, "");
        } catch (bytes memory consumerErrorData) {
            if (!LOG_CONSUMER_ERROR_DATA) {
                consumerErrorData = "";
            }
            emit ProvideResult(
                requestId, req.callback.address, msg.sender, result, true, consumerErrorData
            );
        }
    }

    // IOdfAdmin

    function addProvider(address providerAddr) external onlyOwner {
        sProviders[providerAddr] = ProviderInfo(providerAddr);
        emit AddProvider(providerAddr);
    }

    function removeProvider(address providerAddr) external onlyOwner {
        delete sProviders[providerAddr];
        emit RemoveProvider(providerAddr);
    }
}
