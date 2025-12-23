import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { parseEther } from 'viem'

import { network } from 'hardhat'
import { log } from 'node:console'

describe('Lock', async function () {
    const { viem: hviem, networkHelpers } = await network.connect()
    const publicClient = await hviem.getPublicClient()

    async function deployLockFixture() {
        const ONE_YEAR_IN_SECONDS = 365n * 24n * 60n * 60n
        const lockedAmount = parseEther('1')
        const unlockTime = BigInt(Math.floor(Date.now() / 1000)) + ONE_YEAR_IN_SECONDS
        const [owner, user1] = await hviem.getWalletClients()
        log('Owner address:', await owner.account.address)
        log('User1 address:', await user1.account.address)
        const Lock = await hviem.deployContract('Lock', [unlockTime], { value: lockedAmount })
        return { Lock, unlockTime, lockedAmount, owner, user1 }
    }

    describe('Lock Deployment', async () => {
        it('Should set the right unlockTime', async () => {
            const { Lock, unlockTime } = await networkHelpers.loadFixture(deployLockFixture)
            assert.equal(unlockTime, await Lock.read.unlockTime())
        })

        it('Should receive and store the funds to lock', async () => {
            const { Lock, lockedAmount } = await networkHelpers.loadFixture(deployLockFixture)
            assert.equal(lockedAmount, await publicClient.getBalance({ address: Lock.address }))
        })

        it('Should fail if the unlockTime is not in the future', async () => {
            const latestTime = BigInt(await networkHelpers.time.latest())
            await hviem.assertions.revertWith(
                hviem.deployContract('Lock', [latestTime], { value: 1n }),
                'Unlock time should be in the future'
            )
        })
    })

    describe('Withdrawals', async () => {
        it('Should revert with the right error if called too soon', async () => {
            const { Lock, owner } = await networkHelpers.loadFixture(deployLockFixture)
            await hviem.assertions.revertWith(
                Lock.write.withdraw({ account: owner.account }),
                'You cannot withdraw yet'
            )
        })

        it('Should revert with the right error if called from another account', async () => {
            const { Lock, unlockTime, user1 } = await networkHelpers.loadFixture(deployLockFixture)
            await networkHelpers.time.increaseTo(unlockTime + 1n)
            await hviem.assertions.revertWith(Lock.write.withdraw({ account: user1.account }), 'You are not the owner')
        })

        it("shouldn't fail if the unlockTime has arrived and the owner calls it", async () => {
            const { Lock, unlockTime, owner } = await networkHelpers.loadFixture(deployLockFixture)
            await networkHelpers.time.increaseTo(unlockTime + 1n)
            await hviem.assertions.emit(Lock.write.withdraw({ account: owner.account }), Lock, 'Withdrawal')
        })
    })
})
