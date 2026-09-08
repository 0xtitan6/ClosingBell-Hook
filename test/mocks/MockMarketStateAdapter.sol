// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMarketStateAdapter, MarketState, Session} from "../../src/IMarketStateAdapter.sol";

/// @notice Canned oracle for hook tests. Set any MarketState, then swap.
contract MockMarketStateAdapter is IMarketStateAdapter {
    MarketState internal state;

    constructor() {
        // Sensible default: Regular hours, live, $100 reference, fresh print, dollar quote.
        state = MarketState({
            session: Session.Regular,
            isLive: true,
            price: 100e18,
            prevPrice: 100e18,
            updatedAt: block.timestamp,
            hasQuoteFeed: false,
            quotePrice: 0
        });
    }

    function getMarketState() external view returns (MarketState memory) {
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

    function setPrevPrice(uint256 p) external {
        state.prevPrice = p;
    }

    /// @notice Simulate a reference print: the old price becomes prevPrice.
    function print(uint256 newPrice) external {
        state.prevPrice = state.price;
        state.price = newPrice;
        state.updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        state.updatedAt = t;
    }

    function setQuote(bool has, uint256 quotePrice) external {
        state.hasQuoteFeed = has;
        state.quotePrice = quotePrice;
    }

    /// @notice Simulate a dead feed: price 0, not live.
    function kill() external {
        state.isLive = false;
        state.price = 0;
        state.prevPrice = 0;
    }
}
