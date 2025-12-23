import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

export default buildModule('SwapModule', (m) => {
    const PoolManager = m.contract('PoolManager')
    const SwapRouter = m.contract('SwapRouter', [PoolManager])
    const PositionManager = m.contract('PositionManager', [PoolManager])
    return {
        PoolManager,
        SwapRouter,
        PositionManager
    }
})
