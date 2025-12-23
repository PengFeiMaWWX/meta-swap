// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';

import '../lib/LiquidityAmounts.sol';
import './interfaces/IPositionManager.sol';
import './interfaces/IPool.sol';
import './interfaces/IPoolManager.sol';

// test
import 'hardhat/console.sol';

/**
 * @title PositionManager
 * @dev ERC721 代币化的头寸管理器：
 *      - 为每个流动性头寸铸造 NFT（Position token）并记录头寸信息。
 *      - 与 `Pool`、`PoolManager` 交互以创建/管理/结算头寸。
 */
contract PositionManager is IPositionManager, ERC721 {
    // Pool 管理合约，用于查询或创建池
    IPoolManager public poolManager;

    // 下一个可用的 position id（从 1 开始），使用 uint176 省 gas
    uint176 private _nextId = 1;

    /**
     * @notice 构造函数
     * @dev 初始化 ERC721 名称和符号以及关联的 `PoolManager` 合约地址
     * @param poolManager_ PoolManager 合约地址
     */
    constructor(address poolManager_) ERC721('JSwap V1 Position', 'JSPOS') {
        poolManager = IPoolManager(poolManager_);
    }

    // 存储所有头寸信息：positionId => PositionInfo
    mapping(uint256 => PositionInfo) public positions;

    /**
     * @notice 获取所有已创建的头寸信息
     * @dev 为了返回一个静态数组，先计算总数再逐一填充（遍历从 1 到 _nextId-1）
     * @return result 包含全部 PositionInfo 的数组
     */
    function getAllPositions() external view override returns (PositionInfo[] memory) {
        // 步骤1: 计算当前已创建头寸的总数
        uint256 total = _nextId - 1;

        // 步骤2: 分配内存并填充每个头寸信息
        PositionInfo[] memory result = new PositionInfo[](total);
        for (uint256 i = 1; i <= total; i++) {
            result[i - 1] = positions[i];
        }

        // 步骤3: 返回结果数组
        return result;
    }

    function getSender() public view returns (address) {
        /**
         * @notice 返回当前调用者地址（包装 msg.sender 以便于单元测试或重写）
         * @dev 该函数简单封装了 `msg.sender`，在继承或测试中可被覆盖
         */
        return msg.sender;
    }

    function _blockTimestamp() internal view virtual returns (uint256) {
        /**
         * @notice 返回当前区块时间戳（包装 block.timestamp）
         * @dev 使用包装函数便于在测试中重写时间相关行为
         */
        return block.timestamp;
    }

    modifier checkDeadline(uint256 deadline) {
        require(_blockTimestamp() <= deadline, 'Transaction too old');
        _;
    }

    /**
     * @notice 为指定接收者铸造一个流动性头寸（NFT）并向池中增加流动性
     * @dev 主要步骤：
     *      1. 从 `PoolManager` 获取目标池地址并读取池相关价格信息
     *      2. 使用 `LiquidityAmounts.getLiquidityForAmounts` 计算在给定价格区间和期望代币输入下的流动性值
     *      3. 构造回调数据并调用 `pool.mint`（回调会要求调用者转入 token）
     *      4. 将头寸信息存入本合约并铸造对应的 NFT 给接收者
     */
    function mint(
        MintParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // 步骤1: 获取池并读取价格边界
        address _pool = poolManager.getPool(params.token0, params.token1, params.index);
        IPool pool = IPool(_pool);
        uint160 sqrtPriceX96 = pool.sqrtPriceX96();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(pool.tickLower());
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(pool.tickUpper());
        // 步骤2: 计算可提供的流动性量
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            params.amount0Desired,
            params.amount1Desired
        );
        // 步骤3: 计算并验证所需代币数量
        // 步骤3: 调用池的 mint 并传入 callback 数据，callback 将从 payer 转入代币
        bytes memory data = abi.encode(msg.sender, params.token0, params.token1, params.index);
        try pool.mint(address(this), liquidity, data) returns (uint256 _amount0, uint256 _amount1) {
            amount0 = _amount0;
            amount1 = _amount1;
        } catch Error(string memory reason) {
            console.log('Mint failed with reason: ', reason);
            revert(reason);
        }
        // 步骤4: 铸造代表该头寸的 ERC721 NFT，并记录头寸信息
        _mint(params.recipient, (positionId = _nextId++));

        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.getPosition(address(this));

        positions[positionId] = PositionInfo({
            id: positionId,
            owner: params.recipient,
            token0: params.token0,
            token1: params.token1,
            index: params.index,
            fee: pool.fee(),
            liquidity: liquidity,
            tickLower: pool.tickLower(),
            tickUpper: pool.tickUpper(),
            tokensOwed0: 0,
            tokensOwed1: 0,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128
        });
    }

    /**
     * @dev 检查调用者是否被授权操作指定的 position NFT
     *      允许持有者或被授权的地址（operator/approved）操作
     */
    modifier _isAuthorizedForToken(uint256 tokenId) {
        address owner = ERC721.ownerOf(tokenId);
        require(_isAuthorized(owner, msg.sender, tokenId), 'Not authorized');
        _;
    }

    /**
     * @notice 从池中移除指定头寸的全部流动性并结算应得代币
     * @dev 主要步骤：
     *      1. 读取头寸并获取对应池
     *      2. 调用池的 `burn` 方法移除流动性，返回应付的 token0 和 token1
     *      3. 读取池中最新的 feeGrowth 快照并计算自上次记录以来应补偿的手续费
     *      4. 更新头寸的 tokensOwed 和 feeGrowth 快照，并将流动性设为 0
     */
    function burn(
        uint256 positionId
    ) external override _isAuthorizedForToken(positionId) returns (uint256 amount0, uint256 amount1) {
        // 步骤1: 读取头寸并获取对应池
        PositionInfo storage position = positions[positionId];
        uint128 _liquidity = position.liquidity;
        address _pool = poolManager.getPool(position.token0, position.token1, position.index);
        IPool pool = IPool(_pool);

        // 步骤2: 调用池的 burn，池会把应付的代币累加到 pool 内的 tokensOwed（或返回给 caller）
        (amount0, amount1) = pool.burn(_liquidity);

        // 步骤3: 获取池中最新的 fee growth 快照，用于计算应补偿的手续费
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.getPosition(address(this));

        // 步骤4: 累计应付的代币（包括 burn 直接返还的 amount 与因手续费增长产生的额外分配）
        position.tokensOwed0 +=
            uint128(amount0) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );
        position.tokensOwed1 +=
            uint128(amount1) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );

        // 步骤5: 更新快照并清空流动性
        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity = 0;
    }

    function collect(
        uint256 positionId,
        address recipient
    ) external override _isAuthorizedForToken(positionId) returns (uint256 amount0, uint256 amount1) {
        /**
         * @notice 提取头寸中应计的 token0 和 token1 到指定接收者
         * @dev 主要步骤：
         *      1. 获取头寸和对应池
         *      2. 调用池的 `collect` 将 tokensOwed 转移到接收者
         *      3. 清零头寸中的 tokensOwed
         *      4. 如果头寸流动性为 0，则销毁对应的 NFT
         */

        // 步骤1: 获取头寸信息与所属池
        PositionInfo storage position = positions[positionId];
        address _pool = poolManager.getPool(position.token0, position.token1, position.index);
        IPool pool = IPool(_pool);

        // 步骤2: 调用 pool.collect 执行转账(由于精度问题，这里需要减 1)
        (amount0, amount1) = pool.collect(recipient, position.tokensOwed0 - 1, position.tokensOwed1 - 1);

        // 步骤3: 清零本地记录的应付余额
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        // 步骤4: 如果头寸已经没有流动性，则销毁 NFT
        if (position.liquidity == 0) {
            _burn(positionId);
        }
    }

    function mintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external override {
        /**
         * @notice Pool 的 mint 回调处理函数
         * @dev Pool 在 mint 时会回调该函数，要求调用者（payer）将对应代币转入 Pool 合约
         * @param amount0 mint 过程中需要转入的 token0 数量
         * @param amount1 mint 过程中需要转入的 token1 数量
         * @param data 回调数据，包含 payer 与 pool 标识（由 mint 时编码）
         */
        // 步骤1: 解码回调数据并校验调用者是预期的 pool
        (address payer, address token0, address token1, uint32 index) = abi.decode(
            data,
            (address, address, address, uint32)
        );
        require(msg.sender == poolManager.getPool(token0, token1, index), 'Unauthorized');

        // 步骤2: 从 payer 向 pool 转移 token（如果数量大于 0）
        if (amount0 > 0) {
            IERC20(token0).transferFrom(payer, msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(payer, msg.sender, amount1);
        }
    }
}
