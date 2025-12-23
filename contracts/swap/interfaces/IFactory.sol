// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/**
 * @title IFactory
 * @author mapf
 * @notice 工厂合约接口，用于创建和管理特定参数配置的流动性池（Pool）
 * @dev 该接口定义了创建和查询流动性池的标准方法，支持通过多个参数唯一确定一个池子
 */
interface IFactory {
    
    /**
     * @notice 创建一个新的流动性池
     * @param factory 工厂合约地址
     * @param tokenA 代币A的合约地址
     * @param tokenB 代币B的合约地址
     * @param tickLower 流动性范围的下限
     * @param tickUpper 流动性范围的上限
     * @param fee 交易手续费率
     */
    struct Parameters {
        address factory;
        address tokenA;
        address tokenB;
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
    }

    /**
     * @notice 获取流动性池的参数
     * @return factory 
     * @return tokenA 
     * @return tokenB 
     * @return tickLower 
     * @return tickUpper 
     * @return fee 
     */
    function parameters() external view returns (
        address factory,
        address tokenA,
        address tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) ;

    /**
     * @notice 当新的流动性池被成功创建时触发
     * @param token0 排序后较小的代币地址
     * @param token1 排序后较大的代币地址 
     * @param index 新池子在对应代币对中的索引位置
     * @param tickLower 价格区间下限
     * @param tickUpper 价格区间上限
     * @param fee 费率
     * @param pool 新创建的流动性池地址
     */
    event PoolCreated(
        address  token0,
        address  token1,
        uint32 index,
        int24  tickLower,
        int24 tickUpper,
        uint24 fee,
        address pool
    );
    
    /**
     * @notice 根据两个代币地址和一个索引号查询已存在的资金池地址
     * @param tokenA 代币A地址
     * @param tokenB 代币B地址
     * @param index 索引号， 区分同一个代币对的不同池子
     * @return pool 返回对应的流动性池地址，若不存在则返回零地址 
     */
    function getPool (
        address tokenA,
        address tokenB,
        int32 index
    ) external view returns (address pool);

    /**
     * @notice 创建一个新的流动性池
     * @param tokenA 代币A地址
     * @param tokenB 代币B地址
     * @param tickLower 价格区间下线
     * @param tickUpper 价格区间上线
     * @param fee 费率
     * @return pool 返回新创建的流动性池地址 
     */
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) external returns (address pool);
}