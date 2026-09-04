# Pre-build review — Sept 4 2026

Findings from an adversarial review run before any contract code was written (`src/*.sol` were
stubs). Spec is `proposal.md` (r6); this file records what the review says must change, and is the
place those changes are tracked rather than editing the frozen spec.

Sources: four review passes (v4 mechanics, mechanism attack surface, novelty/prior art, oracle
failure modes) plus direct verification noted inline. Two passes were cut short — see
[§7 Unverified](#7-unverified-and-open).

---

## 0. The one thing that changes the design

**The deviation surcharge never fires on the trade the hook exists to price.**

`README.md` states the rule as *"trades that move the pool toward the reference pay only the
session floor"* and separately describes the target trade as an arbitrageur who, at the reopen,
*"trades the gap against the passive LP in one swap."*

Those are the same trade. LVR **is** the restoring trade — arbitrage toward fair value is
definitionally price-restoring. So at the Sunday 20:00 ET reference wake:

- the gap-capturing swap moves the pool *toward* the new reference → `deviationMult = 1.0`
- the gap was revealed by a *fresh* print → `stalenessMult = 1.0`

```
fee = closedFloor × 1.0 × 1.0 = closedFloor
```

Both multipliers sit at their minimum at the most toxic instant of the week. At the Monday 9:30
open it is worse: session `Regular`, feed live, trade restoring → `fee = baseFee`, i.e. **5 bps on
SPY/USDG — bit-for-bit identical to the unhooked pool.**

What remains is a flat elevated weekend fee. That has real value (see §1) but it needs no oracle,
no calendar and no hook.

**Consequence for Workstream C.** The planned control ("hook vs unprotected") compares
`closedFloor` to 5 bps and will produce a large number that means nothing. The honest control is
**a static fee equal to the hook's average realized fee**, and as specified the hook cannot beat
it, because 100% of its protection comes from a term with no swap-dependence.

**Fix — F1.** The restoring exemption must cover **pool-created deviation only, never
reference-created deviation.** The adapter already keeps `lastKnownPrice` for the plausibility
check; store the pool price alongside it. Deviation that appears because the reference moved is
charged `f(·)`; deviation the pool created itself keeps the exemption. One extra storage word,
pure math, no funds, no deltas, no blocking.

**Where this lands.** Cheap during the dark window, spiking at the reopen, decaying over ~15 min —
which is *Fables' shape*, reached independently from our own premises rather than from theirs.
Together with the adverse-selection argument (§3, A8) this gives a theoretical reason to expect
the reopen carries the toxicity. Workstream A's job changes from **picking the shape** to
**sizing the spike**.

---

## 1. Baseline arithmetic (adopt this for all sizing)

Linearize around the reference. `m` = notional per unit relative displacement (`m = L·√V/2`),
`g` = relative gap, `φ` = fee rate. An arb trades until the pool is inside the no-arb band:

- **arb profit = LP loss = `m·(g−φ)²/2`** (zero-sum; fees are a transfer)
- **the arb declines entirely iff `φ ≥ g`** — not `g/2`
- **LP loss avoided = `1 − ((g−φ)/g)²`**

Against the measured SPY weekend gap of **0.53%**:

| fee on the reopen trade | LP loss avoided |
|---|---|
| 5 bps (SPY/USDG today, no hook) | 18% |
| 30 bps | 81% |
| 53 bps (= g) | 100% |

For a 3% earnings gap: 100 bps → 55%, 200 bps → 89%, 300 bps → 100%.

Two conclusions. The `feeCap` instinct of 300–500 bps is the right order of magnitude. And there
is **no interior optimum** against the arb — more fee is monotonically better — so the entire
design problem is **discrimination**: charging `φ ≈ g` to the arb and ~base to noise. The
deviation term is the only instrument for that, which is why §0 is load-bearing.

---

## 2. Mechanism attacks, ranked

| # | Attack | Severity | Fix |
|---|---|---|---|
| A1 | Restoring exemption + staleness collapse nullify both multipliers at the reopen | **Fatal to thesis** | F1 |
| A2 | Estimator forced to say "restoring" via flash-loaned JIT liquidity | **Fatal to r5 claim** | F3 |
| A3 | Endpoint fee is superadditive → swap splitting; routers split for free | High | F2 |
| A4 | Sandwich amplification: displace to spike victim's fee, harvest via own JIT | High | F3 |
| A5 | Pre-displacement: buy `2δ` of adverse movement at the restoring rate | High | F2 |
| A6 | Chainlink 86400s heartbeat / 0.5% threshold breaks halt detection and misfires staleness | High | F4 |
| A7 | Decay window is a no-op for its purpose; `freshSince` is attacker-scheduled | Medium | F5 |
| A8 | Adverse selection: a higher floor selects surviving flow toward toxicity | Medium (thesis) | argue it, §3 |
| A9 | JIT dilutes fee revenue (but not LVR avoided) | Medium | reframe, §3 |
| A10 | Unguarded external calls break "never blocks a swap" | Medium | F6 |
| A11 | Implementation landmines | Medium | §5 |
| — | Donations | **not a vector** | — |

### A2 — forcing "restoring"

`StateLibrary.getLiquidity` returns the **active tick range's** liquidity, and the estimator
extrapolates it across the whole swap. Direction can't be faked; *magnitude* can, and magnitude is
what the overshoot test turns on. One transaction: add `L_fake` in a narrow range at the current
price → swap (estimator predicts tiny impact, concludes restoring) → remove. The real swap eats
the narrow range, falls off the liquidity cliff, and blasts through the reference.

Cost to make the estimate read `δ` on notional `N` in a range of relative width `w` is `≈ N·w/δ`.
With `N = $1M`, `δ = 0.5%`, a 1-tick range: **~2% of notional, and flash-loanable.** This defeats
the r5 post-swap-estimate fix outright.

It also fails the *other* way naturally: on a pool with a thin active tick and deep neighbours
(tickSpacing 60 on the 0.30% pools), the estimator overshoots and honest restorers get surcharged.
`verified-onchain.md` §4 already shows the dispersion — the thin 0.05% AAPL pool at +2.47% while
the deep pool was 0.004% off. Thin pools under this hook would pay near-cap forever and never
converge.

### A3 — splitting, and the router that does it for you

Charging `f(d_post)` on the whole notional makes cost depend on the swap's decomposition, not its
endpoints. For any increasing `f`, endpoint value exceeds path average. With
`floor × staleness = 100 bps`, `f(d) = 1 + 100·d`, cap 400 bps, a 3% adverse move:

| strategy | fee |
|---|---|
| 1 swap (endpoint rule) | 400 bps (at cap) |
| 2 swaps | 325 bps |
| 10 swaps | 265 bps |
| N→∞ | 250 bps |

**Endpoint evaluation leaks 37.5% of the surcharge**, and chain 4663 has 0.1s blocks — gas is not
a deterrent. Note the correction to the doc's framing: the curve does not need to be **convex** in
size; convexity is what splitting defeats. It needs to be **path-additive**.

**The router splits for you.** With 2,435 sibling stock/USDG pools running static fees, an
optimizing router allocates until marginal cost equalizes — so the hooked pool receives exactly
the first, cheapest slice of every arb and the rest goes elsewhere at 5 bps. In a multi-pool world
**the hook does not price toxic flow, it declines it.** "LP value retained" will read ~100%
because volume goes to zero. The metric that separates a working mechanism from a soft halt is
**LVR avoided vs fee revenue forgone**.

This also inverts r5's "non-negotiable modeling requirement". The doc forbids modeling the arb as
a sequence because a sequence flatters the deviation curve — correct diagnosis, backwards
conclusion. The arb will split *precisely because* it flatters them. Model the adversarially
optimal strategy (split, plus an A5 pre-displacement leg) as the headline; report the single-swap
number as the upper bound.

### A5 — pre-displacement

The endpoint rule is all-or-nothing, so a trader wanting to buy `N` can first **sell** to displace
the pool to `R(1−δ)` (adverse, on notional `N' ≈ N/2`), then **buy** `N + N'` and have the entire
swap classified restoring. With `δ = δ_N/2`, the maneuver is cheaper iff `k·δ_N > 4/3` — i.e.
**whenever the deviation surcharge exceeds ~2.33×**, which is exactly the regime the mechanism
needs to operate in. At `k·δ_N = 4`: 25% saving, and it composes with A3.

On the related question: a *pure* wash round trip never pays (gross P&L zero, cost ≥ `2·F·N`), so
the floor is a sufficient guard there. But the round trip **embedded in a directional trade** is
the attack, and the floor does nothing against it — the floor is what makes the escape leg cheap.

### A6 — the feed's own parameters

From `verified-onchain.md` §1: **heartbeat 86400s, deviation threshold 0.5%.**

1. **Halt detection is structurally weak.** A healthy quiet stock legitimately carries a 20-hour-old
   `updatedAt`. Detecting a 10:00 halt needs `maxStaleness ≪ 86400`, which false-positives
   constantly. This weakens novelty claim #2 against Fables' manual bitmap.
2. **The staleness tax fires on calm days.** No 0.5% move → no update → `updatedAt` ages →
   `stalenessMult` climbs on a healthy market. Backwards, and it will show on any weekday fork test.
3. **A permanent 50 bp deadband.** The reference may be 0.5% wrong at all times — comparable to the
   0.53% weekend gap. Any deviation slope below 50 bps measures feed lag, not pool mispricing.

### A7 — the decay window

Stated purpose is "so the pool can absorb the gap", but gap-absorbing trades are restoring, which
is already `1.0`. **Decay toward 1.0 cannot make 1.0 cheaper.** What it actually does is discount
**adverse** trades during the most informed 15 minutes of the day. Both readings of the ambiguous
spec are exploitable (a scheduled 9:45 discount, or a free 9:30 window), and `freshSince` is
written on the permissionless swap path, so a searcher chooses when the window falls.

---

## 3. Two objections to argue rather than fix

**A8 — adverse selection.** Flow is a mixture: noise traders trade iff `b > φ`, informed iff
`g > φ`. Raising `φ` to 100–200 bps eliminates most noise and barely dents a 3–5% informed edge.
Volume falls and the *toxicity share* of the remainder rises. `README.md`'s two claims — "adverse
flow near gap size is largely priced out" and "uninformed flow pays moderate session-floor fees and
fills all weekend" — are governed by the same `φ`, differing only by `deviationMult`. Per §0 that
term is 1.0 on the trade that matters, so the claims are in direct contradiction until F1 lands.

Compounding effect: the hook taxes any trade moving the pool away from the frozen Friday close, so
the pool is **pinned** to Friday's close by the fee structure — contradicting the premise that the
pool is the only weekend price discovery, and **maximizing the gap waiting at Sunday 20:00**, which
is then handed over at the floor rate. The existing one-line caveat understates this; the two
effects compound rather than being independent.

**A9 — JIT.** The naive objection is wrong and we should say so: a JIT LP fronting the reopen arb
has P&L `−q·m·(g−φ)²/2 < 0` for all φ — pure adverse selection, JIT capital will not show up.
The real form is that raising the weekend fee 5 → 200 bps is a 40× prize on flow with *no* adverse
selection.

The defensible answer holds. Decompose the benefit to passive LPs:

- **fee revenue** — JIT-dilutable
- **LVR avoided** — accrues to whoever *holds* the position when the arb declines; JIT LPs don't
  hold, so **not dilutable**

At `φ = g` the arb doesn't trade: revenue is zero, avoidance is 100%. **The protection is
deterrence, not revenue**, and only the revenue half leaks. State the decomposition explicitly and
the objection becomes an asset. The one real anti-JIT lever (withdrawal penalty via
`beforeRemoveLiquidity`) requires taking deltas — out of scope; name the limitation, and note it is
shared with every dynamic-fee hook.

---

## 4. v4 mechanics — corrections to `architecture.md`

Verified against vendored source: `uniswap-hooks` v1.2.1 (`acbd604`), `v4-core` `d153b04`,
`hookmate` v0.6.0.

**Adopt `BaseOverrideFee`** (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol`). It is exactly this
hook's shape — `_getFee` is the only thing to implement — and the `OVERRIDE_FEE_FLAG` OR lives in
the base, which removes the failure below.

1. **The silent 0% fee.** A returned fee *without* `OVERRIDE_FEE_FLAG` does not fall back to a
   stored default. `LPFeeLibrary.getInitialLPFee` returns **0** for dynamic-fee pools and the hook
   never calls `updateDynamicLPFee`, so the swap executes at **zero LP fee**. `architecture.md:161`
   describes this as falling back to "its stored dynamic fee" — it is the worst-case silent failure,
   not a benign one.
2. **Units: v4 fees are pips (1e-6), the docs are in bps.** `feeCap` 300–500 bps = **30_000–50_000**,
   against `MAX_LP_FEE = 1_000_000`. `removeOverrideFlagAndValidate` **reverts** `LPFeeTooLarge`
   rather than clamping, so a 100× units slip reverts every swap in the pool. Needs an explicit unit
   note in `FeeCurve` and a `fee <= MAX_LP_FEE` fuzz invariant.
3. **Permission bits are `0x3080`, not `…080`.** `BaseOverrideFee` alone forces `afterInitialize`
   (`0x1080`); adding the `beforeInitialize` gate makes it `0x3080`
   (`BEFORE_INITIALIZE 1<<13 | AFTER_INITIALIZE 1<<12 | BEFORE_SWAP 1<<7`). The "every Fables RWA
   hook ends …080" remark does not transfer.
   - `HookMiner` is in **`@uniswap/v4-periphery/src/utils/HookMiner.sol`**, not `hookmate`
     (`architecture.md:163` is wrong); `script/testing/00_DeployV4.s.sol:5` already imports it
     correctly. CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`; `BaseScript.sol:27`
     has no mining step yet.
   - Mining cost is **flat in the number of bits** — `HookMiner` tests equality on all 14 masked
     bits, so 3 bits costs the same ~16k iterations as 1. No reason to economize on flags.
   - `BaseHook._beforeInitialize` is `revert HookNotImplemented()`. Adding the bit **without**
     overriding the function makes every pool initialization revert, including ours.
   - Keep `afterInitialize: true` — its `_afterInitialize` is the only thing enforcing
     `key.fee.isDynamicFee()`.
4. **Registration must precede `initialize`.** `PoolManager.initialize` has **no `hookData`
   parameter at all**; neither init hook receives any. So per-pool params need a separate
   `register(PoolKey, Params)` call *before* initialize, `beforeInitialize` is the gate that checks
   it, and params live in `params[poolId]` storage, write-once — **not `immutable`** as
   `README.md:75` and `architecture.md:132` imply. Gate on the whole key (`poolId` includes
   `tickSpacing`). `Hooks.noSelfCall` means `beforeInitialize` is skipped if the hook itself calls
   `initialize` — don't route registration through the hook.
5. **`feeCap` bounds the LP leg only.** Protocol fee composes on top as `p + lp − p·lp/1e6`, up to
   0.1%. The writeup should not claim the cap bounds what the trader pays.
6. **Pool state reads are cheap and correctly timed.** `Pool.swap` snapshots `slot0Start` and does
   not write back until after `beforeSwap` returns, so the estimator reads genuine pre-swap state —
   the approach is sound. `getSlot0` is a warm SLOAD (~250–350 gas, `checkPoolInitialized` already
   touched it); `getLiquidity` ~2.3k. Budget ~2.6k. The oracle calls and the holiday table are where
   the gas actually goes — prefer a packed bitmap or binary search over a linear scan in
   `MarketHours`.

---

## 5. Implementation landmines

- **`amountSpecified` sign.** v4: negative = exact input, positive = exact output. Reversing it
  inverts every direction classification, and the exact-output branch needs a *different* estimator
  formula, not a flipped sign.
- **`sqrtPriceLimitX96` must clamp the estimate.** Swapper-controlled and binding on the real swap;
  ignoring it misclassifies limit-protected restorers as overshooting.
- **`lastKnownPrice` and `freshSince` are attacker-scheduled** — both written on the permissionless
  swap path. Prefer deriving plausibility from the feed's own round history
  (`getRoundData` / `answeredInRound`). Also: if `getMarketState()` writes, it is not `view`,
  contradicting the architecture doc's signature and adding an SSTORE to every swap.
- **First-swap seeding** with plausibility skipped lets an attacker be the first swapper at a moment
  of their choosing, with the check disabled.
- **`getLiquidity` is current-range only**, not path liquidity. Comment it so nobody later mistakes
  it.
- **The plausibility bound can wedge the pool.** At a documented 3–5% weekend gap, a `plausibilityBps`
  set below the real gap judges the wake print implausible → `isLive = false` → highest floor,
  possibly forever. Fail-safe direction, but confirm it is an *exitable* state.
- **Clamp the fee before the OR, and round up.**

---

## 6. Novelty — the claim is two claims wide and one is gone

Three hooks not in `prior-art-fables.md`:

- **`BallastHook`** — `github.com/dny-777/ballast`, pushed **Sept 3 2026**. Header states *"a swap
  pushing the pool price further away from the oracle price is treated as toxic"*, cites
  Milionis/Moallemi/Roughgarden, and credits **Uniswap Hook Incubator's taught "Nezlobin's
  Directional Fee."** Discounts restoring (1500 vs 3000 base), surcharges adverse by |dev| up to
  15000. **This is our `deviationMult`.** Reverts on stale (`DEFAULT_MAX_ORACLE_STALENESS = 3600`);
  zero calendar references.
  → **Direction asymmetry relative to a reference is dead as a novelty claim.** It survives only as
  a refinement: Ballast discounts *below* base for restoring trades, we refuse to (wash-flow
  argument), and we evaluate direction on a post-swap estimate.
- **`StockShieldHook`** — `github.com/ayush18pop/stockshield.eth`, Jan 2026, *"The Protection Layer
  for Tokenized Stock LPs."* Seven-regime session enum, per-regime fee floors **and** per-regime
  staleness bounds — uncomfortably close to "jointly". Survives on two clauses: staleness is a
  **revert gate**, never a fee input (`MAX_STALENESS_CORE = 60`, which reverts every weekend swap
  against a `us_equities_24/5` feed); and the fee is not computed on-chain at all — an off-chain
  `yellowSigner` ECDSA-signs it and the hook only bounds-checks. **Cite it explicitly.**
- **`FlockStockPairHook`** — `github.com/FLock-io/flock-v4-hook`, repo created **Sept 4 2026
  09:24 UTC**. Dynamic-fee hook for FLOCK / Robinhood Stock Token pools on Robinhood Chain. Raises
  fee when the calendar is closed, rationale *"the AP cannot mint stock tokens, LPs carry the gap
  risk alone"* — our argument, our ordering, reached independently hours before our window opened.
  **Zero oracle references**, so it does not touch the joint claim, but it ends the "lone dissenter
  against Fables" framing.

**Levery — checklist item closed, no collision.** Per `docs.levery.io`: oracle-to-pool divergence
drives fees, plus AML/KYC in hook callbacks. Pure |deviation| magnitude — no calendar, no
`updatedAt`, no direction conditioning, no equities. (Fee engine is closed-source, so this is "no
public evidence", not proof of absence.)

**What survives, and it is real:** every implementation that reads `updatedAt` (Ballast,
StockShield) **reverts** on it; every implementation that prices an equity calendar (Fables, FLock)
carries **no reference price**. *Nothing prices staleness as a continuous fee input.* Proposed
narrowing:

> No surveyed hook prices reference-price staleness. The two that read `updatedAt` at all —
> Ballast, StockShield — revert on it; the two that price an equity calendar — Fables, FLock —
> carry no reference price. ClosingBell is the only one that reads the feed every swap and converts
> staleness into fee rather than into a revert, and the only one whose calendar and feed jointly
> form a liveness predicate that resolves an open-but-frozen market to the highest floor.

### README accuracy fix (independent of the novelty question)

`README.md:184` implies Fables believes the closure is not toxic. Their verified source says the
opposite. `SessionLib.FloorConfig`'s `closedSpike` docstring: *"That open is the most toxic — a
whole weekend of off-venue price discovery the pool is blind to."* And `_validateFloorConfig`
states *"No ordering is imposed on the three floors. They are independent session prices"* — the
quoted calibration is a current setting, flippable with one `setPoolConfig` call, not a design
commitment. `prior-art-fables.md` §3 already states the disagreement correctly (it is about
*where* toxicity is realized); the README flattens it into something their source refutes in
writing.

Fables re-verification otherwise holds: Sourcify reports `creationMatch`/`runtimeMatch` **exact**
for both hooks, and they contain no oracle — contribution 1 is safe.

---

## 7. Unverified and open

Two review passes were stopped before finishing. These remain open:

- **Adapter failure modes are unverified.** Whether `latestRoundData` can revert on chain 4663,
  aggregator phase-transition behaviour, `minAnswer`/`maxAnswer`, and whether the stock tokens are
  upgradeable proxies that could remove `oraclePaused()` / `uiMultiplier()`. **F6 (wrap every
  external call in `try/catch`, fail to `isLive = false`) should be implemented regardless** — it
  makes the "never blocks a swap" claim true rather than aspirational, and `getMarketState()` should
  be total.
- **The live multiplier re-check did not complete.** `verified-onchain.md` §4 explicitly asks for
  re-verification during regular hours; the existing result is one post-market observation. Next
  window is Tuesday Sept 8 (Monday Sept 7 is Labor Day).
- **Permissioned Pools deployment on chain 4663** — not confirmed either way.
- **`eth_getLogs` range limits and rate limits** on the primary RPC. Partial finding: the limit is
  **compute-weighted, not request-count**, so pacing must be by call cost. Untested at scale.

**Backfill works — nothing was time-critical.** Verified directly: block 36,634,737
(2026-08-14T23:06Z) returns full data from `rpc.mainnet.chain.robinhood.com`, ~3 weeks deep. The
Sept 4–8 Labor Day window can be reconstructed after the fact.

**Permissioned Pools collision (verified directly, deployment status aside).** `PoolKey` has exactly
one `hooks` field (`PoolKey.sol:21`), and `Uniswap/v4-hooks-public`'s
`src/permissioned-pools/PermissionedHooks.sol` claims `beforeInitialize`, `beforeSwap`, `afterSwap`
and `beforeAddLiquidity`, returning fee `0` with **no** `OVERRIDE_FEE_FLAG`. So a pool cannot run
both that hook and this one — ClosingBell's logic would have to be composed *into* a
`PermissionedHooks` subclass (its `_beforeSwap` is `virtual`). Worth one line in the writeup: our
fee is a pure function of pool state, calendar and oracle — **identity-free** — so it composes with
a permissioning layer instead of duplicating it, and needs no router allowlist and no trusted
`hookData`.

---

## 8. Fix list

| | Fix | Kills | Cost |
|---|---|---|---|
| **F1** | Restoring exemption covers pool-created deviation only, never reference-created | A1 | 1 storage word + pure math |
| **F2** | Charge the notional-weighted **path integral** of the fee density, not the endpoint value; apply the restoring/adverse split *per unit* | A3, A5; hardens A2 | ~30 lines of pure `FeeCurve` (trapezoid over the knots) |
| **F3** | Anchor price **and** liquidity to values that cannot move in-block: `(blockNumber, sqrtPriceX96, liquidity)` in one slot. Use `L_eff = min(current, cached)`. Classify restoring only with margin `ε` and against *pessimistic* liquidity — fail adverse, not restoring. Clamp the estimate to `sqrtPriceLimitX96` | A2, A4 | reuses the slot F5 frees; costs 100 ms responsiveness on a 0.1s chain |
| **F4** | Deviation curve's first knot at **≥ 50 bps** (outside the feed's own deadband); split `maxStaleness` into a short bound gating the *deviation* term and a long one tied to the 86400s heartbeat for `isLive` | A6 | parameter shape only |
| **F5** | Delete `freshSince`; derive the decay window from the calendar, and repoint it at the F1 reference-jump surcharge | A7 | removes the only swap-path SSTORE |
| **F6** | `try/catch` every external call in the adapter; fail to `isLive = false` + `closedFloor`. `getMarketState()` must be total | A10 | adapter-local |

F2 is the generalization of the midpoint rule the spec lists as "acceptable" — promote it to
primary. The cap-induced split leakage that remains (~12.5% in the worked case) is irreducible with
any cap; state it rather than fix it.

## 9. Things to state honestly rather than fix

- **Cap-induced split leakage**, ~12.5%. Bounded, small, unavoidable.
- **"Restoring" toward a stale anchor during the dark window.** Intrinsic — but sharpen the caveat
  per §3: the mechanism *pins* the pool to the stale price and thereby maximizes the reopen gap.
- **JIT dilution of fee revenue.** Only the revenue half leaks; LVR avoided does not. Make the
  decomposition explicit.
- **Multi-pool routing around the hook.** Real, unfixable by a single hook. Reframe the headline
  metric to **LVR avoided vs fee revenue forgone**.
