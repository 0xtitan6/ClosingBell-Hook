# Prior art: Fables (verified on-chain, Sept 4 2026)

**Summary.** Fables is a hook-native ve(3,3) DEX on Uniswap v4, live on Robinhood Chain, that
prices tokenized-stock pools off a US-equity trading calendar in a `beforeSwap` dynamic-fee hook.
It is the closest prior art to ClosingBell and it invalidates the r5 novelty claim as written.
This document records what was verified, how, and where the two designs genuinely diverge.

Discovered day 1 of the build window. Evidence is reproducible from the commands noted.

---

## 1. What was verified, and how

| Method | What it established |
|---|---|
| `cast code` on 9 hook addresses (chain 4663) | All are live contracts, 28–36KB, five distinct codehashes |
| Hook address low bits | Every hook ends `0x…080` = bit 7 = `BEFORE_SWAP_FLAG` only — same permission set as ClosingBell |
| Selector extraction from bytecode + openchain lookup | Recovered the ABI surface without verification |
| `cast call` on live hooks | Config values read directly from the deployed contracts |
| Sourcify `/v2/contract/4663/<hook>` + Blockscout | **Source is verified and readable** (47 files, solc 0.8.26, licence `UNLICENSED`) |

Contracts: `FablesRWA.sol`, `base/{FablesBaseHook,FablesLedger,MarketCalendar,LedgerTypes}.sol`,
`libraries/{SessionLib,CalendarLib,LedgerLib}.sol`. Verified on Sourcify 2026-08-25.

Blockscout sits behind Cloudflare — a browser User-Agent is required. The docs site is a
client-rendered SPA; content lives in the JS bundle (`/assets/index-*.js` and the lazy
`DocsRoute-*.js` chunk), not the served HTML.

## 2. The fee mechanism

Verbatim from `FablesRWA.sol`:

```solidity
function _autonomousFee(PoolId poolId, IPoolManager.SwapParams memory) internal view override returns (uint256) {
    return feeFloorAt(_floorConfig[poolId], block.timestamp);
}
```

The `SwapParams` argument is unnamed and unused. **The fee is a pure function of
`block.timestamp` and per-pool config.** No external oracle, and not even the pool's own
tick or `sqrtPrice`. `SessionLib` describes itself as *"Pure time math mapping unix
timestamps to US equity trading sessions and fee floors."*

Session model — three tiers, ET-localized with a real US DST rule:

```solidity
enum Session { OPEN, OVERNIGHT, CLOSED }
if (dow == 0 || dow == 6) return Session.CLOSED;        // weekend
if (dow == 5 && sec >= closeS) return Session.CLOSED;   // Friday after close
if (closedDay) return Session.CLOSED;                   // baked holiday table
if (sec >= openS && sec < closeS) return Session.OPEN;
return Session.OVERNIGHT;
```

Verified live: `openSec()=34200` (09:30 ET), `closeSec()=57600` (16:00 ET), `dstMode()=0` (AUTO).
NYSE full-day holidays are hardcoded for 2026–2030 (2026 includes Labor Day 09-07); probing
`sessionAt()` returns `2` for Labor Day, Thanksgiving and Christmas. **Half-days are not modeled.**
Pre-market and post-market are not distinguished — both are `OVERNIGHT`, one tier, one price.

Fee shape: three session floors, plus an **opening descent** (linear decay from a spike to
`openFloor` over `descentWindow`, the spike being an absolute `closedSpike` if the previous ET day
was fully closed), plus a **closing ramp** into the bell, plus an optional side premium, plus the
keeper poke, clamped to `maxFee`.

Live configs (ppm), read from `floorConfig(poolId)`:

| Pool | open | overnight | closed | closedSpike | descent | cap |
|---|---|---|---|---|---|---|
| NVDA/USDG | 1000 | 800 | **300** | 4000 | 7200s | 8000 |
| TSLA/USDG | 900 | 500 | **400** | 4000 | 7200s | 10000 |
| SPY/USDG | 800 | 350 | **250** | 0 | 0 | 8000 |
| AAPL, NVDA/SPY, SPY/GLD | 500 | 350 | **300** | 0 | 0 | 8000 |
| META/USDG | 900 | 750 | **450** | 0 | 0 | 8000 |

## 3. The substantive disagreement

**On every equity pool, `closedFloor < openFloor`. The weekend is Fables' cheapest tier.**
Their rationale, verbatim from `SessionLib`:

> "the calibrated shape is open > overnight > closed (the open and its bells are the toxic
> windows, not the closure)"

Gap risk is charged at the **reopen** instead, via `closedSpike` (NVDA/TSLA 4000 ppm decaying
over 2h). ClosingBell's r5 takes the opposite position: calendar-closed is the *highest* floor,
because the pool is maximally stale while the reference is dark.

This is a genuine, falsifiable disagreement about *where* weekend toxicity is realized —
in the dark window, or at the reopen. Workstream A measures exactly this. Whichever way the
data falls, adjudicating it is a contribution.

## 4. Deviation is externalized, not absent

Fables has no on-chain reference price, therefore no staleness term and no pool-vs-reference
deviation term. But they have not ignored the idea — they moved it off-chain. `pokeFee` is an
authority-gated fee override, TTL ≤ 72h, bounded by the pool's floor/cap and a 50% max discount.
`/docs/swap-fee`, verbatim:

> "Authorised off-chain software observes market conditions and can write a temporary fee for a
> configured pool. Depending on the pool, that decision can use reference-price divergence,
> realised volatility, or another configured signal."

And the design position is argued explicitly in `FablesRamp.sol`:

> "the quantity that actually matters — LVR / adverse selection against the external mid — is
> invisible without an ORACLE. A flat fee plus an oracle-driven off-chain poke is both simpler
> and strictly better where it matters"

**As of Sept 4 2026 no tokenized-stock pool has a live keeper** (`pokeOf()` zero or expired on
all 8 RWA hooks; only the ETH pool is keeper-flagged in their frontend).

So the axis is not "deviation vs no deviation". It is **trustless on-chain vs trusted off-chain**.

## 5. Halts and frozen feeds

Fables has no halt detection and cannot have any: a calendar cannot observe that a feed froze.
Their docs concede it — `/docs/risks`: *"A calendar can miss an exceptional closure. A reference
price can be stale, manipulated or unavailable."* The remedy is manual: `setDayOverrides` writes a
2-bit-per-day bitmap (`FORCE_CLOSED` / `FORCE_OPEN`), admin-driven, capped at
`MAX_FORCED_CLOSURES = 10` per month.

Consequence: a Tuesday-10am trading halt that freezes the Chainlink feed leaves Fables charging
`openFloor` — its *cheapest* weekday tier — against a stale reference. ClosingBell's liveness
predicate resolves the same state to the highest floor, automatically, per swap.

## 6. Neither design halts trading

`pausedUntil()` and `MAX_PAUSE() = 604800` exist, but `whenNotPaused` guards only ledger actions
(deposit, stake, claim, ERC-6909 transfers, sweeps). **`beforeSwap` carries no pause check**, and
`withdraw` is deliberately exempt so a compromised pauser cannot trap principal. Fables cannot halt
a pool. "Keeps the pool open" is therefore **common ground, not a differentiator** — the honest
contrast is against `trading-days`, which reverts.

## 7. Governance and licence

Contracts are not proxies (*"The hook is immutable. A defect cannot be patched in place"*), but
essentially every fee parameter is mutable through OpenZeppelin AccessManaged
(`authority() = 0xA362D98B33A7bb5B5E2180a05f995A70FB404f30` on every hook): `setPoolConfig`,
`setPoolAsymmetry`, `setSessionHours`, `setDstMode`, `setDayOverrides`, `pokeFee`, `pause`,
`setAuthority`. Immutable bytecode ceilings include `ABSOLUTE_MAX_FEE = 20000` (2%),
`MIN_POOL_FEE = 100`, `MAX_POKE_TTL = 259200`, `MAX_DESCENT_WINDOW = 21600`.

Source is **verified but `UNLICENSED`** — readable, not reusable. No GitHub org is referenced.
`/docs/security` states plainly: *"No Fables-specific audit report with auditor, commit hash,
scope and findings is currently linked here."*

## 8. Corporate actions (ERC-8056)

No `uiMultiplier` reference exists in any Fables contract. Their **frontend** pins each token's
expected multiplier and blanks the pool in the UI on mismatch; the pool itself keeps trading
unadjusted. Their docs never mention ERC-8056.

## 9. Where ClosingBell stands after this

Overlapping, and to be stated plainly rather than glossed: same problem, same chain, same
`beforeSwap`-only dynamic-fee hook, same calendar conditioning variable, session-tiered floors,
direction asymmetry, a decay window, a fee cap, pools that stay open.

Diverging, and defensible:

| | Fables | ClosingBell |
|---|---|---|
| Reference price | off-chain keeper, ≤72h TTL, trusted operator, currently inactive | on-chain, every swap, trustless |
| Staleness tax | none | `stalenessMult` on `updatedAt` |
| Deviation term | off-chain, discretionary | on-chain, signed, post-swap-estimated |
| Halt / frozen feed | undetectable; manual bitmap ≤10/month | liveness predicate, automatic |
| Weekend floor | cheapest tier | highest tier (opposite thesis) |
| Direction asymmetry | by swap side (`zeroForOne`) | relative to the reference (restoring vs adverse) |
| Parameters | admin-mutable via AccessManaged | immutable at initialization |
| Half-days | not modeled | modeled |
| ERC-8056 | frontend-only; UI blanks on mismatch | on-chain convention (see proposal §5.3) |
| Licence / form | UNLICENSED, welded into a ve(3,3) DEX | MIT, standalone hook for any v4 pool |

## 10. Addresses

RWA hooks (all `beforeSwap`-only), chain 4663:

```
0x66622f77B797D506e5376F7798b67ab288966080
0x67D86050d22D574Df046F3D90F722045F714e080
0x70a9A88402989226847Ec122043CE5e7FF462080
0x79576FBAD6e83915630BBB5D5658483F05532080
0x8AF95932eC4484fb10C641a4cBcf19a798cB2080
0xA0E8fBFf13E24Af2b5e61A72800E08a161bDe080
0xA4570C37590E45f0b06898123D4de16307A32080
0xB608a78761f179f7C56f15E7D13921B92F00a080
0x06a889870C8f83640D6816319f72e2aA579b6080   (crypto/ramp variant, no sessionAt)
```

Authority: `0xA362D98B33A7bb5B5E2180a05f995A70FB404f30`.
PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951` — the same non-canonical deployment
ClosingBell targets, independently corroborating proposal §11.
