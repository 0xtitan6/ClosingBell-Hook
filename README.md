# ClosingBell Hook

**A Uniswap v4 hook that protects LPs in tokenized-stock pools by pricing fees off the underlying market's trading calendar and reference-price staleness, jointly, while keeping the pool open.**

Built for [ETHOnline 2026](https://ethglobal.com/events/ethonline2026) (Sept 4–16). Uniswap Foundation track: Best Uniswap Stack Contribution. Uses Chainlink Data Feeds.

> Status: **in progress**. Design and scaffolding began Sept 1; hook code from Sept 4. Sections marked `[TBD]` are filled in as results land.

---

## The one-sentence version

Uniswap already has the equity liquidity. About 60% of it trades while the reference market is dark. Every existing LP-protection signal — realized volatility, deviation from a live price, priority fees — goes quiet at exactly that moment. ClosingBell prices the calendar without closing the book.

## The problem

US equities trade roughly 19% of the week. Tokenized stocks trade 24/7. For ~17.5 hours on weekdays and the entire weekend, a Uniswap pool is the only on-chain price discovery for the token, while the Chainlink reference repeats Friday's close. When the market reopens, the real price asserts itself and an arbitrageur — in practice a KYB-onboarded authorized participant, the only party who can redeem — trades the gap against the passive LP in one swap.

This is loss-versus-rebalancing, the central LP problem in AMMs, made structurally worse by a reference market that is closed two-thirds of the time. Every production LVR-mitigation design we surveyed infers toxicity from a signal that only exists in continuous markets. On a Sunday afternoon they all read "calm" and quote their minimum fee to the Monday-morning arbitrageur.

**Where this is happening, verified on-chain (Sept 1 2026):**

- Robinhood Chain (ID 4663): 194 Robinhood Stock Tokens, 25,139 Uniswap v4 pools touching them, ~99% of the chain's tokenized-stock DEX liquidity on Uniswap, cumulative volume past $1B.
- The largest pools — SPY/USDG, TSLA/USDG, AAPL/USDG, SPY/NVDA — all run a **static fee with no hook**.

Full venue data, sources, and the honest gaps in the evidence: [`docs/proposal.md`](docs/proposal.md).

## What the hook does

`beforeSwap` returns a per-swap fee override computed from four inputs:

```
floor(session):
  Regular hours, live                                      → base
  Pre / post / overnight                                   → elevated floor
  Calendar closed, or calendar-open-but-stale/implausible  → highest floor

deviationMult = 1.0        if the swap reduces |pool − ref|   (restoring)
              = f(|dev|)   otherwise                           (adverse)

fee = min( floor(session) × stalenessMult(updatedAt) × deviationMult, feeCap )
```

1. **Session** from a calendar-as-data library (`MarketHours.sol`): NYSE regular / extended / overnight / closed, DST-aware, holiday table.
2. **Staleness** from the Chainlink Data Feed's `updatedAt`: fees rise with time since the last authoritative print.
3. **Deviation** between the pool price and the Chainlink reference, multiplier-normalized.
4. **Direction**, evaluated on an *estimated post-swap price*: trades that move the pool toward the reference pay only the session floor; trades that take the gap pay proportionally to the gap they take. A swap sized to blast through the reference is adverse for the overshoot.

The pool stays open throughout. Uninformed weekend flow fills and pays LPs; only the toxic direction and size gets priced out.

### Liveness predicate

"Live" means the calendar says open **and** the feed agrees:

```
isLive = calendarOpen
      && updatedAt fresh
      && price plausible vs last known
      && quote feed fresh          (stock/SPY pools only)
      && !token.oraclePaused()     (ERC-8056 corporate-action freeze; ABI [TBD: verify on a live token])
```

Chainlink documents states where a market is nominally open but the price is frozen — reopen auction, halts, provider outages. A stale `updatedAt` while the calendar says open is the halt detector. Paused or frozen during regular hours is treated as a halt: the pool stays open at the highest floor. There is no fifth regime.

### Edge cases handled

- **Corporate actions.** Robinhood tokens expose `uiMultiplier()` (ERC-8056). Chainlink documents that the feed incorporates the multiplier into the price; the exact convention (`underlying × uiMultiplier()`) is the first thing the day-1 script checks against a live dividend-paying token (AAPL, multiplier 1.000566) `[TBD: verified on-chain]`. The hook normalizes the *pool* price into the same units and never multiplies the feed again; getting this backwards would read a permanent phantom basis on every dividend-paying token. Multiplier is cached per block in transient storage.
- **Stock/SPY pools.** The pool quotes SPY-per-stock; the stock feed is USD. The adapter takes an optional quote feed and compares the pool ratio to `stockFeed / quoteFeed`. Session and liveness stay keyed to the stock leg.
- **Post-open decay.** After the reopen, only `deviationMult` decays (15 min, linear) so the pool can absorb the gap. The session floor and staleness term never decay; a 9:31 halt still pays the highest floor.
- **Restoring trades never get a discount below the session floor.** A discount invites wash flow that farms cheap rebalancing against the LP.
- **Honest caveat.** When the reference is stale, "restoring" means toward the last official close, not toward fundamentals. Weekend noise pushing the pool back toward a reference that no longer reflects reality gets the cheap rate. This is intrinsic to any stale-reference design; the session floor bounds the damage.

### Why this is not a soft halt

For the fee to matter against documented 3–5% weekend gaps, `feeCap` has to be of that order (v1 default 300–500 bps, creator-set at initialization). At that cap, adverse flow near gap size is largely priced out — that is the mechanism working. Uninformed flow pays moderate session-floor fees and fills all weekend; restoring flow pays `floor × staleness` and fills. The only prior calendar-aware AMM design (`horsefacts/trading-days`) hard-reverts every one of those trades.

### Parameters (creator-set at initialization, immutable)

The hook's users are pool creators — issuers, professional LPs, Robinhood itself. This is the full surface a creator sets; tuned defaults land after the fork tests (days 7–9).

| Parameter | What it controls | v1 default |
|---|---|---|
| `baseFee` | Floor during regular hours, live | pool's normal tier `[TBD: tuned]` |
| `elevatedFloor` | Floor for pre/post/overnight sessions | `[TBD: tuned]` |
| `closedFloor` | Floor when calendar-closed or open-but-stale/implausible | `[TBD: tuned]` |
| staleness curve | `stalenessMult` vs time since `updatedAt`, capped | `[TBD: tuned]` |
| deviation curve | Piecewise-linear knots for `f(\|dev\|)` | `[TBD: tuned]` |
| `feeCap` | Single cap on the full product | 300–500 bps |
| `decayWindow` | Post-open blend of `deviationMult` toward 1.0 | 15 min, linear |
| `quoteFeed` | Optional second feed for non-dollar quote legs (stock/SPY) | `address(0)` for stock/USDG |
| `maxStaleness`, plausibility bound | Liveness-predicate thresholds | `[TBD: tuned]` |

## Oracle: what v1 reads, and what it doesn't

**v1 reads free on-chain Chainlink Data Feeds** for price and `updatedAt`, and derives session state from the calendar. `marketStatus` is **not** read on-chain in v1.

Chainlink Data Streams carries an explicit `marketStatus` enum (v8 / v11 / v10 schemas differ — `1` means Closed on v8 but Pre-market on v11) and Chainlink's own guidance is to use it rather than timestamps. Streams requires credentials and a subscription. The adapter is built behind `IMarketStateAdapter` so a Streams implementation drops in for production without touching the hook; the predicate's first term becomes `marketStatus == Open` and the other terms are unchanged.

## Measurement `[TBD]`

Nobody has published a pool-level weekend/reopen analysis or LVR measurement for any tokenized-equity pool on any chain. This section fills that gap across two windows: a historical control weekend (same pools, same pipeline) and the Sept 4–8 2026 Labor Day window (~90 hours of reference staleness, reopen Tuesday Sept 8 — the longest-staleness observation available).

- `[TBD]` Historical weekend chart: stock-leg pool mid vs prior-close reference plus the Monday reprice, for one stock/SPY and one stock/USDG pool. This is also the go/no-go gate on effect size, and the fallback if the Labor Day window happens to be newsless.
- `[TBD]` Labor Day chart: same pools, Fri 16:00 ET → Tue 10:30 ET.
- `[TBD]` Reopen reprice path, 9:30–10:30 ET Sept 8.
- `[TBD]` Optional: realized LVR vs fees earned over the windows.

Pipeline: `scripts/spread-analysis/` (Envio HyperSync → `Swap` logs → `sqrtPriceX96` decode → decimals + multiplier normalization).

## Results `[TBD]`

Fork test on Robinhood Chain: pool at Friday close, reference jumps at the open, **one optimally sized arbitrage swap** with and without the hook.

- `[TBD]` LP value retained, hook vs unprotected
- `[TBD]` Fee revenue captured from the arb
- `[TBD]` Decomposition: how much protection came from `floor × staleness` vs the deviation surcharge

If most of v1's protection turns out to be floor × staleness, that is the finding, and it is reported as such.

## Architecture

```
  swap ──────► Uniswap v4 PoolManager (non-canonical address on Robinhood Chain)
                        │ beforeSwap
                        ▼
              ┌─────────────────────────────┐        ┌────────────────────────────────┐
              │ ClosingBellHook (beforeSwap)│ ◄───── │ IMarketStateAdapter            │
              │  session ← MarketHours.sol  │        │  v1: ChainlinkEquityAdapter    │
              │  isLive (liveness predicate)│        │    Data Feed price, updatedAt  │
              │  staleness mult             │        │    optional quoteFeed          │
              │  deviation mult (signed,    │        │    uiMultiplier() per-block    │
              │    post-swap estimate)      │        │    transient cache             │
              │  post-open decay            │        │  prod: Streams marketStatus    │
              │  FeeCurve → min(floor×m×m,  │        │    (per-schema decode)         │
              │             cap) → override │        └────────────────────────────────┘
              └─────────────┬───────────────┘
                            ▼
                  swap executes at computed fee
```

## Contracts

| File | What it is |
|---|---|
| [`src/ClosingBellHook.sol`](src/ClosingBellHook.sol) | The hook. `beforeSwap` only, dynamic-fee flag. Post-swap price estimate, fee override. `[TBD: line pointers]` |
| [`src/FeeCurve.sol`](src/FeeCurve.sol) | Pure library: floors, staleness and deviation multipliers, signed rule, decay, cap |
| [`src/MarketHours.sol`](src/MarketHours.sol) | Pure library: UTC→ET with DST, session windows, NYSE holiday table |
| [`src/IMarketStateAdapter.sol`](src/IMarketStateAdapter.sol) | Adapter interface: one underlying per pool for session; optional quote price for deviation |
| [`src/ChainlinkEquityAdapter.sol`](src/ChainlinkEquityAdapter.sol) | v1 adapter: Data Feed price/`updatedAt`, optional quote feed, transient-storage multiplier cache, `oraclePaused()`, liveness |
| [`src/Constants.sol`](src/Constants.sol) | Verified Robinhood Chain addresses. The PoolManager is **non-canonical** on this chain |

**Uniswap v4 integration points** `[TBD: exact lines]`: hook permissions (`beforeSwap`), dynamic-fee flag on pool init, fee override return in `beforeSwap`, `StateLibrary` reads for the post-swap estimate.

## Running it

```bash
forge install
forge test                                                            # unit + local integration
forge test --fork-url https://rpc.mainnet.chain.robinhood.com -vv     # fork tests (Robinhood Chain, ID 4663)
./script/day1-checks.sh                                               # feed + multiplier sanity checks via cast
```

Test names are fixed by the spec; see [`test/`](test/). Tests route swaps through the PoolManager / v4 test router only — the UniversalRouter on Robinhood Chain is a modified fork.

## Scope

**In:** the hook, the adapter, the calendar library, unit + fork tests, one measured weekend for two pools, this README, `FEEDBACK.md`.

**Out:** frontend; cross-wrapper arbitrage or any trading; non-EVM chains; permissioned/KYC logic; `afterSwap`; audit-grade hardening; the production UniversalRouter.

Dynamic-fee hooks need Uniswap Labs routing allowlisting before the official app routes through them. Nothing here depends on that; the hook is usable by any pool creator and any integrator routing through the PoolManager.

## Novelty, stated carefully

The pieces all exist: dynamic fees, oracle-deviation hooks (Arrakis Pro, Detox; Levery, pending confirmation that it does not also condition on market hours `[TBD: verified]`), staleness decay (Valantis HOT), direction asymmetry (Balancer StableSurge), market-hours gating (`trading-days`, which reverts), and bespoke market-hours oracle pipelines (Stork for Ostium's perps). As far as the published landscape shows, no AMM design conditions LP protection on the underlying venue's trading calendar jointly with reference-price staleness and signed deviation while keeping the pool open, packaged as a reusable primitive. That is an argument from what is published, not a proof of absence: 489 hook addresses are live on Robinhood Chain, most undocumented.

## Feedback to Uniswap

See [`FEEDBACK.md`](FEEDBACK.md) `[TBD]`.

## License

MIT. See [`LICENSE`](LICENSE).

## Author

Neil Khedekar — [github.com/0xtitan6](https://github.com/0xtitan6)