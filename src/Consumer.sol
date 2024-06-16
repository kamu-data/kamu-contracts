// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { OdfRequest, OdfResponse, IOdfClient } from "./Odf.sol";
import { WitnetCBOR as CborReader } from "witnet-solidity-bridge/contracts/libs/WitnetCBOR.sol";

contract Consumer {
    using OdfRequest for OdfRequest.Req;
    using OdfResponse for OdfResponse.Res;
    using CborReader for CborReader.CBOR;

    IOdfClient private oracle;

    string public province;
    uint64 public totalCases;

    constructor(address oracleAddr) {
        oracle = IOdfClient(oracleAddr);
    }

    modifier onlyOracle() {
        assert(msg.sender == address(oracle));
        _;
    }

    function startDistributeRewards() public {
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

    function onResult(OdfResponse.Res memory result) external onlyOracle {
        assert(result.numRecords() == 1);
        CborReader.CBOR[] memory record = result.record(0);
        province = record[0].readString();
        totalCases = uint64(int64(record[1].readInt()));
    }
}
