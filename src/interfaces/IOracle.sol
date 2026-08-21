// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Price of the collateral asset denominated in the loan asset.
/// @dev Returns how many loan-token units (1e18-scaled) one whole unit (1e18) of collateral is
///      worth. Both tokens are assumed to be 18 decimals in this reference implementation.
///      The oracle is a trusted input to the market; a wrong/manipulable feed is the primary
///      external risk of any lending market and is the market creator's responsibility to choose.
interface IOracle {
    function price() external view returns (uint256);
}
