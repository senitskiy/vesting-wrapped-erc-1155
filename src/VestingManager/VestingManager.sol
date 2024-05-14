// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./Ownable.sol";

import "./interfaces/IVestingManager.sol";

contract VestingManager is IVestingManager, Ownable {

    uint64 public start;
    uint64 public duration;

    constructor() {
        start = type(uint64).max;
        duration = type(uint64).max;
    }

    function setStart(uint64 start_) public override virtual onlyOwner {
        start = start_;
    }

    function setDuration(uint64 duration_) public override virtual onlyOwner {
        duration = duration_;
    }
}