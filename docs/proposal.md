# Project Proposal (final): ClosingBell Hook

**A Uniswap v4 hook that protects LPs in tokenized-stock pools by pricing fees off the underlying market's trading calendar and reference-price staleness, jointly, while keeping the pool open.**

Target: ETHOnline 2026 (Sept 4 to 16), Uniswap Foundation track, "Best Uniswap Stack Contribution"
Builder: Neil Khedekar (0xtitan6)
Status: Final r5 (frozen). r5 reopens r4 for five surgical fixes: stock/SPY quote feed (§5.3), post-swap-estimated direction rule (§5.4), Labor Day demo window (§6A) and single-swap fork requirement (§6C), first-trade open question (§9), soft-halt defense with cap magnitude (§14). Verified against chain data (Research audit, Sept 1 2026); internally consistent. Build against this; further changes go in the repo, not here
Primary chain: Robinhood Chain (ID 4663), Uniswap v4
Oracle: v1 = Chainlink Data Feeds (price + `updatedAt`) + calendar session state; production = Data Streams `marketStatus` behind `IMarketStateAdapter`

---

## 1. One-paragraph pitch

If Uniswap is going to be the go-to liquidity layer for tokenized equities, LPs have to survive an asset class whose reference market is open about 19% of the week. Today, every major stock-token pool on Robinhood Chain runs a static fee with no hook. A tokenized NVDA or SPY pool sits at Friday's price all weekend; when the market opens Monday and the stock gaps, an authorized-participant market maker (the only party who can redeem) trades against the pool at the stale price and the passive LP eats the loss. Every existing LP-protection design keys off signals that go quiet exactly when this happens: realized volatility, deviation from a live reference, priority fees. On a Sunday afternoon all of them read "calm" and quote their minimum fee to the Monday 9:30 arbitrageur. ClosingBell conditions the fee on the one signal that does not go dark: the underlying venue's trading calendar, combined with how stale the Chainlink reference is and how far the pool has drifted from it. v1 reads free on-chain Chainlink Data Feeds for price and staleness and derives session state from a calendar-as-data library; the adapter is built so a Data Streams `marketStatus` implementation drops in for production. Fees rise when the market is closed, scale with deviation, and are asymmetric by direction so trades that restore parity stay cheap. The pool stays open throughout, so uninformed weekend flow still fills and still pays LPs. One hook, deployable by any issuer or LP launching a stock-token pool on any v4 chain with a Chainlink equity feed.

## 2. The problem

**Loss-versus-rebalancing (toxic flow) is the central LP problem in AMMs.** Informed traders arbitrage a pool whose price is stale relative to the outside market. LPs are the counterparty to every one of those trades.

**Tokenized equities make it structurally worse than any crypto pair:**

- US equities trade ~6.5h x 5d, roughly 19% of the week. The tokens trade continuously. Uniswap Labs' own reporting puts ~60% of tokenized-equity volume on Robinhood Chain outside US market hours (Uniswap Labs Substack, "Hood morning"). No published decomposition of spread or deviation by session exists.
- For ~17.5 hours on weekdays and the entire weekend, the pool is the only on-chain price discovery mechanism. Off-chain overnight venues exist (Robinhood's registry marks tokens tradable in `extended` and `overnight` sessions; Blue Ocean ATS runs an overnight US session) but are thin. At the open, "the real price asserts itself and the pool has to reprice, fast, against arbitrageurs who now have a hard reference."
- Weekend earnings reactions have moved single names 3 to 5% before the underlying reopens (Kraken/xStocks). Cross-venue spreads of 0.15 to 0.75% "widen at night" (CoinGecko). Solana xStocks deviations from underlying spanned -5.02% to +3.45% (Birdeye, May 2026).
- The closing channel is primary-market mint/burn, restricted to KYB-onboarded authorized participants. Retail cannot redeem. The party able to monetize a reopen gap is a permissioned professional; the counterparty is the passive LP.
- Oracle weekend freezes exacerbate the gap (RedStone via CoinDesk). Chainlink equity feeds repeat the closing price while closed.

**Evidence status, stated honestly:** the mechanism is supported by primary sources and by peer-reviewed LVR results on crypto pairs. No one has published a pool-level weekend/open analysis or an LVR measurement for any tokenized-equity pool on any chain. The one academic paper on this market reads off-hours deviations as "modest." This project measures it directly (Section 6, Workstream A) and treats that measurement as an original contribution, engaging the "modest" finding rather than ignoring it.

## 3. The venue (verified on-chain, Sept 1 2026)

| Fact | Value |
|---|---|
| Chain | Robinhood Chain, Arbitrum Orbit L2, chain ID 4663, ~0.1s blocks |
| Stock tokens | 194 ERC-20s (tokenized debt securities issued by Robinhood Assets Jersey), 18 decimals, per-session `market`/`extended`/`overnight` tradability flags |
| Uniswap share | ~99% of tokenized-stock DEX liquidity on the chain |
| Volume | Cumulative stock-token volume passed $1B on Aug 21; record ~$130M single day on Aug 29 |
| v4 pools touching a stock token | 25,139 (2,435 stock/USDG, 221 stock/ETH, 94 stock/stock, 22,359 launchpad memecoin pairs) |
| Hook adoption in real quote pools | stock/USDG 17.2%, stock/ETH 4.1%, stock/stock 9.6% (the three target classes), nearly all launchpad tooling; stock/WETH (30 pools) is 56.7% hooked. Headline "64% dynamic fee" is a memecoin artifact; do not cite it |
| Priority pools, all verified **no hook, static fee** | SPY/USDG (0.05%, tick 5), TSLA/USDG (0.30%, tick 60), AAPL/USDG (0.30%, tick 60), SPY/NVDA (0.05%, tick 5) |
| Stock/SPY relative-value pools | 48 SPY-paired stock/stock pools across all fee tiers; 18 in the tight 0.05%/tick-5 config, rolled out programmatically in waves. Note: Adams' public "~10 pools / $33M / 11k traders" figure refers to the initial launch wave, not all 48 |

**Primary target class: stock/SPY pools.** Both legs are stale when the market is closed; fair value moves only with overnight news about one name versus the index. The economic story is purest here: the hook protects against informed flow about a single name, not directional market risk. Stock/USDG pools are the secondary target and the more familiar demo.

## 4. Why this matters to Uniswap specifically

- Tokenized securities went live in the Uniswap web app, wallet, and API in June 2026. Uniswap's launch language pointed issuers at v4 hook infrastructure as the way to tap on-chain liquidity.
- Uniswap's stated goal (per recruiter conversation) is to be the on-chain liquidity layer. A liquidity layer for equities requires LPs willing to provide equity liquidity. If LPs get picked off every Monday, they leave, spreads widen, the product fails.
- Uniswap's own Permissioned Pools standard (July 2026) is an allowlist / compliance primitive; it does not express session state. Without this hook, an issuer's only session-level lever is a halt. This hook fills the gap the official RWA standard leaves open. (Checker interface detail stays out of the README until the spec is read; checklist item remains.)
- Routing note: dynamic-fee hooks need Uniswap Labs routing allowlisting before the official app will route through them. The prize submission does not depend on that; the hook is usable by any pool creator and any integrator routing directly through the PoolManager.
- Hooks are permissionless. The users are pool creators: Robinhood, issuers, professional LPs. Uniswap benefits when good hooks make its pools safe to LP in.

## 5. The mechanism

A `beforeSwap` hook on a pool initialized with the dynamic-fee flag, returning a per-swap fee override. Four inputs.

### 5.1 Market state: calendar adapter (v1), Streams `marketStatus` (production)
**v1 (this hackathon, free):** session state comes from `MarketHours.sol`, a calendar-as-data library (weekday, 9:30 to 16:00 ET with DST, NYSE holiday calendar, extended/overnight session windows), following the `trading-days` pattern. Price and `updatedAt` come from the free on-chain Chainlink Data Feed for the underlying. `marketStatus` is **not** read on-chain in v1; nothing in this document should be read as claiming it is.

**Three-part liveness predicate (design contribution).** Chainlink documents states where the calendar says the market is open but the feed is frozen: the reopen auction window (closing price repeated until a bid/ask appears), trading halts (timestamp frozen), and provider outages. v1 has no `Open` enum; "live" means the calendar is open AND the feed agrees. So:

```
isLive = calendarOpen(block.timestamp)
      && (block.timestamp - updatedAt <= maxStaleness)
      && (price > 0 && price within plausibility bounds vs last known)
```

`calendarOpen` is true for **any** trading session (regular, pre, post, overnight); `MarketHours.sol` separately returns a `Session` enum (`Regular`, `Extended`, `Overnight`, `Closed`) that drives the floor. `isLive` gates the staleness/plausibility logic; the floor is chosen by `Session`, so an overnight swap with a fresh feed is `isLive` but still pays the elevated floor, never base. A fresh `updatedAt` confirms the feed agrees with the calendar; the plausibility bound guards outages. A stale `updatedAt` while `calendarOpen` is the halt / reopen-auction detector.

**Production upgrade (documented, not built this week):** swap the adapter for Chainlink Data Streams, which carries an explicit `marketStatus` enum. Chainlink's guidance: "Always use the `marketStatus` field to determine whether a market is open. Do not use timestamps." The predicate's first term becomes `marketStatus == Open` with the other two unchanged. Schema footgun for that adapter: under RWA Standard (v8), `1` = Closed and `2` = Open; under RWA Advanced (v11) 24/5 US equities, `1` = Pre-market, `2` = Regular hours, `3` = Post-market, `4` = Overnight, `5` = Closed. Decode per schema. Footnote: Tokenized Asset schema v10 carries `marketStatus`, `currentMultiplier`, and a separate `tokenizedPrice`; if v10 streams exist for the Robinhood wrappers, the production adapter can take the corporate-action convention from the feed instead of `uiMultiplier()`. Not this week's work.

**Fee regimes and stacking rule (no fourth curve):**

```
floor(session):
  Regular hours, live        → base
  Pre / post / overnight     → elevated floor
  Calendar closed, or calendar-open-but-stale/implausible → highest floor

deviationMult = 1.0          if the swap reduces |pool − ref|   (restoring)
              = f(|dev|)     otherwise                           (adverse), f(0) = 1.0, piecewise-linear

fee = min( floor(session) × stalenessMult(updatedAt) × deviationMult, feeCap )
```

Session sets the floor. Staleness and signed deviation are multipliers on top of that floor. One cap. Regular-hours live with fresh price and zero deviation resolves to exactly base. A restoring swap pays `floor(session) × stalenessMult`, capped: that is base only when the session floor is base; in an elevated or closed session it is the elevated floor times staleness, which is the rule, not a discount.

### 5.2 Reference-price staleness
Time since the last authoritative print (`updatedAt`). `stalenessMult` rises from 1.0 with elapsed time, capped, and multiplies the session floor. This is the HOT/Valantis "time since last update" idea applied as a staleness tax, and it is what makes Sunday afternoon expensive even when nothing has moved yet.

### 5.3 Deviation from reference
Compare pool price to the Chainlink reference. `deviationMult` rises from 1.0 with |deviation| via a piecewise-linear curve, multiplies the session floor alongside `stalenessMult`, and the product is capped once at `feeCap`. Parameters set by the pool creator at initialization, immutable.

**Which leg is priced (v1 rule, revised in r5):** for stock/USDG, the hook compares pool price to the stock's own Chainlink feed with the dollar token as quote. For stock/SPY a one-feed rule cannot work — the pool quotes SPY-per-stock while the feed is USD, so deviation is undefined without SPY/USD (r4's one-leg rule was internally inconsistent here). The adapter therefore takes an optional `quoteFeed`: when set, deviation compares the pool ratio to `stockFeed / quoteFeed`. Session state and the liveness predicate stay keyed to the stock leg (both legs share the NYSE calendar); when `quoteFeed` is set, `isLive` gains one extra `&&` requiring the quote feed fresh as well. `IMarketStateAdapter` remains one-underlying for session and gains a quote price for deviation.

**Multiplier gotcha (must handle):** Robinhood stock tokens implement ERC-8056 `uiMultiplier()` for corporate actions. Dividends and splits adjust the shares-per-token ratio while raw balances stay static; AAPL's multiplier is already 1.000566. The Chainlink oracle "automatically incorporates the multiplier into the price." The hook must apply the same convention when computing pool price, or it reads a permanent phantom basis on every dividend-paying token and a split presents as a discontinuous double-digit "arbitrage." The adapter reads `uiMultiplier()` on a per-block cache miss only, caches it in transient storage (`tstore`/`tload` — the right cache granularity for 0.1s blocks, and a primitive v4 itself relies on), and normalizes; subsequent swaps in the same block reuse the cached value.

### 5.4 Direction asymmetry (r5: post-swap-estimated signed rule)
The signed rule is evaluated on an **estimated post-swap price**, not the pre-swap price. In `beforeSwap` the hook has `amountSpecified`, the current `sqrtPriceX96`, and active liquidity via `StateLibrary`; a constant-liquidity approximation yields a post-swap price estimate good enough to price a fee (it only needs to be right about direction and order of magnitude). Then:

- **Restoring iff `|post − ref| < |pre − ref|`**: `deviationMult = 1.0`, so the swap pays `floor(session) × stalenessMult`, capped. Never below base and, in an elevated or closed session, the elevated floor, not bare base. A discount below the session floor is deliberately excluded because it invites wash flow that farms cheap rebalancing against the LP.
- **Adverse otherwise**: `deviationMult = f(|dev|)` evaluated at the estimated post-swap deviation (midpoint of pre and post is acceptable), so the fee scales with the gap the swap actually captures.

This closes both loopholes the pre-swap rule left open: at Friday close (deviation ≈ 0) a single optimally sized Monday swap is adverse and pays proportionally to the gap it takes, rather than `f(0) = 1.0` regardless of size; and a "restoring" buy sized to blast through the reference fails the `|post − ref| < |pre − ref|` test, so the overshoot is automatically adverse. This is StableSurge's insight (tax the side moving away from the peg) applied to the last official close, made size-aware. It converts the hook from "raise fees at night" into a market-microstructure mechanism: the toxic-flow premium is paid by informed traders and captured by LPs.

One honest caveat for the README: when the reference is stale, "restoring" means toward the last official close, not toward fundamentals — weekend noise flow pushing the pool back toward a reference that no longer reflects reality gets the cheap rate. This is intrinsic to any stale-reference design; the session floor bounds the damage.

### 5.5 Post-open decay
When the session transitions to regular hours and `updatedAt` turns fresh, the pool needs to reprice. Decay applies **only to `deviationMult`**: it is blended toward 1.0 over a short window (v1: 15 minutes, linear) so the pool can absorb the gap without permanently taxing the correcting trades. The session floor and `stalenessMult` are never decayed; a 9:31 halt with a frozen feed still pays the highest floor times staleness, and decay does not begin until `updatedAt` is fresh. Unit test: `test_noDecayWhileFeedFrozenAfterOpen`.

## 6. Workstreams

### Workstream A: Measurement (the empirical contribution)
**Minimum deliverable (the prize artifact):** one weekend, two pools (one stock/SPY, one stock/USDG):
- (a) stock-leg pool mid vs the prior close reference through the weekend (same two-feed rule as §5.3: for stock/USDG, pool price vs the stock's Chainlink close; for stock/SPY, pool ratio vs `stockFeed / quoteFeed`)
- (b) the reopen reprice path, 9:30 to 10:30 ET. **Note the demo window:** the first in-window weekend is Labor Day weekend — market closed Monday Sept 7, so the reprice lands Tuesday Sept 8 after ~90 hours of staleness instead of ~65. That is a longer-staleness natural experiment, not a complication, but the holiday table in `MarketHours.sol` is exercised by the demo itself (`test_laborDay2026_isClosed` is mandatory, not optional)
- (c) fork counterfactual: LP value retained with the hook vs unprotected (Workstream C)

That is a chart a UF reviewer can screenshot plus one fork number. **Optional, only if the pipeline is cheap:** realized LVR vs fees earned over the window. Do not let the LVR estimator eat the hackathon.

Thresholds to test against: AltStreet's published gates (2% spot-TWAP divergence, 10% premium, 30-minute staleness) as externally-sourced reference points.

Data path: no pre-built Uniswap subgraph exists for Robinhood Chain. Options, in order of verified support: (1) Envio HyperSync (robinhood.hypersync.xyz, free tier) for raw `Swap` logs from the PoolManager; (2) fork `Uniswap/v4-subgraph`, add a `networks.json` entry for chain 4663, and deploy to Goldsky, Ormi, or The Graph (all explicitly support the chain); (3) Dune. Robinhood Chain is live on Dune per Dune's announcement, but decoded v4 `PoolManager` tables are unconfirmed; treat as unusable until one query succeeds; (4) public RPC `eth_getLogs`, batched in small block windows. NodeFlare publishes the limits: 2 req/s per IP, 10 req/s with a free key. Decode price from `sqrtPriceX96`, adjust for decimals (USDG 6, stock tokens 18), normalize by `uiMultiplier()`.

### Workstream B: The hook
- `ClosingBellHook.sol`: `beforeSwap` fee override only. No `afterSwap`; dynamic-fee flag plus `beforeSwap` is the whole permission set
- `FeeCurve.sol` (pure library): staleness, deviation, direction, decay math; unit-testable without a chain
- `MarketHours.sol` (pure library): calendar-as-data session state (v1 source of truth for session); holiday table covered by `test_laborDay2026_isClosed` since the demo window exercises it
- `ChainlinkEquityAdapter.sol` (v1): Data Feed `latestRoundData()` for price and `updatedAt`, optional `quoteFeed` for non-dollar quote legs (stock/SPY, §5.3), per-block `uiMultiplier()` cache in transient storage, plausibility bound. Implements an `IMarketStateAdapter` interface so a Streams `marketStatus` adapter can replace it without touching the hook
- Mock oracle for unit tests; real feed for fork tests

### Workstream C: Evidence of effect
Fork test simulating a weekend: pool at Friday close, reference jumps at open, arbitrageur trades with and without the hook. **Non-negotiable modeling requirement (r5): the arbitrageur is one optimally sized swap**, not a sequence of small swaps — a sequence flatters the deviation curve and makes the headline number a strawman. Output: LP value retained with hook vs without, fee revenue captured from the arb, and the honest decomposition of where the protection came from (`floor × staleness` vs the deviation surcharge). If most of v1's protection turns out to be floor × staleness, that is a legitimate finding to publish, not a failure. This is the headline number.

### Workstream D: Submission
README (strategy → measurement → mechanism → edge cases → results → exact contract and line pointers), FEEDBACK.md, Uniswap Developer Feedback Form, ETHGlobal submission, testnet deploy if time allows.

## 7. Architecture

```
  swap ──────► Uniswap v4 PoolManager (Robinhood Chain: NON-CANONICAL address, verify)
                        │ beforeSwap
                        ▼
              ┌─────────────────────────────┐        ┌────────────────────────────────┐
              │ ClosingBellHook (beforeSwap)│ ◄───── │ IMarketStateAdapter            │
              │  session ← MarketHours.sol  │        │  v1: ChainlinkEquityAdapter    │
              │  isLive (3-part predicate)  │        │    Data Feed price, updatedAt  │
              │  staleness mult             │        │    uiMultiplier() per-block    │
              │  deviation mult (signed)    │        │    cache                       │
              │  post-open decay            │        │  prod: Streams marketStatus    │
              │  FeeCurve → min(floor×m×m,  │        │    (per-schema decode)         │
              │             cap) → override │        └────────────────────────────────┘
              └─────────────┬───────────────┘
                            ▼
                  swap executes at computed fee
```

Stack: Foundry, Uniswap v4-template, Solidity. Python for Workstream A.

## 8. Scope

### In scope (12 days)
- Workstreams A through D as defined above
- Unit tests for all pure libraries; fork tests for the hook against a real feed
- One measured weekend for at least two pools (one stock/SPY, one stock/USDG)
- README with the measurement chart and the fork-test result

### Out of scope
- Frontend
- Cross-wrapper arbitrage execution or any trading
- Non-EVM chains
- Permissioned / KYC-gated logic (compatible; separate concern)
- Corporate-action handling beyond multiplier normalization
- `afterSwap` tracking of any kind
- Audit-grade hardening
- Any interaction with the modified UniversalRouter (swaps in tests go through the PoolManager / test router, not the chain's production router)

## 9. Design decisions and open questions

| Decision | Final choice | Open question |
|---|---|---|
| Oracle (v1) | Free Chainlink Data Feeds for price and `updatedAt`; session from `MarketHours.sol` calendar | None for v1. Production: Streams `marketStatus` per-schema adapter behind `IMarketStateAdapter`; v10 `currentMultiplier` / `tokenizedPrice` if those streams exist for the wrappers (README footnote) |
| Oracle alternative considered | Not used: Pyth Pro | Pyth Pro exposes a `marketSession` field (regular / preMarket / postMarket / overNight / closed), the exact primitive this hook needs. Rejected for v1 because it is a paid off-chain WebSocket (~$500/mo, bearer auth) not deployed on Robinhood Chain, and its public Hermes price path is now paywalled. Keep this answer ready; a Uniswap engineer will ask |
| Liveness | Three-part predicate: `calendarOpen && fresh && plausible`. Seed: on first swap, `lastKnown = current feed price` and the plausibility branch is skipped until the next block | Plausibility bound width |
| Schema handling | Production adapter only | Which schema the Robinhood Chain Streams use (not needed for v1) |
| Stacking | Session sets a floor; `stalenessMult × deviationMult` on top; single `feeCap`. No fourth curve | Resolved |
| Deviation curve | Piecewise linear with cap, creator-set params | Quadratic for extreme deviations? |
| Direction | Signed rule on estimated post-swap price: restoring iff `|post − ref| < |pre − ref|` (overshoot through reference is adverse); adverse `f` evaluated at estimated post-swap deviation. Never below the session floor (wash-flow guard) | Resolved (r5) |
| First-trade protection | Adverse fee is size-aware via the constant-liquidity post-swap estimate, so the single optimal Monday swap pays proportionally to the gap it captures | How accurate is the constant-liquidity estimate across tick boundaries, and how much residual protection is `floor × staleness` alone? Fork test (§6C) reports the split |
| Post-open decay | 15 min linear | Adaptive on volume? |
| Multiplier | `uiMultiplier()` read on per-block cache miss only; normalize pool price | Resolved |
| Halts | Covered by frozen-timestamp branch of predicate → highest fee | Should a halt close the pool instead? (v1: no; stay open) |
| Parameter ownership | Immutable at init | Resolved: governance out of scope |

## 10. Timeline (Sept 4 to 16)

| Days | Focus | Deliverable |
|---|---|---|
| 1 (Fri) | Fetch Chainlink Data Feed addresses from rendered docs, verify on explorer, confirm `latestRoundData()` returns a usable `updatedAt` on chain 4663; AAPL multiplier convention check; scaffold Foundry + v4-template | Verified addresses committed to a constants file; repo compiles |
| 2 to 3 | **Workstream A first.** Data pipeline (Envio HyperSync, or a v4-subgraph fork), pull one weekend for SPY/USDG and one stock/SPY pool, decode, normalize, chart pool vs Chainlink close and the Monday reprice | Evidence chart; go/no-go on effect size |
| 4 to 6 | `FeeCurve` + `MarketHours` pure libraries with unit tests; `IMarketStateAdapter` interface; `ChainlinkEquityAdapter` v1: Data Feed `latestRoundData()`, three-part predicate, per-block `uiMultiplier()` cache, plausibility bound; hook wiring against mock | Hook logic complete against mock |
| 7 to 8 | Fork tests: real Chainlink feed, simulated weekend + open, arb vs LP with and without hook | Quantified LP-retention and fee-capture result |
| 9 | Direction asymmetry and post-open decay tuned against fork results; gas pass | Tuned v1 parameters |
| 10 to 11 | README, FEEDBACK.md, feedback form, testnet deploy if time | Submission-ready |
| 12 | Submit early. Tweet: repo, thesis, measurement chart. Tag @UniswapFND | Done |

LeetCode: one problem/day for the window. Ornn article starts Sept 17.

## 11. Verify-before-build checklist

- [x] Robinhood Chain v4 PoolManager address (`0x8366a39cc670b4001a1121b8f6a443a643e40951`): confirmed two ways in the evidence base. `eth_getCode` returns bytecode, and all 25,139 poolIds recompute as `keccak256(abi.encode(PoolKey))` from each pool's own currencies/fee/tickSpacing/hooks with zero mismatches. PoolIds in the evidence tables are cryptographically self-validating. Still not on Uniswap's deployments page; document that in the README
- [ ] **Multiplier convention (promoted; must precede deviation math).** Confirm which side `uiMultiplier()` lives on by checking one dividend-paying token (AAPL, multiplier 1.000566) against its Chainlink price and its pool price. Getting this backwards makes every dividend-paying token read a permanent phantom basis and the fee curve is wrong from the first swap
- [ ] **Chainlink equity feed proxy addresses (the real blocker)** for SPY, NVDA, TSLA, AAPL on Robinhood Chain. Docs render client-side; fetch in a browser, verify on Blockscout
- [ ] Confirm the Data Feed proxy addresses resolve on chain 4663 and that `latestRoundData()` returns a usable `updatedAt` (not zero, moves during regular hours, freezes when closed). Schema / `marketStatus` is a production footnote, not a build gate
- [ ] Levery's mechanism (UF-subsidized "toxic arbitrage mitigation" hook): confirm it does not already condition on market hours before writing the novelty claim
- [ ] Permissioned Pools: read the spec; confirm it does not express session state
- [ ] ETHOnline rules on pre-window code
- [ ] `uiMultiplier()` ABI on a live stock token (the convention check above depends on it)

## 12. Risks

- **Measured effect is small.** Workstream A runs first. If weekend deviation and Monday reprice are negligible for the priority pools, pivot early: the hook still works for extended-hours sessions, or the project reframes around staleness pricing. The measurement is publishable either way.
- **Selling the primitive honestly.** v1 is calendar-plus-staleness-conditioned fees on free feeds. The README must not imply `marketStatus` is read on every swap. If a reviewer asks why not Streams: credentials and subscription are gated; the adapter interface exists so it drops in.
- **Non-canonical PoolManager / router surprises.** All test swaps go through the PoolManager directly or the v4 test router. Never touch the production UniversalRouter.
- **RPC rate limits stall Workstream A.** Use Envio HyperSync or a deployed subgraph fork; fall back to batched small block ranges on the public RPC (2 req/s per IP, 10 with a free key). One weekend for two pools is enough.
- **Scope creep.** This document is the fence. Anything not in Section 8 waits until Sept 17.

## 13. Success criteria

Minimum: public repo, passing tests, README with measurement and mechanism, FEEDBACK.md, submitted to the Uniswap track.

Target: original weekend/open measurement for at least two pools; fork-test LP-retention number; testnet deploy; one tweet with the chart that gets ecosystem engagement.

Stretch: Uniswap Foundation prize; Hook Design Lab conversation; a Uniswap engineer in the interview loop asks about the three-part predicate or the multiplier handling.

## 14. Novelty claim, as it will appear in the README

Dynamic fees are commodity infrastructure. What is unoccupied is the conditioning variable. Every production LVR-mitigation design surveyed infers toxicity from a signal endogenous to continuous markets: realized volatility, deviation from a live reference, priority fees, inventory imbalance, or auction competition. For a tokenized equity, all of these read "calm" on a Sunday afternoon and quote their minimum fee at the moment the pool is maximally stale. The only prior market-hours-aware AMM design (`trading-days`) hard-reverts outside NYSE hours, sacrificing all off-hours flow. The capability itself is not hypothetical: Stork powers Ostium's 22 tokenized stocks on Arbitrum with market-hours logic and holiday calendars, built bespoke, per asset, with the protocol, for a peer-to-pool perp venue that also has an active risk manager, hedging rails, and funding to compensate its vault. A passive spot AMM LP has none of that. No published AMM design conditions LP protection on the trading calendar of the asset's underlying venue jointly with reference-price staleness while keeping the pool open, and nobody has made that capability a reusable AMM primitive. ClosingBell does: v1 prices the calendar plus Chainlink staleness and signed deviation from free on-chain feeds; the same interface takes Streams `marketStatus` in production. (Caveat in README: argument from the published landscape, not proof of absence; 489 distinct non-zero hook addresses are live on Robinhood Chain, most undocumented.)

**Anticipated critique, answered up front: "a cap that big is a soft halt with extra steps."** For the fee to matter against the documented 3 to 5% weekend gaps, `feeCap` must be of that order — v1 default in the 300 to 500 bps range, creator-set at initialization. At that cap, adverse flow near gap size is largely priced out, and that is the mechanism working, not the pool closing: the cap binds only for the toxic direction and size. Uninformed flow pays moderate session-floor fees and fills all weekend; restoring flow pays `floor × staleness` and fills; the only prior calendar-aware design (`trading-days`) hard-reverts every one of those trades. "Open" means open to everyone except the one counterparty the fee is designed to price.

## 15. Process note

This proposal lives in the repo at `docs/proposal.md`. ETHOnline's requirement is that the contribution is open-source; a public design doc demonstrates process and is an asset, not a liability.

## 16. Sources to cite in the README

- Chainlink Data Streams Market Hours and report schema docs (`marketStatus`, three-part guidance)
- Robinhood Chain docs: stock tokens, ERC-8056 multiplier, AP-only mint/burn
- Uniswap tokenized-securities launch (June 2026), Permissioned Pools (July 2026)
- Milionis, Moallemi, Roughgarden, Zhang: LVR
- AltStreet Tokenized Stock Reference Marks methodology and Aug 1 / Aug 31 spreads
- Birdeye Solana xStocks deviation corridor; Kraken/xStocks off-hours note; CoinGecko cross-venue spreads; Alandale "Trading Tokenized Stocks 24/7"
- Uniswap Labs Substack, "Hood morning" (~60% of tokenized-equity volume outside US hours)
- `horsefacts/trading-days`, Bunni v2 surge fees (MIT), Valantis HOT decay, Balancer StableSurge
- Stork / Ostium market-hours oracle pipeline (bespoke prior art for the capability)
- Pyth Pro `marketSession` (considered alternative)