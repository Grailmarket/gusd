// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Currency} from "../../contracts/libraries/Currency.sol";
import {GUSD} from "../../contracts/GUSD.sol";

contract GUSDMock is GUSD {
    constructor(address _owner, Currency _currency, address _minter, uint32 _governanceEid, address _lzEndpoint)
        GUSD(_owner, _currency, _minter, _governanceEid, _lzEndpoint)
    {}

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function addPeer(uint32 _eid, bytes32 _peer) public {
        _setPeer(_eid, _peer);
    }
}
