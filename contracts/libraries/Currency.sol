// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

type Currency is address;

using {greaterThan as >, lessThan as <, greaterThanOrEqualTo as >=, equals as ==} for Currency global;
using CurrencyLibrary for Currency global;

function equals(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) == Currency.unwrap(other);
}

function greaterThan(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) > Currency.unwrap(other);
}

function lessThan(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) < Currency.unwrap(other);
}

function greaterThanOrEqualTo(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) >= Currency.unwrap(other);
}
/**
 * @title CurrencyLibrary
 * @dev This library allows for transferring and holding native tokens and ERC20 tokens
 */

library CurrencyLibrary {
    /**
     * @notice Thrown when native transfer fails
     */
    error NativeTransferFailed();

    /// @notice Thrown when an ERC20 transfer fails
    error ERC20TransferFailed();

    /**
     * @notice Thrown when an ERC20 TrasnaferFrom fails
     */
    error ERC20TransferFromFailed();

    /**
     * @notice Thrown when an ERC20 Approve fails
     */
    error ERC20ApproveFailed();

    /// @notice A constant to represent the native currency
    Currency public constant ADDRESS_ZERO = Currency.wrap(address(0));

    function nativeTransfer(address to, uint256 amount) internal {
        bool success;

        assembly ("memory-safe") {
            // Transfer the ETH and revert if it fails.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }
        // revert with NativeTransferFailed
        if (!success) revert NativeTransferFailed();
    }

    function tokenTransfer(Currency currency, address to, uint256 amount) internal {
        bool success;

        assembly ("memory-safe") {
            // Get a pointer to some free memory.
            let fmp := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(fmp, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(fmp, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(fmp, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success :=
                and(
                    // Set success to whether the call reverted, if not we check it either
                    // returned exactly 1 (can't just be non-zero data), or had no return data.
                    or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                    // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                    // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                    // Counterintuitively, this call must be positioned second to the or() call in the
                    // surrounding and() call or else returndatasize() will be zero during the computation.
                    call(gas(), currency, 0, fmp, 68, 0, 32)
                )

            // Now clean the memory we used
            mstore(fmp, 0) // 4 byte `selector` and 28 bytes of `to` were stored here
            mstore(add(fmp, 0x20), 0) // 4 bytes of `to` and 28 bytes of `amount` were stored here
            mstore(add(fmp, 0x40), 0) // 4 bytes of `amount` were stored here
        }
        // revert with ERC20TransferFailed
        if (!success) revert ERC20TransferFailed();
    }

    function transfer(Currency currency, address to, uint256 amount) internal {
        // altered from https://github.com/transmissions11/solmate/blob/44a9963d4c78111f77caa0e65d677b8b46d6f2e6/src/utils/SafeTransferLib.sol
        // modified custom error selectors

        if (currency.isNative()) {
            nativeTransfer(to, amount);
        } else {
            tokenTransfer(currency, to, amount);
        }
    }

    function safeTransferFrom(Currency currency, address from, address to, uint256 amount) internal {
        bool success;
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x60, amount) // Store the `amount` argument.
            mstore(0x40, to) // Store the `to` argument.
            mstore(0x2c, shl(96, from)) // Store the `from` argument.
            mstore(0x0c, 0x23b872dd000000000000000000000000) // `transferFrom(address,address,uint256)`.
            success :=
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), currency, 0, 0x1c, 0x64, 0x00, 0x20)
                )
            mstore(0x60, 0) // Restore the zero slot to zero.
            mstore(0x40, m) // Restore the free memory pointer.
        }

        // revert with ERC20TransferFromFailed
        if (!success) revert ERC20TransferFromFailed();
    }

    function safeApprove(Currency currency, address to, uint256 amount) internal {
        bool success;
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x14, to) // Store the `to` argument.
            mstore(0x34, amount) // Store the `amount` argument.
            mstore(0x00, 0x095ea7b3000000000000000000000000) // `approve(address,uint256)`.

            success :=
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), currency, 0, 0x10, 0x44, 0x00, 0x20)
                )

            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }

        // revert with ERC20ApproveFailed
        if (!success) revert ERC20ApproveFailed();
    }

    function balanceOf(Currency currency, address account) internal view returns (uint256) {
        if (currency.isNative()) {
            return account.balance;
        } else {
            return IERC20Metadata(Currency.unwrap(currency)).balanceOf(account);
        }
    }

    function balanceOfSelf(Currency currency) internal view returns (uint256) {
        return balanceOf(currency, address(this));
    }

    function decimals(Currency currency) internal view returns (uint8) {
        return IERC20Metadata(Currency.unwrap(currency)).decimals();
    }

    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == Currency.unwrap(ADDRESS_ZERO);
    }
}
