# ClosingBell Hook

**A Uniswap v4 hook that protects LPs in tokenized-stock pools by pricing fees off the underlying market's trading calendar and its live reference price, jointly, while keeping the pool open.**

Built for [ETHOnline 2026](https://ethglobal.com/events/ethonline2026) (build window opens Sept 4; submission deadline Sept 13, 12:00 pm EDT). Uniswap Foundation track: Best Uniswap Stack Contribution. Uses Chainlink Data Feeds.

> Status: **contracts complete, 174 unit tests + 6 fork tests passing** (Sept 12). Pre-window work, disclosed to ETHGlobal: this README, the design doc (`docs/proposal.md`), and the Uniswap v4-template boilerplate scaffold. All project code is written from the Sept 4 kickoff. Not deployed to mainnet; the fork tests run against the live chain. Sections marked `[TBD]` are open. AI usage is documented per file in [How AI was used](#how-ai-was-used).

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

The pool stays open throughout, and uninformed weekend flow fills and pays LPs. One caveat measured in Round 4: while the reference has moved and nobody has yet arbitraged the pool onto it, *every* trade pays the gap surcharge, not only the toxic direction. That is a consequence of charging on the larger endpoint of the swap (build note B6). Once the gap is closed, restoring flow is back to the session floor.

### Liveness predicate

"Live" means the feed is usable. The calendar is deliberately **not** part of it: the session drives
the floor, and the hook reads the calendar itself, so the oracle seam carries prices only (B12).

```
isLive = price readable and > 0
      && updatedAt fresh           (maxStaleness > 86400s heartbeat — see below)
      && price plausible vs the last distinct print
      && quote feed fresh          (stock/SPY pools only)
      && !token.oraclePaused()     (ERC-8056 corporate-action freeze; ABI verified on-chain Sept 4)
```

Chainlink documents states where a market is nominally open but the price is frozen — reopen auction, halts, provider outages. Paused or frozen during regular hours is treated as a halt: the pool stays open at the highest floor. There is no fifth regime.

**`updatedAt` is not a halt detector on these feeds** (correction to r7; see [`docs/build-notes.md`](docs/build-notes.md) B1). The feeds carry a 0.5% deviation threshold and an 86400s heartbeat, and the measured SPY round history shows a normal quiet Monday passing with no print at all — `r113` Sun 20:00 ET to `r114` Mon 20:00 ET, consecutive rounds exactly one heartbeat apart, spanning that Monday's entire regular session. Any `maxStaleness` tight enough to catch a 5–15 minute halt would therefore charge `closedFloor` at 14:00 on an ordinary trading day. `maxStaleness` is sized *above* the heartbeat and means "this feed is dead for days." Halts are priced by `deviationMult` instead — the reference freezes, the token keeps trading, the pool drifts off it, the surcharge climbs on its own. `marketStatus`-based halt detection is a Data Streams feature and stays in the production adapter.

### Edge cases handled

- **Corporate actions — measured, then simplified.** Robinhood tokens expose `uiMultiplier()` (ERC-8056); AAPL's is 1.000566080061092436. Checking AAPL against both its Chainlink price and its deep pool settles the convention: the pool sits **0.4bp from the raw feed** versus 5.3bp under a divide-by-multiplier convention, on a multiplier worth 5.66bp. Both sides are already per-token, so **the hook applies no multiplier adjustment** — no per-swap external call, no transient cache. Residual edge case: if the multiplier and the feed price update at different moments, a transient basis appears. Evidence: [`docs/verified-onchain.md`](docs/verified-onchain.md).
- **Stock/SPY pools.** The pool quotes SPY-per-stock; the stock feed is USD. The adapter takes an optional quote feed and compares the pool ratio to `stockFeed / quoteFeed`. Session and liveness stay keyed to the stock leg.
- **No post-open decay.** An earlier draft blended `deviationMult` back toward 1.0 over 15 minutes after the reopen. It was cut (B4): a decay clock is something an arbitrageur can wait out, and the surcharge already falls on its own as the gap closes. Ramps are driven by *calendar* time, liveness by feed time (B2).
- **The reference window, not the last print.** Whether a gap belongs to the reference or to the pool is judged against the lowest and highest print in the feed's recent history. Anchoring on a single previous print let a trend of small prints, or a reopen followed by a retrace, be arbitraged at the floor (B9).
- **Half the week is off-hours with a *live* reference.** `us_equities_24/5` means the feed runs continuously Sunday 20:00 ET → Friday evening, weekday overnight included. Regular hours are ~32.5h/week, the weekend dark window ~52h, and the remaining ~83.5h are off-hours where the deviation surcharge still has a working reference to measure against. Only ~31% of the week is genuinely blind, not the ~60% that "outside US market hours" suggests — which is why `elevatedFloor` sits near `baseFee` and the height is concentrated in `closedFloor` (B3).
- **Restoring trades never get a discount below the session floor.** A discount invites wash flow that farms cheap rebalancing against the LP. (Ballast discounts below base for restoring trades; this is the deliberate divergence.)
- **The reopen is priced, not exempted.** When the reference wakes — Sunday ~20:00 ET for these feeds — the gap it reveals is reference-created, so the arbitrage that captures it is charged `f(·)` despite moving the pool toward fair value.
- **Honest caveat.** When the reference is stale, "restoring" means toward the last official close, not toward fundamentals. Weekend noise pushing the pool back toward a reference that no longer reflects reality gets the cheap rate. This is intrinsic to any stale-reference design; the session floor bounds the damage.

### Why this is not a soft halt

For the fee to matter against documented 3–5% weekend gaps, `feeCap` has to be of that order (v1 default 300–500 bps = 30_000–50_000 pips, creator-set at construction). At that cap, adverse flow near gap size is largely priced out — that is the mechanism working. Uninformed flow pays moderate session-floor fees and fills all weekend; restoring flow pays `floor × staleness` and fills. The calendar-aware design that *reverts* (`horsefacts/trading-days`) blocks every one of those trades. Note the live prior art (Fables) also keeps pools open, so staying open is common ground with it — the contrast that carries weight is against `trading-days`.

### Parameters (creator-set at initialization, immutable)

The hook's users are pool creators — issuers, professional LPs, Robinhood itself. Parameters are `immutable`, set in the constructor: one hook instance per pool. **v4 fees are pips (1e-6), not bps** — `MAX_LP_FEE` is 1_000_000, and an over-cap fee reverts rather than clamps. The defaults below are the values the end-to-end and fork tests use; they were not tuned against measured data.

| Parameter | What it controls | v1 default |
|---|---|---|
| `baseFee` | Floor during regular hours, live | 500 pips = 5 bps *(provisional)* |
| `elevatedFloor` | Floor for pre/post/overnight sessions — reference is still live here, so this sits near `baseFee` (B3) | 800 pips = 8 bps *(provisional)* |
| `closedFloor` | Floor when calendar-closed, or the feed is unusable | 3_000 pips = 30 bps *(provisional)* |
| staleness curve | `stalenessMult` vs time since **session close**, capped (B2) | slope `1.0684e13`/sec, cap 3.0x *(provisional)* |
| deviation curve | `devKink`, `devSlope1`, `devSlope2`: multiplier grows with \|dev\| at `slope1` up to the kink, `slope2` past it | kink 0.5%, slopes 100 / 200 *(provisional)* |
| `feeCap` | Single cap on the full product; at most `MAX_LP_FEE − 2` or v4 can compound it to 100% and reject exact-output swaps | 40_000 pips = 400 bps *(provisional)* |
| `quoteFeed` | Optional second feed for non-dollar quote legs (stock/SPY) | `address(0)` for stock/USDG |
| `maxStaleness`, plausibility bound | Liveness-predicate thresholds. `maxStaleness` **above** the 86400s heartbeat — dead-feed net, not halt detector (B1) | 2 days, 2000 bps *(provisional)* |

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

## Results from the fork

[`test/fork/Hook.fork.t.sol`](test/fork/Hook.fork.t.sol) runs the hook on a fork of Robinhood Chain against the **real PoolManager, the real AAPL and USDG tokens, and the real Chainlink AAPL/USD and USDG/USD feeds**. Friday Sept 11 2026, 20:59 ET, one hour after the 24/5 feed's weekly close, pool opened at the live reference of 332.53 USDG per AAPL:

| swap | fee (pips) | fee |
|---|---|---|
| buy 100 USDG of AAPL | 3149 | 0.31% |
| buy 100k USDG of AAPL (thin fork pool) | 40000 | 4.00%, the cap |
| sell 1 AAPL | 3229 | 0.32% |
| 24 hours later, feed still dark | 5949 | 0.59% |
| a real 1,000 USDG swap through the PoolManager | quoted 3459, **charged 3459** | 0.35% |

During regular hours the same pool quotes 500 (0.05%). The closed floor, the staleness ramp and the size-aware deviation term are all visible in one run. What is **not** measured: LP value retained vs an unhooked pool over a real reopen. That experiment was scoped and not run; see `docs/proposal.md` §8.

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
              │  deviation mult (signed,    │        │    raw staticcall, length-     │
              │    post-swap estimate, F1)  │        │    checked: never reverts      │
              │  window rule (B9)           │        │  prod: Streams marketStatus    │
              │  FeeCurve → min(floor×m×m,  │        │    (per-schema decode)         │
              │             cap) → override │        └────────────────────────────────┘
              └─────────────┬───────────────┘
                            ▼
                  swap executes at computed fee
```

## Contracts

| File | What it is |
|---|---|
| [`src/ClosingBellHook.sol`](src/ClosingBellHook.sol) | The hook, `is BaseOverrideFee`. Permissions `afterInitialize + beforeSwap` (address flags `0x1080`); implements `_getFee` only. Constructor-immutable params, one instance per pool; `_afterInitialize` rejects any other pool and a start price >10x off the reference. ~200 lines |
| [`src/FeeCurve.sol`](src/FeeCurve.sol) | Pure library: floors, staleness and deviation multipliers, the signed direction rule, the reference window, cap |
| [`src/MarketHours.sol`](src/MarketHours.sol) | Pure library: UTC→ET with DST, session windows, NYSE holidays as **rules** (no table, nothing to expire) |
| [`src/IMarketStateAdapter.sol`](src/IMarketStateAdapter.sol) | The oracle seam: one `view` call returning prices and their recent window. Must never revert |
| [`src/ChainlinkEquityAdapter.sol`](src/ChainlinkEquityAdapter.sol) | v1 adapter: Data Feed price and round history, optional quote feed, `oraclePaused()`, liveness predicate |
| [`src/Constants.sol`](src/Constants.sol) | Fixed-point units, NYSE clock times, feed-history lookback. Verified chain addresses live in [`docs/verified-onchain.md`](docs/verified-onchain.md) — the PoolManager is **non-canonical** here |

**Uniswap v4 integration points:** permissions and the `OVERRIDE_FEE_FLAG` return come from OpenZeppelin's [`BaseOverrideFee`](lib/uniswap-hooks/src/fee/BaseOverrideFee.sol); the dynamic-fee check is [`ClosingBellHook.sol:50`](src/ClosingBellHook.sol#L50); the fee itself is [`_getFee`](src/ClosingBellHook.sol#L102); pool state for the post-swap estimate is read with `StateLibrary` at [`_poolPrices`](src/ClosingBellHook.sol#L165); the estimate uses v4's own `SqrtPriceMath`.

## Running it

```bash
forge install
forge test                                   # 174 unit + integration tests; fork tests self-skip
forge test --fuzz-runs 10000                 # what the audit rounds ran

# Against the live chain (Robinhood Chain, ID 4663): real feeds, real PoolManager, real tokens
RPC=https://rpc.mainnet.chain.robinhood.com
forge test --match-path test/fork/Adapter.fork.t.sol --fork-url $RPC -vv
forge test --match-path test/fork/Hook.fork.t.sol    --fork-url $RPC -vv
```

Tests route swaps through the PoolManager and v4's test routers only — the UniversalRouter on Robinhood Chain is a modified fork.

## Scope

**In:** the hook, the adapter, the calendar library, unit + fork tests, one measured weekend for two pools, this README, `FEEDBACK.md`.

**Out:** frontend; cross-wrapper arbitrage or any trading; non-EVM chains; permissioned/KYC logic; `afterSwap`; audit-grade hardening; the production UniversalRouter.

Dynamic-fee hooks need Uniswap Labs routing allowlisting before the official app routes through them. Nothing here depends on that; the hook is usable by any pool creator and any integrator routing through the PoolManager.

## Novelty, stated carefully

Five hooks surveyed as of **Sept 4 2026**, all verified directly from source or on-chain bytecode, plus Uniswap Labs' StablePair hook published Sept 10, mid-build. Two of them defeat claims this project originally made, and saying so first is the point.

| | Calendar | Reads a reference price | What it does with `updatedAt` |
|---|---|---|---|
| [Fables](https://www.fables.fi/) (live, chain 4663) | yes, 3 sessions | **no** — fee is a pure function of `block.timestamp` | nothing |
| Ballast (`dny-777/ballast`) | no | yes | **reverts** (3600s) |
| StockShield (`ayush18pop/stockshield.eth`) | yes, 7 regimes | yes | **reverts** (60s) |
| FLock (`FLock-io/flock-v4-hook`) | yes | **no** | nothing |
| Levery | no | yes | not conditioned |
| [StablePair](https://blog.uniswap.org/stablepair-hook-a-fee-that-moves-with-the-market) (Uniswap Labs, Sept 10 2026) | no | configured constant, not an oracle | n/a |
| **ClosingBell** | yes, 4 sessions | yes, every swap | **prices it** |

**What is not novel, stated plainly.** Calendar-conditioned fees for tokenized stocks are occupied — Fables ships them live on this chain with real TVL, and analysis with addresses and quoted source is in [`docs/prior-art-fables.md`](docs/prior-art-fables.md). Direction asymmetry against an oracle reference is occupied *and taught* — Ballast implements it and credits Uniswap Hook Incubator's "Nezlobin's Directional Fee." Neither is claimed here.

**The surviving claim, narrow and falsifiable:** *of the five hooks surveyed, ClosingBell is the only one that computes its fee on-chain from both a trading calendar and a live reference price.* Fables and FLock price the calendar and read no reference at all. Ballast and Levery read a reference and have no calendar. StockShield has both, but its staleness is a revert gate — a 60-second bound rejects every weekend swap against a `us_equities_24/5` feed — and its fee is ECDSA-signed off-chain, the hook only bounds-checking it. That row of the table is occupied by one hook. The sharpest mechanism-level difference is F1: no surveyed hook splits deviation by *who created it*, and Ballast — implementing the taught directional fee — actively discounts the reopen arbitrage 2×. What this project does **not** claim, after its own measurements (B1, B2 in [`docs/build-notes.md`](docs/build-notes.md)): that `updatedAt` detects halts on these feeds, or that the fee ramp is driven by feed staleness. It is driven by calendar time; the feed drives deviation and a dead-feed safety net.

**Two honest notes.** Fables does *not* believe the closure is harmless — their `closedSpike` docstring says the post-weekend open is *"the most toxic — a whole weekend of off-venue price discovery the pool is blind to,"* and their source states *"No ordering is imposed on the three floors."* The disagreement is about where weekend toxicity is charged, not whether it exists. And FLock's hook was created 2026-09-04 09:24 UTC — concurrent independent work, not prior art; nobody could have read it beforehand.

**StablePair** (Uniswap Labs, MIT, OZ-audited) is the closest in mechanism and the most instructive contrast. It holds a pool near a *configured* reference with a fee that decays block by block, and its direction rule is the reverse of ClosingBell's: a swap pushing the price *away* from the reference pays **zero**, because for a stablecoin pair the trader is already taking a worse-than-par price. For a stock whose reference has been dark for two days, the stale price is the *pool's*, not the trader's, so ClosingBell charges the adverse direction the most. One detail was adopted from it: the fee cap is `MAX_LP_FEE − 2`, since v4 compounds the LP fee with any protocol fee and rounds up ([`FeeCurve.sol:31`](src/FeeCurve.sol#L31)).

Verification with line numbers, timestamps and licences: [`docs/prior-art-verification.md`](docs/prior-art-verification.md). Ballast and StockShield carry no licence file; nothing was copied from any of them.

Caveat: this is a survey of five named hooks on one date, not proof of absence — 489 distinct non-zero hook addresses are live on Robinhood Chain, most undocumented.

## Feedback to Uniswap

See [`FEEDBACK.md`](FEEDBACK.md) `[TBD]`.

## How AI was used

Per ETHGlobal's rules. Claude (Anthropic, via Claude Code) was used throughout; this is what it wrote, what it did not, and how to check.

**Process.** Design, architecture and the prior-art survey were written by the author before the build window (`docs/proposal.md`, `docs/architecture.md`). During the build, Claude drafted contracts and tests from the spec, then ran five adversarial audit rounds with independent reviewer prompts (findings and fixes in `docs/build-notes.md` B7–B13, one fix per commit up to `a0d219f`). On Sept 11 the author reset the four core contracts (`cafa0a8`) and rebuilt them by hand against the existing test suite, asking Claude for explanations, reviews and specific arithmetic-heavy functions. The git log is the record: commits from `cafa0a8` onward are the rebuild.

| File | Author | Claude | Notes |
|---|---|---|---|
| `src/ClosingBellHook.sol` | imports, immutables, errors, constructor and its guards, `_decimals`, `quoteFee`, `_getFee`, `_fee`, `_market`, `_afterInitialize` pool check | `_references`, `_ratio`, `_price`, `_dev`, `_deviationMult`, `_poolPrices`, `_estimatePostSqrtPrice`, `stepSqrtPrice`, the 10x `PriceMismatch` check, one-line comments | Claude's functions wrap `FullMath`, `SqrtPriceMath` and `StateLibrary`; written on request, verified by 41 hook tests |
| `src/FeeCurve.sol` | `Params`, `validate`, `floorFor`, `stalenessMult`, `isRestoring`, `MAX_CAP` | `computeFee`, `deviationMult`, `referenceMoved` (supplied on request, then cleaned up by the author) | |
| `src/ChainlinkEquityAdapter.sol` | reviewed, not written | all of it | Delegated: stateless feed reading, decode and range checks. Spec is the header of its test file |
| `src/AggregatorV3Interface.sol` | copied from Chainlink's MIT interface, trimmed | — | |
| `src/IMarketStateAdapter.sol` | author | comments reviewed | |
| `src/MarketHours.sol` | — | all of it | Calendar library, pre-reset; kept as-is with its 36 tests |
| `src/Constants.sol` | author | — | |
| `test/**` | — | all of it | 174 unit tests + 6 fork tests; the suite is the spec the rebuild was validated against |
| `docs/build-notes.md` | — | all of it | Audit-round write-ups, reviewed by the author |
| `docs/proposal.md`, `docs/architecture.md`, `docs/prior-art-*.md`, this README | author | edits and the sections added after the rebuild | |
| `script/` | v4-template boilerplate | — | |

Prompts were conversational, not spec files; the specs Claude worked from are the docs above and the test headers. No AI-generated video, voiceover or images.

## License

MIT. See [`LICENSE`](LICENSE).

## Author

Neil K — [github.com/0xtitan6](https://github.com/0xtitan6)