// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {Currency} from "../libraries/Currency.sol";

interface IGrailDollar {
    /// @notice Revert when amount is either zero or less than LOT_AMOUNT
    error InvalidAmount();

    /// @notice Revert when trying to set peer for an endpoint ID already set
    error PeerExist();

    /// @notice Revert when trying to redeem when chain has insufficient liquidity
    error InsufficientLiquidity();

    /// @notice Revert when not called by authorized protocol minter
    error OnlyMinterAllowed();

    /// @notice Revert when trying to recovered accepted currency
    error CannotRecoverCurrency();

    /**
     * @notice Emitted whenever an account mints GUSD
     */
    event Mint(address indexed account, uint256 amount);

    /**
     * @notice Emitted whenever an account burns GUSD
     * to redeem underlying asset
     */
    event Redeem(address indexed account, uint256 amount);

    /**
     * @notice Emitted whenever minter credit's GUSD reward
     */
    event CreditedTo(address indexed account, uint256 amount);

    /**
     * @notice Emitted whenever minter burns staked GUSD for wager
     */
    event DebitedFrom(address indexed account, uint256 amount);

    /**
     * @notice Emitted when minter account is added
     */
    event AddMinter(address indexed minter);

    /**
     * @dev Allows anyone to mint GUSD by locking the mint price
     * amount of the chains accepted stable coin
     *
     */
    function mint() external;

    /**
     * @dev Allows anyone to redeem the underlying stable coin by burning an equivalent
     * GUSD amount
     *
     * @param amount the amount of GUSD to redeem in 6 decimals
     */
    function redeem(uint256 amount) external;

    /**
     * @dev Allow prediction market to mint reward to users
     *
     * @param account the account address
     * @param amount the amount in 6 decimals
     */
    function creditTo(address account, uint256 amount) external returns (bool);

    /**
     * @dev Allow prediction market to burn stake
     *
     * @param account the account address
     * @param amount the amount in 6 decimals
     */
    function debitFrom(address account, uint256 amount) external returns (bool);

    /**
     * @notice useful for recovering native/local tokens sent to the contract by mistake
     *
     * @param recoveredCurrency address of token to withdraw
     * @param recipient address of token receiver
     * @param amount the amount to recover
     */
    function recoverToken(Currency recoveredCurrency, address recipient, uint256 amount) external;
}
