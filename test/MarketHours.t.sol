// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {MarketHours} from "../src/MarketHours.sol";
import {Session} from "../src/IMarketStateAdapter.sol";

/// Fixed points for the NYSE calendar. Timestamps are built independently of the library under
/// test: ET wall-clock + a hardcoded offset (EDT 4h between 2026-03-08 and 2026-11-01, else EST 5h).
contract MarketHoursTest is Test {
    uint256 constant EDT = 4 hours;
    uint256 constant EST = 5 hours;

    function et(uint256 y, uint256 m, uint256 d, uint256 h, uint256 min, uint256 off) internal pure returns (uint256) {
        return DateTimeLib.dateTimeToTimestamp(y, m, d, h, min, 0) + off;
    }

    function sessionAt(uint256 ts) internal pure returns (Session s) {
        (s,) = MarketHours.calendar(ts);
    }

    function lastCloseAt(uint256 ts) internal pure returns (uint256 lc) {
        (, lc) = MarketHours.calendar(ts);
    }

    function assertSession(uint256 ts, Session want, string memory label) internal pure {
        assertEq(uint8(sessionAt(ts)), uint8(want), label);
    }

    // ── sessions ────────────────────────────────────────────────────────────────

    function test_laborDay2026_isClosed() public pure {
        assertSession(et(2026, 9, 7, 12, 0, EDT), Session.Closed, "Labor Day noon");
        assertSession(et(2026, 9, 7, 2, 0, EDT), Session.Closed, "Labor Day overnight");
        assertSession(et(2026, 9, 7, 18, 0, EDT), Session.Closed, "Labor Day post");
    }

    function test_regularHours() public pure {
        assertSession(et(2026, 9, 4, 12, 0, EDT), Session.Regular, "Fri noon");
        assertSession(et(2026, 9, 4, 9, 30, EDT), Session.Regular, "09:30 open tick");
        assertSession(et(2026, 9, 4, 15, 59, EDT), Session.Regular, "15:59");
    }

    function test_extended_preAndPost() public pure {
        assertSession(et(2026, 9, 4, 6, 0, EDT), Session.Extended, "pre-market");
        assertSession(et(2026, 9, 4, 4, 0, EDT), Session.Extended, "04:00 pre start");
        assertSession(et(2026, 9, 4, 9, 29, EDT), Session.Extended, "09:29");
        assertSession(et(2026, 9, 3, 16, 0, EDT), Session.Extended, "16:00 post start");
        assertSession(et(2026, 9, 3, 18, 0, EDT), Session.Extended, "post-market");
        assertSession(et(2026, 9, 3, 19, 59, EDT), Session.Extended, "19:59");
    }

    function test_overnight_belongsToFollowingTradingDay() public pure {
        assertSession(et(2026, 9, 3, 22, 0, EDT), Session.Overnight, "Thu 22:00 -> Fri overnight");
        assertSession(et(2026, 9, 4, 2, 0, EDT), Session.Overnight, "Fri 02:00");
        assertSession(et(2026, 9, 4, 3, 59, EDT), Session.Overnight, "Fri 03:59");
        assertSession(et(2026, 9, 3, 20, 0, EDT), Session.Overnight, "20:00 exact");
    }

    function test_weekend_isClosed() public pure {
        assertSession(et(2026, 9, 4, 20, 0, EDT), Session.Closed, "Fri 20:00 -> Sat overnight is closed");
        assertSession(et(2026, 9, 4, 21, 0, EDT), Session.Closed, "Fri 21:00");
        assertSession(et(2026, 9, 5, 12, 0, EDT), Session.Closed, "Sat noon");
        assertSession(et(2026, 9, 6, 12, 0, EDT), Session.Closed, "Sun noon");
    }

    function test_sundayNight_dependsOnMonday() public pure {
        // Sept 6 -> Labor Day Monday: closed. Sept 13 -> normal Monday: overnight.
        assertSession(et(2026, 9, 6, 21, 0, EDT), Session.Closed, "Sun before Labor Day");
        assertSession(et(2026, 9, 13, 21, 0, EDT), Session.Overnight, "Sun before normal Mon");
        assertSession(et(2026, 9, 13, 20, 0, EDT), Session.Overnight, "Sun 20:00 exact reopen");
        assertSession(et(2026, 9, 13, 19, 59, EDT), Session.Closed, "Sun 19:59 still closed");
    }

    function test_holidays2026() public pure {
        assertSession(et(2026, 1, 1, 12, 0, EST), Session.Closed, "New Year's");
        assertSession(et(2026, 1, 19, 12, 0, EST), Session.Closed, "MLK");
        assertSession(et(2026, 2, 16, 12, 0, EST), Session.Closed, "Presidents'");
        assertSession(et(2026, 4, 3, 12, 0, EDT), Session.Closed, "Good Friday");
        assertSession(et(2026, 5, 25, 12, 0, EDT), Session.Closed, "Memorial");
        assertSession(et(2026, 6, 19, 12, 0, EDT), Session.Closed, "Juneteenth");
        assertSession(et(2026, 7, 3, 12, 0, EDT), Session.Closed, "Independence observed (Jul 4 = Sat)");
        assertSession(et(2026, 7, 4, 12, 0, EDT), Session.Closed, "Jul 4 itself is a Saturday");
        assertSession(et(2026, 11, 26, 12, 0, EST), Session.Closed, "Thanksgiving");
        assertSession(et(2026, 12, 25, 12, 0, EST), Session.Closed, "Christmas");
        // Neighbours are open.
        assertSession(et(2026, 1, 2, 12, 0, EST), Session.Regular, "Jan 2");
        assertSession(et(2026, 4, 2, 12, 0, EDT), Session.Regular, "Maundy Thursday");
        assertSession(et(2026, 7, 2, 12, 0, EDT), Session.Regular, "Jul 2");
    }

    function test_halfDays2026() public pure {
        // Day after Thanksgiving: 13:00 close.
        assertSession(et(2026, 11, 27, 12, 59, EST), Session.Regular, "Nov 27 12:59");
        assertSession(et(2026, 11, 27, 13, 0, EST), Session.Extended, "Nov 27 13:00 closed early");
        assertSession(et(2026, 11, 27, 14, 0, EST), Session.Extended, "Nov 27 14:00");
        // Christmas Eve 2026 is a Thursday: 13:00 close.
        assertSession(et(2026, 12, 24, 12, 0, EST), Session.Regular, "Dec 24 noon");
        assertSession(et(2026, 12, 24, 14, 0, EST), Session.Extended, "Dec 24 14:00");
        // Jul 3 2026 is the observed holiday, NOT a half day (already tested closed).
        // A normal day still closes at 16:00.
        assertSession(et(2026, 11, 25, 14, 0, EST), Session.Regular, "Nov 25 14:00 full day");
    }

    function test_halfDays_laterYears() public pure {
        // 2028: Jul 4 is a Tuesday -> Mon Jul 3 early close.
        assertSession(et(2028, 7, 3, 14, 0, EDT), Session.Extended, "Jul 3 2028 14:00");
        assertSession(et(2028, 7, 3, 12, 0, EDT), Session.Regular, "Jul 3 2028 noon");
        // 2027: Dec 25 is Saturday -> Fri Dec 24 is the observed holiday, not a half day.
        assertSession(et(2027, 12, 24, 12, 0, EST), Session.Closed, "Dec 24 2027 observed Christmas");
    }

    function test_newYears_saturdayNotObserved() public pure {
        // Jan 1 2028 is a Saturday: NYSE does not close Fri Dec 31 2027.
        assertSession(et(2027, 12, 31, 12, 0, EST), Session.Regular, "Dec 31 2027 open");
        // Jan 1 2029 is a Monday: closed.
        assertSession(et(2029, 1, 1, 12, 0, EST), Session.Closed, "Jan 1 2029");
    }

    // ── DST ─────────────────────────────────────────────────────────────────────

    function test_dstBoundaries2026() public pure {
        // Spring forward: Sun Mar 8 2026 02:00 EST -> 03:00 EDT (07:00 UTC).
        assertEq(MarketHours.utcOffset(et(2026, 3, 8, 1, 59, EST)), EST, "01:59 EST");
        assertEq(MarketHours.utcOffset(et(2026, 3, 8, 3, 0, EDT)), EDT, "03:00 EDT");
        // Fall back: Sun Nov 1 2026 02:00 EDT -> 01:00 EST (06:00 UTC).
        assertEq(MarketHours.utcOffset(et(2026, 11, 1, 1, 59, EDT)), EDT, "01:59 EDT");
        assertEq(MarketHours.utcOffset(et(2026, 11, 1, 1, 0, EST)), EST, "01:00 EST after fallback");
        // Same wall-clock open on both sides of the switch resolves to Regular.
        assertSession(et(2026, 3, 9, 9, 30, EDT), Session.Regular, "first EDT open");
        assertSession(et(2026, 11, 2, 9, 30, EST), Session.Regular, "first EST open");
    }

    // ── lastCloseAt / lastOpenAt ───────────────────────────────────────────────

    function test_lastCloseAt_laborDayWeekend() public pure {
        uint256 friClose = et(2026, 9, 4, 20, 0, EDT);
        assertEq(lastCloseAt(et(2026, 9, 4, 21, 0, EDT)), friClose, "Fri 21:00");
        assertEq(lastCloseAt(et(2026, 9, 5, 12, 0, EDT)), friClose, "Sat");
        assertEq(lastCloseAt(et(2026, 9, 6, 21, 0, EDT)), friClose, "Sun 21:00");
        assertEq(lastCloseAt(et(2026, 9, 7, 12, 0, EDT)), friClose, "Labor Day");
        assertEq(lastCloseAt(et(2026, 9, 7, 19, 59, EDT)), friClose, "Labor Day 19:59, last closed minute");
        // 20:00 on Labor Day is Tuesday's overnight: open again, ~72h after Friday's close.
        uint256 reopen = et(2026, 9, 7, 20, 0, EDT);
        assertEq(lastCloseAt(reopen), reopen, "Labor Day 20:00 reopens");
        assertEq(reopen - friClose, 72 hours, "Labor Day dark window is 72h");
    }

    function test_lastCloseAt_midweekHoliday() public pure {
        uint256 wedClose = et(2026, 11, 25, 20, 0, EST);
        assertEq(lastCloseAt(et(2026, 11, 25, 21, 0, EST)), wedClose, "Wed 21:00 before Thanksgiving");
        assertEq(lastCloseAt(et(2026, 11, 26, 2, 0, EST)), wedClose, "Thanksgiving 02:00");
        assertEq(lastCloseAt(et(2026, 11, 26, 12, 0, EST)), wedClose, "Thanksgiving noon");
    }

    function test_lastCloseAt_returnsTsWhenOpen() public pure {
        uint256 ts = et(2026, 9, 4, 12, 0, EDT);
        assertEq(lastCloseAt(ts), ts, "open -> ts");
        uint256 ts2 = et(2026, 9, 8, 2, 0, EDT);
        assertEq(lastCloseAt(ts2), ts2, "Tue overnight after Labor Day -> ts");
    }

    function test_lastOpenAt() public pure {
        // Week of Aug 31 – Sep 4 reopened Sun Aug 30 20:00 ET.
        uint256 reopen = et(2026, 8, 30, 20, 0, EDT);
        assertEq(MarketHours.lastOpenAt(et(2026, 9, 2, 12, 0, EDT)), reopen, "Wed noon");
        assertEq(MarketHours.lastOpenAt(et(2026, 8, 31, 1, 0, EDT)), reopen, "Mon 01:00 overnight");
        assertEq(MarketHours.lastOpenAt(et(2026, 9, 4, 19, 0, EDT)), reopen, "Fri 19:00");
        // During the Labor Day closure the most recent reopen is still Aug 30.
        assertEq(MarketHours.lastOpenAt(et(2026, 9, 6, 12, 0, EDT)), reopen, "Sun during closure");
        // After Labor Day the run Tue–Fri reopened Mon Sep 7 20:00 ET.
        assertEq(MarketHours.lastOpenAt(et(2026, 9, 8, 12, 0, EDT)), et(2026, 9, 7, 20, 0, EDT), "Tue after Labor Day");
        // Sunday 20:00 itself is the reopen instant.
        assertEq(MarketHours.lastOpenAt(et(2026, 9, 13, 20, 0, EDT)), et(2026, 9, 13, 20, 0, EDT), "Sun 20:00 exact");
    }

    // ── totality ────────────────────────────────────────────────────────────────

    /// Every timestamp in the supported window maps to exactly one Session, no reverts,
    /// and the derived calendar timestamps are consistent with it.
    function testFuzz_calendar_isTotal(uint256 ts) public pure {
        ts = bound(ts, et(2026, 1, 1, 0, 0, EST), et(2030, 12, 31, 23, 59, EST));
        (Session s, uint256 lc) = MarketHours.calendar(ts);
        uint256 lo = MarketHours.lastOpenAt(ts);
        assertTrue(uint8(s) <= uint8(Session.Closed));
        assertLe(lc, ts, "lastClose <= ts");
        if (s == Session.Closed) assertLt(lc, ts, "closed => close strictly before");
        else assertEq(lc, ts, "open => lastClose == ts");
        assertLe(lo, ts, "lastOpen <= ts");
        assertTrue(sessionAt(lo) != Session.Closed, "reopen instant is open");
    }

    /// Hot-path gas: `calendar()` is flat across the week — no walk-back on the per-swap path.
    function test_gas_calendar_flatAcrossWeek() public view {
        uint256[3] memory ts = [et(2026, 8, 31, 12, 0, EDT), et(2026, 9, 4, 12, 0, EDT), et(2026, 9, 4, 2, 0, EDT)];
        for (uint256 i; i < 3; i++) {
            uint256 g = gasleft();
            MarketHours.calendar(ts[i]);
            assertLt(g - gasleft(), 8_000, "calendar() per-swap gas");
        }
    }

    // ── holidays 2027–2030 (dates hand-verified against NYSE rules) ──────────────

    function test_holidays2027() public pure {
        assertSession(et(2027, 1, 1, 12, 0, EST), Session.Closed, "New Year's Fri");
        assertSession(et(2027, 1, 18, 12, 0, EST), Session.Closed, "MLK");
        assertSession(et(2027, 2, 15, 12, 0, EST), Session.Closed, "Presidents'");
        assertSession(et(2027, 3, 26, 12, 0, EDT), Session.Closed, "Good Friday");
        assertSession(et(2027, 5, 31, 12, 0, EDT), Session.Closed, "Memorial");
        assertSession(et(2027, 6, 18, 12, 0, EDT), Session.Closed, "Juneteenth observed (Jun 19 = Sat)");
        assertSession(et(2027, 7, 5, 12, 0, EDT), Session.Closed, "Independence observed (Jul 4 = Sun)");
        assertSession(et(2027, 9, 6, 12, 0, EDT), Session.Closed, "Labor");
        assertSession(et(2027, 11, 25, 12, 0, EST), Session.Closed, "Thanksgiving");
        assertSession(et(2027, 12, 24, 12, 0, EST), Session.Closed, "Christmas observed (Dec 25 = Sat)");
        assertSession(et(2027, 6, 21, 12, 0, EDT), Session.Regular, "Mon after Juneteenth open");
        assertSession(et(2027, 7, 6, 12, 0, EDT), Session.Regular, "Tue after Jul 5 open");
    }

    function test_holidays2028() public pure {
        assertSession(et(2028, 1, 3, 12, 0, EST), Session.Regular, "Jan 1 = Sat: no observance, Mon Jan 3 open");
        assertSession(et(2028, 1, 17, 12, 0, EST), Session.Closed, "MLK");
        assertSession(et(2028, 2, 21, 12, 0, EST), Session.Closed, "Presidents'");
        assertSession(et(2028, 4, 14, 12, 0, EDT), Session.Closed, "Good Friday");
        assertSession(et(2028, 5, 29, 12, 0, EDT), Session.Closed, "Memorial (leap year)");
        assertSession(et(2028, 6, 19, 12, 0, EDT), Session.Closed, "Juneteenth Mon");
        assertSession(et(2028, 7, 4, 12, 0, EDT), Session.Closed, "Independence Tue");
        assertSession(et(2028, 9, 4, 12, 0, EDT), Session.Closed, "Labor");
        assertSession(et(2028, 11, 23, 12, 0, EST), Session.Closed, "Thanksgiving");
        assertSession(et(2028, 12, 25, 12, 0, EST), Session.Closed, "Christmas Mon");
        assertSession(et(2028, 2, 29, 12, 0, EST), Session.Regular, "leap day open");
    }

    function test_holidays2029() public pure {
        assertSession(et(2029, 1, 1, 12, 0, EST), Session.Closed, "New Year's Mon");
        assertSession(et(2029, 1, 15, 12, 0, EST), Session.Closed, "MLK");
        assertSession(et(2029, 2, 19, 12, 0, EST), Session.Closed, "Presidents'");
        assertSession(et(2029, 3, 30, 12, 0, EDT), Session.Closed, "Good Friday");
        assertSession(et(2029, 5, 28, 12, 0, EDT), Session.Closed, "Memorial");
        assertSession(et(2029, 6, 19, 12, 0, EDT), Session.Closed, "Juneteenth Tue");
        assertSession(et(2029, 7, 4, 12, 0, EDT), Session.Closed, "Independence Wed");
        assertSession(et(2029, 9, 3, 12, 0, EDT), Session.Closed, "Labor");
        assertSession(et(2029, 11, 22, 12, 0, EST), Session.Closed, "Thanksgiving");
        assertSession(et(2029, 12, 25, 12, 0, EST), Session.Closed, "Christmas Tue");
    }

    function test_holidays2030() public pure {
        assertSession(et(2030, 1, 1, 12, 0, EST), Session.Closed, "New Year's Tue");
        assertSession(et(2030, 1, 21, 12, 0, EST), Session.Closed, "MLK");
        assertSession(et(2030, 2, 18, 12, 0, EST), Session.Closed, "Presidents'");
        assertSession(et(2030, 4, 19, 12, 0, EDT), Session.Closed, "Good Friday");
        assertSession(et(2030, 5, 27, 12, 0, EDT), Session.Closed, "Memorial");
        assertSession(et(2030, 6, 19, 12, 0, EDT), Session.Closed, "Juneteenth Wed");
        assertSession(et(2030, 7, 4, 12, 0, EDT), Session.Closed, "Independence Thu");
        assertSession(et(2030, 9, 2, 12, 0, EDT), Session.Closed, "Labor");
        assertSession(et(2030, 11, 28, 12, 0, EST), Session.Closed, "Thanksgiving");
        assertSession(et(2030, 12, 25, 12, 0, EST), Session.Closed, "Christmas Wed");
    }

    function test_halfDays2027to2030() public pure {
        // Day after Thanksgiving, every year.
        assertSession(et(2027, 11, 26, 14, 0, EST), Session.Extended, "2027");
        assertSession(et(2028, 11, 24, 14, 0, EST), Session.Extended, "2028");
        assertSession(et(2029, 11, 23, 14, 0, EST), Session.Extended, "2029");
        assertSession(et(2030, 11, 29, 14, 0, EST), Session.Extended, "2030");
        // Jul 3 when Mon–Thu: 2028 Mon, 2029 Tue, 2030 Wed. 2027 Jul 3 is a Saturday.
        assertSession(et(2029, 7, 3, 14, 0, EDT), Session.Extended, "Jul 3 2029");
        assertSession(et(2030, 7, 3, 14, 0, EDT), Session.Extended, "Jul 3 2030");
        assertSession(et(2027, 7, 2, 14, 0, EDT), Session.Regular, "Jul 2 2027 full day");
        // Dec 24 when Mon–Thu: 2029 Mon, 2030 Tue. 2028 Dec 24 is a Sunday.
        assertSession(et(2029, 12, 24, 14, 0, EST), Session.Extended, "Dec 24 2029");
        assertSession(et(2030, 12, 24, 14, 0, EST), Session.Extended, "Dec 24 2030");
        assertSession(et(2028, 12, 22, 14, 0, EST), Session.Regular, "Fri Dec 22 2028 full day");
    }

    // ── session ticks across each DST switch ────────────────────────────────────

    function _ticks(uint256 y, uint256 m, uint256 d, uint256 off, string memory day) internal pure {
        assertSession(et(y, m, d, 3, 59, off), Session.Overnight, string.concat(day, " 03:59"));
        assertSession(et(y, m, d, 4, 0, off), Session.Extended, string.concat(day, " 04:00"));
        assertSession(et(y, m, d, 9, 29, off), Session.Extended, string.concat(day, " 09:29"));
        assertSession(et(y, m, d, 9, 30, off), Session.Regular, string.concat(day, " 09:30"));
        assertSession(et(y, m, d, 15, 59, off), Session.Regular, string.concat(day, " 15:59"));
        assertSession(et(y, m, d, 16, 0, off), Session.Extended, string.concat(day, " 16:00"));
        assertSession(et(y, m, d, 19, 59, off), Session.Extended, string.concat(day, " 19:59"));
    }

    function test_sessionTicks_aroundDST() public pure {
        _ticks(2026, 3, 6, EST, "Fri before spring-forward");
        _ticks(2026, 3, 9, EDT, "Mon after spring-forward");
        _ticks(2026, 10, 30, EDT, "Fri before fall-back");
        _ticks(2026, 11, 2, EST, "Mon after fall-back");
        _ticks(2027, 3, 15, EDT, "Mon after 2027 spring-forward");
        _ticks(2027, 11, 8, EST, "Mon after 2027 fall-back");
    }

    function test_midnightBoundary() public pure {
        assertSession(et(2026, 9, 3, 23, 59, EDT), Session.Overnight, "Thu 23:59");
        assertSession(et(2026, 9, 4, 0, 0, EDT), Session.Overnight, "Fri 00:00");
        assertSession(et(2026, 9, 4, 23, 59, EDT), Session.Closed, "Fri 23:59");
        assertSession(et(2026, 9, 5, 0, 0, EDT), Session.Closed, "Sat 00:00");
        assertSession(et(2026, 9, 6, 23, 59, EDT), Session.Closed, "Sun 23:59 before Labor Day");
        assertSession(et(2026, 9, 7, 23, 59, EDT), Session.Overnight, "Labor Day 23:59 = Tue overnight");
    }

    // ── one-day trading runs ────────────────────────────────────────────────────

    function test_thanksgivingFriday_isOneDayRun() public pure {
        // Friday Nov 27 2026 trades (half day); its run started Thu 20:00 ET.
        uint256 fri = et(2026, 11, 27, 12, 0, EST);
        assertEq(MarketHours.lastOpenAt(fri), et(2026, 11, 26, 20, 0, EST), "reopen Thu 20:00");
        assertEq(lastCloseAt(fri), fri, "open");
        assertSession(et(2026, 11, 26, 21, 0, EST), Session.Overnight, "Thanksgiving 21:00 = Fri overnight");
        // Following Monday's run reopened Sun Nov 29 20:00 ET.
        assertEq(MarketHours.lastOpenAt(et(2026, 11, 30, 12, 0, EST)), et(2026, 11, 29, 20, 0, EST), "Mon reopen");
    }

    // ── properties (fuzz) ───────────────────────────────────────────────────────

    uint256 constant FUZZ_LO = 1767243600; // 2026-01-01 00:00 EST
    uint256 constant FUZZ_HI = 1925010000; // 2030-12-31 23:00 EST

    function _etSec(uint256 ts) internal pure returns (uint256 sec, uint256 wd) {
        uint256 local = ts - MarketHours.utcOffset(ts);
        return (local % 1 days, DateTimeLib.weekday(local));
    }

    /// Each session only ever occurs in its window. Uses utcOffset (pinned by test_dstBoundaries2026).
    function testFuzz_sessionMatchesWindow(uint256 ts) public pure {
        ts = bound(ts, FUZZ_LO, FUZZ_HI);
        (uint256 sec, uint256 wd) = _etSec(ts);
        Session s = sessionAt(ts);
        if (s == Session.Regular) {
            assertTrue(wd <= DateTimeLib.FRI, "Regular on a weekday");
            assertTrue(sec >= 9 hours + 30 minutes && sec < 16 hours, "Regular in 09:30-16:00");
        } else if (s == Session.Overnight) {
            assertTrue(sec >= 20 hours || sec < 4 hours, "Overnight in 20:00-04:00");
        } else if (s == Session.Extended) {
            assertTrue(wd <= DateTimeLib.FRI, "Extended on a weekday");
            assertTrue((sec >= 4 hours && sec < 9 hours + 30 minutes) || (sec >= 13 hours && sec < 20 hours), "Extended window");
        }
    }

    /// Sessions change only at the five bell seconds: 04:00, 09:30, 13:00, 16:00, 20:00 ET.
    function testFuzz_transitionsOnlyAtBells(uint256 ts) public pure {
        ts = bound(ts, FUZZ_LO, FUZZ_HI - 1);
        if (sessionAt(ts) == sessionAt(ts + 1)) return;
        (uint256 sec,) = _etSec(ts + 1);
        assertTrue(
            sec == 4 hours || sec == 9 hours + 30 minutes || sec == 13 hours || sec == 16 hours || sec == 20 hours,
            "transition off-bell"
        );
    }

    /// Weekends are never open, in ET terms.
    function testFuzz_weekendsClosed(uint256 ts) public pure {
        ts = bound(ts, FUZZ_LO, FUZZ_HI);
        (uint256 sec, uint256 wd) = _etSec(ts);
        if (wd == DateTimeLib.SAT) assertTrue(sessionAt(ts) == Session.Closed, "Saturday");
        if (wd == DateTimeLib.SUN && sec < 20 hours) assertTrue(sessionAt(ts) == Session.Closed, "Sunday before 20:00");
    }

    /// Derived calendar timestamps always land on 20:00 ET.
    function testFuzz_closeAndOpenAreAt2000ET(uint256 ts) public pure {
        ts = bound(ts, FUZZ_LO, FUZZ_HI);
        (Session s, uint256 lc) = MarketHours.calendar(ts);
        if (s == Session.Closed) {
            (uint256 sec,) = _etSec(lc);
            assertEq(sec, 20 hours, "lastClose at 20:00 ET");
        }
        (uint256 osec,) = _etSec(MarketHours.lastOpenAt(ts));
        assertEq(osec, 20 hours, "lastOpen at 20:00 ET");
    }
}
