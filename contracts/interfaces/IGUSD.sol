// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {Currency} from "../libraries/Currency.sol";

interface IGUSD {
    /**
     * @dev Struct representing token parameters for the OFT send() operation.
     */
    struct SendParam {
        uint32 dstEid; // Destination endpoint ID.
        bytes32 to; // Recipient address.
        uint256 amount; // Amount to send in 6 decimals.
        bytes extraOptions; // Additional options supplied by the caller to be used in the LayerZero message.
    }

    /**
     * @dev Struct representing peer parameters for addPeers() operation
     */
    struct PeerConfig {
        uint32 eid;
        bytes32 peer;
    }

    /// @notice Revert when amount is either zero or less than LOT_AMOUNT
    error InvalidAmount();

    /// @notice Revert when config message does not originate from governance chain
    error OnlyGovernanceChainAllowed();

    /// @notice Revert when trying to redeem when chain has insufficient liquidity
    error InsufficientLiquidity();

    /// @notice Revert msg.value does not match expected total fee
    error InsufficientFee();

    /// @notice Revert when not called by authorized protocol minter
    error OnlyMinterAllowed();

    /// @notice Revert when trying to recovered accepted currency
    error CannotRecoverCurrency();

    /// @notice Revert when trying to claim more than the accrued fee
    error AmountExceedsAccruedFee();

    /// @notice Revert when protocol/mint fee exceeds maximum allowed
    error FeeTooLarge(uint16 fee);

    /// @notice Revert when function is disabled
    error FunctionDisabled();

    /**
     * @notice Emitted whenever an account mints GUSD
     */
    event Mint(address indexed account, uint256 amount, uint8 lotSize, uint256 totalCost);

    /**
     * @notice Emitted whenever an account burns GUSD
     * to redeem underlying asset
     */
    event Redeem(address indexed account, uint256 amount, uint256 amountLD);

    /**
     * @notice Emitted whenever minter credit's GUSD reward
     */
    event Credit(address indexed account, uint256 amount);

    /**
     * @notice Emitted whenever minter burns staked GUSD for wager
     */
    event Debit(address indexed account, uint256 amount);

    /**
     * @notice Emitted when minter account is added
     */
    event AddMinter(address indexed minter);

    /**
     * @dev Emitted when the protocol manager collects accrued mint fees
     */
    event CollectMintFee(address indexed collector, address indexed recipient, uint256 amount);

    /**
     * @dev Emitted when a new minting fee is set
     */
    event SetMintFee(uint16 newFee);

    /**
     * @notice Emitted whenever an account sends GUSD across chain
     */
    event OFTSent(bytes32 indexed guid, uint32 indexed dstEid, address indexed from, uint256 amount);

    /**
     * @notice Emitted whenever an account receive GUSD credit from remote chain
     */
    event OFTReceived(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount);

    /**
     * @dev Allows anyone to mint GUSD by locking the mint price
     * amount of the chains accepted stable coin
     *
     * @param lotSize the number of lot amount to buy
     * each lot is about 1_000 GUSD and cost about 5 USD
     *
     */
    function mint(uint8 lotSize) external payable;

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
    function credit(address account, uint256 amount) external returns (bool);

    /**
     * @dev Allow prediction market to burn stake
     *
     * @param account the account address
     * @param amount the amount in 6 decimals
     */
    function debit(address account, uint256 amount) external returns (bool);

    /**
     * @dev Allows protocol managers to collect accrued mint fee
     *
     * @param recipient address to forward fund to
     * @param amount amount in local currency decimals
     */
    function collectMintFee(address recipient, uint256 amount) external;

    /**
     * @dev Allows protocol managers to set minting fee
     *
     * @param fee the fee in BPS
     */
    function setMintFee(uint16 fee) external;

    /**
     * @notice useful for recovering native/local tokens sent to the contract by mistake
     *
     * @param recoveredCurrency address of token to withdraw
     * @param recipient address of token receiver
     * @param amount the amount to recover
     */
    function recoverToken(Currency recoveredCurrency, address recipient, uint256 amount) external;

    /**
     * @dev Allow protocol operator to add peers accross all supported chains
     *
     * @param peerConfigs an array of peer chain endpoint IDs and address to add
     * @param extraOptions additional options supplied by the caller to be used in the LayerZero message.
     */
    function addPeers(PeerConfig[] calldata peerConfigs, bytes calldata extraOptions) external payable;

    /**
     * @notice Executes the send() operation.
     * @param _sendParam The parameters for the send operation.
     * @param _fee The fee information supplied by the caller.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param _refundAddress The address to receive any excess funds from fees etc. on the src.
     * @return receipt The LayerZero messaging receipt from the send() operation.
     *
     * @dev MessagingReceipt: LayerZero msg receipt
     *  - guid: The unique identifier for the sent message.
     *  - nonce: The nonce of the sent message.
     *  - fee: The LayerZero fee incurred for the message.
     */
    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory);

    /**
     * @notice Provides a quote for the send() operation.
     * @param _sendParam The parameters for the send() operation.
     * @param _payInLzToken Flag indicating whether the caller is paying in the LZ token.
     * @return fee The calculated LayerZero messaging fee from the send() operation.
     *
     * @dev MessagingFee: LayerZero msg fee
     *  - nativeFee: The native fee.
     *  - lzTokenFee: The lzToken fee.
     */
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory fee);

    /**
     * @dev Allows calculation of required cost to mint a certain amount of GUSD
     *
     * @param lotSize the number of lot amount to buy
     * each lot is about 1_000 GUSD and cost about 5 USD
     * @return totalCost
     *
     */
    function quoteMint(uint8 lotSize) external view returns (uint256 totalCost);

    /**
     * @dev Used to get quote estimate for adding peers accross supported chains
     *
     * @param peerConfigs an array of peer chain endpoint IDs and address to add
     * @param extraOptions additional options supplied by the caller to be used in the LayerZero message.
     * @return fee The fee information supplied by the caller.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     */
    function quoteAddPeers(PeerConfig[] calldata peerConfigs, bytes calldata extraOptions)
        external
        view
        returns (MessagingFee memory fee);

    /**
     * @dev Allow fetching the users wallet and protocol balance in a single RPC call
     *
     * @param account the account address
     * @return currencyBalance the accepted currency balance of user
     * @return gusdBalance the GUSD wallet balance of user
     */
    function getBalances(address account) external view returns (uint256 currencyBalance, uint256 gusdBalance);
}
