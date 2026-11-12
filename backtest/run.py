#!/usr/bin/env python3
"""Replay real swaps through the hook's fee model and report what LPs would have earned.

    python3 backtest/run.py --data backtest/data/swaps.csv --out backtest/RESULTS.md

What it does: for every historical swap, in order, it asks the model what fee the hook would have
charged, then records the swap's tick so the model's volatility state follows the real price path.
It compares that fee revenue with the pool's actual static LP fee.

What it assumes: the same swaps would have happened. Higher fees deter some flow, so the fixed-flow
revenue is an upper bound; the report gives the break-even volume loss alongside it.
"""

import argparse
import bisect
import csv
import datetime
import itertools
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import Config, Hook  # noqa: E402

Q96 = 1 << 96


def load(path):
    swaps = []
    with open(path) as f:
        for r in csv.DictReader(f):
            swaps.append({
                "block": int(r["block"]),
                "timestamp": int(r["timestamp"]),
                "tx_hash": r["tx_hash"],
                "sender": r["sender"],
                "amount0": int(r["amount0"]),
                "amount1": int(r["amount1"]),
                "sqrt_price_x96": int(r["sqrt_price_x96"]),
                "tick": int(r["tick"]),
                "fee": int(r["fee"]),
            })
    return swaps


def enrich(swaps, dec0, dec1):
    """Adds direction, USD volume (the quote-token leg) and price in token1 per token0."""
    for s in swaps:
        # V4 amounts are from the swapper's side: negative means paid in
        s["zero_for_one"] = s["amount0"] < 0
        s["usd"] = abs(s["amount1"]) / 10**dec1
        s["price"] = (s["sqrt_price_x96"] / Q96) ** 2 * 10 ** (dec0 - dec1)


def replay(swaps, config):
    """Returns the hook fee and reversal flag for swaps[1:]. swaps[0] only seeds the state."""
    hook = Hook(config, swaps[0]["tick"], swaps[0]["timestamp"])
    fees, flags = [], []
    for s in swaps[1:]:
        fee, flagged = hook.before_swap(s["timestamp"], s["block"], s["zero_for_one"])
        hook.after_swap(s["timestamp"], s["block"], s["zero_for_one"], s["tick"])
        fees.append(fee)
        flags.append(flagged)
    return fees, flags


def adverse_selection(swaps, horizon, dec0):
    """LP loss on each swap, in USD, measured against the pool price `horizon` seconds later.

    The LP takes the other side of every swap. If the price keeps moving the way the swapper traded,
    the LP sold too cheap or bought too dear: that loss is adverse selection (the same thing LVR
    measures against an external price). Fees are excluded here, so this is the cost that fee income
    has to cover. Positive = LP lost. None for swaps too close to the end of the data.
    """
    times = [s["timestamp"] for s in swaps]
    end = times[-1]
    out = []
    for s in swaps:
        if s["timestamp"] + horizon > end:
            out.append(None)
            continue
        future = swaps[bisect.bisect_right(times, s["timestamp"] + horizon) - 1]["price"]
        # the swap's own fee stays out of the trade: remove it from the input side
        keep = 1 - s["fee"] / 1e6
        if s["zero_for_one"]:
            token0_in = -s["amount0"] / 10**dec0 * keep
            lp_pnl = token0_in * future - s["usd"]
        else:
            token0_out = s["amount0"] / 10**dec0
            lp_pnl = s["usd"] * keep - token0_out * future
        out.append(-lp_pnl)
    return out


def likely_sandwich_backruns(swaps):
    """Indices of swaps that look like the closing leg of a sandwich, from log data alone.

    Pattern inside one block: sender X swaps one way, at least one swap from a different transaction
    goes the same way, then X swaps back in a later transaction. A heuristic, not ground truth.
    """
    found = set()
    for _, group in itertools.groupby(enumerate(swaps), key=lambda p: p[1]["block"]):
        group = list(group)
        for a in range(len(group)):
            ia, sa = group[a]
            for c in range(a + 2, len(group)):
                ic, sc = group[c]
                if sc["sender"] != sa["sender"] or sc["zero_for_one"] == sa["zero_for_one"]:
                    continue
                if sc["tx_hash"] == sa["tx_hash"]:
                    continue
                victims = [
                    s for _, s in group[a + 1:c]
                    if s["tx_hash"] not in (sa["tx_hash"], sc["tx_hash"]) and s["zero_for_one"] == sa["zero_for_one"]
                ]
                if victims:
                    found.add(ic)
                    break
    return found


def summarize(swaps, fees, flags, static_fee, adverse):
    """Aggregates over swaps[1:] (the swaps the model priced)."""
    priced = swaps[1:]
    volume = sum(s["usd"] for s in priced)
    static_rev = volume * static_fee / 1e6
    hook_rev = sum(s["usd"] * f for s, f in zip(priced, fees)) / 1e6
    above = [(s["usd"], f) for s, f in zip(priced, fees) if f > static_fee]
    above_rev = sum(v * f for v, f in above) / 1e6
    # fraction of the volume charged more than the static fee that could disappear before the
    # hook earns no more than the static pool
    break_even = (hook_rev - static_rev) / above_rev if above_rev else 0.0
    return {
        "swaps": len(priced),
        "volume": volume,
        "static_rev": static_rev,
        "hook_rev": hook_rev,
        "ratio": hook_rev / static_rev if static_rev else 0.0,
        "break_even": break_even,
        "avg_fee": hook_rev / volume * 1e6 if volume else 0.0,
        "vol_above": sum(v for v, _ in above) / volume if volume else 0.0,
        "vol_below": sum(s["usd"] for s, f in zip(priced, fees) if f < static_fee) / volume if volume else 0.0,
        "flagged": sum(flags),
        "adverse": sum(a for a in adverse[1:] if a is not None),
        "adverse_volume": sum(s["usd"] for s, a in zip(priced, adverse[1:]) if a is not None),
    }


def quartile_adverse(priced, fees, adverse):
    """Adverse selection in bps of volume for the lowest-fee and highest-fee quarters of volume."""
    rows = sorted(
        ((f, s["usd"], a) for s, f, a in zip(priced, fees, adverse[1:]) if a is not None), key=lambda r: r[0]
    )
    total = sum(v for _, v, _ in rows)

    def bps(part):
        volume = sum(v for _, v, _ in part)
        return sum(a for _, _, a in part) / volume * 1e4 if volume else 0.0

    low, high, seen = [], [], 0.0
    for row in rows:
        if seen < total * 0.25:
            low.append(row)
        elif seen >= total * 0.75:
            high.append(row)
        seen += row[1]
    return bps(low), bps(high)


def money(x):
    return f"${x:,.0f}"


def pct(x):
    return f"{x * 100:.1f}%"


def report(swaps, config, static_fee, horizon, dec0, sweep):
    fees, flags = replay(swaps, config)
    adverse = adverse_selection(swaps, horizon, dec0)
    s = summarize(swaps, fees, flags, static_fee, adverse)
    priced = swaps[1:]
    day = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d")
    days = (swaps[-1]["timestamp"] - swaps[0]["timestamp"]) / 86400
    out = []
    w = out.append

    w("# Backtest results\n")
    w("Generated by `backtest/run.py`. Real swaps of the Uniswap V4 ETH/USDC 0.05% pool on Ethereum mainnet, "
      "replayed in order through the hook's fee model. The model is checked against the contract in "
      "`test/BacktestModel.t.sol`.\n")
    w(f"- Window: {day(swaps[0]['timestamp'])} to {day(swaps[-1]['timestamp'])} ({days:.1f} days), "
      f"blocks {swaps[0]['block']} to {swaps[-1]['block']}")
    w(f"- Swaps: {s['swaps']:,}, volume {money(s['volume'])}")
    w(f"- Price range: {min(x['price'] for x in swaps):,.0f} to {max(x['price'] for x in swaps):,.0f} USDC per ETH")
    w(f"- Baseline: the pool's actual LP fee, {static_fee} pips ({static_fee / 100:.2f} bps)")
    w(f"- Hook config: baseFee {config.base_fee}, maxFee {config.max_fee}, mevSurcharge {config.mev_surcharge}, "
      f"feePerTick {config.fee_per_tick}, alphaBps {config.alpha_bps}, samplePeriod {config.sample_period}s\n")

    w("## Read this first\n")
    w("These numbers assume every historical swap would still have happened at the hook's fee. That is not true: "
      "a higher fee turns some trades away, arbitrage most of all. So **hook revenue here is an upper bound**. "
      "The break-even figure says how much of the surcharged volume could disappear before the hook stops "
      "being better. Nothing here measures whether that volume would in fact stay.\n")

    w("## LP fee revenue\n")
    w("| | Static pool | With hook |")
    w("|---|---|---|")
    w(f"| LP fees | {money(s['static_rev'])} | {money(s['hook_rev'])} |")
    w(f"| Volume-weighted fee | {static_fee / 100:.2f} bps | {s['avg_fee'] / 100:.2f} bps |")
    w(f"| Relative to static | 1.00x | {s['ratio']:.2f}x |\n")
    w(f"- Volume charged more than the static fee: {pct(s['vol_above'])}")
    w(f"- Volume charged less than the static fee: {pct(s['vol_below'])}")
    w(f"- Break-even: the hook still earns more than the static pool unless more than "
      f"**{pct(s['break_even'])}** of the surcharged volume leaves.\n")

    w(f"## Does fee income cover what LPs lose to informed flow?\n")
    w(f"Adverse selection is the LP's loss on each swap measured against the pool price {horizon} seconds later, "
      "fees excluded. It is the cost fee income has to cover, and it includes the swap's own price impact. It is "
      "the same in both columns because the price path is the same. The reference price is the pool's own "
      "later price, not an exchange feed.\n")
    scale = s["adverse_volume"] / s["volume"] if s["volume"] else 0
    w("| | Static pool | With hook |")
    w("|---|---|---|")
    w(f"| LP fees | {money(s['static_rev'] * scale)} | {money(s['hook_rev'] * scale)} |")
    w(f"| Adverse selection | {money(-s['adverse'])} | {money(-s['adverse'])} |")
    w(f"| Net | {money(s['static_rev'] * scale - s['adverse'])} | {money(s['hook_rev'] * scale - s['adverse'])} |\n")
    w(f"Fees here are scaled to the {pct(scale)} of volume that has a full {horizon}s of later data.\n")

    w("## Is the hook charging the right swaps?\n")
    w("Swaps grouped by the fee the hook would have charged. If the hook works as intended, the higher-fee "
      "groups should be the ones where LPs lose more.\n")
    b, m = config.base_fee, config.max_fee
    edges = [("at base fee", lambda f, fl: not fl and f == b),
             (f"up to 2x base", lambda f, fl: not fl and b < f <= 2 * b),
             (f"2x to 5x base", lambda f, fl: not fl and 2 * b < f <= 5 * b),
             (f"above 5x base", lambda f, fl: not fl and f > 5 * b),
             ("reversal surcharge", lambda f, fl: fl)]
    w("| Hook fee | Swaps | Share of volume | Static fees | Hook fees | Adverse selection (bps of volume) |")
    w("|---|---|---|---|---|---|")
    for name, pick in edges:
        idx = [i for i, (f, fl) in enumerate(zip(fees, flags)) if pick(f, fl)]
        vol = sum(priced[i]["usd"] for i in idx)
        adv = [(adverse[i + 1], priced[i]["usd"]) for i in idx if adverse[i + 1] is not None]
        adv_bps = sum(a for a, _ in adv) / sum(v for _, v in adv) * 1e4 if adv and sum(v for _, v in adv) else 0
        w(f"| {name} | {len(idx):,} | {pct(vol / s['volume'])} | {money(vol * static_fee / 1e6)} | "
          f"{money(sum(priced[i]['usd'] * fees[i] for i in idx) / 1e6)} | {adv_bps:+.2f} |")
    capped = sum(1 for f, fl in zip(fees, flags) if (f - config.mev_surcharge if fl else f) >= m)
    w(f"\nSwaps priced at the cap (`maxFee`): {capped:,} ({pct(capped / len(fees))}).\n")

    w("## Same-block reversal check\n")
    backruns = likely_sandwich_backruns(swaps)
    flagged = {i + 1 for i, fl in enumerate(flags) if fl}
    hit = flagged & backruns
    fl_vol = sum(swaps[i]["usd"] for i in flagged)
    w(f"- Swaps flagged by the hook: {len(flagged):,} of {len(fees):,} ({pct(len(flagged) / len(fees))}), "
      f"{pct(fl_vol / s['volume'])} of volume")
    w(f"- Swaps that look like a sandwich's closing leg: {len(backruns):,}")
    w(f"- Of those, flagged by the hook: {len(hit):,}" + (f" ({pct(len(hit) / len(backruns))})" if backruns else ""))
    w(f"- Flagged swaps that do **not** look like a sandwich: {len(flagged - backruns):,}"
      + (f" ({pct(len(flagged - backruns) / len(flagged))} of flags)" if flagged else ""))
    w(f"- Surcharge collected: {money(fl_vol * config.mev_surcharge / 1e6)}\n")
    w("The sandwich pattern is a heuristic on log data: the same sender trades one way, another transaction "
      "trades the same way, and the first sender trades back, all in one block. It misses sandwiches split "
      "across senders and counts some arbitrage as sandwiches.\n")

    if sweep:
        w("## Sweep 1: which settings aim the fee best?\n")
        w("`alphaBps` and `samplePeriod` decide *which* swaps pay more; they set the ranking, not the level. "
          "For each pair, swaps are ranked by the volatility the hook saw, and the table compares LP losses on "
          "the calmest quarter of volume with the most volatile quarter. A bigger gap means the fee lands on "
          "the flow that costs LPs the most.\n")
        w("| alphaBps | samplePeriod | Adverse selection, calmest 25% of volume | Most volatile 25% | Gap |")
        w("|---|---|---|---|---|")
        rows = []
        for alpha, period in itertools.product((500, 1000, 2000, 5000), (12, 60, 300, 900)):
            probe = Config(base_fee=0, max_fee=999_000, mev_surcharge=0, fee_per_tick=1000,
                           alpha_bps=alpha, sample_period=period)
            f, _ = replay(swaps, probe)
            low, high = quartile_adverse(priced, f, adverse)
            rows.append((high - low, alpha, period, low, high))
        for gap, alpha, period, low, high in sorted(rows, reverse=True):
            w(f"| {alpha} | {period} | {low:+.2f} bps | {high:+.2f} bps | {gap:.2f} bps |")
        w("")

        w("## Sweep 2: how high should the fee be?\n")
        w(f"`baseFee` and `feePerTick` set the level. `alphaBps` {config.alpha_bps} and `samplePeriod` "
          f"{config.sample_period}s as configured, `mevSurcharge` 0 to isolate the volatility fee. The static pool "
          f"charges {static_fee / 100:.2f} bps. Rows near 1.00x charge about what the market already pays; "
          "the further above, the less the fixed-flow assumption can be trusted.\n")
        w("| baseFee | feePerTick | Volume-weighted fee | Revenue vs static | Volume charged less than static | "
          "Break-even volume loss |")
        w("|---|---|---|---|---|---|")
        for base, per_tick in itertools.product((200, 300, 400, 500), (5, 10, 15, 25, 50, 100)):
            c = Config(base_fee=base, max_fee=config.max_fee, mev_surcharge=0, fee_per_tick=per_tick,
                       alpha_bps=config.alpha_bps, sample_period=config.sample_period)
            f, fl = replay(swaps, c)
            r = summarize(swaps, f, fl, static_fee, adverse)
            w(f"| {base} | {per_tick} | {r['avg_fee'] / 100:.2f} bps | {r['ratio']:.2f}x | {pct(r['vol_below'])} | "
              f"{pct(r['break_even']) if r['ratio'] > 1 else 'n/a'} |")
        w("")
    return "\n".join(out), fees


def write_fixture(swaps, path, size, configs):
    """A slice of the real data plus the model's fees, for the Solidity differential test."""
    # start where the price is moving, so decay, the cap and reversals are all exercised
    best = max(range(0, len(swaps) - size, size // 4),
               key=lambda i: sum(abs(swaps[j + 1]["tick"] - swaps[j]["tick"]) for j in range(i, i + size)))
    part = swaps[best:best + size + 1]
    fixture = {
        "seedTick": part[0]["tick"],
        "seedTimestamp": part[0]["timestamp"],
        "blocks": [s["block"] for s in part[1:]],
        "timestamps": [s["timestamp"] for s in part[1:]],
        "zeroForOne": [s["zero_for_one"] for s in part[1:]],
        "ticks": [s["tick"] for s in part[1:]],
    }
    for name, c in configs.items():
        fees, _ = replay(part, c)
        fixture[name] = {
            "config": [c.base_fee, c.max_fee, c.mev_surcharge, c.fee_per_tick, c.alpha_bps, c.sample_period],
            "fees": fees,
        }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(fixture, f, separators=(",", ":"))
    print(f"wrote fixture: {size} swaps from block {part[0]['block']} to {path}", file=sys.stderr)


def check_fixture(path):
    """Re-runs the model over a fixture's swaps and compares with the fees stored in it."""
    with open(path) as f:
        fx = json.load(f)
    part = [{"tick": fx["seedTick"], "timestamp": fx["seedTimestamp"]}] + [
        {"block": b, "timestamp": t, "zero_for_one": z, "tick": k}
        for b, t, z, k in zip(fx["blocks"], fx["timestamps"], fx["zeroForOne"], fx["ticks"])
    ]
    ok = True
    for name in ("defaults", "alternate"):
        fees, _ = replay(part, Config(*fx[name]["config"]))
        bad = [i for i, (a, b) in enumerate(zip(fees, fx[name]["fees"])) if a != b]
        print(f"{name}: {len(fees)} swaps, {len(bad)} mismatches" + (f", first at {bad[0]}" if bad else ""))
        ok = ok and not bad and len(fees) == len(fx[name]["fees"])
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default="backtest/data/swaps.csv")
    ap.add_argument("--out", help="write the markdown report here (default: stdout)")
    ap.add_argument("--static-fee", type=int, default=500, help="LP fee of the real pool, in pips")
    ap.add_argument("--decimals0", type=int, default=18)
    ap.add_argument("--decimals1", type=int, default=6, help="token1 is treated as the USD leg")
    ap.add_argument("--horizon", type=int, default=300, help="seconds ahead for adverse selection")
    ap.add_argument("--base-fee", type=int, default=500)
    ap.add_argument("--max-fee", type=int, default=20_000)
    ap.add_argument("--mev-surcharge", type=int, default=3000)
    ap.add_argument("--fee-per-tick", type=int, default=100)
    ap.add_argument("--alpha-bps", type=int, default=2000)
    ap.add_argument("--sample-period", type=int, default=60)
    ap.add_argument("--no-sweep", action="store_true")
    ap.add_argument("--fixture", help="also write a differential-test fixture to this path")
    ap.add_argument("--fixture-size", type=int, default=2000)
    ap.add_argument("--check-fixture", help="verify a fixture against the model and exit")
    args = ap.parse_args()

    if args.check_fixture:
        sys.exit(0 if check_fixture(args.check_fixture) else 1)

    swaps = load(args.data)
    enrich(swaps, args.decimals0, args.decimals1)
    config = Config(args.base_fee, args.max_fee, args.mev_surcharge, args.fee_per_tick, args.alpha_bps, args.sample_period)

    text, _ = report(swaps, config, args.static_fee, args.horizon, args.decimals0, not args.no_sweep)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        print(text)

    if args.fixture:
        write_fixture(swaps, args.fixture, args.fixture_size, {
            "defaults": config,
            "alternate": Config(base_fee=300, max_fee=5000, mev_surcharge=1000, fee_per_tick=37,
                                alpha_bps=5000, sample_period=300),
        })


if __name__ == "__main__":
    main()
