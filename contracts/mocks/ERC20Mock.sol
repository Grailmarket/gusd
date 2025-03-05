// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    uint8 private _decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimal) ERC20(_name, _symbol) {
        _decimals = _decimal;
    }

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
