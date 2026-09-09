// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {MarketState, IMarketStateAdapter} from "./IMarketStateAdapter.sol";
import {AggregatorV3Interface, IOraclePausable} from "./AggregatorV3Interface.sol";
import {Constants as C} from "./Constants.sol";

/// @notice Where the hook gets the stock's real price: Chainlink's published feeds. Reports the
///         latest price, the recent range, and whether any of it can be trusted.
///
///         Nothing here can fail. If it could, every swap would stop working, and it would happen
///         exactly when the feed is least healthy and the pool most needs protecting.
/// @dev Stateless. "Not live" means a broken feed, not a trading halt (B1), so `maxStaleness`
///      must sit above the feed's 24-hour heartbeat.
contract ChainlinkEquityAdapter is IMarketStateAdapter {
    error InvalidConfig();

    AggregatorV3Interface public immutable stockFeed;
    AggregatorV3Interface public immutable quoteFeed; // only for pools priced in something but dollars
    address public immutable stockToken; // the token itself, which can flag a corporate action
    uint256 public immutable maxStaleness; // how old a price can get before we stop trusting it
    uint256 public immutable plausibilityBps; // how big a one-step jump we believe; 0 accepts any

    struct Round {
        bool ok;
        uint80 id;
        int256 answer;
        uint256 updatedAt;
    }

    /// @dev Reads every address once before accepting it. None can be changed later, so one that
    ///      does not answer would leave the pool stuck at its highest fee forever.
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
        m.hasQuoteFeed = address(quoteFeed) != address(0);

        uint256 last;
        uint256 updatedAt;
        (m.price, m.loPrice, m.hiPrice, last, updatedAt) = _leg(stockFeed);
        bool live = m.price != 0 && _fresh(updatedAt) && _plausible(m.price, last) && !_paused();

        if (m.hasQuoteFeed) {
            uint256 quoteAt;
            (m.quotePrice, m.loQuotePrice, m.hiQuotePrice,, quoteAt) = _leg(quoteFeed);
            live = live && m.quotePrice != 0 && _fresh(quoteAt);
        }
        m.isLive = live;
    }

    // ── one feed ────────────────────────────────────────────────────────────

    /// @dev Everything one feed can tell us: latest price, the highest and lowest recently, the
    ///      last price that differed, and when it was published. All zero if it cannot be read.
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

    /// @dev Walks back through recent prices for the highest and lowest. That range is how the
    ///      hook decides whether a gap is the stock's doing or the pool's. Stops at the first
    ///      unreadable one; if none can be read it reports nothing and the hook charges.
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

    /// @dev Calls another contract without ever failing: checks code is there, then the reply's size.
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

    /// @dev Feeds publish in their own units; this puts them on one scale. 0 if the price is
    ///      negative, zero, or too large.
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

    /// @dev Published recently enough to trust? A future timestamp is a clock difference, not a
    ///      stale price, so it counts as fresh.
    function _fresh(uint256 updatedAt) internal view returns (bool) {
        return updatedAt >= block.timestamp || block.timestamp - updatedAt <= maxStaleness;
    }

    /// @dev A believable step from the last price? Catches a feed glitch printing a wild number.
    ///      Nothing to compare against means accept.
    function _plausible(uint256 price, uint256 last) internal view returns (bool) {
        if (plausibilityBps == 0 || last == 0) return true;
        uint256 diff = price > last ? price - last : last - price;
        return diff <= FullMath.mulDiv(last, plausibilityBps, 10_000);
    }

    /// @dev Tokenized stocks flag themselves frozen during a corporate action like a split, when
    ///      the published price no longer lines up with the token. Unreadable counts as frozen.
    function _paused() internal view returns (bool) {
        if (stockToken == address(0)) return false;
        (bool ok, bytes memory r) = _call(stockToken, abi.encodeCall(IOraclePausable.oraclePaused, ()), 32);
        if (!ok) return true;
        return abi.decode(r, (uint256)) != 0;
    }
}
