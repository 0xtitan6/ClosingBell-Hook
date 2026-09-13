# Feedback to Uniswap — building ClosingBell on v4

ETHOnline 2026, Uniswap Foundation track. Hook: [`src/ClosingBellHook.sol`](src/ClosingBellHook.sol).
Built with v4-core, v4-periphery, and OpenZeppelin's `uniswap-hooks`; tested against the live
PoolManager on Robinhood Chain (chain 4663).

## What worked well

- **`BaseOverrideFee` is the right abstraction.** A dynamic-fee hook reduces to one function,
  `_getFee`. Permissions, the override flag, and the `beforeSwap` plumbing are handled. The hook
  is 200 lines and most of that is oracle handling, not v4 wiring.
- **The math libraries cover everything.** `FullMath.mulDiv`, `SqrtPriceMath.getNextSqrtPriceFrom*`,
  `StateLibrary.getSlot0/getLiquidity`, `LPFeeLibrary`. Estimating a post-swap price for
  size-aware fees needed no custom arithmetic.
- **`deployCodeTo` + flag bits in tests, `HookMiner` for deploys.** Once understood, hook
  addressing is a non-issue.
- **v4 test routers (`PoolSwapTest`, `PoolModifyLiquidityTest`)** made a fork demo against the real
  PoolManager possible in an afternoon, without touching the chain's modified UniversalRouter.

## What cost time

1. **Non-canonical PoolManager.** Robinhood Chain's PoolManager
   (`0x8366a39CC670B4001A1121B8F6A443A643e40951`) is not on the deployments page. I verified it
   from bytecode and by recomputing all 25,139 poolIds from their PoolKeys. A deployments entry,
   or a note that some chains run their own, would save every builder on that chain a day.

2. **The fee ceiling is `MAX_LP_FEE − 2`, not `− 1`.** `ProtocolFeeLibrary.calculateSwapFee` is
   `p + lp − p·lp/1e6`, so an LP fee of 999,999 compounds to exactly 100% with any protocol fee,
   and exact-output swaps revert. The only place this is written down is a comment in the
   StablePair hook's source. It belongs in the dynamic-fee docs.

3. **No guidance on reading an oracle from a hook without being able to brick the pool.**
   `try/catch` does not catch a decode failure in the caller, and a decode failure in `beforeSwap`
   freezes every swap on the pool. The safe pattern (raw `staticcall`, check `returndata.length`,
   decode words by hand) is not obvious and I expect many oracle-reading hooks to get it wrong.
   A short "hooks that read external contracts" section would prevent a class of production bugs.

4. **Hook reverts are wrapped (ERC-7751).** Asserting that `initialize` failed *because the hook
   reverted with X* takes a nested `abi.encodeWithSelector(CustomRevert.WrappedError.selector, …)`.
   A test helper in `v4-core/test/utils` for "expect this hook error" would remove the boilerplate.

5. **`beforeSwap` runs before the PoolManager validates `sqrtPriceLimitX96`.** A hook that prices
   off the trader's limit sees out-of-range limits that v4 will reject a few lines later. Not a
   bug, but worth a sentence in the hook docs so authors clamp defensively.

6. **`IDynamicFeeHook.getFee(key)` (from StablePair) assumes size-independent fees.** Hooks that
   price on swap size — which the size-blind-first-swap problem forces — can't implement it
   honestly. If that interface becomes the standard, a variant that takes `SwapParams` would let
   routers quote size-aware hooks.

## Suggestions

- Add a **dynamic-fee hooks checklist** to the docs: fee units are pips; cap at `MAX_LP_FEE − 2`;
  `beforeSwap` must never revert for oracle reasons; clamp price limits; one hook per pool vs
  per-pool config tradeoffs.
- List **non-canonical deployments** (or state that they exist) on the deployments page.
- A **`HookTestUtils`** with `expectHookRevert(hook, selector, innerError)`.
- The StablePair blog post was the single most useful document during the build, because it shows
  a complete, audited, production dynamic-fee hook with its reasoning. More of those, for other
  hook categories, would be worth more than reference snippets.

## What I'd want from Uniswap for this project specifically

Routing. Dynamic-fee hooks need Uniswap Labs allowlisting before the app routes through them.
For a hook whose whole point is that the fee is *different at different times*, being visible in
the router's quotes is what makes it usable by ordinary traders, not just integrators. A published
path for getting a hook reviewed and allowlisted would change what's worth building.
