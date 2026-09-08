// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Which trading session the stock market is in. Sets the fee floor.
///         `Closed` is deliberately the zero value: an empty struct reads as the safe default.
enum Session {Closed, Regular, Extended, Overnight}

/// @notice Everything the hook needs to know about the outside world for one swap.
struct MarketState {
    Session session; // market-wide: are we in regular hours, after hours, or closed?
    bool isLive; // can the price below be trusted? false if the feed is dead or paused
    uint256 price; // the stock's reference price, 1e18 units; 0 if the feed could not be read
    uint256 prevPrice; // the feed's previous print, so the hook can tell a fresh move from an old gap; 0 if unknown
    uint256 updatedAt; // when the feed last printed
    bool hasQuoteFeed; // true when the pool's other token is not a dollar (e.g. stock/SPY)
    uint256 quotePrice; // that token's reference price, 1e18; only meaningful if hasQuoteFeed
}

/// @notice The oracle boundary. The hook reads a `MarketState` and never needs to know where it
///         came from — Chainlink feeds today, a different source tomorrow, a mock in tests.
interface IMarketStateAdapter {
    /// @notice The current market state for this pool's stock.
    /// @dev MUST NEVER REVERT. If anything goes wrong reading a feed, return `isLive = false`
    ///      (and `price = 0`) — the hook then charges the highest floor and the pool stays open.
    ///      An adapter that reverts would block every swap in the pool.
    function getMarketState() external view returns (MarketState memory);
}
