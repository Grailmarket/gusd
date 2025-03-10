// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

interface IProtocolFees {
    /// @notice Revert when protocol fee exceeds maximum allowed
    error FeeTooLarge(uint16 fee);

    /// @notice Revert when trying to claim more than the accrued fee
    error AmountExceedsAccruedFee();

    /**
     * @dev Emitted when the protocol manager collects accrued fees
     */
    event CollectFee(address indexed collector, address indexed recipient, uint256 amount);

    /**
     * @dev Emitted when a new protocol fee is set
     */
    event SetProtocolFee(uint16 newFee);

    /**
     * @dev Allows protocol managers to collect accrued fee
     *
     * @param recipient address to forward fund to
     * @param amount amount in local currency decimals
     */
    function collectProtocolFee(address recipient, uint256 amount) external;

    /**
     * @dev Allows protocol managers to set minting fee
     *
     * @param fee the fee in BPS
     */
    function setProtocolFee(uint16 fee) external;
}
