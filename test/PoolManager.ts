import test, { describe, it } from 'node:test'

import { network } from 'hardhat'

import { TickMath, encodeSqrtRatioX96 } from '@uniswap/v3-sdk'
import assert from 'node:assert/strict'
import { log } from 'node:console'

describe('PoolManager', async () => {
    const { viem: hviem, networkHelpers } = await network.connect()
    const publicClient = await hviem.getPublicClient()

    const deployFactoryFixture = async () => {
        const Manager = await hviem.deployContract('PoolManager')
        return { Manager }
    }

    describe('functions', async () => {
        it('Test1', async () => {
            const { Manager } = await networkHelpers.loadFixture(deployFactoryFixture)
            const tokenA: `0x${string}` = '0x0000000000000000000000000000000000000001'
            const tokenB: `0x${string}` = '0x0000000000000000000000000000000000000002'
            const tokenC: `0x${string}` = '0x0000000000000000000000000000000000000003'
            const tokenD: `0x${string}` = '0x0000000000000000000000000000000000000004'

            // 创建 A - B 交易对
            await Manager.write.createPoolIfNecessary([
                {
                    token0: tokenA,
                    token1: tokenB,
                    fee: 3000,
                    tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1)),
                    tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(10000, 1)),
                    sqrtPriceX96: BigInt(encodeSqrtRatioX96(100, 1).toString())
                }
            ])
            // 再创建 A - B 和上一个会合并
            await Manager.write.createPoolIfNecessary([
                {
                    token0: tokenA,
                    token1: tokenB,
                    fee: 3000,
                    tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1)),
                    tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(10000, 1)),
                    sqrtPriceX96: BigInt(encodeSqrtRatioX96(100, 1).toString())
                }
            ])
            // 创建 C - D 交易对
            await Manager.write.createPoolIfNecessary([
                {
                    token0: tokenC,
                    token1: tokenD,
                    fee: 2000,
                    tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(100, 1)),
                    tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(5000, 1)),
                    sqrtPriceX96: BigInt(encodeSqrtRatioX96(200, 1).toString())
                }
            ])
            it('pairs', async () => {
                // 验证pairs数量
                const pairs = await Manager.read.getPairs()
                // log(pairs)
                assert.equal(pairs.length, 2)
            })
            it('pools', async () => {
                // 判断pools数量和数据
                const pools = await Manager.read.getAllPools()
                assert.equal(pools.length, 2)
                assert.equal(pools[0].token0, tokenA)
                assert.equal(pools[0].token1, tokenB)
                assert.equal(pools[0].sqrtPriceX96, BigInt(encodeSqrtRatioX96(100, 1).toString()))

                assert.equal(pools[1].token0, tokenC)
                assert.equal(pools[1].token1, tokenD)
                assert.equal(pools[1].sqrtPriceX96, BigInt(encodeSqrtRatioX96(200, 1).toString()))
            })
        })

        it('Test2', async () => {
            const { Manager } = await networkHelpers.loadFixture(deployFactoryFixture)

            it('rquire token0 < token1', async () => {
                const tokenA: `0x${string}` = '0x0000000000000000000000000000000000000002'
                const tokenB: `0x${string}` = '0x0000000000000000000000000000000000000001'
                await hviem.assertions.revertWith(
                    Manager.write.createPoolIfNecessary([
                        {
                            token0: tokenA,
                            token1: tokenB,
                            fee: 3000,
                            tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1)),
                            tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(10000, 1)),
                            sqrtPriceX96: BigInt(encodeSqrtRatioX96(100, 1).toString())
                        }
                    ]),
                    'Token0 must be less than token1'
                )
            })
        })
    })
})
