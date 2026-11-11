// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Addresses shared between the scripts, persisted to `deployments/<chainId>.json`.
abstract contract Deployment is Script {
    int24 internal constant TICK_SPACING = 60;

    struct Addresses {
        address poolManager;
        address hook;
        address token0;
        address token1;
        address liquidityRouter;
        address swapRouter;
    }

    function _path() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _load() internal view returns (Addresses memory a) {
        string memory json = vm.readFile(_path());
        a.poolManager = vm.parseJsonAddress(json, ".poolManager");
        a.hook = vm.parseJsonAddress(json, ".hook");
        a.token0 = vm.parseJsonAddress(json, ".token0");
        a.token1 = vm.parseJsonAddress(json, ".token1");
        a.liquidityRouter = vm.parseJsonAddress(json, ".liquidityRouter");
        a.swapRouter = vm.parseJsonAddress(json, ".swapRouter");
    }

    function _save(Addresses memory a) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "poolManager", a.poolManager);
        vm.serializeAddress(obj, "hook", a.hook);
        vm.serializeAddress(obj, "token0", a.token0);
        vm.serializeAddress(obj, "token1", a.token1);
        vm.serializeAddress(obj, "liquidityRouter", a.liquidityRouter);
        vm.writeJson(vm.serializeAddress(obj, "swapRouter", a.swapRouter), _path());
    }

    function _poolKey(Addresses memory a) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(a.token0),
            currency1: Currency.wrap(a.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(a.hook)
        });
    }
}
