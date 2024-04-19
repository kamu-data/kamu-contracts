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

    struct ExecutorInfo {
        address addr;
    }

    bool private immutable LOG_CONSUMER_ERROR_DATA;
    uint64 private lastRequestId = 0;

    mapping(address executorAddress => ExecutorInfo executorInfo) private executors;
    mapping(uint64 requestId => PendingRequest pendingRequest) private requests;

    constructor(bool logConsumerErrorData) Ownable(msg.sender) {
        LOG_CONSUMER_ERROR_DATA = logConsumerErrorData;
    }

    modifier onlyAuthorizedExecutor() {
        if (executors[msg.sender].addr == address(0)) revert UnauthorizedExecutor(msg.sender);
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
        lastRequestId += 1;
        requests[lastRequestId] = PendingRequest(lastRequestId, _callback);

        bytes memory requestData = _request.intoBytes();
        emit SendRequest(lastRequestId, _callback.address, requestData);

        return lastRequestId;
    }

    // IOdfProvider

    function canProvideResults(address _addr) external view returns (bool) {
        return executors[_addr].addr != address(0);
    }

    function provideResult(
        uint64 _requestId,
        bytes memory _result
    )
        external
        onlyAuthorizedExecutor
    {
        PendingRequest memory req = requests[_requestId];
        if (req.requestId != _requestId) {
            revert RequestNotFound(_requestId);
        }
        delete requests[_requestId];

        OdfResponse.Res memory res = OdfResponse.fromBytes(_requestId, _result);

        // TODO: Trap errors, as failure of a consumer contract doesn't mean that the oracle failed
        // to provide a valid result
        try req.callback(res) {
            emit ProvideResult(_requestId, req.callback.address, msg.sender, _result, false, "");
        } catch (bytes memory consumerErrorData) {
            if (!LOG_CONSUMER_ERROR_DATA) {
                consumerErrorData = "";
            }
            emit ProvideResult(
                _requestId, req.callback.address, msg.sender, _result, true, consumerErrorData
            );
        }
    }

    // IOdfAdmin

    // Register an authorized executor
    function addExecutor(address _addr) external onlyOwner {
        executors[_addr] = ExecutorInfo(_addr);
        emit AddExecutor(_addr);
    }

    // Revoke the authorization from an executor to supply results
    function removeExecutor(address _addr) external onlyOwner {
        delete executors[_addr];
        emit RemoveExecutor(_addr);
    }
}
