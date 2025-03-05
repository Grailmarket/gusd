// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {IGrailDollar} from "./interfaces/IGrailDollar.sol";
import {Currency} from "./libraries/Currency.sol";

contract GrailDollar is IGrailDollar, OFT {
    /// @dev store stable coin accepted
    Currency public immutable currency;

    /// @dev store the GUSD conversion rate
    uint8 public immutable gusdConversionRate;

    /// @dev store the decimal conversion rate
    uint256 public immutable currencyConversionRate;

    /// @dev store the mint price per lot amount
    uint256 public immutable mintPrice;

    /// @dev store the minting rate
    uint256 public constant LOT_AMOUNT = 1_000 * 10 ** 6; // 1000 GUSD

    /// @dev store the grail market minter address
    address public immutable minter;

    constructor(Currency _currency, address _minter, address _lzEndpoint, address _delegate)
        OFT("Grail Dollar", "GUSD", _lzEndpoint, _delegate)
        Ownable(_delegate)
    {
        currency = _currency;
        minter = _minter;
        uint8 _decimals = _currency.decimals();

        gusdConversionRate = 100; // mint price * 100 = 1000
        currencyConversionRate = 10 ** (_decimals - sharedDecimals());
        mintPrice = 10 * 10 ** _decimals; // 10 USD

        emit AddMinter(_minter);
    }

    /// @inheritdoc IGrailDollar
    function mint() external override {
        // pull the deposit
        currency.safeTransferFrom(msg.sender, address(this), mintPrice);
        // credit the user balance
        _mint(msg.sender, LOT_AMOUNT);
        emit Mint(msg.sender, LOT_AMOUNT);
    }

    /// @inheritdoc IGrailDollar
    function redeem(uint256 amount) external override {
        uint256 balance = currency.balanceOfSelf();

        if (amount == 0 || amount < gusdConversionRate) revert InvalidAmount();
        uint256 amountLD = _previewRedeem(amount);

        if (balance < amountLD) revert InsufficientLiquidity();

        // @dev Default OFT burns on src before redemption
        _burn(msg.sender, amount);
        currency.transfer(msg.sender, amountLD);

        emit Redeem(msg.sender, amount);
    }

    /// @inheritdoc IGrailDollar
    function credit(address account, uint256 amount) external override returns (bool) {
        if (msg.sender != minter) revert OnlyMinterAllowed();

        _mint(account, amount);
        emit Credit(account, amount);

        return true;
    }

    /// @inheritdoc IGrailDollar
    function debit(address account, uint256 amount) external override returns (bool) {
        if (msg.sender != minter) revert OnlyMinterAllowed();

        _burn(account, amount);
        emit Debit(account, amount);

        return true;
    }

    /// @inheritdoc IGrailDollar
    function recoverToken(Currency recoveredCurrency, address recipient, uint256 amount) external override onlyOwner {
        if (currency == recoveredCurrency) revert CannotRecoverCurrency();

        uint256 recoveredAmount;
        if (amount == 0) {
            recoveredAmount = currency.balanceOfSelf();
        }

        currency.transfer(recipient, recoveredAmount);
    }

    function setPeer(uint32 _eid, bytes32 _peer) public override onlyOwner {
        if (peers[_eid] != bytes32(0)) revert PeerExist();

        _setPeer(_eid, _peer);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @dev Internal function to convert an amount from shared decimals into local decimals.
     * @param _amountSD The amount in shared decimals.
     * @return amountLD The amount in local decimals.
     */
    function _previewRedeem(uint256 _amountSD) private view returns (uint256 amountLD) {
        return (_amountSD / gusdConversionRate) * currencyConversionRate;
    }
}
