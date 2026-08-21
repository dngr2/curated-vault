// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Interest rate model: returns the per-second borrow rate (1e18-scaled) for a market
///         given its current supply/borrow totals.
interface IIrm {
    function borrowRatePerSecond(uint256 totalSupplyAssets, uint256 totalBorrowAssets) external view returns (uint256);
}
