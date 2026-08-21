// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IIrm} from "./interfaces/IIrm.sol";

/// @title LendingMarket — a minimal, immutable, isolated lending market (Morpho-Blue-style).
/// @notice One market = one collateral asset + one loan asset + one oracle + one LLTV + one IRM,
///         all fixed at construction. Lenders supply the loan asset for yield; borrowers post
///         collateral and borrow the loan asset up to `lltv` of their collateral's value. The
///         market is a standalone contract holding only its own funds, so it is isolated at the
///         contract level — a failure in one market cannot touch another.
///
/// @dev Design guarantees:
///      - Immutable parameters: no governance, no upgrade, no admin path to user funds. The only
///        privileged party is the fee recipient, whose fee is a bounded share of interest and can
///        never reach principal.
///      - Share accounting uses virtual shares/assets (Morpho-style) so the lender share price is
///        defined from empty and the first-depositor inflation attack is neutralized.
///      - Rounding always favors the market/lenders: debt rounds up, supplied-share credit rounds
///        down, withdrawals burn shares rounded up.
///      - 18-decimal loan and collateral tokens are assumed (documented); the oracle returns the
///        price of 1e18 collateral in loan units, 1e18-scaled.
contract LendingMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    /// @notice Max fee on interest (25%). Bounded at construction; fee is on interest only.
    uint256 public constant MAX_FEE = 0.25e18;
    /// @notice Liquidation incentive factor: liquidators receive 5% more collateral value than the
    ///         debt they repay. Fixed and bounded.
    uint256 public constant LIQUIDATION_INCENTIVE = 1.05e18;

    IERC20 public immutable loanToken;
    IERC20 public immutable collateralToken;
    IOracle public immutable oracle;
    IIrm public immutable irm;
    uint256 public immutable lltv; // loan-to-value, 1e18-scaled, < 1e18

    address public immutable feeRecipient;
    uint256 public immutable fee; // share of interest to feeRecipient, 1e18-scaled, <= MAX_FEE

    // Market totals.
    uint256 public totalSupplyAssets;
    uint256 public totalSupplyShares;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastUpdate;

    struct Position {
        uint256 supplyShares;
        uint256 borrowShares;
        uint256 collateral;
    }

    mapping(address => Position) public positions;

    event Supply(address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares
    );
    event Borrow(
        address indexed caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares
    );
    event Repay(address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
    event SupplyCollateral(address indexed caller, address indexed onBehalf, uint256 amount);
    event WithdrawCollateral(
        address indexed caller, address indexed onBehalf, address indexed receiver, uint256 amount
    );
    event Liquidate(
        address indexed liquidator, address indexed borrower, uint256 repaidAssets, uint256 seized, uint256 badDebt
    );
    event AccrueInterest(uint256 interest, uint256 feeShares);

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientLiquidity();
    error Unhealthy();
    error HealthyPosition();
    error InconsistentInput();
    error LltvTooHigh();
    error FeeTooHigh();

    constructor(
        IERC20 loanToken_,
        IERC20 collateralToken_,
        IOracle oracle_,
        IIrm irm_,
        uint256 lltv_,
        address feeRecipient_,
        uint256 fee_
    ) {
        if (
            address(loanToken_) == address(0) || address(collateralToken_) == address(0)
                || address(oracle_) == address(0) || address(irm_) == address(0)
        ) revert ZeroAddress();
        if (lltv_ >= WAD) revert LltvTooHigh();
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        if (fee_ > 0 && feeRecipient_ == address(0)) revert ZeroAddress();
        loanToken = loanToken_;
        collateralToken = collateralToken_;
        oracle = oracle_;
        irm = irm_;
        lltv = lltv_;
        feeRecipient = feeRecipient_;
        fee = fee_;
        lastUpdate = block.timestamp;
    }

    // --- share math (virtual-shares, Morpho-style) ---

    function _toSharesDown(uint256 assets, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return assets.mulDiv(tShares + VIRTUAL_SHARES, tAssets + VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    function _toSharesUp(uint256 assets, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return assets.mulDiv(tShares + VIRTUAL_SHARES, tAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil);
    }

    function _toAssetsDown(uint256 shares, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return shares.mulDiv(tAssets + VIRTUAL_ASSETS, tShares + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    function _toAssetsUp(uint256 shares, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return shares.mulDiv(tAssets + VIRTUAL_ASSETS, tShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    // --- interest accrual ---

    /// @notice Accrue interest since lastUpdate: grows borrow + supply assets, mints fee shares.
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return;
        uint256 borrowAssets = totalBorrowAssets;
        if (borrowAssets != 0) {
            uint256 rate = irm.borrowRatePerSecond(totalSupplyAssets, borrowAssets);
            uint256 interest = borrowAssets.mulDiv(rate * elapsed, WAD, Math.Rounding.Floor);
            totalBorrowAssets = borrowAssets + interest;
            totalSupplyAssets += interest;
            uint256 feeShares;
            if (fee != 0 && interest != 0) {
                uint256 feeAssets = interest.mulDiv(fee, WAD, Math.Rounding.Floor);
                // fee as supply shares against post-interest supply (excluding the fee itself)
                feeShares = _toSharesDown(feeAssets, totalSupplyAssets - feeAssets, totalSupplyShares);
                positions[feeRecipient].supplyShares += feeShares;
                totalSupplyShares += feeShares;
            }
            emit AccrueInterest(interest, feeShares);
        }
        lastUpdate = block.timestamp;
    }

    // --- lender side ---

    function supply(uint256 assets, address onBehalf) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();
        accrueInterest();
        shares = _toSharesDown(assets, totalSupplyAssets, totalSupplyShares);
        positions[onBehalf].supplyShares += shares;
        totalSupplyShares += shares;
        totalSupplyAssets += assets;
        loanToken.safeTransferFrom(msg.sender, address(this), assets);
        emit Supply(msg.sender, onBehalf, assets, shares);
    }

    /// @notice Withdraw supplied loan assets. Exactly one of (assets, shares) must be non-zero.
    function withdraw(uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        nonReentrant
        returns (uint256 assetsOut, uint256 sharesBurned)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if ((assets == 0) == (shares == 0)) revert InconsistentInput();
        accrueInterest();
        if (assets > 0) {
            sharesBurned = _toSharesUp(assets, totalSupplyAssets, totalSupplyShares);
            assetsOut = assets;
        } else {
            sharesBurned = shares;
            assetsOut = _toAssetsDown(shares, totalSupplyAssets, totalSupplyShares);
        }
        positions[onBehalf].supplyShares -= sharesBurned; // reverts on underflow if > owned
        totalSupplyShares -= sharesBurned;
        totalSupplyAssets -= assetsOut;
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        loanToken.safeTransfer(receiver, assetsOut);
        emit Withdraw(msg.sender, onBehalf, receiver, assetsOut, sharesBurned);
    }

    // --- borrower side ---

    function supplyCollateral(uint256 amount, address onBehalf) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();
        positions[onBehalf].collateral += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit SupplyCollateral(msg.sender, onBehalf, amount);
    }

    function withdrawCollateral(uint256 amount, address onBehalf, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();
        positions[onBehalf].collateral -= amount;
        if (!_isHealthy(onBehalf)) revert Unhealthy();
        collateralToken.safeTransfer(receiver, amount);
        emit WithdrawCollateral(msg.sender, onBehalf, receiver, amount);
    }

    function borrow(uint256 assets, address onBehalf, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();
        shares = _toSharesUp(assets, totalBorrowAssets, totalBorrowShares);
        positions[onBehalf].borrowShares += shares;
        totalBorrowShares += shares;
        totalBorrowAssets += assets;
        if (!_isHealthy(onBehalf)) revert Unhealthy();
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        loanToken.safeTransfer(receiver, assets);
        emit Borrow(msg.sender, onBehalf, receiver, assets, shares);
    }

    /// @notice Repay debt. Exactly one of (assets, shares) must be non-zero.
    function repay(uint256 assets, uint256 shares, address onBehalf)
        external
        nonReentrant
        returns (uint256 assetsPaid, uint256 sharesRepaid)
    {
        if (onBehalf == address(0)) revert ZeroAddress();
        if ((assets == 0) == (shares == 0)) revert InconsistentInput();
        accrueInterest();
        if (assets > 0) {
            sharesRepaid = _toSharesDown(assets, totalBorrowAssets, totalBorrowShares);
            assetsPaid = assets;
        } else {
            sharesRepaid = shares;
            assetsPaid = _toAssetsUp(shares, totalBorrowAssets, totalBorrowShares);
        }
        positions[onBehalf].borrowShares -= sharesRepaid;
        totalBorrowShares -= sharesRepaid;
        totalBorrowAssets -= assetsPaid;
        loanToken.safeTransferFrom(msg.sender, address(this), assetsPaid);
        emit Repay(msg.sender, onBehalf, assetsPaid, sharesRepaid);
    }

    // --- liquidation ---

    /// @notice Liquidate an unhealthy borrower by seizing `seizedCollateral`; the liquidator repays
    ///         the corresponding debt (discounted by the liquidation incentive). If the seizure
    ///         empties the borrower's collateral while debt remains, the residual is socialized as
    ///         bad debt across lenders (totalSupplyAssets reduced), and the borrower's remaining
    ///         borrow shares are cleared.
    function liquidate(address borrower, uint256 seizedCollateral)
        external
        nonReentrant
        returns (uint256 repaidAssets, uint256 badDebt)
    {
        if (seizedCollateral == 0) revert ZeroAmount();
        accrueInterest();
        if (_isHealthy(borrower)) revert HealthyPosition();

        Position storage p = positions[borrower];
        uint256 price = oracle.price();

        // Value of seized collateral in loan units, discounted by the incentive → debt repaid.
        uint256 seizedValue = seizedCollateral.mulDiv(price, WAD, Math.Rounding.Floor);
        repaidAssets = seizedValue.mulDiv(WAD, LIQUIDATION_INCENTIVE, Math.Rounding.Floor);

        uint256 repaidShares = _toSharesDown(repaidAssets, totalBorrowAssets, totalBorrowShares);
        if (repaidShares > p.borrowShares) {
            // Cap the repayment to the borrower's full debt.
            repaidShares = p.borrowShares;
            repaidAssets = _toAssetsUp(repaidShares, totalBorrowAssets, totalBorrowShares);
        }
        if (seizedCollateral > p.collateral) revert InconsistentInput();

        p.borrowShares -= repaidShares;
        p.collateral -= seizedCollateral;
        totalBorrowShares -= repaidShares;
        totalBorrowAssets -= repaidAssets;

        // Bad-debt socialization: collateral fully seized but debt remains → write it off to lenders.
        if (p.collateral == 0 && p.borrowShares != 0) {
            badDebt = _toAssetsUp(p.borrowShares, totalBorrowAssets, totalBorrowShares);
            totalBorrowShares -= p.borrowShares;
            totalBorrowAssets -= badDebt;
            totalSupplyAssets -= badDebt; // lenders absorb the loss
            p.borrowShares = 0;
        }

        collateralToken.safeTransfer(msg.sender, seizedCollateral);
        loanToken.safeTransferFrom(msg.sender, address(this), repaidAssets);
        emit Liquidate(msg.sender, borrower, repaidAssets, seizedCollateral, badDebt);
    }

    // --- health / views ---

    function _isHealthy(address borrower) internal view returns (bool) {
        Position storage p = positions[borrower];
        if (p.borrowShares == 0) return true;
        uint256 borrowed = _toAssetsUp(p.borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = p.collateral.mulDiv(oracle.price(), WAD, Math.Rounding.Floor);
        uint256 maxBorrow = collateralValue.mulDiv(lltv, WAD, Math.Rounding.Floor);
        return borrowed <= maxBorrow;
    }

    function isHealthy(address borrower) external view returns (bool) {
        return _isHealthy(borrower);
    }

    /// @notice Current debt of a borrower in loan assets (rounded up), at the live state.
    function borrowAssetsOf(address borrower) external view returns (uint256) {
        return _toAssetsUp(positions[borrower].borrowShares, totalBorrowAssets, totalBorrowShares);
    }

    /// @notice Current redeemable value of a lender's supply shares (rounded down).
    function supplyAssetsOf(address lender) external view returns (uint256) {
        return _toAssetsDown(positions[lender].supplyShares, totalSupplyAssets, totalSupplyShares);
    }
}
