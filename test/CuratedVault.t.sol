// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {LendingMarket} from "../src/LendingMarket.sol";
import {LinearIrm} from "../src/LinearIrm.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {IIrm} from "../src/interfaces/IIrm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract CuratedVaultTest is Test {
    MockERC20 loan;
    MockERC20 collA;
    MockERC20 collB;
    MockOracle oracleA;
    MockOracle oracleB;
    LinearIrm irm;
    LendingMarket mA;
    LendingMarket mB;
    CuratedVault vault;

    address curator = makeAddr("curator");
    address alice = makeAddr("alice");
    address borrower = makeAddr("borrower");

    uint256 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        loan = new MockERC20("Loan", "LOAN");
        collA = new MockERC20("CollA", "CA");
        collB = new MockERC20("CollB", "CB");
        oracleA = new MockOracle(1e18);
        oracleB = new MockOracle(1e18);
        irm = new LinearIrm(uint256(0.1e18) / 365 days, uint256(0.2e18) / 365 days);
        mA = new LendingMarket(IERC20(address(loan)), IERC20(address(collA)), oracleA, irm, 0.8e18, address(0xF), 0);
        mB = new LendingMarket(IERC20(address(loan)), IERC20(address(collB)), oracleB, irm, 0.8e18, address(0xF), 0);

        vault = new CuratedVault(IERC20(address(loan)), "Curated LOAN", "cLOAN", curator);
        vm.startPrank(curator);
        vault.addMarket(mA, 600e18); // cap 600 in market A
        vault.addMarket(mB, type(uint256).max); // uncapped market B
        LendingMarket[] memory q = new LendingMarket[](2);
        q[0] = mA;
        q[1] = mB;
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        loan.mint(who, amt);
        vm.startPrank(who);
        loan.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function test_deposit_allocatesAcrossMarketsByCapAndQueue() public {
        _deposit(alice, 1000e18);
        // supply queue fills A up to its 600 cap, remainder (400) goes to B
        assertApproxEqAbs(mA.supplyAssetsOf(address(vault)), 600e18, 1);
        assertApproxEqAbs(mB.supplyAssetsOf(address(vault)), 400e18, 1);
        assertApproxEqAbs(vault.totalAssets(), 1000e18, 2);
        assertEq(loan.balanceOf(address(vault)), 0, "nothing idle when caps allow full allocation");
    }

    function test_deposit_leftoverStaysIdleWhenCapped() public {
        // shrink B's cap so total capacity < deposit → remainder idles in the vault
        vm.prank(curator);
        vault.setCap(mB, 100e18);
        _deposit(alice, 1000e18);
        assertApproxEqAbs(mA.supplyAssetsOf(address(vault)), 600e18, 1);
        assertApproxEqAbs(mB.supplyAssetsOf(address(vault)), 100e18, 1);
        assertApproxEqAbs(loan.balanceOf(address(vault)), 300e18, 2); // idle remainder
        assertApproxEqAbs(vault.totalAssets(), 1000e18, 2);
    }

    function test_withdraw_pullsFromMarketsInQueueOrder() public {
        _deposit(alice, 1000e18);
        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);
        assertApproxEqAbs(loan.balanceOf(alice), 500e18, 1);
        // withdraw queue pulls A first: A had 600, now ~100; B untouched at 400
        assertApproxEqAbs(mA.supplyAssetsOf(address(vault)), 100e18, 2);
        assertApproxEqAbs(mB.supplyAssetsOf(address(vault)), 400e18, 2);
        assertApproxEqAbs(vault.totalAssets(), 500e18, 2);
    }

    function test_yieldFlowsToDepositors() public {
        _deposit(alice, 1000e18);
        // a borrower draws from market A, generating interest
        collA.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        collA.approve(address(mA), 1000e18);
        mA.supplyCollateral(1000e18, borrower);
        mA.borrow(400e18, borrower, borrower);
        vm.stopPrank();

        uint256 before = vault.totalAssets();
        vm.warp(T0 + 365 days);
        mA.accrueInterest(); // poke the market so its supply value reflects accrued interest
        assertGt(vault.totalAssets(), before, "vault NAV grew from market interest");
        // alice's shares are now worth more
        assertGt(vault.convertToAssets(vault.balanceOf(alice)), 1000e18);
    }

    function test_withdraw_revertsIfMarketsIlliquid() public {
        _deposit(alice, 1000e18);
        // borrow out most of market A's liquidity so it can't be fully withdrawn
        collA.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        collA.approve(address(mA), 1000e18);
        mA.supplyCollateral(1000e18, borrower);
        mA.borrow(560e18, borrower, borrower); // A had 600 supplied; 560 borrowed → 40 idle
        vm.stopPrank();
        // A idle=40, B idle=400 → total pullable ~440 < 1000; a 900 withdraw must revert
        vm.prank(alice);
        vm.expectRevert(CuratedVault.NotEnoughLiquidity.selector);
        vault.withdraw(900e18, alice, alice);
    }

    function test_addMarket_assetMismatchReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        LendingMarket bad =
            new LendingMarket(IERC20(address(other)), IERC20(address(collA)), oracleA, irm, 0.8e18, address(0xF), 0);
        vm.prank(curator);
        vm.expectRevert(CuratedVault.AssetMismatch.selector);
        vault.addMarket(bad, 100e18);
    }

    function test_onlyCurator_canConfigure() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setCap(mA, 1e18);
    }

    function test_inflationAttack_neutralized() public {
        address attacker = makeAddr("attacker");
        loan.mint(attacker, 1);
        vm.startPrank(attacker);
        loan.approve(address(vault), 1);
        vault.deposit(1, attacker);
        vm.stopPrank();
        loan.mint(address(vault), 10_000e18); // donation
        uint256 vShares = _deposit(alice, 10_000e18);
        assertGt(vault.convertToAssets(vShares), 9_900e18, "victim keeps ~all of deposit");
    }

    function test_multipleDepositors_shareProRata() public {
        _deposit(alice, 1000e18);
        address bob = makeAddr("bob");
        _deposit(bob, 1000e18);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), vault.convertToAssets(vault.balanceOf(bob)), 2);
        assertApproxEqAbs(vault.totalAssets(), 2000e18, 3);
    }
}
