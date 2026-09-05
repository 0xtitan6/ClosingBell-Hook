// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Enum of current state of the market
enum Session {Regular, Extended, Overnight, Closed}

// Everything the hook needs from the oracle layer one swap
struct MarketState {
    Session session;
    bool isLive;
    uint256 price;
    uint256 updatedAt;
    bool hasQuoteFeed;
    uint256 quotePrice;
}

interface IMarketStateAdapter {

    // Current market state for this adapter's underlying
    // MUST NEVER REVERT — any failure resolves to isLive = false
    function getMarketState() external view returns (MarketState memory);
    
}