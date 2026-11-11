// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Runs against Ethereum mainnet state: the deployed PoolManager, PositionManager, Universal
///      Router and Permit2, with real USDC and WETH. Nothing here is a test double except the trader.
///      Skipped unless MAINNET_RPC_URL is set:
///        MAINNET_RPC_URL=<rpc> forge test --match-contract ForkTest -vv
contract ForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IUniversalRouter constant ROUTER = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 constant V4_SWAP = 0x10; // Universal Router command
    int24 constant TICK_SPACING = 60;
    /// @dev ~3000 USDC per WETH in raw token units, on the tick-spacing grid.
    int24 constant START_TICK = 196_260;

    uint24 constant BASE_FEE = 500;
    uint24 constant MAX_FEE = 20_000;
    uint24 constant MEV_SURCHARGE = 3000;

    VolatilityShieldHook hook;
    PoolKey key;
    PoolId id;
    address owner = makeAddr("owner");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        VolatilityShieldHook.Config memory config = VolatilityShieldHook.Config({
            baseFee: BASE_FEE,
            maxFee: MAX_FEE,
            mevSurcharge: MEV_SURCHARGE,
            feePerTick: 100,
            alphaBps: 2000,
            samplePeriod: 60,
            revertOnSuspectedMEV: false
        });

        // the same CREATE2 salt mining the deploy script does
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), flags, type(VolatilityShieldHook).creationCode, abi.encode(MANAGER, owner, config)
        );
        hook = new VolatilityShieldHook{salt: salt}(MANAGER, owner, config);
        assertEq(address(hook), expected);

        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        id = key.toId();
        MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));

        deal(USDC, address(this), 100_000_000e6);
        deal(WETH, address(this), 100_000 ether);
        _approve(USDC);
        _approve(WETH);
        _mintLiquidity(3_000_000e6, 1000 ether);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployedContractsAreWiredTogether() public onlyFork {
        assertEq(address(POSM.poolManager()), address(MANAGER));
        assertGt(address(ROUTER).code.length, 0);
        assertEq(address(hook.poolManager()), address(MANAGER));
    }

    function test_fork_initializeRegistersPool() public onlyFork {
        (int24 tick,,,, uint128 ewma) = hook.observations(id);
        assertEq(tick, START_TICK);
        assertEq(ewma, 0);
        assertGt(MANAGER.getLiquidity(id), 0, "PositionManager mint reached the pool");
        (uint24 baseFee,,,,,,) = hook.poolConfig(id);
        assertEq(baseFee, BASE_FEE);
    }

    function test_fork_volatilityFeeThroughUniversalRouter() public onlyFork {
        // calm pool: base fee
        assertEq(_swap(true, 1000e6), BASE_FEE);

        // sell 100 WETH into ~1000 WETH of liquidity: a large move
        _swap(false, 100 ether);
        (int24 stored,,,, uint128 ewma) = hook.observations(id);
        (, int24 poolTick,,) = MANAGER.getSlot0(id);
        assertEq(stored, poolTick);
        assertGt(ewma, 0);

        (uint24 quoted,) = hook.previewFee(id, false, address(ROUTER), tx.origin);
        assertGt(quoted, BASE_FEE);
        assertEq(_swap(false, 0.01 ether), quoted);

        // a quiet day later the fee is back at base
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 7200);
        assertEq(_swap(false, 0.01 ether), BASE_FEE);
    }

    function test_fork_reversalSurchargeSeesTheRouterAsSender() public onlyFork {
        vm.prank(owner);
        hook.setPoolConfig(
            id,
            VolatilityShieldHook.Config({
                baseFee: BASE_FEE,
                maxFee: MAX_FEE,
                mevSurcharge: MEV_SURCHARGE,
                feePerTick: 0,
                alphaBps: 2000,
                samplePeriod: 60,
                revertOnSuspectedMEV: false
            })
        );

        _swap(true, 1000e6);
        assertEq(_swap(false, 0.1 ether), BASE_FEE + MEV_SURCHARGE, "same-block reversal");

        // whitelisting the Universal Router exempts swaps routed through it
        vm.prank(owner);
        hook.setWhitelist(address(ROUTER), true);
        assertEq(_swap(true, 1000e6), BASE_FEE);
    }

    // ------------------------------------------------------------------ helpers

    function _approve(address token) internal {
        // USDT-style tokens are not used here, so a plain approve is fine
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, address(POSM), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token, address(ROUTER), type(uint160).max, type(uint48).max);
    }

    /// @dev Mints a position through the deployed PositionManager.
    function _mintLiquidity(uint256 amount0, uint256 amount1) internal {
        int24 lower = START_TICK - 100 * TICK_SPACING;
        int24 upper = START_TICK + 100 * TICK_SPACING;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(START_TICK),
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0,
            amount1
        );

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        POSM.modifyLiquidities(abi.encode(actions, params), vm.getBlockTimestamp() + 60);
    }

    /// @dev Exact-input swap through the deployed Universal Router. Returns the fee from the
    ///      PoolManager's Swap event.
    function _swap(bool zeroForOne, uint128 amountIn) internal returns (uint24 fee) {
        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = zeroForOne ? key.currency1 : key.currency0;

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(currencyIn, uint256(amountIn));
        params[2] = abi.encode(currencyOut, uint256(0));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.recordLogs();
        ROUTER.execute(abi.encodePacked(uint8(V4_SWAP)), inputs, vm.getBlockTimestamp() + 60);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(MANAGER) && logs[i].topics[0] == IPoolManager.Swap.selector
                    && logs[i].topics[1] == PoolId.unwrap(id)
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(ROUTER), "swap sender is the router");
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }
}
