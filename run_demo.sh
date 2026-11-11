#!/usr/bin/env bash
# End-to-end local demo: deploys a Uniswap V4 PoolManager and the hook to Anvil, creates a
# dynamic-fee pool, and shows the LP fee reacting to volatility. Every fee printed is read from
# the PoolManager's Swap event, i.e. it is what the pool actually charged.
set -euo pipefail
cd "$(dirname "$0")"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil's first default account. Publicly known test key: never fund it on a real network.
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SWAP_TOPIC="$(cast sig-event 'Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)')"

if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "Starting anvil..."
    anvil --silent &
    ANVIL_PID=$!
    trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
    until cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; do sleep 0.2; done
fi

if [ "$(cast chain-id --rpc-url "$RPC_URL")" != "31337" ]; then
    echo "run_demo.sh only runs against a local Anvil node (chain 31337)." >&2
    exit 1
fi

run() { forge script "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast 2>&1; }

# swap <label> <zeroForOne> <amountIn>
swap() {
    local out quoted data fee pm
    out="$(run script/DemoSwap.s.sol --sig 'run(bool,uint256)' "$2" "$3")" || { echo "$out" >&2; exit 1; }
    quoted="$(echo "$out" | sed -n 's/.*quoted fee.*: //p')"
    pm="$(sed -n 's/.*"poolManager": *"\([^"]*\)".*/\1/p' deployments/31337.json)"
    data="$(cast logs --rpc-url "$RPC_URL" --from-block latest --to-block latest --address "$pm" "$SWAP_TOPIC" | sed -n 's/^[[:space:]]*data: //p' | tail -1)"
    fee=$((16#${data: -6}))
    printf '%-44s quoted %6s   charged %6s pips (%d.%02d%%)\n' "$1" "$quoted" "$fee" $((fee / 10000)) $((fee % 10000 / 100))
}

echo "Deploying PoolManager + hook..."
run script/DeployHook.s.sol | grep -E '^\s*(PoolManager|Hook|Owner):' || { echo "deploy failed" >&2; exit 1; }
echo "Creating pool and adding liquidity..."
run script/CreatePoolAddLiquidity.s.sol >/dev/null

echo
swap "1. small swap, calm pool"                    true  1000000000000000
swap "2. large swap (moves the price ~2%)"         true  10000000000000000000
swap "3. small swap right after the large one"     true  1000000000000000

cast rpc --rpc-url "$RPC_URL" evm_increaseTime 180 >/dev/null
cast rpc --rpc-url "$RPC_URL" evm_mine >/dev/null
swap "4. small swap three minutes later"           true  1000000000000000

cast rpc --rpc-url "$RPC_URL" evm_increaseTime 86400 >/dev/null
cast rpc --rpc-url "$RPC_URL" evm_mine >/dev/null
swap "5. small swap after a quiet day"             true  1000000000000000

echo
echo "Done. Addresses are in deployments/31337.json"
