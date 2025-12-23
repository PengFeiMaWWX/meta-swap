// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract TToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address recipient, uint256 quantity) public payable {
        require(quantity > 0, 'TToken: mint quantity should be positive');
        _mint(recipient, quantity);
    }
}
