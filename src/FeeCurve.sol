// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Session} from "./MarketHours.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "./Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";


/// @notice What a swap costs: a floor for the time of day, raised the longer the market has been
///         shut, raised again the further the pool has drifted from the real price, then capped. All in basis points.
library FeeCurve {

    /// @notice The fee settings, chosen once by whoever launches the pool and fixed forever.
    struct Params {
        uint24 baseFee;                           // floor: regular hours, feed usable
        uint24 elevatedFloor;                     // floor: pre-market, after-hours, overnight
        uint24 closedFloor;                       // floor: weekends, holidays, or any session with an unusable feed
        uint24 feeCap;                            // the most this pool will ever charge
        uint64 stalenessSlope;                    // added to the staleness multiplier each second the market is shut
        uint64 stalenessMax;                      // and how high that multiplier is allowed to climb
        uint64 devKink;                           // the drift beyond which the surcharge gets steeper
        uint64 devSlope1;                         // how hard drift is charged below the kink
        uint64 devSlope2;                         // and above it
    }

    /// @notice Each floor must be at least the one before it, and the cap must stay under 100%
    function validate(Params memory p) internal pure returns (bool) {
        return p.baseFee <= p.elevatedFloor && p.elevatedFloor <= p.closedFloor && p.closedFloor <= p.feeCap
            && p.feeCap < LPFeeLibrary.MAX_LP_FEE && p.stalenessMax >= Constants.ONE;
    }

    /// @notice The least this swap can cost. A feed we can't trust pays the closed-market rate.
    function floorFor(Params memory p, Session s, bool isLive) internal pure returns (uint24) {
        if (!isLive || s == Session.Closed) {
            return p.closedFloor;
        }
        if (s == Session.Regular) {
            return p.baseFee;
        }
        return p.elevatedFloor;     
    }
    
    /// @notice Staleness of a market the longer nobody has seen a real price
    function stalenessMult(Params memory p, Session s, uint256 lastClose, uint256 nowTs) internal pure returns (uint256) {
        if (s != Session.Closed || nowTs <= lastClose) {
            return Constants.ONE;
        }
        uint256 mulVal = Constants.ONE + (nowTs - lastClose) * p.stalenessSlope;

        if (mulVal > p.stalenessMax) return p.stalenessMax;
        return mulVal;
    }

    /// @notice The final fee sent to Uniswap 
    function computeFee(Params memory p, uint24 floorFee, uint256 stalenessM, uint256 deviationM) internal pure returns (uint24) {
        uint256 num = uint256(floorFee) * stalenessM;
        uint256 denom = Constants.ONE * Constants.ONE;
        uint256 fee = FullMath.mulDiv(num, deviationM, denom);

        if (mulmod(num, deviationM, denom) * 2 >= denom) fee += 1;
        
        uint256 cap;
        if (p.feeCap < LPFeeLibrary.MAX_LP_FEE) {
            cap = p.feeCap;          
        } else {
            cap = LPFeeLibrary.MAX_LP_FEE - 1;  
        }

        if (fee > cap) {
            return uint24(cap);
        }
        return uint24(fee);
    }

    /// @notice Cheap rate only if the pool drifted on its own and this swap pushes it back.
    function isRestoring(int256 preDev, int256 postDev, bool refMoved) internal pure returns (bool) {
        if (refMoved) return false;

        if (postDev == 0) return preDev != 0;

        if ((preDev > 0) != (postDev > 0)) return false;

        return FixedPointMathLib.abs(postDev) < FixedPointMathLib.abs(preDev);
    }
    
    /// @notice How much the drift multiplies the fee. Helpful swaps pay nothing extra.
    function deviationMult(Params memory p, uint256 absPreDev, uint256 absPostDev, bool restoring) internal pure returns (uint256) {
        if (restoring) return Constants.ONE;

        uint256 dev = absPreDev > absPostDev ? absPreDev : absPostDev;
        if (dev == 0) return Constants.ONE;

        if (dev > Constants.MAX_DEV) dev = Constants.MAX_DEV;

        if (dev <= p.devKink) {
            return Constants.ONE + dev * p.devSlope1;
        }

        return Constants.ONE + uint256(p.devKink) * p.devSlope1 + (dev - p.devKink) * p.devSlope2;
    }

    /// @notice Stock move out from under a pool it was tracking or a pool drift occured
    function referenceMoved(uint256 poolPrice, uint256 ref, uint256 lo, uint256 hi) internal pure returns (bool) {
        if (lo == 0 || hi == 0 || lo > hi) return true;

        if (lo == hi && lo == ref) return false;
    
        uint256 low = lo < ref ? lo : ref;
        uint256 high = hi > ref ? hi : ref;

        uint256 refAboveLow = ref - low;
        uint256 refBelowHigh = high - ref;

        uint256 lower = refAboveLow >= low ? 0 : low - refAboveLow;
        uint256 upper = refBelowHigh > type(uint256).max - high ? type(uint256).max : high + refBelowHigh;

        return poolPrice >= lower && poolPrice <= upper;
    }
}
