# ClosingBell Hook

**A Uniswap v4 hook that protects LPs in tokenized-stock pools by pricing fees off the underlying market's trading calendar and its live reference price, jointly, while keeping the pool open.**

Built for [ETHOnline 2026](https://ethglobal.com/events/ethonline2026) (build window opens Sept 4; submission deadline Sept 13, 12:00 pm EDT). Uniswap Foundation track: Best Uniswap Stack Contribution. Uses Chainlink Data Feeds.

> Status: **in progress**. Pre-window work, disclosed to ETHGlobal: this README, the design doc (`docs/proposal.md`), and the Uniswap v4-template boilerplate scaffold. All project code is written from the Sept 4 kickoff. Sections marked `[TBD]` are filled in as results land.

---

## The one-sentence version

Uniswap already has the equity liquidity. About 60% of it trades while the reference market is dark. Every existing LP-protection signal — realized volatility, deviation from a live price, priority fees — goes quiet at exactly that moment. ClosingBell prices the calendar without closing the book.

## The problem

US equities trade roughly 19% of the week. Tokenized stocks trade 24/7. For ~17.5 hours on weekdays and the entire weekend, a Uniswap pool is the only on-chain price discovery for the token, while the Chainlink reference goes dark. Verified on-chain: these feeds are `us_equities_24/5` — live from ~Sunday 20:00 ET through Friday evening, then frozen for ~52 hours with the 24h heartbeat suspended. The reference wakes and gaps **Sunday 20:00 ET** (SPY moved −0.53% across one such boundary), 13.5 hours before the regular open. When the market reopens, the real price asserts itself and an arbitrageur — in practice a KYB-onboarded authorized participant, the only party who can redeem — trades the gap against the passive LP in one swap.

This is loss-versus-rebalancing, the central LP problem in AMMs, made structurally worse by a reference market that is closed two-thirds of the time. Every production LVR-mitigation design we surveyed infers toxicity from a signal that only exists in continuous markets. On a Sunday afternoon they all read "calm" and quote their minimum fee to the Monday-morning arbitrageur.

**Where this is happening, verified on-chain (Sept 1 2026):**

- Robinhood Chain (ID 4663): 194 Robinhood Stock Tokens, 25,139 Uniswap v4 pools touching them, ~99% of the chain's tokenized-stock DEX liquidity on Uniswap, cumulative volume past $1B.
- The deepest pools — SPY/USDG, TSLA/USDG, AAPL/USDG, SPY/NVDA — all run a **static fee with no hook**. (One protocol, Fables, does run its own calendar-fee'd stock pools alongside them — see Novelty.)

Full venue data, sources, and the honest gaps in the evidence: [`docs/proposal.md`](docs/proposal.md). On-chain verification log (feed addresses, feed liveness, multiplier convention): [`docs/verified-onchain.md`](docs/verified-onchain.md). Closest prior art: [`docs/prior-art-fables.md`](docs/prior-art-fables.md). Post-freeze corrections to the spec: [`docs/build-notes.md`](docs/build-notes.md).

## What the hook does

`beforeSwap` returns a per-swap fee override computed from four inputs:

```
floor(session):
  Regular hours, live                                      → base
  Pre / post / overnight                                   → elevated floor
  Calendar closed, or calendar-open-but-stale/implausible  → highest floor

deviationMult = 1.0        if the swap reduces POOL-CREATED deviation   (restoring)
              = f(|dev|)   otherwise, and always for deviation the
                           REFERENCE created by moving                    (adverse)

fee = min( floor(session) × stalenessMult(time since session close) × deviationMult, feeCap )
```

1. **Session** from a calendar-as-data library (`MarketHours.sol`): NYSE regular / extended / overnight / closed, DST-aware, holiday table.
2. **Staleness**, measured in calendar time: fees ramp with time since the session closed (B2). The feed's `updatedAt` is not the ramp input — on a 0.5%-threshold, 86400s-heartbeat feed it cannot distinguish a quiet market from a frozen one (B1) — so it serves only as a dead-feed safety net inside `isLive`.
3. **Deviation** between the pool price and the Chainlink reference (both already per-token — no multiplier adjustment; see Edge cases).
4. **Direction**, evaluated on an *estimated post-swap price*, and split by **who created the gap**. A trade closing deviation the pool itself wandered into pays only the session floor. A trade closing deviation that appeared because the *reference* moved — the reopen arbitrage — pays the full surcharge. This distinction is load-bearing: LVR arbitrage is definitionally price-restoring, so an unrestricted restoring exemption would hand the cheapest fee of the week to the exact trade the hook exists to price. A swap sized to blast through the reference is adverse for the overshoot.

The pool stays open throughout. Uninformed weekend flow fills and pays LPs; only the toxic direction and size gets priced out.

### Liveness predicate

"Live" means the calendar says open **and** the feed agrees:

```
isLive = calendarOpen
      && updatedAt fresh          (maxStaleness > 86400s heartbeat — see below)
      && price plausible vs last known
      && quote feed fresh          (stock/SPY pools only)
      && !token.oraclePaused()     (ERC-8056 corporate-action freeze; ABI verified on-chain Sept 4)
```

Chainlink documents states where a market is nominally open but the price is frozen — reopen auction, halts, provider outages. Paused or frozen during regular hours is treated as a halt: the pool stays open at the highest floor. There is no fifth regime.

**`updatedAt` is not a halt detector on these feeds** (correction to r7; see [`docs/build-notes.md`](docs/build-notes.md) B1). The feeds carry a 0.5% deviation threshold and an 86400s heartbeat, and the measured SPY round history shows a normal quiet Monday passing with no print at all — `r113` Sun 20:00 ET to `r114` Mon 20:00 ET, consecutive rounds exactly one heartbeat apart, spanning that Monday's entire regular session. Any `maxStaleness` tight enough to catch a 5–15 minute halt would therefore charge `closedFloor` at 14:00 on an ordinary trading day. `maxStaleness` is sized *above* the heartbeat and means "this feed is dead for days." Halts are priced by `deviationMult` instead — the reference freezes, the token keeps trading, the pool drifts off it, the surcharge climbs on its own. `marketStatus`-based halt detection is a Data Streams feature and stays in the production adapter.

### Edge cases handled

- **Corporate actions — measured, then simplified.** Robinhood tokens expose `uiMultiplier()` (ERC-8056); AAPL's is 1.000566080061092436. Checking AAPL against both its Chainlink price and its deep pool settles the convention: the pool sits **0.4bp from the raw feed** versus 5.3bp under a divide-by-multiplier convention, on a multiplier worth 5.66bp. Both sides are already per-token, so **the hook applies no multiplier adjustment** — no per-swap external call, no transient cache. Residual edge case: if the multiplier and the feed price update at different moments, a transient basis appears. Evidence: [`docs/verified-onchain.md`](docs/verified-onchain.md).
- **Stock/SPY pools.** The pool quotes SPY-per-stock; the stock feed is USD. The adapter takes an optional quote feed and compares the pool ratio to `stockFeed / quoteFeed`. Session and liveness stay keyed to the stock leg.
- **Post-open decay.** After the reopen, only `deviationMult` decays (15 min, linear) so the pool can absorb the gap. The session floor and staleness term never decay; a 9:31 halt still pays the highest floor. The window is measured from the *calendar* reopen, not from an observed feed transition — **calendar time drives ramps, feed time drives liveness only** (B2).
- **Half the week is off-hours with a *live* reference.** `us_equities_24/5` means the feed runs continuously Sunday 20:00 ET → Friday evening, weekday overnight included. Regular hours are ~32.5h/week, the weekend dark window ~52h, and the remaining ~83.5h are off-hours where the deviation surcharge still has a working reference to measure against. Only ~31% of the week is genuinely blind, not the ~60% that "outside US market hours" suggests — which is why `elevatedFloor` sits near `baseFee` and the height is concentrated in `closedFloor` (B3).
- **Restoring trades never get a discount below the session floor.** A discount invites wash flow that farms cheap rebalancing against the LP. (Ballast discounts below base for restoring trades; this is the deliberate divergence.)
- **The reopen is priced, not exempted.** When the reference wakes — Sunday ~20:00 ET for these feeds — the gap it reveals is reference-created, so the arbitrage that captures it is charged `f(·)` despite moving the pool toward fair value.
- **Honest caveat.** When the reference is stale, "restoring" means toward the last official close, not toward fundamentals. Weekend noise pushing the pool back toward a reference that no longer reflects reality gets the cheap rate. This is intrinsic to any stale-reference design; the session floor bounds the damage.

### Why this is not a soft halt

For the fee to matter against documented 3–5% weekend gaps, `feeCap` has to be of that order (v1 default 300–500 bps = 30_000–50_000 pips, creator-set at construction). At that cap, adverse flow near gap size is largely priced out — that is the mechanism working. Uninformed flow pays moderate session-floor fees and fills all weekend; restoring flow pays `floor × staleness` and fills. The calendar-aware design that *reverts* (`horsefacts/trading-days`) blocks every one of those trades. Note the live prior art (Fables) also keeps pools open, so staying open is common ground with it — the contrast that carries weight is against `trading-days`.

### Parameters (creator-set at initialization, immutable)

The hook's users are pool creators — issuers, professional LPs, Robinhood itself. Parameters are `immutable`, set in the constructor: one hook instance per pool. **v4 fees are pips (1e-6), not bps** — `MAX_LP_FEE` is 1_000_000, and an over-cap fee reverts rather than clamps. Tuned defaults land after the fork tests.

| Parameter | What it controls | v1 default |
|---|---|---|
| `baseFee` | Floor during regular hours, live | pool's normal tier `[TBD: tuned]` |
| `elevatedFloor` | Floor for pre/post/overnight sessions — reference is still live here, so this sits near `baseFee` (B3) | `[TBD: tuned]` |
| `closedFloor` | Floor when calendar-closed or open-but-stale/implausible | `[TBD: tuned]` |
| staleness curve | `stalenessMult` vs time since **session close**, capped (B2) | `[TBD: tuned]` |
| deviation curve | Piecewise-linear knots for `f(\|dev\|)` | `[TBD: tuned]` |
| `feeCap` | Single cap on the full product | 300–500 bps = **30_000–50_000 pips** |
| `decayWindow` | Post-open blend of `deviationMult` toward 1.0 | 15 min, linear |
| `quoteFeed` | Optional second feed for non-dollar quote legs (stock/SPY) | `address(0)` for stock/USDG |
| `maxStaleness`, plausibility bound | Liveness-predicate thresholds. `maxStaleness` **above** the 86400s heartbeat — dead-feed net, not halt detector (B1) | `[TBD: tuned]` |

## Oracle: what v1 reads, and what it doesn't

**v1 reads free on-chain Chainlink Data Feeds** for price and `updatedAt`, and derives session state from the calendar. `marketStatus` is **not** read on-chain in v1.

Chainlink Data Streams carries an explicit `marketStatus` enum (v8 / v11 / v10 schemas differ — `1` means Closed on v8 but Pre-market on v11) and Chainlink's own guidance is to use it rather than timestamps. Streams requires credentials and a subscription. The adapter is built behind `IMarketStateAdapter` so a Streams implementation drops in for production without touching the hook; the predicate's first term becomes `marketStatus == Open` and the other terms are unchanged.

## Measurement `[TBD]`

Nobody has published a pool-level weekend/reopen analysis or LVR measurement for any tokenized-equity pool on any chain. This section fills that gap across two windows: a historical control weekend (same pools, same pipeline) and the Sept 4–8 2026 Labor Day window (~90 hours of reference staleness, reopen Tuesday Sept 8 — the longest-staleness observation available).

- `[TBD]` Historical weekend chart: stock-leg pool mid vs prior-close reference plus the Monday reprice, for one stock/SPY and one stock/USDG pool. This is also the go/no-go gate on effect size, and the fallback if the Labor Day window happens to be newsless.
- `[TBD]` Labor Day chart: same pools, Fri 16:00 ET → Tue 10:30 ET.
- `[TBD]` **Two reopen events, not one:** the Sunday ~20:00 ET reference wake-up (when the feed unfreezes and gaps) and the 9:30–10:30 ET regular open. Charting only the latter misses the actual repricing moment.
- `[TBD]` Does the dark window or the reopen carry the toxicity? This is the question that separates ClosingBell's floor ordering from the live prior art's (see Novelty).
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
              │ ClosingBellHook._getFee()   │ ◄───── │ IMarketStateAdapter            │
              │  session ← MarketHours.sol  │        │  v1: ChainlinkEquityAdapter    │
              │  isLive (liveness predicate)│        │    Data Feed price, updatedAt  │
              │  staleness mult             │        │    optional quoteFeed          │
              │  deviation mult (signed,    │        │    try/catch every call —      │
              │    post-swap estimate, F1)  │        │    getMarketState() is total   │
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
| [`src/ClosingBellHook.sol`](src/ClosingBellHook.sol) | The hook, `is BaseOverrideFee`. Permissions `afterInitialize + beforeSwap` (salt `0x1080`); implements `_getFee` only. Constructor-immutable params, one instance per pool; `_afterInitialize` rejects any other pool. `[TBD: line pointers]` |
| [`src/FeeCurve.sol`](src/FeeCurve.sol) | Pure library: floors, staleness and deviation multipliers, signed rule, decay, cap |
| [`src/MarketHours.sol`](src/MarketHours.sol) | Pure library: UTC→ET with DST, session windows, NYSE holiday table |
| [`src/IMarketStateAdapter.sol`](src/IMarketStateAdapter.sol) | Adapter interface: one underlying per pool for session; optional quote price for deviation |
| [`src/ChainlinkEquityAdapter.sol`](src/ChainlinkEquityAdapter.sol) | v1 adapter: Data Feed price/`updatedAt`, optional quote feed, `oraclePaused()`, liveness predicate |
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

Five hooks surveyed as of **Sept 4 2026**, all verified directly from source or on-chain bytecode. Two of them defeat claims this project originally made, and saying so first is the point.

| | Calendar | Reads a reference price | What it does with `updatedAt` |
|---|---|---|---|
| [Fables](https://www.fables.fi/) (live, chain 4663) | yes, 3 sessions | **no** — fee is a pure function of `block.timestamp` | nothing |
| Ballast (`dny-777/ballast`) | no | yes | **reverts** (3600s) |
| StockShield (`ayush18pop/stockshield.eth`) | yes, 7 regimes | yes | **reverts** (60s) |
| FLock (`FLock-io/flock-v4-hook`) | yes | **no** | nothing |
| Levery | no | yes | not conditioned |
| **ClosingBell** | yes, 4 sessions | yes, every swap | **prices it** |

**What is not novel, stated plainly.** Calendar-conditioned fees for tokenized stocks are occupied — Fables ships them live on this chain with real TVL, and analysis with addresses and quoted source is in [`docs/prior-art-fables.md`](docs/prior-art-fables.md). Direction asymmetry against an oracle reference is occupied *and taught* — Ballast implements it and credits Uniswap Hook Incubator's "Nezlobin's Directional Fee." Neither is claimed here.

**The surviving claim, narrow and falsifiable:** *of the five hooks surveyed, ClosingBell is the only one that computes its fee on-chain from both a trading calendar and a live reference price.* Fables and FLock price the calendar and read no reference at all. Ballast and Levery read a reference and have no calendar. StockShield has both, but its staleness is a revert gate — a 60-second bound rejects every weekend swap against a `us_equities_24/5` feed — and its fee is ECDSA-signed off-chain, the hook only bounds-checking it. That row of the table is occupied by one hook. The sharpest mechanism-level difference is F1: no surveyed hook splits deviation by *who created it*, and Ballast — implementing the taught directional fee — actively discounts the reopen arbitrage 2×. What this project does **not** claim, after its own measurements (B1, B2 in [`docs/build-notes.md`](docs/build-notes.md)): that `updatedAt` detects halts on these feeds, or that the fee ramp is driven by feed staleness. It is driven by calendar time; the feed drives deviation and a dead-feed safety net.

**Two honest notes.** Fables does *not* believe the closure is harmless — their `closedSpike` docstring says the post-weekend open is *"the most toxic — a whole weekend of off-venue price discovery the pool is blind to,"* and their source states *"No ordering is imposed on the three floors."* The disagreement is about where weekend toxicity is charged, not whether it exists. And FLock's hook was created 2026-09-04 09:24 UTC — concurrent independent work, not prior art; nobody could have read it beforehand.

Verification with line numbers, timestamps and licences: [`docs/prior-art-verification.md`](docs/prior-art-verification.md). Ballast and StockShield carry no licence file; nothing was copied from any of them.

Caveat: this is a survey of five named hooks on one date, not proof of absence — 489 distinct non-zero hook addresses are live on Robinhood Chain, most undocumented.

## Feedback to Uniswap

See [`FEEDBACK.md`](FEEDBACK.md) `[TBD]`.

## License

MIT. See [`LICENSE`](LICENSE).

## Author

Neil Khedekar — [github.com/0xtitan6](https://github.com/0xtitan6)