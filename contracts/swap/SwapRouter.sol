// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import './interfaces/ISwapRouter.sol';
import './interfaces/IPool.sol';
import './interfaces/IPoolManager.sol';

contract SwapRouter is ISwapRouter {
    IPoolManager public poolManager;

    constructor(address poolManager_) {
        /**
         * @notice 构造函数
         * @dev 关联一个 `PoolManager` 合约实例，用于查询池地址
         * @param poolManager_ PoolManager 合约地址
         */
        poolManager = IPoolManager(poolManager_);
    }

    function parseRevertReason(bytes memory data) private pure returns (int256, int256) {
        /**
         * @notice 从捕获的 revert 返回数据中解析出 revert 原因或返回的两个 int256
         * @dev 如果返回的数据不是两个 int256（64 字节），则尝试解析为 Error(string)，并 revert 出具体消息
         * @param data 捕获到的 revert 字节数据
         * @return 两个 int256 值（如果解析成功）
         */
        if (data.length != 64) {
            // data 可能是 Error(string) 编码：function selector(4 bytes) + abi.encode(string)
            if (data.length < 68) revert('SwapRouter: unknown reason');
            assembly {
                // 跳过 selector（4 bytes）以解码 string
                data := add(data, 0x04)
            }
            revert(abi.decode(data, (string)));
        }
        // 如果恰好匹配两个 int256 的长度，则直接解码并返回
        return abi.decode(data, (int256, int256));
    }

    function swapInPool(
        IPool pool,
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory data
    ) external returns (int256 amount0, int256 amount1) {
        /**
         * @notice 在指定池中执行单步 swap，并捕获池合约的 revert 信息
         * @dev 通过 try/catch 捕获外部调用的 revert；若 pool.swap 返回 revert，解析出其中的 int256 返回值或 revert 原因
         * @param pool 目标池合约实例
         * @param recipient 兑换接收者地址
         * @param zeroForOne 方向标志：true 表示 token0 -> token1
         * @param amountSpecified 交换数量（正数为精确输入、负数为精确输出）
         * @param sqrtPriceLimitX96 价格限制
         * @param data 回调数据（由本路由自行构造）
         * @return amount0 本池视角的 token0 变化（可能为负）
         * @return amount1 本池视角的 token1 变化（可能为负）
         */
        try pool.swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data) returns (
            int256 _amount0,
            int256 _amount1
        ) {
            // 成功返回直接转发
            return (_amount0, _amount1);
        } catch (bytes memory reason) {
            // 捕获 revert 数据并尝试解析为 (int256,int256) 或 Error(string)
            return parseRevertReason(reason);
        }
    }

    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        /**
         * @notice 按顺序对路径上的每个池进行精确输入的交换，返回最终输出数量
         * @dev 主要步骤：
         *      1. 以 params.amountIn 作为初始输入量，从第一池开始依次调用 swap，直至用尽或遍历完路径
         *      2. 每步调用后更新剩余输入和累计输出
         *      3. 最终校验输出是否满足最低要求并触发事件
         */

        // 步骤1: 初始化剩余输入和方向（token 地址大小决定方向）
        uint256 amountIn = params.amountIn;
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 步骤2: 遍历索引路径，对每个池执行单步 swap
        for (uint256 i = 0; i < params.indexPath.length; i++) {
            // 获取当前池地址并校验存在性
            address poolAddress = poolManager.getPool(params.tokenIn, params.tokenOut, params.indexPath[i]);
            require(poolAddress != address(0), 'SwapRouter: pool not found');
            IPool pool = IPool(poolAddress);

            // 构造回调数据：路由会在回调时要求 payer（通常是 msg.sender）支付代币
            bytes memory data = abi.encode(
                params.tokenIn,
                params.tokenOut,
                params.indexPath[i],
                params.recipient == address(0) ? address(0) : msg.sender
            );

            // 在池中执行 swap（精确输入），将剩余输入作为本步的 amountSpecified
            (int256 amount0, int256 amount1) = this.swapInPool(
                pool,
                params.recipient,
                zeroForOne,
                int256(amountIn),
                params.sqrtPriceLimitX96,
                data
            );

            // 步骤2.1: 更新剩余输入和累计输出
            amountIn -= uint256(zeroForOne ? amount0 : amount1);
            amountOut += uint256(zeroForOne ? -amount1 : -amount0);

            // 如果输入已耗尽，提前结束
            if (amountIn == 0) {
                break;
            }
        }

        // 步骤3: 校验输出下限并发事件
        require(amountOut >= params.amountOutMinimum, 'SwapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        emit Swap(msg.sender, zeroForOne, params.amountIn, amountIn, amountOut);
        return amountOut;
    }

    function exactOutput(ExactOutputParams calldata params) external payable override returns (uint256 amountIn) {
        /**
         * @notice 以精确输出（specified output）为目标，反向在路径上执行 swap，返回所需的最大输入量
         * @dev 主要步骤：
         *      1. 从目标输出量开始，逐池调用 swap（传入负的 amountSpecified 表示精确输出）
         *      2. 每步更新剩余目标输出和累计输入
         *      3. 最终校验输入不超过最大允许值并触发事件
         */

        // 步骤1: 初始化剩余输出与方向
        uint256 amountOut = params.amountOut;
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 步骤2: 遍历路径，按需逐步消耗剩余输出
        for (uint256 i = 0; i < params.indexPath.length; i++) {
            address poolAddress = poolManager.getPool(params.tokenIn, params.tokenOut, params.indexPath[i]);
            require(poolAddress != address(0), 'pool not found');

            IPool pool = IPool(poolAddress);
            bytes memory data = abi.encode(
                params.tokenIn,
                params.tokenOut,
                params.indexPath[i],
                params.recipient == address(0) ? address(0) : msg.sender
            );

            // 使用负数表示精确输出的请求
            (int256 amount0, int256 amount1) = this.swapInPool(
                pool,
                params.recipient,
                zeroForOne,
                -int256(amountOut),
                params.sqrtPriceLimitX96,
                data
            );

            // 步骤2.1: 更新剩余输出和累计输入
            amountOut -= uint256(zeroForOne ? -amount1 : -amount0);
            amountIn += uint256(zeroForOne ? amount0 : amount1);

            // 如果目标输出已满足，提前结束
            if (amountOut == 0) {
                break;
            }
        }

        // 步骤3: 校验输入上限并发事件
        require(amountIn <= params.amountInMaximum, 'Slippage exceeded');
        emit Swap(msg.sender, zeroForOne, params.amountOut, amountOut, amountIn);
        return amountIn;
    }

    function quoteExactInput(QuoteExactInputParams calldata params) external override returns (uint256 amountOut) {
        /**
         * @notice 基于当前池状态估算精确输入时的输出量（只做模拟，不进行实际转账）
         * @dev 直接调用 `exactInput`，但将 `recipient` 设为 `address(0)` 且 `amountOutMinimum` 为 0 以只返回估算值
         */
        return
            this.exactInput(
                ExactInputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    indexPath: params.indexPath,
                    recipient: address(0),
                    deadline: block.timestamp + 1 hours,
                    amountIn: params.amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );
    }

    function quoteExactOutput(QuoteExactOutputParams calldata params) external override returns (uint256 amountIn) {
        /**
         * @notice 基于当前池状态估算达到指定输出量所需的输入（模拟调用）
         * @dev 通过调用 `exactOutput` 并将 `recipient` 设为 `address(0)` 来避免实际转账，返回估算的输入量
         */
        return
            this.exactOutput(
                ExactOutputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    indexPath: params.indexPath,
                    recipient: address(0),
                    deadline: block.timestamp + 1 hours,
                    amountOut: params.amountOut,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );
    }

    function swapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        /**
         * @notice swap 回调：当 Pool 执行 swap 时会回调本函数，路由负责从 payer 向 pool 转移所需支付的代币
         * @dev 回调数据包含 tokenIn、tokenOut、pool index 和 payer 地址；若 payer 为 0，则将 revert 原因编码并回退
         * @param amount0Delta Pool 要求本次 swap 中 token0 的增量（正表示需要入账到池）
         * @param amount1Delta Pool 要求本次 swap 中 token1 的增量（正表示需要入账到池）
         * @param data 回调数据（由路由在发起 swap 时编码）
         */
        // 步骤1: 解码回调数据并验证调用者为 pool
        (address tokenIn, address tokenOut, uint32 index, address payer) = abi.decode(
            data,
            (address, address, uint32, address)
        );
        address _pool = poolManager.getPool(tokenIn, tokenOut, index);
        require(_pool == msg.sender, 'SwapRouter: unauthorized callback');

        // 步骤2: 计算需支付的数量（取正数部分）
        uint256 amountToPay = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);

        // 步骤3: 如果 payer 为 address(0)，则将 amountDeltas 作为返回值，通过 revert 将二进制数据返回给调用者
        if (payer == address(0)) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amount0Delta)
                mstore(add(ptr, 0x20), amount1Delta)
                revert(ptr, 64)
            }
        }

        // 步骤4: 否则从 payer 向 pool 转移所需代币
        if (amountToPay > 0) {
            IERC20(tokenIn).transferFrom(payer, _pool, amountToPay);
        }
    }
}
