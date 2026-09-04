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

No `afterSwap`. No deltas taken. `afterInitialize` is claimed only to enforce the dynamic-fee flag
and to reject pools this hook was not configured for. The hook never holds funds and never blocks
a swap — see the adapter totality contract in §4.

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
- internals: `_isDST`, `_dayOfWeek`, `_isHoliday`, and the holiday table as data — a **packed
  bitmap indexed by day-number** or a binary search, never a linear scan: this runs on every swap
  in the pool, forever

Half-days are in scope (the live prior art does not model them; see `prior-art-fables.md`).

### `FeeCurve.sol` — pure
- `Params` — the creator-set surface (README "Parameters")
- `floorFor(Params, Session, bool isLive) → uint24`
- `stalenessMult(Params, updatedAt, nowTs) → uint256` (1e18)
- `isRestoring(preDev, postDev, refMoved) → bool` — the signed rule, **restricted to pool-created
  deviation**. Arbitrage toward a reference that just moved is definitionally restoring, so an
  unrestricted rule exempts the exact trade the hook exists to price (see `pre-build-review.md` §0).
  Deviation the reference created is charged `f(·)`; deviation the pool created keeps the exemption
- `deviationMult(Params, postDev, bool restoring) → uint256`
- `decayedDeviationMult(Params, rawMult, freshSince, nowTs) → uint256`
- `computeFee(...) → uint24` — single entry point composing `min(floor × s × d, cap)`

### `IMarketStateAdapter.sol`
- `getMarketState() → MarketState`

**Contract: `getMarketState()` is total. It must never revert.** This is the interface's central
guarantee, not an implementation detail — the hook's whole claim is that it never blocks a swap, and
an adapter that reverts on a deprecated feed, a paused aggregator, or a changed token ABI would
brick every swap in the pool, permanently, precisely when the feed is least healthy. Any failure
resolves to `isLive = false`, which already has a defined regime: highest floor, pool open.

No `warmMultiplier()`. The day-1 measurement showed the Chainlink price and the pool price are
both denominated per-token, so no `uiMultiplier()` read and no transient cache are needed
(`verified-onchain.md` §4). This removes an external call from every swap.

### `ChainlinkEquityAdapter.sol`
- `constructor(stockFeed, quoteFeed, stockToken, maxStaleness, plausibilityBps)` — all immutable
- `getMarketState()` — every external call wrapped in `try/catch`; failure → `isLive = false`
- internals: `_readFeed(feed) → (price, updatedAt, ok)`, `_isPlausible(price)`

Guard the no-code case explicitly (`feed.code.length == 0` returns success with empty returndata).
On a failed read, return the **last known good price**, not zero — a frozen feed should still be
deviated against its last real reference, which is exactly the weekend case. Zero only when the
adapter has never seen a good price, and the hook must then price on floor x staleness alone.

`quoteFeed == address(0)` for dollar-quote pools; set for stock/SPY, where deviation compares the
pool ratio to `stockFeed / quotePrice` and `isLive` gains a quote-freshness term.

### `ClosingBellHook.sol` — `is BaseOverrideFee`
- `constructor(poolManager, adapter, params, currency0, currency1, fee, tickSpacing)` — all `immutable`
- `_getFee(sender, key, params, hookData) → uint24` — the only abstract function of the base
- `_afterInitialize(...)` — `super` (the `NotDynamicFee` check), then reject any pool whose key does
  not match the four configured components
- internals: `_poolPrice(poolId)` (decimals-normalized from `sqrtPriceX96`),
  `_estimatePostSwapPrice(sqrtPriceX96, liquidity, amountSpecified, zeroForOne)`

`getHookPermissions()` and `_beforeSwap` are inherited; do not override them.

**One hook instance per pool, parameters `immutable` in the constructor.** Two reasons. First,
pool creation is permissionless: without a check, anyone can initialize a `JUNK/WETH` pool pointing
at this hook, and the adapter — bound to one stock feed — would compute a deviation between an
unrelated pool and AAPL. Second, `IPoolManager.initialize(PoolKey, uint160)` takes **no `hookData`
at all**, so no parameters can ride through initialization; the alternatives are constructor
immutability or a write-once registry, and the registry is both weaker (storage, not `immutable` —
the exact property claimed against the admin-mutable prior art) and front-runnable by anyone who can
predict the `PoolKey`.

The apparent circularity — `poolId` depends on the hook address, which depends on the constructor
args — is avoided by storing `currency0/currency1/fee/tickSpacing` rather than `poolId`. `hooks` is
necessarily `address(this)`, so checking those four is equivalent and has no dependency loop.

Rejecting in `_afterInitialize` reverts the whole `initialize` transaction, so the pool never comes
into existence with this hook. No `beforeInitialize` bit is needed.

---

## 5. State

The hook is almost stateless. It holds one mutable value:

**Target: none.** The hook should hold no mutable state on the swap path.

The r5 design implied a `freshSince[poolId]` marking the feed's stale to fresh transition, to drive
post-open decay. Two problems: it is written on the permissionless swap path, so an attacker chooses
when the decay window falls; and decaying `deviationMult` toward 1.0 cannot make a restoring trade
cheaper than the 1.0 it already pays, so the window's stated purpose is not what it does. Derive the
decay window from the calendar instead, and repoint it at the reference-jump surcharge that F1
introduces. That removes the only SSTORE from `beforeSwap`.

Per-pool configuration is constructor-set and `immutable` (see §6), so it is code, not storage.

---

## 6. Uniswap v4 integration points

**Inherit `BaseOverrideFee`** (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol`). It is exactly this
hook's shape: `_getFee` is the only abstract function, the base performs the `OVERRIDE_FEE_FLAG` OR,
and `_afterInitialize` already enforces `key.fee.isDynamicFee()`. That removes integration point 2
below as a class of bug rather than as a thing to remember.

1. **Pool initialization.** The pool's `PoolKey.fee` must be `LPFeeLibrary.DYNAMIC_FEE_FLAG`
   (`0x800000`). A static-fee pool ignores the returned `uint24` entirely. `BaseOverrideFee`
   reverts `NotDynamicFee` if you get this wrong.
2. **Fee override.** Return `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG` (`0x400000`). Returning a bare
   fee is **not** a fallback to some stored default — `LPFeeLibrary.getInitialLPFee` returns **0**
   for dynamic-fee pools and the hook never calls `updateDynamicLPFee`, so the swap executes at
   **zero LP fee**. Worst-case silent failure; handled inside `BaseOverrideFee`.
3. **Units are pips (1e-6), not bps.** `MAX_LP_FEE = 1_000_000` = 100%. A `feeCap` of 300–500 bps
   is `30_000–50_000`. `removeOverrideFlagAndValidate` **reverts** `LPFeeTooLarge` rather than
   clamping, so a 100x units slip bricks every swap in the pool. Annotate units on every `FeeCurve`
   signature and fuzz `fee <= MAX_LP_FEE`.
4. **Hook address.** v4 encodes permissions in the low 14 bits. `BaseOverrideFee` forces
   `afterInitialize` + `beforeSwap` = `1<<12 | 1<<7` = **`0x1080`** — mined with CREATE2 via
   `HookMiner`, which lives in **`@uniswap/v4-periphery/src/utils/HookMiner.sol`** (already imported
   correctly by `script/testing/00_DeployV4.s.sol`). CREATE2 deployer
   `0x4e59b44847b379578588920cA78FbF26c0B4956C`. Mining cost is flat in the number of flags —
   `HookMiner` tests equality across all 14 masked bits — so there is no reason to economize.
   Note `0x1080` differs from every Fables RWA hook (`…080`), which are `beforeSwap`-only.
5. **Pool state reads.** `StateLibrary.getSlot0` / `getLiquidity` against the PoolManager, via
   `extsload`. `POOLS_SLOT = 6`. `Pool.swap` snapshots `slot0Start` and does not write back until
   after `beforeSwap` returns, so the estimator reads genuine pre-swap state. Budget ~2.6k gas;
   the oracle calls and the calendar lookup are where gas actually goes.

**Do not add `beforeInitialize`.** `BaseHook._beforeInitialize` reverts `HookNotImplemented()`, so
claiming the bit without overriding the function makes every pool initialization revert.

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

1. `IMarketStateAdapter.sol` — types first; everything imports them, and its totality contract is
   what the adapter is later written against
2. `MarketHours.sol` + unit tests — zero dependencies, nothing can block it
3. `FeeCurve.sol` + unit tests — the mechanism; the file to write by hand
4. Mock adapter + `ClosingBellHook.sol` + integration tests
5. `ChainlinkEquityAdapter.sol` — last, because it is the only piece gated on external facts
   (all of which are now verified: `verified-onchain.md`)

Arithmetic is borrowed, not written: `FullMath.mulDiv` for every multiply-divide,
`LPFeeLibrary` for fee units. Only the policy is original.
