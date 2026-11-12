# Backtest

Replays real Uniswap V4 swaps through the hook's fee logic and reports what LPs would have earned compared with the pool's actual static fee.

Full output of the latest run: [RESULTS.md](RESULTS.md).

## What the latest run says

30 days of the mainnet V4 ETH/USDC 0.05% pool, 12 October to 11 November 2026: 47,549 swaps, $137.3M volume.

**1. The shipped default settings are far too expensive for a liquid pair.** With the defaults (`baseFee` 500, `feePerTick` 100) the hook would have charged a volume-weighted 36.97 bps on a pool that trades at 5 bps. Only 111 swaps would have paid the base fee. The report shows this as 7.39x the fee revenue, but that figure assumes nobody leaves, and at seven times the market price most volume would. The defaults were guesses and this is the evidence that they need recalibrating before real use.

**2. The volatility signal does find the swaps that cost LPs money.** Ranked by the volatility the hook saw, the calmest quarter of volume cost LPs 3.73 bps in adverse selection; the most volatile quarter cost 18.26 bps. That is the property the design depends on, and it holds on real data.

**3. The static 5 bps fee did not cover LP losses.** LPs collected $68,667 in fees and lost $209,694 to adverse selection over the window, a net of -$141,029. The loss is concentrated in the swaps the hook would price higher.

**4. A fee-neutral setting exists.** With `baseFee` 200 and `feePerTick` 10 the hook's volume-weighted fee is 5.42 bps, about what the market already pays. It would have charged *less* than the static pool on 81.7% of volume and more on the rest.

**5. The same-block reversal surcharge is aimed at the wrong flow.** The hook flagged 2,067 swaps (4.3% of swaps, 8.5% of volume). Only 28 of them look like the closing leg of a sandwich; 98.6% of flags do not. It did catch 28 of the 31 sandwich-shaped swaps in the data. Flagged swaps also had the *lowest* LP loss of any group (0.37 bps), because a swap that brings the price back is good for LPs. As it stands the surcharge mostly taxes ordinary two-way flow, and it protects traders at best, not LPs.

## What this does not show

- **It assumes the same swaps would have happened.** A different fee changes who trades. Revenue above 1.00x is an upper bound, and the break-even column in the report is the honest way to read it.
- **One pool, one month.** ETH ranged from 2,010 to 2,773 USDC. A calmer or wilder month would move every number.
- **Adverse selection is measured against the pool's own price 300 seconds later**, not an exchange feed, and it includes each swap's own price impact (about half of the 5-minute figure on this pool).
- **The sandwich pattern is a heuristic on log data.** It misses sandwiches split across senders and counts some arbitrage as sandwiches.
- **No competition model.** It does not simulate routers moving volume to cheaper pools.

## How it stays honest about the contract

The fee logic in [model.py](model.py) is an integer-exact port of `VolatilityShieldHook.sol`. That is checked, not assumed:

- `test/BacktestModel.t.sol` replays 2,000 consecutive real swaps through the contract and requires every fee to equal the model's, for two different configs.
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
| Same-block reversal check | How often does it fire, and on what? |
| Sweep 1 | Which `alphaBps` and `samplePeriod` aim the fee best? |
| Sweep 2 | Which `baseFee` and `feePerTick` put the fee at a sensible level? |
