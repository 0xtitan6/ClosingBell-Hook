// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {MockMarketStateAdapter} from "./mocks/MockMarketStateAdapter.sol";

import {ClosingBellHook} from "../src/ClosingBellHook.sol";
import {FeeCurve} from "../src/FeeCurve.sol";
import {IMarketStateAdapter, Session} from "../src/IMarketStateAdapter.sol";

/// Integration spec for the hook, driven through a real PoolManager. Expects:
///   constructor(IPoolManager, IMarketStateAdapter, FeeCurve.Params, PoolKey, bool stockIsToken1)
///   quoteFee(SwapParams) external view returns (uint24)   // _getFee's number, for tests and tooling
/// Pool: token0 = quote (a dollar), token1 = stock, both 18 decimals, initialized at 100 quote/stock,
/// matching the mock adapter's 100e18 reference. Buying stock is zeroForOne.
contract ClosingBellHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant ONE = 1e18;
    uint256 constant EDT = 4 hours;

    Currency currency0; // quote
    Currency currency1; // stock
    PoolKey poolKey;
    PoolId poolId;
    ClosingBellHook hook;
    MockMarketStateAdapter adapter;
    FeeCurve.Params P;

    // 100 quote per stock; stock is token1 so raw token1/token0 price is 1/100 -> sqrt = 0.1 * 2^96
    uint160 constant SQRT_PRICE_100 = uint160((uint256(1) << 96) / 10);

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        adapter = new MockMarketStateAdapter();

        P = FeeCurve.Params({
            baseFee: 500,
            elevatedFloor: 800,
            closedFloor: 3000,
            feeCap: 40_000,
            stalenessSlope: 10_684_000_000_000,
            stalenessMax: 3e18,
            devKink: 5e15,
            devSlope1: 100,
            devSlope2: 200
        });

        // BaseOverrideFee permissions: afterInitialize | beforeSwap = 0x1080, namespaced.
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flags));
        poolId = poolKey.toId();

        deployCodeTo(
            "ClosingBellHook.sol:ClosingBellHook", abi.encode(poolManager, adapter, P, poolKey, true), flags
        );
        hook = ClosingBellHook(flags);

        // Regular hours, Fri Sep 4 2026 12:00 ET, before the pool exists.
        vm.warp(et(2026, 9, 4, 12, 0));
        poolManager.initialize(poolKey, SQRT_PRICE_100);

        int24 tl = TickMath.minUsableTick(60);
        int24 tu = TickMath.maxUsableTick(60);
        // Full range at price 0.01 needs ~10x L of token0 and ~0.1x L of token1: ~100k quote / 1k stock.
        uint128 liq = 10_000e18;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_100, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liq
        );
        positionManager.mint(poolKey, tl, tu, liq, a0 + 1, a1 + 1, address(this), block.timestamp, V4Constants.ZERO_BYTES);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    function et(uint256 y, uint256 m, uint256 d, uint256 h, uint256 min) internal pure returns (uint256) {
        return DateTimeLib.dateTimeToTimestamp(y, m, d, h, min, 0) + EDT;
    }

    /// Fee the hook would charge for an exact-input swap of `amountIn`, buying stock if `buyStock`.
    function quote(bool buyStock, uint256 amountIn) internal view returns (uint24) {
        return hook.quoteFee(
            SwapParams({
                zeroForOne: buyStock,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: buyStock ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function swap(bool buyStock, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: buyStock,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function poolPrice() internal view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        // token1 per token0 -> invert for quote per stock
        uint256 raw = (uint256(sqrtP) * sqrtP * 1e18) >> 192;
        return 1e36 / raw;
    }

    // ── wiring ──────────────────────────────────────────────────────────────────

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap, "afterInitialize + beforeSwap");
        assertFalse(
            p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.afterSwap || p.beforeDonate || p.afterDonate
                || p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta,
            "nothing else"
        );
    }

    function test_poolInitializedAtReference() public view {
        assertApproxEqRel(poolPrice(), 100e18, 1e12, "100 quote per stock");
    }

    function test_rejectsStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        poolManager.initialize(bad, SQRT_PRICE_100);
    }

    function test_rejectsAnyOtherPool() public {
        // Same tokens, different tick spacing: not the pool this hook was configured for.
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert();
        poolManager.initialize(other, SQRT_PRICE_100);
    }

    // ── the four regimes ────────────────────────────────────────────────────────

    function test_quietRegularHours_isExactlyBase() public view {
        // Fri 12:00 ET, feed live, pool at reference, tiny swap: bit-for-bit the unhooked pool.
        assertEq(quote(true, 1e15), 500, "buy stock");
        assertEq(quote(false, 1e15), 500, "sell stock");
    }

    function test_overnight_paysElevatedFloor() public {
        vm.warp(et(2026, 9, 3, 22, 0)); // Thu 22:00 ET = Friday's overnight
        assertEq(quote(true, 1e15), 800);
    }

    function test_weekend_paysClosedFloorTimesStaleness() public {
        vm.warp(et(2026, 9, 5, 12, 0)); // Sat noon: 16h after Fri 20:00 close
        uint24 fee = quote(true, 1e15);
        uint256 expectedMult = ONE + 16 hours * P.stalenessSlope;
        assertEq(fee, FeeCurve.computeFee(P, 3000, expectedMult, ONE), "closed floor x 16h staleness");
        assertGt(fee, 3000);
    }

    function test_laborDayWeekend_stalenessCaps() public {
        vm.warp(et(2026, 9, 7, 12, 0)); // Labor Day noon: 64h after close, past the 52h cap
        assertEq(quote(true, 1e15), FeeCurve.computeFee(P, 3000, P.stalenessMax, ONE), "3x cap");
    }

    // ── deviation and direction ─────────────────────────────────────────────────

    function test_largeAdverseSwap_paysDeviation() public view {
        // A big buy pushes the pool above the reference: adverse, priced on the post-swap gap.
        uint24 small = quote(true, 1e15);
        uint24 big = quote(true, 5_000e18); // ~10% of the quote reserve: a material move
        assertEq(small, 500);
        // Post price 110.25 (sqrt moves 0.1 -> 0.0952...), dev 10.25%: 500 x (1 + 0.5% x 100 + 9.75% x 200) = 500 x 21 = 10500.
        assertEq(big, 10500, "size-aware: priced on the post-swap gap, both slopes");
    }

    function test_restoringSwap_paysFloor_adverseSwapPaysMore() public {
        // Push the pool ~2% above reference with a real swap (pool-created gap).
        swap(true, 1_000e18);
        uint256 p1 = poolPrice();
        assertGt(p1, 100e18, "pool above reference");
        // Selling a little stock moves it back toward 100 without crossing: restoring, pool-created -> floor.
        uint24 restoring = quote(false, 2e18);
        assertEq(restoring, 500, "restoring pool-created gap pays base");
        // Buying more widens it: adverse -> surcharge.
        uint24 adverse = quote(true, 1_000e18);
        assertGt(adverse, 500, "widening pays more");
    }

    function test_overshootThroughReference_isAdverse() public {
        swap(true, 250e18); // nudge pool ~0.5% above reference
        // Selling far more stock than the gap is worth crosses to well below the reference.
        uint24 fee = quote(false, 40e18);
        assertGt(fee, 500, "crossing the reference is adverse even though it 'moved toward' it");
    }

    // ── F1: the reopen arbitrage ────────────────────────────────────────────────

    function test_reopenArb_isCharged_notExempt() public {
        // Sunday 21:00 ET (Overnight). Reference wakes: 100 -> 103. Pool still at 100.
        vm.warp(et(2026, 9, 13, 21, 0));
        adapter.setSession(Session.Overnight);
        adapter.print(103e18); // prev 100, ref 103
        // The arb buys stock toward 103. Moving toward the reference - but the reference moved.
        uint24 arb = quote(true, 1_400e18);
        assertGt(arb, 800, "F1: reopen arbitrage is charged, not floored");
        // Control: same pool, same trade, but the feed says the reference did NOT move (prev == ref).
        // Then the gap is the pool's own and buying toward 103 is restoring: floor.
        adapter.setPrevPrice(103e18);
        assertEq(quote(true, 100e18), 800, "control: pool-created gap, restoring toward ref, pays floor");
    }

    function test_reopenArb_splitDoesNotEscape() public {
        vm.warp(et(2026, 9, 13, 21, 0));
        adapter.setSession(Session.Overnight);
        adapter.print(103e18);
        uint24 leg1 = quote(true, 700e18);
        swap(true, 700e18); // execute the first leg: pool moves ~1.4% toward 103
        assertTrue(poolPrice() > 100e18 && poolPrice() < 103e18, "pool between the two prints");
        uint24 leg2 = quote(true, 700e18);
        assertGt(leg2, 800, "B6: second leg still charged - pool is between the prints");
        assertLe(leg2, leg1, "surcharge falls as the gap closes");
    }

    // ── never blocks ────────────────────────────────────────────────────────────

    function test_deadFeed_chargesClosedFloor_andPoolStaysOpen() public {
        adapter.kill(); // isLive = false, price = 0
        assertEq(quote(true, 1e15), 3000, "dead feed -> closed floor even in regular hours");
        BalanceDelta d = swap(true, 1e18);
        assertLt(d.amount0(), 0, "swap executed: the pool stays open");
    }

    function test_unknownHistory_chargesByDefault() public {
        // Pool-created 2% gap. With history (prev == ref) closing it is restoring: floor.
        swap(true, 1_000e18);
        assertEq(quote(false, 2e18), 500, "known history: restoring pays base");
        // Without history the hook cannot tell it from a reference move: charged.
        adapter.setPrevPrice(0);
        assertGt(quote(false, 2e18), 500, "prevPrice == 0: when in doubt, charge");
    }

    function test_calendarWins_overFeedSession() public {
        // The hook takes the session from the NYSE calendar, never from the feed.
        adapter.setSession(Session.Closed);
        assertEq(quote(true, 1e15), 500, "Friday noon is Regular whatever the feed says");
    }

    // ── the fee actually reaches the swap ───────────────────────────────────────

    function test_overrideFlagApplied_swapEventCarriesTheHookFee() public {
        uint256 amountIn = 100e18;
        uint256 snap = vm.snapshotState();
        uint24 expectedWeekday = quote(true, amountIn);
        vm.recordLogs();
        BalanceDelta weekday = swap(true, amountIn);
        assertEq(lastSwapFee(), expectedWeekday, "weekday: PoolManager charged exactly the hook's number");
        vm.revertToState(snap); // identical pool state for the second swap
        vm.warp(et(2026, 9, 5, 12, 0)); // Saturday
        uint24 expectedWeekend = quote(true, amountIn);
        vm.recordLogs();
        BalanceDelta weekend = swap(true, amountIn);
        assertEq(lastSwapFee(), expectedWeekend, "Saturday: PoolManager charged exactly the hook's number");
        assertGt(expectedWeekend, expectedWeekday);
        assertLt(weekend.amount1(), weekday.amount1(), "higher fee -> less output");
    }

    /// The `fee` word of the most recent PoolManager Swap event.
    function lastSwapFee() internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == sig) {
                (,,,,, fee) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    // ── Round 3 regressions ─────────────────────────────────────────────────────

    function test_reopenArb_prepositionedPool_stillCharged() public {
        // H1: nudge the pool a wei below the last print before Friday's close, then run the same
        // Sunday arbitrage. The pool is now outside [prev, ref]; it must still read as "reference
        // moved" or the whole reopen move rides at the floor.
        vm.warp(et(2026, 9, 11, 19, 59)); // Fri, post-market, one minute before the close
        swap(false, 1e15); // sell dust: pool 99.9998
        vm.warp(et(2026, 9, 13, 21, 0)); // Sunday overnight
        adapter.print(103e18);
        assertGt(quote(true, 1_400e18), 800, "pre-positioned pool: reopen arb still charged");
    }

    function test_reopenArb_prepositionedPool_mirror() public {
        vm.warp(et(2026, 9, 11, 19, 59));
        swap(true, 1e15); // buy dust: pool a hair above 100
        vm.warp(et(2026, 9, 13, 21, 0));
        adapter.print(97e18); // reference gaps down
        assertGt(quote(false, 14e18), 800, "mirror: selling toward 97 is arbitrage, not restoring");
    }

    function test_liveFeedWithUnusablePrice_paysClosedFloor() public {
        // "isLive" without a usable reference is a broken adapter, not a healthy market.
        adapter.setPrice(0);
        assertEq(quote(true, 5_000e18), 3000, "live but price 0: closed floor, no cheap deviation-free rate");
        adapter.setPrice(100e18);
        adapter.setQuote(true, 0, 0);
        assertEq(quote(true, 5_000e18), 3000, "quote feed at 0: same");
    }

    function test_revertingAdapter_isTreatedAsDeadFeed() public {
        adapter.setReverting(true);
        assertEq(quote(true, 1e15), 3000, "adapter revert -> zero struct -> closed floor");
        BalanceDelta d = swap(true, 1e18);
        assertLt(d.amount0(), 0, "the swap still executes");
    }

    function test_pausedFeedWithLastPrice_keepsDeviationPricing() public {
        // A paused market-status feed still carries a last print. The floor rises to closed;
        // the deviation term still applies to adverse swaps and still exempts restoring ones.
        swap(true, 1_000e18); // pool ~2% above ref
        adapter.setLive(false);
        assertGt(quote(true, 1_000e18), 3000, "adverse: closed floor x deviation");
        assertEq(quote(false, 2e18), 3000, "restoring: closed floor x 1.0");
    }

    function test_quoteFeedPool_referenceIsStockOverQuote() public {
        // Stock/SPY-style pool: reference = stockPrice / quotePrice.
        adapter.setQuote(true, 1e18, 1e18); // quote worth $1: ref 100, pool at 100
        assertEq(quote(true, 1e15), 500);
        adapter.setQuote(true, 2e18, 2e18); // quote worth $2: ref 50, pool at 100 is +100%
        assertEq(quote(true, 1e15), P.feeCap, "adverse buy on a 100% gap: capped");
        // Unknown quote history counts as a reference move: a restoring sell is charged.
        adapter.setQuote(true, 1e18, 1e18);
        swap(true, 1_000e18);
        assertEq(quote(false, 2e18), 500, "known history: restoring");
        adapter.setQuote(true, 1e18, 0);
        assertGt(quote(false, 2e18), 500, "prevQuotePrice == 0: charged");
    }

    function test_exactOutput_isPricedLikeExactInput() public {
        SwapParams memory buy50 = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(50e18), // want 50 stock out
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        uint24 fee50 = hook.quoteFee(buy50);
        assertGt(fee50, 500, "exact-output buy that widens the gap pays deviation");
        // More output than the pool holds: the estimate reverts inside try/catch, the fallback is
        // the trader's own price limit, and the fee saturates instead of the swap reverting.
        buy50.amountSpecified = int256(5_000e18);
        assertEq(hook.quoteFee(buy50), P.feeCap, "impossible exact-output: fallback to limit, capped");
        // And the PoolManager charges exactly the quoted number on a real exact-output swap.
        uint24 expected = hook.quoteFee(
            SwapParams({zeroForOne: true, amountSpecified: int256(7e18), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
        vm.recordLogs();
        swapRouter.swapTokensForExactTokens({
            amountOut: 7e18,
            amountInMax: type(uint256).max,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        assertEq(lastSwapFee(), expected, "exact-output swap charged the quoted fee");
    }

    function test_priceLimit_readsAsHugeDeviation_neverZero() public {
        // F-1: a buy clamped to the minimum sqrt price used to read as price 0 (-100%), making the
        // fee non-monotone in size. It must read as an enormous positive deviation.
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x5555 << 144));
        deployCodeTo("ClosingBellHook.t.sol:HookHarness", abi.encode(poolManager, adapter, P, poolKey, true), flags);
        HookHarness h = HookHarness(flags);
        assertApproxEqRel(h.price(SQRT_PRICE_100), 100e18, 1e12, "reads 100 at the initial price");
        assertGt(h.price(TickMath.MIN_SQRT_PRICE), 1e40, "buy-side limit: pool price is astronomically high");
        assertLt(h.price(TickMath.MAX_SQRT_PRICE), 1, "sell-side limit: pool price is ~0");
        assertEq(h.price(0), type(uint256).max, "sqrtP 0 saturates rather than dividing by zero");
        // Fee is monotone in size all the way to the limit.
        assertGe(quote(true, 1e40), quote(true, 50_000e18), "sweeping the pool never costs less than half of it");
    }
}

/// Exposes the price conversion for direct testing.
contract HookHarness is ClosingBellHook {
    constructor(IPoolManager pm, IMarketStateAdapter a, FeeCurve.Params memory p, PoolKey memory k, bool s1)
        ClosingBellHook(pm, a, p, k, s1)
    {}

    function price(uint160 sqrtP) external view returns (uint256) {
        return _price(sqrtP);
    }
}

/// Production layout: USDG (6 decimals) as token0, AAPL (18 decimals) as token1, same fee params.
/// Every number here should match the 18/18 suite above: decimals must be invisible to the fee.
contract ClosingBellHookDecimalsTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant EDT = 4 hours;
    // 100 USDG per AAPL: token1/token0 in wei = 1e18 / 100e6 = 1e10, sqrt = 1e5.
    uint160 constant SQRT_INIT = uint160(uint256(1e5) << 96);

    MockERC20 usdg;
    MockERC20 aapl;
    PoolKey poolKey;
    ClosingBellHook hook;
    MockMarketStateAdapter adapter;
    FeeCurve.Params P;

    function setUp() public {
        deployArtifactsAndLabel();
        aapl = deployTokenWithDecimals(18);
        // Need the 6-decimal token to sort first; redeploy until it does.
        do {
            usdg = deployTokenWithDecimals(6);
        } while (address(usdg) > address(aapl));
        adapter = new MockMarketStateAdapter();
        P = FeeCurve.Params({
            baseFee: 500,
            elevatedFloor: 800,
            closedFloor: 3000,
            feeCap: 40_000,
            stalenessSlope: 10_684_000_000_000,
            stalenessMax: 3e18,
            devKink: 5e15,
            devSlope1: 100,
            devSlope2: 200
        });
        poolKey = PoolKey(Currency.wrap(address(usdg)), Currency.wrap(address(aapl)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(0)));
    }

    function deployTokenWithDecimals(uint8 dec) internal returns (MockERC20 token) {
        token = new MockERC20("Test Token", "TEST", dec);
        token.mint(address(this), 10_000_000 * 10 ** uint256(dec));
        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function deployHook(bool stockIsToken1, uint160 salt) internal returns (address flags) {
        flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (salt << 144));
        poolKey.hooks = IHooks(flags);
        deployCodeTo(
            "ClosingBellHook.sol:ClosingBellHook", abi.encode(poolManager, adapter, P, poolKey, stockIsToken1), flags
        );
    }

    function initAndSeed() internal {
        vm.warp(DateTimeLib.dateTimeToTimestamp(2026, 9, 4, 12, 0, 0) + EDT); // Fri noon ET
        poolManager.initialize(poolKey, SQRT_INIT);
        int24 tl = TickMath.minUsableTick(60);
        int24 tu = TickMath.maxUsableTick(60);
        uint128 liq = 1e16; // ~100k USDG / ~1k AAPL, the same economics as the 18/18 suite
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_INIT, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liq
        );
        positionManager.mint(poolKey, tl, tu, liq, a0 + 1, a1 + 1, address(this), block.timestamp, V4Constants.ZERO_BYTES);
    }

    function quote(bool buyStock, uint256 amountIn) internal view returns (uint24) {
        return hook.quoteFee(
            SwapParams({
                zeroForOne: buyStock,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: buyStock ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function test_sixDecimalQuote_feesMatchThe18DecimalSuite() public {
        hook = ClosingBellHook(deployHook(true, 0x4444));
        initAndSeed();
        assertEq(quote(true, 1e3), 500, "quiet tiny buy");
        assertEq(quote(false, 1e15), 500, "quiet tiny sell");
        assertEq(quote(true, 5_000e6), 10500, "5000 USDG buy: same 10.25% post-gap as 5000e18 in the 18/18 pool");
        vm.warp(DateTimeLib.dateTimeToTimestamp(2026, 9, 5, 12, 0, 0) + EDT); // Saturday noon
        assertEq(quote(true, 1e3), FeeCurve.computeFee(P, 3000, 1e18 + 16 hours * P.stalenessSlope, 1e18));
    }

    function test_wrongStockSide_isRefusedAtInitialize() public {
        // With the flag inverted the hook would read the pool at 0.01 against a reference of 100
        // and charge the cap on every buy, forever. It must refuse to initialize instead.
        deployHook(false, 0x5555);
        vm.expectRevert();
        poolManager.initialize(poolKey, SQRT_INIT);
    }
}
