// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {GUSD} from "../GUSD.sol";
import {Currency} from "../libraries/Currency.sol";

// @dev WARNING: This is for testing purposes only
contract GUSDMock is GUSD {
    constructor(Currency _currency, address _minter, address _lzEndpoint, address _delegate)
        GUSD(_currency, _minter, _lzEndpoint, _delegate)
    {}

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }
}
