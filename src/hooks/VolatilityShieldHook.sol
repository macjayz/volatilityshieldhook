// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

pragma abicoder v2;

contract VolatilityShieldHook is Ownable {
    using PoolIdLibrary for PoolKey;

    struct Config {
        uint24 baseFee;
        uint24 minFee;
        uint24 maxFee;
        uint16 alphaBps;
        uint32 minSampleGap;
        uint256 k;
        uint24 mevSurchargeBps;
        bool   revertOnSuspectedMEV;
    }

    struct Obs {
        int24  tick;
        uint32 t;
        uint256 ewma;
        bool   init;
        uint32 lastBlock;
        bool   lastZeroForOne;
    }

    IPoolManager public immutable poolManager;
    mapping(PoolId => Config) public cfg;
    mapping(PoolId => Obs)    public obs;
    mapping(address => bool)  public whitelist;

    constructor(IPoolManager _pm) Ownable(msg.sender) {
        poolManager = _pm;
    }

    function seedObservation(PoolKey calldata key, int24 tick) external onlyOwner {
        PoolId id = key.toId();
        obs[id] = Obs({ tick: tick, t: uint32(block.timestamp), ewma: 0, init: true, lastBlock: 0, lastZeroForOne: false });
    }

    function getBaseFee(PoolKey calldata key) public view returns (uint24) {
        PoolId id = key.toId();
        Config memory c = cfg[id];
        Obs memory o = obs[id];
        uint256 addOn = (c.k * o.ewma) / 1e18;
        uint256 fee = uint256(c.baseFee) + addOn;
        if (fee < c.minFee) fee = c.minFee;
        if (fee > c.maxFee) fee = c.maxFee;
        return uint24(fee);
    }

    function getEffectiveFee(PoolKey calldata key, address sender, IPoolManager.SwapParams calldata params) public view returns (uint24) {
        uint24 base = getBaseFee(key);
        Obs memory o = obs[key.toId()];
        uint24 surcharge = 0;
        if (o.lastBlock == block.number && o.lastZeroForOne != params.zeroForOne && !whitelist[sender]) {
            surcharge = cfg[key.toId()].mevSurchargeBps;
        }
        unchecked {
            uint256 tot = uint256(base) + uint256(surcharge);
            if (tot > cfg[key.toId()].maxFee) tot = cfg[key.toId()].maxFee;
            return uint24(tot);
        }
    }

    function onAfterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta /*delta*/,
        bytes calldata /*hookData*/
    ) external onlyOwner returns (uint24) {
        PoolId id = key.toId();
        Obs storage o = obs[id];
        require(o.init, "obs not seeded");

        uint24 mevSurcharge = 0;
        if (o.lastBlock == block.number && o.lastZeroForOne != params.zeroForOne && !whitelist[sender]) {
            mevSurcharge = cfg[id].mevSurchargeBps;
        }

        o.lastBlock = uint32(block.number);
        o.lastZeroForOne = params.zeroForOne;

        uint24 baseApplied = getBaseFee(key);
        unchecked {
            uint256 tmp = uint256(baseApplied) + uint256(mevSurcharge);
            if (tmp > cfg[id].maxFee) tmp = cfg[id].maxFee;
            return uint24(tmp);
        }
    }
}
