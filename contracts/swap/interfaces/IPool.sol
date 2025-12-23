// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/**
 * @title IMintCallback
 * @author mapf
 * @notice 代币铸造回调接口
 * @dev 当用户通过 `mint` 函数向池子添加流动性时，如果操作需要调用者转入代币，池子合约会调用此接口
 * @dev 调用者必须在回调中支付所需的代币数量，否则交易将失败
 * @dev amount0Owed 用户需要支付的代币0数量
 * @dev amount1Owed 用户需要支付的代币1数量
 * @dev data 传递给 `mint` 函数的任意数据，可以用于在回调中携带额外信息
 */
interface IMintCallback  {
    function mintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
    
}

/**
 * @title ISwapCallback
 * @author mapf
 * @notice 代币交换回调接口
 * @dev 当用户通过 `swap` 函数在池子中交换代币时，如果操作需要调用者转入代币，池子合约会调用此接口
 * @dev 调用者必须在回调中支付所需的代币数量，否则交易将失败
 * @dev amount0Delta 如果为正，表示调用者需要支付的代币0数量；如果为负，表示调用者将收到的代币0数量
 * @dev amount1Delta 如果为正，表示调用者需要支付的代币1数量；如果为负，表示调用者将收到的代币1数量
 * @dev data 传递给 `swap` 函数的任意数据，可以用于在回调中携带额外信息
 */
interface ISwapCallback {
    function swapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
} 

/**
 * @title IPool
 * @author mapf
 * @notice 资金池主接口
 */
interface IPool {

    // --- 池子的基本信息查询（视图函数）---

    // @notice 回创建此池子的工厂合约地址
    function factory() external view returns (address);

    // @notice 返回池中代币对中地址较小的代币（token0）地址
    function token0() external view returns (address);

    // @notice 返回池中代币对中地址较大的代币（token1）地址
    function token1() external view returns (address);

    // @notice 返回池子的手续费率,  以万分之几（bp）表示。例如，500 表示 0.05%（5bp）
    function fee() external view returns (uint24);

    // @notice 返回池子的价格区间下限
    function tickLower() external view returns (int24);

    // @notice 返回池子的价格区间上限
    function tickUpper() external view returns (int24);

    // @notice 返回当前的现货价格，以 Q64.96 格式的定点数表示
    function sqrtPriceX96() external view returns (uint160);

    // @notice 返回当前的价格刻度（tick）
    function tick() external view returns (int24);

    // @notice 返回池子的流动性
    function liquidity() external view returns (uint128);

    // ---------- 池子的初始化 ----------
    /**
     * @notice 初始化池子的价格
     * @param sqrtPriceX96 以 Q64.96 格式表示的初始价格平方根
     * @dev 只能在池子未初始化时调用此函数，且只能调用一次
     */
    function initialize(uint160 sqrtPriceX96) external;

    // ----------- 手续费追踪 -----------
    /**
     * @notice 返回代币0的全局手续费增长总量
     * @dev 这是一个 Q128.128 定点数，表示自池子创建以来，每单位流动性累计产生的 token0 手续费
     * @dev 此值可能会溢出 uint256，计算时需小心
     * @return 以 Q128.128 格式表示的手续费增长总量
     */
    function feeGrowthGlobal0X128() external view returns (uint128);

    /**
     * @notice 返回代币1的全局手续费增长总量
     * @dev 这是一个 Q128.128 定点数，表示自池子创建以来，每单位流动性累计产生的 token1 手续费
     * @dev 此值可能会溢出 uint256，计算时需小心
     * @return 以 Q128.128 格式表示的手续费增长总量
     */
    function feeGrowthGlobal1X128() external view returns (uint128);

    // ----------- 流动性头寸查询 -----------
    /**
     * @notice 查询指定所有者的流动性头寸信息
     * @param owner 头寸所有者地址
     * @return _liquidity 该头寸的流动性数量
     * @return feeGrowthInside0LastX128 上次计算手续费时，头寸内代币0的手续费增长值
     * @return feeGrowthInside1LastX128 上次计算手续费时，头寸内代币1的手续费增长值
     * @return tokensOwed0 该头寸应收但未提取的代币0数量
     * @return tokensOwed1 该头寸应收但未提取的代币1数量
     */
    function getPosition(
        address owner
    ) external view returns (
        uint128 _liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );

    // --- 流动性提供相关事件与函数 ---
    /**
     * @notice 当流动性被添加到池子时触发
     * @notice owner 头寸所有者地址
     * @notice amount 流动性数量
     * @notice data 附加数据，会传递给回调函数
     * @return amount0 实际存入的代币0数量
     * @return amount1 实际存入的代币1数量
     */
    event Mint(
        address sender,
        address indexed owner,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice 向池子添加流动性（铸造流动性凭证）
     * @dev 调用此函数会触发 `Mint` 事件，并可能调用调用者的 `mintCallback` 方法
     * @param recipient 接收流动性头寸所有权的地址
     * @param amount 期望添加的流动性数量
     * @param data 传递给 `mintCallback` 的任意数据
     * @return amount0 实际投入的 token0 数量
     * @return amount1 实际投入的 token1 数量
     */
    function mint(
        address recipient,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice 当用户从池子中领取手续费或移除流动性时返还的代币时触发
     * @param owner 头寸所有者地址
     * @param recipient 接收手续费的地址
     * @param amount0 提取的代币0数量
     * @param amount1 提取的代币1数量
     */
    event Collect(
        address indexed owner,
        address recipient,
        uint128 amount0,
        uint128 amount1
    );

    /**
     * @notice 领取累积的手续费或移除流动性后应得的代币
     * @param recipient 接收手续费的地址
     * @param amount0Requested 期望领取的代币0数量
     * @param amount1Requested 期望领取的代币1数量
     * @return amount0 实际领取的代币0数量
     * @return amount1 实际领取的代币1数量
     */
    function collect(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /**
     * @notice 当流动性被销毁（移除）时触发
     * @param owner 头寸所有者地址
     * @param amount 移除的流动性数量
     * @param amount0 移除流动性后应得的 token0 数量（此时尚未实际领取，需调用 `collect`）
     * @param amount1  移除流动性后应得的 token1 数量（此时尚未实际领取，需调用 `collect`）
     */
    event Burn(
        address indexed owner,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice 移除流动性（销毁流动性凭证）
     * @param amount 期望移除的流动性数量
     * @return amount0 移除流动性后应得的 token0 数量（此时尚未实际领取，需调用 `collect`）
     * @return amount1 移除流动性后应得的 token1 数量（此时尚未实际领取，需调用 `collect`）
     */
    function burn(
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice 当发生代币交换时触发
    /// @param sender 执行交换操作的地址
    /// @param recipient 接收交换产出代币的地址
    /// @param amount0 token0 的数量变化（正数表示流入池子，负数表示流出池子）
    /// @param amount1 token1 的数量变化（正数表示流入池子，负数表示流出池子）
    /// @param sqrtPriceX96 交换后的价格
    /// @param liquidity 交换后的流动性
    /// @param tick 交换后的 tick
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    /// @notice 执行代币交换
    /// @dev 会触发 `Swap` 事件，并可能调用调用者的 `swapCallback` 方法
    /// @param recipient 接收产出代币的地址
    /// @param zeroForOne 交换方向。true 表示用 token0 交换 token1，false 表示用 token1 交换 token0
    /// @param amountSpecified 输入代币的数量（正数）。如果为负数，则代表希望获得的输出代币数量（暂较少见）
    /// @param sqrtPriceLimitX96 价格限制。当价格达到此限制时，交换停止
    /// @param data 传递给 `swapCallback` 的任意数据
    /// @return amount0 token0 的数量变化（正数表示流入池子，负数表示流出池子）
    /// @return amount1 token1 的数量变化（正数表示流入池子，负数表示流出池子）
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
