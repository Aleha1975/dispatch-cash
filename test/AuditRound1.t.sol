// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {LPVaultBase} from "../src/LPVaultBase.sol";
import {RiskBudgets} from "../src/RiskBudgets.sol";
import {VaultTimelock} from "../src/VaultTimelock.sol";
import {MockLPVault} from "./mocks/Mocks.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

/// Regression tests for audit round 1 (docs/audit/round1_report_1222.md). Each test reproduces the report's
/// scenario and shows that it now reverts or is bounded. LP-range specifics of H-3 and the M-8 gas griefing need the
/// real PositionManager and live in test/fork/UniV4LPVault.fork.t.sol.
contract AuditRound1Test is VaultTestBase {
    uint256 constant M = 1_000_000e6;

    function _report(uint256 price, uint256 hedge, uint256 nDep, uint256 nRed)
        internal
        view
        returns (LPVaultBase.Report memory)
    {
        return LPVaultBase.Report(vault.epoch(), price, hedge, nDep, nRed);
    }

    /// keeper reports `price` with the pool sitting at `pool`
    function _settleAt(uint256 pool, uint256 price, uint256 hedge) internal {
        vault.setPoolPrice(pool);
        LPVaultBase.Report memory r = _report(price, hedge, 100, 100);
        vm.prank(keeper);
        vault.settle(r);
    }

    function _fund(address who, uint256 a) internal {
        usdc.mint(who, a);
    }

    /// alice = incumbents: 1M, half of it in HYPE
    function _incumbents() internal {
        deposit(alice, M);
        settle(P0);
        vm.prank(keeper);
        vault.swap(false, M / 2, P0);
        settle(P0);
    }

    // ================================================================== High
    /// H-1: an accomplice deposit used to inflate the hedge-drift base (5% x (1+k) x NAV of fake equity, paid out
    /// to the accomplice's redeem). The keeper alone can no longer raise hedge equity at all.
    function test_H1_AccompliceDepositCannotFundFakeHedgeEquity() public {
        deposit(alice, M);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(100_000e6);
        _fund(carol, 9 * M);
        deposit(carol, 9 * M);
        settle(P0); // honest: lastNav = 10M, carol owns 90%
        assertEq(vault.lastNav(), 10 * M);
        redeem(carol, vault.balanceOf(carol));
        uint256 c0 = usdc.balanceOf(carol);
        // report +500k of fake equity (= 5% of the inflated 10M base)
        settle(P0, 100_000e6 + 500_000e6);
        assertEq(vault.hedgeEquity(), 100_000e6); // refused
        assertEq(vault.balanceOf(feeTo), 0); // no fee on a clipped settlement
        assertLe(usdc.balanceOf(carol) - c0, 9 * M); // paid at the honest NAV
        assertGe(valueOf(alice) + 2, M); // incumbents whole
    }

    /// H-1 (other direction): understating hedge equity for a depositing accomplice is bounded by hedgeStepBps of
    /// the NAV *before* this settlement's deposits, per decaying day.
    function test_H1_UnderstateBoundedByBudgetOnPreDepositNav() public {
        deposit(alice, M);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(300_000e6);
        _fund(carol, 9 * M);
        deposit(carol, 9 * M);
        settle(P0, 0); // try to zero the equity while carol's 9M is minted
        // at most 5% of the 1M pre-deposit NAV could be removed
        assertEq(vault.hedgeEquity(), 250_000e6);
        // and it was a clipped report: carol's deposit was not processed at the understated NAV
        assertEq(vault.balanceOf(carol), 0);
    }

    /// H-2: the keeper (with an accomplice moving the thin pool) settles at a spot pushed 30% down to mint an
    /// accomplice deposit cheaply. The anchor moves at most refDriftBps (10%) per day, the report is clipped and
    /// no deposit is processed at the clipped price.
    function test_H2_PushedSpotCannotRebaseAnchorOrMintCheapShares() public {
        _incumbents();
        _fund(carol, 850_000e6);
        deposit(carol, 850_000e6);
        uint256 pushed = P0 * 70 / 100;
        _settleAt(pushed, pushed, 0);
        assertEq(vault.lastPrice(), P0 * 90 / 100); // moved by the 10%/day budget only
        assertEq(vault.balanceOf(carol), 0); // clipped: deposits wait
        // a further empty settle in the same day cannot walk the anchor (L-1 / H-2 re-basing)
        _settleAt(pushed, pushed, 0);
        assertEq(vault.lastPrice(), P0 * 90 / 100);
        // and swaps/LP adds at the pushed price are refused (they must sit within the band of the anchor)
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.BadPrice.selector);
        vault.swap(true, 1 ether, pushed);
        // the guardian vouches for the honest price: one settlement re-anchors and processes the deposit fairly
        vm.prank(guardian);
        vault.approvePrice(P0 * 99 / 100, P0 * 101 / 100, vm.getBlockTimestamp() + 1 hours);
        _settleAt(P0, P0, 0);
        assertEq(vault.lastPrice(), P0);
        assertApproxEqRel(valueOf(carol), 850_000e6, 1e12);
        assertApproxEqRel(valueOf(alice), M * 9985 / 10_000, 1e15); // only the swap fee (0.3% of 500k) lost
    }

    /// H-2: an empty settle can no longer re-base the reference used by swap/mint/increase.
    function test_H2_EmptySettlesWalkAnchorOnlyAtBudgetRate() public {
        _incumbents();
        uint256 p = P0;
        // walk up 1.4% per settle, as fast as possible
        for (uint256 i; i < 20; ++i) {
            p = vault.lastPrice() * 1014 / 1000;
            _settleAt(p, p, 0);
        }
        // in one block the anchor moved by at most the 10% budget (relative steps compound: e^0.1 = 1.105)
        assertLe(vault.lastPrice(), P0 * 1106 / 1000);
        assertGe(vault.lastPrice(), P0 * 1100 / 1000); // and the budget is fully usable
        // and over a full day of trying, at most ~2x (decaying budget)
        for (uint256 h; h < 24; ++h) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            p = vault.lastPrice() * 1014 / 1000;
            _settleAt(p, p, 0);
        }
        // budget restored over the day: path <= ~2x 10%, compounding e^0.2 = 1.2214
        assertLe(vault.lastPrice(), P0 * 12215 / 10_000);
    }

    /// H-3 (venue-independent part): LP adds count against the same decaying turnover budget as swaps (weighted by
    /// their smaller loss bound, slippage instead of band + slippage) and must quote within the band of the anchor. Range/value checks: see the fork tests.
    function test_H3_AddsChargeTurnoverAndNeedAnchorBand() public {
        deposit(alice, M);
        settle(P0);
        vm.startPrank(keeper);
        // an add is charged its paid value x slippage / (band + slippage) = 0.4 x M: five adds use the 2x NAV budget
        for (uint256 i; i < 5; ++i) {
            vault.addLiquidity(0, M, P0);
            vault.removeLiquidity(0, M);
        }
        vm.expectRevert(RiskBudgets.Turnover.selector);
        vault.addLiquidity(0, 1e6, P0);
        vm.stopPrank();
        // anchor-band check: pool and keeper price 10% away from the anchor (the H-3 PoC's 33 vs 30)
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.setPoolPrice(P0 * 110 / 100);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.BadPrice.selector);
        vault.addLiquidity(0, 1e6, P0 * 110 / 100);
    }

    // ================================================================== Medium
    /// M-1: an unhedged vault cannot carry hedge equity, and its hedge step must be 0.
    function test_M1_UnhedgedVaultRejectsHedgeEquity() public {
        MockLPVault v = new MockLPVault(config(address(0)), P0);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(M);
        LPVaultBase.Report memory r = LPVaultBase.Report(0, P0, 0, 10, 10);
        vm.prank(keeper);
        v.settle(r);
        r = LPVaultBase.Report(1, P0, 50_000e6, 10, 10);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.NoHedge.selector);
        v.settle(r);
        LPVaultBase.Params memory p = defaultParams();
        p.hedgeCapBps = 0; // hedgeStepBps still 500
        vm.prank(owner);
        vm.expectRevert(LPVaultBase.BadParam.selector);
        v.setParams(p);
    }

    /// M-2: an approval is cleared by any margin move and expires.
    function test_M2_ApprovalClearedByMarginMoveAndExpires() public {
        deposit(alice, M);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(100_000e6);
        vm.prank(guardian);
        vault.approveHedgeEquity(200_000e6, vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        vault.sendHedgeMargin(150_000e6); // stored 250k; the approval was judged against 100k
        settle(P0, 200_000e6);
        // without the (cleared) approval a -50k move is a keeper decrease: 5% x 1M budget = 50k, allowed
        // but the report is no longer "approved"; the jump down was budgeted, not waved through
        (,, uint256 used,,,,,,,,,) = vault.budgets();
        assertEq(used, 50_000e6);
        // expiry: approval given, deadline passes, value refused
        uint256 h = vault.hedgeEquity();
        vm.prank(guardian);
        vault.approveHedgeEquity(h + 10_000e6, vm.getBlockTimestamp() + 1 hours);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        settle(P0, h + 10_000e6);
        assertEq(vault.hedgeEquity(), h);
        // return also clears
        vm.prank(guardian);
        vault.approveHedgeEquity(h + 10_000e6, vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        vault.returnHedgeMargin(1e6);
        settle(P0, h + 10_000e6);
        assertEq(vault.hedgeEquity(), h - 1e6);
    }

    /// M-3: a batch mixing vault calls with a timelock self-call used to become guardian-uncancellable.
    function test_M3_MixedBatchRejected() public {
        VaultTimelock tl = new VaultTimelock(48 hours, owner, guardian);
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = address(vault);
        d[0] = abi.encodeCall(LPVaultBase.setKeeper, (bob));
        t[1] = address(tl);
        d[1] = abi.encodeCall(TimelockController.updateDelay, (48 hours));
        vm.prank(owner);
        vm.expectRevert(VaultTimelock.MixedBatch.selector);
        tl.scheduleBatch(t, v, d, bytes32(0), bytes32(0), 48 hours);
        // a vault-only batch stays guardian-cancellable
        t[1] = address(vault);
        d[1] = abi.encodeCall(LPVaultBase.setPaused, (false));
        vm.prank(owner);
        tl.scheduleBatch(t, v, d, bytes32(0), bytes32(0), 48 hours);
        bytes32 id = tl.hashOperationBatch(t, v, d, bytes32(0), bytes32(0));
        assertFalse(tl.isSelfOperation(id));
        vm.prank(guardian);
        tl.cancel(id);
    }

    /// M-4: alternating settlements at the band edges with an accomplice cycling 9M. Previously each round trip
    /// took ~1.35% of incumbent NAV without limit; now the anchor's path budget bounds the whole day.
    function test_M4_BandSkewHarvestBoundedPerDay() public {
        _incumbents();
        uint256 lo = P0 * 986 / 1000;
        uint256 hi = P0 * 1014 / 1000;
        _fund(carol, 9 * M);
        uint256 c0 = usdc.balanceOf(carol);
        for (uint256 i; i < 50; ++i) {
            if (vault.pendingDepositAssets() == 0 && vault.balanceOf(carol) == 0) deposit(carol, 9 * M);
            _settleAt(P0, lo, 0);
            if (vault.balanceOf(carol) != 0) redeem(carol, vault.balanceOf(carol));
            _settleAt(P0, hi, 0);
        }
        // unwind honestly: refund anything queued, redeem at a guardian-vouched P0
        if (vault.pendingDepositAssets() != 0) {
            uint256 id = vault.depositTail() - 1;
            vm.prank(carol);
            vault.cancelDeposit(id);
        }
        if (vault.balanceOf(carol) != 0) redeem(carol, vault.balanceOf(carol));
        vm.prank(guardian);
        vault.approvePrice(P0, P0, vm.getBlockTimestamp());
        _settleAt(P0, P0, 0);
        uint256 gain = usdc.balanceOf(carol) > c0 ? usdc.balanceOf(carol) - c0 : 0;
        // base exposure 500k x anchor path (<= 10% in one block) + one band: <= ~57.5k (old code: ~675k)
        assertLe(gain, 500_000e6 * 1150 / 10_000);
        assertEq(vault.pendingRedeems(), 0);
    }

    /// M-5: the cap applies to max(reported equity, net margin outstanding): reporting equity down no longer
    /// frees room for more USDC to the treasury.
    function test_M5_CapOnNetMarginNotReportedEquity() public {
        deposit(alice, M);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(350_000e6); // full 35% cap
        settle(P0, 300_000e6); // -50k reported (in budget)
        assertEq(vault.hedgeEquity(), 300_000e6);
        assertEq(vault.netMargin(), 350_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(LPVaultBase.HedgeCap.selector);
        vault.sendHedgeMargin(10_000e6);
    }

    /// M-6: while paused the NAV inputs are frozen (anchor, hedge increases, fee); redemptions still go through.
    function test_M6_PauseFreezesNavInputsButNotExits() public {
        deposit(alice, M);
        deposit(bob, M);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(100_000e6);
        vm.prank(keeper);
        vault.addLiquidity(0, 500_000e6, P0);
        vm.prank(guardian);
        vault.setPaused(true);
        vault.simulateLp(0, 550_000e6); // a gain would normally mint a fee
        usdc.mint(address(vault.pool()), 50_000e6);
        redeem(bob, vault.balanceOf(bob));
        uint256 b0 = usdc.balanceOf(bob);
        _settleAt(P0 * 101 / 100, P0 * 101 / 100, 150_000e6); // +1% price, +50k equity
        assertEq(vault.lastPrice(), P0); // anchor frozen
        assertEq(vault.hedgeEquity(), 100_000e6); // increase refused
        assertEq(vault.balanceOf(feeTo), 0); // no fee while paused
        assertGt(usdc.balanceOf(bob) - b0, M); // exit paid (incl. the real LP gain)
    }

    /// M-7: a head redeem larger than idle USDC is filled partially instead of blocking; and settling without
    /// paying anything no longer resets the liveness clock.
    function test_M7_PartialFillAndLivenessMeasuresProgress() public {
        deposit(alice, M);
        settle(P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 920_000e6, P0); // idle 80k
        redeem(alice, vault.balanceOf(alice) / 10); // ~100k at the head
        redeem(alice, vault.balanceOf(alice) / 100); // smaller ones behind
        uint256 a0 = usdc.balanceOf(alice);
        settle(P0);
        assertApproxEqAbs(usdc.balanceOf(alice) - a0, 80_000e6, 2); // all idle USDC went to the head
        assertEq(vault.redeemHead(), 0);
        // a hostile keeper keeps settling with maxRedeems = 0: the clock does not reset
        uint256 t0 = vault.lastProgressTime();
        for (uint256 i; i < 4; ++i) {
            vm.warp(vm.getBlockTimestamp() + 20 hours);
            vault.setPoolPrice(P0);
            LPVaultBase.Report memory r = _report(P0, 0, 10, 0);
            vm.prank(keeper);
            vault.settle(r);
        }
        assertEq(vault.lastProgressTime(), t0);
        assertTrue(vault.canEmergencyUnwind());
        vault.emergencyUnwind(); // arm
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vault.emergencyUnwind();
        assertTrue(vault.emergency());
    }

    /// M-8: emergencyRedeem refuses to pay out while positions are still open (within the grace period), so an
    /// induced unwind failure cannot make early redeemers forfeit the LP. (Gas griefing itself: fork test.)
    function test_M8_NoEmergencyRedeemWhilePositionsOpen() public {
        deposit(alice, 100_000e6);
        deposit(bob, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 150_000e6, P0);
        vault.setStuck(true);
        forceEmergency();
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.PositionsOpen.selector);
        vault.emergencyRedeem(sh, alice);
        vault.setStuck(false);
        vault.emergencyUnwind(); // retry succeeds
        vm.prank(alice);
        vault.emergencyRedeem(sh, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), M, 2); // full value incl. the LP
        // a position that never unwinds no longer blocks forever: after the grace period holders may leave
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.InEmergency.selector);
        vault.addLiquidity(0, 1, P0);
    }

    /// M-8 (grace): after EMERGENCY_GRACE a permanently stuck position no longer blocks exits.
    function test_M8_GraceAfterSevenDays() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 50_000e6, P0);
        vault.setStuck(true);
        forceEmergency();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyRedeem(sh, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), M - 50_000e6, 2);
    }

    /// M-9: an over-budget honest equity move no longer reverts the settlement (and its redemptions); the budget is
    /// on decreases only, so equity chop (down, guardian-approved up, down) is not counted twice.
    function test_M9_OverBudgetMoveDoesNotBlockRedeems() public {
        deposit(alice, M);
        deposit(bob, M);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(500_000e6);
        redeem(bob, vault.balanceOf(bob));
        uint256 b0 = usdc.balanceOf(bob);
        settle(P0, 300_000e6); // -200k > 5% x 2M = 100k: clipped, not reverted
        assertEq(vault.hedgeEquity(), 400_000e6);
        assertGt(usdc.balanceOf(bob), b0); // redeem processed
        // chop: guardian approves the way back up, which does not consume the decrease budget
        vm.prank(guardian);
        vault.approveHedgeEquity(450_000e6, vm.getBlockTimestamp() + 1 hours);
        settle(P0, 450_000e6);
        (,, uint256 used,,,,,,,,,) = vault.budgets();
        assertEq(used, 100_000e6);
    }

    /// M-10: the PoC swap at a keeper price 10% off the last settled price (spot moved there) is refused: swaps
    /// must quote within the band of the anchor, so the per-swap loss is <= band + slippage vs the anchor.
    function test_M10_SwapAtDriftedSpotRefused() public {
        deposit(alice, M);
        settle(P0);
        vault.setPoolPrice(P0 * 110 / 100);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.BadPrice.selector);
        vault.swap(false, 100_000e6, P0 * 110 / 100);
        // inside the band of the anchor it is allowed
        vault.setPoolPrice(P0 * 1014 / 1000);
        vm.prank(keeper);
        vault.swap(false, 100_000e6, P0 * 1014 / 1000);
    }

    // ================================================================== Low
    /// L-1: budgets decay continuously; anchoring a window with 1 wei no longer allows 2x in two blocks.
    function test_L1_NoDoubleBudgetAtWindowEdge() public {
        deposit(alice, M);
        settle(P0);
        vm.startPrank(keeper);
        vault.swap(false, 1, P0); // "anchor the window"
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        vault.swap(false, M - 1, P0); // ~1x
        uint256 hype = address(vault).balance;
        vault.swap(true, hype, P0); // ~2x
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(RiskBudgets.Turnover.selector);
        vault.swap(false, 100_000e6, P0); // old fixed window: a fresh 2x here
        vm.stopPrank();
    }

    /// L-5: a blocked owner can route its claim / cancelled deposit elsewhere.
    function test_L5_ClaimToAndBlockedCancel() public {
        uint256 id = deposit(bob, 10_000e6);
        usdc.setBlocked(bob, true);
        vm.prank(bob);
        vault.cancelDeposit(id); // no revert: credited
        assertEq(vault.claimable(bob), 10_000e6);
        address safe = makeAddr("safe");
        vm.prank(bob);
        vault.claimTo(safe);
        assertEq(usdc.balanceOf(safe), 10_000e6);
    }

    /// L-6: a failed USDC leg in emergencyRedeem is credited; the native leg still goes out.
    function test_L6_EmergencyRedeemNotAllOrNothing() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.swap(false, 50_000e6, P0);
        forceEmergency();
        usdc.setBlocked(alice, true);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyRedeem(sh, alice);
        assertGt(alice.balance, 0);
        assertApproxEqAbs(vault.claimable(alice), 50_000e6, 1);
    }

    /// L-7: shares cannot be sent to the vault outside the redeem queue; the fee recipient cannot be the vault.
    function test_L7_NoStrayVaultShares() public {
        deposit(alice, 1_000e6);
        settle(P0);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.BadParam.selector);
        vault.transfer(address(vault), 1);
        assertEq(vault.balanceOf(address(vault)), vault.lockedShares());
    }

    /// L-8: a deposit that would mint 0 shares is refunded (as a claim); dust redeems are refused.
    function test_L8_ZeroShareDepositRefunded() public {
        LPVaultBase.Params memory p = defaultParams();
        p.minDeposit = 1;
        vm.prank(owner);
        vault.setParams(p);
        deposit(alice, 1_000e6);
        settle(P0);
        redeem(alice, vault.balanceOf(alice));
        settle(P0);
        usdc.mint(address(vault), 1_000_000e6); // leftover with zero supply: 1 share unit ~ 1 USDC
        deposit(bob, 1);
        settle(P0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.claimable(bob), 1);
        p.minDeposit = 0;
        vm.prank(owner);
        vm.expectRevert(LPVaultBase.BadParam.selector);
        vault.setParams(p);
    }

    /// L-10 / L-11: ready operations expire; the delay has an upper bound.
    function test_L10_L11_TimelockExpiryAndDelayCap() public {
        vm.expectRevert(VaultTimelock.DelayAboveCap.selector);
        new VaultTimelock(31 days, owner, guardian);
        VaultTimelock tl = new VaultTimelock(48 hours, owner, guardian);
        bytes memory data = abi.encodeCall(LPVaultBase.setPaused, (false));
        vm.prank(owner);
        tl.schedule(address(vault), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 7 days + 1);
        vm.prank(owner);
        vm.expectPartialRevert(VaultTimelock.OperationExpired.selector);
        tl.execute(address(vault), 0, data, bytes32(0), bytes32(0));
    }

    /// L-12: renounceOwnership is disabled.
    function test_L12_RenounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(LPVaultBase.BadParam.selector);
        vault.renounceOwnership();
    }

    /// L-13 (on-chain part) / L-17: keeper != guardian; wrappedBase must be a contract.
    function test_L13_L17_ConstructorValidation() public {
        LPVaultBase.BaseConfig memory c = config(treasury);
        c.guardian = c.keeper;
        vm.expectRevert(LPVaultBase.BadParam.selector);
        new MockLPVault(c, P0);
        c = config(treasury);
        c.wrappedBase = makeAddr("noCode");
        vm.expectRevert(LPVaultBase.BadParam.selector);
        new MockLPVault(c, P0);
    }
}
