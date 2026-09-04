# Prior-art verification — Sept 4 2026

Independent confirmation of the prior-art findings in `pre-build-review.md` §6, which originated
from a single automated review pass. Every claim below was re-checked directly against the GitHub
API, raw source, and Sourcify. **All four verified; nothing was overstated.**

---

## 1. `BallastHook` — CONFIRMED

`github.com/dny-777/ballast`, `src/BallastHook.sol`, 1,492 lines.

| Claim | Verified |
|---|---|
| Created 2026-08-19, pushed 2026-09-03 | `created_at 2026-08-19T05:03:24Z`, `pushed_at 2026-09-03T18:31:33Z` |
| Directional toxicity framing | `:42` *"pool price further away from the oracle price is treated as the toxic/arbitrage signature"* |
| Cites Milionis/Moallemi/Roughgarden | `:43` |
| Credits UHI's taught Nezlobin fee | `:53` *"Uniswap Hook Incubator's taught \"Nezlobin's Directional Fee\""*; again at `:378`, `:1342` |
| Fee constants 3000 / 1500 / 15000 | `:172` `BASE_FEE = 3000`, `:176` `DISCOUNTED_FEE = 1500`, `:181` `MAX_SURCHARGE_FEE = 15000` |
| Reverts on stale, 3600s default | `:194` `DEFAULT_MAX_ORACLE_STALENESS = 3600` |
| Corrective/adverse classification | `:1351` `_signal1` returns `(isToxic, isCorrective, deviationBps)`; branches at `:1377`–`:1389` |
| **No calendar whatsoever** | grep for `weekend\|holiday\|NYSE\|dayOfWeek\|session` → **0 hits** |

Note: repo has **no license file** (`license: None`), so it is not open-source licensed despite
being public. Cite it, don't copy from it.

**Verdict: direction asymmetry relative to an oracle reference is confirmed dead as a novelty
claim.** It is not merely prior art — it is *taught curriculum*, which is worse, because
UHI-adjacent judges already know it.

## 2. `StockShieldHook` — CONFIRMED

`github.com/ayush18pop/stockshield.eth`, `contracts/src/StockShieldHook.sol`, 727 lines.
Created 2026-01-29, pushed 2026-02-11. Description verbatim: *"The Protection Layer for Tokenized
Stock LPs."* No license file.

| Claim | Verified |
|---|---|
| Multi-regime session enum | `:30` `enum Regime` |
| Regime-selected staleness bounds | `:87` `MAX_STALENESS_CORE = 60`, `:88` `MAX_STALENESS_EXTENDED = 120` |
| **Staleness is a revert, not a fee input** | `:133` `error OracleStale()`, thrown `:360` |
| Fee is signed off-chain, not computed | `:109` `yellowSigner`; `:253` fee = `_validateSignedFee(regime, signedState.recommendedFee)`; ECDSA check `:422` |
| Hook only bounds-checks the signed fee | `:461` `if (recommendedFee < params.baseFee \|\| recommendedFee > maxFee) revert` |
| `_calculateDynamicFee` exists but is unused | defined `:467`, not reached from the swap path |

**Verdict: closest thing to the joint claim, and it must be cited.** It survives only on our two
escape clauses — it reverts rather than prices, and it computes nothing on-chain. A 60-second
staleness bound reverts every weekend swap against a `us_equities_24/5` feed.

## 3. `FlockStockPairHook` — CONFIRMED

`github.com/FLock-io/flock-v4-hook`, `src/FlockStockPairHook.sol`, 419 lines. **MIT licensed.**
`created_at 2026-09-04T09:24:55Z`, `pushed_at 2026-09-04T12:27:10Z` — i.e. created roughly seven
hours before this review, on our chain, in our problem space.

| Claim | Verified |
|---|---|
| Description | *"FlockStockPairHook: dynamic-fee Uniswap v4 hook for FLOCK / Robinhood Stock Token pools on Robinhood Chain"* |
| Calendar closure logic | `:290` `function isMarketClosed(uint256 timestamp) public pure returns (bool)` |
| Raises fee when closed | `:403` `if (cfg.closedMarketFee > fee && isMarketClosed(block.timestamp)) fee = cfg.closedMarketFee;` |
| The AP rationale — **our argument** | `:402` *"Closed market: the AP cannot mint stock tokens, LPs carry the gap risk alone."* |
| Price-independent | `:35` *"The fee depends only on configuration and time, never on the pool tick"* |
| **Zero oracle references** | grep for `oracle\|chainlink\|latestRoundData\|updatedAt` → **0 hits** |

**Verdict: does not touch the joint claim** (no reference price at all), **but it ends the "lone
dissenter against Fables" framing.** They reached our floor ordering independently, from our exact
argument, hours before our build window opened.

## 4. Fables `closedSpike` — CONFIRMED, and the README correction stands

Sourcify, chain 4663, `0x66622f77B797D506e5376F7798b67ab288966080`:

```
creationMatch: match   runtimeMatch: match   verifiedAt: 2026-08-25T04:24:02Z
48 source files
```

`SessionLib.sol`, `closedSpike` docstring, verbatim:

> *"A post-closure open (Monday, the morning after a holiday) descends from this ABSOLUTE peak
> instead. That open is **the most toxic — a whole weekend of off-venue price discovery the pool is
> blind to** — yet `closedFloor` is the cheapest tier, so pricing its spike as
> `closedFloor * spikeMult` put the LOWEST spike on the WORST open. Setting it absolutely decouples
> the post-weekend peak from the (cheap) weekend floor."*

`FablesRWA.sol`, `_validateFloorConfig`, verbatim:

> *"**No ordering is imposed on the three floors. They are independent session prices** — the
> calibrated shape is open > overnight > closed (the open and its bells are the toxic windows, not
> the closure) — and the calendar no longer promotes flanking hours to CLOSED..."*

**Both readings hold.** Fables does **not** believe the closure is harmless — they agree the
weekend's accumulated information is the dominant risk and engineered `closedSpike` specifically to
price it. And the quoted ordering is an explicitly *uncommitted calibration*, flippable via
`setPoolConfig`, not a design position.

`prior-art-fables.md` §3 already frames this correctly (the disagreement is about *where* weekend
toxicity is realized). **`README.md:184` flattens it into a claim their own source refutes in
writing, and should be fixed.**

**Incidental corroboration:** `SessionLib.sol` states *"All fee values are pips (1e-6)"* —
independently confirming the units hazard in `pre-build-review.md` §4.2, from a production hook on
the same chain.

---

## Bottom line

Nothing in the prior-art findings was fabricated, misdated, or misquoted. The novelty narrowing
proposed in `pre-build-review.md` §6 is justified and should be adopted:

- **Drop** direction asymmetry as a novelty claim → demote to a one-line refinement (no discount
  below the session floor; direction evaluated on a post-swap estimate).
- **Cite** StockShield explicitly, with the revert-vs-price and off-chain-signing distinctions.
- **Soften** the "opposite, falsifiable thesis" framing — FLock independently reached our ordering,
  and Fables' source agrees the weekend accumulates the information.
- **Keep and sharpen** the surviving claim: *nothing prices reference-price staleness as a
  continuous fee input.* Everything that reads `updatedAt` reverts on it; everything that prices an
  equity calendar carries no reference price.
