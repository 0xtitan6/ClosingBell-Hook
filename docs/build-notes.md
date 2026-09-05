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
