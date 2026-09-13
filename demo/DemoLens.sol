// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MarketHours, Session} from "../src/MarketHours.sol";
import {IMarketStateAdapter, MarketState} from "../src/IMarketStateAdapter.sol";

/// Demo-only read helper: one call that returns everything the UI shows.
/// Not part of the hook. Session comes from the same MarketHours library the hook uses.
contract DemoLens {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    IMarketStateAdapter public immutable adapter;
    PoolId public immutable poolId;

    constructor(IPoolManager pm_, IMarketStateAdapter adapter_, PoolId poolId_) {
        pm = pm_;
        adapter = adapter_;
        poolId = poolId_;
    }

    struct View {
        uint256 timestamp;
        uint8 session; // 0 Closed, 1 Regular, 2 Extended, 3 Overnight
        uint256 lastClose;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 poolPrice; // USDG per AAPL, 1e18 (USDG 6 dec is token0, AAPL 18 dec is token1)
        MarketState market;
        uint256 refPrice; // stock / quote, 1e18
    }

    function state() external view returns (View memory v) {
        v.timestamp = block.timestamp;
        (Session s, uint256 lastClose) = MarketHours.calendar(block.timestamp);
        v.session = uint8(s);
        v.lastClose = lastClose;
        (v.sqrtPriceX96,,,) = pm.getSlot0(poolId);
        v.liquidity = pm.getLiquidity(poolId);
        if (v.sqrtPriceX96 != 0) {
            uint256 inv = FullMath.mulDiv(1 << 96, 1 << 96, v.sqrtPriceX96);
            v.poolPrice = FullMath.mulDiv(inv, 1e18 * 1e18, uint256(v.sqrtPriceX96) * 1e6);
        }
        v.market = adapter.getMarketState();
        if (v.market.hasQuoteFeed && v.market.quotePrice != 0) {
            v.refPrice = FullMath.mulDiv(v.market.price, 1e18, v.market.quotePrice);
        } else if (!v.market.hasQuoteFeed) {
            v.refPrice = v.market.price;
        }
    }
}
