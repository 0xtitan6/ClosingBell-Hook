# Architecture

How ClosingBell is put together, why it is split this way, and what each piece owes the others.
Spec is `proposal.md` (r6). On-chain facts referenced here are verified in `verified-onchain.md`.

---

## 1. One swap, end to end

```
  trader ──► UniversalRouter / test router ──► PoolManager.swap()
                                                     │
                                                     │ pool was initialized with
                                                     │ fee = DYNAMIC_FEE_FLAG (0x800000)
                                                     │ and hooks = ClosingBellHook
                                                     ▼
                                        ClosingBellHook._beforeSwap()
                                                     │
                    ┌────────────────────────────────┼────────────────────────────────┐
                    ▼                                ▼                                ▼
        IMarketStateAdapter               StateLibrary.getSlot0            SwapParams
        .getMarketState()                 + getLiquidity                   (zeroForOne,
                    │                          (this pool)                  amountSpecified)
                    │                                │                                │
        session, isLive, price,            pool price (pre)                           │
        updatedAt, quotePrice                        │                                │
                    │                                └──────────┬─────────────────────┘
                    │                                           ▼
                    │                              estimated post-swap price
                    │                            (constant-liquidity approximation)
                    └───────────────────┬───────────────────────┘
                                        ▼
                                   FeeCurve
                    floor(session, isLive) × stalenessMult × deviationMult
                              (deviationMult decayed post-open)
                                   → min(…, feeCap)
                                        │
                                        ▼
                    return (selector, ZERO_DELTA, fee | OVERRIDE_FEE_FLAG)
                                        │
                                        ▼
                            swap executes at the computed fee
```

No `afterSwap`. No deltas taken. The hook never holds funds and never blocks a swap.

---

## 2. Components

| File | Kind | Responsibility |
|---|---|---|
| `ClosingBellHook.sol` | hook contract | Orchestration only: gather inputs, call `FeeCurve`, return the override |
| `FeeCurve.sol` | pure library | All fee math: floors, staleness, signed deviation, decay, cap |
| `MarketHours.sol` | pure library | Timestamp → `Session`. Calendar only |
| `IMarketStateAdapter.sol` | interface + types | The oracle seam. Owns the `Session` enum and `MarketState` struct |
| `ChainlinkEquityAdapter.sol` | contract | v1 oracle: Data Feeds, liveness predicate, optional quote leg |
| `Constants.sol` | library | Verified chain-4663 addresses |

**Why the split.** The two libraries are `pure`, so the mechanism is unit-testable with no chain,
no mocks and no fork — that is where the correctness risk lives, and it is where tests are
cheapest. The hook is deliberately thin: if logic accumulates there, it belongs in `FeeCurve`.
The adapter quarantines every external call.

---

## 3. The seam

`IMarketStateAdapter` is the load-bearing architectural decision. The hook consumes a struct and
never learns how it was produced:

```solidity
enum Session { Regular, Extended, Overnight, Closed }

struct MarketState {
    Session session;
    bool    isLive;        // calendarOpen && fresh && plausible && (quote fresh) && !oraclePaused
    uint256 price;         // stock reference, 1e18
    uint256 updatedAt;     // last authoritative print for the stock feed
    bool    hasQuoteFeed;  // true for non-dollar quote legs (stock/SPY)
    uint256 quotePrice;    // meaningful only when hasQuoteFeed
}
```

This is what makes the production story true rather than aspirational: a Data Streams adapter
decoding `marketStatus` replaces `ChainlinkEquityAdapter` without touching the hook, the fee
curve, or any test of either. It is also what lets the whole hook be tested against a mock
before a single real feed address is used.

`Session` and `MarketState` live in the interface file, not in `MarketHours`, because both the
calendar library and the adapter need them — defining them anywhere else creates a circular
import. Decide this first; everything else follows from it.

---

## 4. Function inventory

### `MarketHours.sol` — pure
- `sessionAt(uint256 tsUTC) → Session` — UTC→ET with US DST, weekday, session windows, holiday table
- `calendarOpen(uint256) → bool` — `sessionAt(ts) != Closed`
- internals: `_isDST`, `_dayOfWeek`, `_isHoliday`, and the holiday table as data

Half-days are in scope (the live prior art does not model them; see `prior-art-fables.md`).

### `FeeCurve.sol` — pure
- `Params` — the creator-set surface (README "Parameters")
- `floorFor(Params, Session, bool isLive) → uint24`
- `stalenessMult(Params, updatedAt, nowTs) → uint256` (1e18)
- `isRestoring(preDev, postDev) → bool` — r5 signed rule: `|post−ref| < |pre−ref|`
- `deviationMult(Params, postDev, bool restoring) → uint256`
- `decayedDeviationMult(Params, rawMult, freshSince, nowTs) → uint256`
- `computeFee(...) → uint24` — single entry point composing `min(floor × s × d, cap)`

### `IMarketStateAdapter.sol`
- `getMarketState() → MarketState`

No `warmMultiplier()`. The day-1 measurement showed the Chainlink price and the pool price are
both denominated per-token, so no `uiMultiplier()` read and no transient cache are needed
(`verified-onchain.md` §4). This removes an external call from every swap.

### `ChainlinkEquityAdapter.sol`
- `constructor(stockFeed, quoteFeed, stockToken, maxStaleness, plausibilityBps)` — all immutable
- `getMarketState()`
- internals: `_readFeed(feed) → (price, updatedAt, ok)`, `_isPlausible(price)` vs `lastKnownPrice`

`quoteFeed == address(0)` for dollar-quote pools; set for stock/SPY, where deviation compares the
pool ratio to `stockFeed / quotePrice` and `isLive` gains a quote-freshness term.

### `ClosingBellHook.sol`
- `constructor(poolManager, adapter, params)`
- `getHookPermissions()` — `beforeSwap: true`, everything else false
- `_beforeSwap(...) → (bytes4, BeforeSwapDelta, uint24)`
- internals: `_poolPrice(poolId)` (decimals-normalized from `sqrtPriceX96`),
  `_estimatePostSwapPrice(sqrtPriceX96, liquidity, amountSpecified, zeroForOne)`

---

## 5. State

The hook is almost stateless. It holds one mutable value:

**`freshSince[poolId]`** — the timestamp at which the feed last transitioned stale → fresh.

Post-open decay blends `deviationMult` toward 1.0 over `decayWindow`, and a pure library cannot
know when the feed woke up. Something must observe the transition and record it. It lives in the
hook rather than the adapter because it is per-pool, and one adapter may serve several pools.

This is the only storage write on the swap path. Everything else is immutable config or a read.

---

## 6. Uniswap v4 integration points

Four, and three of them are conventions you cannot derive:

1. **Pool initialization.** The pool's `PoolKey.fee` must be `LPFeeLibrary.DYNAMIC_FEE_FLAG`
   (`0x800000`). A static-fee pool ignores the returned `uint24` entirely.
2. **Fee override.** Return `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG` (`0x400000`). Returning a bare
   fee is a **silent no-op** — the pool falls back to its stored dynamic fee. `feeCap` ≤ 500bps
   sits far below the flag bits, so the OR can never corrupt the value.
3. **Hook address.** v4 encodes permissions in the low 14 bits of the hook address. `beforeSwap`
   only = bit 7 = `0x0080`, so the deployed address must end in those bits — mined with CREATE2
   (`HookMiner`, from the `hookmate` dependency). Every Fables RWA hook ends `…080` for the same
   reason.
4. **Pool state reads.** `StateLibrary.getSlot0` / `getLiquidity` against the PoolManager, via
   `extsload`. `POOLS_SLOT = 6`.

---

## 7. Testing architecture

```
unit  ─ MarketHours.t.sol   pure, no chain            (calendar, DST, holidays, half-days)
      ─ FeeCurve.t.sol      pure, no chain            (floors, ramps, signed rule, decay, cap)
      │
integ ─ ClosingBellHook.t.sol + MockMarketStateAdapter (canned MarketState → full hook path)
      │
fork  ─ real Chainlink feeds on chain 4663            (adapter liveness, weekend simulation,
                                                       single optimally-sized arb, LP retention)
```

The mock adapter is what lets the hook be finished and tested before the fork tests exist —
and it is why the adapter is the last contract built, not the first.

Swaps in tests route through the PoolManager or the v4 test router only. Robinhood Chain's
UniversalRouter is a modified fork and is out of scope.

---

## 8. Build order

Dependency order, which is also risk order:

1. `IMarketStateAdapter.sol` — types first; everything imports them
2. `MarketHours.sol` + unit tests — zero dependencies, nothing can block it
3. `FeeCurve.sol` + unit tests — the mechanism; the file to write by hand
4. Mock adapter + `ClosingBellHook.sol` + integration tests
5. `ChainlinkEquityAdapter.sol` — last, because it is the only piece gated on external facts
   (all of which are now verified: `verified-onchain.md`)

Arithmetic is borrowed, not written: `FullMath.mulDiv` for every multiply-divide,
`LPFeeLibrary` for fee units. Only the policy is original.
