// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Session, MarketState, IMarketStateAdapter} from "./IMarketStateAdapter.sol";
import {AggregatorV3Interface, IOraclePausable} from "./AggregatorV3Interface.sol";
import {Constants as C} from "./Constants.sol";
import {MarketHours} from "./MarketHours.sol";

/// @notice v1 oracle for ClosingBell: Chainlink Data Feeds plus the NYSE calendar.
///
/// Stateless and total. Every external read is a raw staticcall whose return data is length-
/// checked and decoded by hand, because `try/catch` cannot catch a decoding failure in the
/// caller. Anything that fails degrades to "not live" and the hook charges its highest floor
/// with the pool still open. Nothing here can block a swap.
///
/// `isLive` is a dead-feed net, not a halt detector (build note B1): the price is fresh, plausible
/// against the previous distinct print, the token's corporate-action flag is clear, and the quote
/// leg (if any) is fresh too. `maxStaleness` must sit above the feed's 86400s heartbeat.
contract ChainlinkEquityAdapter is IMarketStateAdapter {
    error InvalidConfig();

    AggregatorV3Interface public immutable stockFeed;
    AggregatorV3Interface public immutable quoteFeed; // address(0) for dollar-quote pools
    address public immutable stockToken; // address(0) to skip the oraclePaused() check
    uint256 public immutable maxStaleness; // seconds; above the 86400s heartbeat
    uint256 public immutable plausibilityBps; // max jump vs the previous distinct print; 0 disables

    struct Round {
        bool ok;
        uint80 id;
        int256 answer;
        uint256 updatedAt;
    }

    /// @dev Every address is dry-read here. A feed or token that cannot be read at deployment
    ///      would pin the pool at the closed floor forever, and nothing here can be changed later.
    constructor(
        address stockFeed_,
        address quoteFeed_,
        address stockToken_,
        uint256 maxStaleness_,
        uint256 plausibilityBps_
    ) {
        if (stockFeed_ == address(0) || maxStaleness_ <= 1 days || plausibilityBps_ > 10_000) revert InvalidConfig();
        if (quoteFeed_ == stockFeed_) revert InvalidConfig();
        if (!_readable(stockFeed_) || (quoteFeed_ != address(0) && !_readable(quoteFeed_))) revert InvalidConfig();
        if (stockToken_ != address(0)) {
            (bool ok,) = _call(stockToken_, abi.encodeCall(IOraclePausable.oraclePaused, ()), 32);
            if (!ok) revert InvalidConfig();
        }
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

        uint256 last;
        (m.price, m.loPrice, m.hiPrice, last, m.updatedAt) = _leg(stockFeed);
        bool live = m.price != 0 && _fresh(m.updatedAt) && _plausible(m.price, last) && !_paused();

        if (m.hasQuoteFeed) {
            uint256 quoteAt;
            (m.quotePrice, m.loQuotePrice, m.hiQuotePrice,, quoteAt) = _leg(quoteFeed);
            live = live && m.quotePrice != 0 && _fresh(quoteAt);
        }
        m.isLive = live;
    }

    // ── one feed ────────────────────────────────────────────────────────────

    /// @dev Latest price, the low/high of the recent window, the previous distinct print, and the
    ///      latest print time. All zero on failure; lo/hi zero if no history could be read.
    function _leg(AggregatorV3Interface feed)
        internal
        view
        returns (uint256 price, uint256 lo, uint256 hi, uint256 last, uint256 updatedAt)
    {
        (bool okDec, uint256 dec) = _decimals(address(feed));
        if (!okDec) return (0, 0, 0, 0, 0);
        Round memory r = _round(address(feed), abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (!r.ok || r.answer <= 0) return (0, 0, 0, 0, 0);
        price = _scale(r.answer, dec);
        if (price == 0) return (0, 0, 0, 0, 0);
        updatedAt = r.updatedAt;
        (int256 rawLo, int256 rawHi, int256 rawLast) = _window(address(feed), r.id, r.answer);
        if (rawLo != 0) (lo, hi) = (_scale(rawLo, dec), _scale(rawHi, dec));
        last = _scale(rawLast, dec);
    }

    /// @dev Walk LOOKBACK rounds behind the latest. The window is min/max over those prints plus
    ///      the latest one; `last` is the first print that differs from the latest (0 if none).
    ///      A pool that tracked any print in the window is inside the hook's band, so a trend of
    ///      small prints or a reopen-then-retrace cannot be arbitraged at the floor (B6, B9).
    ///      Stops at the first unreadable round; if none could be read, lo = hi = 0 (unknown).
    function _window(address feed, uint80 id, int256 answer)
        internal
        view
        returns (int256 lo, int256 hi, int256 last)
    {
        uint256 seen;
        (lo, hi) = (answer, answer);
        for (uint80 i = 1; i <= C.LOOKBACK; i++) {
            if (id < i) break;
            Round memory r = _round(feed, abi.encodeCall(AggregatorV3Interface.getRoundData, (id - i)));
            if (!r.ok) break;
            if (r.answer <= 0) continue;
            seen++;
            if (r.answer < lo) lo = r.answer;
            if (r.answer > hi) hi = r.answer;
            if (last == 0 && r.answer != answer) last = r.answer;
        }
        if (seen == 0) return (0, 0, 0);
    }

    // ── raw reads: length-checked, hand-decoded, never revert ───────────────

    function _call(address target, bytes memory data, uint256 minLen) internal view returns (bool ok, bytes memory r) {
        if (target.code.length == 0) return (false, r);
        (ok, r) = target.staticcall(data);
        ok = ok && r.length >= minLen;
    }

    function _readable(address feed) internal view returns (bool) {
        (bool ok,) = _decimals(feed);
        return ok && _round(feed, abi.encodeCall(AggregatorV3Interface.latestRoundData, ())).ok;
    }

    function _decimals(address feed) internal view returns (bool ok, uint256 dec) {
        bytes memory r;
        (ok, r) = _call(feed, abi.encodeCall(AggregatorV3Interface.decimals, ()), 32);
        if (!ok) return (false, 0);
        dec = abi.decode(r, (uint256));
        ok = dec <= 77;
    }

    function _round(address feed, bytes memory data) internal view returns (Round memory out) {
        (bool ok, bytes memory r) = _call(feed, data, 160);
        if (!ok) return out;
        (uint256 rid, int256 answer,, uint256 updatedAt,) = abi.decode(r, (uint256, int256, uint256, uint256, uint256));
        if (rid > type(uint80).max) return out;
        return Round(true, uint80(rid), answer, updatedAt);
    }

    /// @dev Feed units to 1e18. 0 if the answer is not positive or the scaling would overflow.
    function _scale(int256 answer, uint256 dec) internal pure returns (uint256) {
        if (answer <= 0 || dec > 77) return 0;
        uint256 a = uint256(answer);
        if (dec <= 18) {
            uint256 f = 10 ** (18 - dec);
            return a > type(uint256).max / f ? 0 : a * f;
        }
        return a / 10 ** (dec - 18);
    }

    // ── the liveness predicate ──────────────────────────────────────────────

    function _fresh(uint256 updatedAt) internal view returns (bool) {
        return updatedAt >= block.timestamp || block.timestamp - updatedAt <= maxStaleness;
    }

    /// @dev Within plausibilityBps of the previous distinct print. Nothing to compare against passes.
    function _plausible(uint256 price, uint256 last) internal view returns (bool) {
        if (plausibilityBps == 0 || last == 0) return true;
        uint256 diff = price > last ? price - last : last - price;
        return diff <= FullMath.mulDiv(last, plausibilityBps, 10_000);
    }

    /// @dev ERC-8056 oraclePaused(). Unreadable, or any non-zero word, counts as paused: fail adverse.
    function _paused() internal view returns (bool) {
        if (stockToken == address(0)) return false;
        (bool ok, bytes memory r) = _call(stockToken, abi.encodeCall(IOraclePausable.oraclePaused, ()), 32);
        if (!ok) return true;
        return abi.decode(r, (uint256)) != 0;
    }
}
