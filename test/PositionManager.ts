import test, { describe, it } from 'node:test'

import { network } from 'hardhat'

import { Position, TickMath, encodeSqrtRatioX96 } from '@uniswap/v3-sdk'
import assert from 'node:assert/strict'
import { log } from 'node:console'

describe('PositionManager', async () => {
    const { viem: hviem, networkHelpers } = await network.connect()

    const deployFactoryFixture = async () => {
        // 初始化一个池子
        const PoolManager = await hviem.deployContract('PoolManager')
        const TTA = await hviem.deployContract('TestToken')
        const TTB = await hviem.deployContract('TestToken')
        const token0 = TTA.address < TTB.address ? TTA : TTB
        const token1 = TTA.address < TTB.address ? TTB : TTA
        const tickLower = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1))
        const tickUpper = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(40000, 1))
        const fee = 3000

        // 初始账户
        const publicClient = await hviem.getPublicClient()
        const [owner] = await hviem.getWalletClients()
        const [sender] = await owner.getAddresses()
        // log('sender:', sender)

        await PoolManager.write.createPoolIfNecessary([
            {
                token0: token0.address,
                token1: token1.address,
                tickLower: tickLower,
                tickUpper: tickUpper,
                fee: fee,
                sqrtPriceX96: BigInt(encodeSqrtRatioX96(10000, 1).toString())
            }
        ])
        const createEvents = await PoolManager.getEvents.PoolCreated()
        const poolAddress: `0x${string}` = createEvents[0].args.pool || '0x'
        const Pool = await hviem.getContractAt('Pool' as string, poolAddress)
        const PositionManager = await hviem.deployContract('PositionManager', [PoolManager.address])

        return { PositionManager, PoolManager, token0, token1, tickLower, tickUpper, fee, sender, Pool }
    }
    describe('functions', async () => {
        it('Test1', async () => {
            const { PositionManager, sender, token0, token1, Pool } = await networkHelpers.loadFixture(
                deployFactoryFixture
            )
            // 初始化账户余额
            const initBalanceValue = 1000n * 10n ** 18n
            await token0.write.mint([sender, initBalanceValue])
            await token1.write.mint([sender, initBalanceValue])
            // 初始化账户授权
            await token0.write.approve([PositionManager.address, initBalanceValue])
            await token1.write.approve([PositionManager.address, initBalanceValue])

            await PositionManager.write.mint([
                {
                    token0: token0.address,
                    token1: token1.address,
                    index: 0,
                    recipient: sender,
                    amount0Desired: 1000n * 10n ** 18n,
                    amount1Desired: 1000n * 10n ** 18n,
                    deadline: BigInt(Date.now() + 1000)
                }
            ])
            it('mint', async () => {
                assert.equal(await token0.read.balanceOf([sender]), 999949496579641839196n)
                assert.equal(await token0.read.balanceOf([Pool.address]), 50503420358160804n)
                assert.equal(await PositionManager.read.ownerOf([1n]), sender)
            })
            it('burn', async () => {
                await PositionManager.write.burn([1n])
                await PositionManager.write.collect([1n, sender])
                assert.equal(await token0.read.balanceOf([sender]), 1000000000000000000000n)
            })
        })
        it('Test2', async () => {
            it('collect', async () => {
                const { PositionManager, sender, token0, token1, Pool } = await networkHelpers.loadFixture(
                    deployFactoryFixture
                )
                const initBalanceValue = 100000000000n * 10n ** 18n
                await token0.write.mint([sender, initBalanceValue])
                await token1.write.mint([sender, initBalanceValue])
                await token0.write.approve([PositionManager.address, initBalanceValue])
                await token1.write.approve([PositionManager.address, initBalanceValue])

                await PositionManager.write.mint([
                    {
                        token0: token0.address,
                        token1: token1.address,
                        index: 0,
                        recipient: sender,
                        amount0Desired: initBalanceValue - 1000n * 10n ** 18n,
                        amount1Desired: initBalanceValue - 1000n * 10n ** 18n,
                        deadline: BigInt(Date.now() + 3000)
                    }
                ])

                await PositionManager.write.mint([
                    {
                        token0: token0.address,
                        token1: token1.address,
                        index: 0,
                        recipient: sender,
                        amount0Desired: 1000n * 10n ** 18n,
                        amount1Desired: 1000n * 10n ** 18n,
                        deadline: BigInt(Date.now() + 3000)
                    }
                ])

                // 通过testswap交易
                const TestSwap = await hviem.deployContract('TestSwap')
                const minPrice = 1000
                const minSqrtPriceX96 = BigInt(encodeSqrtRatioX96(minPrice, 1).toString())
                // 给testswap转账一些token0
                await token0.write.mint([TestSwap.address, 300n * 10n ** 18n])

                await TestSwap.write.testSwap([
                    TestSwap.address,
                    100n * 10n ** 18n,
                    minSqrtPriceX96,
                    Pool.address,
                    token0.address,
                    token1.address
                ])

                // 提取流动性
                await PositionManager.write.burn([1n])
                await PositionManager.write.burn([2n])
                // log('token0 balance of sender', await token0.read.balanceOf([sender]))
                assert.equal(await token0.read.balanceOf([sender]), 99994949657964183919574228501n)

                // 提取token
                await PositionManager.write.collect([1n, sender])
                // log('token0 balance of sender', await token0.read.balanceOf([sender]))
                assert.equal(await token0.read.balanceOf([sender]), 100000000099949495579641839196n)

                await PositionManager.write.collect([2n, sender])
                // log('token0 balance of sender', await token0.read.balanceOf([sender]))
                assert.equal(await token0.read.balanceOf([sender]), 100000000099999999999999999999n)
            })
        })
    })
})
