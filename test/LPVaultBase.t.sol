// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPVaultBase} from "../src/LPVaultBase.sol";
import {RiskBudgets} from "../src/RiskBudgets.sol";
import {MockLPVault} from "./mocks/Mocks.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract LPVaultBaseTest is VaultTestBase {
    // ------------------------------------------------------------------ deposits
    function test_DepositQueuedThenSettled() public {
        uint256 id = deposit(alice, 100_000e6);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.pendingDepositAssets(), 100_000e6);
        assertEq(usdc.balanceOf(address(vault)), 100_000e6);
        settle(P0);
        assertEq(vault.balanceOf(alice), 100_000e6 * 1e6); // first deposit: 1 USDC raw = 1e6 share units
        assertEq(vault.pendingDepositAssets(), 0);
        assertEq(vault.lastNav(), 100_000e6);
        (, uint256 left) = vault.depositRequests(id);
        assertEq(left, 0);
        assertApproxEqAbs(valueOf(alice), 100_000e6, 1);
        assertEq(vault.decimals(), 12);
    }

    function test_DepositWithPermit_OneTx() public {
        vm.prank(alice);
        usdc.approve(address(vault), 0);
        uint256 amount = 5_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(alice, address(vault), amount, usdc.nonces(alice), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        vm.prank(alice);
        vault.requestDepositWithPermit(amount, deadline, v, r, s);
        assertEq(vault.pendingDepositAssets(), amount);
    }

    function test_DepositWithPermit_FrontRunStillWorks() public {
        vm.prank(alice);
        usdc.approve(address(vault), 0);
        uint256 amount = 5_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(alice, address(vault), amount, usdc.nonces(alice), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        usdc.permit(alice, address(vault), amount, deadline, v, r, s); // griefer front-runs
        vm.prank(alice);
        vault.requestDepositWithPermit(amount, deadline, v, r, s);
        assertEq(vault.pendingDepositAssets(), amount);
    }

    function test_CancelDeposit() public {
        uint256 id = deposit(alice, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(LPVaultBase.NotRequestOwner.selector);
        vault.cancelDeposit(id);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.cancelDeposit(id);
        assertEq(usdc.balanceOf(alice), before + 1_000e6);
        assertEq(vault.pendingDepositAssets(), 0);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.ZeroAmount.selector);
        vault.cancelDeposit(id);
        settle(P0); // cancelled request is skipped
        assertEq(vault.totalSupply(), 0);
    }

    function test_CannotCancelAfterSettlement() public {
        uint256 id = deposit(alice, 1_000e6);
        settle(P0);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.ZeroAmount.selector);
        vault.cancelDeposit(id);
    }

    function test_MinDeposit() public {
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.BelowMinDeposit.selector);
        vault.requestDeposit(0.5e6);
    }

    function test_SecondDepositorFairPrice() public {
        deposit(alice, 100_000e6);
        settle(P0);
        // vault gains 10% (all in LP), then bob enters
        vm.prank(keeper);
        vault.addLiquidity(0, 100_000e6, P0);
        vault.simulateLp(0, 110_000e6);
        usdc.mint(address(vault.pool()), 10_000e6);
        deposit(bob, 11_000e6);
        settle(P0);
        // bob pays post-fee price: his value equals what he put in (rounded down)
        assertApproxEqAbs(valueOf(bob), 11_000e6, 2);
        assertLe(valueOf(bob), 11_000e6);
    }

    // ------------------------------------------------------------------ redeems
    function test_RedeemPushesUsdc_NoClaimTx() public {
        deposit(alice, 100_000e6);
        settle(P0);
        uint256 sh = vault.balanceOf(alice);
        uint256 before = usdc.balanceOf(alice);
        redeem(alice, sh);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.lockedShares(), sh);
        settle(P0);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 100_000e6, 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.lockedShares(), 0);
    }

    function test_RedeemWaitsForLiquidityFifo() public {
        deposit(alice, 60_000e6);
        deposit(bob, 40_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 90_000e6, P0); // only 10k idle
        redeem(alice, vault.balanceOf(alice)); // 60k: not payable in full
        redeem(bob, vault.balanceOf(bob) / 8); // 5k: behind alice (FIFO)
        uint256 a0 = usdc.balanceOf(alice);
        settle(P0);
        // M-7: the head gets all idle USDC now, the rest of it stays at the head
        assertApproxEqAbs(usdc.balanceOf(alice) - a0, 10_000e6, 2);
        assertEq(vault.redeemHead(), 0);
        assertEq(vault.pendingRedeems(), 2);
        // a new deposit nets against redemptions
        deposit(carol, 100_000e6);
        settle(P0);
        assertApproxEqAbs(usdc.balanceOf(alice) - a0, 60_000e6, 3);
        assertEq(vault.pendingRedeems(), 0);
    }

    function test_KeeperFreesLiquidityThenRedeemPaid() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 100_000e6, P0);
        redeem(alice, vault.balanceOf(alice));
        settle(P0);
        assertEq(vault.pendingRedeems(), 1);
        vm.prank(keeper);
        vault.removeLiquidity(0, 100_000e6);
        uint256 b = usdc.balanceOf(alice);
        settle(P0);
        assertApproxEqAbs(usdc.balanceOf(alice) - b, 100_000e6, 1);
    }

    function test_FailedPushBecomesClaim() public {
        deposit(bob, 10_000e6);
        settle(P0);
        redeem(bob, vault.balanceOf(bob));
        usdc.setBlocked(bob, true);
        settle(P0); // must not revert for everybody
        uint256 owed = vault.claimable(bob);
        assertApproxEqAbs(owed, 10_000e6, 1);
        assertEq(vault.totalClaimable(), owed);
        // claims are reserved: keeper cannot spend them
        assertEq(vault.idleAsset(), usdc.balanceOf(address(vault)) - owed);
        usdc.setBlocked(bob, false);
        vm.prank(bob);
        vault.claim();
        assertEq(vault.totalClaimable(), 0);
    }

    // ------------------------------------------------------------------ fees / HWM
    function test_PerformanceFee15PercentOfGain() public {
        deposit(alice, 100_000e6);
        settle(P0);
        _setLpValue(110_000e6); // +10k gain
        settle(P0);
        uint256 feeValue = valueOf(feeTo);
        assertApproxEqRel(feeValue, 1_500e6, 1e12); // 15% of 10k
        assertApproxEqAbs(valueOf(alice), 108_500e6, 2);
        assertApproxEqAbs(valueOf(alice) + feeValue, 110_000e6, 2);
    }

    function test_HighWaterMark_NoFeeUntilRecovered() public {
        deposit(alice, 100_000e6);
        settle(P0);
        _setLpValue(110_000e6);
        settle(P0);
        uint256 feeShares1 = vault.balanceOf(feeTo);
        uint256 hwm1 = vault.highWaterMark();
        _setLpValue(95_000e6); // loss
        settle(P0);
        assertEq(vault.balanceOf(feeTo), feeShares1);
        assertEq(vault.highWaterMark(), hwm1);
        _setLpValue(110_000e6); // back to the mark: still no fee
        settle(P0);
        assertEq(vault.balanceOf(feeTo), feeShares1);
        _setLpValue(120_000e6); // +10k above the mark
        settle(P0);
        uint256 newFeeShares = vault.balanceOf(feeTo) - feeShares1;
        uint256 newFeeValue = vault.previewRedeemLast(newFeeShares);
        assertApproxEqRel(newFeeValue, 1_500e6, 1e12);
    }

    function test_FeeRateCappedAt20() public {
        LPVaultBase.Params memory p = defaultParams();
        p.feeBps = 2001;
        vm.prank(owner);
        vm.expectRevert(LPVaultBase.BadParam.selector);
        vault.setParams(p);
        p.feeBps = 2000;
        vm.prank(owner);
        vault.setParams(p);
        vm.prank(keeper);
        vm.expectRevert();
        vault.setParams(p);
    }

    function test_ZeroFee() public {
        LPVaultBase.Params memory p = defaultParams();
        p.feeBps = 0;
        vm.prank(owner);
        vault.setParams(p);
        deposit(alice, 100_000e6);
        settle(P0);
        _setLpValue(110_000e6);
        settle(P0);
        assertEq(vault.balanceOf(feeTo), 0);
    }

    // ------------------------------------------------------------------ price / epoch checks
    function test_SettleRevertsOutsidePoolBand() public {
        deposit(alice, 1_000e6);
        LPVaultBase.Report memory r = report(P0, 0);
        vault.setPoolPrice(P0 * 1016 / 1000); // pool 1.6% above keeper price, band 1.5%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LPVaultBase.PoolPriceOff.selector, P0 * 1016 / 1000, P0));
        vault.settle(r);
        vault.setPoolPrice(P0 * 1014 / 1000);
        vm.prank(keeper);
        vault.settle(r);
    }

    function test_SettleEpochReplay() public {
        LPVaultBase.Report memory r = report(P0, 0);
        vm.prank(keeper);
        vault.settle(r);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.BadEpoch.selector);
        vault.settle(r);
    }

    function test_OnlyKeeperSettles() public {
        LPVaultBase.Report memory r = report(P0, 0);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotKeeper.selector);
        vault.settle(r);
    }

    function test_HypeValuedAtKeeperPrice() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.swap(false, 40_000e6, P0); // ~997 HYPE
        uint256 hype = address(vault).balance;
        assertApproxEqRel(hype, 997 ether, 1e14);
        settle(P0 * 101 / 100);
        assertEq(vault.lastNav(), 60_000e6 + hype * (P0 * 101 / 100) / 1e18);
    }

    // ------------------------------------------------------------------ swaps
    function test_SwapGuards() public {
        deposit(alice, 100_000e6);
        settle(P0);
        // keeper price too far from pool
        vm.prank(keeper);
        vm.expectRevert();
        vault.swap(false, 1_000e6, P0 * 90 / 100);
        // pool + keeper both drifted beyond the band from the price anchor
        vault.setPoolPrice(P0 * 115 / 100);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.BadPrice.selector);
        vault.swap(false, 1_000e6, P0 * 115 / 100);
        vault.setPoolPrice(P0);
        // turnover cap: 2x NAV per epoch
        vm.startPrank(keeper);
        vault.swap(false, 100_000e6, P0);
        uint256 hype = address(vault).balance;
        vault.swap(true, hype, P0);
        vm.expectRevert(RiskBudgets.Turnover.selector);
        vault.swap(false, 10_000e6, P0);
        vm.stopPrank();
    }

    /// Regression: the turnover budget used to reset on every settle, so a keeper could settle with empty queues
    /// between swaps and churn unbounded notional through the pool. It is now a rolling-day window.
    function test_TurnoverNotResetBySettle() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.swap(false, 100_000e6, P0); // 1x NAV
        settle(P0); // an empty settle used to reset the budget
        uint256 hype = address(vault).balance;
        vm.prank(keeper);
        vm.expectRevert(RiskBudgets.Turnover.selector);
        vault.swap(true, hype, P0); // another ~1x within the same day: > 2x
        skip(1 days);
        settle(P0);
        vm.prank(keeper);
        vault.swap(true, hype, P0); // new window
        (,,,, uint256 used,,,,,,,) = vault.budgets();
        assertEq(used, hype * P0 / 1e18);
    }

    function test_SwapMinOutFromKeeperPrice() public {
        deposit(alice, 100_000e6);
        settle(P0);
        // keeper price 0.9% below the pool and 1.4% below the anchor (inside both bands), but the pool can't
        // deliver within 1% max slippage incl. the 0.3% fee
        vault.setPoolPrice(P0 * 995 / 1000);
        vm.prank(keeper);
        vm.expectRevert(bytes("min out"));
        vault.swap(false, 1_000e6, P0 * 986 / 1000); // asks for cheap HYPE
    }

    // ------------------------------------------------------------------ reserve
    function test_KeeperCannotSpendQueuedDeposits() public {
        deposit(alice, 50_000e6);
        settle(P0);
        deposit(bob, 50_000e6); // queued, not part of NAV
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.ReserveBreached.selector);
        vault.addLiquidity(0, 50_001e6, P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 50_000e6, P0);
    }

    // ------------------------------------------------------------------ hedge
    function test_HedgeMarginCapAndTreasuryOnly() public {
        deposit(alice, 100_000e6);
        settle(P0);
        assertEq(vault.hedgeCap(), 35_000e6);
        vm.prank(keeper);
        vault.sendHedgeMargin(35_000e6);
        assertEq(usdc.balanceOf(treasury), 35_000e6);
        assertEq(vault.hedgeEquity(), 35_000e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LPVaultBase.HedgeCap.selector, 35_000e6 + 1, 35_000e6));
        vault.sendHedgeMargin(1);
        // NAV unchanged by moving margin
        settle(P0);
        assertEq(vault.lastNav(), 100_000e6);
        vm.prank(keeper);
        vault.returnHedgeMargin(10_000e6);
        assertEq(vault.hedgeEquity(), 25_000e6);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotKeeper.selector);
        vault.sendHedgeMargin(1);
    }

    function test_HedgeEquityDecreaseBudgetIncreaseNeedsGuardian() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(30_000e6);
        // keeper alone may lower by up to 5% of NAV (5k) per decaying day
        settle(P0, 26_000e6);
        assertEq(vault.hedgeEquity(), 26_000e6);
        // a further 2k decrease exceeds the remaining 5% x 96k - 4k = 0.8k: clipped, not reverted
        settle(P0, 24_000e6);
        assertEq(vault.hedgeEquity(), 25_200e6);
        // an increase without the guardian is refused (value kept) and the settlement processes no deposits
        uint256 h = vault.hedgeEquity();
        deposit(bob, 10_000e6);
        settle(P0, h + 1);
        assertEq(vault.hedgeEquity(), h);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.pendingDepositAssets(), 10_000e6);
        // guardian co-confirms exactly this value for this epoch: applied, deposits processed, one-shot
        vm.prank(guardian);
        vault.approveHedgeEquity(29_700e6, block.timestamp + 1 hours);
        settle(P0, 29_700e6);
        assertEq(vault.hedgeEquity(), 29_700e6);
        assertGt(vault.balanceOf(bob), 0);
        (,,,,,, uint256 h1, uint256 ep,,,,) = vault.budgets();
        assertEq(h1, 29_700e6);
        assertEq(ep, 0);
    }

    function test_HedgeEquityDecreaseBudgetDecays() public {
        deposit(alice, 100_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.sendHedgeMargin(30_000e6);
        settle(P0, 27_000e6); // -3% of NAV
        uint256 nav = vault.lastNav();
        settle(P0, 27_000e6 - nav * 3 / 100); // another -3%: only ~2% left, clipped
        assertGt(vault.hedgeEquity(), 27_000e6 - nav * 3 / 100);
        uint256 h = vault.hedgeEquity();
        nav = vault.lastNav();
        vm.warp(vm.getBlockTimestamp() + 1 days); // fully restored
        settle(P0, h - nav * 5 / 100);
        assertEq(vault.hedgeEquity(), h - nav * 5 / 100);
    }

    function test_UnhedgedVaultCannotSendMargin() public {
        MockLPVault v = new MockLPVault(config(address(0)), P0);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.NoHedge.selector);
        v.sendHedgeMargin(1);
        LPVaultBase.Params memory p = defaultParams();
        vm.prank(owner);
        vm.expectRevert(LPVaultBase.BadParam.selector);
        v.setParams(p); // hedge cap > 0 without treasury
    }

    // ------------------------------------------------------------------ pause
    function test_PauseBlocksDepositsAndRiskButNotExits() public {
        deposit(alice, 100_000e6);
        settle(P0);
        deposit(bob, 1_000e6); // queued before pause
        vm.prank(guardian);
        vault.setPaused(true);

        vm.prank(carol);
        vm.expectRevert(LPVaultBase.IsPaused.selector);
        vault.requestDeposit(1_000e6);
        vm.startPrank(keeper);
        vm.expectRevert(LPVaultBase.IsPaused.selector);
        vault.addLiquidity(0, 1e6, P0);
        vm.expectRevert(LPVaultBase.IsPaused.selector);
        vault.swap(false, 1e6, P0);
        vault.sendHedgeMargin(1e6); // L-16: topping up the short stays possible while paused
        vm.stopPrank();

        // exits keep working: redeem request + settlement pays it; queued deposit stays queued
        redeem(alice, vault.balanceOf(alice));
        uint256 b = usdc.balanceOf(alice);
        settle(P0);
        // 1 USDC sits at the hedge treasury: the head is filled partially with all idle USDC (M-7)
        assertApproxEqAbs(usdc.balanceOf(alice) - b, 99_999e6, 1);
        assertEq(vault.pendingDepositAssets(), 1_000e6);
        vm.prank(bob);
        vault.cancelDeposit(1);

        // guardian cannot unpause or touch funds; owner unpauses
        vm.prank(guardian);
        vm.expectRevert();
        vault.setPaused(false);
        vm.prank(owner);
        vault.setPaused(false);
        assertFalse(vault.paused());
    }

    // ------------------------------------------------------------------ emergency
    function test_EmergencyUnwind_TooEarly() public {
        vm.expectRevert(LPVaultBase.TooEarly.selector);
        vault.emergencyUnwind();
        // L-2: never before the first settlement, however long the deployment sits idle
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(LPVaultBase.TooEarly.selector);
        vault.emergencyUnwind();
        settle(P0);
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        vm.expectRevert(LPVaultBase.TooEarly.selector);
        vault.emergencyUnwind();
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.emergencyUnwind(); // arms only
        assertFalse(vault.emergency());
        vm.warp(vm.getBlockTimestamp() + 6 hours - 1);
        vm.expectRevert(LPVaultBase.TooEarly.selector);
        vault.emergencyUnwind();
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.emergencyUnwind();
        assertTrue(vault.emergency());
    }

    function test_EmergencyUnwind_ProRataInKind() public {
        deposit(alice, 75_000e6);
        deposit(bob, 25_000e6);
        settle(P0);
        vm.startPrank(keeper);
        vault.swap(false, 40_000e6, P0);
        uint256 hype = address(vault).balance;
        vault.addLiquidity(hype, 40_000e6, P0);
        vault.sendHedgeMargin(10_000e6);
        vm.stopPrank();
        deposit(carol, 5_000e6); // queued deposit
        redeem(bob, vault.balanceOf(bob) / 2); // queued redeem

        vm.prank(makeAddr("anyone"));
        forceEmergency();
        assertEq(vault.lpBase() + vault.lpAsset(), 0);

        // nothing new can happen
        LPVaultBase.Report memory r = report(P0, 10_000e6);
        vm.prank(keeper);
        vm.expectRevert(LPVaultBase.InEmergency.selector);
        vault.settle(r);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.InEmergency.selector);
        vault.requestRedeem(1);

        // queued deposit is refundable in full
        vm.prank(carol);
        vault.cancelDeposit(2);
        assertEq(usdc.balanceOf(carol), 1_000_000e6);

        uint256 onchainUsdc = vault.idleAsset();
        uint256 onchainHype = address(vault).balance;
        uint256 supply = vault.totalSupply();
        uint256 aliceSh = vault.balanceOf(alice);
        uint256 a0 = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyRedeem(aliceSh, alice);
        assertEq(usdc.balanceOf(alice) - a0, onchainUsdc * aliceSh / supply);
        assertEq(alice.balance, onchainHype * aliceSh / supply);

        // keeper returns the hedge margin later: remaining holders get it
        vm.prank(keeper);
        vault.returnHedgeMargin(10_000e6);
        vm.prank(bob);
        vault.cancelRedeem(0);
        uint256 bobSh = vault.balanceOf(bob);
        assertEq(bobSh, vault.totalSupply());
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.emergencyRedeem(bobSh, bob);
        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        // bob: 25% of on-chain value + all 10k returned margin
        assertApproxEqRel(usdc.balanceOf(bob) - b0 + bob.balance * P0 / 1e18, 25_000e6 * 9 / 10 + 10_000e6, 2e15);
    }

    /// L-3: the old 10% band against the (3-day-old) anchor turned the 72 h exit into 7 days in any >10% market
    /// move. Removing liquidity at a pushed price only costs the pusher and the exit is in kind, so it is gone.
    function test_EmergencyUnwind_NotBlockedByPriceMove() public {
        deposit(alice, 10_000e6);
        settle(P0);
        vm.prank(keeper);
        vault.addLiquidity(0, 10_000e6, P0);
        vault.setPoolPrice(P0 / 2); // crashed
        forceEmergency();
        assertEq(vault.lpAsset(), 0);
    }

    function test_EmergencyRedeemOnlyInEmergency() public {
        deposit(alice, 1_000e6);
        settle(P0);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotEmergency.selector);
        vault.emergencyRedeem(1, alice);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotEmergency.selector);
        vault.cancelRedeem(0);
    }

    // ------------------------------------------------------------------ inflation / donation
    function test_InflationAttackBounded() public {
        LPVaultBase.Params memory p = defaultParams();
        p.minDeposit = 1;
        vm.prank(owner);
        vault.setParams(p);
        deposit(bob, 1); // attacker: 1 raw unit
        settle(P0);
        vm.prank(bob);
        usdc.transfer(address(vault), 100_000e6); // donation
        deposit(alice, 1_000e6);
        settle(P0);
        assertGt(vault.balanceOf(alice), 0);
        assertGe(valueOf(alice), 1_000e6 * 99 / 100); // victim loses < 1%
        assertLt(valueOf(bob), 100_000e6); // attacker loses money
    }

    function test_DonationDoesNotHurtHolders() public {
        deposit(alice, 1_000e6);
        settle(P0);
        usdc.mint(address(vault), 500e6);
        deposit(bob, 1_000e6);
        settle(P0);
        assertApproxEqAbs(valueOf(bob), 1_000e6, 2);
        assertGt(valueOf(alice), 1_000e6);
    }

    // ------------------------------------------------------------------ roles
    function test_RoleAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setKeeper(alice);
        vm.prank(guardian);
        vm.expectRevert();
        vault.setKeeper(guardian);
        vm.prank(owner);
        vault.setKeeper(bob);
        assertEq(vault.keeper(), bob);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotGuardian.selector);
        vault.approveHedgeEquity(1, block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotGuardian.selector);
        vault.approvePrice(1, 2, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotGuardian.selector);
        vault.setPaused(true);
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_DepositRedeemRoundTripNeverProfits(uint96 a, uint96 b) public {
        uint256 x = bound(uint256(a), 1e6, 1e12);
        uint256 y = bound(uint256(b), 1e6, 1e12);
        deposit(alice, x);
        settle(P0);
        deposit(bob, y);
        settle(P0);
        uint256 b0 = usdc.balanceOf(bob);
        redeem(bob, vault.balanceOf(bob));
        settle(P0);
        assertLe(usdc.balanceOf(bob) - b0, y);
        assertGe(usdc.balanceOf(bob) - b0 + 2, y);
    }

    // ------------------------------------------------------------------ helpers
    function _setLpValue(uint256 v) internal {
        if (vault.lpAsset() == 0) {
            uint256 idle = vault.idleAsset();
            uint256 px = vault.lastPrice() == 0 ? P0 : vault.lastPrice();
            vm.prank(keeper);
            vault.addLiquidity(0, idle, px);
        }
        vault.simulateLp(0, v);
    }

    function _permitDigest(address o, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                o,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }
}
