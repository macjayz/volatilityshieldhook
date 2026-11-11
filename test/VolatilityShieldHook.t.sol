// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";

/// @dev Every test runs against a real PoolManager. Fees are read from the PoolManager's own `Swap`
///      event, so they are the fees the pool actually charged, not what the hook says it returned.
contract VolatilityShieldHookTest is Deployers {
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

    function setUp() public {
        vm.warp(time);
        vm.roll(blockNo);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = _deployHook(_defaultConfig());
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        _addLiquidity(key);
    }

    // ------------------------------------------------------------------ deployment / wiring

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta || p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    function test_deploysWithMinedSalt() public {
        bytes memory args = abi.encode(manager, owner, _defaultConfig());
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(VolatilityShieldHook).creationCode, args);

        VolatilityShieldHook mined = new VolatilityShieldHook{salt: salt}(manager, owner, _defaultConfig());

        assertEq(address(mined), expected);
        assertEq(mined.owner(), owner);
        assertEq(address(mined.poolManager()), address(manager));
    }

    function test_revertsWhenAddressDoesNotEncodePermissions() public {
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, _nextCreateAddress()));
        new VolatilityShieldHook(manager, owner, _defaultConfig());
    }

    function test_constructorRejectsInvalidConfig() public {
        VolatilityShieldHook.Config memory c = _defaultConfig();
        c.alphaBps = 0;
        vm.expectRevert();
        this.deployHookAt(c, address(FLAGS | (uint160(0x5555) << 144)));
    }

    function test_initializeSeedsObservationAndConfig() public view {
        (int24 tick, uint40 decayedAt, uint48 lastSwapBlock,, uint128 ewma) = hook.observations(id);
        assertEq(tick, 0);
        assertEq(decayedAt, time);
        assertEq(lastSwapBlock, 0);
        assertEq(ewma, 0);

        (uint24 baseFee, uint24 maxFee, uint24 surcharge, uint32 feePerTick, uint16 alpha, uint32 period, bool rev) =
            hook.poolConfig(id);
        assertEq(baseFee, BASE_FEE);
        assertEq(maxFee, MAX_FEE);
        assertEq(surcharge, MEV_SURCHARGE);
        assertEq(feePerTick, FEE_PER_TICK);
        assertEq(alpha, ALPHA_BPS);
        assertEq(period, PERIOD);
        assertFalse(rev);
    }

    function test_initializeRevertsForStaticFeePool() public {
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(VolatilityShieldHook.DynamicFeeRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_initializeKeepsPreconfiguredPool() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        VolatilityShieldHook.Config memory c = _defaultConfig();
        c.baseFee = 1234;

        vm.prank(owner);
        hook.setPoolConfig(other.toId(), c);
        manager.initialize(other, SQRT_PRICE_1_1);
        _addLiquidity(other);

        assertEq(_swap(other, true, 1e15), 1234);
        assertEq(_swap(key, true, 1e15), BASE_FEE);
    }

    function test_onlyPoolManagerCanCallHook() public {
        SwapParams memory params = SwapParams(true, -1e18, MIN_PRICE_LIMIT);

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, ZERO_BYTES);

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), ZERO_BYTES);

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);

        vm.prank(owner);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, ZERO_BYTES);
    }

    // ------------------------------------------------------------------ volatility fee

    function test_calmPoolPaysBaseFee() public {
        assertEq(_swap(true, 1e15), BASE_FEE);

        // dust swaps can still step the price over a tick boundary; each crossing is worth
        // alpha * feePerTick on top of the base fee, and they decay between swaps
        uint24 oneTick = uint24(uint256(ALPHA_BPS) * FEE_PER_TICK / 10_000);
        for (uint256 i; i < 6; ++i) {
            _advance(PERIOD);
            assertLe(_swap(i % 2 == 0, 1e15), BASE_FEE + 2 * oneTick);
        }
    }

    function test_swapIsRecordedAndPricesTheNextSwap() public {
        assertEq(_swap(true, 10 ether), BASE_FEE, "the swap itself is priced on prior volatility");
        uint256 move = _absTick();
        assertGt(move, 100, "swap should move the price by more than 1%");

        (int24 tick, uint40 decayedAt, uint48 lastSwapBlock, bool lastZeroForOne, uint128 ewma) = hook.observations(id);
        assertEq(tick, _tick());
        assertEq(decayedAt, time);
        assertEq(lastSwapBlock, blockNo);
        assertTrue(lastZeroForOne);
        assertEq(ewma, move * WAD * ALPHA_BPS / 10_000);
        assertEq(hook.currentVolatility(id), ewma);

        uint24 expected = uint24(BASE_FEE + move * ALPHA_BPS * FEE_PER_TICK / 10_000);
        (uint24 quoted,) = hook.previewFee(id, true, address(swapRouter), tx.origin);
        assertEq(quoted, expected);
        assertEq(_swap(true, 1e15), expected);
    }

    function test_roundTripCountsBothLegs() public {
        _swap(true, 10 ether);
        uint256 out = _absTick();
        vm.roll(++blockNo);
        _swap(false, 10 ether);
        uint256 back = _tickDistance(-int256(out));

        assertLt(_absTick(), 10, "price is back near where it started");
        (,,,, uint128 ewma) = hook.observations(id);
        assertEq(ewma, (out + back) * WAD * ALPHA_BPS / 10_000);
    }

    function test_volatilityDecaysOverTime() public {
        _swap(true, 10 ether);
        (,,,, uint128 ewma) = hook.observations(id);

        // inside the first period nothing decays
        _advance(PERIOD - 1);
        assertEq(hook.currentVolatility(id), ewma);

        // three whole periods: 0.8^3 = 0.512
        _advance(2 * PERIOD + 1);
        assertEq(hook.currentVolatility(id), uint256(ewma) * 512 / 1000);
        uint24 expected = uint24(BASE_FEE + uint256(ewma) * 512 / 1000 * FEE_PER_TICK / WAD);
        assertEq(_swap(true, 1e15), expected);
        assertGt(expected, BASE_FEE);

        // a quiet day: back to the base fee
        _advance(1 days);
        assertEq(_swap(true, 1e15), BASE_FEE);
    }

    function test_frequentSwapsDoNotStopOrSpeedUpDecay() public {
        _swap(true, 10 ether);
        (, uint40 start,,, uint128 ewma) = hook.observations(id);

        // 8 dust swaps, one every 15 seconds = 2 whole periods
        for (uint256 i; i < 8; ++i) {
            _advance(PERIOD / 4);
            _swap(true, 1e12);
        }

        (, uint40 decayedAt,,, uint128 afterwards) = hook.observations(id);
        assertEq(decayedAt, start + 2 * PERIOD);
        assertEq(afterwards, uint256(ewma) * 64 / 100, "exactly two periods of decay, dust swaps add nothing");
    }

    function test_feeIsCappedAtMaxFee() public {
        _swap(true, 200 ether);
        assertGt(_absTick() * ALPHA_BPS * FEE_PER_TICK / 10_000, MAX_FEE, "move should exceed the cap");
        assertEq(_swap(true, 1e15), MAX_FEE);
    }

    // ------------------------------------------------------------------ same-block reversal

    function test_sameBlockReversalPaysSurcharge() public {
        _setConfig(_flatConfig());
        assertEq(_swap(true, 1e15), BASE_FEE);

        (uint24 quoted, bool suspected) = hook.previewFee(id, false, address(swapRouter), tx.origin);
        assertTrue(suspected);
        assertEq(quoted, BASE_FEE + MEV_SURCHARGE);
        assertEq(_swap(false, 1e15), BASE_FEE + MEV_SURCHARGE);
    }

    function test_sameDirectionInSameBlockIsNotSurcharged() public {
        _setConfig(_flatConfig());
        _swap(true, 1e15);
        assertEq(_swap(true, 1e15), BASE_FEE);
    }

    function test_reversalInNextBlockIsNotSurcharged() public {
        _setConfig(_flatConfig());
        _swap(true, 1e15);
        vm.roll(++blockNo);
        assertEq(_swap(false, 1e15), BASE_FEE);
    }

    function test_surchargeStacksOnTopOfMaxFee() public {
        _swap(true, 200 ether);
        assertEq(_swap(false, 1e15), MAX_FEE + MEV_SURCHARGE);
    }

    function test_whitelistedRouterIsExempt() public {
        _setConfig(_flatConfig());
        vm.prank(owner);
        hook.setWhitelist(address(swapRouter), true);

        _swap(true, 1e15);
        assertEq(_swap(false, 1e15), BASE_FEE);
    }

    function test_whitelistedOriginIsExempt() public {
        _setConfig(_flatConfig());
        vm.prank(owner);
        hook.setWhitelist(tx.origin, true);

        _swap(true, 1e15);
        assertEq(_swap(false, 1e15), BASE_FEE);

        vm.prank(owner);
        hook.setWhitelist(tx.origin, false);
        assertEq(_swap(true, 1e15), BASE_FEE + MEV_SURCHARGE);
    }

    function test_revertOnSuspectedMEV() public {
        VolatilityShieldHook.Config memory c = _flatConfig();
        c.revertOnSuspectedMEV = true;
        _setConfig(c);

        _swap(true, 1e15);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(VolatilityShieldHook.SuspectedMEV.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, false, -1e15, ZERO_BYTES);

        // same direction is still fine, and so is the reversal one block later
        assertEq(_swap(true, 1e15), BASE_FEE);
        vm.roll(++blockNo);
        assertEq(_swap(false, 1e15), BASE_FEE);
    }

    // ------------------------------------------------------------------ owner settings

    function test_ownerSettersAreOwnerOnly() public {
        VolatilityShieldHook.Config memory c = _defaultConfig();
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this));

        vm.expectRevert(unauthorized);
        hook.setDefaultConfig(c);
        vm.expectRevert(unauthorized);
        hook.setPoolConfig(id, c);
        vm.expectRevert(unauthorized);
        hook.setWhitelist(address(this), true);
    }

    function test_setPoolConfigChangesTheFee() public {
        VolatilityShieldHook.Config memory c = _defaultConfig();
        c.baseFee = 3000;
        vm.prank(owner);
        hook.setPoolConfig(id, c);

        assertEq(_swap(true, 1e15), 3000);
    }

    function test_setDefaultConfigAppliesToNewPools() public {
        VolatilityShieldHook.Config memory c = _defaultConfig();
        c.baseFee = 900;
        vm.prank(owner);
        hook.setDefaultConfig(c);

        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        manager.initialize(other, SQRT_PRICE_1_1);
        _addLiquidity(other);

        assertEq(_swap(other, true, 1e15), 900);
        assertEq(_swap(key, true, 1e15), BASE_FEE, "existing pool keeps its config");
    }

    function test_configValidation() public {
        vm.startPrank(owner);

        VolatilityShieldHook.Config memory c = _defaultConfig();
        c.alphaBps = 0;
        vm.expectRevert(VolatilityShieldHook.InvalidConfig.selector);
        hook.setPoolConfig(id, c);

        c = _defaultConfig();
        c.alphaBps = 10_001;
        vm.expectRevert(VolatilityShieldHook.InvalidConfig.selector);
        hook.setPoolConfig(id, c);

        c = _defaultConfig();
        c.samplePeriod = 0;
        vm.expectRevert(VolatilityShieldHook.InvalidConfig.selector);
        hook.setPoolConfig(id, c);

        c = _defaultConfig();
        c.baseFee = c.maxFee + 1;
        vm.expectRevert(VolatilityShieldHook.InvalidConfig.selector);
        hook.setDefaultConfig(c);

        c = _defaultConfig();
        c.maxFee = 999_000;
        c.mevSurcharge = 1001;
        vm.expectRevert(VolatilityShieldHook.InvalidConfig.selector);
        hook.setDefaultConfig(c);

        c.mevSurcharge = 1000; // exactly 100% in total is allowed
        hook.setDefaultConfig(c);

        vm.stopPrank();
    }

    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        hook.transferOwnership(next);
        assertEq(hook.owner(), owner);

        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Random swaps, directions, time jumps and block advances. For every swap the fee the pool
    ///      charged must equal the hook's quote taken just before it and stay inside the configured bounds.
    function testFuzz_chargedFeeMatchesQuoteAndBounds(uint256 seed) public {
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = seed & 1 == 0;
            uint256 amount = bound(seed >> 8, 1e12, 40 ether);
            uint256 dt = bound(seed >> 96, 0, 4 * PERIOD);
            if (dt != 0) _advance(dt);
            if (seed & 2 == 0) vm.roll(++blockNo);

            (uint24 quoted, bool suspected) = hook.previewFee(id, zeroForOne, address(swapRouter), tx.origin);
            uint24 charged = _swap(zeroForOne, amount);

            assertEq(charged, quoted);
            assertGe(charged, BASE_FEE);
            assertLe(charged, suspected ? MAX_FEE + MEV_SURCHARGE : MAX_FEE);
        }
    }

    /// @dev Checks the stored EWMA against a straightforward model (one multiplication per elapsed
    ///      period, no exponentiation by squaring) over random swaps, alphas and periods.
    function testFuzz_ewmaMatchesReferenceModel(uint256 seed, uint16 alphaBps, uint32 period) public {
        VolatilityShieldHook.Config memory c = _defaultConfig();
        c.alphaBps = uint16(bound(alphaBps, 1, 10_000));
        c.samplePeriod = uint32(bound(period, 1, 1 hours));
        _setConfig(c);

        uint256 model;
        uint256 modelDecayedAt = time;
        for (uint256 i; i < 10; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _advance(bound(seed >> 96, 0, 5 * uint256(c.samplePeriod)));

            int256 tickBefore = _tick();
            _swap(seed & 1 == 0, bound(seed >> 8, 1e12, 40 ether));

            uint256 periods = (time - modelDecayedAt) / c.samplePeriod;
            modelDecayedAt += periods * c.samplePeriod;
            for (uint256 j; j < periods; ++j) {
                model = model * (10_000 - c.alphaBps) / 10_000;
            }
            model += _tickDistance(tickBefore) * WAD * c.alphaBps / 10_000;

            (, uint40 decayedAt,,, uint128 ewma) = hook.observations(id);
            assertEq(decayedAt, modelDecayedAt);
            assertApproxEqAbs(ewma, model, 1e6); // rounding only: 1e-12 of a tick
        }
    }

    // ------------------------------------------------------------------ helpers

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

    function _addLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
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

    /// @dev Exact-input swap; returns the LP fee from the PoolManager's Swap event.
    function _swap(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal returns (uint24 fee) {
        vm.recordLogs();
        swap(k, zeroForOne, -int256(amountIn), ZERO_BYTES);
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
