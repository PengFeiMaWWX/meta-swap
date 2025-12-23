import test, { describe, it } from 'node:test'

import { network } from 'hardhat'

import { Position, TickMath, encodeSqrtRatioX96 } from '@uniswap/v3-sdk'
import assert from 'node:assert/strict'
import { log } from 'node:console'

describe('SwapRouter', async () => {
    const { viem: hviem, networkHelpers } = await network.connect()

    const deployFactoryFixture = async () => {
        // 部署测试代币
        const tokenA = await hviem.deployContract('TestToken')
        const tokenB = await hviem.deployContract('TestToken')
        const token0 = tokenA.address < tokenB.address ? tokenA : tokenB
        const token1 = tokenA.address < tokenB.address ? tokenB : tokenA

        // 部署PoolManager合约
        const PoolManager = await hviem.deployContract('PoolManager')

        // 初始化价格上下限
        const tickLower = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1))
        const tickUpper = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(40000, 1))
        const sqrtPriceX96 = BigInt(encodeSqrtRatioX96(10000, 1).toString())

        // 建立池子(两种费率)
        await PoolManager.write.createPoolIfNecessary([
            {
                token0: token0.address,
                token1: token1.address,
                fee: 3000,
                tickLower,
                tickUpper,
                sqrtPriceX96
            }
        ])
        await PoolManager.write.createPoolIfNecessary([
            {
                token0: token0.address,
                token1: token1.address,
                fee: 10000,
                tickLower,
                tickUpper,
                sqrtPriceX96
            }
        ])
        // 部署SwapRouter合约
        const SwapRouter = await hviem.deployContract('SwapRouter', [PoolManager.address])
        // 部署测试LP
        const TestLP = await hviem.deployContract('TestLP')
        // 初始化LP
        const initBalanceValue = 10n ** 12n * 10n ** 18n
        await token0.write.mint([TestLP.address, initBalanceValue])
        await token1.write.mint([TestLP.address, initBalanceValue])
        // 注入流动性
        // 池子1注入
        const pool1Addr = await PoolManager.read.getPool([token0.address, token1.address, 0])
        await token0.write.approve([pool1Addr, initBalanceValue])
        await token1.write.approve([pool1Addr, initBalanceValue])
        await TestLP.write.mint([TestLP.address, 50000n * 10n ** 18n, pool1Addr, token0.address, token1.address])
        // 池子2注入
        const pool2Addr = await PoolManager.read.getPool([token0.address, token1.address, 1])
        await token0.write.approve([pool2Addr, initBalanceValue])
        await token1.write.approve([pool2Addr, initBalanceValue])
        await TestLP.write.mint([TestLP.address, 50000n * 10n ** 18n, pool2Addr, token0.address, token1.address])

        // 准备测试账户
        const [owner] = await hviem.getWalletClients()
        const [sender] = await owner.getAddresses()

        return {
            SwapRouter,
            token0,
            token1,
            sender
        }
    }

    it('functions', async () => {
        it('exacInput', async () => {
            const { SwapRouter, token0, token1, sender } = await deployFactoryFixture()
            await token0.write.mint([sender, 10n ** 12n * 10n ** 18n])
            await token0.write.approve([SwapRouter.address, 100n * 10n ** 18n])

            await SwapRouter.write.exactInput([
                {
                    tokenIn: token0.address,
                    tokenOut: token1.address,
                    amountIn: 10n * 10n ** 18n,
                    amountOutMinimum: 0n,
                    indexPath: [0, 1],
                    sqrtPriceLimitX96: BigInt(encodeSqrtRatioX96(100, 1).toString()),
                    recipient: sender,
                    deadline: BigInt(Math.floor(Date.now() / 1000) + 1000)
                }
            ])
            const token1Amount = await token1.read.balanceOf([sender])
            // log('token1Amount:', token1Amount)
            assert.equal(token1Amount, 97750848089103280585132n)
        })

        it('exacOutput', async () => {
            const { SwapRouter, token0, token1, sender } = await deployFactoryFixture()
            await token0.write.mint([sender, 10n ** 12n * 10n ** 18n])
            await token0.write.approve([SwapRouter.address, 100n * 10n ** 18n])
            await SwapRouter.write.exactOutput([
                {
                    tokenIn: token0.address,
                    tokenOut: token1.address,
                    amountOut: 10n * 10n ** 18n,
                    amountInMaximum: 10n * 10n ** 18n,
                    indexPath: [0, 1],
                    sqrtPriceLimitX96: BigInt(encodeSqrtRatioX96(100, 1).toString()),
                    recipient: sender,
                    deadline: BigInt(Math.floor(Date.now() / 1000) + 1000)
                }
            ])
            const token0Amount = await token0.read.balanceOf([sender])
            // log('tokenIn:', 10n ** 12n * 10n ** 18n - token0Amount)
            assert.equal(10n ** 12n * 10n ** 18n - token0Amount, 1000002000004001n)

            const token1Amount = await token1.read.balanceOf([sender])
            // log('tokenOut:', token1Amount)
            assert.equal(token1Amount, 10000000000000000000n)
        })

        it('quoteExactInput', async () => {
            const { SwapRouter, token0, token1, sender } = await deployFactoryFixture()
            const data = await SwapRouter.simulate.quoteExactInput([
                {
                    tokenIn: token0.address,
                    tokenOut: token1.address,
                    amountIn: 10n * 10n ** 18n,
                    indexPath: [0, 1],
                    sqrtPriceLimitX96: BigInt(encodeSqrtRatioX96(100, 1).toString())
                }
            ])
            // log('quoteExactInput:', data.result)
            assert.equal(data.result, 97750848089103280585132n)
        })

        it('quoteExactOutput', async () => {
            const { SwapRouter, token0, token1, sender } = await deployFactoryFixture()
            const data = await SwapRouter.simulate.quoteExactOutput([
                {
                    tokenIn: token0.address,
                    tokenOut: token1.address,
                    amountOut: 10000n * 10n ** 18n,
                    indexPath: [0, 1],
                    sqrtPriceLimitX96: BigInt(encodeSqrtRatioX96(100, 1).toString())
                }
            ])
            // log('quoteExactOutput:', data.result)
            assert.equal(data.result, 1002004008016032065n)
        })
    })
})
