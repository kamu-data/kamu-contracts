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
    bool private _disabled = false;
    uint64 private _lastRequestId = 0;

    mapping(address providerAddress => ProviderInfo providerInfo) private _providers;
    mapping(uint64 requestId => PendingRequest pendingRequest) private _requests;

    constructor(bool logConsumerErrorData) Ownable(msg.sender) {
        LOG_CONSUMER_ERROR_DATA = logConsumerErrorData;
    }

    modifier ifEnabled() {
        if (_disabled) {
            revert ContractDisabled();
        }
        _;
    }

    modifier onlyAuthorizedProvider() {
        if (_providers[msg.sender].providerAddr != msg.sender) {
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
        payable
        ifEnabled
        returns (uint64)
    {
        _lastRequestId += 1;
        _requests[_lastRequestId] = PendingRequest(_lastRequestId, _callback);

        bytes memory requestData = _request.intoBytes();
        emit SendRequest(_lastRequestId, _callback.address, requestData);

        return _lastRequestId;
    }

    // IOdfProvider

    function canProvideResults(address providerAddr) external view ifEnabled returns (bool) {
        return _providers[providerAddr].providerAddr == providerAddr;
    }

    function provideResult(
        uint64 requestId,
        bytes calldata result
    )
        external
        ifEnabled
        onlyAuthorizedProvider
    {
        PendingRequest memory req = _requests[requestId];
        if (req.requestId != requestId) {
            revert RequestNotFound(requestId);
        }
        delete _requests[requestId];

        OdfResponse.Res memory response = OdfResponse.fromBytes(requestId, result);

        // TODO: Trap errors, as failure of a consumer contract doesn't mean that the oracle failed
        // to provide a valid result
        try req.callback(response) {
            emit ProvideResult(
                requestId, req.callback.address, msg.sender, result, !response.ok(), false, ""
            );
        } catch (bytes memory consumerErrorData) {
            if (!LOG_CONSUMER_ERROR_DATA) {
                consumerErrorData = "";
            }
            emit ProvideResult(
                requestId,
                req.callback.address,
                msg.sender,
                result,
                !response.ok(),
                true,
                consumerErrorData
            );
        }
    }

    // IOdfAdmin

    function addProvider(address providerAddr) external onlyOwner {
        _providers[providerAddr] = ProviderInfo(providerAddr);
        emit AddProvider(providerAddr);
    }

    function removeProvider(address providerAddr) external onlyOwner {
        delete _providers[providerAddr];
        emit RemoveProvider(providerAddr);
    }

    // Emergency

    function disableContract() external onlyOwner {
        _disabled = true;
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        // solhint-disable-next-line custom-errors
        require(amount <= address(this).balance, "Insufficient funds");
        to.transfer(amount);
    }
}
