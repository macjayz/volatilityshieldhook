// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";
import {Deployment} from "./Deployment.sol";

/// @notice Deploys the hook with CREATE2 at an address whose low bits encode its permissions.
/// @dev    Env: POOL_MANAGER (required off Anvil; on chain 31337 a fresh PoolManager is deployed if unset),
///         HOOK_OWNER (defaults to the broadcaster), and the fee settings below.
contract DeployHook is Deployment {
    /// @dev Foundry routes `new C{salt: ...}` in a broadcast through this proxy.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", address(0));
        address owner = vm.envOr("HOOK_OWNER", msg.sender);

        // Defaults follow the settings rule in backtest/RESULTS.md, taken from a month of the mainnet
        // ETH/USDC 0.05% pool: base at that pool's tier, a slope that triples the fee at the 99th
        // percentile of volatility, and no reversal surcharge. Set them per pair before real use.
        VolatilityShieldHook.Config memory config = VolatilityShieldHook.Config({
            baseFee: uint24(vm.envOr("BASE_FEE", uint256(500))), // 0.05%
            maxFee: uint24(vm.envOr("MAX_FEE", uint256(10_000))), // 1%
            mevSurcharge: uint24(vm.envOr("MEV_SURCHARGE", uint256(0))), // off
            feePerTick: uint32(vm.envOr("FEE_PER_TICK", uint256(5))), // +0.0005% per tick of volatility
            alphaBps: uint16(vm.envOr("ALPHA_BPS", uint256(2000))),
            samplePeriod: uint32(vm.envOr("SAMPLE_PERIOD", uint256(60))),
            revertOnSuspectedMEV: vm.envOr("REVERT_ON_SUSPECTED_MEV", false)
        });

        vm.startBroadcast();

        if (poolManager == address(0)) {
            require(block.chainid == 31337, "DeployHook: set POOL_MANAGER");
            poolManager = address(new PoolManager(msg.sender));
        }

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(VolatilityShieldHook).creationCode, abi.encode(poolManager, owner, config)
        );

        VolatilityShieldHook hook = new VolatilityShieldHook{salt: salt}(IPoolManager(poolManager), owner, config);
        require(address(hook) == expected, "DeployHook: address mismatch");

        vm.stopBroadcast();

        Addresses memory a;
        a.poolManager = poolManager;
        a.hook = address(hook);
        _save(a);

        console2.log("PoolManager:", poolManager);
        console2.log("Hook:       ", address(hook));
        console2.log("Owner:      ", owner);
    }
}
