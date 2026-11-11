// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";
import {HookFixture} from "./utils/HookFixture.sol";

/// @dev The only contract the invariant fuzzer calls. It swaps in random sizes and directions, moves
///      time and blocks forward, and records what it saw so the invariants can check it.
contract Handler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;
    PoolSwapTest immutable router;
    VolatilityShieldHook immutable hook;
    PoolId immutable id;
    PoolKey key;

    uint24 immutable baseFee;
    uint24 immutable maxFee;
    uint24 immutable mevSurcharge;

    uint256 public time;
    uint256 public blockNo;

    uint256 public swaps;
    /// @dev Sum of |tick after - tick before| over every swap.
    uint256 public totalTicksMoved;
    uint256 public quoteMismatches;
    uint256 public feesOutOfBounds;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _router,
        VolatilityShieldHook _hook,
        PoolKey memory _key,
        uint256 _time,
        uint256 _blockNo
    ) {
        manager = _manager;
        router = _router;
        hook = _hook;
        key = _key;
        id = _key.toId();
        time = _time;
        blockNo = _blockNo;
        (baseFee, maxFee, mevSurcharge,,,,) = _hook.poolConfig(id);

        MockERC20(Currency.unwrap(_key.currency0)).approve(address(_router), type(uint256).max);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(_router), type(uint256).max);
    }

    function swap(uint256 amount, bool zeroForOne, bool exactOutput) external {
        amount = bound(amount, 1e12, 50 ether);
        vm.warp(time);
        vm.roll(blockNo);

        (uint24 quoted, bool suspected) = hook.previewFee(id, zeroForOne, address(router), tx.origin);
        (, int24 tickBefore,,) = manager.getSlot0(id);

        vm.recordLogs();
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactOutput ? int256(amount) : -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint24 charged = _chargedFee(vm.getRecordedLogs());

        (, int24 tickAfter,,) = manager.getSlot0(id);
        int256 d = int256(tickAfter) - tickBefore;
        totalTicksMoved += uint256(d < 0 ? -d : d);
        swaps++;

        if (charged != quoted) quoteMismatches++;
        if (charged < baseFee || charged > (suspected ? maxFee + mevSurcharge : maxFee)) feesOutOfBounds++;
    }

    function warp(uint256 dt) external {
        time += bound(dt, 1, 3 hours);
        blockNo++;
        vm.warp(time);
        vm.roll(blockNo);
    }

    function nextBlock() external {
        vm.roll(++blockNo);
    }

    function _chargedFee(Vm.Log[] memory logs) private view returns (uint24 fee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }
}

/// @dev Stateful fuzzing: long random sequences of swaps and time jumps against a real PoolManager,
///      with the properties below checked after every call.
contract VolatilityShieldInvariantTest is HookFixture {
    using StateLibrary for IPoolManager;

    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(manager, swapRouter, hook, key, time, blockNo);
        MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 1e30);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 1e30);
        targetContract(address(handler));
    }

    /// The fee the pool charged always equals the hook's quote taken just before the swap.
    function invariant_chargedFeeEqualsQuote() public view {
        assertEq(handler.quoteMismatches(), 0);
    }

    /// No swap is ever charged less than the base fee or more than the cap (plus surcharge if flagged).
    function invariant_chargedFeeWithinBounds() public view {
        assertEq(handler.feesOutOfBounds(), 0);
    }

    /// The hook's stored tick is always the pool's tick.
    function invariant_storedTickTracksPool() public view {
        (int24 stored,,,,) = hook.observations(id);
        (, int24 poolTick,,) = manager.getSlot0(id);
        assertEq(stored, poolTick);
    }

    /// Volatility only grows by alpha per tick moved and only shrinks with time, so it can never
    /// exceed alpha times the total distance the price has travelled.
    function invariant_volatilityBoundedByDistanceTravelled() public view {
        (,,,, uint128 ewma) = hook.observations(id);
        assertLe(ewma, handler.totalTicksMoved() * WAD * ALPHA_BPS / 10_000);
        assertLe(hook.currentVolatility(id), ewma);
    }

    /// The decay clock never runs ahead of the chain.
    function invariant_decayClockNotInFuture() public view {
        (, uint40 decayedAt,,,) = hook.observations(id);
        assertLe(decayedAt, handler.time());
    }

    /// Quotes for both directions are always inside the configured range.
    function invariant_quotesWithinBounds() public view {
        for (uint256 i; i < 2; ++i) {
            (uint24 fee,) = hook.previewFee(id, i == 0, address(swapRouter), tx.origin);
            assertGe(fee, BASE_FEE);
            assertLe(fee, MAX_FEE + MEV_SURCHARGE);
        }
    }

    /// Guards against a vacuous run: the handler must actually have swapped.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0);
    }
}
