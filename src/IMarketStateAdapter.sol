// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Everything the hook needs to know about the outside world to price one swap.
struct MarketState {
    bool isLive; // can we trust the price below? false if the feed is broken, stale or frozen
    uint256 price; // what the stock is really worth; 0 if we could not find out
    // Highest and lowest prices published recently. The hook uses this range to work out whether a
    // gap is the stock's doing or the pool's (B9). Both equal to the price above means no move;
    // both zero means we do not know, so we charge.
    uint256 loPrice;
    uint256 hiPrice;
    bool hasQuoteFeed; // true when the pool prices the stock in something other than dollars
    uint256 quotePrice; // what that other thing is worth, and its recent range
    uint256 loQuotePrice;
    uint256 hiQuotePrice;
}

/// @notice The line between the hook and the outside world. The hook never needs to know where
///         prices came from, so the source can be swapped without touching the fee logic.
interface IMarketStateAdapter {
    /// @notice What the stock is worth right now, and whether that can be trusted.
    /// @dev MUST NEVER FAIL. On any problem report `isLive = false` and `price = 0`: the hook then
    ///      charges its highest rate and the pool keeps trading. A failure blocks every swap.
    function getMarketState() external view returns (MarketState memory);
}
