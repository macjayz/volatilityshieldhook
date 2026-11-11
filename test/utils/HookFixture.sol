// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {VolatilityShieldHook} from "../../src/hooks/VolatilityShieldHook.sol";

/// @dev Shared setup: a real PoolManager, the hook at a flag-encoded address, and one dynamic-fee
///      ERC-20 pool with full-range liquidity. Fees are read from the PoolManager's own `Swap` event,
///      so they are the fees the pool actually charged, not what the hook says it returned.
abstract contract HookFixture is Deployers {
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint256 constant WAD = 1e18;

    uint24 constant BASE_FEE = 500; // 0.05%
    uint24 constant MAX_FEE = 20_000; // 2%
    uint24 constant MEV_SURCHARGE = 3000; // 0.30%
    uint32 constant FEE_PER_TICK = 100; // +0.01% per tick of volatility
    uint16 constant ALPHA_BPS = 2000; // 20%
    uint32 constant PERIOD = 60; // seconds

    VolatilityShieldHook hook;
    PoolId id;
    address owner = makeAddr("owner");

    // via-IR may cache block.timestamp / block.number across cheatcodes, so the test tracks them itself.
    uint256 time = 1_700_000_000;
    uint256 blockNo = 100;

    function setUp() public virtual {
        vm.warp(time);
        vm.roll(blockNo);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = _deployHook(_defaultConfig());
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        _addLiquidity(key, 0);
    }

    function _defaultConfig() internal pure returns (VolatilityShieldHook.Config memory) {
        return VolatilityShieldHook.Config({
            baseFee: BASE_FEE,
            maxFee: MAX_FEE,
            mevSurcharge: MEV_SURCHARGE,
            feePerTick: FEE_PER_TICK,
            alphaBps: ALPHA_BPS,
            samplePeriod: PERIOD,
            revertOnSuspectedMEV: false
        });
    }

    /// @dev Volatility pricing switched off, to isolate the same-block reversal logic.
    function _flatConfig() internal pure returns (VolatilityShieldHook.Config memory c) {
        c = _defaultConfig();
        c.feePerTick = 0;
    }

    function _setConfig(VolatilityShieldHook.Config memory c) internal {
        vm.prank(owner);
        hook.setPoolConfig(id, c);
    }

    function _deployHook(VolatilityShieldHook.Config memory c) internal returns (VolatilityShieldHook) {
        address at = address(FLAGS | (uint160(0x4444) << 144));
        deployHookAt(c, at);
        return VolatilityShieldHook(at);
    }

    /// @dev Runs the real constructor (including the address-permission check) at a flag-encoded address.
    function deployHookAt(VolatilityShieldHook.Config memory c, address at) public {
        deployCodeTo("VolatilityShieldHook.sol:VolatilityShieldHook", abi.encode(manager, owner, c), at);
    }

    /// @dev Full-range liquidity. `value` is the ETH to send for a native-currency pool.
    function _addLiquidity(PoolKey memory k, uint256 value) internal {
        modifyLiquidityRouter.modifyLiquidity{value: value}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(k.tickSpacing),
                tickUpper: TickMath.maxUsableTick(k.tickSpacing),
                liquidityDelta: 1000 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint24) {
        return _swap(key, zeroForOne, amountIn);
    }

    /// @dev Exact-input swap; returns the swap fee from the PoolManager's Swap event.
    function _swap(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal returns (uint24) {
        return _swapRaw(k, zeroForOne, -int256(amountIn), 0);
    }

    /// @dev `amountSpecified` < 0 is exact input, > 0 exact output. `value` is ETH sent with the swap.
    function _swapRaw(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (uint24 fee)
    {
        vm.recordLogs();
        swapRouter.swap{value: value}(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }

    function _advance(uint256 dt) internal {
        time += dt;
        vm.warp(time);
        vm.roll(++blockNo);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    function _absTick() internal view returns (uint256) {
        int24 tick = _tick();
        return uint256(int256(tick < 0 ? -tick : tick));
    }

    function _tickDistance(int256 from) internal view returns (uint256) {
        int256 d = int256(_tick()) - from;
        return uint256(d < 0 ? -d : d);
    }

    function _nextCreateAddress() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    }
}
