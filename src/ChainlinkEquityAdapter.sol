// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Session, MarketState, IMarketStateAdapter} from "./IMarketStateAdapter.sol";
import {AggregatorV3Interface, IOraclePausable} from "./AggregatorV3Interface.sol";
import {Constants as C} from "./Constants.sol";
import {MarketHours} from "./MarketHours.sol";

/// @notice v1 oracle for ClosingBell: Chainlink Data Feeds plus the NYSE calendar.
///
/// Stateless and total. Every external read is quarantined; anything that fails degrades to
/// "not live" and the hook charges its highest floor with the pool still open. Nothing here can
/// block a swap.
///
/// `isLive` is a dead-feed net, not a halt detector (build note B1): the price is fresh, plausible
/// against the previous print, the token's corporate-action flag is clear, and the quote leg (if
/// any) is fresh too. `maxStaleness` must sit above the feed's 86400s heartbeat.
contract ChainlinkEquityAdapter is IMarketStateAdapter {
    error InvalidConfig();

    AggregatorV3Interface public immutable stockFeed;
    AggregatorV3Interface public immutable quoteFeed; // address(0) for dollar-quote pools
    address public immutable stockToken; // address(0) to skip the oraclePaused() check
    uint256 public immutable maxStaleness; // seconds; above the 86400s heartbeat
    uint256 public immutable plausibilityBps; // max jump vs the previous print; 0 disables

    constructor(
        address stockFeed_,
        address quoteFeed_,
        address stockToken_,
        uint256 maxStaleness_,
        uint256 plausibilityBps_
    ) {
        if (stockFeed_ == address(0) || maxStaleness_ <= 1 days) revert InvalidConfig();
        stockFeed = AggregatorV3Interface(stockFeed_);
        quoteFeed = AggregatorV3Interface(quoteFeed_);
        stockToken = stockToken_;
        maxStaleness = maxStaleness_;
        plausibilityBps = plausibilityBps_;
    }

    /// @inheritdoc IMarketStateAdapter
    function getMarketState() external view returns (MarketState memory m) {
        (m.session,) = MarketHours.calendar(block.timestamp);
        m.hasQuoteFeed = address(quoteFeed) != address(0);

        (m.price, m.prevPrice, m.updatedAt) = _leg(stockFeed);
        bool live = m.price != 0 && _fresh(m.updatedAt) && _plausible(m.price, m.prevPrice) && !_paused();

        if (m.hasQuoteFeed) {
            uint256 quoteAt;
            (m.quotePrice, m.prevQuotePrice, quoteAt) = _leg(quoteFeed);
            live = live && m.quotePrice != 0 && _fresh(quoteAt);
        }
        m.isLive = live;
    }

    // ── one feed ────────────────────────────────────────────────────────────

    /// @dev Latest price, previous different price, and the latest print time. Zeros on failure.
    function _leg(AggregatorV3Interface feed) internal view returns (uint256 price, uint256 prev, uint256 updatedAt) {
        if (address(feed).code.length == 0) return (0, 0, 0);
        uint8 dec;
        try feed.decimals() returns (uint8 d) {
            dec = d;
        } catch {
            return (0, 0, 0);
        }
        (bool ok, uint80 id, int256 answer, uint256 at) = _latest(feed);
        if (!ok) return (0, 0, 0);
        price = _scale(answer, dec);
        if (price == 0) return (0, 0, 0);
        updatedAt = at;
        prev = _scale(_prevAnswer(feed, id, answer, at), dec);
    }

    /// @dev The previous print the pool could have been tracking, walked from round history:
    ///      skip re-prints of the same answer; if two consecutive rounds are CLOSURE_GAP or more
    ///      apart the market was closed between them, and the print before the closure wins even
    ///      when a different print sits in between (a reopen followed by a retrace). 0 if unknown.
    function _prevAnswer(AggregatorV3Interface feed, uint80 id, int256 answer, uint256 updatedAt)
        internal
        view
        returns (int256 prev)
    {
        uint256 curAt = updatedAt;
        for (uint80 i = 1; i <= C.LOOKBACK; i++) {
            if (id < i) break;
            (bool ok, int256 a, uint256 at) = _round(feed, id - i);
            if (!ok || a <= 0) break;
            uint256 gap = at > curAt ? 0 : curAt - at;
            if (gap >= C.CLOSURE_GAP) return a;
            if (prev == 0 && a != answer) prev = a;
            curAt = at;
        }
    }

    function _latest(AggregatorV3Interface feed) internal view returns (bool ok, uint80 id, int256 answer, uint256 at) {
        try feed.latestRoundData() returns (uint80 rid, int256 a, uint256, uint256 updatedAt, uint80) {
            return (a > 0, rid, a, updatedAt);
        } catch {}
    }

    function _round(AggregatorV3Interface feed, uint80 rid) internal view returns (bool ok, int256 answer, uint256 at) {
        try feed.getRoundData(rid) returns (uint80, int256 a, uint256, uint256 updatedAt, uint80) {
            return (true, a, updatedAt);
        } catch {}
    }

    /// @dev Feed units to 1e18. 0 if the answer is not positive or the scaling would overflow.
    function _scale(int256 answer, uint8 dec) internal pure returns (uint256) {
        if (answer <= 0 || dec > 77) return 0;
        uint256 a = uint256(answer);
        if (dec <= 18) {
            uint256 f = 10 ** (18 - uint256(dec));
            return a > type(uint256).max / f ? 0 : a * f;
        }
        return a / 10 ** (uint256(dec) - 18);
    }

    // ── the liveness predicate ──────────────────────────────────────────────

    function _fresh(uint256 updatedAt) internal view returns (bool) {
        return updatedAt >= block.timestamp || block.timestamp - updatedAt <= maxStaleness;
    }

    /// @dev Within plausibilityBps of the previous print. Nothing to compare against passes.
    function _plausible(uint256 price, uint256 prev) internal view returns (bool) {
        if (plausibilityBps == 0 || prev == 0) return true;
        uint256 diff = price > prev ? price - prev : prev - price;
        return diff <= FullMath.mulDiv(prev, plausibilityBps, 10_000);
    }

    /// @dev ERC-8056 oraclePaused(). Unreadable counts as paused: fail adverse.
    function _paused() internal view returns (bool) {
        if (stockToken == address(0)) return false;
        if (stockToken.code.length == 0) return true;
        try IOraclePausable(stockToken).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return true;
        }
    }
}
