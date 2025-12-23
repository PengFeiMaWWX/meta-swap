import test, { describe, it } from 'node:test'

import { network } from 'hardhat'

import { TickMath, encodeSqrtRatioX96 } from '@uniswap/v3-sdk'
import assert from 'node:assert/strict'
import { log } from 'node:console'

describe('Pool', async () => {
    const { viem: hviem, networkHelpers } = await network.connect()
    const publicClient = await hviem.getPublicClient()

    const deployFactoryFixture = async () => {
        const Factory = await hviem.deployContract('Factory')
        const TTA = await hviem.deployContract('TestToken')
        const TTB = await hviem.deployContract('TestToken')
        const token0 = TTA.address < TTB.address ? TTA : TTB
        const token1 = TTA.address < TTB.address ? TTB : TTA
        const tickLower = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1))
        const tickUpper = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(40000, 1))
        // 以1000000为基底，uniswap 支持4种费率：0.01%，0.05%，0.3%，1%，分别对应100，500，3000，10000
        const fee = 3000
        await Factory.write.createPool([token0.address, token1.address, tickLower, tickUpper, fee])
        const createEvents = await Factory.getEvents.PoolCreated()
        const poolAddress: `0x${string}` = createEvents[0].args.pool || '0x'
        const Pool = await hviem.getContractAt('Pool' as string, poolAddress)
        // 初始化一个价格，按照 1个token0 = 10000个token1 来初始化
        const sqrtPriceX96 = await encodeSqrtRatioX96(10000, 1)
        await Pool.write.initialize([sqrtPriceX96])
        return {
            token0,
            token1,
            Factory,
            Pool,
            tickLower,
            tickUpper,
            fee,
            sqrtPriceX96: BigInt(sqrtPriceX96.toString())
        }
    }

    describe('Pool Info', async () => {
        it('should get pool info', async () => {
            const { Pool, token0, token1, tickLower, tickUpper, fee, sqrtPriceX96 } = await deployFactoryFixture()
            // 验证初始地址
            assert.equal(((await Pool.read.token0()) as string).toLocaleLowerCase(), token0.address)
            assert.equal(((await Pool.read.token1()) as string).toLocaleLowerCase(), token1.address)
            // 验证初始tick
            assert.equal(await Pool.read.tickLower(), tickLower)
            assert.equal(await Pool.read.tickUpper(), tickUpper)
            // 验证初始费率
            assert.equal(await Pool.read.fee(), fee)
            // 验证初始价格
            assert.equal(await Pool.read.sqrtPriceX96(), sqrtPriceX96)
        })

        it('mint and burn and collect', async () => {
            const { Pool, token0, token1, sqrtPriceX96 } = await deployFactoryFixture()
            const testLp = await hviem.deployContract('TestLP')

            const initBalanceValue = 10000n ** 18n
            await token0.write.mint([testLp.address, initBalanceValue])
            await token1.write.mint([testLp.address, initBalanceValue])

            await testLp.write.mint([testLp.address, 20000000n, Pool.address, token0.address, token1.address])

            // 验证余额
            assert.equal(
                await token0.read.balanceOf([Pool.address]),
                initBalanceValue - (await token0.read.balanceOf([testLp.address]))
            )
            assert.equal(
                await token1.read.balanceOf([Pool.address]),
                initBalanceValue - (await token1.read.balanceOf([testLp.address]))
            )

            // 验证lp余额
            const position = await Pool.read.positions([testLp.address])
            assert.deepEqual(position, [20000000n, 0n, 0n, 0n, 0n])
            assert.equal(await Pool.read.liquidity(), 20000000n)
            // 再铸造50000个lp
            await testLp.write.mint([testLp.address, 50000n, Pool.address, token0.address, token1.address])
            // 验证余额
            assert.equal(await Pool.read.liquidity(), 20050000n)
            // 验证lp余额
            assert.equal(
                await token0.read.balanceOf([Pool.address]),
                initBalanceValue - (await token0.read.balanceOf([testLp.address]))
            )
            assert.equal(
                await token1.read.balanceOf([Pool.address]),
                initBalanceValue - (await token1.read.balanceOf([testLp.address]))
            )

            // 销毁lp 10000个
            await testLp.write.burn([10000n, Pool.address])
            // 验证余额
            assert.equal(await Pool.read.liquidity(), 20040000n)

            // create new LP
            const testLP2 = await hviem.deployContract('TestLP')
            await token0.write.mint([testLP2.address, initBalanceValue])
            await token1.write.mint([testLP2.address, initBalanceValue])
            await testLP2.write.mint([testLP2.address, 3000n, Pool.address, token0.address, token1.address])
            assert.equal(await Pool.read.liquidity(), 20043000n)

            const totalToken0 =
                initBalanceValue -
                (await token0.read.balanceOf([testLp.address])) +
                (initBalanceValue - (await token0.read.balanceOf([testLP2.address])))
            // 验证余额(token0 = LP1he LP2的token0余额之和)
            assert.equal(await token0.read.balanceOf([Pool.address]), totalToken0)

            // burn all LP
            await testLp.write.burn([20040000n, Pool.address])
            // 验证余额
            assert.equal(await Pool.read.liquidity(), 3000n)
            // 判断池子余额,burn只返回流动性不返回token
            assert.equal(await token0.read.balanceOf([Pool.address]), totalToken0)
            // collect，返回所有余额
            await testLp.write.collect([testLp.address, Pool.address])
            //
            assert.ok(Number(initBalanceValue - (await token0.read.balanceOf([testLp.address]))) < 10)
            assert.ok(Number(initBalanceValue - (await token1.read.balanceOf([testLp.address]))) < 10)
        })

        it('swap', async () => {
            const { Pool, token0, token1, sqrtPriceX96 } = await deployFactoryFixture()
            const testLP = await hviem.deployContract('TestLP')

            const initBalanceValue = 10000n ** 18n
            await token0.write.mint([testLP.address, initBalanceValue])
            await token1.write.mint([testLP.address, initBalanceValue])
            // 多准备一些流动性，防止swap时不够
            const liquidityDelta = 1000000000000000000000000000n
            const hash = await testLP.write.mint([
                testLP.address,
                liquidityDelta,
                Pool.address,
                token0.address,
                token1.address
            ])
            // 验证余额
            assert.equal(
                await token0.read.balanceOf([Pool.address]),
                initBalanceValue - (await token0.read.balanceOf([testLP.address]))
            )
            assert.equal(
                await token1.read.balanceOf([Pool.address]),
                initBalanceValue - (await token1.read.balanceOf([testLP.address]))
            )

            // 验证lp余额
            const position = await Pool.read.positions([testLP.address])
            assert.deepEqual(position, [liquidityDelta, 0n, 0n, 0n, 0n])

            const LPToken0 = await token0.read.balanceOf([testLP.address])
            assert.equal(LPToken0, 999999999999999999999999999999999999999999999995000161384542080378486216n)

            const LPToken1 = await token1.read.balanceOf([testLP.address])
            assert.equal(LPToken1, 999999999999999999999999999999999999999999901000000000000000000000000000n)
            // 通过testswap触发交易
            const TestSwap = await hviem.deployContract('TestSwap')
            const minPrice = 1000
            const minSqrtPricex96 = BigInt(encodeSqrtRatioX96(minPrice, 1).toString())
            // 给testswap一些token0
            await token0.write.mint([TestSwap.address, 300n * 10n ** 18n])
            // 验证余额
            assert.equal(await token0.read.balanceOf([TestSwap.address]), 300n * 10n ** 18n)
            assert.equal(await token1.read.balanceOf([TestSwap.address]), 0n)
            // swap
            const res = await TestSwap.write.testSwap([
                TestSwap.address,
                100n * 10n ** 18n,
                minSqrtPricex96,
                Pool.address,
                token0.address,
                token1.address
            ])
            const costToken0 = 300n * 10n ** 18n - (await token0.read.balanceOf([TestSwap.address]))
            const receivedToken1 = await token1.read.balanceOf([TestSwap.address])
            const newPrice = (await Pool.read.sqrtPriceX96()) as bigint
            const liquidity = await Pool.read.liquidity()
            // log('costToken0', costToken0)
            // log('receivedToken1', receivedToken1)
            // log('newPrice', newPrice)
            // log('liquidity', liquidity)
            // log('sqrtPriceX96 - newPrice', sqrtPriceX96 - newPrice)
            assert.equal(newPrice, 7922737261735934252089901697281n)
            assert.equal(sqrtPriceX96 - newPrice, 78989690499507264493336319n)
            assert.equal(liquidity, liquidityDelta)
            assert.equal(costToken0, 1000n ** 18n)
            assert.equal(receivedToken1, 996990060009101709255958n)
            // 提取流动性
            await testLP.write.burn([liquidityDelta, Pool.address])
            assert.equal(await token0.read.balanceOf([testLP.address]), initBalanceValue)
        })
    })
})
