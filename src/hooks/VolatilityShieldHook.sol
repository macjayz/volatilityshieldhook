// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title VolatilityShieldHook
/// @notice Uniswap V4 dynamic-fee hook. The LP fee of every swap is set in `beforeSwap` from an
///         exponentially weighted moving average (EWMA) of how far the pool's tick has been moving,
///         so LPs are paid more while the price is unstable. A swap that reverses the direction of
///         the previous swap inside the same block (the shape of a sandwich back-run) pays an extra
///         surcharge, or is rejected outright if the pool is configured that way.
/// @dev    `afterSwap` records how many ticks each swap moved the price; `beforeSwap` prices the next
///         swap on the decayed total. Moves are counted by distance travelled, not net change, so a
///         round trip inside one period raises the fee twice.
///         All fees are in Uniswap V4 LP-fee units: hundredths of a basis point ("pips"),
///         so 1_000_000 = 100% and 3000 = 0.30%.
///         Volatility is in ticks scaled by 1e18. One tick is roughly one basis point of price.
contract VolatilityShieldHook is BaseHook, Ownable2Step {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /// @notice Fee settings for one pool. Packs into a single storage slot.
    struct Config {
        /// @dev Fee charged when volatility is zero, in pips.
        uint24 baseFee;
        /// @dev Upper bound of the volatility-driven fee, in pips. Must be >= baseFee.
        uint24 maxFee;
        /// @dev Added on top of the volatility fee for a suspected same-block reversal, in pips.
        ///      Not limited by `maxFee`; `maxFee + mevSurcharge` must be <= 100%.
        uint24 mevSurcharge;
        /// @dev Pips of fee added per tick of EWMA volatility.
        uint32 feePerTick;
        /// @dev EWMA smoothing factor in basis points, 1..10_000. Each tick moved adds `alpha` ticks of
        ///      volatility, and volatility loses `alpha` of its value every `samplePeriod`.
        uint16 alphaBps;
        /// @dev Length of one EWMA period in seconds. Must be non-zero.
        uint32 samplePeriod;
        /// @dev Revert suspected same-block reversals instead of surcharging them.
        bool revertOnSuspectedMEV;
    }

    /// @notice Rolling state for one pool. Packs into a single storage slot.
    struct Observation {
        /// @dev Pool tick after the most recent swap.
        int24 tick;
        /// @dev Timestamp `ewma` is decayed up to. Advances in whole sample periods.
        uint40 decayedAt;
        /// @dev Block number of the most recent swap.
        uint48 lastSwapBlock;
        /// @dev Direction of the most recent swap.
        bool lastZeroForOne;
        /// @dev EWMA of absolute tick movement per sample period, in ticks * 1e18.
        uint128 ewma;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice Config copied to a pool when it is initialized, unless the owner configured it beforehand.
    Config public defaultConfig;

    mapping(PoolId => Config) public poolConfig;
    mapping(PoolId => Observation) public observations;

    /// @notice Addresses exempt from the same-block reversal check. Matched against both the swap
    ///         `sender` (the router that called the PoolManager) and `tx.origin` (the signing account),
    ///         so the owner can exempt a trusted router or a known market maker.
    mapping(address => bool) public whitelist;

    event DefaultConfigSet(Config config);
    event PoolConfigSet(PoolId indexed id, Config config);
    event WhitelistSet(address indexed account, bool allowed);
    event PoolRegistered(PoolId indexed id, int24 tick);

    error DynamicFeeRequired();
    error InvalidConfig();
    error SuspectedMEV();

    constructor(IPoolManager _poolManager, address _owner, Config memory _defaultConfig)
        BaseHook(_poolManager)
        Ownable(_owner)
    {
        _validate(_defaultConfig);
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet(_defaultConfig);
    }

    // ------------------------------------------------------------------ hook wiring

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Rejects static-fee pools (the fee override would be ignored) and records the starting tick.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert DynamicFeeRequired();

        PoolId id = key.toId();
        if (poolConfig[id].alphaBps == 0) poolConfig[id] = defaultConfig;
        observations[id] = Observation({
            tick: tick,
            decayedAt: uint40(block.timestamp),
            lastSwapBlock: 0,
            lastZeroForOne: false,
            ewma: 0
        });

        emit PoolRegistered(id, tick);
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Runs before every swap: prices it on the volatility recorded so far and returns the fee
    ///      with the override flag set. Reads only; state is written once per swap, in `_afterSwap`.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Config memory c = poolConfig[id];
        Observation memory o = observations[id];

        bool suspected = _isSuspectedReversal(o, params.zeroForOne, sender, tx.origin);
        if (suspected && c.revertOnSuspectedMEV) revert SuspectedMEV();

        (uint256 volatility,) = _decayed(o, c);
        uint24 fee = _fee(c, volatility, suspected);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Runs after every swap: adds the distance the swap moved the tick to the volatility estimate.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Config memory c = poolConfig[id];
        Observation memory o = observations[id];

        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 delta = int256(tick) - int256(o.tick);
        uint256 move = uint256(delta < 0 ? -delta : delta);

        (uint256 volatility, uint256 periods) = _decayed(o, c);
        volatility += move * c.alphaBps * (WAD / BPS);

        o.ewma = volatility > type(uint128).max ? type(uint128).max : uint128(volatility);
        o.tick = tick;
        o.decayedAt += uint40(periods * c.samplePeriod);
        o.lastSwapBlock = uint48(block.number);
        o.lastZeroForOne = params.zeroForOne;
        observations[id] = o;

        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------ views

    /// @notice Volatility the next swap would be priced on, in ticks * 1e18.
    function currentVolatility(PoolId id) public view returns (uint256 volatility) {
        (volatility,) = _decayed(observations[id], poolConfig[id]);
    }

    /// @notice Fee a swap would be charged if it executed now.
    /// @param id Pool to quote.
    /// @param zeroForOne Direction of the swap.
    /// @param sender Address that will call `PoolManager.swap` (normally the router).
    /// @param origin Account that will sign the transaction.
    /// @return fee LP fee in pips.
    /// @return suspected True if the swap counts as a same-block reversal. If the pool reverts those,
    ///         the swap would fail rather than pay `fee`.
    function previewFee(PoolId id, bool zeroForOne, address sender, address origin)
        external
        view
        returns (uint24 fee, bool suspected)
    {
        suspected = _isSuspectedReversal(observations[id], zeroForOne, sender, origin);
        fee = _fee(poolConfig[id], currentVolatility(id), suspected);
    }

    // ------------------------------------------------------------------ owner settings

    function setDefaultConfig(Config calldata config) external onlyOwner {
        _validate(config);
        defaultConfig = config;
        emit DefaultConfigSet(config);
    }

    /// @notice Sets the config of one pool. May be called before the pool is initialized.
    function setPoolConfig(PoolId id, Config calldata config) external onlyOwner {
        _validate(config);
        poolConfig[id] = config;
        emit PoolConfigSet(id, config);
    }

    function setWhitelist(address account, bool allowed) external onlyOwner {
        whitelist[account] = allowed;
        emit WhitelistSet(account, allowed);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Stored volatility with time decay applied: it keeps (1 - alpha) of its value for every
    ///      whole sample period since `decayedAt`. Swaps cannot dilute it; only time brings it down.
    function _decayed(Observation memory o, Config memory c)
        internal
        view
        returns (uint256 volatility, uint256 periods)
    {
        periods = (block.timestamp - o.decayedAt) / c.samplePeriod;
        volatility = periods == 0 ? o.ewma : uint256(o.ewma) * _powWad((BPS - c.alphaBps) * (WAD / BPS), periods) / WAD;
    }

    function _fee(Config memory c, uint256 volatility, bool suspected) internal pure returns (uint24) {
        uint256 fee = c.baseFee + volatility * c.feePerTick / WAD;
        if (fee > c.maxFee) fee = c.maxFee;
        if (suspected) fee += c.mevSurcharge;
        // maxFee + mevSurcharge <= MAX_LP_FEE is enforced by _validate
        return uint24(fee);
    }

    /// @dev A swap in the opposite direction to the previous swap of the same block. The check is on
    ///      the pool, not the trader, so splitting a sandwich across several addresses does not evade it.
    function _isSuspectedReversal(Observation memory o, bool zeroForOne, address sender, address origin)
        internal
        view
        returns (bool)
    {
        if (o.lastSwapBlock != block.number || o.lastZeroForOne == zeroForOne) return false;
        return !(whitelist[sender] || whitelist[origin]);
    }

    function _validate(Config memory c) internal pure {
        if (
            c.alphaBps == 0 || c.alphaBps > BPS || c.samplePeriod == 0 || c.baseFee > c.maxFee
                || uint256(c.maxFee) + c.mevSurcharge > LPFeeLibrary.MAX_LP_FEE
        ) revert InvalidConfig();
    }

    /// @dev x^n for a WAD-scaled x <= 1e18, by squaring.
    function _powWad(uint256 x, uint256 n) internal pure returns (uint256 result) {
        result = WAD;
        while (n != 0) {
            if (n & 1 != 0) result = result * x / WAD;
            x = x * x / WAD;
            n >>= 1;
        }
    }
}
