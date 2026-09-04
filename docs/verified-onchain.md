# On-chain verification log — day 1 (Sept 4 2026)

Results of the proposal §11 verify-before-build checklist. Every value below was read from
Robinhood Chain (ID 4663) via `cast` against `https://rpc.mainnet.chain.robinhood.com`
at block ~54,576,000. Reproduce with the commands noted.

## 1. Chainlink Data Feed proxies — VERIFIED

The Chainlink docs table renders client-side, but it is backed by a JSON directory:

```
https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json    # 57 feeds
```

| Feed | Proxy | Price (Sept 4, 17:14 ET) |
|---|---|---|
| Robinhood SPY / USD | `0x319724394D3A0e3669269846abE664Cd621f9f6A` | 769.59 |
| Robinhood AAPL / USD | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | 320.52 |
| Robinhood NVDA / USD | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | 230.24 |
| Robinhood TSLA / USD | `0x4A1166a659A55625345e9515b32adECea5547C38` | 353.98 |
| USDG / USD | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | 1.00007 |

All equity feeds: **8 decimals, heartbeat 86400s, deviation threshold 0.5%**, tagged
`docs.marketHours = "us_equities_24/5"`. `latestRoundData()` returns a live, moving `updatedAt`.

## 2. Feed liveness is 24/5, not "frozen from Friday's close" — DESIGN-RELEVANT

Walking SPY's round history (`getRoundData`, phase 1) across three weekends:

```
r112  770.27  Fri 08-28 12:18 ET
r113  766.14  Sun 08-30 20:00 ET    <- 55.7h gap, price gapped -0.53%
r114  767.49  Mon 08-31 20:00 ET    (exactly 86401s later = heartbeat)
```

Same shape on Sun 08-23 20:00 and Sun 08-16 20:00. Weekday overnight updates do occur
(AAPL Fri 02:44 ET; SPY 02:00 and 05:14 ET on weekdays).

Conclusions:

1. The feed is **live continuously from ~Sunday 20:00 ET to Friday evening**, then dark for
   the weekend. The 24h heartbeat is **suspended while closed** (the 55.7h gap exceeds it),
   so no filler rounds are written.
2. The staleness window is therefore **~52h, Friday evening → Sunday 20:00 ET**, not
   ~65h Friday 16:00 → Monday 09:30.
3. **The reference wakes up Sunday 20:00 ET and gaps then.** By Monday 09:30 it has been live
   for 13.5 hours. Workstream A must chart *two* events: the Sunday-night reference wake-up and
   the Monday regular open.
4. Proposal §2's "Chainlink equity feeds repeat the closing price while closed" is true only
   for the weekend window, not for weekday overnight.

Chainlink's own Robinhood feeds page states the integration guidance ClosingBell implements:

> "When underlying equity markets are closed (weekends, holidays, thin overnight windows), the
> feed may hold the last published price even though the contract remains callable via
> `latestRoundData()`... Integrators should read `updatedAt` and implement staleness bounds
> appropriate to their use case."

## 3. Stock tokens and ERC-8056 ABI — VERIFIED

| Token | Address | dec | `uiMultiplier()` | `oraclePaused()` |
|---|---|---|---|---|
| AAPL | `0xaf3d76f1834a1d425780943c99ea8a608f8a93f9` | 18 | **1.000566080061092436** | false |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | 18 | 1.0 | false |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 18 | 1.0 | false |
| TSLA | `0x322f0929c4625ed5bad873c95208d54e1c003b2d` | 18 | 1.0 | false |
| META | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | 18 | — | — |
| GLD | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` | 18 | — | — |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | **6** | n/a | n/a |

Both `uiMultiplier()` and `oraclePaused()` exist and return sane values. AAPL's multiplier
matches the figure cited in the proposal exactly. USDG's 6 decimals confirm the decimal
normalization noted in §6.

## 4. Multiplier convention — RESOLVED: no adjustment needed

The §11 check as specified: AAPL against both its Chainlink price and its pool price.
AAPL/USDG pools read via `PoolManager.extsload` (`StateLibrary.POOLS_SLOT = 6`):

| Convention | Implied price | Deep pool (0.30%, tick 218622) deviation |
|---|---|---|
| Chainlink **as-is** | 320.5163 | **−0.0039%** |
| Chainlink ÷ multiplier | 320.3350 | +0.0527% |
| Chainlink × multiplier | 320.6978 | −0.0604% |

The deep pool sits 0.4bp from the raw Chainlink price versus 5.3bp under the divide convention.
The multiplier itself is 5.66bp, so this discriminates 13:1.

**Conclusion: the Chainlink price and the pool price are both denominated per-token. Neither
side needs a `uiMultiplier()` adjustment.** This removes the per-swap external call and the
transient-storage cache from the hook's hot path.

Caveats: one observation, on the only token with a non-unit multiplier, taken post-market.
Re-verify during regular hours with a fresh feed. The edge case survives regardless — if the
multiplier and the feed price update at different moments, a transient basis appears.

Incidental: at 17:40 ET the deep AAPL/USDG pool was 0.004% from reference while the thin 0.05%
pool was +2.47% and the 1% pool +0.83%. Cross-pool dispersion, post-market.

## 5. Infrastructure

- PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` — independently corroborated: it is
  the `poolManager()` returned by every Fables hook.
- Block explorers: `robinhoodchain.blockscout.com` (Cloudflare — browser UA required),
  `robinscan.io`, `hoodscan.co`. Contract verification also available via Sourcify
  (`sourcify.dev/server/v2/contract/4663/<address>`).
- Additional public RPCs beyond the primary (useful against Workstream A rate limits):
  `robinhood-rpc.publicnode.com`, `rpc.arrowrpc.com`, `rpc.ordofi.network`.

## 6. Checklist status

- [x] PoolManager address (pre-existing, now double-corroborated)
- [x] Chainlink equity feed proxy addresses
- [x] `latestRoundData()` returns usable `updatedAt` on chain 4663
- [x] `uiMultiplier()` ABI on a live stock token
- [x] Multiplier convention (resolved: no adjustment)
- [x] Prior art: Fables (see `prior-art-fables.md`) — supersedes the Levery-only check in urgency
- [ ] Levery's mechanism — does it condition on market hours?
- [ ] Permissioned Pools spec — confirm it does not express session state
- [x] ETHOnline rules on pre-window code (Classic track: code starts at kickoff; boilerplate and
      disclosed pre-existing docs permitted; submission deadline **Sept 13, 12:00 pm EDT**)
