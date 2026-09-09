// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Session} from "./MarketHours.sol";
import {Constants as C} from "./Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice What a swap costs: a floor for the time of day, raised the longer the market has been
///         shut, raised again the further the pool has drifted from the real price, then capped.
/// @dev Fees in pips (500 = 5 basis points). Multipliers and drift use 1e18 for 1.0.
library FeeCurve {
    uint256 private constant ONE = C.ONE;

    /// @notice Chosen by whoever launches the pool. Fixed forever once deployed.
    struct Params {
        uint24 baseFee; // the cheapest rate: market open, price feed working
        uint24 elevatedFloor; // pre-market, after-hours and overnight
        uint24 closedFloor; // weekends, holidays, or when the price feed is unusable
        uint24 feeCap; // the most this pool will ever charge
        uint64 stalenessSlope; // how fast the fee climbs for each second the market stays shut
        uint64 stalenessMax; // and how high that climb is allowed to go
        uint64 devKink; // the drift beyond which the surcharge gets steeper
        uint64 devSlope1; // how hard drift is charged below that point
        uint64 devSlope2; // and above it
    }

    /// @notice Each floor must be at least the one before it, and the cap must stay under 100%,
    ///         because Uniswap rejects some swaps at a 100% fee.
    function validate(Params memory p) internal pure returns (bool) {
        return p.baseFee <= p.elevatedFloor && p.elevatedFloor <= p.closedFloor && p.closedFloor <= p.feeCap
            && p.feeCap < LPFeeLibrary.MAX_LP_FEE && p.stalenessMax >= ONE;
    }

    /// @notice The least this swap can cost. A broken feed gets the closed-market rate.
    function floorFor(Params memory p, Session s, bool isLive) internal pure returns (uint24) {
        if (!isLive || s == Session.Closed) return p.closedFloor;
        if (s == Session.Regular) return p.baseFee;
        return p.elevatedFloor;
    }

    /// @notice Climbs the longer the market has been shut. The longer nobody has seen a real
    ///         price, the more the stock could have moved. 1.0x while open.
    function stalenessMult(Params memory p, Session s, uint256 lastClose, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        if (s != Session.Closed || nowTs <= lastClose) return ONE;
        uint256 m = ONE + (nowTs - lastClose) * p.stalenessSlope;
        return m > p.stalenessMax ? p.stalenessMax : m;
    }

    /// @notice Whose fault is the gap: did the stock move, or did the pool drift?
    ///         If the pool sits near any price the feed published recently, it was following the
    ///         stock and got left behind, so closing that gap is arbitrage and pays full price.
    ///         Using the whole recent range, not just the last price, stops someone waiting out a
    ///         run of small moves and then taking the lot cheaply (B9). No history means charge.
    /// @dev The pool tracked some p in [lo, hi] if |pool - p| <= |ref - p|. Every such band
    ///      contains ref, so the union is one interval, [2lo - ref, 2hi - ref].
    function referenceMoved(uint256 poolPrice, uint256 ref, uint256 lo, uint256 hi) internal pure returns (bool) {
        if (lo == 0 || hi == 0 || lo > hi) return true;
        if (lo == hi && lo == ref) return false;
        uint256 l = lo < ref ? lo : ref; // l <= ref
        uint256 h = hi > ref ? hi : ref; // h >= ref
        // Written the long way so an absurd price cannot overflow. A failure here stops every swap.
        uint256 down = ref - l;
        uint256 up = h - ref;
        uint256 lower = down >= l ? 0 : l - down;
        uint256 upper = up > type(uint256).max - h ? type(uint256).max : h + up;
        return poolPrice >= lower && poolPrice <= upper;
    }

    /// @notice Earns the cheap rate only by narrowing a gap the pool made itself, without
    ///         overshooting past the real price into a new gap.
    function isRestoring(int256 preDev, int256 postDev, bool refMoved) internal pure returns (bool) {
        if (refMoved) return false;
        if (postDev == 0) return preDev != 0;
        if ((preDev > 0) != (postDev > 0)) return false; // crossed the reference
        return abs(postDev) < abs(preDev);
    }

    /// @notice How much the drift multiplies the fee. Helpful swaps pay nothing extra. The rest
    ///         pay on the wider of the gap before and after, so landing exactly on the real price
    ///         still pays for the gap it took (B6). Steeper past `devKink`.
    function deviationMult(Params memory p, uint256 absPreDev, uint256 absPostDev, bool restoring)
        internal
        pure
        returns (uint256)
    {
        if (restoring) return ONE;
        uint256 dev = absPreDev > absPostDev ? absPreDev : absPostDev;
        if (dev == 0) return ONE;
        if (dev > C.MAX_DEV) dev = C.MAX_DEV;
        if (dev <= p.devKink) return ONE + dev * p.devSlope1;
        return ONE + uint256(p.devKink) * p.devSlope1 + (dev - p.devKink) * p.devSlope2;
    }

    /// @notice Multiplies it all together and applies the cap.
    /// @dev Rounds to nearest, not up: a rounding speck should not turn the base fee into base + 1.
    function computeFee(Params memory p, uint24 floorFee, uint256 stalenessM, uint256 deviationM)
        internal
        pure
        returns (uint24)
    {
        uint256 num = uint256(floorFee) * stalenessM;
        uint256 fee = FullMath.mulDiv(num, deviationM, ONE * ONE);
        if (mulmod(num, deviationM, ONE * ONE) * 2 >= ONE * ONE) fee += 1;
        uint256 cap = p.feeCap < LPFeeLibrary.MAX_LP_FEE ? p.feeCap : LPFeeLibrary.MAX_LP_FEE - 1;
        return fee > cap ? uint24(cap) : uint24(fee);
    }

    /// @dev Size ignoring sign. The one impossible case is pinned, not failed: a failure blocks swaps.
    function abs(int256 x) internal pure returns (uint256) {
        if (x == type(int256).min) return uint256(type(int256).max);
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
