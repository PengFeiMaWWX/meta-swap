import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

export default buildModule('MyTokenModule', (m) => {
    const MyToken = m.contract('MyToken')
    return {
        MyToken
    }
})
