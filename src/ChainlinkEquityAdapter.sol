// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMarketStateAdapter, MarketState} from "./IMarketStateAdapter.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Constants} from "./Constants.sol";
import {AggregatorV3Interface, IOraclePausable} from "./AggregatorV3Interface.sol";

contract ChainlinkEquityAdapter is IMarketStateAdapter {
    error InvalidConfig();
   
    address public immutable stockFeed;
    address public immutable quoteFeed;        // address(0) for dollar-quoted pools
    address public immutable stockToken;       // address(0) skips the corporate-action check
    uint256 public immutable maxStaleness;     // seconds
    uint256 public immutable plausibilityBps;  // 0 disables the check

    constructor(address stockFeed_, address quoteFeed_, address stockToken_, uint256 maxStaleness_, uint256 plausibilityBps_) {
        if (stockFeed_ == address(0)) revert InvalidConfig();

        if (maxStaleness_ <= 1 days) revert InvalidConfig();

        if (plausibilityBps_ > 10000) revert InvalidConfig();

        if (quoteFeed_ == stockFeed_) revert InvalidConfig();

        if (!_readable(stockFeed_)) revert InvalidConfig();

        if (quoteFeed_ != address(0) && !_readable(quoteFeed_)) revert InvalidConfig();

        if (stockToken_ != address(0)) {
            (bool okPaused,) = _call(stockToken_, abi.encodeCall(IOraclePausable.oraclePaused, ()), 32);
            
            if (!okPaused) revert InvalidConfig();
        }

        stockFeed = stockFeed_;
        quoteFeed = quoteFeed_;
        stockToken = stockToken_;
        maxStaleness = maxStaleness_;
        plausibilityBps = plausibilityBps_;
    }

    function _scale(int256 answer, uint256 decimals) internal pure returns (uint256) {
        if (answer <= 0 || decimals > 77) return 0;

        uint256 a = uint256(answer);
        uint256 unit = 10 ** decimals;

        if (a > type(uint256).max / Constants.ONE) return 0;
        
        return FullMath.mulDiv(a, Constants.ONE, unit);
    }

    /// @dev A call that cannot fail. Checks there is code at the target, makes the call, and checks
    ///      the reply is long enough to read before anything touches it.
    function _call(address target, bytes memory data, uint256 minLength)
        internal
        view
        returns (bool ok, bytes memory result)
    {
        if (target.code.length == 0) return (false, result);
        (ok, result) = target.staticcall(data);
        ok = ok && result.length >= minLength;
    }

    /// @dev One Chainlink round, decoded by hand. The five words are read as plain uint256 and int256
    ///      rather than the declared uint80, because decoding into uint80 reverts if the feed returns
    ///      anything larger, and that revert would stop every swap.
    function _readRound(address feed, bytes memory data)
        internal
        view
        returns (bool ok, uint80 id, int256 answer, uint256 updatedAt)
    {
        (bool called, bytes memory r) = _call(feed, data, 160);
        if (!called) return (false, 0, 0, 0);

        (uint256 rid, int256 a,, uint256 at,) = abi.decode(r, (uint256, int256, uint256, uint256, uint256));
        if (rid > type(uint80).max) return (false, 0, 0, 0);
        return (true, uint80(rid), a, at);
    }

    /// @dev How many decimal places the feed publishes at. Rejects anything above 77, where 10**d
    ///      would itself overflow.
    function _readDecimals(address feed) internal view returns (bool ok, uint256 decimals) {
        bytes memory r;
        (ok, r) = _call(feed, abi.encodeCall(AggregatorV3Interface.decimals, ()), 32);
        if (!ok) return (false, 0);
        decimals = abi.decode(r, (uint256));
        ok = decimals <= 77;
    }

    /// @dev Everything one feed can tell us: the latest price, the window low and high, the last price
    ///      that differed from the latest, and when it was published. All zero if unreadable.
    function _readFeed(address feed)
        internal
        view
        returns (uint256 price, uint256 lo, uint256 hi, uint256 last, uint256 updatedAt)
    {
        (bool okDec, uint256 dec) = _readDecimals(feed);
        if (!okDec) return (0, 0, 0, 0, 0);

        (bool ok, uint80 id, int256 answer, uint256 at) =
            _readRound(feed, abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (!ok || answer <= 0) return (0, 0, 0, 0, 0);

        price = _scale(answer, dec);
        if (price == 0) return (0, 0, 0, 0, 0);
        updatedAt = at;

        (int256 rawLo, int256 rawHi, int256 rawLast) = _window(feed, id, answer);
        if (rawLo != 0) (lo, hi) = (_scale(rawLo, dec), _scale(rawHi, dec));
        last = _scale(rawLast, dec);
    }

    /// @dev Walks back through recent rounds for the highest and lowest prints. That range is how the
    ///      hook tells a reference move from pool drift (B9). Stops at the first unreadable round; if
    ///      none could be read, reports zeros and the hook charges by default.
    function _window(address feed, uint80 id, int256 answer)
        internal
        view
        returns (int256 lo, int256 hi, int256 last)
    {
        uint256 seen;
        (lo, hi) = (answer, answer);

        for (uint80 i = 1; i <= Constants.LOOKBACK; i++) {
            if (id < i) break;
            (bool ok,, int256 a,) = _readRound(feed, abi.encodeCall(AggregatorV3Interface.getRoundData, (id - i)));
            if (!ok) break;
            if (a <= 0) continue;

            seen++;
            if (a < lo) lo = a;
            if (a > hi) hi = a;
            if (last == 0 && a != answer) last = a;
        }
        if (seen == 0) return (0, 0, 0);
    }

    /// @dev Published recently enough to trust? A future timestamp is a clock difference, not staleness.
    function _fresh(uint256 updatedAt) internal view returns (bool) {
        return updatedAt >= block.timestamp || block.timestamp - updatedAt <= maxStaleness;
    }

    /// @dev A believable step from the last distinct print. Nothing to compare against passes.
    function _plausible(uint256 price, uint256 last) internal view returns (bool) {
        if (plausibilityBps == 0 || last == 0) return true;
        uint256 diff = price > last ? price - last : last - price;
        return diff <= FullMath.mulDiv(last, plausibilityBps, 10_000);
    }

    /// @dev The token's corporate-action flag. Unreadable, or any non-zero word, counts as frozen.
    function _paused() internal view returns (bool) {
        if (stockToken == address(0)) return false;
        (bool ok, bytes memory r) = _call(stockToken, abi.encodeCall(IOraclePausable.oraclePaused, ()), 32);
        if (!ok) return true;
        return abi.decode(r, (uint256)) != 0;
    }

    /// @dev Used only by the constructor: can this feed be read at all?
    function _readable(address feed) internal view returns (bool) {
        (bool okDec,) = _readDecimals(feed);
        if (!okDec) return false;
        (bool ok,,,) = _readRound(feed, abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        return ok;
    }

    /// @inheritdoc IMarketStateAdapter
    function getMarketState() external view returns (MarketState memory m) {
        m.hasQuoteFeed = quoteFeed != address(0);

        uint256 last;
        uint256 updatedAt;
        (m.price, m.loPrice, m.hiPrice, last, updatedAt) = _readFeed(stockFeed);

        bool live = m.price != 0 && _fresh(updatedAt) && _plausible(m.price, last) && !_paused();

        if (m.hasQuoteFeed) {
            uint256 quoteAt;
            (m.quotePrice, m.loQuotePrice, m.hiQuotePrice,, quoteAt) = _readFeed(quoteFeed);
            live = live && m.quotePrice != 0 && _fresh(quoteAt);
        }
        m.isLive = live;
    }
}
