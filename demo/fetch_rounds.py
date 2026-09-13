#!/usr/bin/env python3
"""Copies real Chainlink AAPL/USD rounds from Robinhood Chain into demo/AAPLRounds.sol so the demo
can replay the Labor Day weekend against a fork that starts before the feed woke up.
Usage: demo/fetch_rounds.py [rpc]   (default: https://rpc.mainnet.chain.robinhood.com)"""
import json, subprocess, sys, datetime, zoneinfo

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://rpc.mainnet.chain.robinhood.com"
FEED = "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0"  # Robinhood AAPL / USD, 8 decimals
FIRST_TS, LAST_TS = 1788480000, 1789000000            # Thu Sep 3 → Wed Sep 9 2026 (UTC)
ET = zoneinfo.ZoneInfo("America/New_York")

def call(sig, *args):
    out = subprocess.run(["cast", "call", FEED, sig, *map(str, args), "--rpc-url", RPC, "--json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)

latest = int(call("latestRoundData()(uint80,int256,uint256,uint256,uint80)")[0])
rows = []
for i in range(0, 400):
    try:
        r = call("getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)", latest - i)
    except subprocess.CalledProcessError:
        break
    rid, ans, upd = latest - i, int(r[1]), int(r[2])
    if upd == 0 or ans <= 0:
        continue
    if upd < FIRST_TS:
        break
    if upd <= LAST_TS:
        rows.append((rid, ans, upd))
rows.reverse()

lines = [
    "// SPDX-License-Identifier: MIT",
    "pragma solidity ^0.8.28;",
    "",
    f"/// Real Chainlink AAPL/USD rounds (proxy {FEED}, 8 decimals) on Robinhood Chain,",
    f"/// copied by demo/fetch_rounds.py on {datetime.datetime.now(ET):%Y-%m-%d %H:%M ET}. Do not edit by hand.",
    "library AAPLRounds {",
    "    function get() internal pure returns (uint80[] memory id, int256[] memory answer, uint256[] memory updatedAt) {",
    f"        id = new uint80[]({len(rows)}); answer = new int256[]({len(rows)}); updatedAt = new uint256[]({len(rows)});",
]
for i, (rid, ans, upd) in enumerate(rows):
    when = datetime.datetime.fromtimestamp(upd, ET).strftime("%a %b %d %H:%M ET")
    lines.append(f"        id[{i}] = {rid}; answer[{i}] = {ans}; updatedAt[{i}] = {upd}; // {ans/1e8:.2f}  {when}")
lines += ["    }", "}", ""]
open("demo/AAPLRounds.sol", "w").write("\n".join(lines))
print(f"wrote demo/AAPLRounds.sol with {len(rows)} rounds, {rows[0][2]} → {rows[-1][2]}")
