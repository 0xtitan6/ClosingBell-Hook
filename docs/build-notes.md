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


## B7 — Round 3 audit of the hook: fixes and accepted risks

**Baseline:** working tree after `89e7cd3` (hook + FeeCurve rounding/validate + hook tests).
Four independent reviewers (math precision, integration, serial attacker, testing). Fixed, each
with a regression test that fails without the fix; suite 106 → 118 tests.

*Reopen arb was bypassable by a wei (High, fixed).* `referenceMoved` required the pool to sit
**between** the two prints. A pool nudged one wei past the old print before Friday's close read as
a pool-created gap on Sunday and the whole reopen move rode at the floor (probe: 800 instead of
5060). The existing test only passed because the sqrt-price constant truncates one ulp *above*
the previous print. New rule: the pool was tracking the old print if `|pool − prev| ≤ |ref − prev|`
— the band plus its mirror on the far side of the old print. Residual: a trader can still escape by
pre-paying a real gap larger than the overnight move, in the right direction, before knowing it
(the attacker reviewer measured this at ~68 bps paid to save the surcharge on a ≤1% overshoot).

*Live feed with an unusable price was priced as a healthy market (Medium, 2/4, fixed).*
`isLive = true` with `price = 0`, or a quote feed at 0, gave the base floor and no deviation term.
The cheap floors now require `isLive && ref != 0`; otherwise the closed floor applies.

*`_price` read 0 at the buy-side price limit (Medium, fixed).* Inverting a truncated intermediate
turned an extreme sqrtPrice into "−100%" instead of "+∞", making the fee non-monotone in trade
size for gentle slopes. Each orientation is now computed directly; `_dev` saturates at `MAX_DEV`
before multiplying; `sqrtP == 0` saturates rather than dividing by zero.

*`feeCap == 100%` blocked exact-output swaps (Low, fixed).* v4 rejects exact-output swaps at a
fee of exactly `MAX_LP_FEE`. `validate` now requires `feeCap < MAX_LP_FEE`; `computeFee` clamps
to `MAX_LP_FEE − 1`.

*Belt and braces (Low, fixed).* The adapter call sits behind `try/catch` (a reverting adapter
degrades to the closed floor instead of blocking the pool). `_afterInitialize` refuses a starting
price more than 10x from the reference — a wrong `stockIsToken1` or decimals would otherwise be
immutable and charge the cap on every buy. The constructor rejects a static-fee key and a decimals
gap above 18.

**Accepted, documented, not fixed:**

*Same-unlock JIT liquidity thins the post-swap estimate (Medium, 2/4).* Mint a one-spacing
position over the current tick, swap, burn — all inside one `unlock`, deltas net to gas. The hook
reads inflated in-range liquidity, estimates a small move, and under-prices an adverse swap that
then exhausts the sliver. Measured: regular hours, pool at reference, 1000e18 buy: 2260 honest →
1253 spoofed (≈37% of the surcharge shed) at `tickSpacing = 60`; the reopen defence is immune
because `preDev` comes from real slot0, which JIT cannot move. No fix exists inside "the swap path
writes nothing": the alternatives are a multi-tick Quoter-style walk in `beforeSwap` (gas) or
pricing in `afterSwap` with a return delta (architecture change). Hackathon disposition: document;
the floor component is unaffected; a wider `tickSpacing` tightens the bound.

*Swap splitting (F2, known since B5, now quantified).* Charging `max(|pre|, |post|)` per leg is
superadditive: the reopen arb split into 10 legs pays 3105 average vs 5060 in one (−39%). A
path-integral charge is the fix and remains deferred.

*Displace-then-restore asymmetry (Low).* An attacker who pushes the pool away from the reference
pays the full surcharge (211 bps on a 10% push) and can unwind at the floor; a victim swapping
in between pays 19x. The displacer loses far more than the victim, and the victim's fee goes to
LPs. Noted as an MEV-sandwich amplifier, not a standalone profit.

*Never read by the hook:* `MarketState.session` and `updatedAt`. The session comes from
`MarketHours`; `updatedAt` is dead by B1. Both stay in the struct for adapters and tooling.

## B8 — Adapter: stateless reference history (supersedes the closure-gap rule)

**Refines:** B6's adapter contract. **Superseded in part by B9.**

B6 asked the adapter for "the last print at or before the close" after a reopen. Two constraints
shaped how: the adapter must be `view` (the hook reaches it by `staticcall`), so it cannot remember
anything; and `MarketHours.calendar` returns `lastClose = now` whenever the market is open, so on
Sunday night there is no calendar signal saying "you just reopened".

The first implementation derived the closure from the feed: a gap of 36h or more between
consecutive rounds could only be a market closure, and the print before it became `prevPrice`.
Round 4 showed that rule is both fragile (a single weekend heartbeat re-print splits the gap into
two sub-36h halves, and a one-day mid-week holiday never reaches 36h at all) and wrong in the case
it was built for: once the pool *has* tracked the reopen print, pinning `prevPrice` to the
pre-closure print makes the retrace read as pool drift. See B9.

The adapter now reports the **window** instead: the lowest and highest print over the latest round
and up to `LOOKBACK = 6` rounds behind it. No gap heuristic, no closure detection, no dependence on
whether the feed heartbeats while closed. Unknown history (new feed, phase boundary, unreadable
round) reports zeros, and the hook charges by default.

Verified against live Robinhood Chain feeds during this build: the feeds do **not** print while the
market is closed (GOOGL Fri 10:27 to Mon 20:00, 81.5h; SPY Fri 12:18 to Sun 20:00, 55.7h), and a
forced print lands at 20:00 on reopen regardless of deviation. Weekday heartbeat prints carry the
current price rather than repeating the last one, so they are ordinary prints, not re-prints.

## B9 — One reference is not enough: the window rule

**Refines:** B4, B6, B8. **Round 4, three of four reviewers.**

`referenceMoved` asked whether the pool sits within the last move of the last print. That is only
correct if the pool tracked every print before the current one. Four symptoms, one cause, all
reachable in an ordinary week with no attacker setup:

- **A trend of small prints.** 100, 100.3, 100.6, 100.9 with the pool still at 100. Each print's
  band is only 0.3 wide, so by the third print the pool is "outside" it and the arb that takes the
  whole 0.9% pays the bare floor (500 measured, against 1142 deserved).
- **A tracked reopen followed by a retrace.** The pool arbs to Sunday's 103 print, paying the
  surcharge as designed; the feed then retraces to 102, and selling back captures a real move at
  the floor. Live GOOGL history shows exactly this shape: up 0.31% at the reopen, down 0.52% ten
  minutes later.
- **A holiday weekend.** The staleness cap makes tracking Sunday's print unprofitable, and
  Tuesday's first print then leaves the untracked 3.3% gap priced at 500.
- **Quote-feed pools.** When one leg printed and the other did not, the previous ratio mixed a
  fresh leg with a stale one, producing a reference that never existed and misclassifying most
  prints in both directions.

The fix anchors on the whole window rather than one print. The pool was "following some print p"
if `|pool - p| <= |ref - p|`. Every such band contains `ref`, so the union over the window is a
single interval, `[2*lo - ref, 2*hi - ref]` — two comparisons, no loop. For a quote-feed pool the
hook builds the widest ratio either leg's history could have produced (low stock over high quote,
high stock over low quote), so a move on one leg is never mistaken for pool drift.

`MarketState` accordingly carries `loPrice`/`hiPrice` and `loQuotePrice`/`hiQuotePrice` in place of
`prevPrice`/`prevQuotePrice`.

**Residual, accepted:** once `LOOKBACK` distinct prints have landed after a gap, the older print
scrolls out of the window and a pool that never tracked any of them reads as pool drift. Real feeds
reach six prints within an hour or two of the open, so this is a bound on how long the protection
lasts, not a bypass a trader can trigger. Raising `LOOKBACK` to 10 costs about 12k gas.

## B10 — `try/catch` does not make a call safe

**Round 4, two of four reviewers.**

Both the adapter and the hook wrapped their external reads in `try/catch` and documented themselves
as total. They were not. `try/catch` catches a revert in the callee; decoding the return data
happens afterwards, in the caller's own frame, and a decode failure there is not caught. A feed
returning a `uint8` word above 255, a `bool` word of 2, a four-word tuple, short data, or nothing
at all would revert the adapter — and, through the same hole, the hook.

Both now use a raw `staticcall`, check the return length, and decode by hand into `uint256` words,
which cannot fail. The hook tolerates an out-of-range `session` word rather than reverting on the
enum bounds check, since it takes the session from the calendar anyway. Cost: about 8k gas on the
adapter (57k to 65k) and roughly 2k on the hook. That is the price of the guarantee the whole
design rests on, and it is paid once per swap.

The adapter's constructor now dry-reads every address it is given, because all five parameters are
immutable: a feed or token that cannot be read would pin the pool at the closed floor forever with
no way to fix it. Plausibility also now compares against the last distinct print rather than the
window low, so a large but legitimate reopen gap no longer holds the feed "not live" for six rounds.

## B11 — Round 4 test coverage

The suite went from 154 to 168 tests. New: an end-to-end file (`test/EndToEnd.t.sol`) that runs the
real adapter behind the real hook through a real PoolManager across one week — Friday's session, a
tracked print, post-market, the close, a dark weekend with the staleness ramp, the Sunday reopen
gapping up, the arbitrage, a retrace, Labor Day, Tuesday's open — asserting the fee at every step
in the production 6-decimal USDG layout. Also added: the stock-as-token0 orientation (a swapped
scale factor previously passed the whole suite), the 10x initialization boundary, `_dev` saturation,
malformed adapter and feed return data, and the quote-leg window.

Measured, production layout, warm: swap through the hook and adapter on the deviation path 111k
gas; with a dead feed 70k; `getMarketState` alone 65k.

## B12 — Cut the fields the hook never reads

**Overrides:** architecture.md §4 (constructor signature and the pool-key rationale), and B10's
"both stay in the struct for adapters and tooling".

`MarketState` carried `session` and `updatedAt`. The hook decoded both and used neither: the
session comes from `MarketHours.calendar`, which the hook calls itself, and `updatedAt` is dead by
B1 (it cannot detect a halt on these feeds). Filling `session` meant the adapter ran the whole NYSE
calendar on every swap — 3-4k gas in regular hours, 8-12k on a closed day — to produce a value the
hook threw away, and the calendar then ran a second time inside the hook.

Both fields are gone. The adapter no longer imports `MarketHours` at all; the oracle seam now
carries only prices, and the calendar is the hook's business alone. `MarketState` is eight words
instead of ten.

The hook's four pool-key immutables (`currency0`, `currency1`, `poolFee`, `tickSpacing`) collapsed
into one `poolId`, computed once in the constructor. `_afterInitialize` compares one hash instead
of four fields, and is stricter for it — the id covers the hooks address too. `_poolPrices` reads
the immutable directly instead of rebuilding a `PoolKey` and hashing it on every swap.

Measured, production layout, warm:

| | before | after |
|---|---|---|
| swap, live feed | 111,397 | 105,926 |
| swap, dead feed | 70,316 | 65,216 |
| `getMarketState` | 65,668 | 61,079 |

**Note for the Streams upgrade:** a Data Streams adapter carries an explicit `marketStatus`, and
the proposal's plan was for it to arrive through this struct. It would reintroduce a session field
then. Paying 3-12k gas per swap now, on every trade, to hold a slot open for a v2 that does not
exist is the wrong trade; the interface change is a one-line struct edit when that day comes.

## B13 — Round 5: two bugs, one of them mine from the day before

Two reviewers, fresh mandates: a holistic senior review and a pure bug hunt.

**The band arithmetic could revert, and a revert on the swap path bricks the pool (High).**
`referenceMoved` computed the band as `2*lo - ref` and `2*hi - ref`. The doubling of `hi` was
guarded against overflow; the doubling of `lo` was not, and in checked arithmetic `2 * lo` panics
before the comparison that was supposed to guard it. An 8-decimal feed answer at or above ~5.79e66
scales to a price above `uint256.max / 2`, and every swap in the pool then reverted — including
through the real router, and including when the feed was flagged not live, because the deviation
term runs whenever a reference exists. Every other piece of arithmetic that touches feed data
(`_scale`, `_ratio`, `_dev`, `computeFee`, `abs`) saturates for exactly this reason; this one line
did not. The band is now written as `l - (ref - l)` and `h + (h - ref)`, which is the same
interval with no intermediate that can overflow, saturating upward only. A window reported
backwards (`lo > hi`) now charges rather than exempting, since the seam is meant to be swappable.

**B12's pool-id collapse added a deploy footgun (Medium).** `toId()` hashes the whole key, `hooks`
included, and the four-field comparison it replaced deliberately excluded that field — this
document said so, and the note replacing it did not add the guard that made the change safe. A
deploy script that mines the address but mis-writes the key produced a hook that constructs and
verifies but whose pool can never be initialized. It is fail-closed, not fail-open: the id check
still rejects every wrong pool, and `_poolPrices` can never read a different pool's slot0. The
constructor now assigns `key.hooks = address(this)` before hashing, which removes the failure mode
rather than detecting it.

**The decimals guard was the wrong guard (Low).** B7 documented rejecting a decimals gap above 18;
the code checked absolute decimals above 24 instead. With a gap of 21 or more, `_price` overflows
at v4's own `MIN_SQRT_PRICE`, which the post-swap estimate reaches whenever an exact-output swap
asks for more than the pool holds — turning a legal, partially-fillable v4 swap into a revert. Both
bounds are now enforced. Not reachable in the production 6/18 layout.

**Documentation drift, corrected.** The README still described post-open decay, deleted in B4,
including a `decayWindow` parameter row; defined `isLive` with a calendar term the adapter no
longer has; advertised "try/catch every call" in its diagram, which is the anti-pattern B10 exists
to correct; and claimed `Constants.sol` holds verified chain addresses, which it never has. The
parameter table now carries the values the end-to-end test actually uses, marked provisional,
rather than `[TBD: tuned]`.

**Verified sound by the bug hunt**, and worth recording because these are the load-bearing claims:
the B12 hand-decode is exactly 256 bytes with field order matching the struct, checked field by
field against the live adapter; the window rule's union identity holds under 40,000 fuzz runs
against a brute-force model, including when the reference sits outside the window; and every
weekday from 2024 to 2040 that `MarketHours` calls closed matches an independently written NYSE
model exactly, 167 holidays, with `lastClose` fuzzed 20,000 times across DST boundaries.

172 tests pass at `--fuzz-runs 10000`. Every fix above was mutated out and confirmed to fail a test.
