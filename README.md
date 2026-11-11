# VolatilityShieldHook

A Uniswap V4 hook that sets the LP fee of every swap from recent price volatility, and charges extra for swaps that reverse direction inside a single block.

- **Volatility fee.** The hook tracks an exponentially weighted moving average of how many ticks the pool's price moves per period. The fee is `baseFee + feePerTick × volatility`, capped at `maxFee`. LPs earn more while the price is unstable, and the fee falls back to the base as the pool calms down.
- **Same-block reversal surcharge.** A swap in the opposite direction to the previous swap of the same block (the shape of a sandwich back-run) pays `mevSurcharge` on top, or reverts if the pool is configured with `revertOnSuspectedMEV`.

Not audited. Not deployed to a public network.

## How it works

The hook uses three V4 callbacks, encoded in its address as required by V4:

| Callback | What it does |
|---|---|
| `afterInitialize` | Rejects pools that are not dynamic-fee pools, copies the default config to the pool, and records the starting tick. |
| `beforeSwap` | Read-only. Computes the fee from stored volatility and returns it with `OVERRIDE_FEE_FLAG`, so the PoolManager charges it for this swap. |
| `afterSwap` | Reads the pool's new tick and adds the distance the swap moved it to the volatility estimate. One storage write per swap. |

Volatility update, per swap:

```
periods     = floor((now - decayedAt) / samplePeriod)
volatility  = volatility × (1 - alpha)^periods  +  alpha × |tick_after - tick_before|
```

Moves are counted by distance travelled, not net change, so a round trip inside one period raises the fee twice. Decay depends only on elapsed time, so dust swaps cannot dilute the estimate.

Units: fees are in V4 LP-fee units (hundredths of a basis point: `10000` = 1%, `1000000` = 100%). Volatility is in ticks scaled by 1e18; one tick is about one basis point of price.

### Config

Set per pool by the owner (`setPoolConfig`), with a default for new pools (`setDefaultConfig`).

| Field | Meaning |
|---|---|
| `baseFee` | Fee at zero volatility. |
| `maxFee` | Cap on the volatility fee. |
| `mevSurcharge` | Added for a same-block reversal. Stacks on top of `maxFee`. |
| `feePerTick` | Fee added per tick of volatility. |
| `alphaBps` | EWMA smoothing factor, 1 to 10000. |
| `samplePeriod` | Seconds per EWMA period. |
| `revertOnSuspectedMEV` | Revert same-block reversals instead of surcharging them. |

`setWhitelist(address, bool)` exempts an address from the reversal check. It is matched against both the swap `sender` (the router that called the PoolManager) and `tx.origin`.

`previewFee(poolId, zeroForOne, sender, origin)` returns the fee a swap would be charged right now.

### Limits

- A swap is priced on volatility recorded before it. Its own price impact is charged to the swaps that follow.
- The reversal check is a heuristic on the pool, not on the trader. It cannot be evaded by using several addresses, but it also flags honest opposing flow and arbitrage that lands in the same block. It does not see sandwiches that span blocks.
- Ownership is a single address (two-step transfer). The owner can change fees up to 100%.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/macjayz/volatilityshieldhook
cd volatilityshieldhook
forge test
```

The tests in `test/VolatilityShieldHook.t.sol` run against a real V4 `PoolManager` and read fees from its `Swap` event, so they assert what the pool actually charged. They cover hook-address validation and CREATE2 salt mining, pool initialization, the fee after large moves, decay, the cap, the reversal surcharge and whitelist, `revertOnSuspectedMEV`, access control, and config validation. Two fuzz tests check that the charged fee always equals `previewFee` and stays in bounds, and that the stored EWMA matches an independent reference model.

## Local demo

```bash
./run_demo.sh
```

Starts Anvil if it is not running, deploys a `PoolManager` and the hook, creates a dynamic-fee pool with two mock tokens, and runs five swaps. Output from a real run:

```
1. small swap, calm pool                     quoted    500   charged    500 pips (0.05%)
2. large swap (moves the price ~2%)          quoted    520   charged    520 pips (0.05%)
3. small swap right after the large one      quoted   4480   charged   4480 pips (0.44%)
4. small swap three minutes later            quoted   2537   charged   2537 pips (0.25%)
5. small swap after a quiet day              quoted    500   charged    500 pips (0.05%)
```

"Charged" is read from the PoolManager's `Swap` event. The private key in the script is Anvil's public test key.

## Deploying to a network

```bash
POOL_MANAGER=<v4 PoolManager address> HOOK_OWNER=<owner> \
forge script script/DeployHook.s.sol --rpc-url <rpc> --private-key <key> --broadcast
```

The script mines a CREATE2 salt so the hook address encodes its permissions, deploys through the standard CREATE2 deployer, and writes the address to `deployments/<chainId>.json`. Fee settings can be overridden with `BASE_FEE`, `MAX_FEE`, `MEV_SURCHARGE`, `FEE_PER_TICK`, `ALPHA_BPS`, `SAMPLE_PERIOD` and `REVERT_ON_SUSPECTED_MEV`.

Pools must be created with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` and `hooks = <hook address>`. `CreatePoolAddLiquidity.s.sol` and `DemoSwap.s.sol` use v4-core's test routers and only run on Anvil.

## Layout

```
src/hooks/VolatilityShieldHook.sol   the hook
test/VolatilityShieldHook.t.sol      tests against a real PoolManager
script/DeployHook.s.sol              CREATE2 deployment
script/CreatePoolAddLiquidity.s.sol  local demo pool
script/DemoSwap.s.sol                one demo swap
run_demo.sh                          end-to-end local demo
```

## License

MIT
