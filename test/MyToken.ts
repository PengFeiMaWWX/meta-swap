import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { parseEther } from 'viem'

import { network } from 'hardhat'
import { log } from 'node:console'

describe('MyToken', async () => {
    const { viem: hviem, networkHelpers } = await network.connect()
    const publicClient = await hviem.getPublicClient()

    async function deploayFixture() {
        const token = await hviem.deployContract('MyToken')
        return { token }
    }

    describe('MyToken deployment', () => {
        it('gets the name', async () => {
            const { token } = await networkHelpers.loadFixture(deploayFixture)
            const name = await token.read.name()
            assert.equal(name, 'MyToken')
        })
    })
})
