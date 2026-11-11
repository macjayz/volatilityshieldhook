// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {HookFixture} from "./utils/HookFixture.sol";

/// @dev Swap shapes beyond exact-input ERC-20: exact output, native ETH pools, pools with a
///      protocol fee switched on, and the gas the hook adds to a swap.
contract SwapModesTest is HookFixture {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ exact output

    function test_exactOutput_paysVolatilityFee() public {
        assertEq(_swapRaw(key, true, 1 ether, 0), BASE_FEE, "calm pool, exact output");

        _swapRaw(key, true, 10 ether, 0); // buy exactly 10 token1: moves the price ~2%
        (,,,, uint128 ewma) = hook.observations(id);
        assertGt(ewma, 100 * WAD * ALPHA_BPS / 10_000);

        (uint24 quoted,) = hook.previewFee(id, true, address(swapRouter), tx.origin);
        assertEq(quoted, uint24(BASE_FEE + uint256(ewma) * FEE_PER_TICK / WAD));
        assertEq(_swapRaw(key, true, 1e15, 0), quoted);
    }

    function test_exactOutput_reversalPaysSurcharge() public {
        _setConfig(_flatConfig());
        _swapRaw(key, true, 1e15, 0);
        assertEq(_swapRaw(key, false, 1e15, 0), BASE_FEE + MEV_SURCHARGE);
    }

    function testFuzz_exactOutput_chargedFeeMatchesQuote(uint256 seed) public {
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = seed & 1 == 0;
            if (seed & 2 == 0) _advance(bound(seed >> 96, 1, 4 * PERIOD));

            (uint24 quoted, bool suspected) = hook.previewFee(id, zeroForOne, address(swapRouter), tx.origin);
            uint24 charged = _swapRaw(key, zeroForOne, int256(bound(seed >> 8, 1e12, 20 ether)), 0);

            assertEq(charged, quoted);
            assertLe(charged, suspected ? MAX_FEE + MEV_SURCHARGE : MAX_FEE);
        }
    }

    // ------------------------------------------------------------------ native ETH

    function test_nativePool_volatilityFeeAndSurcharge() public {
        (PoolKey memory ethKey, PoolId ethId) = _initNativePool();

        // ETH in
        assertEq(_swapRaw(ethKey, true, -1e15, 1e15), BASE_FEE);
        _swapRaw(ethKey, true, -10 ether, 10 ether);

        (int24 tick,,,, uint128 ewma) = hook.observations(ethId);
        (, int24 poolTick,,) = manager.getSlot0(ethId);
        assertEq(tick, poolTick);
        assertGt(ewma, 100 * WAD * ALPHA_BPS / 10_000);

        uint24 volFee = uint24(BASE_FEE + uint256(ewma) * FEE_PER_TICK / WAD);
        assertEq(_swapRaw(ethKey, true, -1e15, 1e15), volFee);

        // ETH out, same block: reversal surcharge on top
        assertEq(_swapRaw(ethKey, false, -1e15, 0), volFee + MEV_SURCHARGE);
    }

    function test_poolsAreTrackedIndependently() public {
        (PoolKey memory ethKey,) = _initNativePool();
        _swapRaw(ethKey, true, -10 ether, 10 ether);

        // a volatile ETH pool does not raise the fee of the ERC-20 pool, and its swaps do not
        // count as the "previous swap" for the other pool's reversal check
        assertEq(_swap(false, 1e15), BASE_FEE);
        (,,,, uint128 ewma) = hook.observations(id);
        assertLe(ewma, WAD * ALPHA_BPS / 10_000, "at most the dust swap's own tick");
    }

    // ------------------------------------------------------------------ protocol fee

    function test_protocolFee_isChargedOnTopOfHookFee() public {
        uint16 protocolFee = 1000; // 0.1%, the maximum V4 allows
        vm.prank(feeController);
        manager.setProtocolFee(key, uint24(protocolFee) | (uint24(protocolFee) << 12));

        assertEq(_swap(true, 1e15), ProtocolFeeLibrary.calculateSwapFee(protocolFee, BASE_FEE));

        _swap(true, 10 ether);
        (uint24 lpFee,) = hook.previewFee(id, true, address(swapRouter), tx.origin);
        assertGt(lpFee, BASE_FEE);

        // the pool's swap fee is protocol fee + the hook's LP fee on the remainder
        assertEq(_swap(true, 1e15), ProtocolFeeLibrary.calculateSwapFee(protocolFee, lpFee));
        (,, uint24 slotProtocolFee,) = manager.getSlot0(id);
        assertEq(slotProtocolFee, uint24(protocolFee) | (uint24(protocolFee) << 12));
    }

    // ------------------------------------------------------------------ gas

    /// @dev Same swap on a pool with the hook and on a plain static-fee pool. Both pools are warmed
    ///      up first so the comparison is between two steady-state swaps.
    function test_gas_hookOverheadPerSwap() public {
        (PoolKey memory plain,) = initPool(currency0, currency1, IHooks(address(0)), BASE_FEE, 60, SQRT_PRICE_1_1);
        _addLiquidity(plain, 0);

        _swap(key, true, 1e15);
        _swap(plain, true, 1e15);
        _advance(PERIOD);

        uint256 g = gasleft();
        swap(key, true, -1e15, ZERO_BYTES);
        uint256 hooked = g - gasleft();

        g = gasleft();
        swap(plain, true, -1e15, ZERO_BYTES);
        uint256 unhooked = g - gasleft();

        emit log_named_uint("swap gas with hook   ", hooked);
        emit log_named_uint("swap gas without hook", unhooked);
        emit log_named_uint("hook overhead        ", hooked - unhooked);
        assertLt(hooked - unhooked, 20_000);
    }

    // ------------------------------------------------------------------ helpers

    function _initNativePool() internal returns (PoolKey memory ethKey, PoolId ethId) {
        ethKey = PoolKey(Currency.wrap(address(0)), currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        ethId = ethKey.toId();
        manager.initialize(ethKey, SQRT_PRICE_1_1);

        vm.deal(address(this), 10_000 ether);
        _addLiquidity(ethKey, 1001 ether); // the router refunds what it does not need
    }
}
