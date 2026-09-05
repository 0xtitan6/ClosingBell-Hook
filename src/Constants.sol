// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Constants {
    // ── NYSE calendar, Eastern Time, seconds since ET midnight ──────────────
    uint256 internal constant EDT_OFFSET = 4 hours;
    uint256 internal constant EST_OFFSET = 5 hours;

    uint256 internal constant PRE_START = 4 hours; // 04:00 pre-market opens
    uint256 internal constant OPEN_SEC = 9 hours + 30 minutes; // 09:30 regular open
    uint256 internal constant CLOSE_SEC = 16 hours; // 16:00 regular close
    uint256 internal constant HALF_CLOSE_SEC = 13 hours; // 13:00 early-close days
    uint256 internal constant POST_END = 20 hours; // 20:00 post-market ends; overnight begins
}
