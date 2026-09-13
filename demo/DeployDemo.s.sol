// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ClosingBellHook} from "../src/ClosingBellHook.sol";
import {ChainlinkEquityAdapter} from "../src/ChainlinkEquityAdapter.sol";
import {FeeCurve} from "../src/FeeCurve.sol";
import {MarketState} from "../src/IMarketStateAdapter.sol";
import {DemoLens} from "./DemoLens.sol";
import {ReplayFeed} from "./ReplayFeed.sol";
import {AAPLRounds} from "./AAPLRounds.sol";

/// Deploys the demo onto a local anvil fork of Robinhood Chain taken on Sunday of Labor Day
/// weekend 2026: real PoolManager, real AAPL/USDG tokens, and the real AAPL/USD rounds replayed
/// against the chain clock (demo/ReplayFeed.sol). Writes demo/addresses.json for the UI.
contract DeployDemo is Script {
    using PoolIdLibrary for PoolKey;

    // docs/verified-onchain.md
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // 18 dec, token1
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 dec, token0
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Deployed {
        ClosingBellHook hook;
        ChainlinkEquityAdapter adapter;
        PoolSwapTest swapRouter;
        DemoLens lens;
    }

    function params() internal pure returns (FeeCurve.Params memory) {
        return FeeCurve.Params({
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
    }

    function run() external {
        vm.startBroadcast();
        Deployed memory d = _deploy();
        vm.stopBroadcast();
        _writeJson(d);
    }

    function _deploy() internal returns (Deployed memory d) {
        (uint80[] memory id, int256[] memory answer, uint256[] memory updatedAt) = AAPLRounds.get();
        ReplayFeed feed = new ReplayFeed(8, id, answer, updatedAt);
        d.adapter = new ChainlinkEquityAdapter(address(feed), address(0), AAPL, 2 days, 2000);

        PoolKey memory key =
            PoolKey(Currency.wrap(USDG), Currency.wrap(AAPL), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(0)));
        d.hook = _deployHook(key, d.adapter);
        key.hooks = IHooks(address(d.hook));

        d.swapRouter = new PoolSwapTest(PM);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(PM);
        d.lens = new DemoLens(PM, d.adapter, key.toId());

        IERC20(USDG).approve(address(d.swapRouter), type(uint256).max);
        IERC20(AAPL).approve(address(d.swapRouter), type(uint256).max);
        IERC20(USDG).approve(address(lpRouter), type(uint256).max);
        IERC20(AAPL).approve(address(lpRouter), type(uint256).max);

        PM.initialize(key, _sqrtAtReference(d.adapter));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e17,
                salt: 0
            }),
            ""
        );
    }

    function _deployHook(PoolKey memory key, ChainlinkEquityAdapter adapter) internal returns (ClosingBellHook hook) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(PM, adapter, params(), key, true);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ClosingBellHook).creationCode, args);
        hook = new ClosingBellHook{salt: salt}(PM, adapter, params(), key, true);
        require(address(hook) == expected, "hook address mismatch");
    }

    // Open the pool at the live reference: sqrt(token1 per token0 in raw units) * 2^96.
    function _sqrtAtReference(ChainlinkEquityAdapter adapter) internal view returns (uint160) {
        MarketState memory m = adapter.getMarketState();
        uint256 ref = m.price; // dollar-quoted: USDG is treated as $1 in the demo
        console2.log("reference USDG per AAPL (1e18)", ref);
        uint256 rawQ192 = FullMath.mulDiv(1e36, 1 << 192, ref * 1e6);
        return uint160(FixedPointMathLib.sqrt(rawQ192));
    }

    function _writeJson(Deployed memory d) internal {
        string memory j = "demo";
        vm.serializeAddress(j, "poolManager", address(PM));
        vm.serializeAddress(j, "hook", address(d.hook));
        vm.serializeAddress(j, "adapter", address(d.adapter));
        vm.serializeAddress(j, "swapRouter", address(d.swapRouter));
        vm.serializeAddress(j, "lens", address(d.lens));
        vm.serializeAddress(j, "usdg", USDG);
        vm.serializeAddress(j, "aapl", AAPL);
        vm.serializeUint(j, "tickSpacing", 60);
        string memory out = vm.serializeUint(j, "fee", LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.writeJson(out, "demo/addresses.json");
        console2.log("hook   ", address(d.hook));
        console2.log("lens   ", address(d.lens));
    }
}
