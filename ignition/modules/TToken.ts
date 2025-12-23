import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

export default buildModule('TTokenModule', (m) => {
    const TTokenA = m.contract('TToken', ['TToken A', 'TTA'], { id: 'TTokenA' })
    const TTokenB = m.contract('TToken', ['TToken B', 'TTB'], { id: 'TTokenB' })
    const TTokenC = m.contract('TToken', ['TToken C', 'TTC'], { id: 'TTokenC' })
    const TTokenD = m.contract('TToken', ['TToken D', 'TTD'], { id: 'TTokenD' })
    return {
        TTokenA,
        TTokenB,
        TTokenC,
        TTokenD
    }
})
