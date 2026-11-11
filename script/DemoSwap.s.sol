// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";
import {Deployment} from "./Deployment.sol";

/// @notice One exact-input swap through the demo pool. Logs the hook's fee quote and the pool tick
///         before the swap; `run_demo.sh` reads the fee actually charged from the PoolManager's Swap event.
///         forge script script/DemoSwap.s.sol --sig "run(bool,uint256)" <zeroForOne> <amountIn>
contract DemoSwap is Deployment {
    using StateLibrary for IPoolManager;

    function run(bool zeroForOne, uint256 amountIn) external {
        Addresses memory a = _load();
        PoolKey memory key = _poolKey(a);
        PoolId id = key.toId();

        (, int24 tick,,) = IPoolManager(a.poolManager).getSlot0(id);
        (uint24 fee, bool suspected) = VolatilityShieldHook(a.hook).previewFee(id, zeroForOne, a.swapRouter, msg.sender);

        console2.log("tick before swap:", tick);
        console2.log("quoted fee (pips, 10000 = 1%):", fee);
        if (suspected) console2.log("flagged as same-block reversal");

        vm.broadcast();
        PoolSwapTest(a.swapRouter).swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
