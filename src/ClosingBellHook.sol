// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMarketStateAdapter, MarketState, Session} from "./IMarketStateAdapter.sol";
import {Constants as C} from "./Constants.sol";
import {FeeCurve} from "./FeeCurve.sol";
import {MarketHours} from "./MarketHours.sol";

/// @notice A Uniswap v4 hook that protects LPs in tokenized-stock pools by raising the swap fee
///         when the stock market is closed or the pool has drifted from the reference price,
///         instead of halting the pool.
///
/// One hook serves one pool. Everything is fixed in the constructor. The swap path writes
/// nothing. Each swap, the hook answers one question: what should this trade cost right now?
contract ClosingBellHook is BaseOverrideFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    error InvalidParams();
    error WrongPool();
    error PriceMismatch(); // pool initialized more than 10x away from the reference: wrong side or wrong decimals

    IMarketStateAdapter public immutable adapter;
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    bool public immutable stockIsToken1; // true for every AAPL/USDG pool: USDG's address sorts lower
    uint256 internal immutable scale0; // 10^decimals of each token, to read the pool price in human units
    uint256 internal immutable scale1;

    FeeCurve.Params internal P; // the creator's fee settings; a struct cannot be immutable, so set once here

    constructor(
        IPoolManager poolManager_,
        IMarketStateAdapter adapter_,
        FeeCurve.Params memory p,
        PoolKey memory key,
        bool stockIsToken1_
    ) BaseHook(poolManager_) {
        if (!FeeCurve.validate(p)) revert InvalidParams();
        if (!key.fee.isDynamicFee()) revert InvalidParams(); // a static-fee key could never initialize with this hook
        P = p;
        adapter = adapter_;
        currency0 = key.currency0;
        currency1 = key.currency1;
        poolFee = key.fee;
        tickSpacing = key.tickSpacing;
        stockIsToken1 = stockIsToken1_;
        uint8 d0 = _decimals(key.currency0);
        uint8 d1 = _decimals(key.currency1);
        if ((d0 > d1 ? d0 - d1 : d1 - d0) > 18) revert InvalidParams(); // keeps the price math overflow-free
        scale0 = 10 ** d0;
        scale1 = 10 ** d1;
    }

    /// @notice What this swap would be charged right now.
    function quoteFee(SwapParams calldata params) external view returns (uint24) {
        return _fee(params);
    }

    /// @notice The creator's fee settings.
    function feeParams() external view returns (FeeCurve.Params memory) {
        return P;
    }

    // ── hook callbacks ──────────────────────────────────────────────────────

    /// @dev Only the pool this hook was built for may use it. Otherwise anyone could attach an
    ///      unrelated pool to a hook whose oracle is, say, AAPL. Also refuses a starting price more
    ///      than 10x off the reference: that is how a wrong `stockIsToken1` or decimals shows up,
    ///      and once initialized it is immutable. Skipped if the feed is down at initialization.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        bytes4 sel = super._afterInitialize(sender, key, sqrtPriceX96, tick);
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1) || key.fee != poolFee
                || key.tickSpacing != tickSpacing
        ) revert WrongPool();
        (uint256 ref,) = _references(_market());
        if (ref != 0) {
            uint256 pool = _price(sqrtPriceX96);
            if (pool > ref * 10 || pool * 10 < ref) revert PriceMismatch();
        }
        return sel;
    }

    function _getFee(address, PoolKey calldata, SwapParams calldata params_, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _fee(params_);
    }

    // ── the fee ─────────────────────────────────────────────────────────────

    /// @dev fee = floor(session) x staleness x deviation, capped. The cheap floors require a
    ///      reference the hook can actually use: a feed that says "live" but prints 0 gets the
    ///      closed floor like a dead one.
    function _fee(SwapParams calldata sp) internal view returns (uint24) {
        FeeCurve.Params memory p = P;
        MarketState memory m = _market();
        (uint256 ref, uint256 prevRef) = _references(m);
        (Session s, uint256 lastClose) = MarketHours.calendar(block.timestamp);

        uint24 floorFee = FeeCurve.floorFor(p, s, m.isLive && ref != 0);
        uint256 staleM = FeeCurve.stalenessMult(p, s, lastClose, block.timestamp);
        uint256 devM = ref == 0 ? C.ONE : _deviationMult(p, ref, prevRef, sp);
        return FeeCurve.computeFee(p, floorFee, staleM, devM);
    }

    /// @dev Read the oracle. The adapter promises never to revert; if it does anyway, treat it as
    ///      a dead feed (zero struct: not live, no price) rather than block the swap.
    function _market() internal view returns (MarketState memory m) {
        try adapter.getMarketState() returns (MarketState memory s) {
            m = s;
        } catch {}
    }

    /// @dev How far the pool is from the reference, and whether this swap helps or hurts.
    function _deviationMult(FeeCurve.Params memory p, uint256 ref, uint256 prevRef, SwapParams calldata sp)
        internal
        view
        returns (uint256)
    {
        (uint256 pre, uint256 post) = _poolPrices(sp);

        bool refMoved = FeeCurve.referenceMoved(pre, ref, prevRef);
        int256 preDev = _dev(pre, ref);
        int256 postDev = _dev(post, ref);
        bool restoring = FeeCurve.isRestoring(preDev, postDev, refMoved);
        return FeeCurve.deviationMult(p, FeeCurve.abs(preDev), FeeCurve.abs(postDev), restoring);
    }

    /// @dev Current and previous reference price, as quote-per-stock. 0 means "not usable".
    function _references(MarketState memory m) internal pure returns (uint256 ref, uint256 prevRef) {
        if (m.price == 0) return (0, 0);
        if (!m.hasQuoteFeed) return (m.price, m.prevPrice);
        if (m.quotePrice == 0) return (0, 0);
        ref = FullMath.mulDiv(m.price, C.ONE, m.quotePrice);
        prevRef = (m.prevPrice == 0 || m.prevQuotePrice == 0) ? 0 : FullMath.mulDiv(m.prevPrice, C.ONE, m.prevQuotePrice);
    }

    /// @dev The pool's price now, and where this swap would leave it.
    function _poolPrices(SwapParams calldata sp) internal view returns (uint256 pre, uint256 post) {
        PoolKey memory key = PoolKey(currency0, currency1, poolFee, tickSpacing, this);
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        pre = _price(sqrtP);
        post = _price(_estimatePostSqrtPrice(sqrtP, liquidity, sp));
    }

    /// @dev Turn Uniswap's sqrtPriceX96 into quote-per-stock, 1e18 units, whichever side the stock
    ///      is on. Computed directly in each orientation rather than by inverting a truncated
    ///      intermediate, so an extreme sqrtPrice (a trader's price limit) reads as a huge
    ///      deviation, never as zero.
    function _price(uint160 sqrtP) internal view returns (uint256) {
        if (!stockIsToken1) {
            uint256 pX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), C.Q96); // token1 per token0
            return FullMath.mulDiv(pX96, C.ONE * scale0, C.Q96 * scale1);
        }
        if (sqrtP == 0) return type(uint256).max;
        uint256 inv = FullMath.mulDiv(C.Q96, C.Q96, uint256(sqrtP)); // token0 per token1, X96
        return FullMath.mulDiv(inv, C.ONE * scale1, uint256(sqrtP) * scale0);
    }

    /// @dev Estimate the price after the swap, treating current liquidity as if it covered the whole
    ///      move (Uniswap's own formula). Clamped to the trader's price limit, which binds on the
    ///      real swap too. If the estimate fails - e.g. asking for more output than exists - use the
    ///      limit itself, the most pessimistic reading.
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

    /// @dev Public only so it can sit behind try/catch above; Uniswap's math reverts on impossible amounts.
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

    /// @dev (pool - ref) / ref, signed. Negative means the pool is below the reference. Saturates at
    ///      MAX_DEV before any multiplication, so no pool price can make it revert.
    function _dev(uint256 pool, uint256 ref) internal pure returns (int256) {
        if (pool / ref > C.MAX_DEV / C.ONE) return int256(C.MAX_DEV);
        return int256(FullMath.mulDiv(pool, C.ONE, ref)) - int256(C.ONE);
    }

    function _decimals(Currency c) internal view returns (uint8) {
        if (Currency.unwrap(c) == address(0)) return 18;
        return IERC20Metadata(Currency.unwrap(c)).decimals();
    }
}
