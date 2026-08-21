// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIrm} from "./interfaces/IIrm.sol";

/// @title LinearIrm — a simple, immutable linear (kink-free) interest rate model.
/// @notice borrowRate = baseRate + slope * utilization, where utilization = borrow/supply (1e18).
///         All parameters are immutable and bounded at construction, so the rate a market charges
///         can never be changed after deployment.
contract LinearIrm is IIrm {
    uint256 internal constant WAD = 1e18;
    /// @notice Hard ceiling on the per-second rate this IRM can ever return (~ up to a few
    ///         hundred % APR at full utilization); guards against a misconfigured deployment.
    uint256 public constant MAX_RATE_PER_SECOND = uint256(10e18) / 365 days; // ~1000% APR ceiling

    uint256 public immutable baseRatePerSecond;
    uint256 public immutable slopePerSecond;

    error RateTooHigh();

    constructor(uint256 baseRatePerSecond_, uint256 slopePerSecond_) {
        if (baseRatePerSecond_ + slopePerSecond_ > MAX_RATE_PER_SECOND) revert RateTooHigh();
        baseRatePerSecond = baseRatePerSecond_;
        slopePerSecond = slopePerSecond_;
    }

    function borrowRatePerSecond(uint256 totalSupplyAssets, uint256 totalBorrowAssets) external view returns (uint256) {
        if (totalSupplyAssets == 0) return baseRatePerSecond;
        uint256 utilization = totalBorrowAssets * WAD / totalSupplyAssets; // 1e18-scaled, <= 1e18
        if (utilization > WAD) utilization = WAD;
        return baseRatePerSecond + slopePerSecond * utilization / WAD;
    }
}
