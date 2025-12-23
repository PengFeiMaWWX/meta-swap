// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
pragma abicoder v2;

import './IFactory.sol';

interface IPoolManager is IFactory {
    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        uint32 index;
        uint24 fee;
        uint8 feeProtocol;
        int24 tickLower;
        int24 tickUpper;
        int24 tick;
        uint128 liquidity;
        uint160 sqrtPriceX96;
    }

    struct Pair {
        address token0;
        address token1;
    }

    function getPairs() external view returns (Pair[] memory);

    function getAllPools() external view returns (PoolInfo[] memory);

    struct CreatePoolParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        uint160 sqrtPriceX96;
    }

    function createPoolIfNecessary(CreatePoolParams calldata params) external returns (address pool);
}
