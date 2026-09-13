// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ClosingBellHook} from "../../src/ClosingBellHook.sol";
import {ChainlinkEquityAdapter} from "../../src/ChainlinkEquityAdapter.sol";
import {FeeCurve} from "../../src/FeeCurve.sol";
import {MarketState} from "../../src/IMarketStateAdapter.sol";
import {MarketHours, Session} from "../../src/MarketHours.sol";
import {ReplayFeed} from "../../demo/ReplayFeed.sol";
import {AAPLRounds} from "../../demo/AAPLRounds.sol";

/// Labor Day weekend 2026 replayed on a fork taken Sunday morning, with the real AAPL/USD rounds.
/// Run with: forge test --match-path test/fork/Replay.fork.t.sol --fork-url https://rpc.ordofi.network --fork-block-number 56000000 -vv
contract ReplayForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 constant MON_1950 = 1788825000; // Mon Sep 7 19:50 ET, still dark
    uint256 constant MON_2020 = 1788826800; // Mon Sep 7 20:20 ET, feed woke at 20:00 and gapped at 20:17
    uint256 constant TUE_0935 = 1788874500; // Tue Sep 8 09:35 ET, regular open

    ClosingBellHook hook;
    ChainlinkEquityAdapter adapter;
    FeeCurve.Params P;

    function setUp() public {
        if (block.chainid != 4663 || block.number > 56_100_000) vm.skip(true);
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
        (uint80[] memory id, int256[] memory answer, uint256[] memory updatedAt) = AAPLRounds.get();
        ReplayFeed feed = new ReplayFeed(8, id, answer, updatedAt);
        adapter = new ChainlinkEquityAdapter(address(feed), address(0), AAPL, 2 days, 2000);

        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        PoolKey memory key =
            PoolKey(Currency.wrap(USDG), Currency.wrap(AAPL), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flags));
        deployCodeTo("ClosingBellHook.sol:ClosingBellHook", abi.encode(PM, adapter, P, key, true), flags);
        hook = ClosingBellHook(flags);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        deal(USDG, address(this), 100_000_000e6);
        deal(AAPL, address(this), 1_000_000e18);
        IERC20(USDG).approve(address(lp), type(uint256).max);
        IERC20(AAPL).approve(address(lp), type(uint256).max);

        uint256 ref = adapter.getMarketState().price;
        uint160 sqrtInit = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(1e36, 1 << 192, ref * 1e6)));
        PM.initialize(key, sqrtInit);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e17, 0),
            ""
        );
    }

    function test_laborDayWeekend_replayed() public {
        (uint24 sunBuy, uint24 sunSell) = _row("Sun 09:05  fork start, feed dark since Fri 15:51");
        assertEq(uint8(_session()), uint8(Session.Closed));
        assertTrue(adapter.getMarketState().isLive, "41h after Friday's print: within maxStaleness, calendar is what closes the pool");
        assertGt(sunBuy, P.closedFloor, "closed floor x staleness");

        vm.warp(MON_1950);
        (uint24 monBuy,) = _row("Mon 19:50  Labor Day, still dark");
        assertGt(monBuy, sunBuy, "ramp climbs");
        assertEq(uint8(_session()), uint8(Session.Closed));
        assertFalse(adapter.getMarketState().isLive, "76h after the print: the dead-feed net is now also on");

        vm.warp(MON_2020);
        (uint24 wakeBuy, uint24 wakeSell) = _row("Mon 20:20  feed woke, gapped to 318.53");
        MarketState memory m = adapter.getMarketState();
        assertTrue(m.isLive);
        assertEq(m.price, 318_53021158 * 1e10, "real 20:17 print: 318.53021158");
        assertEq(uint8(_session()), uint8(Session.Overnight));
        assertGt(wakeBuy, P.elevatedFloor, "buy pushes the pool further above the new reference: adverse");
        assertGt(wakeSell, P.elevatedFloor, "sell toward the new print is the reopen arbitrage: charged, not floored");
        assertGt(wakeBuy, wakeSell, "adverse pays more than the arb");

        vm.warp(TUE_0935);
        (uint24 tueBuy, uint24 tueSell) = _row("Tue 09:35  regular open");
        assertEq(uint8(_session()), uint8(Session.Regular));
        assertGt(tueBuy, P.baseFee, "untracked gap still priced in regular hours");
        assertLt(tueBuy, wakeBuy, "cheaper floor once regular hours start");
        sunSell; tueSell;
    }

    function _session() internal view returns (Session s) {
        (s,) = MarketHours.calendar(block.timestamp);
    }

    function _row(string memory label) internal view returns (uint24 buy, uint24 sell) {
        buy = hook.quoteFee(SwapParams(true, -1_000e6, TickMath.MIN_SQRT_PRICE + 1));
        sell = hook.quoteFee(SwapParams(false, -3e18, TickMath.MAX_SQRT_PRICE - 1));
        MarketState memory m = adapter.getMarketState();
        console2.log(label);
        console2.log("   session", uint256(_session()), "isLive", m.isLive);
        console2.log("   reference (1e18)", m.price);
        console2.log("   buy 1000 USDG fee", buy, "sell 3 AAPL fee", sell);
    }
}
