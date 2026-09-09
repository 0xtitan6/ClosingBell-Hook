// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The parts of a Chainlink price feed this project reads.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Tokenized stocks flag themselves frozen during a corporate action such as a split.
interface IOraclePausable {
    function oraclePaused() external view returns (bool);
}
