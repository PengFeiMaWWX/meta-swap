/**
 * @title Factory
 * @dev Factory 合约用于创建和管理流动性池。支持为同一对代币创建多个不同配置的池。
 * @notice 使用 CREATE2 进行确定性地址生成，确保池的地址可预测
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import './interfaces/IFactory.sol';
import './Pool.sol';

contract Factory is IFactory {
    // 存储池地址的嵌套映射：token0 => token1 => [pool1, pool2, ...]
    // 对于同一对代币，可以创建多个不同费用和价格范围的池
    mapping(address => mapping(address => address[])) public pools;

    // 临时存储池的参数，在 CREATE2 构造时由 Pool 读取
    // 使用临时存储的原因：CREATE2 constructor 不能接收参数
    Parameters public override parameters;

    /**
     * @dev 对代币地址进行排序，确保 token0 < token1
     * @notice 保证同一对代币的规范化顺序，便于统一管理和查询
     * @param token0 第一个代币地址
     * @param token1 第二个代币地址
     * @return 排序后的 token0 地址
     * @return 排序后的 token1 地址
     */
    function sortTokens(address token0, address token1) internal pure returns (address, address) {
        // 通过比较地址大小进行排序
        return token0 < token1 ? (token0, token1) : (token1, token0);
    }

    /**
     * @notice 根据代币对和索引获取对应的池地址
     * @dev 支持查询同一对代币下的多个不同配置的池
     * @param token0 第一个代币地址
     * @param token1 第二个代币地址
     * @param index 池的索引位置
     * @return pool 返回的池合约地址
     */
    function getPool(address token0, address token1, uint32 index) external view override returns (address pool) {
        // 检查两个代币地址是否相同
        require(token0 != token1, 'Identical addresses');
        // 检查代币地址是否为零地址
        require(token0 != address(0) && token1 != address(0), 'Zero address');
        // 对代币地址进行规范化排序
        (address token0_, address token1_) = sortTokens(token0, token1);
        // 返回指定索引的池地址
        return pools[token0_][token1_][index];
    }

    /**
     * @notice 创建或获取一个流动性池
     * @dev 如果相同配置的池已存在则返回现有池，否则创建新池
     * @param token0 第一个代币地址
     * @param token1 第二个代币地址
     * @param tickLower 池的下限 tick
     * @param tickUpper 池的上限 tick
     * @param fee 池的手续费率
     * @return pool 创建或返回的池合约地址
     */
    function createPool(
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) external override returns (address pool) {
        // 步骤1: 验证代币地址有效性
        require(token0 != token1, 'Identical addresses');

        // 步骤2: 对代币地址进行规范化排序，确保统一的查询顺序
        (address token0_, address token1_) = sortTokens(token0, token1);

        // 步骤3: 获取该代币对的所有池列表
        address[] storage tokenPools = pools[token0_][token1_];

        // 步骤4: 检查是否已存在相同配置的池，避免创建重复的池
        for (uint32 i = 0; i < tokenPools.length; i++) {
            IPool currentPool = IPool(tokenPools[i]);
            // 检查当前池是否具有相同的配置（tickLower、tickUpper、fee）
            if (
                currentPool.tickLower() == tickLower && currentPool.tickUpper() == tickUpper && currentPool.fee() == fee
            ) {
                // 如果池已存在，直接返回现有池地址
                return address(currentPool);
            }
        }

        // 步骤5: 为新池准备初始化参数
        // 由于 CREATE2 构造函数不支持参数，通过临时存储来传递参数
        parameters = Parameters({
            factory: address(this),
            token0: token0_,
            token1: token1_,
            tickLower: tickLower,
            tickUpper: tickUpper,
            fee: fee
        });

        // 步骤6: 计算确定性 salt，确保相同配置的池地址可预测
        // salt = keccak256(token0, token1, tickLower, tickUpper, fee)
        bytes32 salt = keccak256(abi.encode(token0_, token1_, tickLower, tickUpper, fee));

        // 步骤7: 使用 CREATE2 和 salt 创建新池
        // Pool 的 constructor 会从 parameters 中读取配置参数
        pool = address(new Pool{salt: salt}());

        // 步骤8: 将新创建的池地址添加到池列表中
        pools[token0_][token1_].push(pool);

        // 步骤9: 清空临时存储的参数，节省 gas
        delete parameters;

        // 步骤10: 发出池创建事件
        emit PoolCreated(token0_, token1_, uint32(tokenPools.length - 1), tickLower, tickUpper, fee, pool);
    }
}
