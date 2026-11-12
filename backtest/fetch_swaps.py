#!/usr/bin/env python3
"""Download real swaps of one Uniswap V4 pool into a CSV.

Reads the PoolManager's `Swap` events for a pool id over a block range. Requests go through
Foundry's `cast rpc`, so the only requirements are Python 3.9+ and Foundry.

    python3 backtest/fetch_swaps.py --rpc <url> --days 30

The RPC must serve historical logs for the range and include `blockTimestamp` on each log
(current geth, reth and erigon do).
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import time

POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90"  # Ethereum mainnet
# ETH/USDC 0.05%, tick spacing 10, no hook: keccak256(abi.encode(PoolKey))
ETH_USDC_500 = "0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
# Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1,
#      uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
BLOCKS_PER_DAY = 7200

FIELDS = [
    "block", "timestamp", "tx_index", "log_index", "tx_hash", "sender",
    "amount0", "amount1", "sqrt_price_x96", "liquidity", "tick", "fee",
]


def rpc(url, method, *params, retries=5):
    cmd = ["cast", "rpc", "--rpc-url", url, method, *[json.dumps(p) for p in params]]
    for attempt in range(retries):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            out = None
        if out is not None and out.returncode == 0:
            return json.loads(out.stdout)
        if attempt == retries - 1:
            raise RuntimeError(out.stderr.strip() if out is not None else f"{method} timed out")
        time.sleep(2 ** attempt)


def signed(word):
    value = int(word, 16)
    return value - (1 << 256) if value >> 255 else value


def decode(log):
    data = log["data"][2:]
    words = [data[i:i + 64] for i in range(0, len(data), 64)]
    return {
        "block": int(log["blockNumber"], 16),
        "timestamp": int(log["blockTimestamp"], 16),
        "tx_index": int(log["transactionIndex"], 16),
        "log_index": int(log["logIndex"], 16),
        "tx_hash": log["transactionHash"],
        "sender": "0x" + log["topics"][2][-40:],
        "amount0": signed(words[0]),
        "amount1": signed(words[1]),
        "sqrt_price_x96": int(words[2], 16),
        "liquidity": int(words[3], 16),
        "tick": signed(words[4]),
        "fee": int(words[5], 16),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc", default=os.environ.get("MAINNET_RPC_URL"), help="RPC URL (default: $MAINNET_RPC_URL)")
    ap.add_argument("--pool-id", default=ETH_USDC_500)
    ap.add_argument("--manager", default=POOL_MANAGER)
    ap.add_argument("--days", type=float, default=30, help="how far back from --to-block (default 30)")
    ap.add_argument("--from-block", type=int)
    ap.add_argument("--to-block", type=int, help="default: latest")
    ap.add_argument("--chunk", type=int, default=5000, help="blocks per eth_getLogs request")
    ap.add_argument("--out", default="backtest/data/swaps.csv")
    args = ap.parse_args()
    if not args.rpc:
        sys.exit("pass --rpc or set MAINNET_RPC_URL")

    to_block = args.to_block or int(rpc(args.rpc, "eth_blockNumber"), 16)
    from_block = args.from_block or to_block - int(args.days * BLOCKS_PER_DAY)

    rows = []
    start = from_block
    while start <= to_block:
        end = min(start + args.chunk - 1, to_block)
        logs = rpc(args.rpc, "eth_getLogs", {
            "address": args.manager,
            "topics": [SWAP_TOPIC, args.pool_id],
            "fromBlock": hex(start),
            "toBlock": hex(end),
        })
        if logs and "blockTimestamp" not in logs[0]:
            sys.exit("this RPC does not return blockTimestamp on logs; use another one")
        rows.extend(decode(log) for log in logs if not log.get("removed"))
        print(f"blocks {start}-{end}: {len(logs)} swaps (total {len(rows)})", file=sys.stderr)
        start = end + 1

    rows.sort(key=lambda r: (r["block"], r["log_index"]))
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} swaps, blocks {from_block}-{to_block}, to {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
