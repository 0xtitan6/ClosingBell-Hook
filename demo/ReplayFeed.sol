// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "../src/AggregatorV3Interface.sol";

/// Demo-only: replays real Chainlink rounds against the chain clock. `latestRoundData` returns the
/// last round published at or before `block.timestamp`, and later rounds do not exist yet, so a
/// fork started on Sunday sees the feed wake up on Monday night exactly as it did on mainnet.
contract ReplayFeed is AggregatorV3Interface {
    uint8 public immutable decimals;
    uint80[] internal ids;
    int256[] internal answers;
    uint256[] internal updatedAts;

    constructor(uint8 decimals_, uint80[] memory id, int256[] memory answer, uint256[] memory updatedAt) {
        decimals = decimals_;
        ids = id;
        answers = answer;
        updatedAts = updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        for (uint256 i = ids.length; i > 0; i--) {
            if (updatedAts[i - 1] <= block.timestamp) return _round(i - 1);
        }
        revert("No data present");
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) {
                if (updatedAts[i] > block.timestamp) revert("No data present");
                return _round(i);
            }
        }
        revert("No data present");
    }

    function _round(uint256 i) internal view returns (uint80, int256, uint256, uint256, uint80) {
        return (ids[i], answers[i], updatedAts[i], updatedAts[i], ids[i]);
    }
}
