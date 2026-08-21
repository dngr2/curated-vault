// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {LendingMarket} from "../src/LendingMarket.sol";
import {LinearIrm} from "../src/LinearIrm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract Handler is Test {
    CuratedVault public vault;
    MockERC20 public loan;
    LendingMarket public mA;
    address[] public actors;

    constructor(CuratedVault v, MockERC20 l, LendingMarket _mA, address[] memory a) {
        vault = v;
        loan = l;
        mA = _mA;
        actors = a;
    }

    function _a(uint256 i) internal view returns (address) {
        return actors[i % actors.length];
    }

    function deposit(uint256 who, uint256 amt) external {
        address a = _a(who);
        amt = bound(amt, 1, 1_000_000e18);
        loan.mint(a, amt);
        vm.startPrank(a);
        loan.approve(address(vault), amt);
        vault.deposit(amt, a);
        vm.stopPrank();
    }

    function withdraw(uint256 who, uint256 shares) external {
        address a = _a(who);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        try vault.redeem(shares, a, a) {} catch {}
    }

    function yield(uint256 amt) external {
        // simulate market interest by donating to a market's balance then poking it via a supply
        amt = bound(amt, 0, 10_000e18);
        if (amt == 0) return;
        loan.mint(address(mA), amt);
    }
}

contract CuratedVaultInvariant is StdInvariant, Test {
    CuratedVault vault;
    MockERC20 loan;
    MockERC20 coll;
    MockOracle oracle;
    LinearIrm irm;
    LendingMarket mA;
    LendingMarket mB;
    Handler h;
    address[] actors;

    function setUp() public {
        vm.warp(1_000_000);
        loan = new MockERC20("Loan", "LOAN");
        coll = new MockERC20("Coll", "COLL");
        oracle = new MockOracle(1e18);
        irm = new LinearIrm(uint256(0.1e18) / 365 days, uint256(0.2e18) / 365 days);
        mA = new LendingMarket(IERC20(address(loan)), IERC20(address(coll)), oracle, irm, 0.8e18, address(0xF), 0);
        mB = new LendingMarket(IERC20(address(loan)), IERC20(address(coll)), oracle, irm, 0.8e18, address(0xF), 0);
        vault = new CuratedVault(IERC20(address(loan)), "cLOAN", "cLOAN", address(this));
        vault.addMarket(mA, 500_000e18);
        vault.addMarket(mB, type(uint256).max);
        LendingMarket[] memory q = new LendingMarket[](2);
        q[0] = mA;
        q[1] = mB;
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);

        actors.push(makeAddr("a0"));
        actors.push(makeAddr("a1"));
        h = new Handler(vault, loan, mA, actors);
        targetContract(address(h));
    }

    /// The vault never owes depositors more than it holds: redeemable value of all shares
    /// never exceeds reported net assets.
    function invariant_solvent() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets());
    }

    /// Reported assets equal idle plus the vault's position in each market (no double count / gap).
    function invariant_navConsistent() public view {
        uint256 sum = loan.balanceOf(address(vault));
        sum += mA.supplyAssetsOf(address(vault));
        sum += mB.supplyAssetsOf(address(vault));
        assertEq(vault.totalAssets(), sum);
    }
}
