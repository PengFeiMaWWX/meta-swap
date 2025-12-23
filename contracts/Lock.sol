// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract Lock {
    uint256 public unlockTime;
    address payable public owner;

    event Withdrawal(uint256 amount, uint256 when);

    constructor(uint256 _unlockTime) payable {
        require(block.timestamp < _unlockTime, 'Unlock time should be in the future');

        unlockTime = _unlockTime;
        owner = payable(msg.sender);
    }

    function withdraw() public {
        require(msg.sender == owner, 'You are not the owner');
        require(block.timestamp >= unlockTime, 'You cannot withdraw yet');

        emit Withdrawal(address(this).balance, block.timestamp);

        owner.transfer(address(this).balance);
    }
}
