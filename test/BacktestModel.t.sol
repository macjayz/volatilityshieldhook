// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VolatilityShieldHook} from "../src/hooks/VolatilityShieldHook.sol";

/// @dev Stands in for the PoolManager: it reports whatever tick the test sets, in slot0's layout,
///      and is the address allowed to call the hook. This lets the test put the pool at the exact
///      tick history recorded after each real swap.
contract TickFeed {
    int24 public tick;

    function setTick(int24 newTick) external {
        tick = newTick;
    }

    /// @dev slot0 = lpFee (24) | protocolFee (24) | tick (24) | sqrtPriceX96 (160)
    function extsload(bytes32) external view returns (bytes32) {
        return bytes32((uint256(uint24(tick)) << 160) | 1);
    }
}

/// @dev Differential test for the backtest. `test/fixtures/backtest_sample.json` holds 2,000
///      consecutive real swaps of the mainnet V4 ETH/USDC pool (block, timestamp, direction, tick
///      after the swap) and the fee `backtest/model.py` computed for each one. This replays the same
///      swaps through the contract and requires every fee to match, for three different configs:
///      the shipped defaults, the original steeper defaults (which reach the cap and use the
///      reversal surcharge), and an unrelated one.
///      CI separately re-runs the Python model over the fixture, so model == fixture == contract.
contract BacktestModelTest is Test {
    uint160 constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    string json;

    function setUp() public {
        json = vm.readFile("test/fixtures/backtest_sample.json");
    }

    function test_contractMatchesModel_calibratedConfig() public {
        _replay(".calibrated", 1);
    }

    function test_contractMatchesModel_steepConfig() public {
        _replay(".steep", 2);
    }

    function test_contractMatchesModel_alternateConfig() public {
        _replay(".alternate", 3);
    }

    function _replay(string memory name, uint160 salt) internal {
        uint256[] memory raw = vm.parseJsonUintArray(json, string.concat(name, ".config"));
        VolatilityShieldHook.Config memory config = VolatilityShieldHook.Config({
            baseFee: uint24(raw[0]),
            maxFee: uint24(raw[1]),
            mevSurcharge: uint24(raw[2]),
            feePerTick: uint32(raw[3]),
            alphaBps: uint16(raw[4]),
            samplePeriod: uint32(raw[5]),
            revertOnSuspectedMEV: false
        });

        uint256[] memory expected = vm.parseJsonUintArray(json, string.concat(name, ".fees"));
        uint256[] memory blocks = vm.parseJsonUintArray(json, ".blocks");
        uint256[] memory timestamps = vm.parseJsonUintArray(json, ".timestamps");
        bool[] memory zeroForOne = vm.parseJsonBoolArray(json, ".zeroForOne");
        int256[] memory ticks = vm.parseJsonIntArray(json, ".ticks");
        assertEq(expected.length, 2000);
        assertEq(blocks.length, expected.length);
        assertEq(timestamps.length, expected.length);
        assertEq(zeroForOne.length, expected.length);
        assertEq(ticks.length, expected.length);

        TickFeed feed = new TickFeed();
        address at = address(FLAGS | (salt << 144));
        deployCodeTo("VolatilityShieldHook.sol:VolatilityShieldHook", abi.encode(feed, address(this), config), at);
        VolatilityShieldHook hook = VolatilityShieldHook(at);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(at)
        });

        int24 seedTick = int24(vm.parseJsonInt(json, ".seedTick"));
        vm.warp(vm.parseJsonUint(json, ".seedTimestamp"));
        feed.setTick(seedTick);
        vm.prank(address(feed));
        hook.afterInitialize(address(this), key, 0, seedTick);

        uint256 distinct;
        uint256 flagged;
        uint256 previous;
        for (uint256 i; i < expected.length; ++i) {
            vm.warp(timestamps[i]);
            vm.roll(blocks[i]);
            SwapParams memory params =
                SwapParams({zeroForOne: zeroForOne[i], amountSpecified: -1, sqrtPriceLimitX96: 0});

            vm.prank(address(feed));
            (,, uint24 fee) = hook.beforeSwap(address(this), key, params, "");
            fee &= ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
            if (fee != expected[i]) {
                emit log_named_uint("first mismatch at swap", i);
                assertEq(fee, expected[i], "contract fee != model fee");
            }
            if (fee != previous) distinct++;
            if (fee > config.maxFee) flagged++;
            previous = fee;

            feed.setTick(int24(ticks[i]));
            vm.prank(address(feed));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        }

        // the sample must actually exercise the fee logic, not sit at the base fee
        assertGt(distinct, 100, "fees should vary across the sample");
        if (config.mevSurcharge != 0) assertGt(flagged, 0, "sample should contain same-block reversals");
    }
}
