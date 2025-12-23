## 一、核心业务逻辑
+ 任何人都可以创建或向任意 Pool 添加流动性；
+ 添加流动性时需指定价格区间，这一整套信息构成一个 **Position（头寸）**；
+ 当市场价格落在该区间内时，该 Position 的提供者会按其流动性占比，**自动累积**该 Pool 收取的交易手续费，可随时提取。

### 1、创建Pool
+ 通过调用 `Factory.createPool(tokenA, tokenB, feeTier)` 来创建一个新的 Pool。
+ 同一个交易对（tokenA/tokenB）和手续费等级（feeTier）只能创建一次（通过 `getPool` 查询，避免重复）。

### 2、向Pool提供流动性
+ 只要持有两种代币（比如 ETH 和 USDC），你就可以调用 `PositionManager` 或 `Pool` 的添加流动性接口，为任意 Pool 提供流动性。
+ 提供流动性，就是将两种代币（比如 ETH 和 USDC）**转入Pool合约地址**，这一步是通过调用 `mint` 或 `increaseLiquidity` 函数自动完成的。这些函数会：
    - 记录 **头寸（position）**
    - 将指定数量的两种代币转入 Pool
    - 铸造一个 NFT（或内部记录）代表流动性头寸（在 V3 中，每个 position 通常是一个ERC721 NFT）

### 3、头寸（position）
+ 添加流动性时，必须指定`tickLower` 和 `tickUpper`，价格区间的上下界（必须是对齐到 tickSpacing 的合规 tick）
+ 这个 **“用户 + 区间 + 流动性数量 + 费用记录”** 的完整信息，就构成了一个 **Position**。
+ **Position = 谁 + 在哪个 Pool + 在什么价格区间 + 提供了多少流动性 + 赚了多少手续费**

### 4、手续费
+ 当交易发生时，**只要当前市场价格落在提供的Position的价格区间内**，这部分流动性就会被“激活”，参与做市，从而按比例获得该 Pool 收取的 **交易手续费**。
+ 举例：
    - 在 ETH/USDC Pool 设置流动性区间：$1800 ~ $2200
    - 当前价格是 $2000 → 流动性活跃 → 开始赚取每笔交易的 0.3% 手续费（按占当前总流动性的比例分配）
    - 价格跌到 $1700 → 提供的Position区间不包含当前价 → 停止赚费
    - 价格回到 $1900 → 重新进入提供的Position区间 → 继续赚费
+ 手续费是持续累计的，不会自动分发，可以在任何时候调用 collect() 把应得的手续费提现到钱包。

## 二、合约结构
+ `PoolManager.sol`: 顶层合约，对应 Pool 页面，负责 Pool 的创建和管理。
+ `PositionManager.sol`: 顶层合约，对应 Position 页面，负责 LP 头寸和流动性的管理。
+ `SwapRouter.sol`: 顶层合约，对应 Swap 页面，负责预估价格和交易。
+ `Factory.sol`: 底层合约，Pool 的工厂合约；
+ `Pool.sol`: 最底层合约，对应一个交易池，记录了当前价格、头寸、流动性等信息。

## 三、核心代码分析
**（1）Factory.sol**

+ 核心函数：createPool()，创建pool，使用create2部署pool
+ 核心逻辑：排序代币地址 → 检查是否已存在 → 临时传参 → create2 部署 Pool → 记录地址
    - **使用create2部署pool：只要参数相同，Pool 的地址就永远相同**

```markdown
        //============使用create2 部署 Pool=================
        // generate create2 salt
        bytes32 salt = keccak256(
            abi.encode(token0, token1, tickLower, tickUpper, fee)
        );

        // create pool
        pool = address(new Pool{salt: salt}());
        //============使用create2 部署 Pool=================
```

**（2）PoolManager.sol**

+ 继承了 `Factory.sol`，实现了IPoolManager接口。
+ 核心函数：
    - `getPairs()` 获取所有交易对
    - `getAllPools()` 获取所有 Pool 的详细信息
    - `createAndInitializePoolIfNecessary()` 核心入口函数，**用户创建 Pool 的主要入口**
        * 强制参数顺序正确 -> 调用继承的 `Factory.createPool` 创建 Pool -> 获取 Pool 实例 -> 如果未初始化，设置初始价格 -> 如果是该交易对的第一个 Pool，记录到 `pairs`
+ 为什么要存在 `Factory.sol`和 `PoolManager.sol`两个合约？

| **合约** | **职责** | **改变的原因** |
| --- | --- | --- |
| `Factory` | **确定性创建 Pool**，保证地址唯一、不可变 | 几乎永不改变（理想情况下） |
| `PoolManager` | **管理 Pool 的生命周期**：初始化、查询、记录交易对 | 可能需要升级功能、修复 bug |


+ `PoolManager.sol`合约已经有了`Pair[] public pairs`公共变量，为什么还要`**getPairs()**`函数？
    - solidity 生成的 getter 方法并不会返回整个数据，而是需要调用者指定索引，只返回索引对应的值。这么设计的原因是避免一次返回过多的数据，在别的合约使用这份数据时产生不可控的 gas 费。
    - `**getPairs()**`函数需要返回全部内容供前端展示。
+ `getAllPools()` 函数的作用？
    - 由于池子的信息是在 `Factory` 合约中保存的，因此我们在返回全部池子信息的时候，还需要对 `Factory` 保存的信息进行处理，处理成我们想要的数据格式。

**（3）Pool.sol**

+ `**mint()**`：用户在指定的价格区间内**添加流动性（Liquidity）**
    - `address recipient`：流动性归属地址(谁拥有这笔流动性)
    - `uint28 amount`：要增加的流动性数量（ΔL）
    - `bytes calldata data`：附加数据，通常用于回调中传递信息（如手续费率、路径等）
    - 返回值：`amount0`-需要转入的 `token0` 数量，`amount1`-需要转入的 `token1` 数量

```markdown
function mint(
    address recipient,
    uint128 amount,
    bytes calldata data
) external override returns (uint256 amount0, uint256 amount1)
```

+ 流程图

```markdown
用户调用 Router.mint(...)
        ↓
Router 调用 Pool.mint(recipient, amount, data)
        ↓
Pool._modifyPosition(...) → 计算需要多少 token0/token1
        ↓
Pool 记录调用前余额 balance0Before, balance1Before
        ↓
Pool 调用 Router.mintCallback(amount0, amount1, data)
        ↓
Router 执行 transferFrom(user, Pool, amount0/1)
        ↓
Pool 验证余额是否增加
        ↓
Pool 发出 Mint 事件
```

+ `**_modifyPosition()**`：添加/移除流动性时的状态更新。内部函数(被 `mint` 和 `burn` 调用)
    - 输入：`params.owner`（用户地址），`params.liquidityDelta`（流动性变化量，正-被 `mint` 调用、添加流动性、用户需转入token，负-`burn` 调用、减少流动性、用户将收到token）
    - 输出：`amount0`, `amount1`（需要转入或转出的 token 数量）。

```markdown
function _modifyPosition(
    ModifyPositionParams memory params
) private returns (int256 amount0, int256 amount1)
```

+ 作用：
    - 计算所需 token0、token1 的数量。
    - 计算该用户从上次提取手续费以来，应得的 token0、token1 手续费。
    - 更新手续费提取记录(下次再调用 _modifyPosition 时，只会计算从现在到未来的手续费)。
    - 累加可提取手续费(把刚刚计算出的应得手续费，加到用户的“待领取余额”中，不转账、只记账，需要用户调用collect()函数提取手续费)。
    - 更新流动性(池子的总流动性 `liquidity`，用户的个人流动性 `position.liquidity`)。
+ 流程图

```markdown
接收参数：owner, liquidityDelta
  │
  ▼
计算需要的 token 数量 (amount0, amount1)：
计算 amount0 = getAmount0Delta(当前价格√P, 上限价格√P_upper, ΔL)；
计算 amount1 = getAmount1Delta(下限价格√P_lower, 当前价格√P, ΔL)
  │
  ▼
获取或初始化用户头寸 position
  │
  ▼
结算手续费（收益结算）：tokensOwed0 = (feeGrowthGlobal0 - last0) × liquidity；
                      tokensOwed1 = (feeGrowthGlobal1 - last1) × liquidity
  │
  ▼
更新用户待领取手续费：position.tokensOwed0 += tokensOwed0；
                    position.tokensOwed1 += tokensOwed1
  │
  ▼
更新流动性
│
├── 更新全局流动性：liquidity += liquidityDelta
│
└── 更新用户头寸流动性：position.liquidity += liquidityDelta
```

+ `**burn()**`：用户**移除流动性（Liquidity）**
    - 入参：`uint28 amount`：要移除的流动性数量（ΔL）
    - 返回值：`amount0`-将要返还给用户的 `token0` 数量，`amount1`-将要返还给用户的 `token1` 数量
    - 对于手续费、退还的代币，只记账、不转账，用户调 `collect()` 用函数转账

```markdown
function burn(
    uint128 amount
) external override returns (uint256 amount0, uint256 amount1)
```

+ 流程图

```markdown
输入：要移除的流动性数量 amount
  │
  ▼
校验：amount > 0 且 amount ≤ 用户当前流动性
  │
  ▼
调用 _modifyPosition() 获取返还的 token0、token1 的数量（负值）
  │
  ▼
转换为正数：amount0 = uint256(-amount0Int); amount1 = uint256(-amount1Int)
  │
  ▼
若 amount0 > 0 或 amount1 > 0，将返还的 token 加入用户待领取余额，
   tokensOwed0 += amount0; tokensOwed1 += amount1
  │
  ▼
触发 Burn 事件
```

+ `**collect()**`：用户**提取流动性提供者（LP）应得的代币收益**，包括因 `mint` / `burn` 操作而应返还的本金（token），累计产生的交易手续费
    - `address recipient`：代币将被发送到的目标地址（可以不是调用者）
    - `uint128 amount0Requested`：请求提取的 `token0` 数量（可小于等于 `tokensOwed0`）
    - `uint128 amount1Requested`：请求提取的 `token1` 数量（可小于等于 `tokensOwed1`）
    - 返回值：`amount0`-实际成功提取的 `token0` 数量，`amount1`-实际成功提取的 `token1` 数量

```markdown
function collect(
    address recipient,
    uint128 amount0Requested,
    uint128 amount1Requested
) external override returns (uint128 amount0, uint128 amount1)
```

+ 流程图

```markdown
输入：recipient, amount0Requested, amount1Requested
  │
  ▼
获取 position = positions[msg.sender]
  │
  ▼
计算实际提取量：amount0 = min(requested, tokensOwed0)；amount1 = min(requested, tokensOwed1)
  │
  ▼
更新待领取余额：tokensOwed0 -= amount0；tokensOwed1 -= amount1
  │
  ▼
执行转账：transfer token0 → recipient；transfer token1 → recipient
  │
  ▼
触发 Collect 事件
```

+ `**swap()**`：实现了**高效的、基于集中流动性的代币兑换**。
    - `address recipient`：交易后，收到输出代币的地址
    - `bool zeroForOne`：方向：`true` 表示用 `token0` 换 `token1`；`false` 表示用 `token1` 换 `token0`
    - `int256 amountSpecified`：指定输入量（>0）或期望输出量（<0）
    - `uint160 sqrtPriceLimitX96`：价格限制（防止滑点过大）
    - `bytes calldata data`：回调时传递的自定义数据（如路径信息）
    - 返回值：`amount0` 和 `amount1` 是**变化量**（正表示池子收到，负表示池子付出）

```markdown
function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
) external override returns (int256 amount0, int256 amount1)
```

+ 流程图

```markdown
参数校验（amount ≠ 0, 价格限制有效）
  │
  ▼
判断方向（zeroForOne）和类型（exactInput）：
amountSpecified > 0 → 精确输入（如：用 100 USDC 换尽可能多的 DAI），
amountSpecified < 0 → 精确输出（如：想要 50 DAI，最多愿意付多少 USDC）
  │
  ▼
初始化状态（SwapState）
  │
  ▼
计算价格边界（tick → price）
  │
  ▼
调用 computeSwapStep 计算交易结果
  │
  ▼
更新全局状态（价格、tick、手续费增长）
  │
  ▼
计算返回值 amount0, amount1
  │
  ▼
记录余额前状态
  │
  ▼
回调 swapCallback：用户转入输入 token。
用户必须在回调中把 token 转给池子，因为池子不能主动从用户钱包转账。
  │
  ▼
验证 token 是否到账
  │
  ▼
将输出 token 转给 recipient
  │
  ▼
触发 Swap 事件
```

**（4）PositionManager.sol**

+ 通过 NFT（ERC721）来管理流动性头寸（position），并作为用户与底层池子（Pool）之间的中介。合约封装了流动性操作的复杂性，使用户可以更方便地添加、移除和收集收益。
+ 整体结构：
    - `ERC721`：每个流动性头寸用一个 NFT 表示（tokenId = positionId）
    - `IPoolManager`：管理所有交易对池子的创建与查找
    - `IPool`：实际执行 `mint`/`burn`/`collect` 的池子合约
    - `LiquidityAmounts`, `TickMath` 等库：数学计算支持

**核心函数**

+ `**mint()**`：用户**添加流动性（Liquidity）**

```markdown
    struct MintParams {
        address token0;
        address token1;
        uint32 index; // 池子索引（支持多费率/多区间）
        uint256 amount0Desired; // 期望提供的 token0 数量
        uint256 amount1Desired; // 期望提供的 token1 数量
        address recipient; // 流动性 NFT 发送给谁
        uint256 deadline; // 交易截止时间
    }

    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 positionId, // 新生成的 NFT tokenId，唯一标识该流动性头寸
            uint128 liquidity, // 实际添加的流动性单位数
            uint256 amount0, // 实际使用的 token0 数量
            uint256 amount1 // 实际使用的 token1 数量
        );
```

+ 流程图

```markdown
用户调用 PositionManager.mint(...)
  │
  ▼
校验 deadline 是否过期
  │
  ▼
通过 token0/token1/index 查找 Pool 地址
  │
  ▼
从Pool获取当前价格 & tick 区间
  │
  ▼
计算 amount0Desired + amount1Desired 能提供的 liquidity（通过LiquidityAmounts.getLiquidityForAmounts()）
  │
  ▼
构造回调数据（包含 payer=msg.sender）
  │
  ▼
调用 pool.mint(address(this), liquidity, data)添加流动性
     │
     ▼
     Pool 回调 PositionManager.mintCallback(...)
         │
         ▼
         从 msg.sender 转账 token0 和 token1 给 Pool
         │
         ▼
     返回实际使用的 amount0, amount1
  │
  ▼
铸造 NFT 给 recipient，tokenId = positionId
  │
  ▼
查询 Pool 中该位置的最新 feeGrowthInside
  │
  ▼
保存完整 PositionInfo 到 storage
  │
  ▼
返回 positionId, liquidity, amount0, amount1
```

+ `**burn()**`：**用于“移除流动性”但不立即领取代币。**
    - `uint256 positionId`：要移除流动性的头寸 ID（即 NFT 的 tokenId）
    - 返回：移除流动性时，池子返还的 `token0` 和 `token1`的数量（本金部分）

```markdown
function burn(
    uint256 positionId
)
    external
    override
    isAuthorizedForToken(positionId)
    returns (uint256 amount0, uint256 amount1)
```

+ 流程图

```markdown
用户调用 PositionManager.burn(positionId)
  │
  ▼
权限校验：是否 owner 或 approved
  │
  ▼
加载 position 信息（token0/token1/index/liquidity等）
  │
  ▼
通过 poolManager 查找 Pool 地址
  │
  ▼
调用 pool.burn(liquidity) → 移除流动性：
Pool 记录：该位置应得 amount0 + amount1，Pool 不转账，只记账
  │
  ▼
查询 Pool 中该位置的最新 feeGrowthInside 值
  │
  ▼
计算新增手续费收益：
   tokensOwed0 += amount0 + (delta_feeGrowth * liquidity / Q128)
   tokensOwed1 += amount1 + (delta_feeGrowth * liquidity / Q128)
  │
  ▼
更新 position 的 feeGrowth 记录
  │
  ▼
清零 liquidity（流动性已移除）
  │
  ▼
返回 amount0, amount1（仅作参考）
```

+ `**collect()**`：**领取流动性收益，取回本金和手续费。**
    - `uint256 positionId`：要领取收益的头寸 ID（即 NFT 的 tokenId）
    - `address recipient`：收到代币的地址（可以不是调用者）
    - 返回：实际转账给 `recipient` 的 `token0` 和 `token1`的数量

```markdown
function collect(
    uint256 positionId,
    address recipient
)
    external
    override
    isAuthorizedForToken(positionId)
    returns (uint256 amount0, uint256 amount1)
```

+ 流程图

```markdown
用户调用 PositionManager.collect(positionId, recipient)
  │
  ▼
权限校验：是否拥有该 NFT
  │
  ▼
加载 position 信息（tokensOwed0/1, token0/token1等）
  │
  ▼
通过 poolManager 查找 Pool 地址
  │
  ▼
调用 pool.collect(recipient, owed0, owed1)
Pool 执行：
        token0.transfer(recipient, owed0)
        token1.transfer(recipient, owed1)
     │
     ▼
     返回实际转账数量
  │
  ▼
清空 position.tokensOwed0 和 tokensOwed1
  │
  ▼
检查 liquidity 是否为 0
  │
  ┌─────────────┐
  ▼             ▼
是            否
  │             │
  ▼             ▼
销毁 NFT     不销毁
_burn(positionId)
  │
  ▼
函数结束
```

+ `**mintCallback()**`：**添加流动性时的代币回调。**在用户调用 mint 添加流动性时，由 **Pool 合约主动调用**的回调函数，目的是让 PositionManager 代表用户将代币从用户钱包转移到 Pool。
    - `uint256 amount0`：Pool 要求提供的 `token0` 数量
    - `uint256 amount1`：Pool 要求提供的 `token1` 数量
    - `bytes calldata data`：由 `PositionManager.mint()` 传入的编码数据，包含上下文信息

```markdown
function mintCallback(
    uint256 amount0,
    uint256 amount1,
    bytes calldata data
) external override
```

+ 流程图

```markdown
用户调用 PositionManager.mint(...)
  │
  ▼
PositionManager 计算 liquidity
  │
  ▼
PositionManager 调用 pool.mint(address(this), liquidity, data)
     │
     ▼
     Pool 开始执行 mint 流程
     需要代币 → 调用 msg.sender.mintCallback(amount0, amount1, data)
           │
           ▼
           回到 PositionManager.mintCallback(...)
               │
               ▼
               解码 data → 得到 token0/token1/payer
               │
               ▼
               校验 msg.sender 是否为正确的 Pool
               │
               ▼
               调用 transferFrom(payer, msg.sender, amount0/1)
                     │
                     ▼
                     从用户钱包扣款，转入 Pool 合约
               │
               ▼
               回到 Pool.mint()
                     │
                     ▼
                     流动性添加成功
           │
           ▼
     返回 amount0, amount1 给 PositionManager
  │
  ▼
PositionManager 铸造 NFT 给用户
  │
  ▼
完成
```

+ **典型使用流程**：

```markdown
// 1. 用户先 approve 代币给 PositionManager
USDC.approve(positionManager, amount0);
DAI.approve(positionManager, amount1);

// 2. 调用 mint 添加流动性
const tx = await positionManager.mint({
  token0: USDC,
  token1: DAI,
  index: 0,
  amount0Desired: 100e6,
  amount1Desired: 100e18,
  recipient: user,
  deadline: now + 3600
});

// 3. 成功后获得一个 NFT（positionId）
const positionId = await tx.logs[0].args.tokenId;

// 4. 后续可 burn + collect 领取本金和手续费
await positionManager.burn(positionId);
await positionManager.collect(positionId, user);
```

**（5）SwapRouter.sol**

+ **去中心化交易所（DEX）的路由核心组件**，实现了支持拆单交易、精确输入/输出交换、实时报价（Quote）、安全回调机制。
+ 通过 NFT（ERC721）来管理流动性头寸（position），并作为用户与底层池子（Pool）之间的中介。合约封装了流动性操作的复杂性，使用户可以更方便地添加、移除和收集收益。
+ `**exactInput()**`：**精确输入交换。**用户指定要卖出多少 `tokenIn`，系统尽可能多地兑换成 `tokenOut`。

```markdown
struct ExactInputParams {
    address tokenIn; // 输入代币
    address tokenOut; // 输出代币
    uint32[] indexPath; // 经过的 Pool 索引（费率或版本）
    address recipient; // 接收 tokenOut 的地址
    uint256 deadline; // 过期时间
    uint256 amountIn; // 确定要卖出的数量
    uint256 amountOutMinimum; // 最少接受数量（防滑点）
    uint160 sqrtPriceLimitX96; // 价格限制，防止过度滑点
}

function exactInput(
    ExactInputParams calldata params
) external payable override returns (uint256 amountOut)
```

+ 流程图

```markdown
开始
  │
  ▼
设置 amountIn = params.amountIn，zeroForOne = (tokenIn < tokenOut)
  │
  ▼
循环遍历 indexPath[i] 中的每个索引
  │
  ▼
获取 Pool 地址：poolManager.getPool(tokenIn, tokenOut, indexPath[i])
  │
  ▼
检查 Pool 是否存在 → 否？→ revert "Pool not found"
  │
  ▼
是 → 获取 IPool 实例
  │
  ▼
构造回调数据 data = abi.encode(tokenIn, tokenOut, index, payer)
  │
  ▼
调用 this.swapInPool(...) → 获取 (amount0, amount1)
  │
  ▼
更新：
  amountIn -= (zeroForOne ? amount0 : amount1)
  amountOut += (zeroForOne ? -amount1 : -amount0)
  │
  ▼
amountIn == 0？→ 是 → 跳出循环
  │
  ▼
否 → 继续下一轮循环
  │
  ▼
循环结束
  │
  ▼
检查：amountOut ≥ amountOutMinimum？→ 否 → revert "Slippage exceeded"
  │
  ▼
是 → 发送事件：emit Swap(...)
  │
  ▼
返回 amountOut
  │
  ▼
结束
```

+ `**exactOutput()**`：**精确输出交换。**用户指定要兑换多少 `tokenOut`，系统花费 `tokenIn`，且限制不能超过用户设定的上限。
    - 调用 `swapInPool()`函数时，数量参数要传入负数，**表示“要收到这个代币”**。

```markdown
function exactOutput(
    ExactOutputParams calldata params
) external payable override returns (uint256 amountIn)
```

+ 流程图

```markdown
开始
  │
  ▼
设置 amountOut = params.amountOut         ← 用户想要换到的确切数量
  │
  ▼
设置 zeroForOne = (tokenIn < tokenOut)   ← 判断交易方向
  │
  ▼
循环遍历 indexPath[i] 中的每个索引
  │
  ▼
获取 Pool 地址：poolManager.getPool(tokenIn, tokenOut, indexPath[i])
  │
  ▼
检查 Pool 是否存在 → 否？→ revert "Pool not found"
  │
  ▼
是 → 获取 IPool 实例
  │
  ▼
构造回调数据 data = abi.encode(tokenIn, tokenOut, index, payer)
  │
  ▼
调用 this.swapInPool(...)，传入：-int256(amountOut)
  │
  ▼
Pool 执行 swap，回调 mintCallback，完成转账
  │
  ▼
拿到 (amount0, amount1)：Pool 收/付的代币量
  │
  ▼
更新：
  amountOut -= uint256(zeroForOne ? -amount1 : -amount0)  ← 减去已换到的 output
  amountIn  += uint256(zeroForOne ?  amount0 :  amount1)  ← 累加已花费的 input
  │
  ▼
amountOut == 0？→ 是 → 跳出循环
  │
  ▼
否 → 继续下一轮循环（继续换剩下的 output）
  │
  ▼
循环结束
  │
  ▼
检查：amountIn ≤ amountInMaximum？→ 否 → revert "Slippage exceeded"
  │
  ▼
是 → 发送事件：emit Swap(...)
  │
  ▼
返回 amountIn（总共花了多少 tokenIn）
  │
  ▼
结束
```

+ `**swapInPool()**`：**安全调用 Pool 的 swap 方法。**这是一个包装函数。使用了try-catch，捕获错误信息并进行转换。

```markdown
    function swapInPool(
        IPool pool,
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        try
            pool.swap(
                recipient,
                zeroForOne,
                amountSpecified,
                sqrtPriceLimitX96,
                data
            )
        returns (int256 _amount0, int256 _amount1) {
            return (_amount0, _amount1);
        } catch (bytes memory reason) {
            return parseRevertReason(reason);
        }
    }
```

+ `**parseRevertReason()**`：**解析 swapInPool 中捕获的 revert 错误信息。**实现了“**部分成交 + 容错路由**”的高级功能。可以辅助实现报价功能。

```solidity
function parseRevertReason(
        bytes memory reason
    ) private pure returns (int256, int256) {
        if (reason.length != 64) {
            if (reason.length < 68) revert("Unexpected error");
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (int256, int256));
    }
```

+ `**quoteExactInput()**`：**报价函数。**模拟执行 exactInput 以获取预期输出数量（即“报价”）。实现“如果我用 X 个 tokenIn 去换 tokenOut，能拿到多少？”。不实际转账，只返回一个预估的 amountOut。

```markdown
    function quoteExactInput(
        QuoteExactInputParams calldata params
    ) external override returns (uint256 amountOut) {
        // 因为没有实际 approve，所以这里交易会报错，我们捕获错误信息，解析需要多少 token

        return
            this.exactInput(
                ExactInputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    indexPath: params.indexPath,
                    recipient: address(0), // 不真正发送代币
                    deadline: block.timestamp + 1 hours, // 设置一个未来的 deadline
                    amountIn: params.amountIn,
                    amountOutMinimum: 0, // 不设下限
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );
    }
```

+ `**quoteExactOutput()**`：**报价函数。**模拟执行 exactOutput 以获取预期输入数量（即“报价”）。实现“我想换到 exactly 100 DAI，需要花多少 USDC？”。不实际转账，只返回一个预估的 amountIn。

```markdown
    function quoteExactOutput(
        QuoteExactOutputParams calldata params
    ) external override returns (uint256 amountIn) {
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
```

+ `**swapCallback()**`：**处理流动性池（Pool）在 swap 过程中发起的回调请求。**这是一个 **回调函数（callback）**，由 IPool 在执行 swap 时调用，目的是让外部合约（这里是 Router）提供输入代币。

```markdown
    function swapCallback(
        int256 amount0Delta, // Pool 需要收到或付出的 token0 数量:
                             // 正数 → 需要收到（用户卖出）,负数 → 会付出（用户买入）
        int256 amount1Delta, // 同上，对应 token1
        bytes calldata data // 调用者传入的额外数据，包含交易上下文
    ) external override {
        // transfer token
        (address tokenIn, address tokenOut, uint32 index, address payer) = abi
            .decode(data, (address, address, uint32, address));
        address _pool = poolManager.getPool(tokenIn, tokenOut, index);

        // 检查 callback 的合约地址是否是 Pool
        require(_pool == msg.sender, "Invalid callback caller");

        uint256 amountToPay = amount0Delta > 0
            ? uint256(amount0Delta)
            : uint256(amount1Delta);
        // payer 是 address(0)，这是一个用于预估 token 的请求（quoteExactInput or quoteExactOutput）
        // 参考代码 https://github.com/Uniswap/v3-periphery/blob/main/contracts/lens/Quoter.sol#L38
        if (payer == address(0)) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amount0Delta)
                mstore(add(ptr, 0x20), amount1Delta)
                revert(ptr, 64)
            }
        }

        // 正常交易，转账给交易池
        if (amountToPay > 0) {
            IERC20(tokenIn).transferFrom(payer, _pool, amountToPay);
        }
    }
```

+ 在整体流程中的角色

```markdown
用户调用 exactInput(amountIn=100 USDC)
 └─→ Router 调用 pool.swap(...)
      └─→ Pool 计算成交结果 (amount0=100, amount1=-0.05 ETH)
      └─→ Pool 回调 router.swapCallback(100, -0.05, data)
           └─→ Router 从 payer 转 100 USDC 给 Pool
      └─→ Pool 将 0.05 ETH 付给 recipient
```



