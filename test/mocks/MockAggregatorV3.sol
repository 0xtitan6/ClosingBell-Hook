// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "../../src/AggregatorV3Interface.sol";

/// @notice Canned Chainlink feed. Push rounds in order; reads behave like a real proxy:
///         `getRoundData` reverts "No data present" for unknown rounds, and round ids carry a
///         phase id in the top 16 bits like a real proxy.
contract MockAggregatorV3 is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool exists;
    }

    uint8 internal dec;
    uint80 public latestRoundId;
    mapping(uint80 => Round) internal rounds;

    bool public revertLatest; // latestRoundData reverts
    bool public revertDecimals; // decimals() reverts
    bool public revertHistory; // getRoundData reverts for every round

    constructor(uint8 decimals_, uint80 firstRoundId) {
        dec = decimals_;
        latestRoundId = firstRoundId - 1;
    }

    // ── writes ──────────────────────────────────────────────────────────────

    /// @notice Append a print. Real feeds re-print an unchanged answer on heartbeat; do that here too.
    function push(int256 answer, uint256 updatedAt) external returns (uint80 id) {
        id = ++latestRoundId;
        rounds[id] = Round(answer, updatedAt, true);
    }

    /// @notice Overwrite the latest round in place (e.g. to set an odd updatedAt).
    function setLatest(int256 answer, uint256 updatedAt) external {
        rounds[latestRoundId] = Round(answer, updatedAt, true);
    }

    function setDecimals(uint8 d) external {
        dec = d;
    }

    function setRevertLatest(bool r) external {
        revertLatest = r;
    }

    function setRevertDecimals(bool r) external {
        revertDecimals = r;
    }

    function setRevertHistory(bool r) external {
        revertHistory = r;
    }

    // ── reads ───────────────────────────────────────────────────────────────

    function decimals() external view returns (uint8) {
        if (revertDecimals) revert("no decimals");
        return dec;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (revertLatest) revert("feed down");
        Round memory r = rounds[latestRoundId];
        if (!r.exists) revert("No data present");
        return (latestRoundId, r.answer, r.updatedAt, r.updatedAt, latestRoundId);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (revertHistory) revert("history down");
        Round memory r = rounds[id];
        if (!r.exists) revert("No data present");
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}

/// @notice A tokenized stock exposing the ERC-8056 `oraclePaused()` corporate-action flag.
contract MockPausableStock {
    bool public paused;
    bool public reverting;

    function setPaused(bool p) external {
        paused = p;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function oraclePaused() external view returns (bool) {
        if (reverting) revert("no such function");
        return paused;
    }
}

/// @notice Returns caller-chosen raw bytes for any selector: for proving the adapter survives
///         malformed return data (which `try/catch` cannot catch).
contract MockRawReturner {
    mapping(bytes4 => bytes) internal ret;

    function set(bytes4 sel, bytes memory r) external {
        ret[sel] = r;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return ret[msg.sig];
    }
}
