import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { network } from 'hardhat'

describe('Factory', async () => {
    const { viem: hviem, networkHelpers } = await network.connect()
    const publicClient = await hviem.getPublicClient()

    const deployFactoryFixture = async () => {
        const Factory = await hviem.deployContract('Factory')
        return { Factory }
    }

    describe('Factory functions', async () => {
        it('Should create a new pool', async () => {
            const { Factory } = await deployFactoryFixture()
            const tokenA: `0x${string}` = '0x0000000000000000000000000000000000000001'
            const tokenB: `0x${string}` = '0x0000000000000000000000000000000000000002'

            const hash = await Factory.write.createPool([tokenA, tokenB, 1, 100000, 3000])
            const receipt = await publicClient.waitForTransactionReceipt({ hash })
            const createEvents = await Factory.getEvents.PoolCreated()

            assert.ok(createEvents.length === 1)
            const evnet = createEvents[0]
            if (evnet.args.token0) {
                assert.match(evnet.args.token0, /^0x[a-fA-F0-9]{40}$/)
            }
            if (evnet.args.token1) {
                assert.match(evnet.args.token1, /^0x[a-fA-F0-9]{40}$/)
            }
            assert.equal(evnet.args.tickLower, 1)
            assert.equal(evnet.args.tickUpper, 100000)
            assert.equal(evnet.args.fee, 3000)

            const poolAddress = await Factory.simulate.createPool([tokenA, tokenB, 1, 100000, 3000])
            assert.match(poolAddress.result, /^0x[a-fA-F0-9]{40}$/)
            assert.equal(evnet.args.pool, poolAddress.result)
        })

        it('Should create a new pool with some token', async () => {
            const { Factory } = await deployFactoryFixture()
            const tokenA: `0x${string}` = '0x0000000000000000000000000000000000000001'
            const tokenB: `0x${string}` = '0x0000000000000000000000000000000000000001'

            await hviem.assertions.revertWith(
                Factory.write.createPool([tokenA, tokenB, 1, 100000, 3000]),
                'Identical addresses'
            )

            await hviem.assertions.revertWith(Factory.read.getPool([tokenA, tokenB, 3]), 'Identical addresses')
        })
    })
})
