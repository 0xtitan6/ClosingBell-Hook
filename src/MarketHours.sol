// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Constants as C} from "./Constants.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @notice Which part of the trading day it is; sets the pool's minimum fee. `Closed` is first so
///         an unset value defaults to the safest answer.
enum Session {
    Closed,
    Regular,
    Extended,
    Overnight
}

/// @notice The New York Stock Exchange calendar. Give it a moment in time and it says which part
///         of the trading day that is, and if the market is shut, when it closed.
///
///         New York time, on a trading day:
///           Regular    09:30-16:00, the main session (13:00 on half-days)
///           Extended   04:00-09:30 and 16:00-20:00, before and after the bell
///           Overnight  20:00-04:00, counted as the next trading day
///           Closed     the rest: Friday evening to Sunday evening, and holidays
///
///         Holidays come from the exchange's rules, like "first Monday in September", not a list
///         of dates, so nothing expires.
/// @dev Not modelled: unscheduled closures, and after-hours ending early on half-days.
library MarketHours {
    uint256 private constant NONE = type(uint256).max;

    // ── public ──────────────────────────────────────────────────────────────

    /// @notice The one question the hook asks, once per swap.
    /// @return session   which part of the trading day it is
    /// @return lastClose when the market last shut, or the current time if it is open
    function calendar(uint256 tsUTC) internal pure returns (Session session, uint256 lastClose) {
        (uint256 day, uint256 sec) = _etParts(tsUTC);
        session = _session(day, sec);
        if (session != Session.Closed) return (session, tsUTC);
        lastClose = _etToUTC(_lastTradingDayOnOrBefore(sec < C.POST_END ? day - 1 : day), C.POST_END);
    }

    // ── New York time ───────────────────────────────────────────────────────

    /// @notice How far New York is behind UTC: 4h in daylight time, 5h in standard.
    /// @dev Daylight time runs 2nd Sunday of March to 1st Sunday of November, 02:00 local.
    function utcOffset(uint256 tsUTC) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = DateTimeLib.timestampToDate(tsUTC > C.EST_OFFSET ? tsUTC - C.EST_OFFSET : 0);
        if (m >= 4 && m <= 10) return C.EDT_OFFSET; // always daylight time
        if (m == 12 || m <= 2) return C.EST_OFFSET; // always standard time
        uint256 dstStart = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, 3, 2, DateTimeLib.SUN) + 7 hours;
        uint256 dstEnd = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, 11, 1, DateTimeLib.SUN) + 6 hours;
        return (tsUTC >= dstStart && tsUTC < dstEnd) ? C.EDT_OFFSET : C.EST_OFFSET;
    }

    /// @dev UTC timestamp to (New York day, seconds since New York midnight).
    function _etParts(uint256 tsUTC) private pure returns (uint256 day, uint256 sec) {
        uint256 local = tsUTC - utcOffset(tsUTC);
        return (local / 1 days, local % 1 days);
    }

    /// @dev The reverse. Only called with 20:00, well clear of the 02:00 clock change.
    function _etToUTC(uint256 day, uint256 sec) private pure returns (uint256) {
        uint256 local = day * 1 days + sec;
        uint256 candidate = local + C.EDT_OFFSET;
        return utcOffset(candidate) == C.EDT_OFFSET ? candidate : local + C.EST_OFFSET;
    }

    // ── sessions and trading days ───────────────────────────────────────────

    /// @dev After 20:00 we are in tomorrow's overnight session; before 04:00, today's.
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

    /// @dev Steps back over a weekend or a run of holidays. Never more than a few days.
    function _lastTradingDayOnOrBefore(uint256 day) private pure returns (uint256) {
        while (!_isTradingDay(day)) day -= 1;
        return day;
    }

    /// @dev Trading day, and when it closes. Holidays are dispatched by month, so a normal day
    ///      evaluates one or two rules. Early close (13:00): the day after Thanksgiving, and Dec 24
    ///      and Jul 3 when they fall Mon-Thu.
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

    /// @dev "The third Monday in January", and so on.
    function _nth(uint256 y, uint256 m, uint256 n, uint256 wd) private pure returns (uint256) {
        return DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, m, n, wd) / 1 days;
    }

    /// @dev The one holiday that moves. Two days before Easter, which is worked out with the
    ///      standard formula, so this holds for any year without a list.
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

    /// @dev A fixed-date holiday, moved off a weekend: back to Friday, or forward to Monday. One
    ///      real exchange exception: a Saturday New Year's Day does not close the Friday before.
    function _observed(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        uint256 day = DateTimeLib.dateToEpochDay(y, m, d);
        uint256 wd = DateTimeLib.weekday(day * 1 days);
        if (wd == DateTimeLib.SAT) return m == 1 ? NONE : day - 1;
        if (wd == DateTimeLib.SUN) return day + 1;
        return day;
    }
}
