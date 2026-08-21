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

    // ------------------------------------------------------------------
    // DEEP DIVE (v2): adversarial coverage of the accrual/pricing boundary,
    // cap enforcement, and market-set integrity.
    // ------------------------------------------------------------------

    /// A market only accrues on its own interactions, so between pokes it carries
    /// earned-but-unposted interest. If entry priced shares against that stale NAV,
    /// an attacker could deposit right before a poke and skim the pending interest
    /// from existing holders. Regression: entry must accrue first, so the JIT
    /// depositor gets back only their own principal and the existing holder keeps
    /// 100% of the interest earned before the attacker arrived.
    function test_jitDeposit_cannotStealPendingInterest() public {
        _deposit(alice, 1000e18); // A=600, B=400

        // borrower draws from market A; interest starts accruing
        collA.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        collA.approve(address(mA), 1000e18);
        mA.supplyCollateral(1000e18, borrower);
        mA.borrow(400e18, borrower, borrower);
        vm.stopPrank();

        vm.warp(T0 + 365 days); // ~93e18 interest earned, not yet posted to the vault

        address attacker = makeAddr("attacker");
        uint256 attackerShares = _deposit(attacker, 1000e18); // must accrue before pricing

        mA.accrueInterest(); // realize the pending interest on-chain

        // Attacker cannot extract more than the assets they put in.
        uint256 attackerValue = vault.convertToAssets(attackerShares);
        assertLe(attackerValue, 1000e18 + 1e15, "JIT depositor must not skim pending interest");

        // The pre-existing holder keeps essentially all of the earned interest.
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        assertGt(aliceValue, 1090e18, "existing holder keeps the pending interest");
    }

    /// Symmetric to the JIT-deposit case: a holder who redeems while interest is
    /// pending must still be credited their share of it (exit accrues first),
    /// instead of forfeiting it to whoever pokes the market afterwards.
    function test_redeem_accruesInterestBeforePricing() public {
        _deposit(alice, 1000e18);

        collA.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        collA.approve(address(mA), 1000e18);
        mA.supplyCollateral(1000e18, borrower);
        mA.borrow(100e18, borrower, borrower); // small draw => plenty of exit liquidity
        vm.stopPrank();

        vm.warp(T0 + 365 days); // interest accrues, not yet posted

        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 got = vault.redeem(half, alice, alice);

        // Half the shares must be worth strictly more than half the raw principal,
        // i.e. the redeemer's share of pending interest is included.
        assertGt(got, 502e18, "redeemer must receive their share of pending interest");
    }

    /// The allocator can never push a market past its cap, even across several
    /// deposits: fill A exactly to its cap, then a further deposit must overflow
    /// into B (or idle) rather than exceeding the cap.
    function test_cap_neverExceededAcrossDeposits() public {
        vm.prank(curator);
        vault.setCap(mB, 0); // only A has capacity (cap 600), rest idles

        _deposit(alice, 400e18);
        assertApproxEqAbs(mA.supplyAssetsOf(address(vault)), 400e18, 1);

        _deposit(alice, 400e18); // A can take only 200 more; 200 must idle
        assertApproxEqAbs(mA.supplyAssetsOf(address(vault)), 600e18, 2, "A capped at 600");
        assertApproxEqAbs(loan.balanceOf(address(vault)), 200e18, 2, "overflow stays idle, cap respected");
    }

    /// A market not in the supply queue must never receive allocation, and a
    /// non-tracked market cannot be placed in any queue.
    function test_queue_rejectsUntrackedMarket() public {
        MockERC20 collC = new MockERC20("CollC", "CC");
        LendingMarket mC =
            new LendingMarket(IERC20(address(loan)), IERC20(address(collC)), oracleA, irm, 0.8e18, address(0xF), 0);
        LendingMarket[] memory q = new LendingMarket[](1);
        q[0] = mC; // never added to the vault
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.NotTracked.selector, address(mC)));
        vault.setSupplyQueue(q);

        // and it never held any allocation
        _deposit(alice, 100e18);
        assertEq(mC.supplyAssetsOf(address(vault)), 0, "untracked market receives nothing");
    }
}
