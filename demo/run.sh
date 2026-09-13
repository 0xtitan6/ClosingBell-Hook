#!/usr/bin/env bash
# Starts a local fork of Robinhood Chain, deploys the demo, and serves the UI.
# Usage: demo/run.sh            (Ctrl-C stops everything)
set -euo pipefail
cd "$(dirname "$0")/.."

# rpc.ordofi.network keeps archive state back to Sun Sep 6 2026; the primary RPC does not.
RPC="${ROBINHOOD_RPC:-https://rpc.ordofi.network}"
FORK_BLOCK=56000000   # Sun Sep 6 2026 09:05 ET, Labor Day weekend: feed dark since Fri 15:51
LOCAL=http://127.0.0.1:8545
ACCOUNT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266                                   # anvil account 0
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
AAPL=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
# balanceOf(ACCOUNT) storage slots, found with vm.record on the fork (USDG packs balances in 64 bits)
AAPL_SLOT=0x03b401b7b39ad5148aeb9ef28bef316a982c01bdaadee32abc45fed3bc7f4746
USDG_SLOT=0xa3c1274aadd82e4d12c8004c33fb244ca686dad4fcc8957fc5668588c11d9502

echo "→ anvil fork of $RPC at block $FORK_BLOCK (Sun Sep 6 2026, 09:05 ET)"
anvil --fork-url "$RPC" --fork-block-number $FORK_BLOCK --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; kill ${HTTP:-0} 2>/dev/null; exit' INT TERM EXIT
until cast chain-id --rpc-url $LOCAL >/dev/null 2>&1; do sleep 0.5; done

echo "→ seeding account 0 with 1,000,000 AAPL and 100,000,000 USDG"
cast rpc anvil_setStorageAt $AAPL $AAPL_SLOT $(cast to-uint256 1000000000000000000000000) --rpc-url $LOCAL >/dev/null
cast rpc anvil_setStorageAt $USDG $USDG_SLOT $(cast to-uint256 100000000000000)           --rpc-url $LOCAL >/dev/null

echo "→ deploying hook, pool, liquidity"
forge script demo/DeployDemo.s.sol --rpc-url $LOCAL --private-key $KEY --broadcast -q

echo "→ UI at http://127.0.0.1:8080/demo/"
python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP=$!
[ -z "${NO_OPEN:-}" ] && open http://127.0.0.1:8080/demo/ 2>/dev/null || true
wait $ANVIL
