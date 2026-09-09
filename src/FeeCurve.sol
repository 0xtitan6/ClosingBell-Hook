// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Session} from "./IMarketStateAdapter.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Pure fee math. Fees in pips (1e-6); multipliers and deviations in 1e18.
library FeeCurve {
    uint256 internal constant ONE = 1e18;

    /// @notice Creator-set, immutable in the hook's constructor.
    /// Invariant (enforced by the hook): baseFee <= elevatedFloor <= closedFloor <= feeCap <= MAX_LP_FEE
    struct Params {
        uint24 baseFee;        // floor: Regular, live
        uint24 elevatedFloor;  // floor: Extended / Overnight
        uint24 closedFloor;    // floor: Closed, or any session with !isLive
        uint24 feeCap;         // single cap on the full product
        uint64 stalenessSlope; // 1e18 per second since lastClose
        uint64 stalenessMax;   // cap on stalenessMult, 1e18
        uint64 devKink;        // deviation (1e18) where f's slope changes
        uint64 devSlope1;      // f slope below the kink, 1e18 per 1e18 of deviation
        uint64 devSlope2;      // f slope above the kink
        uint32 decayWindow;    // seconds after reopen over which the surcharge blends out
    }
}
