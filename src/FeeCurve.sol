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
    /// The hook must enforce: baseFee <= elevatedFloor <= closedFloor <= feeCap < MAX_LP_FEE,
    /// and stalenessMax >= 1e18. The cap is strictly below 100%: v4 rejects exact-output swaps
    /// at a 100% fee, so a saturated fee would block them.
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

    /// @notice Are these parameters sane? The hook's constructor requires this to be true.
    ///         Floors must be ordered, the cap must be a legal v4 fee, and the staleness ceiling
    ///         must not make a closed market cheaper than an open one.
    function validate(Params memory p) internal pure returns (bool) {
        return p.baseFee <= p.elevatedFloor && p.elevatedFloor <= p.closedFloor && p.closedFloor <= p.feeCap
            && p.feeCap < LPFeeLibrary.MAX_LP_FEE && p.stalenessMax >= ONE;
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

    /// @notice True when the reference price moved and the pool has not finished following it.
    ///         The pool "was tracking the old print" if it sits no further from that print than
    ///         the reference itself moved: |pool - prev| <= |ref - prev|. That covers the whole
    ///         band between the two prints and its mirror image on the far side of the old print,
    ///         so a pool nudged a wei past the old print before the close cannot ride the reopen
    ///         move at the floor. To escape, a trader must pre-pay a real gap larger than the
    ///         move, in the right direction, before knowing it. Uses feed history only, so there
    ///         is no stored state to reset. Unknown history (prevRef == 0) counts as moved: when
    ///         in doubt, charge.
    function referenceMoved(uint256 poolPrice, uint256 ref, uint256 prevRef) internal pure returns (bool) {
        if (prevRef == 0) return true;
        if (prevRef == ref) return false;
        uint256 move = prevRef < ref ? ref - prevRef : prevRef - ref;
        uint256 gap = poolPrice < prevRef ? prevRef - poolPrice : poolPrice - prevRef;
        return gap <= move;
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

    /// @notice 1.0x for restoring swaps. Otherwise rises with the larger of the deviation the swap
    ///         started from and the one it leaves behind — so an arbitrage that lands exactly on
    ///         the reference is charged for the whole gap it took, not for the zero it ends at.
    ///         One slope up to the kink, a steeper one beyond it. Capped at MAX_DEV so it can never
    ///         overflow and block a swap.
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

    /// @notice Multiply it all together, round to the nearest pip, and cap. Also clamps just under
    ///         the protocol maximum so a misconfigured feeCap cannot make the PoolManager reject
    ///         exact-output swaps. Nearest, not up: a real pool is never at the reference to the wei, and a
    ///         1e-12 deviation must not turn "exactly the base fee" into base + 1.
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

    /// @dev Saturating: abs(type(int256).min) would overflow, and a revert here blocks a swap.
    function abs(int256 x) internal pure returns (uint256) {
        if (x == type(int256).min) return uint256(type(int256).max);
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
