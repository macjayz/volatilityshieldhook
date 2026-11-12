# Backtest

Replays real Uniswap V4 swaps through the hook's fee logic and reports what LPs would have earned compared with the pool's actual static fee.

Full output of the latest run: [RESULTS.md](RESULTS.md).

## What the latest run says

30 days of the mainnet V4 ETH/USDC 0.05% pool, 12 October to 11 November 2026: 47,549 swaps, $137.3M volume.

**1. The volatility measure did not reliably predict which swaps cost LPs money.** This is the assumption the whole design rests on, and this month of data does not confirm it.

- Dollar-weighted, it looks strong: the calmest quarter of volume cost LPs 3.73 bps and the most volatile quarter 18.26 bps.
- But that result comes from very few swaps. The largest 1% of swaps are 53.3% of the volume, and a single day is 50.0% of it.
- Split the month in two and the gap is 2.63 bps in the first half and 21.94 bps in the second.
- Day by day, the volatile quarter cost LPs more on 16 of 31 days, which is a coin flip.
- Per swap, with outliers clipped, each extra tick of volatility goes with +0.003 bps more LP loss, and the 95% interval (-0.046 to +0.021) includes zero.

**2. The static 5 bps fee did not cover LP losses.** LPs collected $68,667 in fees and lost $209,694 to adverse selection. Most of that loss is on the same few large swaps; per swap, the average loss is 5.6 bps against a 5 bps fee.

**3. The original default settings were far too expensive.** `baseFee` 500 with `feePerTick` 100 would have charged a volume-weighted 36.97 bps on a pool that trades at 5 bps.

**4. The same-block reversal check flags ordinary trading, not sandwiches.** It flagged 2,067 swaps (4.3% of swaps, 8.5% of volume). 98.6% of them do not look like a sandwich's closing leg. It did catch 28 of the 31 that do. Flagged swaps cost LPs about the same as the rest (5.97 bps against 5.64 bps per swap), so the surcharge does not protect LPs either.

## What changed because of it

The defaults in `script/DeployHook.s.sol` now follow a simple rule, stated in the report, instead of a guess:

| Setting | Before | Now | Why |
|---|---|---|---|
| `baseFee` | 500 | 500 | The reference pool's tier. The hook never charges less than a plain pool. |
| `feePerTick` | 100 | 5 | The fee reaches three times the base at the 99th percentile of volatility (200 ticks). |
| `maxFee` | 20000 | 10000 | 1%, the highest standard Uniswap tier. |
| `mevSurcharge` | 3000 | 0 | Almost nothing the check flags is a sandwich. Still available per pool. |
| `alphaBps`, `samplePeriod` | 2000, 60 | unchanged | Sweep 1 shows the data cannot tell these settings apart. |

With the new defaults the hook would have charged a volume-weighted 6.71 bps, 1.34x the static pool's fee revenue if no volume left. It stays ahead unless more than 25.5% of volume leaves.

This is a level rule, not a fit. Because point 1 is unproven, the slope is deliberately small: the hook behaves like a 5 bps pool almost all the time and charges more only in bursts.

The alternative I did not choose is a base below the tier with a steeper slope, for example `baseFee` 200 with `feePerTick` 10. That averages 5.42 bps over this month, but it charges less than a plain pool on 81.7% of volume and depends on a few volatile days to make it up. That is a bet on point 1.

## What this does not show

- **It assumes the same swaps would have happened.** A different fee changes who trades. Revenue above 1.00x is an upper bound, and the break-even column in the report is the honest way to read it.
- **One pool, one month, and effectively one day.** Half the volume traded on a single day. ETH ranged from 2,010 to 2,773 USDC. Another month could look very different.
- **Adverse selection is measured against the pool's own price 300 seconds later**, not an exchange feed, and it includes each swap's own price impact (about half of the 5-minute figure on this pool).
- **The sandwich pattern is a heuristic on log data.** It misses sandwiches split across senders and counts some arbitrage as sandwiches.
- **No competition model.** It does not simulate routers moving volume to cheaper pools.

## How it stays honest about the contract

The fee logic in [model.py](model.py) is an integer-exact port of `VolatilityShieldHook.sol`. That is checked, not assumed:

- `test/BacktestModel.t.sol` replays 2,000 consecutive real swaps through the contract and requires every fee to equal the model's, for three different configs.
- CI re-runs the model over the same fixture: `python3 backtest/run.py --check-fixture test/fixtures/backtest_sample.json`.

So model, fixture and contract agree, and a change to either the contract or the model that breaks the match fails CI.

## Run it

Requires Python 3.9+ and Foundry. No Python packages.

```bash
python3 backtest/fetch_swaps.py --rpc <mainnet rpc url> --days 30
```

```bash
python3 backtest/run.py --out backtest/RESULTS.md
```

The RPC must serve a month of historical logs and include `blockTimestamp` on each log. The downloaded CSV goes to `backtest/data/`, which is not committed.

Options for `run.py`:

| Flag | Meaning |
|---|---|
| `--base-fee`, `--max-fee`, `--mev-surcharge`, `--fee-per-tick`, `--alpha-bps`, `--sample-period` | Hook config to test. Defaults match `script/DeployHook.s.sol`. |
| `--static-fee` | LP fee of the real pool in pips (default 500). |
| `--horizon` | Seconds ahead for the adverse-selection measure (default 300). |
| `--no-sweep` | Skip the two parameter sweeps. |
| `--fixture <path>` | Also write a differential-test fixture. |
| `--check-fixture <path>` | Verify a fixture against the model and exit. |

`fetch_swaps.py` takes `--pool-id` for a different V4 pool. `run.py` treats token1 as the USD leg; set `--decimals0` and `--decimals1` for other pairs.

## How the report is built

For each historical swap, in order:

1. Ask the model what fee the hook would charge, given the state left by all earlier swaps, the swap's block, timestamp and direction.
2. Record the tick the real swap left the pool at, so the model's volatility follows the real price path.

Fee revenue is the swap's USD leg times the fee. The first swap only seeds the starting tick.

| Section | Question it answers |
|---|---|
| LP fee revenue | What would LPs have collected, and how much volume could leave before that stops being better? |
| Adverse selection | Does fee income cover what LPs lose to better-informed traders? |
| Charging the right swaps | Are the swaps with higher hook fees the ones that cost LPs more? |
| How much weight can that bear | Does the answer survive splitting the month, going day by day, and counting every swap once? |
| Same-block reversal check | How often does it fire, and on what? |
| Settings rule | What level do the defaults follow from? |
| Sweep 1 | Can the data tell `alphaBps` and `samplePeriod` settings apart? |
| Sweep 2 | What does each `baseFee` and `feePerTick` level cost traders and earn LPs? |
