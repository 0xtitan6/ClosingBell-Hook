// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

import {IMarketStateAdapter, MarketState, Session} from "../src/IMarketStateAdapter.sol";
import {AggregatorV3Interface, IOraclePausable} from "../src/AggregatorV3Interface.sol";
import {ChainlinkEquityAdapter} from "../src/ChainlinkEquityAdapter.sol";
import {MockAggregatorV3, MockPausableStock, MockRawReturner} from "./mocks/MockAggregatorV3.sol";

/// Spec for `ChainlinkEquityAdapter`. Written before the contract (Sept 8), revised in Round 4.
///
/// Constructor (stockFeed, quoteFeed /* 0 = dollar quote */, stockToken /* 0 = no oraclePaused()
/// check */, maxStaleness, plausibilityBps /* 0 = disabled */): reverts unless stockFeed and (if
/// set) quoteFeed answer decimals() and latestRoundData(), quoteFeed != stockFeed, stockToken (if
/// set) answers oraclePaused(), maxStaleness > 1 days (the 86400s heartbeat; B1), bps <= 10_000.
///
/// getMarketState() — total, view, never reverts. Every read is a raw staticcall, length-checked and
/// hand-decoded, because try/catch cannot catch a decoding failure in the caller:
///   session     = MarketHours.calendar(block.timestamp) (hook ignores it; tooling reads it)
///   price       = latest answer scaled to 1e18; 0 if unreadable, <= 0, decimals unreadable/>77, or overflow
///   updatedAt   = latest round's updatedAt; 0 on failure
///   loPrice/hiPrice = min/max over the latest print and up to LOOKBACK (6) rounds behind it,
///                 skipping non-positive answers, stopping at the first unreadable round;
///                 both 0 if no history round could be read (unknown -> the hook charges)
///   hasQuoteFeed, quotePrice, loQuotePrice, hiQuotePrice = the same for the quote feed
///   isLive      = price != 0
///                 && (updatedAt >= now || now - updatedAt <= maxStaleness)
///                 && plausible(price, lastDistinctPrint)   // bps == 0 or no distinct print: passes
///                 && (stockToken == 0 || oraclePaused() returned a 32-byte zero word)
///                 && (quoteFeed == 0 || (quotePrice != 0 && quote fresh))
contract ChainlinkEquityAdapterTest is Test {
    uint256 constant EDT = 4 hours;
    uint256 constant MAX_STALENESS = 2 days;
    uint256 constant PLAUSIBILITY_BPS = 2000; // 20%
    uint80 constant PHASE_1_FIRST_ROUND = (uint80(1) << 64) | 1;

    MockAggregatorV3 stock;
    MockAggregatorV3 quoteFeed;
    MockPausableStock token;
    IMarketStateAdapter adapter;

    uint256 friNoon; // Fri Sep 4 2026 12:00 ET, regular hours
    uint256 sunReopen; // Sun Sep 6 2026 20:00 ET

    function setUp() public {
        friNoon = et(2026, 9, 4, 12, 0);
        sunReopen = et(2026, 9, 6, 20, 0);
        vm.warp(friNoon);

        stock = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        quoteFeed = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        token = new MockPausableStock();

        // Two prints this morning: 99.50 at 09:35, 100.00 at 11:00.
        stock.push(99_50000000, et(2026, 9, 4, 9, 35));
        stock.push(100_00000000, et(2026, 9, 4, 11, 0));
        quoteFeed.push(1_00000000, et(2026, 9, 4, 11, 0));

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
        return new ChainlinkEquityAdapter(stockFeed, quote_, stockToken, maxStaleness, bps);
    }

    function state() internal view returns (MarketState memory) {
        return adapter.getMarketState();
    }

    function freshFeed(int256 answer) internal returns (MockAggregatorV3 f) {
        f = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        f.push(answer, block.timestamp - 60);
    }

    /// A raw-bytes feed that starts out well-formed so the constructor's dry read passes.
    function goodRaw() internal returns (MockRawReturner raw) {
        raw = new MockRawReturner();
        raw.set(AggregatorV3Interface.decimals.selector, abi.encode(uint256(8)));
        raw.set(
            AggregatorV3Interface.latestRoundData.selector,
            abi.encode(
                uint256(PHASE_1_FIRST_ROUND) + 1,
                int256(100_00000000),
                block.timestamp - 60,
                block.timestamp - 60,
                uint256(PHASE_1_FIRST_ROUND) + 1
            )
        );
        raw.set(
            AggregatorV3Interface.getRoundData.selector,
            abi.encode(
                uint256(PHASE_1_FIRST_ROUND),
                int256(99_00000000),
                block.timestamp - 3600,
                block.timestamp - 3600,
                uint256(PHASE_1_FIRST_ROUND)
            )
        );
        raw.set(IOraclePausable.oraclePaused.selector, abi.encode(uint256(0)));
    }

    // ── constructor ─────────────────────────────────────────────────────────

    function test_constructor_rejectsBadConfig() public {
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(0), address(0), address(0), MAX_STALENESS, 0);
        // B1: maxStaleness is a dead-feed net and must sit above the 86400s heartbeat.
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(0), address(0), 1 days, 0);
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(0), address(0), MAX_STALENESS, 10_001);
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(stock), address(0), MAX_STALENESS, 0);
    }

    function test_constructor_dryReadsEveryAddress() public {
        // Anything unreadable at deployment would pin the pool at the closed floor forever.
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(0xdead), address(0), address(0), MAX_STALENESS, 0);
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(0xdead), address(0), MAX_STALENESS, 0);
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(0), address(0xdead), MAX_STALENESS, 0);
        stock.setRevertDecimals(true);
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(0), address(0), MAX_STALENESS, 0);
        stock.setRevertDecimals(false);
        token.setReverting(true);
        vm.expectRevert(ChainlinkEquityAdapter.InvalidConfig.selector);
        deploy(address(stock), address(0), address(token), MAX_STALENESS, 0);
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
        assertEq(m.loPrice, 995e17, "window low");
        assertEq(m.hiPrice, 100e18, "window high");
        assertEq(m.updatedAt, et(2026, 9, 4, 11, 0), "latest round's updatedAt");
        assertFalse(m.hasQuoteFeed);
        assertEq(m.quotePrice, 0);
        assertEq(m.loQuotePrice, 0);
        assertEq(m.hiQuotePrice, 0);
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
        assertEq(
            deploy(address(f18), address(0), address(0), MAX_STALENESS, 0).getMarketState().price,
            100e18,
            "18-dec passthrough"
        );

        MockAggregatorV3 f20 = new MockAggregatorV3(20, PHASE_1_FIRST_ROUND);
        f20.push(int256(100e20), block.timestamp - 60);
        assertEq(
            deploy(address(f20), address(0), address(0), MAX_STALENESS, 0).getMarketState().price,
            100e18,
            "20-dec divides down"
        );

        MockAggregatorV3 f0 = new MockAggregatorV3(0, PHASE_1_FIRST_ROUND);
        f0.push(100, block.timestamp - 60);
        assertEq(deploy(address(f0), address(0), address(0), MAX_STALENESS, 0).getMarketState().price, 100e18, "0-dec");
    }

    // ── the window ──────────────────────────────────────────────────────────

    function test_window_reprintsDoNotWidenIt() public {
        stock.push(100_00000000, block.timestamp - 3000);
        stock.push(100_00000000, block.timestamp - 60);
        MarketState memory m = state();
        assertEq(m.price, 100e18);
        assertEq(m.loPrice, 995e17);
        assertEq(m.hiPrice, 100e18);
    }

    function test_window_spansReopenAndRetrace() public {
        // Fri 19:00: 100.50. Dark 49h. Sun 20:05: 103. Sun 20:30: 102 (retrace). The window holds
        // every print the pool could have tracked, so the hook charges the retrace either way (B9).
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        stock.push(103_00000000, sunReopen + 5 minutes);
        stock.push(102_00000000, sunReopen + 30 minutes);
        vm.warp(sunReopen + 31 minutes);
        MarketState memory m = state();
        assertEq(m.price, 102e18);
        assertEq(m.loPrice, 995e17, "oldest print within LOOKBACK");
        assertEq(m.hiPrice, 103e18, "the reopen print");
        assertTrue(m.isLive, "retrace is within 20% of the previous distinct print");
    }

    function test_window_isTheLastSixRoundsPlusLatest() public {
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        for (uint256 i = 1; i <= 7; i++) {
            stock.push(int256(103_00000000 + i * 10000000), sunReopen + i * 5 minutes);
        }
        vm.warp(sunReopen + 40 minutes);
        MarketState memory m = state();
        assertEq(m.price, 1037e17);
        assertEq(m.loPrice, 1031e17, "seven rounds back has scrolled out");
        assertEq(m.hiPrice, 1037e17);
    }

    function test_window_noHistory_isZero() public {
        MockAggregatorV3 fresh = freshFeed(100_00000000);
        MarketState memory m = deploy(address(fresh), address(0), address(0), MAX_STALENESS, 0).getMarketState();
        assertEq(m.price, 100e18);
        assertEq(m.loPrice, 0, "unknown history -> 0 -> the hook charges");
        assertEq(m.hiPrice, 0);
        assertTrue(m.isLive, "unknown history does not make the feed dead");
    }

    function test_window_historyRevert_isZero_andDoesNotBlock() public {
        stock.setRevertHistory(true);
        MarketState memory m = state();
        assertEq(m.price, 100e18, "latest still readable");
        assertEq(m.loPrice, 0);
        assertEq(m.hiPrice, 0);
        assertTrue(m.isLive);
    }

    function test_window_allReprints_reportsNoMove() public {
        MockAggregatorV3 flat = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        for (uint256 i = 0; i < 8; i++) {
            flat.push(100_00000000, block.timestamp - 8 hours + i * 1 hours);
        }
        MarketState memory m = deploy(address(flat), address(0), address(0), MAX_STALENESS, 0).getMarketState();
        assertEq(m.loPrice, 100e18);
        assertEq(m.hiPrice, 100e18, "lo == hi == price: the reference has not moved");
    }

    function test_window_skipsNonPositiveHistory() public {
        stock.push(0, block.timestamp - 1800);
        stock.push(101_00000000, block.timestamp - 60);
        MarketState memory m = state();
        assertEq(m.loPrice, 995e17, "a zero round is skipped, not a stop");
        assertEq(m.hiPrice, 101e18);
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
        stock.push(100_50000000, et(2026, 9, 4, 19, 0));
        vm.warp(et(2026, 9, 5, 12, 0));
        MarketState memory m = state();
        assertTrue(m.isLive);
        assertEq(uint8(m.session), uint8(Session.Closed));
    }

    // ── liveness: plausibility ──────────────────────────────────────────────

    function test_plausibility_bigJumpIsNotLive_butPriceIsReported() public {
        stock.push(130_00000000, block.timestamp - 60); // +30% vs the last distinct print (100)
        MarketState memory m = state();
        assertFalse(m.isLive, "implausible print");
        assertEq(m.price, 130e18);
    }

    function test_plausibility_withinBound_isLive() public {
        stock.push(119_00000000, block.timestamp - 60);
        assertTrue(state().isLive);
        stock.push(120_00000000, block.timestamp - 30); // vs 119: +0.84%
        assertTrue(state().isLive);
    }

    function test_plausibility_exactBoundInclusive() public {
        stock.push(120_00000000, block.timestamp - 60);
        assertTrue(state().isLive, "<= bound is plausible");
    }

    function test_plausibility_comparesToTheLastDistinctPrint_notTheWindowLow() public {
        // 90, 100, 100, 118: +18% vs the last distinct print (live) but +31% vs the window low.
        MockAggregatorV3 f = new MockAggregatorV3(8, PHASE_1_FIRST_ROUND);
        f.push(90_00000000, block.timestamp - 4 hours);
        f.push(100_00000000, block.timestamp - 3 hours);
        f.push(100_00000000, block.timestamp - 2 hours);
        f.push(118_00000000, block.timestamp - 60);
        MarketState memory m =
            deploy(address(f), address(0), address(0), MAX_STALENESS, PLAUSIBILITY_BPS).getMarketState();
        assertTrue(m.isLive, "a large reopen gap does not wedge the feed for the whole window");
        assertEq(m.loPrice, 90e18, "the window itself still reaches back");
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
        assertEq(m.loPrice, 0);
        assertEq(m.updatedAt, 0);
    }

    function test_feedCodeRemoved_returnsDeadState() public {
        MockAggregatorV3 f = freshFeed(100_00000000);
        IMarketStateAdapter a = deploy(address(f), address(0), address(0), MAX_STALENESS, 0);
        vm.etch(address(f), "");
        MarketState memory m = a.getMarketState();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
    }

    function test_nonPositiveAnswer_returnsDeadState() public {
        stock.setLatest(0, block.timestamp - 60);
        assertEq(state().price, 0);
        assertFalse(state().isLive);
        stock.setLatest(-1, block.timestamp - 60);
        assertEq(state().price, 0);
        assertFalse(state().isLive);
    }

    function test_decimalsRevert_returnsDeadState() public {
        stock.setRevertDecimals(true);
        MarketState memory m = state();
        assertFalse(m.isLive);
        assertEq(m.price, 0);
    }

    function test_malformedReturnData_neverReverts() public {
        // R4 M-1: try/catch does not catch decoding failures. Each case used to revert the adapter.
        MockRawReturner raw = goodRaw();
        IMarketStateAdapter a = deploy(address(raw), address(0), address(raw), MAX_STALENESS, PLAUSIBILITY_BPS);
        assertTrue(a.getMarketState().isLive, "well-formed baseline");

        raw.set(AggregatorV3Interface.decimals.selector, abi.encode(uint256(256)));
        assertEq(a.getMarketState().price, 0, "decimals word > 255: dead");
        raw.set(AggregatorV3Interface.decimals.selector, hex"01");
        assertEq(a.getMarketState().price, 0, "decimals short: dead");
        raw.set(AggregatorV3Interface.decimals.selector, "");
        assertEq(a.getMarketState().price, 0, "decimals empty: dead");
        raw.set(AggregatorV3Interface.decimals.selector, abi.encode(uint256(8)));

        raw.set(
            AggregatorV3Interface.latestRoundData.selector,
            abi.encode(uint256(1), int256(100e8), uint256(1), uint256(1))
        );
        assertEq(a.getMarketState().price, 0, "four words: dead");
        raw.set(
            AggregatorV3Interface.latestRoundData.selector,
            abi.encode(uint256(1) << 100, int256(100e8), block.timestamp, block.timestamp, uint256(1))
        );
        assertEq(a.getMarketState().price, 0, "roundId beyond uint80: dead");
        raw.set(
            AggregatorV3Interface.latestRoundData.selector,
            abi.encode(
                uint256(PHASE_1_FIRST_ROUND) + 1,
                int256(100_00000000),
                block.timestamp - 60,
                block.timestamp - 60,
                uint256(PHASE_1_FIRST_ROUND) + 1
            )
        );

        raw.set(AggregatorV3Interface.getRoundData.selector, hex"deadbeef");
        MarketState memory m = a.getMarketState();
        assertEq(m.price, 100e18);
        assertEq(m.loPrice, 0, "history short: unknown window");
        assertTrue(m.isLive);

        raw.set(IOraclePausable.oraclePaused.selector, abi.encode(uint256(2)));
        assertFalse(a.getMarketState().isLive, "bool word 2: paused");
        raw.set(IOraclePausable.oraclePaused.selector, "");
        assertFalse(a.getMarketState().isLive, "empty bool: paused");
        raw.set(IOraclePausable.oraclePaused.selector, abi.encode(uint256(0)));
        assertTrue(a.getMarketState().isLive);
    }

    function testFuzz_neverReverts(int256 answer, uint256 updatedAt, uint8 decimals_, uint80 firstRound) public {
        decimals_ = uint8(bound(decimals_, 0, 60));
        firstRound = uint80(bound(firstRound, 1, type(uint80).max - 2));
        MockAggregatorV3 f = new MockAggregatorV3(decimals_, firstRound);
        f.push(answer, updatedAt);
        f.push(answer, updatedAt);
        MockAggregatorV3 q = new MockAggregatorV3(decimals_, firstRound);
        q.push(answer, updatedAt);
        IMarketStateAdapter a = deploy(address(f), address(q), address(token), MAX_STALENESS, PLAUSIBILITY_BPS);
        a.getMarketState(); // any revert here fails the test: the adapter must be total
    }

    function testFuzz_neverReverts_rawBytes(
        bytes memory dec,
        bytes memory latest,
        bytes memory hist,
        bytes memory paused
    ) public {
        MockRawReturner raw = goodRaw();
        IMarketStateAdapter a = deploy(address(raw), address(0), address(raw), MAX_STALENESS, PLAUSIBILITY_BPS);
        raw.set(AggregatorV3Interface.decimals.selector, dec);
        raw.set(AggregatorV3Interface.latestRoundData.selector, latest);
        raw.set(AggregatorV3Interface.getRoundData.selector, hist);
        raw.set(IOraclePausable.oraclePaused.selector, paused);
        a.getMarketState();
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
        assertEq(m.loQuotePrice, 1e18, "quote window low (setUp print of 1.00)");
        assertEq(m.hiQuotePrice, 770e18, "quote window high");
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
        IMarketStateAdapter a = deploy(address(stock), address(quoteFeed), address(0), MAX_STALENESS, 0);
        quoteFeed.setRevertLatest(true);
        MarketState memory m = a.getMarketState();
        assertFalse(m.isLive);
        assertEq(m.quotePrice, 0);
        assertEq(m.loQuotePrice, 0);
        assertEq(m.price, 100e18, "stock leg unaffected");
    }

    function test_quoteFeed_plausibilityAppliesToStockLegOnly() public {
        quoteFeed.push(1_30000000, block.timestamp - 60); // +30% on the quote leg
        IMarketStateAdapter a = deploy(address(stock), address(quoteFeed), address(0), MAX_STALENESS, PLAUSIBILITY_BPS);
        assertTrue(a.getMarketState().isLive);
    }

    // ── gas ─────────────────────────────────────────────────────────────────

    function test_gas_getMarketState_dollarQuote() public {
        stock.push(100_50000000, block.timestamp - 60);
        uint256 g = gasleft();
        adapter.getMarketState();
        uint256 used = g - gasleft();
        emit log_named_uint("getMarketState gas (dollar quote)", used);
        // Seven cold reads, hand-decoded. Raw staticcall + manual decode costs ~8k over try/catch;
        // that is the price of the adapter never reverting on malformed return data (R4 M-1).
        assertLt(used, 70_000);
    }
}
