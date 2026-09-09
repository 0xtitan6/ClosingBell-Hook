// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Session} from "./IMarketStateAdapter.sol";
import {Constants as C} from "./Constants.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @notice The NYSE calendar. Given a timestamp, says which trading session it is and, if the
///         market is closed, when it closed. Pure math, no state.
///
/// Sessions, in New York time, on a normal trading day (Mon–Fri, not a holiday):
///   Overnight  20:00 the evening before – 04:00   (counts as the NEXT day's session)
///   Extended   04:00 – 09:30 and 16:00 – 20:00     (pre- and post-market)
///   Regular    09:30 – 16:00                        (13:00 on early-close days)
///   Closed     everything else: Fri 20:00 → Sun 20:00, and holidays
///
/// Holidays follow NYSE's rules (e.g. "first Monday of September"), so nothing needs updating
/// year to year. Not modelled: unscheduled closures, and after-hours ending at 17:00 on early-close days.
library MarketHours {
    uint256 private constant NONE = type(uint256).max;

    // ── public ──────────────────────────────────────────────────────────────

    /// @notice The one call the hook makes per swap.
    /// @return session   which session it is right now
    /// @return lastClose when the market closed (20:00 NY on the last trading day), or `tsUTC` if open
    function calendar(uint256 tsUTC) internal pure returns (Session session, uint256 lastClose) {
        (uint256 day, uint256 sec) = _etParts(tsUTC);
        session = _session(day, sec);
        if (session != Session.Closed) return (session, tsUTC);
        lastClose = _etToUTC(_lastTradingDayOnOrBefore(sec < C.POST_END ? day - 1 : day), C.POST_END);
    }

    // ── New York time ───────────────────────────────────────────────────────

    /// @notice How far New York is behind UTC right now: 4h in daylight time, 5h in standard time.
    ///         Daylight time runs from the 2nd Sunday of March to the 1st Sunday of November, 02:00 local.
    function utcOffset(uint256 tsUTC) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = DateTimeLib.timestampToDate(tsUTC > C.EST_OFFSET ? tsUTC - C.EST_OFFSET : 0);
        if (m >= 4 && m <= 10) return C.EDT_OFFSET; // always daylight time
        if (m == 12 || m <= 2) return C.EST_OFFSET; // always standard time
        uint256 dstStart = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, 3, 2, DateTimeLib.SUN) + 7 hours;
        uint256 dstEnd = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, 11, 1, DateTimeLib.SUN) + 6 hours;
        return (tsUTC >= dstStart && tsUTC < dstEnd) ? C.EDT_OFFSET : C.EST_OFFSET;
    }

    /// @dev UTC timestamp → (New York calendar day, seconds since New York midnight).
    function _etParts(uint256 tsUTC) private pure returns (uint256 day, uint256 sec) {
        uint256 local = tsUTC - utcOffset(tsUTC);
        return (local / 1 days, local % 1 days);
    }

    /// @dev The reverse. Only ever called with 20:00, well clear of the 02:00 clock change.
    function _etToUTC(uint256 day, uint256 sec) private pure returns (uint256) {
        uint256 local = day * 1 days + sec;
        uint256 candidate = local + C.EDT_OFFSET;
        return utcOffset(candidate) == C.EDT_OFFSET ? candidate : local + C.EST_OFFSET;
    }

    // ── sessions and trading days ───────────────────────────────────────────

    /// @dev The session decision. After 20:00 we are in tomorrow's overnight; before 04:00, today's.
    function _session(uint256 day, uint256 sec) private pure returns (Session) {
        if (sec >= C.POST_END) return _isTradingDay(day + 1) ? Session.Overnight : Session.Closed;
        if (sec < C.PRE_START) return _isTradingDay(day) ? Session.Overnight : Session.Closed;
        (bool trading, uint256 closeSec) = _dayInfo(day);
        if (!trading) return Session.Closed;
        if (sec < C.OPEN_SEC) return Session.Extended;
        if (sec < closeSec) return Session.Regular;
        return Session.Extended;
    }

    function _isTradingDay(uint256 day) private pure returns (bool trading) {
        (trading,) = _dayInfo(day);
    }

    /// @dev Walks back over a weekend or holiday. Never more than a few steps.
    function _lastTradingDayOnOrBefore(uint256 day) private pure returns (uint256) {
        while (!_isTradingDay(day)) day -= 1;
        return day;
    }

    /// @dev Is this day a trading day, and when does it close? Holidays are checked by month so a
    ///      normal day evaluates one or two rules. Early close (13:00) on the day after Thanksgiving,
    ///      and on Dec 24 and Jul 3 when they fall Mon–Thu.
    function _dayInfo(uint256 day) private pure returns (bool trading, uint256 closeSec) {
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.epochDayToDate(day);
        uint256 wd = DateTimeLib.weekday(day * 1 days);

        bool holiday;
        if (m == 1) holiday = day == _observed(y, 1, 1) || day == _nth(y, 1, 3, DateTimeLib.MON); // New Year's, MLK

        else if (m == 2) holiday = day == _nth(y, 2, 3, DateTimeLib.MON); // Presidents' Day

        else if (m == 3 || m == 4) holiday = day == _goodFriday(y);
        else if (m == 5) holiday = day == _nth(y, 6, 1, DateTimeLib.MON) - 7; // Memorial Day (last Mon of May)

        else if (m == 6) holiday = day == _observed(y, 6, 19); // Juneteenth

        else if (m == 7) holiday = day == _observed(y, 7, 4); // Independence Day

        else if (m == 9) holiday = day == _nth(y, 9, 1, DateTimeLib.MON); // Labor Day

        else if (m == 11) holiday = day == _nth(y, 11, 4, DateTimeLib.THU); // Thanksgiving

        else if (m == 12) holiday = day == _observed(y, 12, 25); // Christmas
        trading = wd <= DateTimeLib.FRI && !holiday;

        closeSec = C.CLOSE_SEC;
        if (m == 11 && day == _nth(y, 11, 4, DateTimeLib.THU) + 1) closeSec = C.HALF_CLOSE_SEC;
        else if (((m == 12 && d == 24) || (m == 7 && d == 3)) && wd <= DateTimeLib.THU) closeSec = C.HALF_CLOSE_SEC;
    }

    // ── holiday rules ───────────────────────────────────────────────────────

    /// @dev "The n-th <weekday> of <month>", as a day number.
    function _nth(uint256 y, uint256 m, uint256 n, uint256 wd) private pure returns (uint256) {
        return DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, m, n, wd) / 1 days;
    }

    /// @dev Good Friday is two days before Easter. Easter is computed (the standard Gregorian
    ///      algorithm), so this works for any year with no table to maintain.
    function _goodFriday(uint256 y) private pure returns (uint256) {
        unchecked {
            uint256 a = y % 19;
            uint256 b = y / 100;
            uint256 c = y % 100;
            uint256 h = (19 * a + b - b / 4 - (b - (b + 8) / 25 + 1) / 3 + 15) % 30;
            uint256 l = (32 + 2 * (b % 4) + 2 * (c / 4) - h - c % 4) % 7;
            uint256 n = h + l - 7 * ((a + 11 * h + 22 * l) / 451) + 114;
            return DateTimeLib.dateToEpochDay(y, n / 31, n % 31 + 1) - 2;
        }
    }

    /// @dev A fixed-date holiday, moved to the nearest weekday if it lands on a weekend
    ///      (Saturday → Friday, Sunday → Monday). One exception: when New Year's Day is a
    ///      Saturday, NYSE stays open on Friday Dec 31.
    function _observed(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        uint256 day = DateTimeLib.dateToEpochDay(y, m, d);
        uint256 wd = DateTimeLib.weekday(day * 1 days);
        if (wd == DateTimeLib.SAT) return m == 1 ? NONE : day - 1;
        if (wd == DateTimeLib.SUN) return day + 1;
        return day;
    }
}
