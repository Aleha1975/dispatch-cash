// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPVaultBase} from "../src/LPVaultBase.sol";
import {MockLPVault} from "./mocks/Mocks.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

/// Receives native HYPE from emergencyRedeem and tries to re-enter every client entry point.
contract ReentrantReceiver {
    MockLPVault immutable v;
    bool public tried;
    uint256 public reentered;

    constructor(MockLPVault v_) {
        v = v_;
    }

    receive() external payable {
        if (tried) return;
        tried = true;
        uint256 sh = v.balanceOf(address(this));
        (bool ok,) = address(v).call(abi.encodeCall(LPVaultBase.emergencyRedeem, (sh, address(this))));
        if (ok) reentered++;
        (ok,) = address(v).call(abi.encodeCall(LPVaultBase.claim, ()));
        if (ok) reentered++;
        (ok,) = address(v).call(abi.encodeCall(LPVaultBase.emergencyUnwind, ()));
        if (ok) reentered++;
    }

    function redeem(uint256 sh) external {
        v.emergencyRedeem(sh, address(this));
    }
}

/// Self-review regression tests (round 1).
contract LPVaultReviewTest is VaultTestBase {
    function _emergencyWithHype() internal returns (uint256 hype) {
        deposit(alice, 60_000e6);
        deposit(bob, 40_000e6);
        settle(P0);
        vm.startPrank(keeper);
        vault.swap(false, 50_000e6, P0);
        hype = address(vault).balance;
        vault.addLiquidity(hype / 2, 20_000e6, P0);
        vm.stopPrank();
        vm.warp(block.timestamp + 72 hours + 1);
        vault.emergencyUnwind();
    }

    function test_EmergencyRedeemNativeReentrancyBlocked() public {
        _emergencyWithHype();
        ReentrantReceiver r = new ReentrantReceiver(vault);
        uint256 half = vault.balanceOf(bob) / 2;
        vm.prank(bob);
        vault.transfer(address(r), half);
        uint256 hypeBefore = address(vault).balance;
        uint256 supplyBefore = vault.totalSupply();
        r.redeem(half);
        assertTrue(r.tried());
        assertEq(r.reentered(), 0);
        assertEq(address(r).balance, hypeBefore * half / supplyBefore);
    }

    function test_EmergencyQueuedRedeemerGetsSameProRata() public {
        deposit(alice, 50_000e6);
        deposit(bob, 50_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.swap(false, 30_000e6, P0);
        uint256 id = redeem(bob, vault.balanceOf(bob)); // stuck in the queue when the keeper disappears
        vm.warp(block.timestamp + 72 hours + 1);
        vault.emergencyUnwind();
        vm.prank(bob);
        vault.cancelRedeem(id);
        uint256 aSh = vault.balanceOf(alice);
        uint256 bSh = vault.balanceOf(bob);
        assertEq(aSh, bSh);
        vm.prank(alice);
        vault.emergencyRedeem(aSh, alice);
        uint256 hypeA = alice.balance;
        vm.prank(bob);
        vault.emergencyRedeem(bSh, bob);
        assertApproxEqAbs(bob.balance, hypeA, 1);
        assertEq(vault.totalSupply(), 0);
        assertLe(address(vault).balance, 1); // no native stranded beyond rounding
    }

    function test_HwmRestartsAfterFullExitWithoutChargingNewcomers() public {
        deposit(alice, 100_000e6);
        settle(P0);
        redeem(alice, vault.balanceOf(alice));
        settle(P0);
        assertEq(vault.totalSupply(), 0);
        usdc.mint(address(vault), 5_000e6); // leftover / late hedge return lands with nobody holding shares
        deposit(bob, 10_000e6);
        settle(P0);
        assertEq(vault.balanceOf(feeTo), 0);
        // the leftover stays with the virtual shares; share units become coarse (pps ~ leftover / 1e6), so the
        // newcomer's rounding loss is <= one share unit (~0.005 USDC here), never a fee
        assertApproxEqAbs(valueOf(bob), 10_000e6, 5_000);
        assertLe(valueOf(bob), 10_000e6);
        settle(P0);
        assertEq(vault.balanceOf(feeTo), 0); // leftover is not "performance" for bob
    }

    function test_FeeOnlyOnGainAboveHwmAcrossDrawdownDeposit() public {
        deposit(alice, 100_000e6);
        settle(P0);
        // loss: pps 0.8
        vm.prank(keeper);
        vault.sendHedgeMargin(30_000e6);
        vm.prank(guardian);
        vault.approveHedgeEquity(10_000e6);
        settle(P0, 10_000e6);
        uint256 hwm = vault.highWaterMark();
        deposit(bob, 80_000e6); // enters in the drawdown
        settle(P0, 10_000e6);
        // recover to above the mark: +25% on everything
        vm.prank(guardian);
        vault.approveHedgeEquity(10_000e6 + 40_000e6);
        settle(P0, 50_000e6);
        uint256 pps = vault.lastPricePerShare();
        assertGt(pps, hwm);
        uint256 feeValue = vault.previewRedeemLast(vault.balanceOf(feeTo));
        // fee = 15% of (pps_before_fee - hwm) * supply; nothing on the recovery from 0.8 to 1.0
        uint256 supplyNoFee = vault.totalSupply() - vault.balanceOf(feeTo);
        uint256 gainAboveMark = (200_000e6 - (hwm * (supplyNoFee + 1e6)) / 1e18);
        assertApproxEqRel(feeValue, gainAboveMark * 1500 / 10_000, 1e15);
    }
}
