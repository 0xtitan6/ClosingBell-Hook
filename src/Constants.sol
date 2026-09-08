// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Constants {
    // ── fixed point ─────────────────────────────────────────────────────────
    uint256 internal constant ONE = 1e18; // 1.0 for multipliers and deviations
    uint256 internal constant MAX_DEV = 1e20; // 10,000% — deviation is capped here so the fee math can never overflow

    // ── NYSE calendar, New York time, as seconds since midnight ─────────────
    uint256 internal constant EDT_OFFSET = 4 hours; // New York behind UTC in daylight time
    uint256 internal constant EST_OFFSET = 5 hours; // New York behind UTC in standard time

    uint256 internal constant PRE_START = 4 hours; // 04:00  pre-market opens
    uint256 internal constant OPEN_SEC = 9 hours + 30 minutes; // 09:30  regular session opens
    uint256 internal constant CLOSE_SEC = 16 hours; // 16:00  regular session closes
    uint256 internal constant HALF_CLOSE_SEC = 13 hours; // 13:00  close on early-close days
    uint256 internal constant POST_END = 20 hours; // 20:00  post-market ends; overnight session begins
}
