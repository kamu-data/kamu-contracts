// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { OdfRequest, OdfResponse, IOdfClient, CborReader } from "./Odf.sol";

contract Consumer {
    using OdfRequest for OdfRequest.Req;
    using OdfResponse for OdfResponse.Res;
    using CborReader for CborReader.CBOR;

    IOdfClient private oracle;

    constructor(address oracleAddr) {
        oracle = IOdfClient(oracleAddr);
    }

    modifier onlyOracle() {
        // solhint-disable-next-line custom-errors
        require(msg.sender == address(oracle), "Can only be called by oracle");
        _;
    }

    // Specific query
    function initiateQuery() public {
        OdfRequest.Req memory req = OdfRequest.init();
        req.dataset(
            "kamu/covid19.canada.case-details",
            "did:odf:fed014895afeb476d5d94c1af0668f30ab661c8561760bba6744e43225ba52e099595"
        );
        req.sql(
            "with by_provice as ("
            "select province, count(*) as count from 'kamu/covid19.canada.case-details' group by 1),"
            "ranked as (select row_number() over (order by count desc) as rank, province, count from by_provice)"
            "select province, count from ranked where rank = 1"
        );
        oracle.sendRequest(req, this.onResult);
    }

    string public province;
    uint64 public totalCases;

    function onResult(OdfResponse.Res memory result) external onlyOracle {
        // solhint-disable-next-line custom-errors
        require(result.numRecords() == 1, "Expected one record");

        CborReader.CBOR[] memory record = result.record(0);
        province = record[0].readString();
        totalCases = uint64(int64(record[1].readInt()));
    }

    // Generic query
    function initiateQueryGeneric(
        string memory sql,
        string memory datasetAlias,
        string memory datasetId
    )
        public
    {
        OdfRequest.Req memory req = OdfRequest.init();
        req.dataset(datasetAlias, datasetId);
        req.sql(sql);
        oracle.sendRequest(req, this.onResultGeneric);
    }

    bool public resultOk;
    uint64 public numRecords;
    string public errorMessage;

    function onResultGeneric(OdfResponse.Res memory result) external onlyOracle {
        resultOk = result.ok();
        numRecords = result.numRecords();
        errorMessage = result.errorMessage();
    }
}
