// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
pragma abicoder v2;

import './interfaces/IPoolManager.sol';
import './interfaces/IPool.sol';
import './Factory.sol';

/**
 * @title PoolManager
 * @dev 管理多个 token 对及其对应的池（Pool），基于 `Factory` 实现池的创建与查询。
 *      PoolManager 继承自 Factory，因此可以直接调用 `createPool` 并访问 `pools` 映射。
 */
contract PoolManager is IPoolManager, Factory {
    // 所有已管理的 token 对列表，用于便捷枚举
    Pair[] public pairs;

    function getPairs() external view override returns (Pair[] memory) {
        /**
         * @notice 返回已记录的 token 对数组
         * @dev 直接返回存储的 `pairs`，便于前端或其他合约查询所有关注的代币对
         * @return 以数组形式返回全部 `Pair`
         */
        return pairs;
    }

    function getAllPools() external view override returns (PoolInfo[] memory) {
        /**
         * @notice 枚举所有已记录 token 对下的池，并返回详细信息数组
         * @dev 分两步：先计算结果数组的总长度，然后填充数据。返回的 PoolInfo 包含池的元数据便于前端展示。
         * @return poolInfos 包含所有池信息的数组
         */

        // 步骤1: 计算需要分配的返回数组长度（所有 pairs 下所有 pools 的总和）
        uint32 len = 0;
        for (uint32 i = 0; i < pairs.length; i++) {
            len += uint32(pools[pairs[i].token0][pairs[i].token1].length);
        }

        // 步骤2: 分配内存数组并逐一填充
        PoolInfo[] memory poolInfos = new PoolInfo[](len);
        uint256 index = 0;
        for (uint32 i = 0; i < pairs.length; i++) {
            // 获取当前 token 对对应的所有池地址列表
            address[] memory addressList = pools[pairs[i].token0][pairs[i].token1];
            // 步骤2.1: 遍历该列表并读取每个池的详细信息
            for (uint32 j = 0; j < addressList.length; j++) {
                IPool pool = IPool(addressList[j]);
                poolInfos[index] = PoolInfo({
                    token0: pairs[i].token0,
                    token1: pairs[i].token1,
                    pool: addressList[j],
                    fee: pool.fee(),
                    feeProtocol: 0,
                    tickLower: pool.tickLower(),
                    tickUpper: pool.tickUpper(),
                    tick: pool.tick(),
                    sqrtPriceX96: pool.sqrtPriceX96(),
                    liquidity: pool.liquidity(),
                    index: j
                });
                index++;
            }
        }

        // 步骤3: 返回填充好的数组
        return poolInfos;
    }

    /**
     * @notice 如果指定配置的池不存在则创建并（可选）初始化
     * @dev 要求 params.token0 < params.token1（调用方需预先排序），调用 Factory.createPool 创建或返回池。
     *      如果新创建的池尚未初始化（sqrtPriceX96 == 0），则对其进行初始化并在需要时将该 token 对加入 `pairs` 列表。
     * @param params 创建池所需的参数（包含 token0、token1、tickLower、tickUpper、fee、sqrtPriceX96）
     * @return _pool 创建或获取到的池地址
     */
    function createPoolIfNecessary(CreatePoolParams calldata params) external override returns (address _pool) {
        // 步骤1: 验证 token 顺序（这里要求调用方传入已排序的 token0 < token1）
        require(params.token0 < params.token1, 'Token0 must be less than token1');
        // 步骤2: 委托 Factory.createPool 来创建或获取具有相同配置的池
        _pool = this.createPool(params.token0, params.token1, params.tickLower, params.tickUpper, params.fee);
        IPool pool = IPool(_pool);
        // 步骤3: 读取该 token 对当前已有的池数量（用于判断是否首次创建）
        uint256 index = pools[pool.token0()][pool.token1()].length;
        // 步骤4: 如果池尚未初始化（未设置价格），则初始化并在首次创建时把 token 对加入 pairs
        if (pool.sqrtPriceX96() == 0) {
            pool.initialize(params.sqrtPriceX96);
            if (index == 1) {
                // 仅在该 token 对首次出现时将其记录到 pairs 列表，便于后续枚举
                pairs.push(Pair({token0: params.token0, token1: params.token1}));
            }
        }

        // 步骤5: 返回池地址
        return _pool;
    }
}
