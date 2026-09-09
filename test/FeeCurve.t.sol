// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../src/FeeCurve.sol";
import {Session} from "../src/IMarketStateAdapter.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// Executable spec for FeeCurve. Units: fees in pips (1e-6); multipliers in 1e18; deviations are
/// SIGNED 1e18 ((pool − ref) / ref). Slopes are plain "multiplier-units per input-unit":
///   stalenessMult = 1e18 + secondsSinceClose * stalenessSlope
///   deviationMult = 1e18 + |dev| * devSlope1            (|dev| <= devKink)
///                 = f(devKink) + (|dev| - devKink) * devSlope2
///
/// The hook composes them as:
///   refMoved  = referenceMoved(poolPrice, ref, lo, hi)             // stateless, from feed history
///   restoring = isRestoring(preDev, postDev, refMoved)             // false whenever refMoved
///   devM      = deviationMult(p, |preDev|, |postDev|, restoring)   // charged on the larger endpoint
///   fee       = computeFee(p, floorFor(p, s, isLive), stalenessMult(p, s, lastClose, now), devM)
/// No time decay (B4): the gap closing is the decay.
contract FeeCurveTest is Test {
    uint256 constant ONE = 1e18;
    int256 constant PCT = 1e16; // 1% in signed 1e18
    uint256 constant UPCT = 1e16;

    FeeCurve.Params P;

    function setUp() public {
        P = FeeCurve.Params({
            baseFee: 500, // 5 bps
            elevatedFloor: 800, // 8 bps
            closedFloor: 3000, // 30 bps
            feeCap: 40_000, // 400 bps
            stalenessSlope: 10_684_000_000_000, // reaches 3x at 52h (187_200s): 2e18 / 187_200
            stalenessMax: 3e18,
            devKink: 5e15, // 0.5%
            devSlope1: 100, // +1.0x per 1% below the kink  (0.01e18 * 100 = 1e18)
            devSlope2: 200 // +2.0x per 1% above the kink
        });
    }

    // ── validate ────────────────────────────────────────────────────────────────

    function test_validate_fixtureIsValid() public view {
        assertTrue(FeeCurve.validate(P));
    }

    function test_validate_rejectsEachBrokenInvariant() public view {
        FeeCurve.Params memory q;
        q = P;
        q.baseFee = 900;
        assertFalse(FeeCurve.validate(q), "base > elevated");
        q = P;
        q.elevatedFloor = 3500;
        assertFalse(FeeCurve.validate(q), "elevated > closed");
        q = P;
        q.closedFloor = 50_000;
        assertFalse(FeeCurve.validate(q), "closed > cap");
        q = P;
        q.feeCap = 1_000_001;
        assertFalse(FeeCurve.validate(q), "cap > MAX_LP_FEE");
        q = P;
        q.feeCap = LPFeeLibrary.MAX_LP_FEE;
        assertFalse(FeeCurve.validate(q), "cap at 100% blocks exact-output swaps in v4");
        q = P;
        q.stalenessMax = 5e17;
        assertFalse(FeeCurve.validate(q), "stalenessMax < 1");
        q = P;
        q.baseFee = 0;
        assertTrue(FeeCurve.validate(q), "zero base is allowed");
        q = P;
        q.feeCap = LPFeeLibrary.MAX_LP_FEE - 1;
        assertTrue(FeeCurve.validate(q), "cap just under 100% is allowed");
    }

    // ── floorFor ────────────────────────────────────────────────────────────────

    function test_floorFor() public view {
        assertEq(FeeCurve.floorFor(P, Session.Regular, true), 500, "Regular live -> base");
        assertEq(FeeCurve.floorFor(P, Session.Extended, true), 800, "Extended -> elevated");
        assertEq(FeeCurve.floorFor(P, Session.Overnight, true), 800, "Overnight -> elevated");
        assertEq(FeeCurve.floorFor(P, Session.Closed, true), 3000, "Closed -> closed");
        assertEq(FeeCurve.floorFor(P, Session.Closed, false), 3000, "Closed !live -> closed");
    }

    function test_floorFor_deadFeedOverridesSession() public view {
        // B1: !isLive is a dead-feed safety net, so it wins in every session.
        assertEq(FeeCurve.floorFor(P, Session.Regular, false), 3000, "Regular !live -> closed");
        assertEq(FeeCurve.floorFor(P, Session.Extended, false), 3000, "Extended !live -> closed");
        assertEq(FeeCurve.floorFor(P, Session.Overnight, false), 3000, "Overnight !live -> closed");
    }

    function test_floorFor_zeroValueSessionIsClosed() public view {
        // #11: a zeroed MarketState must read as the fail-safe regime.
        assertEq(uint8(Session.Closed), 0, "Closed is the enum zero value");
        assertEq(FeeCurve.floorFor(P, Session(0), true), 3000);
    }

    // ── stalenessMult ───────────────────────────────────────────────────────────

    function test_stalenessMult_oneWhenOpen() public view {
        uint256 lc = 1_000_000;
        assertEq(FeeCurve.stalenessMult(P, Session.Regular, lc, lc + 1 days), ONE, "Regular");
        assertEq(FeeCurve.stalenessMult(P, Session.Extended, lc, lc + 1 days), ONE, "Extended");
        assertEq(FeeCurve.stalenessMult(P, Session.Overnight, lc, lc + 1 days), ONE, "Overnight");
    }

    function test_stalenessMult_rampsFromClose() public view {
        uint256 lc = 1_000_000;
        assertEq(FeeCurve.stalenessMult(P, Session.Closed, lc, lc), ONE, "at close");
        assertEq(FeeCurve.stalenessMult(P, Session.Closed, lc, lc + 3600), ONE + 3600 * P.stalenessSlope, "1h in");
        uint256 at52h = FeeCurve.stalenessMult(P, Session.Closed, lc, lc + 187_200);
        assertApproxEqAbs(at52h, 3e18, 1e12, "52h ~ 3x");
    }

    function test_stalenessMult_capped() public view {
        uint256 lc = 1_000_000;
        assertEq(FeeCurve.stalenessMult(P, Session.Closed, lc, lc + 72 hours), P.stalenessMax, "Labor Day 72h capped");
        assertEq(FeeCurve.stalenessMult(P, Session.Closed, lc, lc + 365 days), P.stalenessMax, "1y capped");
    }

    function testFuzz_stalenessMult_bounds(uint256 lc, uint256 dt) public view {
        lc = bound(lc, 0, type(uint128).max);
        dt = bound(dt, 0, type(uint64).max);
        uint256 m = FeeCurve.stalenessMult(P, Session.Closed, lc, lc + dt);
        assertGe(m, ONE, ">= 1");
        assertLe(m, P.stalenessMax, "<= max");
    }

    function testFuzz_stalenessMult_monotone(uint256 lc, uint256 a, uint256 b) public view {
        lc = bound(lc, 0, type(uint128).max);
        a = bound(a, 0, type(uint64).max);
        b = bound(b, a, type(uint64).max);
        assertLe(
            FeeCurve.stalenessMult(P, Session.Closed, lc, lc + a),
            FeeCurve.stalenessMult(P, Session.Closed, lc, lc + b),
            "non-decreasing in time"
        );
    }

    // ── referenceMoved (stateless F1 producer, B4/B6/B9) ──────────────────────
    // referenceMoved(pool, ref, lo, hi): lo/hi = the feed's recent window (current print included).
    // Band = [2*lo - ref, 2*hi - ref]: the union of "within the move of print p" over every p.

    function test_referenceMoved_poolBetweenThePrints() public pure {
        // 100 -> 103; pool anywhere from the old print to the new one is still following.
        assertTrue(FeeCurve.referenceMoved(100e18, 103e18, 100e18, 103e18), "still at the old print");
        assertTrue(FeeCurve.referenceMoved(1016e17, 103e18, 100e18, 103e18), "past the midpoint: STILL moved (B6)");
        assertTrue(FeeCurve.referenceMoved(1029e17, 103e18, 100e18, 103e18), "almost there: still moved");
        assertTrue(
            FeeCurve.referenceMoved(103e18, 103e18, 100e18, 103e18), "landed exactly on the new print (inclusive)"
        );
        assertTrue(FeeCurve.referenceMoved(1015e17, 100e18, 100e18, 103e18), "same band, downward move");
    }

    function test_referenceMoved_poolOutsideTheBand_isPoolCreated() public pure {
        // 100 -> 100.6: band [99.4, 100.6]. A pool at 95 or 105 drifted there on its own.
        assertFalse(FeeCurve.referenceMoved(95e18, 1006e17, 100e18, 1006e17), "far below both prints");
        assertFalse(FeeCurve.referenceMoved(105e18, 1006e17, 100e18, 1006e17), "far above both prints");
        assertFalse(FeeCurve.referenceMoved(104e18, 103e18, 100e18, 103e18), "overshot the new print beyond the band");
    }

    function test_referenceMoved_noMove() public pure {
        assertFalse(FeeCurve.referenceMoved(90e18, 100e18, 100e18, 100e18), "reference did not move: pool-created gap");
    }

    function test_referenceMoved_unknownHistoryChargesByDefault() public pure {
        assertTrue(FeeCurve.referenceMoved(100e18, 103e18, 0, 0));
        assertTrue(FeeCurve.referenceMoved(100e18, 100e18, 0, 0));
        assertTrue(FeeCurve.referenceMoved(100e18, 100e18, 0, 100e18));
    }

    function test_referenceMoved_pastTheOldPrint_isStillMoved() public pure {
        // Round 3 H1: a pool nudged a wei below the old print before the close must not read as a
        // pool-created gap when the reference then gaps up.
        assertTrue(FeeCurve.referenceMoved(999998e14, 103e18, 100e18, 103e18), "a hair below prev, ref moved up");
        assertTrue(FeeCurve.referenceMoved(1000002e14, 97e18, 97e18, 100e18), "a hair above prev, ref moved down");
        assertTrue(FeeCurve.referenceMoved(97e18, 103e18, 100e18, 103e18), "mirror edge: gap == move (inclusive)");
        assertFalse(
            FeeCurve.referenceMoved(969999e14, 103e18, 100e18, 103e18), "just past the mirror edge: pool-created"
        );
        assertFalse(FeeCurve.referenceMoved(96e18, 103e18, 100e18, 103e18), "escaping needs a pre-paid gap > the move");
        assertTrue(
            FeeCurve.referenceMoved(96e18, 104e18, 100e18, 104e18),
            "guessed the wrong direction: charged on the whole gap"
        );
    }

    function test_referenceMoved_trendOfPrints_untrackedPool() public pure {
        // Round 4 High: 100 -> 100.3 -> 100.6 -> 100.9 with the pool still at 100. Anchoring on the
        // last print alone (band [100.3, 100.9]) would exempt the arb; the window keeps 100 in reach.
        assertTrue(FeeCurve.referenceMoved(100e18, 1009e17, 100e18, 1009e17));
        assertTrue(FeeCurve.referenceMoved(1003e17, 1009e17, 100e18, 1009e17));
        assertFalse(FeeCurve.referenceMoved(99e18, 1009e17, 100e18, 1009e17), "below the window's reach: pool-created");
    }

    function test_referenceMoved_trackedReopen_thenRetrace() public pure {
        // Round 4: 100 (Fri) -> 103 (reopen) -> 102 (retrace). Pool tracked 103. Band [98, 104].
        assertTrue(
            FeeCurve.referenceMoved(103e18, 102e18, 100e18, 103e18), "pool at the reopen print: retrace is a move"
        );
        assertTrue(FeeCurve.referenceMoved(100e18, 102e18, 100e18, 103e18), "pool never tracked: still a move");
        assertFalse(FeeCurve.referenceMoved(105e18, 102e18, 100e18, 103e18), "pool drifted past the window on its own");
        // Full retrace to the pre-close print: ref == lo, band [100, 106]. Pool at 103 -> moved.
        assertTrue(FeeCurve.referenceMoved(103e18, 100e18, 100e18, 103e18));
    }

    function test_referenceMoved_isNotAttackerRefreshable() public pure {
        // A dust swap cannot change feed history, and moving the pool anywhere inside the band
        // keeps refMoved true. There is no position a trader can put the pool in, short of
        // finishing the arbitrage, that earns the exemption.
        assertTrue(FeeCurve.referenceMoved(1005e17, 103e18, 100e18, 103e18));
        assertTrue(FeeCurve.referenceMoved(1025e17, 103e18, 100e18, 103e18));
    }

    function testFuzz_referenceMoved_bandProperties(uint256 pool, uint256 ref, uint256 lo, uint256 hi) public pure {
        pool = bound(pool, 1, 1e30);
        ref = bound(ref, 1, 1e30);
        lo = bound(lo, 1, 1e30);
        hi = bound(hi, lo, 1e30);
        // A window that is just the current print never reads as a move.
        assertFalse(FeeCurve.referenceMoved(pool, ref, ref, ref));
        // Anywhere between the window and the current print (inclusive) is "moved".
        uint256 l = lo < ref ? lo : ref;
        uint256 h = hi > ref ? hi : ref;
        if (!(lo == hi && lo == ref) && pool >= l && pool <= h) {
            assertTrue(FeeCurve.referenceMoved(pool, ref, lo, hi), "between window and ref: moved");
        }
        // Exact band: [2l - ref, 2h - ref].
        bool inBand = pool + ref >= 2 * l && pool + ref <= 2 * h;
        if (!(lo == hi && lo == ref)) {
            assertEq(FeeCurve.referenceMoved(pool, ref, lo, hi), inBand, "band formula");
        }
        // Widening the window never turns the flag off.
        if (FeeCurve.referenceMoved(pool, ref, lo, hi) && lo > 1) {
            assertTrue(FeeCurve.referenceMoved(pool, ref, lo - 1, hi + 1), "wider window: still moved");
        }
    }

    // ── isRestoring (F1, signed) ────────────────────────────────────────────────

    function test_isRestoring_poolCreatedDeviation() public pure {
        assertTrue(FeeCurve.isRestoring(-1 * PCT, -PCT / 2, false), "below ref, closing: restoring");
        assertTrue(FeeCurve.isRestoring(1 * PCT, PCT / 2, false), "above ref, closing: restoring");
        assertTrue(FeeCurve.isRestoring(-1 * PCT, 0, false), "closing exactly");
        assertFalse(FeeCurve.isRestoring(-1 * PCT, -3 * PCT / 2, false), "widening");
        assertFalse(FeeCurve.isRestoring(-1 * PCT, -1 * PCT, false), "unchanged is not restoring");
        assertFalse(FeeCurve.isRestoring(0, 0, false), "no gap, no movement");
    }

    function test_isRestoring_crossingIsAdverse() public pure {
        // Pool 1% below; swap ends 0.5% ABOVE. Smaller |dev| but crossed the reference: adverse.
        assertFalse(FeeCurve.isRestoring(-1 * PCT, PCT / 2, false), "cross to smaller |dev|");
        assertFalse(FeeCurve.isRestoring(-1 * PCT, 12 * PCT / 10, false), "cross to larger |dev|");
        assertFalse(FeeCurve.isRestoring(1 * PCT, -PCT / 10, false), "cross downward");
    }

    function test_isRestoring_referenceMovedNeverRestoring() public pure {
        assertFalse(FeeCurve.isRestoring(-1 * PCT, -PCT / 2, true), "F1: reference-created gap");
        assertFalse(FeeCurve.isRestoring(-1 * PCT, 0, true), "even closing it exactly");
    }

    function testFuzz_isRestoring_F1(int256 pre, int256 post) public pure {
        pre = bound(pre, -1e30, 1e30);
        post = bound(post, -1e30, 1e30);
        assertFalse(FeeCurve.isRestoring(pre, post, true), "refMoved => never restoring");
        if (!FeeCurve.isRestoring(pre, post, false)) return;
        // Restoring => same side (or landed exactly on ref) and strictly smaller |dev|.
        assertTrue(post == 0 || (pre > 0) == (post > 0), "same side of the reference");
        assertLt(FeeCurve.abs(post), FeeCurve.abs(pre), "strictly shrinks");
    }

    // ── deviationMult ───────────────────────────────────────────────────────────

    function test_deviationMult_chargesLargerEndpoint() public view {
        // H1: an adverse swap that lands exactly on the reference is charged for the gap it took.
        assertEq(FeeCurve.deviationMult(P, 3 * UPCT, 0, false), 65e17, "3% -> 0: pays f(3%)");
        assertEq(FeeCurve.deviationMult(P, 3 * UPCT, 1 * UPCT, false), 65e17, "3% -> 1%: pays f(3%)");
        assertEq(FeeCurve.deviationMult(P, 1 * UPCT, 3 * UPCT, false), 65e17, "1% -> 3% (widening): pays f(3%)");
        assertEq(FeeCurve.deviationMult(P, 0, 0, false), ONE, "no gap either side");
    }

    function test_deviationMult_restoringIsOne() public view {
        assertEq(FeeCurve.deviationMult(P, 0, 5 * UPCT, true), ONE, "restoring ignores deviation");
        assertEq(FeeCurve.deviationMult(P, 0, 0, true), ONE);
    }

    function test_deviationMult_piecewiseLinear() public view {
        assertEq(FeeCurve.deviationMult(P, 0, 0, false), ONE, "f(0) = 1");
        assertEq(FeeCurve.deviationMult(P, 0, UPCT / 4, false), 125e16, "0.25% below kink -> 1.25x");
        assertEq(FeeCurve.deviationMult(P, 0, P.devKink, false), 15e17, "at kink 0.5% -> 1.5x");
        assertEq(FeeCurve.deviationMult(P, 0, 1 * UPCT, false), 25e17, "1% -> 2.5x");
        assertEq(FeeCurve.deviationMult(P, 0, 3 * UPCT, false), 65e17, "3% -> 6.5x");
    }

    function test_deviationMult_continuousAtKink() public view {
        uint256 below = FeeCurve.deviationMult(P, 0, P.devKink - 1, false);
        uint256 at = FeeCurve.deviationMult(P, 0, P.devKink, false);
        uint256 above = FeeCurve.deviationMult(P, 0, P.devKink + 1, false);
        assertLe(at - below, P.devSlope1 + 1, "no jump from below");
        assertLe(above - at, P.devSlope2 + 1, "no jump from above");
    }

    function testFuzz_deviationMult_monotone(uint256 a, uint256 b) public view {
        a = bound(a, 0, 1e18);
        b = bound(b, a, 1e18);
        assertLe(
            FeeCurve.deviationMult(P, 0, a, false), FeeCurve.deviationMult(P, 0, b, false), "non-decreasing in |dev|"
        );
    }

    function testFuzz_deviationMult_atLeastOne(uint256 dev, bool restoring) public view {
        assertGe(FeeCurve.deviationMult(P, 0, dev, restoring), ONE);
    }

    /// Never reverts on any deviation the hook could compute — blocking a swap is the one failure
    /// this design must not have. Slopes and kink fuzzed too.
    function testFuzz_deviationMult_neverReverts(uint256 dev, uint64 s1, uint64 s2, uint64 kink) public view {
        FeeCurve.Params memory q = P;
        q.devSlope1 = s1;
        q.devSlope2 = s2;
        q.devKink = kink;
        uint256 m = FeeCurve.deviationMult(q, 0, dev, false);
        assertGe(m, ONE);
        FeeCurve.computeFee(q, q.closedFloor, P.stalenessMax, m);
    }

    // ── computeFee ──────────────────────────────────────────────────────────────

    function test_computeFee_quietTuesdayIsExactlyBase() public view {
        assertEq(FeeCurve.computeFee(P, 500, ONE, ONE), 500, "Regular, live, zero deviation -> base");
    }

    function test_computeFee_stacks() public view {
        assertEq(FeeCurve.computeFee(P, 3000, 2e18, 25e17), 15_000, "30bps x 2 x 2.5 = 150bps");
        assertEq(FeeCurve.computeFee(P, 800, ONE, 2e18), 1600, "elevated x 2 = 16bps");
    }

    function test_computeFee_roundsToNearest() public view {
        assertEq(FeeCurve.computeFee(P, 500, ONE + 1, ONE), 500, "a wei of multiplier does not add a pip");
        assertEq(FeeCurve.computeFee(P, 500, ONE + ONE / 1000, ONE), 501, "500.5 -> 501 (half rounds up)");
        assertEq(FeeCurve.computeFee(P, 500, ONE + ONE / 1001, ONE), 500, "500.4995 -> 500");
        assertEq(FeeCurve.computeFee(P, 999, 1_001_000_000_000_000_000, ONE), 1000, "999.999 -> 1000");
    }

    function test_computeFee_singleCap() public view {
        assertEq(FeeCurve.computeFee(P, 3000, 3e18, 5e18), 40_000, "45000 -> capped 400bps");
        assertEq(FeeCurve.computeFee(P, 3000, 3e18, 65e17), 40_000, "earnings gap -> capped");
    }

    function testFuzz_computeFee_neverExceedsCap(uint24 floorFee, uint256 s, uint256 d) public view {
        floorFee = uint24(bound(floorFee, 0, P.feeCap));
        s = bound(s, ONE, P.stalenessMax);
        d = bound(d, ONE, 100e18);
        assertLe(FeeCurve.computeFee(P, floorFee, s, d), P.feeCap, "fee <= feeCap");
    }

    function testFuzz_computeFee_neverBelowFloor(uint24 floorFee, uint256 s, uint256 d) public view {
        floorFee = uint24(bound(floorFee, 0, P.feeCap));
        s = bound(s, ONE, P.stalenessMax);
        d = bound(d, ONE, 100e18);
        assertGe(FeeCurve.computeFee(P, floorFee, s, d), floorFee, "fee >= floor");
    }

    /// Non-vacuous: fuzz Params too, including a feeCap ABOVE MAX_LP_FEE (a misconfiguration the
    /// constructor rejects) — computeFee must still never emit a fee the PoolManager reverts on.
    function testFuzz_computeFee_validLPFee(uint24 floorFee, uint24 cap, uint256 s, uint256 d) public view {
        FeeCurve.Params memory q = P;
        q.feeCap = cap;
        s = bound(s, ONE, 100e18);
        d = bound(d, ONE, 100e18);
        uint24 fee = FeeCurve.computeFee(q, floorFee, s, d);
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "fee <= MAX_LP_FEE even when feeCap is misconfigured");
        assertLe(fee, q.feeCap, "fee <= feeCap");
        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG == 0, "flag bit never set by the curve");
    }

    /// Invariants hold over the whole VALID Params space, not just the fixture.
    function testFuzz_computeFee_invariants_overParams(
        uint24 base,
        uint24 elev,
        uint24 closed,
        uint24 cap,
        uint256 s,
        uint256 d,
        uint8 which
    ) public pure {
        cap = uint24(bound(cap, 1, LPFeeLibrary.MAX_LP_FEE));
        closed = uint24(bound(closed, 0, cap));
        elev = uint24(bound(elev, 0, closed));
        base = uint24(bound(base, 0, elev));
        FeeCurve.Params memory q;
        q.baseFee = base;
        q.elevatedFloor = elev;
        q.closedFloor = closed;
        q.feeCap = cap;
        q.stalenessMax = 3e18;
        uint24 floorFee = which % 3 == 0 ? base : which % 3 == 1 ? elev : closed;
        s = bound(s, ONE, q.stalenessMax);
        d = bound(d, ONE, 100e18);
        uint24 fee = FeeCurve.computeFee(q, floorFee, s, d);
        assertGe(fee, floorFee, "fee >= floor");
        assertLe(fee, cap, "fee <= cap");
    }

    // ── edges ───────────────────────────────────────────────────────────────────

    function test_edge_clockBeforeClose_isOne() public view {
        assertEq(FeeCurve.stalenessMult(P, Session.Closed, 1_000_000, 999_999), ONE);
        assertEq(FeeCurve.stalenessMult(P, Session.Closed, 1_000_000, 0), ONE);
    }

    function test_edge_zeroKink_isSingleSlope() public view {
        FeeCurve.Params memory q = P;
        q.devKink = 0;
        assertEq(FeeCurve.deviationMult(q, 0, 1 * UPCT, false), ONE + 1 * UPCT * 200, "1% -> 1 + 0.01*200 = 3x");
        assertEq(FeeCurve.deviationMult(q, 0, 0, false), ONE, "f(0) still 1");
    }

    function test_edge_zeroSlopes_areFlat() public view {
        FeeCurve.Params memory q = P;
        q.stalenessSlope = 0;
        q.devSlope1 = 0;
        q.devSlope2 = 0;
        assertEq(FeeCurve.stalenessMult(q, Session.Closed, 0, 72 hours), ONE, "flat staleness");
        assertEq(FeeCurve.deviationMult(q, 0, 50 * UPCT, false), ONE, "flat deviation");
        // Degenerates to a pure session-floor hook: Fables' shape is a point in this parameter space.
        assertEq(FeeCurve.computeFee(q, 3000, ONE, ONE), 3000);
    }

    function test_edge_hugeDeviation_saturatesNoRevert() public view {
        uint256 d = FeeCurve.deviationMult(P, 0, type(uint256).max, false);
        assertEq(d, FeeCurve.deviationMult(P, 0, 1e20, false), "saturates at MAX_DEV");
        assertEq(FeeCurve.computeFee(P, 3000, P.stalenessMax, d), P.feeCap, "capped, no revert");
    }

    function test_edge_floorAboveCap_capWins() public view {
        assertEq(FeeCurve.computeFee(P, 50_000, ONE, ONE), P.feeCap, "floor 500bps > cap 400bps -> cap");
    }

    function test_edge_capAboveMaxLPFee_clamped() public view {
        FeeCurve.Params memory q = P;
        q.feeCap = type(uint24).max; // 16_777_215 > MAX_LP_FEE: a one-digit slip in config
        // Clamps just UNDER 100%: Pool.swap reverts exact-output swaps at a fee of exactly MAX_LP_FEE.
        assertEq(FeeCurve.computeFee(q, 900_000, 3e18, ONE), LPFeeLibrary.MAX_LP_FEE - 1, "never reaches 100%");
    }

    function test_edge_stalenessMaxBelowOne_isMisconfig() public view {
        // FeeCurve does not validate Params. The hook's constructor guard MUST enforce stalenessMax >= 1e18.
        FeeCurve.Params memory q = P;
        q.stalenessMax = 5e17;
        assertLt(FeeCurve.stalenessMult(q, Session.Closed, 0, 1 days), ONE, "documents the hazard");
    }

    // ── end to end: the scenarios that define the mechanism ─────────────────────

    function test_scenario_quietTuesday() public view {
        uint24 fee = FeeCurve.computeFee(
            P,
            FeeCurve.floorFor(P, Session.Regular, true),
            FeeCurve.stalenessMult(P, Session.Regular, 0, 1_000_000),
            FeeCurve.deviationMult(P, 0, 0, false)
        );
        assertEq(fee, 500, "bit-for-bit the unhooked pool");
    }

    function test_scenario_sundayAfternoonNoise() public view {
        // Closed 40h, small pool-created deviation, trade widening it slightly.
        uint256 lc = 1_000_000;
        uint256 s = FeeCurve.stalenessMult(P, Session.Closed, lc, lc + 40 hours);
        bool restoring = FeeCurve.isRestoring(-PCT / 10, -PCT / 5, false); // -0.1% -> -0.2%, adverse
        uint256 d = FeeCurve.deviationMult(P, 0, UPCT / 5, restoring);
        uint24 fee = FeeCurve.computeFee(P, FeeCurve.floorFor(P, Session.Closed, true), s, d);
        assertGt(fee, 3000, "above the closed floor");
        assertLt(fee, 15_000, "but nowhere near the cap: noise fills");
    }

    function test_scenario_sundayNightReopenArb() public view {
        // The trade the hook exists for. Reference wakes at 20:00 ET: prev print 100, new print 103.
        // Pool still at 100 -> gap is REFERENCE-created. Arb swaps toward 103.
        bool refMoved = FeeCurve.referenceMoved(100e18, 103e18, 100e18, 103e18);
        assertTrue(refMoved);
        // Pool is 3% below the new ref (dev = (100-103)/103 ~ -2.91%); arb takes it to ~0.
        int256 pre = -291 * PCT / 100;
        bool restoring = FeeCurve.isRestoring(pre, 0, refMoved);
        assertFalse(restoring, "F1: not exempt");
        uint256 d = FeeCurve.deviationMult(P, 0, FeeCurve.abs(pre), restoring); // charged on the gap taken
        uint24 fee = FeeCurve.computeFee(P, FeeCurve.floorFor(P, Session.Overnight, true), ONE, d);
        // TUNING FINDING (Sept 8): 800 x (1 + 0.5 + 2.41%*200) = 800 x 6.32 -> ~51 bps against a
        // 291 bps gap. Multiplicative-on-floor from an 8 bps floor needs slopes ~10x steeper, or a
        // gap-sized surcharge, to reach phi ~ g. The fork test settles the numbers.
        assertEq(fee, 5056, "fixture: 6.32x on the 8 bps Overnight floor, rounded up");
        assertLt(fee, 29_100, "documented gap: fee well below the 291 bps needed to deter the arb");
    }

    function test_scenario_reopenArb_noTimeDecay() public view {
        // B4: fifteen minutes (or fifteen hours) later, with the pool still at the old print, the
        // arbitrage is charged exactly the same. There is no clock to wait out.
        bool refMoved = FeeCurve.referenceMoved(100e18, 103e18, 100e18, 103e18);
        int256 pre = -291 * PCT / 100;
        uint256 d = FeeCurve.deviationMult(P, 0, FeeCurve.abs(pre), FeeCurve.isRestoring(pre, 0, refMoved));
        uint24 fee = FeeCurve.computeFee(P, FeeCurve.floorFor(P, Session.Overnight, true), ONE, d);
        assertEq(fee, 5056, "identical to t=0: no decay");
    }

    function test_scenario_reopenArb_splitBuysNoExemption() public view {
        // H2: three partial arbs, pool 100 -> 101 -> 102 -> 103 against prints 100 -> 103. Every leg
        // sits inside the band, so every leg is charged; the surcharge falls with the remaining
        // gap and reaches the floor only once the gap is closed. No leg pays the bare floor.
        uint24 floorFee = FeeCurve.floorFor(P, Session.Overnight, true);
        uint256[4] memory pools = [uint256(100e18), 101e18, 102e18, 103e18];
        uint24 last = type(uint24).max;
        for (uint256 i; i < 3; i++) {
            bool moved = FeeCurve.referenceMoved(pools[i], 103e18, 100e18, 103e18);
            assertTrue(moved, "inside the band");
            int256 pre = -int256((103e18 - pools[i]) * 1e18 / 103e18);
            int256 post = -int256((103e18 - pools[i + 1]) * 1e18 / 103e18);
            bool restoring = FeeCurve.isRestoring(pre, post, moved);
            assertFalse(restoring);
            uint24 fee = FeeCurve.computeFee(
                P, floorFee, ONE, FeeCurve.deviationMult(P, FeeCurve.abs(pre), FeeCurve.abs(post), restoring)
            );
            assertGt(fee, floorFee, "every leg above the floor");
            assertLt(fee, last, "surcharge falls as the gap closes");
            last = fee;
        }
        // After the gap is closed, a pool-created wobble back toward 103 IS restoring and pays the floor.
        assertFalse(FeeCurve.referenceMoved(1035e17, 103e18, 100e18, 103e18), "overshoot: pool-created");
        assertTrue(FeeCurve.isRestoring(PCT / 2, 0, false));
    }

    function test_scenario_reopenArb_singleVsSplit() public view {
        // Splitting cannot beat the single swap by more than the endpoint rule's known leakage (B5).
        uint24 floorFee = FeeCurve.floorFor(P, Session.Overnight, true);
        int256 full = -291 * PCT / 100;
        uint24 single = FeeCurve.computeFee(P, floorFee, ONE, FeeCurve.deviationMult(P, FeeCurve.abs(full), 0, false));
        int256 half = full / 2;
        uint24 leg1 = FeeCurve.computeFee(
            P, floorFee, ONE, FeeCurve.deviationMult(P, FeeCurve.abs(full), FeeCurve.abs(half), false)
        );
        uint24 leg2 = FeeCurve.computeFee(P, floorFee, ONE, FeeCurve.deviationMult(P, FeeCurve.abs(half), 0, false));
        // Each leg is charged on its own larger endpoint; the second leg is not exempt.
        assertEq(leg1, single, "first leg pays the full-gap rate");
        assertGt(leg2, floorFee, "second leg still charged");
    }
}
