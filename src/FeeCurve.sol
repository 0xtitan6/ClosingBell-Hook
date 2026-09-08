// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Session} from "./IMarketStateAdapter.sol";
import {Constants as C} from "./Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice The fee formula. Pure math, no state.
///
///   fee = min( floor × stalenessMult × deviationMult, feeCap )
///
/// Units: fees in pips (1e-6, so 500 = 5 bps). Multipliers in 1e18 (1e18 = 1.0x).
/// Deviation is (pool − ref) / ref, signed, in 1e18 (−1e16 = pool 1% below the reference).
library FeeCurve {
    uint256 private constant ONE = C.ONE;

    /// @notice What a pool creator sets once, in the hook's constructor.
    /// The hook must enforce: baseFee <= elevatedFloor <= closedFloor <= feeCap <= MAX_LP_FEE,
    /// and stalenessMax >= 1e18.
    struct Params {
        uint24 baseFee; // regular hours, feed live
        uint24 elevatedFloor; // pre/post-market and overnight
        uint24 closedFloor; // weekends, holidays, or a dead feed
        uint24 feeCap; // hard ceiling on the final fee
        uint64 stalenessSlope; // how fast the fee climbs per second the market has been closed
        uint64 stalenessMax; // ceiling on that climb (1e18 units)
        uint64 devKink; // deviation where the surcharge steepens (1e18 units)
        uint64 devSlope1; // surcharge per unit of deviation, below the kink
        uint64 devSlope2; // surcharge per unit of deviation, above the kink
    }

    /// @notice Minimum fee for the current market state. A dead feed always gets the closed floor.
    function floorFor(Params memory p, Session s, bool isLive) internal pure returns (uint24) {
        if (!isLive || s == Session.Closed) return p.closedFloor;
        if (s == Session.Regular) return p.baseFee;
        return p.elevatedFloor;
    }

    /// @notice Grows with time since the market closed; 1.0x whenever it is open.
    function stalenessMult(Params memory p, Session s, uint256 lastClose, uint256 nowTs) internal pure returns (uint256) {
        if (s != Session.Closed || nowTs <= lastClose) return ONE;
        uint256 m = ONE + (nowTs - lastClose) * p.stalenessSlope;
        return m > p.stalenessMax ? p.stalenessMax : m;
    }

    /// @notice True when the reference price moved and the pool has not caught up yet — i.e. the
    ///         pool is still closer to the previous print than to the current one.
    ///         Uses feed history only, so there is no stored state for a trader to reset.
    function referenceMoved(uint256 poolPrice, uint256 ref, uint256 prevRef) internal pure returns (bool) {
        if (prevRef == 0 || prevRef == ref) return false;
        return _absDiff(poolPrice, prevRef) < _absDiff(poolPrice, ref);
    }

    /// @notice Does this swap deserve the cheap rate? Only if it shrinks a gap the pool itself
    ///         drifted into, without crossing the reference. If the gap exists because the
    ///         reference moved, closing it is arbitrage and pays full price.
    function isRestoring(int256 preDev, int256 postDev, bool refMoved) internal pure returns (bool) {
        if (refMoved) return false;
        if (postDev == 0) return preDev != 0;
        if ((preDev > 0) != (postDev > 0)) return false; // crossed the reference
        return abs(postDev) < abs(preDev);
    }

    /// @notice 1.0x for restoring swaps. Otherwise rises with how far from the reference the swap
    ///         leaves the pool: one slope up to the kink, a steeper one beyond it.
    ///         Capped at MAX_DEV so it can never overflow and block a swap.
    function deviationMult(Params memory p, uint256 absPostDev, bool restoring) internal pure returns (uint256) {
        if (restoring || absPostDev == 0) return ONE;
        if (absPostDev > C.MAX_DEV) absPostDev = C.MAX_DEV;
        if (absPostDev <= p.devKink) return ONE + absPostDev * p.devSlope1;
        return ONE + uint256(p.devKink) * p.devSlope1 + (absPostDev - p.devKink) * p.devSlope2;
    }

    /// @notice Multiply it all together, round up, and cap. Also clamps to the protocol maximum
    ///         (100%) so a misconfigured feeCap cannot make the PoolManager reject every swap.
    function computeFee(Params memory p, uint24 floorFee, uint256 stalenessM, uint256 deviationM)
        internal
        pure
        returns (uint24)
    {
        uint256 fee = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(floorFee, stalenessM, ONE), deviationM, ONE);
        uint256 cap = p.feeCap < LPFeeLibrary.MAX_LP_FEE ? p.feeCap : LPFeeLibrary.MAX_LP_FEE;
        return fee > cap ? uint24(cap) : uint24(fee);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
