// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMarketStateAdapter, MarketState, Session} from "../../src/IMarketStateAdapter.sol";

/// @notice Canned oracle for hook tests. Set any MarketState, then swap.
contract MockMarketStateAdapter is IMarketStateAdapter {
    MarketState internal state;
    bool public reverting; // simulate a broken adapter (violates the interface contract)

    constructor() {
        // Sensible default: Regular hours, live, $100 reference, fresh print, dollar quote.
        state = MarketState({
            session: Session.Regular,
            isLive: true,
            price: 100e18,
            loPrice: 100e18,
            hiPrice: 100e18,
            updatedAt: block.timestamp,
            hasQuoteFeed: false,
            quotePrice: 0,
            loQuotePrice: 0,
            hiQuotePrice: 0
        });
    }

    function getMarketState() external view returns (MarketState memory) {
        if (reverting) revert("adapter down");
        return state;
    }

    // ── setters ─────────────────────────────────────────────────────────────

    function set(MarketState memory s) external {
        state = s;
    }

    function setSession(Session s) external {
        state.session = s;
    }

    function setLive(bool live) external {
        state.isLive = live;
    }

    function setPrice(uint256 price) external {
        state.price = price;
    }

    /// @notice The feed's recent window. (0, 0) = unknown history; lo == hi == price = no move.
    function setWindow(uint256 lo, uint256 hi) external {
        state.loPrice = lo;
        state.hiPrice = hi;
    }

    /// @notice Simulate a reference print: the window becomes {old price, new price}.
    function print(uint256 newPrice) external {
        (state.loPrice, state.hiPrice) = state.price < newPrice ? (state.price, newPrice) : (newPrice, state.price);
        state.price = newPrice;
        state.updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        state.updatedAt = t;
    }

    function setQuote(bool has, uint256 quotePrice, uint256 loQuote, uint256 hiQuote) external {
        state.hasQuoteFeed = has;
        state.quotePrice = quotePrice;
        state.loQuotePrice = loQuote;
        state.hiQuotePrice = hiQuote;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    /// @notice Simulate a dead feed: price 0, not live.
    function kill() external {
        state.isLive = false;
        state.price = 0;
        state.loPrice = 0;
        state.hiPrice = 0;
    }
}
