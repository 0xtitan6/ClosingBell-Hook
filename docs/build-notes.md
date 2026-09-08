# Build notes

Corrections to r7 found after the proposal froze. Per proposal §status, further changes go in the
repo, not the doc — this is that file. Each entry names the spec text it overrides.

---

## B1 — The staleness halt detector does not work on these feeds

**Overrides:** `README.md` "Liveness predicate" ("A stale `updatedAt` while the calendar says open
is the halt detector") and `proposal.md` §6A.

**Evidence** — `verified-onchain.md` §2, the measured SPY round history:

```
r113  766.14  Sun 08-30 20:00 ET
r114  767.49  Mon 08-31 20:00 ET    (exactly 86401s later = heartbeat)
```

Consecutive round IDs, exactly one heartbeat apart. Monday 08-31's entire regular session lies
between those two prints with no update: SPY moved +0.18%, under the feed's 0.5% deviation
threshold, so nothing fired. This is not an outage — it is a normal quiet day on a low-volatility
index ETF with a wide threshold.

**Consequence.** At 14:00 ET that Monday — peak liquidity, market open, nothing wrong — `updatedAt`
is 18h old. Any `maxStaleness` tight enough to catch a halt (LULD halts run 5–15 min, so
minutes-to-an-hour) makes `isLive = false` and charges `closedFloor` in the middle of a normal
trading day. The bind admits no single constant:

- tight `maxStaleness` → halts detected, quiet regular sessions taxed at the closed rate
- loose `maxStaleness` (> 86400s heartbeat) → no false positives, no halt ever detected

On a 0.5%-threshold / 86400s-heartbeat feed a quiet market and a halted market are
indistinguishable through `updatedAt`. Retract the claim rather than tune the parameter.

**Resolution.** Set `maxStaleness` loose — above the heartbeat — so `isLive = false` means "the feed
is dead for days," a safety net rather than a halt detector. Halts are covered by the deviation
term instead: during a halt the reference freezes while the token keeps trading, so the pool drifts
off it and `deviationMult` climbs on its own. Targeted, threshold-free, and it already exists.
Real `marketStatus`-based halt detection stays where it already was — the Data Streams production
adapter, behind the same `IMarketStateAdapter` seam.

---

## B2 — Staleness ramp is calendar-derived, not print-age-derived

**Overrides:** `architecture.md` §4, `FeeCurve.stalenessMult(Params, updatedAt, nowTs)`.

Follows from B1: if raw print age cannot be trusted as a liveness signal, it cannot drive the fee
ramp either. Note staleness was never load-bearing for the weekend anyway — `calendarOpen` is false
from Friday evening through Sunday 20:00 ET, so the session floor fires on its own. What
`stalenessMult` contributes is the ramp *within* the ~52h dark window.

Drive that ramp off time since session close instead of time since last print:

```solidity
// was
stalenessMult(Params, uint256 updatedAt, uint256 nowTs) -> uint256   // 1e18

// is
stalenessMult(Params, Session session, uint256 lastCloseTs, uint256 nowTs) -> uint256
```

Same curve shape, no false positives, and `lastCloseTs` is a pure `MarketHours` derivation — no new
state and no new external call. This is the same principle `architecture.md` §5 already applied when
it deleted `freshSince[poolId]`, now stated once and applied consistently:

> **Calendar time drives ramps. Feed time drives liveness only.**

`MarketHours.sol` gains `lastCloseAt(uint256 tsUTC) -> uint256`. Build it in step 2 with the rest of
the calendar, before `FeeCurve` needs it.

---

## B3 — Floor ordering: `elevatedFloor` should sit near `baseFee`

**Refines:** `README.md` "Parameters" (the three floors, all `[TBD: tuned]`).

`us_equities_24/5` (r6, `verified-onchain.md` §2) splits the week into three regimes, not two:

| Regime | Hours/week | Reference | Protection available |
|---|---|---|---|
| Regular | ~32.5h (19%) | live | base fee, deviation term working |
| Weekday off-hours | ~83.5h (50%) | **live** | deviation term working |
| Weekend dark | ~52h (31%) | frozen | floor × staleness only |

Half the week is off-hours *with a live reference*, where the deviation surcharge does targeted
work and a blunt floor is not needed. The genuinely blind window is 31% of the week, not the ~60%
that "outside US market hours" suggests.

This matters commercially: Uniswap Labs reports ~60% of tokenized-equity volume on Robinhood Chain
falls outside US market hours (`proposal.md` §2). The floors are therefore the pool's dominant
pricing regime by volume, not a corner case — set `elevatedFloor` close to `baseFee` and concentrate
the height in `closedFloor`. Combined with B1, the highest floor can then only fire on the weekend
or on a multi-day feed outage, never on a quiet Tuesday.

Still `[TBD: tuned]`; this fixes the ordering and the reasoning, not the numbers. The fork test's
**fee revenue forgone** measurement (`proposal.md` §11) is what settles them.

---

## B4 — No time decay; `refMoved` is derived from feed history, not hook state

**Overrides:** `proposal.md` §5.5 (post-open decay), `architecture.md` §4 `decayedDeviationMult` /
`lastOpenAt`, and the `lastRefPrice` storage word the r7 §5.4 text implied.

Two findings from the Sept 8 review, one fix.

*Decay was a scheduled discount.* `decayedDeviationMult` returned 1.0 fifteen minutes after the
reopen whether or not the gap had been absorbed. The pool reprices only when someone trades, so an
arbitrageur who waited fifteen minutes paid the floor on the whole gap — A7 re-created by the
calendar. Removed. The gap closing *is* the decay: as arbitrage moves the pool toward the new
reference, `|dev|` shrinks and `f(|dev|)` falls on its own. `decayWindow`, `decayedDeviationMult`
and `MarketHours.lastOpenAt` are deleted.

*`refMoved` had no safe producer.* A stored `lastRefPrice` is attacker-refreshable: one dust swap
after the reference moves resets it, and the next swap sees `refMoved = false` — F1 defeated for
the cost of one trade. Replaced by a stateless test on feed history: the adapter supplies the
previous print (`MarketState.prevPrice`, from `getRoundData(roundId − 1)`), and

```
refMoved := |pool − prevRef| < |pool − ref|
```

i.e. the pool is still tracking the *old* reference. No swap-path storage, nothing an attacker
can write, and it turns itself off once the pool has absorbed the move.

## B5 — Deviations are signed; F2 deferred

**Overrides:** `FeeCurve.isRestoring` signature; records the F2 decision `pre-build-review.md` §8
asked for.

With unsigned deviations a swap from 1% below the reference to 0.5% above read as "restoring"
(0.5 < 1). `isRestoring` now takes signed deviations and treats any crossing of the reference as
adverse. `deviationMult` is evaluated on `|postDev|` and saturates at 10,000% so it cannot revert.

F2 (path-additive fee over `[preDev, postDev]`) is **deferred**, not adopted. The endpoint rule
leaks a bounded share of the surcharge to swap-splitting (§8 worked case: ~12–37%). Stated in the
README as a known limitation of v1; the fix is ~30 lines of pure `FeeCurve` when there is time.

Also from the review, mechanical: `computeFee` rounds up and clamps to `MAX_LP_FEE` as well as
`feeCap`; Good Friday is computed (Gregorian computus) rather than tabled; `Session.Closed` is the
enum's zero value so a zeroed `MarketState` is the fail-safe regime.

---

## B6 — Second-pass fixes to the F1 mechanism

**Refines:** B4 (`referenceMoved`) and `FeeCurve.deviationMult`.

The Sept 8 second review found two holes in B4 as first written; both were in the library.

*The surcharge was evaluated on where the swap ends.* An arbitrage that lands exactly on the new
reference ends at zero deviation and was charged 1.0x — the floor. `deviationMult` now takes both
endpoints and charges on `max(|preDev|, |postDev|)`: a swap that takes a 3% gap pays for 3%
whether it stops short or lands on the reference. (The path integral, F2, remains deferred.)

*"Closer to the old print than the new" exempted half the gap.* Once the pool passed the midpoint
between the two prints, `referenceMoved` flipped false and the remaining half was restoring at
the floor — two transactions instead of one recovered ~40% of the surcharge. "Still tracking the
old print" now means the pool lies **between** the two prints (inclusive). The surcharge falls as
the gap closes but reaches the floor only when the gap is actually closed. A pool that drifted
outside the band on its own is unaffected.

Also: unknown history (`prevPrice == 0`) now counts as moved — when in doubt, charge (F3's "fail
adverse"). `abs(int256.min)` saturates instead of reverting. `MarketState` gains `prevQuotePrice`
so a quote-only move on a stock/SPY pool is visible.

**Adapter contract for `prevPrice` (residuals the library cannot fix):** it must be the last print
that *differed* from the current one — skipping heartbeat re-prints — and, right after a closure,
the last print at or before the close, so a reopen followed by a retrace print does not read as
"no move". Documented on the struct; enforced in `ChainlinkEquityAdapter`.

