import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'
import { parseEther } from 'viem'

export default buildModule('LockModule', (m) => {
    const unlockTime = m.getParameter('unlockTime', 1893456000)
    const lockedAmount = m.getParameter('lockedAmount', parseEther('0.001'))
    const lock = m.contract('Lock', [unlockTime], { value: lockedAmount })
    return { lock }
})
