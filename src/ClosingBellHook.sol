// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMarketStateAdapter, MarketState} from "./IMarketStateAdapter.sol";
import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Constants as C} from "./Constants.sol";
import {MarketHours, Session} from "./MarketHours.sol";
import {FeeCurve} from "./FeeCurve.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Dynamic swap fee for a tokenized-stock pool: cheap while the stock market is open and the
// pool tracks it, higher when the market is closed, the feed is stale, or a swap widens the gap.
contract ClosingBellHook is BaseOverrideFee {
    error WrongPool();
    error InvalidParams();
    error PriceMismatch();

    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    IMarketStateAdapter public immutable adapter;
    PoolId public immutable poolId;
    bool public immutable stockIsToken1;
    uint256 internal immutable scale0;
    uint256 internal immutable scale1;

    FeeCurve.Params internal P;

    constructor(
        IPoolManager poolManager_,
        IMarketStateAdapter adapter_,
        FeeCurve.Params memory p,
        PoolKey memory key,
        bool stockIsToken1_
    ) BaseHook(poolManager_) {
        if (!FeeCurve.validate(p)) revert InvalidParams();
        if (!key.fee.isDynamicFee()) revert InvalidParams();
        if (address(adapter_).code.length == 0) revert InvalidParams();

        P = p;
        adapter = adapter_;
        key.hooks = IHooks(address(this));
        poolId = key.toId();
        stockIsToken1 = stockIsToken1_;

        uint8 d0 = _decimals(key.currency0);
        uint8 d1 = _decimals(key.currency1);
        uint8 gap = d0 > d1 ? d0 - d1 : d1 - d0;
        if (d0 > 24 || d1 > 24 || gap > 18) revert InvalidParams();
        scale0 = 10 ** uint256(d0);
        scale1 = 10 ** uint256(d1);
    }

    // Fee this swap would pay right now, for off-chain quoting.
    function quoteFee(SwapParams calldata params) external view returns (uint24) {
        return _fee(params);
    }

    // External only so the estimate below can catch it reverting on impossible sizes.
    function stepSqrtPrice(uint160 sqrtP, uint128 liquidity, int256 amountSpecified, bool zeroForOne)
        external
        pure
        returns (uint160)
    {
        if (amountSpecified < 0) {
            return SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, liquidity, uint256(-amountSpecified), zeroForOne);
        }
        return SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtP, liquidity, uint256(amountSpecified), zeroForOne);
    }

    // Binds to one pool and refuses a start price more than 10x off the reference.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        bytes4 selector = super._afterInitialize(sender, key, sqrtPriceX96, tick);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        // Refuse a pool opened more than 10x away from the reference: almost always a flipped stockIsToken1.
        (uint256 ref,,) = _references(_market());
        if (ref != 0) {
            uint256 pool = _price(sqrtPriceX96);
            if (pool > ref * 10 || pool * 10 < ref) revert PriceMismatch();
        }
        return selector;
    }

    // Hook entry point: the fee charged on every swap.
    function _getFee(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _fee(params);
    }

    // floor(session) x staleness x deviation, capped.
    function _fee(SwapParams calldata sp) internal view returns (uint24) {
        FeeCurve.Params memory p = P;
        MarketState memory m = _market();
        (Session s, uint256 lastClose) = MarketHours.calendar(block.timestamp);
        (uint256 ref, uint256 lo, uint256 hi) = _references(m);
        uint256 devM = ref == 0 ? C.ONE : _deviationMult(p, ref, lo, hi, sp);
        return FeeCurve.computeFee(
            p,
            FeeCurve.floorFor(p, s, m.isLive && ref != 0),
            FeeCurve.stalenessMult(p, s, lastClose, block.timestamp),
            devM
        );
    }

    // Reads the adapter; a failed call or wrong-sized reply reads as a dead feed (all zeros).
    function _market() internal view returns (MarketState memory m) {
        (bool ok, bytes memory r) = address(adapter).staticcall(abi.encodeCall(IMarketStateAdapter.getMarketState, ()));
        if (!ok || r.length != 256) return m;
        uint256[8] memory w = abi.decode(r, (uint256[8]));
        return MarketState(w[0] != 0, w[1], w[2], w[3], w[4] != 0, w[5], w[6], w[7]);
    }

    // Reference price and recent band, dividing by the quote feed when there is one.
    function _references(MarketState memory m) internal pure returns (uint256 ref, uint256 lo, uint256 hi) {
        if (!m.hasQuoteFeed) return (m.price, m.loPrice, m.hiPrice);
        ref = _ratio(m.price, m.quotePrice);
        if (ref == 0) return (0, 0, 0);
        lo = _ratio(m.loPrice, m.hiQuotePrice);
        hi = _ratio(m.hiPrice, m.loQuotePrice);
    }

    // a / b at 1e18 scale; 0 when it cannot be computed.
    function _ratio(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0 || a / b >= type(uint256).max / C.ONE) return 0;
        return FullMath.mulDiv(a, C.ONE, b);
    }

    // How far the pool sits from the reference before and after this swap.
    function _deviationMult(FeeCurve.Params memory p, uint256 ref, uint256 lo, uint256 hi, SwapParams calldata sp)
        internal
        view
        returns (uint256)
    {
        (uint256 pre, uint256 post) = _poolPrices(sp);
        bool refMoved = FeeCurve.referenceMoved(pre, ref, lo, hi);
        int256 preDev = _dev(pre, ref);
        int256 postDev = _dev(post, ref);
        bool restoring = FeeCurve.isRestoring(preDev, postDev, refMoved);
        return FeeCurve.deviationMult(p, FixedPointMathLib.abs(preDev), FixedPointMathLib.abs(postDev), restoring);
    }

    // Pool price now, and where this swap would leave it.
    function _poolPrices(SwapParams calldata sp) internal view returns (uint256 pre, uint256 post) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        pre = _price(sqrtP);
        post = _price(_estimatePostSqrtPrice(sqrtP, liquidity, sp));
    }

    // Where the swap would push the price, never past the trader's limit; on failure assume the limit.
    function _estimatePostSqrtPrice(uint160 sqrtP, uint128 liquidity, SwapParams calldata sp)
        internal
        view
        returns (uint160 next)
    {
        if (liquidity == 0) return sqrtP;
        try this.stepSqrtPrice(sqrtP, liquidity, sp.amountSpecified, sp.zeroForOne) returns (uint160 n) {
            next = n;
        } catch {
            next = sp.sqrtPriceLimitX96;
        }
        if (sp.zeroForOne) return next < sp.sqrtPriceLimitX96 ? sp.sqrtPriceLimitX96 : next;
        return next > sp.sqrtPriceLimitX96 ? sp.sqrtPriceLimitX96 : next;
    }

    // Uniswap sqrt price to quote-per-stock at 1e18, computed per orientation so extremes saturate.
    function _price(uint160 sqrtP) internal view returns (uint256) {
        if (!stockIsToken1) {
            uint256 pX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), C.Q96);
            return FullMath.mulDiv(pX96, C.ONE * scale0, C.Q96 * scale1);
        }
        if (sqrtP == 0) return type(uint256).max;
        uint256 inv = FullMath.mulDiv(C.Q96, C.Q96, uint256(sqrtP));
        return FullMath.mulDiv(inv, C.ONE * scale1, uint256(sqrtP) * scale0);
    }

    // Pool vs reference at 1e18; negative means below; capped at MAX_DEV.
    function _dev(uint256 pool, uint256 ref) internal pure returns (int256) {
        if (ref == 0) return 0;
        if (pool / ref > C.MAX_DEV / C.ONE) return int256(C.MAX_DEV);
        return int256(FullMath.mulDiv(pool, C.ONE, ref)) - int256(C.ONE);
    }

    // A token's decimals, so _price can normalise to 1e18.
    function _decimals(Currency c) internal view returns (uint8) {
        return IERC20Metadata(Currency.unwrap(c)).decimals();
    }
}