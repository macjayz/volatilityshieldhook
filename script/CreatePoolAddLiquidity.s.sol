// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Deployment} from "./Deployment.sol";

/// @notice Local demo setup: two mock tokens, a dynamic-fee pool attached to the hook at price 1:1,
///         and full-range liquidity. Uses v4-core's test routers, so it is for Anvil only.
contract CreatePoolAddLiquidity is Deployment {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        require(block.chainid == 31337, "CreatePoolAddLiquidity: local demo only");
        Addresses memory a = _load();
        IPoolManager manager = IPoolManager(a.poolManager);

        vm.startBroadcast();

        MockERC20 tokenA = new MockERC20("Demo A", "DMA", 18);
        MockERC20 tokenB = new MockERC20("Demo B", "DMB", 18);
        (a.token0, a.token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        a.liquidityRouter = address(liquidityRouter);
        a.swapRouter = address(swapRouter);

        tokenA.mint(msg.sender, 1_000_000 ether);
        tokenB.mint(msg.sender, 1_000_000 ether);
        tokenA.approve(address(liquidityRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        PoolKey memory key = _poolKey(a);
        manager.initialize(key, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1000 ether,
                salt: 0
            }),
            ""
        );

        vm.stopBroadcast();
        _save(a);

        console2.log("Pool id:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("token0:", a.token0);
        console2.log("token1:", a.token1);
    }
}
