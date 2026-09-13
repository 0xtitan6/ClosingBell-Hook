# Act 3 — Tests and results · 2:54–3:44

**Cut to the terminal. `forge test` summary on screen.**

One hundred seventy-four unit tests, seven fork tests.
Calendar, fee curve, adapter and hook are all tested without a chain.

**Run the replay fork test. Show the four-step log.**

This fork test replays Labor Day weekend against the real feed and asserts the fee at every step.
The results card is this log.

**README, Novelty section.**

I surveyed five hooks from source before building.
Two of my claims did not survive, and the README says so.
What survives: the only hook pricing on-chain from both a trading calendar and a live reference.
And the only one that splits deviation by who created it.

**README, Results section.**

Not yet measured: LP value retained versus an unhooked pool over a real reopen.
That is the next experiment.

**Repo link.**

Code, design docs, every correction, and the on-chain verification log are in the repo.
Thanks.

```
forge test --match-path test/fork/Replay.fork.t.sol --fork-url https://rpc.ordofi.network --fork-block-number 56000000 -vv
```
