// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";

contract DeployHook is Script {
    address constant POOL_MANAGER = address(0); // set this for testnet or use local fixture

    function run() external {
        vm.startBroadcast();
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        VolatilityShieldHook hook = new VolatilityShieldHook(pm);
        vm.stopBroadcast();
    }
}
