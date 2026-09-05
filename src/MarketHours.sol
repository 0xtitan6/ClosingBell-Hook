// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Session} from "./IMarketStateAdapter.sol";
import {Constants as C} from "./Constants.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @notice NYSE trading calendar. Pure: maps a UTC timestamp to a `Session` and derives the
///         calendar timestamps that drive the fee ramps. No state, no feed read.
///
/// On a trading day (Mon–Fri, not a holiday), Eastern Time:
///   Overnight  20:00 prev day – 04:00   (belongs to the FOLLOWING trading day)
///   Extended   04:00 – 09:30, close – 20:00
///   Regular    09:30 – 16:00            (13:00 on early-close days)
///   Closed     everything else — Fri 20:00 → Sun 20:00, full-day holidays
///
library MarketHours {
    uint256 private constant NONE = type(uint256).max;

    // ── public ──────────────────────────────────────────────────────────────

    /// @notice The per-swap calendar read, from one ET decomposition (~6k gas).
    /// @return session   current session
    /// @return lastClose 20:00 ET on the last trading day before the current closed window,
    ///                   or `tsUTC` if open. Drives `stalenessMult`.
    function calendar(uint256 tsUTC) internal pure returns (Session session, uint256 lastClose) {
        (uint256 day, uint256 sec) = _etParts(tsUTC);
        session = _session(day, sec);
        if (session != Session.Closed) return (session, tsUTC);
        lastClose = _etToUTC(_lastTradingDayOnOrBefore(sec < C.POST_END ? day - 1 : day), C.POST_END);
    }

    /// @notice 20:00 ET before the first trading day of the current (or most recent) run of
    ///         consecutive trading days — the reopen instant. Drives `decayWindow`.
    /// @dev Deliberately NOT part of `calendar()`: it walks back up to four weekdays (~2.4k each),
    ///      and a reopen can only be recent inside an Overnight session. Call it only then.
    function lastOpenAt(uint256 tsUTC) internal pure returns (uint256) {
        (uint256 day, uint256 sec) = _etParts(tsUTC);
        uint256 runDay;
        if (_session(day, sec) == Session.Closed) {
            runDay = _lastTradingDayOnOrBefore(sec < C.POST_END ? day - 1 : day);
        } else {
            runDay = sec >= C.POST_END ? day + 1 : day;
        }
        while (_isTradingDay(runDay - 1)) runDay -= 1;
        return _etToUTC(runDay - 1, C.POST_END);
    }

    // ── Eastern Time ────────────────────────────────────────────────────────

    /// @dev 4h during US DST (2nd Sun of March 02:00 → 1st Sun of Nov 02:00, local), else 5h.
    ///      Only March and November straddle a transition; every other month is decided by name.
    function utcOffset(uint256 tsUTC) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = DateTimeLib.timestampToDate(tsUTC > C.EST_OFFSET ? tsUTC - C.EST_OFFSET : 0);
        if (m >= 4 && m <= 10) return C.EDT_OFFSET;
        if (m == 12 || m <= 2) return C.EST_OFFSET;
        uint256 dstStart = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, 3, 2, DateTimeLib.SUN) + 7 hours;
        uint256 dstEnd = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, 11, 1, DateTimeLib.SUN) + 6 hours;
        return (tsUTC >= dstStart && tsUTC < dstEnd) ? C.EDT_OFFSET : C.EST_OFFSET;
    }

    /// @dev UTC → (ET epoch day, seconds since ET midnight).
    function _etParts(uint256 tsUTC) private pure returns (uint256 day, uint256 sec) {
        uint256 local = tsUTC - utcOffset(tsUTC);
        return (local / 1 days, local % 1 days);
    }

    /// @dev Exact away from the 02:00 DST transition hour; only ever called with 20:00.
    function _etToUTC(uint256 day, uint256 sec) private pure returns (uint256) {
        uint256 local = day * 1 days + sec;
        uint256 candidate = local + C.EDT_OFFSET;
        return utcOffset(candidate) == C.EDT_OFFSET ? candidate : local + C.EST_OFFSET;
    }

    // ── sessions and trading days ───────────────────────────────────────────

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

    function _lastTradingDayOnOrBefore(uint256 day) private pure returns (uint256) {
        while (!_isTradingDay(day)) day -= 1;
        return day;
    }

    /// @dev One date decode answers both questions about a day. Holidays are NYSE rules
    ///      dispatched by month; Good Friday (Easter-derived) is tabled 2026–2030.
    ///      Early close (13:00): day after Thanksgiving; Dec 24 and Jul 3 when Mon–Thu.
    function _dayInfo(uint256 day) private pure returns (bool trading, uint256 closeSec) {
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.epochDayToDate(day);
        uint256 wd = DateTimeLib.weekday(day * 1 days);

        bool holiday;
        if (m == 1) holiday = day == _observed(y, 1, 1) || day == _nth(y, 1, 3, DateTimeLib.MON); // New Year's, MLK
        else if (m == 2) holiday = day == _nth(y, 2, 3, DateTimeLib.MON); // Presidents'
        else if (m == 3 || m == 4) {
            if (y == 2026) holiday = day == DateTimeLib.dateToEpochDay(2026, 4, 3);
            else if (y == 2027) holiday = day == DateTimeLib.dateToEpochDay(2027, 3, 26);
            else if (y == 2028) holiday = day == DateTimeLib.dateToEpochDay(2028, 4, 14);
            else if (y == 2029) holiday = day == DateTimeLib.dateToEpochDay(2029, 3, 30);
            else if (y == 2030) holiday = day == DateTimeLib.dateToEpochDay(2030, 4, 19); // Good Friday; extend before 2031
        }
        else if (m == 5) holiday = day == _nth(y, 6, 1, DateTimeLib.MON) - 7; // Memorial: last Mon of May
        else if (m == 6) holiday = day == _observed(y, 6, 19); // Juneteenth
        else if (m == 7) holiday = day == _observed(y, 7, 4); // Independence
        else if (m == 9) holiday = day == _nth(y, 9, 1, DateTimeLib.MON); // Labor
        else if (m == 11) holiday = day == _nth(y, 11, 4, DateTimeLib.THU); // Thanksgiving
        else if (m == 12) holiday = day == _observed(y, 12, 25); // Christmas
        trading = wd <= DateTimeLib.FRI && !holiday;

        closeSec = C.CLOSE_SEC;
        if (m == 11 && day == _nth(y, 11, 4, DateTimeLib.THU) + 1) closeSec = C.HALF_CLOSE_SEC;
        else if (((m == 12 && d == 24) || (m == 7 && d == 3)) && wd <= DateTimeLib.THU) closeSec = C.HALF_CLOSE_SEC;
    }

    // ── holiday rules ───────────────────────────────────────────────────────

    /// @dev Epoch day of the n-th weekday `wd` in month `m` of year `y`.
    function _nth(uint256 y, uint256 m, uint256 n, uint256 wd) private pure returns (uint256) {
        return DateTimeLib.nthWeekdayInMonthOfYearTimestamp(y, m, n, wd) / 1 days;
    }

    /// @dev Fixed-date holiday with weekend observance: Sat → Fri, Sun → Mon.
    ///      NYSE does not observe New Year's on Dec 31 when Jan 1 is a Saturday.
    function _observed(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        uint256 day = DateTimeLib.dateToEpochDay(y, m, d);
        uint256 wd = DateTimeLib.weekday(day * 1 days);
        if (wd == DateTimeLib.SAT) return m == 1 ? NONE : day - 1;
        if (wd == DateTimeLib.SUN) return day + 1;
        return day;
    }
}
