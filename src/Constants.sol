// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Constants {
    // ── fixed point ─────────────────────────────────────────────────────────
    uint256 internal constant ONE = 1e18; // how "1.0" is written, since Solidity has no decimals
    uint256 internal constant MAX_DEV = 1e20; // drift is capped at 10,000%, so the maths cannot overflow
    uint256 internal constant Q96 = 1 << 96; // the scale Uniswap uses for its internal prices

    // ── Chainlink round history (adapter) ───────────────────────────────────
    uint256 internal constant LOOKBACK = 6; // how many recent feed prices we look back over

    // ── NYSE calendar, New York time, as seconds since midnight ─────────────
    uint256 internal constant EDT_OFFSET = 4 hours; // New York in summer, behind UTC
    uint256 internal constant EST_OFFSET = 5 hours; // New York in winter

    uint256 internal constant PRE_START = 4 hours; // 04:00  pre-market opens
    uint256 internal constant OPEN_SEC = 9 hours + 30 minutes; // 09:30  regular session opens
    uint256 internal constant CLOSE_SEC = 16 hours; // 16:00  regular session closes
    uint256 internal constant HALF_CLOSE_SEC = 13 hours; // 13:00  close on early-close days
    uint256 internal constant POST_END = 20 hours; // 20:00  after-hours ends, overnight begins
}
