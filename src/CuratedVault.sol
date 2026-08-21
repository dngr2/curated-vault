// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LendingMarket} from "./LendingMarket.sol";

/// @title CuratedVault — a MetaMorpho-style curated allocator over isolated lending markets.
/// @notice An ERC-4626 vault whose asset is a loan token. A curator (owner) approves a set of
///         isolated `LendingMarket`s that all use this asset, assigns each a supply cap, and orders
///         a supply queue (where deposits flow) and a withdraw queue (where withdrawals pull from).
///         Passive depositors get a single, diversified, auto-allocated yield position across
///         several isolated markets — the market failure of any one is contained to its cap.
///
/// @dev Trust model:
///      - The curator chooses which markets and caps — a malicious curator can route deposits into
///        a bad market (up to its cap), but CANNOT withdraw depositor funds to itself: it holds no
///        privileged transfer path, only allocation policy. Depositors' downside is bounded by the
///        caps the curator sets, which are public. This is the MetaMorpho trust model, stated plainly.
///      - Inflation attack on deposit is defended by the virtual-shares offset.
///      - `totalAssets()` (a view) reads each market's last-accrued supply value, so a pure read can
///        lag until a market is poked. To prevent that lag from mispricing shares, every entry/exit
///        (`deposit`/`mint`/`withdraw`/`redeem`) first accrues interest on all tracked markets, so
///        shares are always minted/burned against a fresh NAV — no just-in-time interest skimming.
contract CuratedVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    LendingMarket[] public markets;
    mapping(address => bool) public isTracked;
    mapping(address => uint256) public cap;
    LendingMarket[] public supplyQueue;
    LendingMarket[] public withdrawQueue;

    event MarketAdded(address indexed market, uint256 cap);
    event CapSet(address indexed market, uint256 cap);
    event SupplyQueueSet(uint256 length);
    event WithdrawQueueSet(uint256 length);

    error AssetMismatch();
    error AlreadyTracked();
    error NotTracked(address market);
    error NotEnoughLiquidity();

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address curator_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(curator_)
    {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function marketsLength() external view returns (uint256) {
        return markets.length;
    }

    // --- curation (owner) ---

    /// @notice Approve a new market (must use this vault's asset) and set its supply cap.
    function addMarket(LendingMarket market, uint256 cap_) external onlyOwner {
        if (address(market.loanToken()) != asset()) revert AssetMismatch();
        if (isTracked[address(market)]) revert AlreadyTracked();
        isTracked[address(market)] = true;
        markets.push(market);
        cap[address(market)] = cap_;
        // allow the market to pull this vault's asset on supply()
        IERC20(asset()).forceApprove(address(market), type(uint256).max);
        emit MarketAdded(address(market), cap_);
    }

    function setCap(LendingMarket market, uint256 cap_) external onlyOwner {
        if (!isTracked[address(market)]) revert NotTracked(address(market));
        cap[address(market)] = cap_;
        emit CapSet(address(market), cap_);
    }

    function setSupplyQueue(LendingMarket[] calldata queue) external onlyOwner {
        for (uint256 i; i < queue.length; ++i) {
            if (!isTracked[address(queue[i])]) revert NotTracked(address(queue[i]));
        }
        supplyQueue = queue;
        emit SupplyQueueSet(queue.length);
    }

    function setWithdrawQueue(LendingMarket[] calldata queue) external onlyOwner {
        for (uint256 i; i < queue.length; ++i) {
            if (!isTracked[address(queue[i])]) revert NotTracked(address(queue[i]));
        }
        withdrawQueue = queue;
        emit WithdrawQueueSet(queue.length);
    }

    // --- accounting ---

    /// @notice Idle assets in the vault plus the vault's supplied position in every tracked market.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        LendingMarket[] memory mkts = markets;
        for (uint256 i; i < mkts.length; ++i) {
            total += mkts[i].supplyAssetsOf(address(this));
        }
    }

    // --- reentrancy-guarded entry points ---

    /// @notice Accrue interest on every tracked market so `totalAssets()` reflects all
    ///         earned-but-unposted interest BEFORE shares are priced. Without this, entry/exit
    ///         would price against a stale NAV, letting a just-in-time depositor mint shares
    ///         cheaply right before a market is poked and skim pending interest from existing
    ///         holders (and symmetrically shortchanging a redeemer who exits pre-accrual).
    function _accrueMarkets() internal {
        LendingMarket[] memory mkts = markets;
        for (uint256 i; i < mkts.length; ++i) {
            mkts[i].accrueInterest();
        }
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueMarkets();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueMarkets();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrueMarkets();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrueMarkets();
        return super.redeem(shares, receiver, owner_);
    }

    // --- allocation hooks ---

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares); // pulls assets into the vault, mints shares
        _allocate(assets);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) _pullLiquidity(assets - idle);
        super._withdraw(caller, receiver, owner_, assets, shares); // burns shares, transfers out
    }

    /// @notice Push `amount` into markets in supply-queue order, each up to its cap. Remainder stays idle.
    function _allocate(uint256 amount) internal {
        LendingMarket[] memory queue = supplyQueue;
        for (uint256 i; i < queue.length && amount > 0; ++i) {
            LendingMarket m = queue[i];
            uint256 supplied = m.supplyAssetsOf(address(this));
            uint256 c = cap[address(m)];
            if (c <= supplied) continue;
            uint256 room = c - supplied;
            uint256 toSupply = amount < room ? amount : room;
            if (toSupply > 0) {
                m.supply(toSupply, address(this));
                amount -= toSupply;
            }
        }
        // any leftover remains as idle liquidity in the vault (counted by totalAssets)
    }

    /// @notice Pull `need` assets back from markets in withdraw-queue order (limited by each market's
    ///         idle liquidity). Reverts if the queues cannot cover the request.
    function _pullLiquidity(uint256 need) internal {
        LendingMarket[] memory queue = withdrawQueue;
        for (uint256 i; i < queue.length && need > 0; ++i) {
            LendingMarket m = queue[i];
            uint256 ours = m.supplyAssetsOf(address(this));
            if (ours == 0) continue;
            uint256 marketIdle = m.totalSupplyAssets() - m.totalBorrowAssets();
            uint256 avail = ours < marketIdle ? ours : marketIdle;
            uint256 pull = need < avail ? need : avail;
            if (pull > 0) {
                m.withdraw(pull, 0, address(this), address(this));
                need -= pull;
            }
        }
        if (need > 0) revert NotEnoughLiquidity();
    }
}
