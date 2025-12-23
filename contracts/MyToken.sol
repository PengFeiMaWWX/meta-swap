// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract MyToken is ERC721, Ownable {
    uint256 private _tokenId;

    constructor() ERC721('MyToken', 'MTK') Ownable(msg.sender) {}

    function mint(uint256 quantity) public payable {
        require(quantity == 1, 'mint: can only mint one token at a time');
        require(msg.value == 0.01 ether, 'mint: must send exactly 0.01 ether');
        _tokenId++;
        _mint(msg.sender, _tokenId);
    }
}
