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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {MockAggregatorV3, MockPausableStock} from "./mocks/MockAggregatorV3.sol";

import {ClosingBellHook} from "../src/ClosingBellHook.sol";
import {ChainlinkEquityAdapter} from "../src/ChainlinkEquityAdapter.sol";
import {FeeCurve} from "../src/FeeCurve.sol";
import {MarketState} from "../src/IMarketStateAdapter.sol";

/// The whole system, no mock adapter: real PoolManager, real hook, real ChainlinkEquityAdapter
/// reading a canned Chainlink feed. Walks one realistic week — Friday's session, the close, a dark
/// weekend, the Sunday reopen gapping up, the arbitrage, a retrace, Labor Day, Tuesday's open —
/// and asserts the fee at every step. Production layout: USDG (6 decimals) is token0, the stock
/// (18 decimals) is token1, so buying stock is zeroForOne.
contract EndToEndTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant EDT = 4 hours;
    uint160 constant SQRT_INIT = uint160(uint256(1e5) << 96); // 100 USDG per stock

    MockERC20 usdg;
    MockERC20 stock;
    MockAggregatorV3 feed;
    MockPausableStock token;
    ChainlinkEquityAdapter adapter;
    ClosingBellHook hook;
    PoolKey poolKey;
    PoolId poolId;
    FeeCurve.Params P;

    function setUp() public {
        deployArtifactsAndLabel();
        stock = deployTokenWithDecimals(18);
        do {
            usdg = deployTokenWithDecimals(6);
        } while (address(usdg) > address(stock));

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

        // Thursday afternoon, before the pool exists: two prints so the feed has history.
        vm.warp(et(2026, 9, 3, 16, 0));
        feed = new MockAggregatorV3(8, (uint80(1) << 64) | 1);
        token = new MockPausableStock();
        feed.push(99_50000000, et(2026, 9, 3, 11, 0));
        feed.push(100_00000000, et(2026, 9, 3, 15, 30));
        adapter = new ChainlinkEquityAdapter(address(feed), address(0), address(token), 2 days, 2000);

        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        poolKey = PoolKey(
            Currency.wrap(address(usdg)),
            Currency.wrap(address(stock)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(flags)
        );
        poolId = poolKey.toId();
        deployCodeTo("ClosingBellHook.sol:ClosingBellHook", abi.encode(poolManager, adapter, P, poolKey, true), flags);
        hook = ClosingBellHook(flags);

        vm.warp(et(2026, 9, 4, 12, 0)); // Friday noon
        poolManager.initialize(poolKey, SQRT_INIT);
        int24 tl = TickMath.minUsableTick(60);
        int24 tu = TickMath.maxUsableTick(60);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_INIT, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 1e16
        );
        positionManager.mint(
            poolKey, tl, tu, 1e16, a0 + 1, a1 + 1, address(this), block.timestamp, V4Constants.ZERO_BYTES
        );
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function et(uint256 y, uint256 m, uint256 d, uint256 h, uint256 min) internal pure returns (uint256) {
        return DateTimeLib.dateTimeToTimestamp(y, m, d, h, min, 0) + EDT;
    }

    function deployTokenWithDecimals(uint8 dec) internal returns (MockERC20 t) {
        t = new MockERC20("Test Token", "TEST", dec);
        t.mint(address(this), 10_000_000 * 10 ** uint256(dec));
        t.approve(address(permit2), type(uint256).max);
        t.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(t), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(t), address(poolManager), type(uint160).max, type(uint48).max);
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

    function swap(bool buyStock, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: buyStock,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    /// Quote per stock, 1e18, read from the pool.
    function poolPrice() internal view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint256 raw = (uint256(sqrtP) * sqrtP) >> 192; // token1 per token0, wei
        return 1e18 * 1e12 / raw;
    }

    // ── the week ────────────────────────────────────────────────────────────

    function test_week_friday_toReopen_toTuesday() public {
        // Friday noon, feed fresh, pool at the reference: the unhooked fee.
        assertEq(quote(true, 1e3), 500, "Fri 12:00 quiet buy");
        assertEq(quote(false, 1e12), 500, "Fri 12:00 quiet sell");

        // 15:01: the reference prints +0.4%. The pool has not followed: the arb is charged.
        vm.warp(et(2026, 9, 4, 15, 1));
        feed.push(100_40000000, block.timestamp);
        assertGt(quote(true, 200e6), 500, "0.4% print: arb charged");
        swap(true, 200e6); // someone tracks it
        assertEq(quote(true, 1e3), 500, "once tracked, quiet again");

        // 17:00 post-market: elevated floor.
        vm.warp(et(2026, 9, 4, 17, 0));
        assertEq(quote(true, 1e3), 800, "Extended session floor");

        // Friday 19:00, the last print before the close. Post-market flow tracks it, so the pool
        // goes into the weekend sitting on the reference.
        vm.warp(et(2026, 9, 4, 19, 0));
        feed.push(100_50000000, block.timestamp);
        swap(true, 50e6);

        // Saturday noon: closed floor times 16h of staleness, feed dark.
        vm.warp(et(2026, 9, 5, 12, 0));
        uint24 sat = quote(true, 1e3);
        // Closed floor x 16h of staleness. The pool tracked the reference to within a wei of
        // truncation, which shows up as one pip of deviation surcharge.
        assertApproxEqAbs(
            sat, FeeCurve.computeFee(P, 3000, 1e18 + 16 hours * P.stalenessSlope, 1e18), 1, "Sat noon ramp"
        );
        assertEq(sat, 4847);

        // Sunday 19:30: still closed, ramp higher.
        vm.warp(et(2026, 9, 6, 19, 30));
        assertGt(quote(true, 1e3), sat, "the ramp keeps climbing while closed");

        // Sunday 20:00 the feed wakes and gaps +2.5%. Labor Day weekend, so the calendar is still
        // Closed on Monday: the pool pays the closed floor at the staleness cap plus deviation.
        vm.warp(et(2026, 9, 6, 20, 5));
        feed.push(103_00000000, block.timestamp);
        MarketState memory m = adapter.getMarketState();
        assertEq(m.price, 103e18);
        assertEq(m.loPrice, 995e17, "the window spans every print of the week within LOOKBACK");
        assertEq(m.hiPrice, 103e18);
        assertEq(quote(true, 1e3), P.feeCap, "reopen gap during a holiday weekend: capped");

        // Monday 20:05 is Tuesday's overnight session: the floor drops to elevated, and the arb
        // toward 103 is still charged well above it because the reference moved.
        vm.warp(et(2026, 9, 7, 20, 5));
        uint24 arb = quote(true, 1_400e6);
        assertGt(arb, 800, "reopen arbitrage is charged, not floored");
        swap(true, 1_400e6);
        assertGt(poolPrice(), 102e18, "the arb moved the pool to the new reference");

        // The feed retraces to 102. The pool tracked 103, so selling back captures a real move:
        // charged. This is the Round 4 finding; a single-print anchor floored it.
        feed.push(102_00000000, block.timestamp);
        assertGt(quote(false, 4e18), 800, "retrace after a tracked reopen is charged");

        // Tuesday 09:31, market open. Once the reference and the pool agree, the fee is back to
        // base: the whole week has returned to the unhooked cost.
        vm.warp(et(2026, 9, 8, 9, 31));
        swap(false, 4e18); // the rest of the retrace arb
        feed.push(int256(poolPrice() / 1e10), block.timestamp); // the reference converges too
        assertEq(quote(true, 1e3), 500, "Tuesday open, pool at the reference");
        assertEq(quote(false, 1e12), 500);
    }

    function test_week_trendOfPrints_untrackedPoolIsCharged() public {
        // Round 4 High: four small prints while the pool sits still. The arb that finally takes the
        // whole 0.9% must pay for it.
        vm.warp(et(2026, 9, 4, 13, 0));
        feed.push(100_30000000, block.timestamp);
        feed.push(100_60000000, block.timestamp + 600);
        feed.push(100_90000000, block.timestamp + 1200);
        vm.warp(block.timestamp + 1300);
        assertGt(quote(true, 400e6), 1_100, "trend of prints: the whole gap is charged");
    }

    function test_deadFeed_poolStaysOpen() public {
        feed.setRevertLatest(true);
        assertEq(quote(true, 1e3), 3000, "dead feed in regular hours: closed floor");
        swap(true, 1e6);
        assertGt(poolPrice(), 0, "the swap executed");
    }

    function test_pausedToken_keepsDeviationPricing() public {
        swap(true, 1_000e6); // push the pool above the reference
        token.setPaused(true);
        assertGt(quote(true, 1_000e6), 3000, "paused: closed floor times deviation");
        assertEq(quote(false, 2e18), 3000, "restoring at the closed floor");
        token.setPaused(false);
        assertEq(quote(false, 2e18), 500, "unpaused: restoring pays base again");
    }

    function test_gas_endToEndSwap() public {
        swap(true, 1e6); // warm the pool's slots; the first swap in a fresh pool pays cold costs
        uint256 g = gasleft();
        swap(true, 100e6);
        uint256 deviationPath = g - gasleft();
        emit log_named_uint("router swap gas (live feed)", deviationPath);
        assertLt(deviationPath, 140_000);

        feed.setRevertLatest(true);
        g = gasleft();
        swap(true, 100e6);
        uint256 deadPath = g - gasleft();
        emit log_named_uint("router swap gas (dead feed)", deadPath);
        assertLt(deadPath, 110_000);
    }
}
