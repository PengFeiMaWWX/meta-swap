/**
 * @title Pool
 * @dev 这是一个抽象合约，实现了IPool接口，代表一个Uniswap V3风格的流动性池。
 * 该合约定义了流动性池的基本属性和状态变量。
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// 导入OpenZeppelin的ERC20接口
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
// 导入Uniswap V3核心合约中的安全转换库
import '@uniswap/v3-core/contracts/libraries/SafeCast.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
import '@uniswap/v3-core/contracts/libraries/SwapMath.sol';
import '@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol';
import '@uniswap/v3-core/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '../lib/LiquidityMath.sol';
// 导入自定义的IPool接口
import './interfaces/IPool.sol';
// 导入自定义的IFactory接口
import './interfaces/IFactory.sol';

// test
import 'hardhat/console.sol';

contract Pool is IPool {
    // 使用SafeCast库进行uint256类型的安全转换
    using SafeCast for uint256;

    // 工厂合约地址，不可变
    address public immutable override factory;

    // 池中的第一种代币地址，不可变
    address public immutable override token0;

    // 池中的第二种代币地址，不可变
    address public immutable override token1;

    // 交易手续费率，不可变
    uint24 public immutable override fee;

    // 池价格范围的下限tick，不可变
    int24 public immutable override tickLower;

    // 池价格范围的上限tick，不可变
    int24 public immutable override tickUpper;

    // 当前的价格（使用sqrtPriceX96格式）
    uint160 public override sqrtPriceX96;

    // 当前的tick
    int24 public override tick;

    // 当前的流动性数量
    uint128 public override liquidity;

    // 全局手续费增长0（以128位小数表示）
    uint256 public override feeGrowthGlobal0X128;

    // 全局手续费增长1（以128位小数表示）
    uint256 public override feeGrowthGlobal1X128;

    /**
     * @title Position
     * @notice 表示流动性提供者在某个价格区间内的头寸信息
     * @dev 包含流动性数量、应计代币和费用增长等关键数据
     */
    struct Position {
        uint128 liquidity; // 流动性数量，表示提供流动性的价值
        uint128 tokensOwed0; // 可提取的token0数量
        uint128 tokensOwed1; // 可提取的token1数量
        uint256 feeGrowthInside0LastX128; // token0在费用增长内部最后的乘积值，使用128位小数表示
        uint256 feeGrowthInside1LastX128; // token1在费用增长内部最后的乘积值，使用128位小数表示
    }

    // 保存每个提供者的头寸信息
    mapping(address => Position) public positions;

    /**
     * @notice 获取指定地址的头寸信息
     * @dev 返回头寸的流动性、手续费增长和应计代币
     * @param owner 头寸所有者地址
     * @return _liquidity 头寸中的流动性数量
     * @return feeGrowthInside0LastX128 token0手续费增长最后快照
     * @return feeGrowthInside1LastX128 token1手续费增长最后快照
     * @return tokensOwed0 可提取的token0数量
     * @return tokensOwed1 可提取的token1数量
     */
    function getPosition(
        address owner
    )
        external
        view
        override
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position storage _position = positions[owner];
        return (
            _position.liquidity,
            _position.feeGrowthInside0LastX128,
            _position.feeGrowthInside1LastX128,
            _position.tokensOwed0,
            _position.tokensOwed1
        );
    }

    /**
     * @dev 构造函数初始化不可变的池参数
     * @notice 从Factory合约读取初始化参数。Factory使用CREATE2创建Pool时指定salt，
     *         这样使得外部可以通过推导计算出Pool的地址。
     *         constructor不能带参数，否则无法通过 new Pool{salt:salt}() 的方式创建
     */
    constructor() {
        // 从Factory合约的参数中读取池的配置信息
        (factory, token0, token1, tickLower, tickUpper, fee) = IFactory(msg.sender).parameters();
    }

    /**
     * @dev 初始化流动性池，设置初始价格
     * @param _sqrtPriceX96 初始价格的平方根，乘以2^96的定点数表示
     */
    function initialize(uint160 _sqrtPriceX96) external override {
        // 检查池是否已经初始化
        require(sqrtPriceX96 == 0, 'Pool: already initialized');
        // 计算初始tick值
        tick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);
        // 确保初始tick在有效范围内
        require(tick >= tickLower && tick < tickUpper, 'Pool: initial tick out of range');
        // 设置池的当前价格
        sqrtPriceX96 = _sqrtPriceX96;
    }

    /**
     * @dev 修改持仓参数的结构体
     * @param owner 持仓所有者地址
     * @param liquidityDelta 流动性变化量，正数表示增加，负数表示减少
     */
    struct ModifyPositionParams {
        address owner;
        int128 liquidityDelta;
    }

    /**
     * @dev 修改持仓，计算流动性变化对应的代币数量变化，并更新手续费
     * @param params 包含持仓所有者和流动性变化量的参数
     * @return amount0 token0的变化数量
     * @return amount1 token1的变化数量
     */
    function _modifyPosition(ModifyPositionParams memory params) private returns (int256 amount0, int256 amount1) {
        // 步骤1: 计算流动性变化对应的 token0 数量变化
        // amount0 = Δtoken0，基于当前价格 sqrtPriceX96 到 tickUpper 的价格区间
        // 注意：liquidityDelta 可为负（burn时），需要用其绝对值计算delta，符号通过 < 0 参数传递
        amount0 = int256(
            SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tickUpper),
                params.liquidityDelta < 0 ? uint128(-params.liquidityDelta) : uint128(params.liquidityDelta),
                params.liquidityDelta < 0
            )
        );

        // 步骤2: 计算流动性变化对应的 token1 数量变化
        // amount1 = Δtoken1，基于 tickLower 到当前价格 sqrtPriceX96 的价格区间
        // 注意：当 liquidityDelta < 0 时（burn），getAmount1Delta 的第4个参数应为 true
        amount1 = int256(
            SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                sqrtPriceX96,
                params.liquidityDelta < 0 ? uint128(-params.liquidityDelta) : uint128(params.liquidityDelta),
                params.liquidityDelta < 0
            )
        );

        // 步骤3: 获取并更新持仓费率快照，结算应计费用
        Position storage position = positions[params.owner];

        // 计算自上次快照以来应分配给该持仓的 fee（token0）
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        // 计算自上次快照以来应分配给该持仓的 fee（token1）
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        // 步骤4: 更新持仓的手续费增长快照至全局最新值
        position.feeGrowthInside0LastX128 = feeGrowthGlobal0X128;
        position.feeGrowthInside1LastX128 = feeGrowthGlobal1X128;

        // 步骤5: 将结算得到的应计手续费累加到持仓可提取余额中
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            position.tokensOwed0 += tokensOwed0;
            position.tokensOwed1 += tokensOwed1;
        }

        // 步骤6: 更新全局流动性与持仓流动性
        liquidity = LiquidityMath.addDelta(liquidity, params.liquidityDelta);
        position.liquidity = LiquidityMath.addDelta(position.liquidity, params.liquidityDelta);

        // 当流动性减少时（burn），返回值应为负数，所以需要乘以 -1
        if (params.liquidityDelta < 0) {
            amount0 = -amount0;
            amount1 = -amount1;
        }

        // 返回由于流动性变更而需增减的 token0、token1 数量
        return (amount0, amount1);
    }

    /**
     * @dev 获取合约在token0中的余额
     * @notice 使用staticcall进行安全的外部调用，避免状态变化
     * @return 合约在token0中的余额
     */
    function balance0() private view returns (uint256) {
        // 调用token0的balanceOf函数获取当前合约的余额
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        // 检查调用是否成功且返回数据长度正确
        require(success && data.length >= 32, 'Pool: token0 balance query failed');
        // 解码返回的余额数据
        return abi.decode(data, (uint256));
    }

    /**
     * @dev 获取合约在token1中的余额
     * @notice 使用staticcall进行安全的外部调用，避免状态变化
     * @return 合约在token1中的余额
     */
    function balance1() private view returns (uint256) {
        // 调用token1的balanceOf函数获取当前合约的余额
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        // 检查调用是否成功且返回数据长度正确
        require(success && data.length >= 32, 'Pool: token1 balance query failed');
        // 解码返回的余额数据
        return abi.decode(data, (uint256));
    }

    /**
     * @notice 向流动性池中添加流动性
     * @dev 调用者需实现 IMintCallback 回调以转入所需的 token0 和 token1
     * @param recipient 流动性接收者地址
     * @param amount 添加的流动性数量
     * @param data 回调参数
     * @return amount0 实际需要的 token0 数量
     * @return amount1 实际需要的 token1 数量
     */
    function mint(
        address recipient,
        uint128 amount,
        bytes calldata data
    ) external override returns (uint256 amount0, uint256 amount1) {
        // 验证输入：流动性必须大于 0
        require(amount > 0, 'Pool: amount must be greater than zero');

        // 步骤1: 调整持仓并计算需要的 token0 与 token1 数量
        // _modifyPosition 会根据当前价格和 tick 范围计算出 amount0 和 amount1（可为负）
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({owner: recipient, liquidityDelta: int128(amount)})
        );

        // 步骤2: 将内部有符号的变化量转换为无符号以便后续比较/转账
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 步骤3: 快照池中 token 余额，用于在回调后校验实际转入的数量
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) {
            balance0Before = balance0();
        }
        if (amount1 > 0) {
            balance1Before = balance1();
        }

        // 步骤4: 触发回调，要求调用者（通常是路由或用户）实际转入所需的代币
        IMintCallback(msg.sender).mintCallback(amount0, amount1, data);

        // 步骤5: 回调后校验实际转账数量是否满足要求，防止回调方少转或作恶
        if (amount0 > 0) {
            require(balance0() >= balance0Before + amount0, 'Pool: insufficient token0 amount');
        }
        if (amount1 > 0) {
            require(balance1() >= balance1Before + amount1, 'Pool: insufficient token1 amount');
        }

        // 步骤6: 发出 Mint 事件
        emit Mint(msg.sender, recipient, amount, amount0, amount1);
    }

    /**
     * @notice 从池中领取应计的 token0 和 token1
     * @dev 领取的数量不会超过当前应计的最大值
     * @param recipient 领取代币的接收地址
     * @param amount0Requested 请求领取的 token0 数量
     * @param amount1Requested 请求领取的 token1 数量
     * @return amount0 实际领取的 token0 数量
     * @return amount1 实际领取的 token1 数量
     */
    function collect(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override returns (uint128 amount0, uint128 amount1) {
        // 步骤1: 获取调用者的持仓信息
        Position storage position = positions[msg.sender];

        // 步骤2: 计算实际可领取的数量（不能超过应计的 tokensOwed）
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // 步骤3: 扣减持仓中可领取的余额并进行转账
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        // 步骤4: 发出 Collect 事件
        emit Collect(msg.sender, recipient, amount0, amount1);
    }

    /**
     * @notice 从池中移除流动性
     * @dev 移除的流动性会结算应计的 token0 和 token1
     * @param amount 要移除的流动性数量
     * @return amount0 结算得到的 token0 数量
     * @return amount1 结算得到的 token1 数量
     */
    function burn(uint128 amount) external override returns (uint256 amount0, uint256 amount1) {
        // 验证输入
        require(amount > 0, 'Pool: amount must be greater than zero');
        require(positions[msg.sender].liquidity >= amount, 'Pool: insufficient liquidity to burn');

        // 步骤1: 调整持仓以移除流动性，_modifyPosition 返回移除对应的 token 变化（有符号）
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({owner: msg.sender, liquidityDelta: -int128(amount)})
        );

        // 步骤2: 将返回的有符号变化转换为无符号的归还数量
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        // 步骤3: 将归还金额累加到持仓的 tokensOwed 中，等待持仓所有者调用 collect 提取
        if (amount0 > 0 || amount1 > 0) {
            (positions[msg.sender].tokensOwed0, positions[msg.sender].tokensOwed1) = (
                positions[msg.sender].tokensOwed0 + uint128(amount0),
                positions[msg.sender].tokensOwed1 + uint128(amount1)
            );
        }

        // 步骤4: 发出 Burn 事件
        emit Burn(msg.sender, amount, amount0, amount1);
    }

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        uint256 feeGrowthGlobalX128;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /**
     * @notice 在池中进行代币兑换
     * @dev 支持精确输入或精确输出的兑换，调用者需实现 ISwapCallback 回调
     * @param recipient 兑换得到代币的接收地址
     * @param zeroForOne true 表示 token0 换 token1，false 表示 token1 换 token0
     * @param amountSpecified 兑换的数量（正数为输入，负数为输出）
     * @param sqrtPriceLimitX96 价格限制（防止滑点过大）
     * @param data 回调参数
     * @return amount0 兑换涉及的 token0 数量
     * @return amount1 兑换涉及的 token1 数量
     */
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        // 输入校验：amountSpecified 必须非 0，并且 sqrtPriceLimitX96 在合法范围内
        require(amountSpecified != 0, 'Pool: amount must be greater than zero');
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'Pool: invalid sqrtPriceLimitX96'
        );

        // 步骤1: 判断是精确输入（exactInput）还是精确输出
        bool exactInput = amountSpecified > 0;

        // 步骤2: 初始化交换状态（工作内存），包含剩余需要处理的数量、累积的结果、价格、手续费累积等
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            amountIn: 0,
            amountOut: 0,
            feeAmount: 0
        });

        // 步骤3: 计算池的价格边界与本次 swap 的目标最小/最大价格
        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
        uint160 sqrtPriceX96PoolLimit = zeroForOne ? sqrtPriceX96Lower : sqrtPriceX96Upper;

        // 步骤4: 以单步计算（可能循环实现）为单位，计算此次交换的价格/数量变化
        // 注意：SwapMath.computeSwapStep 会计算出单步变化并返回给调用方（此处调用方式需与库签名匹配）
        (state.sqrtPriceX96, state.amountIn, state.amountOut, state.feeAmount) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            (zeroForOne ? sqrtPriceX96PoolLimit < sqrtPriceLimitX96 : sqrtPriceX96PoolLimit > sqrtPriceLimitX96)
                ? sqrtPriceLimitX96
                : sqrtPriceX96PoolLimit,
            liquidity,
            amountSpecified,
            fee
        );

        // 步骤5: 使用计算得到的新价格更新池的价格与 tick
        sqrtPriceX96 = state.sqrtPriceX96;
        tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);

        // 步骤6: 更新手续费全局累积量
        state.feeGrowthGlobalX128 += FullMath.mulDiv(state.feeAmount, FixedPoint128.Q128, liquidity);

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        // 步骤7: 根据是精确输入或精确输出调整剩余数量和计算值
        if (exactInput) {
            state.amountSpecifiedRemaining -= (state.amountIn + state.feeAmount).toInt256();
            state.amountCalculated = state.amountCalculated - state.amountOut.toInt256();
        } else {
            state.amountSpecifiedRemaining += state.amountOut.toInt256();
            state.amountCalculated = state.amountCalculated + state.amountIn.toInt256();
        }

        // 步骤8: 组合最终返回值：amount0, amount1（表示本次 swap 中输入/输出的量）
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // 步骤9: 触发 swap 回调并验证回调方已转入或池已转出正确数量
        if (zeroForOne) {
            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance0Before + (uint256(amount0)) <= balance0(), 'Pool: insufficient token0 amount');
            // 如果本次 swap 需要向接收方转出 token1（amount1 < 0），则执行转出
            if (amount1 < 0) {
                TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));
            }
        } else {
            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance1Before + uint256(amount1) <= balance1(), 'Pool: insufficient token1 amount');
            if (amount0 < 0) {
                TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));
            }
        }

        // 步骤10: 发出 Swap 事件以记录本次交易的结果
        emit Swap(msg.sender, recipient, amount0, amount1, sqrtPriceX96, liquidity, tick);
    }
}
