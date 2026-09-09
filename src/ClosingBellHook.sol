// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMarketStateAdapter, MarketState} from "./IMarketStateAdapter.sol";
import {Constants as C} from "./Constants.sol";
import {FeeCurve} from "./FeeCurve.sol";
import {MarketHours, Session} from "./MarketHours.sol";

/// @notice A pool holding tokenized Apple sits at Friday's price all weekend. If Apple gaps up on
///         Monday, the first trader through takes the difference out of the liquidity providers.
///         Most designs switch the pool off. This one raises the price of that trade instead, so
///         the pool keeps working for everyone else and LPs get paid for the risk.
/// @dev One hook per pool, all settings fixed at deployment, no storage written on the swap path.
contract ClosingBellHook is BaseOverrideFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    error InvalidParams();
    error WrongPool();
    error PriceMismatch(); // pool opened nowhere near the stock's price: misconfigured

    IMarketStateAdapter public immutable adapter;
    PoolId public immutable poolId; // the one pool this hook serves
    bool public immutable stockIsToken1; // which of the pool's two tokens is the stock
    uint256 internal immutable scale0; // each token's decimals, so prices read in dollars
    uint256 internal immutable scale1;

    FeeCurve.Params internal P; // the fee settings; Solidity cannot mark a struct immutable

    constructor(
        IPoolManager poolManager_,
        IMarketStateAdapter adapter_,
        FeeCurve.Params memory p,
        PoolKey memory key,
        bool stockIsToken1_
    ) BaseHook(poolManager_) {
        if (!FeeCurve.validate(p)) revert InvalidParams();
        if (!key.fee.isDynamicFee()) revert InvalidParams(); // the pool must allow a changing fee
        if (address(adapter_).code.length == 0) revert InvalidParams(); // no going back, so check now
        P = p;
        adapter = adapter_;
        // A pool's id hashes its settings, this hook's address included. Fill ours in rather than
        // trust what was passed, so a deploy script with that field wrong cannot brick the hook.
        key.hooks = IHooks(address(this));
        poolId = key.toId();
        stockIsToken1 = stockIsToken1_;
        uint8 d0 = _decimals(key.currency0);
        uint8 d1 = _decimals(key.currency1);
        // Dollar tokens usually use 6 decimal places, stock tokens 18. Too big a difference
        // either way and the price maths overflows.
        if (d0 > 24 || d1 > 24 || (d0 > d1 ? d0 - d1 : d1 - d0) > 18) revert InvalidParams();
        scale0 = 10 ** d0;
        scale1 = 10 ** d1;
    }

    /// @notice What this swap would cost right now. Free to call.
    function quoteFee(SwapParams calldata params) external view returns (uint24) {
        return _fee(params);
    }

    /// @notice The fee settings this hook was deployed with.
    function feeParams() external view returns (FeeCurve.Params memory) {
        return P;
    }

    // ── hook callbacks ──────────────────────────────────────────────────────

    /// @dev Runs once, when the pool is created. Refuses any pool but its own, so nobody can point
    ///      an unrelated pool at a hook watching Apple, and refuses a starting price nowhere near
    ///      the stock's, which is what a misconfigured deploy looks like and cannot be undone.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        bytes4 sel = super._afterInitialize(sender, key, sqrtPriceX96, tick);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        (uint256 ref,,) = _references(_market());
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

    /// @dev The fee decision. Cheap rates need a usable price, so a feed that claims to work but
    ///      reports nothing is treated as broken.
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

    /// @dev Asks the oracle for prices. Solidity's usual try/catch still crashes if the reply is
    ///      the wrong shape, and a crash here would freeze every swap, so we check the reply's size
    ///      and read it by hand. Anything unexpected reads as a broken feed.
    ///      If MarketState gains a field, the 256 below must change too.
    function _market() internal view returns (MarketState memory m) {
        (bool ok, bytes memory r) = address(adapter).staticcall(abi.encodeCall(IMarketStateAdapter.getMarketState, ()));
        if (!ok || r.length != 256) return m;
        uint256[8] memory w = abi.decode(r, (uint256[8]));
        m.isLive = w[0] != 0;
        m.price = w[1];
        m.loPrice = w[2];
        m.hiPrice = w[3];
        m.hasQuoteFeed = w[4] != 0;
        m.quotePrice = w[5];
        m.loQuotePrice = w[6];
        m.hiQuotePrice = w[7];
    }

    /// @dev How far the pool is from the reference, and whether this swap helps or hurts.
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
        return FeeCurve.deviationMult(p, FeeCurve.abs(preDev), FeeCurve.abs(postDev), restoring);
    }

    /// @dev The stock's real price and recent range, in the units the pool quotes. Zero means
    ///      nothing usable. A pool priced in something other than dollars divides the two feeds,
    ///      and takes the widest range they could have produced, so a move in one leg while the
    ///      other sits still is not mistaken for pool drift.
    function _references(MarketState memory m) internal pure returns (uint256 ref, uint256 lo, uint256 hi) {
        if (m.price == 0) return (0, 0, 0);
        if (!m.hasQuoteFeed) return (m.price, m.loPrice, m.hiPrice);
        if (m.quotePrice == 0) return (0, 0, 0);
        ref = _ratio(m.price, m.quotePrice);
        if (ref == 0) return (0, 0, 0);
        if (m.loPrice == 0 || m.loQuotePrice == 0) return (ref, 0, 0);
        lo = _ratio(m.loPrice, m.hiQuotePrice);
        hi = _ratio(m.hiPrice, m.loQuotePrice);
    }

    /// @dev One price over another; 0 rather than a failure if the answer is too big.
    function _ratio(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0 || a / b >= type(uint256).max / C.ONE) return 0;
        return FullMath.mulDiv(a, C.ONE, b);
    }

    /// @dev The pool's price now, and where this swap would leave it. Both matter: a trade is
    ///      charged on the wider of the two gaps.
    function _poolPrices(SwapParams calldata sp) internal view returns (uint256 pre, uint256 post) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        pre = _price(sqrtP);
        post = _price(_estimatePostSqrtPrice(sqrtP, liquidity, sp));
    }

    /// @dev Uniswap's internal price format into plain dollars per share. The stock can be either
    ///      of the two tokens, so there are two versions. Each is worked out directly rather than
    ///      by flipping the other, because flipping a rounded number can turn a very high price
    ///      into zero, which reads as the opposite of the truth.
    function _price(uint160 sqrtP) internal view returns (uint256) {
        if (!stockIsToken1) {
            uint256 pX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), C.Q96); // token1 per token0
            return FullMath.mulDiv(pX96, C.ONE * scale0, C.Q96 * scale1);
        }
        if (sqrtP == 0) return type(uint256).max;
        uint256 inv = FullMath.mulDiv(C.Q96, C.Q96, uint256(sqrtP)); // token0 per token1, X96
        return FullMath.mulDiv(inv, C.ONE * scale1, uint256(sqrtP) * scale0);
    }

    /// @dev Where this swap would push the price, by Uniswap's own formula. Never past the
    ///      trader's price limit, which caps the real swap too. If the sum cannot be done, say the
    ///      trade asks for more than the pool holds, assume the worst case: that limit.
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

    /// @dev Split out so the call above can catch it failing. Uniswap's maths rejects impossible
    ///      trade sizes, and that must not block the swap.
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

    /// @dev How far the pool is from the real price. Negative means below. Pinned at a ceiling
    ///      first, so no price can make it fail.
    function _dev(uint256 pool, uint256 ref) internal pure returns (int256) {
        if (pool / ref > C.MAX_DEV / C.ONE) return int256(C.MAX_DEV);
        return int256(FullMath.mulDiv(pool, C.ONE, ref)) - int256(C.ONE);
    }

    /// @dev A token's decimal places. Native ETH does not report any, and uses 18.
    function _decimals(Currency c) internal view returns (uint8) {
        if (Currency.unwrap(c) == address(0)) return 18;
        return IERC20Metadata(Currency.unwrap(c)).decimals();
    }
}
