// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

import {IMarketStateAdapter, MarketState, Session} from "../src/IMarketStateAdapter.sol";
import {MockAggregatorV3, MockPausableStock} from "./mocks/MockAggregatorV3.sol";

/// Spec for `ChainlinkEquityAdapter`, written before the contract. Deployed by artifact name so
/// this file compiles against the empty stub; every test fails until the adapter exists.
///
/// Expected constructor:
///   (address stockFeed, address quoteFeed /* 0 = dollar quote */, address stockToken /* 0 = no
///    oraclePaused() check */, uint256 maxStaleness, uint256 plausibilityBps /* 0 = disabled */)
///   reverts if stockFeed == 0 or maxStaleness <= 1 days (the 86400s heartbeat; B1).
///
/// getMarketState() — total, view, never reverts:
///   session        = MarketHours.calendar(block.timestamp) session (hook ignores it; tooling reads it)
///   price          = latest answer scaled to 1e18 from the feed's decimals; 0 if the read fails,
///                    the answer is <= 0, decimals() fails, or the scaling would overflow
///   updatedAt      = latest round's updatedAt; 0 on failure
///   prevPrice      = see "prevPrice walk" below; 0 if unknown
///   hasQuoteFeed   = quoteFeed != 0
///   quotePrice / prevQuotePrice = same two rules applied to the quote feed
///   isLive         = price != 0
///                    && (updatedAt >= now || now - updatedAt <= maxStaleness)   // future never underflows
///                    && plausible(price, prevPrice)                              // see below
///                    && (stockToken == 0 || oraclePaused() returned false)       // a revert counts as paused
///                    && (quoteFeed == 0 || (quotePrice != 0 && quote fresh by the same rule))
///   plausible      = plausibilityBps == 0 || prevPrice == 0 || |price - prev| * 10_000 <= prev * plausibilityBps
///
/// prevPrice walk (stateless; from round history, at most LOOKBACK rounds back from the latest):
///   cur = latest
///   for i in 1..LOOKBACK:
///     if latest.roundId < i: stop
///     r = getRoundData(latest.roundId - i); on revert or answer <= 0: stop
///     gap = r.updatedAt > cur.updatedAt ? 0 : cur.updatedAt - r.updatedAt  // never underflow
///     if gap >= CLOSURE_GAP: return r.answer                               // last print before a closure
///     if no candidate yet and r.answer != latest.answer: candidate = r.answer
///     cur = r
///   return candidate (0 if none)
///   A heartbeat re-print (same answer) is skipped. A gap of CLOSURE_GAP or more between consecutive
///   rounds is a market closure (feeds go dark ~52h over a weekend, 24h on a quiet day is the
///   heartbeat), and the print before it wins even if a different print sits between — so a
///   reopen followed by a retrace (100 -> 103 -> 102) still reports prev = 100 (B6).
///
/// Constants the implementation should put in Constants.sol:
///   CLOSURE_GAP = 36 hours;  LOOKBACK = 6
contract ChainlinkEquityAdapterTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant EDT = 4 hours;
    uint256 constant MAX_STALENESS = 2 days;
    uint256 constant PLAUSIBILITY_BPS = 2000; // 20%
    uint80 constant PHASE_1_FIRST_ROUND = (uint80(1) << 64) | 1;

    MockAggregatorV3 stock;
    MockAggregatorV3 quoteFeed;
    MockPausableStock token;
    IMarketStateAdapter adapter;

    uint256 friNoon; // Fri Sep 4 2026 12:00 ET, regular hours
    uint256 friClose; // Fri Sep 4 2026 20:00 ET
    uint256 sunReopen; // Sun Sep 6 2026 20:00 ET

    function setUp() public {
        friNoon = et(2026, 9, 4, 12, 0);
        friClose = et(2026, 9, 4, 20, 0);
        sunReopen = et(2026, 9, 6, 20, 0);
        vm.warp(friNoon);

        stock = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        quoteFeed = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        token = new MockPausableStock();

        // Two prints this morning: 99.50 at 09:35, 100.00 at 11:00.
        stock.push(99_50000000, et(2026, 9, 4, 9, 35));
        stock.push(100_00000000, et(2026, 9, 4, 11, 0));

        adapter = deploy(address(stock), address(0), address(token), MAX_STALENESS, PLAUSIBILITY_BPS);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function et(uint256 y, uint256 m, uint256 d, uint256 h, uint256 min) internal pure returns (uint256) {
        return DateTimeLib.dateTimeToTimestamp(y, m, d, h, min, 0) + EDT;
    }

    function deploy(address stockFeed, address quote_, address stockToken, uint256 maxStaleness, uint256 bps)
        internal
        returns (IMarketStateAdapter)
    {
        return IMarketStateAdapter(
            deployCode(
                "ChainlinkEquityAdapter.sol:ChainlinkEquityAdapter",
                abi.encode(stockFeed, quote_, stockToken, maxStaleness, bps)
            )
        );
    }

    function state() internal view returns (MarketState memory) {
        return adapter.getMarketState();
    }

    // ── constructor ─────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroStockFeed() public {
        vm.expectRevert();
        deploy(address(0), address(0), address(0), MAX_STALENESS, 0);
    }

    function test_constructor_rejectsStalenessAtOrBelowHeartbeat() public {
        // B1: maxStaleness is a dead-feed net and must sit above the 86400s heartbeat.
        vm.expectRevert();
        deploy(address(stock), address(0), address(0), 1 days, 0);
        vm.expectRevert();
        deploy(address(stock), address(0), address(0), 1 hours, 0);
    }

    function test_constructor_acceptsOptionalLegsAsZero() public {
        IMarketStateAdapter a = deploy(address(stock), address(0), address(0), 1 days + 1, 0);
        MarketState memory m = a.getMarketState();
        assertTrue(m.isLive);
        assertFalse(m.hasQuoteFeed);
    }

    // ── the happy path ──────────────────────────────────────────────────────

    function test_regularHours_freshFeed_isLive() public view {
        MarketState memory m = state();
        assertTrue(m.isLive, "live");
        assertEq(uint8(m.session), uint8(Session.Regular), "session from the calendar");
        assertEq(m.price, 100e18, "8 decimals scaled to 1e18");
        assertEq(m.prevPrice, 995e17, "previous different print");
        assertEq(m.updatedAt, et(2026, 9, 4, 11, 0), "latest round's updatedAt");
        assertFalse(m.hasQuoteFeed);
        assertEq(m.quotePrice, 0);
        assertEq(m.prevQuotePrice, 0);
    }

    function test_sessionField_followsTheCalendar() public {
        vm.warp(et(2026, 9, 5, 12, 0)); // Saturday
        assertEq(uint8(state().session), uint8(Session.Closed));
        vm.warp(et(2026, 9, 3, 22, 0)); // Thursday 22:00 = Friday's overnight
        assertEq(uint8(state().session), uint8(Session.Overnight));
        vm.warp(et(2026, 9, 4, 17, 0)); // Friday post-market
        assertEq(uint8(state().session), uint8(Session.Extended));
    }

    // ── decimals ────────────────────────────────────────────────────────────

    function test_decimals_scaledTo1e18() public {
        stock.setLatest(320_52000000, block.timestamp - 60); // AAPL-style 8-dec print
        assertEq(state().price, 320_52e16);

        MockAggregatorV3 f18 = new MockAggregatorV3(18, PHASE_1_FIRST_ROUND);
        f18.push(int256(100e18), block.timestamp - 60);
        assertEq(deploy(address(f18), address(0), address(0), MAX_STALENESS, 0).getMarketState().price, 100e18, "18-dec passthrough");

        MockAggregatorV3 f20 = new MockAggregatorV3(20, PHASE_1_FIRST_ROUND);
        f20.push(int256(100e20), block.timestamp - 60);
        assertEq(deploy(address(f20), address(0), address(0), MAX_STALENESS, 0).getMarketState().price, 100e18, "20-dec divides down");

        MockAggregatorV3 f0 = new MockAggregatorV3(0, PHASE_1_FIRST_ROUND);
        f0.push(100, block.timestamp - 60);
        assertEq(deploy(address(f0), address(0), address(0), MAX_STALENESS, 0).getMarketState().price, 100e18, "0-dec");
    }

    // ── prevPrice walk ──────────────────────────────────────────────────────

    function test_prevPrice_skipsHeartbeatReprints() public {
        // 99.50, 100, 100, 100 -> prev is 99.50, not 100.
        stock.push(100_00000000, block.timestamp - 3000);
        stock.push(100_00000000, block.timestamp - 60);
        MarketState memory m = state();
        assertEq(m.price, 100e18);
        assertEq(m.prevPrice, 995e17, "unchanged re-prints are not a move");
    }

    function test_prevPrice_afterClosure_isLastPrintBeforeTheClose() public {
        // Fri: 100.50 at 19:00. Dark 49h. Sun 20:05: 103. Sun 20:30: 102 (retrace).
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        stock.push(103_00000000, sunReopen + 5 minutes);
        stock.push(102_00000000, sunReopen + 30 minutes);
        vm.warp(sunReopen + 31 minutes);
        MarketState memory m = state();
        assertEq(m.price, 102e18);
        assertEq(m.prevPrice, 1005e17, "B6: the print before the closure, not the 103 in between");
        assertTrue(m.isLive, "reopen print is fresh and within 20% of prev");
    }

    function test_prevPrice_afterClosure_singleReopenPrint() public {
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        stock.push(103_00000000, sunReopen + 5 minutes);
        vm.warp(sunReopen + 6 minutes);
        assertEq(state().prevPrice, 1005e17);
    }

    function test_prevPrice_reopenAtSamePrice_reportsNoMove() public {
        // 100.50 before the close, 100.50 on reopen: prev == price, the hook reads "no move".
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        stock.push(100_50000000, sunReopen + 5 minutes);
        vm.warp(sunReopen + 6 minutes);
        MarketState memory m = state();
        assertEq(m.price, 1005e17);
        assertEq(m.prevPrice, 1005e17, "the closure print wins even though it equals the current price");
    }

    function test_prevPrice_heartbeatGap_isNotAClosure() public {
        // A quiet day: exactly one heartbeat (24h) between prints. Not a closure; prev is the
        // ordinary previous different print.
        MockAggregatorV3 f = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        f.push(100_00000000, block.timestamp - 27 hours);
        f.push(101_00000000, block.timestamp - 26 hours);
        f.push(101_00000000, block.timestamp - 2 hours); // heartbeat re-print, 24h later
        f.push(101_50000000, block.timestamp - 60);
        MarketState memory m = deploy(address(f), address(0), address(0), MAX_STALENESS, 0).getMarketState();
        assertEq(m.price, 1015e17);
        assertEq(m.prevPrice, 101e18, "24h gap is the heartbeat, not a closure");
    }

    function test_prevPrice_closureScrollsOutOfTheLookback() public {
        // Once more than LOOKBACK different prints have landed since the close, the closure is out
        // of reach and prev is simply the previous different print.
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        for (uint256 i = 1; i <= 7; i++) {
            stock.push(int256(103_00000000 + i * 10000000), sunReopen + i * 5 minutes);
        }
        vm.warp(sunReopen + 40 minutes);
        MarketState memory m = state();
        assertEq(m.price, 1037e17);
        assertEq(m.prevPrice, 1036e17, "closure beyond LOOKBACK: previous different print");
    }

    function test_prevPrice_noHistory_isZero() public {
        // A brand-new feed with one round: getRoundData(roundId - 1) reverts -> unknown.
        MockAggregatorV3 fresh = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        fresh.push(100_00000000, block.timestamp - 60);
        MarketState memory m = deploy(address(fresh), address(0), address(0), MAX_STALENESS, 0).getMarketState();
        assertEq(m.price, 100e18);
        assertEq(m.prevPrice, 0, "unknown history -> 0 -> the hook charges");
        assertTrue(m.isLive, "unknown history does not make the feed dead");
    }

    function test_prevPrice_historyRevert_isZero_andDoesNotBlock() public {
        stock.setRevertHistory(true);
        MarketState memory m = state();
        assertEq(m.price, 100e18, "latest still readable");
        assertEq(m.prevPrice, 0, "history unreadable -> unknown");
        assertTrue(m.isLive);
    }

    function test_prevPrice_allReprints_withinLookback_isZero() public {
        // Seven identical prints on top of the history: no different print within reach.
        MockAggregatorV3 flat = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        for (uint256 i = 0; i < 8; i++) {
            flat.push(100_00000000, block.timestamp - 8 hours + i * 1 hours);
        }
        assertEq(deploy(address(flat), address(0), address(0), MAX_STALENESS, 0).getMarketState().prevPrice, 0);
    }

    // ── liveness: staleness ─────────────────────────────────────────────────

    function test_staleness_boundaryInclusive() public {
        uint256 printedAt = et(2026, 9, 4, 11, 0);
        vm.warp(printedAt + MAX_STALENESS);
        assertTrue(state().isLive, "exactly maxStaleness old: still live");
        vm.warp(printedAt + MAX_STALENESS + 1);
        MarketState memory m = state();
        assertFalse(m.isLive, "one second past: dead");
        assertEq(m.price, 100e18, "the last price is still reported for deviation");
    }

    function test_staleness_futureUpdatedAt_doesNotUnderflow() public {
        stock.setLatest(100_00000000, block.timestamp + 1 hours);
        assertTrue(state().isLive, "a clock skew in the future is fresh, not a revert");
    }

    function test_weekend_feedDark_stillLiveUntilMaxStaleness() public {
        // Sat noon, last print Fri 19:00: 17h old, well under the 2-day net. The calendar, not
        // the adapter, is what closes the market (B1/B2).
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        vm.warp(et(2026, 9, 5, 12, 0));
        MarketState memory m = state();
        assertTrue(m.isLive);
        assertEq(uint8(m.session), uint8(Session.Closed));
    }

    // ── liveness: plausibility ──────────────────────────────────────────────

    function test_plausibility_bigJumpIsNotLive_butPriceIsReported() public {
        stock.push(130_00000000, block.timestamp - 60); // +30% vs prev 100 with a 20% bound
        MarketState memory m = state();
        assertFalse(m.isLive, "implausible print");
        assertEq(m.price, 130e18);
        assertEq(m.prevPrice, 100e18);
    }

    function test_plausibility_withinBound_isLive() public {
        stock.push(119_00000000, block.timestamp - 60);
        assertTrue(state().isLive);
        stock.push(120_00000000, block.timestamp - 30); // prev is now 119: +0.84%
        assertTrue(state().isLive);
    }

    function test_plausibility_exactBoundInclusive() public {
        stock.push(120_00000000, block.timestamp - 60); // exactly +20% vs 100
        assertTrue(state().isLive, "<= bound is plausible");
    }

    function test_plausibility_disabledWhenZero() public {
        IMarketStateAdapter a = deploy(address(stock), address(0), address(0), MAX_STALENESS, 0);
        stock.push(500_00000000, block.timestamp - 60);
        assertTrue(a.getMarketState().isLive, "bps == 0: no plausibility check");
    }

    function test_plausibility_skippedWithoutHistory() public {
        stock.setRevertHistory(true);
        stock.push(500_00000000, block.timestamp - 60);
        assertTrue(state().isLive, "nothing to compare against");
    }

    // ── liveness: oraclePaused ──────────────────────────────────────────────

    function test_oraclePaused_makesItNotLive() public {
        token.setPaused(true);
        MarketState memory m = state();
        assertFalse(m.isLive, "corporate action: reference frozen");
        assertEq(m.price, 100e18, "price still reported");
        token.setPaused(false);
        assertTrue(state().isLive);
    }

    function test_oraclePaused_revertCountsAsPaused() public {
        token.setReverting(true);
        assertFalse(state().isLive, "cannot read the flag: fail adverse");
    }

    function test_oraclePaused_skippedWhenNoToken() public {
        IMarketStateAdapter a = deploy(address(stock), address(0), address(0), MAX_STALENESS, 0);
        assertTrue(a.getMarketState().isLive);
    }

    // ── never reverts ───────────────────────────────────────────────────────

    function test_feedRevert_returnsDeadState() public {
        stock.setRevertLatest(true);
        MarketState memory m = state();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
        assertEq(m.prevPrice, 0);
        assertEq(m.updatedAt, 0);
    }

    function test_feedWithNoCode_returnsDeadState() public {
        IMarketStateAdapter a = deploy(address(0xdead), address(0), address(0), MAX_STALENESS, 0);
        MarketState memory m = a.getMarketState();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
    }

    function test_nonPositiveAnswer_returnsDeadState() public {
        stock.setLatest(0, block.timestamp - 60);
        MarketState memory m = state();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
        stock.setLatest(-1, block.timestamp - 60);
        m = state();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
    }

    function test_decimalsRevert_returnsDeadState() public {
        stock.setRevertDecimals(true);
        MarketState memory m = state();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
    }

    function testFuzz_neverReverts(int256 answer, uint256 updatedAt, uint8 decimals_, uint80 firstRound) public {
        decimals_ = uint8(bound(decimals_, 0, 60));
        firstRound = uint80(bound(firstRound, 1, type(uint80).max - 2));
        MockAggregatorV3 f = new MockAggregatorV3(decimals_, firstRound);
        f.push(answer, updatedAt);
        f.push(answer, updatedAt);
        IMarketStateAdapter a = deploy(address(f), address(f), address(token), MAX_STALENESS, PLAUSIBILITY_BPS);
        a.getMarketState(); // any revert here fails the test: the adapter must be total
    }

    // ── quote feed (stock/SPY pools) ────────────────────────────────────────

    function test_quoteFeed_reportedAndScaled() public {
        quoteFeed.push(700_00000000, block.timestamp - 3600);
        quoteFeed.push(770_00000000, block.timestamp - 60);
        IMarketStateAdapter a =
            deploy(address(stock), address(quoteFeed), address(token), MAX_STALENESS, PLAUSIBILITY_BPS);
        MarketState memory m = a.getMarketState();
        assertTrue(m.hasQuoteFeed);
        assertTrue(m.isLive);
        assertEq(m.quotePrice, 770e18);
        assertEq(m.prevQuotePrice, 700e18, "same walk on the quote leg");
        assertEq(m.price, 100e18, "stock leg unchanged");
    }

    function test_quoteFeed_stale_makesItNotLive() public {
        quoteFeed.push(770_00000000, block.timestamp - MAX_STALENESS - 1);
        IMarketStateAdapter a = deploy(address(stock), address(quoteFeed), address(0), MAX_STALENESS, 0);
        MarketState memory m = a.getMarketState();
        assertFalse(m.isLive, "quote leg stale");
        assertEq(m.quotePrice, 770e18, "still reported");
    }

    function test_quoteFeed_revert_makesItNotLive_andDoesNotBlock() public {
        quoteFeed.push(770_00000000, block.timestamp - 60);
        quoteFeed.setRevertLatest(true);
        IMarketStateAdapter a = deploy(address(stock), address(quoteFeed), address(0), MAX_STALENESS, 0);
        MarketState memory m = a.getMarketState();
        assertFalse(m.isLive);
        assertEq(m.quotePrice, 0);
        assertEq(m.prevQuotePrice, 0);
        assertEq(m.price, 100e18, "stock leg unaffected");
    }

    function test_quoteFeed_plausibilityAppliesToStockLegOnly() public {
        // A 30% quote move is a quote-feed problem; the stock leg's plausibility is what gates isLive.
        quoteFeed.push(700_00000000, block.timestamp - 3600);
        quoteFeed.push(910_00000000, block.timestamp - 60);
        IMarketStateAdapter a =
            deploy(address(stock), address(quoteFeed), address(0), MAX_STALENESS, PLAUSIBILITY_BPS);
        assertTrue(a.getMarketState().isLive);
    }

    // ── gas ─────────────────────────────────────────────────────────────────

    function test_gas_getMarketState_dollarQuote() public {
        // Six warm-ish history reads at most; budget generous for a first cut.
        stock.push(100_50000000, block.timestamp - 60);
        uint256 g = gasleft();
        adapter.getMarketState();
        uint256 used = g - gasleft();
        emit log_named_uint("getMarketState gas (dollar quote)", used);
        assertLt(used, 60_000);
    }
}
