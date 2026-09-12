// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ClosingBellHook} from "../../src/ClosingBellHook.sol";
import {ChainlinkEquityAdapter} from "../../src/ChainlinkEquityAdapter.sol";
import {FeeCurve} from "../../src/FeeCurve.sol";
import {MarketState} from "../../src/IMarketStateAdapter.sol";
import {MarketHours, Session} from "../../src/MarketHours.sol";

/// The hook on a fork of Robinhood Chain: real PoolManager, real AAPL and USDG tokens, real
/// Chainlink feeds. Opens an AAPL/USDG pool at the live reference, adds liquidity, and swaps.
/// Run with:  forge test --match-path test/fork/Hook.fork.t.sol --fork-url $ROBINHOOD_RPC -vv
contract HookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // docs/verified-onchain.md
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // 18 dec
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 dec

    ChainlinkEquityAdapter adapter;
    ClosingBellHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey poolKey;
    PoolId poolId;
    FeeCurve.Params P;
    uint256 ref;

    function setUp() public {
        if (block.chainid != 4663) vm.skip(true);

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

        adapter = new ChainlinkEquityAdapter(AAPL_USD, USDG_USD, AAPL, 3 days, 2000);
        MarketState memory m = adapter.getMarketState();
        ref = FullMath.mulDiv(m.price, 1e18, m.quotePrice);

        // USDG sorts below AAPL, so USDG is token0 and AAPL is token1 (production layout).
        require(USDG < AAPL, "layout");
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        poolKey = PoolKey(Currency.wrap(USDG), Currency.wrap(AAPL), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flags));
        poolId = poolKey.toId();
        deployCodeTo("ClosingBellHook.sol:ClosingBellHook", abi.encode(PM, adapter, P, poolKey, true), flags);
        hook = ClosingBellHook(flags);

        swapRouter = new PoolSwapTest(PM);
        lpRouter = new PoolModifyLiquidityTest(PM);
        deal(USDG, address(this), 100_000_000e6);
        deal(AAPL, address(this), 1_000_000e18);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        IERC20(AAPL).approve(address(swapRouter), type(uint256).max);
        IERC20(USDG).approve(address(lpRouter), type(uint256).max);
        IERC20(AAPL).approve(address(lpRouter), type(uint256).max);

        // sqrtPriceX96 for "ref USDG per AAPL": token1 per token0 in raw units = 1e18 * 1e18 / (ref * 1e6)
        uint256 rawQ192 = FullMath.mulDiv(1e36, 1 << 192, ref * 1e6);
        uint160 sqrtInit = uint160(FixedPointMathLib.sqrt(rawQ192));
        PM.initialize(poolKey, sqrtInit);

        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e17,
                salt: 0
            }),
            ""
        );
    }

    function test_liveQuotes() public view {
        (Session s, uint256 lastClose) = MarketHours.calendar(block.timestamp);
        console2.log("block.timestamp", block.timestamp);
        console2.log("session (0 Closed, 1 Regular, 2 Extended, 3 Overnight)", uint256(s));
        console2.log("hours since last close", (block.timestamp - lastClose) / 3600);
        console2.log("reference USDG per AAPL (1e18)", ref);
        console2.log("pool price (1e18)", _poolPrice());

        console2.log("fee, buy 100 USDG of AAPL   ", quote(true, 100e6));
        console2.log("fee, buy 100k USDG of AAPL  ", quote(true, 100_000e6));
        console2.log("fee, sell 1 AAPL            ", quote(false, 1e18));
        console2.log("fee, sell 1000 AAPL         ", quote(false, 1000e18));

        assertGe(quote(true, 100_000e6), quote(true, 100e6), "bigger swap never cheaper");
    }

    function test_swapChargesTheHookFee() public {
        uint24 expected = quote(true, 1_000e6);
        vm.recordLogs();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1_000e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint24 charged;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, charged) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        console2.log("quoted fee", expected, "charged fee", charged);
        assertEq(charged, expected, "swap event carries the hook fee");
    }

    function test_weekendRamp() public {
        uint24 now_ = quote(true, 100e6);
        vm.warp(block.timestamp + 24 hours);
        uint24 later = quote(true, 100e6);
        console2.log("fee now", now_, "fee +24h", later);
        assertGe(later, now_, "fee never falls while the feed is dark");
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

    function _poolPrice() internal view returns (uint256) {
        (uint160 sqrtP,,,) = PM.getSlot0(poolId);
        uint256 raw = FullMath.mulDiv(uint256(sqrtP) * sqrtP, 1e18, 1 << 192); // token1 per token0, 1e18
        return 1e36 * 1e12 / raw / 1e18;
    }
}
