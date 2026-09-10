// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Everything the hook needs to know about the outside world to price one swap.
struct MarketState {
    bool isLive;                            // price trustworthy? false if stale, broken or frozen
    uint256 price;                          // price of the stock
                                            // gap is the stock's doing or the pool's (B9). Both equal to the price above means no move;
                                            // both zero means we do not know, so we charge.
    uint256 loPrice;                        // highest price
    uint256 hiPrice;                        // lowest price
    bool hasQuoteFeed;                      // true when the pool prices the stock in something other than dollars (stock/SPY)
    uint256 quotePrice;                     // what that other thing is worth
    uint256 loQuotePrice;                   // its recent range, same rules as loPrice/hiPrice above
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
