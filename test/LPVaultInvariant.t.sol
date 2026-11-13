// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LPVaultBase} from "../src/LPVaultBase.sol";
import {MockUSDC, MockLPVault} from "./mocks/Mocks.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract VaultHandler is Test {
    MockLPVault public vault;
    MockUSDC public usdc;
    address public keeper;
    address public guardian;
    address public owner;
    address public treasury;
    address public feeTo;
    address[] public actors;

    uint256 public price;
    bool public feeViolation;
    bool public hedgeCapViolation;
    uint256 public settles;
    uint256 public redeemsPaid;

    constructor(MockLPVault v, MockUSDC u, address k, address g, address o, address t, address f, address[] memory a) {
        vault = v;
        usdc = u;
        keeper = k;
        guardian = g;
        owner = o;
        treasury = t;
        feeTo = f;
        actors = a;
        price = v.mockPrice();
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    // ---------------------------------------------------------------- clients
    function deposit(uint256 s, uint256 amount) external {
        address a = _actor(s);
        amount = bound(amount, 1e6, 200_000e6);
        usdc.mint(a, amount);
        vm.startPrank(a);
        usdc.approve(address(vault), amount);
        vault.requestDeposit(amount);
        vm.stopPrank();
    }

    function cancelDeposit(uint256 id) external {
        uint256 tail = vault.depositTail();
        if (tail == 0) return;
        id = bound(id, 0, tail - 1);
        (address o,) = vault.depositRequests(id);
        vm.prank(o);
        vault.cancelDeposit(id);
    }

    function requestRedeem(uint256 s, uint256 frac) external {
        address a = _actor(s);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 sh = Math.mulDiv(bal, bound(frac, 1, 100), 100);
        vm.prank(a);
        vault.requestRedeem(sh);
    }

    function transferShares(uint256 s1, uint256 s2, uint256 frac) external {
        address a = _actor(s1);
        address b = _actor(s2);
        uint256 sh = Math.mulDiv(vault.balanceOf(a), bound(frac, 0, 100), 100);
        vm.prank(a);
        vault.transfer(b, sh);
    }

    function donate(uint256 amount) external {
        usdc.mint(address(vault), bound(amount, 0, 10_000e6));
    }

    // ---------------------------------------------------------------- keeper (honest)
    function settle(int256 moveBps, int256 hedgeMoveBps, uint256 lpPnlBps) external {
        moveBps = bound(moveBps, -300, 300);
        price = uint256(int256(price) * (10_000 + moveBps) / 10_000);
        if (price < 1e6) price = 1e6;
        vault.setPoolPrice(price);
        // LP PnL in the pool (-5% .. +5%), funded/withdrawn from the mock pool's inventory
        uint256 lpA = vault.lpAsset();
        if (lpA != 0) {
            lpPnlBps = bound(lpPnlBps, 9_500, 10_500);
            vault.simulateLp(vault.lpBase(), lpA * lpPnlBps / 10_000);
        }
        uint256 h = vault.hedgeEquity();
        uint256 step = vault.lastNav() * 400 / 10_000;
        hedgeMoveBps = bound(hedgeMoveBps, -10_000, 10_000);
        uint256 d = Math.mulDiv(step, uint256(hedgeMoveBps < 0 ? -hedgeMoveBps : hedgeMoveBps), 10_000);
        h = hedgeMoveBps < 0 ? (h > d ? h - d : 0) : h + d;

        uint256 supply = vault.totalSupply();
        uint256 hwm = vault.highWaterMark();
        uint256 feeBefore = vault.balanceOf(feeTo);
        LPVaultBase.Report memory r = LPVaultBase.Report(vault.epoch(), price, h, 50, 50);
        // NAV the vault will see, using the new hedge equity
        uint256 navExpected = vault.grossAssets(price) - vault.hedgeEquity() + h;
        vm.prank(keeper);
        vault.settle(r);
        settles++;
        uint256 feeShares = vault.balanceOf(feeTo) - feeBefore;
        if (feeShares != 0) {
            uint256 feeValue = Math.mulDiv(feeShares, navExpected + 1, supply + feeShares + 1e6);
            uint256 pps = Math.mulDiv(navExpected + 1, 1e18, supply + 1e6);
            uint256 gain = pps > hwm ? Math.mulDiv(pps - hwm, supply, 1e18) : 0;
            if (feeValue > Math.mulDiv(gain, vault.MAX_FEE_BPS(), 10_000) + 1) feeViolation = true;
        }
        if (vault.redeemHead() != 0) redeemsPaid = vault.redeemHead();
    }

    function addLiquidity(uint256 frac) external {
        uint256 idle = vault.idleAsset();
        uint256 a = Math.mulDiv(idle, bound(frac, 0, 100), 100);
        uint256 b = address(vault).balance;
        vm.prank(keeper);
        vault.addLiquidity(b, a, price);
    }

    function removeLiquidity(uint256 frac) external {
        uint256 f = bound(frac, 0, 100);
        uint256 b = vault.lpBase() * f / 100;
        uint256 a = vault.lpAsset() * f / 100;
        vm.prank(keeper);
        vault.removeLiquidity(b, a);
    }

    function swap(bool sellBase, uint256 frac) external {
        uint256 bal = sellBase ? address(vault).balance : vault.idleAsset();
        uint256 amt = Math.mulDiv(bal, bound(frac, 1, 100), 100);
        if (amt == 0) return;
        vm.prank(keeper);
        vault.swap(sellBase, amt, price);
    }

    function sendHedge(uint256 amount) external {
        amount = bound(amount, 1, vault.lastNav() + 1);
        vm.prank(keeper);
        vault.sendHedgeMargin(amount);
        if (vault.hedgeEquity() > vault.hedgeCap()) hedgeCapViolation = true;
    }

    function returnHedge(uint256 amount) external {
        uint256 bal = usdc.balanceOf(treasury);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(treasury);
        vault.returnHedgeMargin(amount);
    }

    // ---------------------------------------------------------------- compromised keeper: arbitrary arguments
    function evilKeeper(uint256 which, uint256 x, uint256 y, uint256 z) external {
        LPVaultBase.Report memory r = LPVaultBase.Report(vault.epoch(), z, y % 1e30, x % 100, x % 100);
        vm.prank(keeper);
        if (which % 5 == 0) vault.addLiquidity(x % 1e30, y % 1e30, z);
        else if (which % 5 == 1) vault.removeLiquidity(x % 1e30, y % 1e30);
        else if (which % 5 == 2) vault.swap(x % 2 == 0, y % 1e30, z);
        else if (which % 5 == 3) vault.sendHedgeMargin(x % 1e30);
        else vault.settle(r);
    }

    // ---------------------------------------------------------------- guardian / time / emergency
    function pause(uint256 seed) external {
        bool p = seed % 97 == 3; // mostly unpaused so the other paths get exercised
        vm.prank(p ? guardian : owner);
        vault.setPaused(p);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 8 hours));
    }

    /// Rarely jump past the settlement timeout so some runs explore the wind-down.
    function bigWarp(uint256 seed) external {
        if (seed % 6 == 0) vm.warp(block.timestamp + 73 hours);
    }

    function emergencyUnwind() external {
        vault.emergencyUnwind();
    }

    function emergencyRedeem(uint256 s, uint256 frac) external {
        address a = _actor(s);
        uint256 sh = Math.mulDiv(vault.balanceOf(a), bound(frac, 1, 100), 100);
        if (sh == 0) return;
        vm.prank(a);
        vault.emergencyRedeem(sh, a);
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

contract LPVaultInvariantTest is VaultTestBase {
    VaultHandler handler;
    address[] actorList;

    function setUp() public override {
        super.setUp();
        actorList.push(alice);
        actorList.push(bob);
        actorList.push(carol);
        actorList.push(makeAddr("dave"));
        handler = new VaultHandler(vault, usdc, keeper, guardian, owner, treasury, feeTo, actorList);
        targetContract(address(handler));
    }

    function invariant_reserveBacked() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.pendingDepositAssets() + vault.totalClaimable());
    }

    function invariant_lockedSharesHeldByVault() public view {
        assertEq(vault.balanceOf(address(vault)), vault.lockedShares());
    }

    function invariant_supplyAccounted() public view {
        uint256 sum = vault.balanceOf(feeTo) + vault.lockedShares();
        for (uint256 i; i < actorList.length; ++i) {
            sum += vault.balanceOf(actorList[i]);
        }
        assertEq(sum, vault.totalSupply());
    }

    function invariant_pendingDepositsMatchQueue() public view {
        uint256 sum;
        for (uint256 i = vault.depositHead(); i < vault.depositTail(); ++i) {
            (, uint256 a) = vault.depositRequests(i);
            sum += a;
        }
        assertEq(sum, vault.pendingDepositAssets());
    }

    function invariant_feeNeverAboveCap() public view {
        assertFalse(handler.feeViolation());
    }

    function invariant_hedgeMarginWithinCapWhenSent() public view {
        assertFalse(handler.hedgeCapViolation());
    }

    /// Funds only ever go to clients, the fixed treasury or the venue: keeper, guardian, owner and fee recipient never
    /// receive any token or native coin from the vault.
    function invariant_noLeakToRoles() public view {
        address[4] memory roles = [keeper, guardian, owner, feeTo];
        for (uint256 i; i < 4; ++i) {
            assertEq(usdc.balanceOf(roles[i]), 0);
            assertEq(roles[i].balance, 0);
        }
    }

    function invariant_highWaterMarkMonotoneWhileSupply() public view {
        // HWM >= initial mark always (it only resets when supply is 0)
        assertGe(vault.highWaterMark(), 1e12);
    }
}
