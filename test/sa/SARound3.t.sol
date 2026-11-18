// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {HostileAccount} from "./SAHostile.sol";

interface IHybridUpgrade3 {
    function upgradeToAndCall(address impl, bytes calldata data) external payable;
}

interface IDMPause3 {
    function pause() external;
}

interface IPosmModify {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// Audit SA-3 (docs/audit/sa_round3_report_1226.md, docs/audit/sa_round3b_report_1227.md) regressions, grouped by the
/// root-cause classes of docs/audit/sa_round3_rootcause.md. For every Medium: the PoC and a sibling; then the Lows.
contract SARound3Test is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("bob"));
    address internal sink = makeAddr("sink");

    function setUp() public {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ helpers
    function _upgradeTo(uint256 pk, address a, uint8 mode) internal {
        HostileAccount h = new HostileAccount(
            vm.addr(pk), sink, address(usdc), treasury, feeTo, POSM_ADDR, mode, HYBRID_IMPL, address(executor), PERMIT2, 0, 0
        );
        _clientExec1(pk, a, a, 0, abi.encodeCall(IHybridUpgrade3.upgradeToAndCall, (address(h), "")));
        assertTrue(module.isActive(a));
    }

    /// The client itself runs a POSM decrease (liquidity `liq`, 0 = collect fees) or a burn, paying out to `to`.
    function _clientRemove(uint256 pk, address a, uint256 id, bool burn, uint256 liq, address to) internal {
        bytes[] memory ps = new bytes[](2);
        ps[0] = burn ? abi.encode(id, uint128(0), uint128(0), bytes("")) : abi.encode(id, liq, uint128(0), uint128(0), bytes(""));
        ps[1] = abi.encode(address(0), address(usdc), to);
        bytes memory data = abi.encode(abi.encodePacked(burn ? uint8(0x03) : uint8(0x01), uint8(0x11)), ps);
        _clientExec1(pk, a, POSM_ADDR, 0, abi.encodeCall(IPosmModify.modifyLiquidities, (data, block.timestamp + 60)));
    }

    /// A direct USDC transfer into the account (a client flow the books have not seen).
    function _give(address a, uint256 x) internal {
        if (forked) deal(address(usdc), a, usdc.balanceOf(a) + x);
        else MockUSDC(address(usdc)).mint(a, x);
    }

    function _valueAt(uint256 dUsd, uint256 dHype, uint256 ref) internal pure returns (uint256) {
        return dUsd + dHype * ref / 1e18;
    }

    /// Invested account with LP fee income from round-trip volume; pool back at the anchor, anchor trusted.
    function _withFees(uint256 pk) internal returns (address a, uint256 id) {
        (a,, id) = _invested(pk, 30_000e6);
        uint256 ref = module.lastPrice();
        _volume(20_000, 10);
        _moveTo(ref);
        _syncTouch(a); // book everything so far (the keeper's decrease(0) collects: that is yield)
        _volume(20_000, 10); // new, uncollected fees
        _moveTo(ref);
        _stable();
    }

    /// Onboard, ~40% as HYPE, the rest idle USDC (the fee cap is 20% of idle USDC), everything booked.
    function _withHype(uint256 pk, uint256 usd) internal returns (address a) {
        (a,) = _onboardHybrid(pk, usd);
        _buyBase(a, usd * 2 / 5);
        _report();
        _syncTouch(a);
        assertEq(_pending(a), 0);
    }

    function _step(uint256 target) internal {
        _moveTo(target);
        _report();
        _stable();
    }

    // ================================================================== class F: LP fees are yield (1227 M-1)
    /// PoC: the client collects its own position's fees into the account. Round 2 booked the extra idle as a client
    /// deposit, so the fees (already in the value as uncollected fees) left the profit (fee base erosion). Now the
    /// fees paid out of a tracked position since the books' last look are added to the snapshot first: contributed
    /// does not move, the fees stay profit.
    function test_M1_PoC_ClientCollectIsProfit() public {
        (address a, uint256 id) = _withFees(ALICE_PK);
        uint256 ref = module.lastPrice();
        int256 c0 = _acct(a).contributed;
        int256 p0 = _profit(a);
        (uint256 u0, uint256 h0) = (usdc.balanceOf(a), a.balance);
        _clientRemove(ALICE_PK, a, id, false, 0, a);
        uint256 fees = _valueAt(usdc.balanceOf(a) - u0, a.balance - h0, ref);
        assertGt(fees, 1e6, "fees collected");
        assertApproxEqAbs(_pending(a), 0, 2, "fees are not a client flow");
        vm.prank(keeper);
        module.sync(a);
        assertApproxEqAbs(_acct(a).contributed, c0, 2, "nothing booked as a deposit");
        assertApproxEqAbs(_profit(a), p0, 2, "the fees stay profit");
    }

    /// Siblings: fees taken to an outside address leave the account and the profit (SA-4: never credited above the
    /// idle surplus); a client burn books the principal as an outflow and its fees as a contribution (SA-4 H-1: a
    /// changed position credits nothing), so the profit ends where the outside collect left it.
    function test_M1_Sibling_CollectToOutsideAndBurn() public {
        (address a, uint256 id) = _withFees(ALICE_PK);
        uint256 ref = module.lastPrice();
        int256 c0 = _acct(a).contributed;
        address eoa = vm.addr(ALICE_PK);
        uint256 snap = vm.snapshotState();

        (uint256 u0, uint256 h0) = (usdc.balanceOf(eoa), eoa.balance);
        _clientRemove(ALICE_PK, a, id, false, 0, eoa);
        uint256 fees = _valueAt(usdc.balanceOf(eoa) - u0, eoa.balance - h0, ref);
        int256 p0 = _profit(a);
        vm.prank(keeper);
        module.sync(a);
        // SA-4 H-1 (idle-surplus cap): fees that did not reach the account are not credited as yield; they leave the
        // profit (our fee lower) instead of being booked as a withdrawal of profit
        assertGt(fees, 1e6);
        assertApproxEqAbs(_acct(a).contributed, c0, 2, "outside collect: nothing booked");
        assertApproxEqAbs(_profit(a), p0, 2);
        int256 pCollect = _profit(a);

        vm.revertToState(snap);
        _clientRemove(ALICE_PK, a, id, true, 0, a);
        vm.prank(keeper);
        module.sync(a);
        assertEq(module.positionsOf(a).length, 0, "burned position dropped");
        // the burned principal is booked at the anchor (the pool is within 3 bps of it): fees stay as profit
        assertApproxEqRel(_profit(a), pCollect, 1e14, "burn keeps the fees as profit");
    }

    // ================================================================== class S: swap record bound to the call (1227 M-2)
    /// PoC: account code replaces the module's swap with its own swap through the same executor (no price limit,
    /// min-out 1). Round 2 accepted any new record for the payer. Now the record carries the hash of the calldata the
    /// executor ran and must equal the module's call.
    function test_M2_PoC_SubstitutedSwapRefused() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        _upgradeTo(ALICE_PK, a, 7);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.BelowMinOutOrBadSwap.selector);
        module.swap(a, true, 1 ether, p, 0);
    }

    /// Sibling: a swap in the other direction (USDC sold instead of HYPE, trace B) is refused as well.
    function test_M2_Sibling_OtherDirectionRefused() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        _upgradeTo(ALICE_PK, a, 8);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.BelowMinOutOrBadSwap.selector);
        module.swap(a, true, 1 ether, p, 0);
    }

    // ================================================================== class P: fee at the anchor, gated (M-3, M-6)
    /// PoC (1227 M-3): the keeper walks anchor and pool up within its budget and charges at once. Now the fee needs
    /// the anchor within poolBandBps (1.5%) of its trailing 24 h low and not above the pool; a walked anchor must be
    /// held for a day in public view first.
    function test_M3_PoC_WalkThenFeeGated() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 ref = module.lastPrice();
        _step(ref);
        _step(ref * 101 / 100);
        _step(ref * 102 / 100);
        _moveTo(module.lastPrice() * 1001 / 1000); // pool at / above the anchor: only the trailing-low gate is left
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
        for (uint256 i; i < 10; ++i) {
            vm.warp(vm.getBlockTimestamp() + 3 hours);
            _step(module.lastPrice());
        }
        _moveTo(module.lastPrice() * 1001 / 1000); // the fee also needs the anchor not above the pool
        // SA-5 M-3: a day at the level is not enough when the level is more than poolBandBps above the
        // guardian-confirmed one
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
        _confirm();
        _stable();
        _moveTo(module.lastPrice() * 1001 / 1000);
        vm.prank(keeper);
        assertGt(module.chargeFee(a), 0, "after a day at the level and the guardian's confirmation the gain is chargeable");
    }

    /// Sibling: an anchor above the pool (even inside the booking band) carries no fee.
    function test_M3_Sibling_AnchorAbovePoolNoFee() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 ref = module.lastPrice();
        _moveTo(ref * 1004 / 1000);
        _report();
        _stable();
        _moveTo(ref * 1001 / 1000);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
    }

    /// PoC (1226 M-1 / 1227 M-6): a deposit parked in the account just before the fee. chargeFee books every pending
    /// flow at the anchor the profit is measured at, so the deposit is neutral: the fee is the same with or without it.
    function test_M6_PoC_ParkedDepositNeutral() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 ref = module.lastPrice();
        _step(ref * 1005 / 1000); // SA-5 M-3: within poolBandBps of the confirmed level (the first report)
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        _step(module.lastPrice());
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 f1 = module.chargeFee(a);
        assertGt(f1, 0);
        vm.revertToState(snap);
        _give(a, 10_000e6); // the client's parked deposit, not booked yet
        vm.prank(keeper);
        uint256 f2 = module.chargeFee(a);
        assertApproxEqAbs(f2, f1, 1, "a parked deposit does not change the fee");
    }

    /// Sibling: a client withdrawal right before the fee is neutral too (no fee on principal taken out).
    function test_M6_Sibling_ParkedWithdrawalNeutral() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 ref = module.lastPrice();
        _step(ref * 1005 / 1000); // SA-5 M-3: within poolBandBps of the confirmed level (the first report)
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        _step(module.lastPrice());
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 f1 = module.chargeFee(a);
        vm.revertToState(snap);
        _clientExec1(ALICE_PK, a, address(usdc), 0, abi.encodeCall(IERC20.transfer, (vm.addr(ALICE_PK), 5_000e6)));
        vm.prank(keeper);
        uint256 f2 = module.chargeFee(a);
        assertApproxEqAbs(f2, f1, 1, "a withdrawal does not change the fee");
    }

    // ================================================================== class T: booking only at a trusted anchor (M-4, M-5)
    /// PoC (1227 M-4): the pool is pushed 0.8% off the anchor (inside poolBandBps) and a pending deposit is booked by
    /// a keeper action at that instant. Now booking needs the pool within BOOK_BAND_BPS (0.5%) of the anchor: the
    /// flow stays pending, exact, and is booked once the pool is back.
    function test_M4_PoC_NoBookingOffTheBookBand() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        uint256 ref = module.lastPrice();
        int256 c0 = _acct(a).contributed;
        _give(a, 1_000e6);
        _moveTo(ref * 1008 / 1000);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.sync(a);
        vm.prank(keeper);
        module.reportHedgeEquity(a, 0); // a keeper action that syncs
        assertEq(_acct(a).contributed, c0, "nothing booked off the band");
        assertEq(_pending(a), 1_000e6, "still pending, exact");
        _moveTo(ref);
        _stable();
        vm.prank(keeper);
        module.sync(a);
        assertEq(_acct(a).contributed, c0 + 1_000e6, "booked at the anchor");
    }

    /// Sibling: swaps and LP adds need the same trusted anchor (their sync must book), so they wait too.
    function test_M4_Sibling_SwapAndAddWaitForBand() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        uint256 ref = module.lastPrice();
        _moveTo(ref * 1008 / 1000);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.swap(a, false, 100e6, p, 0);
        (int24 tl, int24 tu) = _range(300);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.mintPosition(a, tl, tu, 1e9, type(uint128).max, type(uint128).max, p);
    }

    /// PoC (1226 M-2 / 1227 M-5): the booking moment was the keeper's choice (any action syncs; swaps synced on a
    /// fresh-but-moving anchor). Now swaps / adds need a trusted anchor and the client can book a pending flow with
    /// `sync(a)` at the first trusted moment (SA-5 L-3: the keeper, the account or its owner; no third party).
    function test_M5_PoC_AnyoneBooksAtTrustedAnchor() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        int256 c0 = _acct(a).contributed;
        _give(a, 2_000e6);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LPManagerModule.NotOwnAccount.selector);
        module.sync(a);
        vm.prank(vm.addr(ALICE_PK)); // the client's owner EOA
        module.sync(a);
        assertEq(_acct(a).contributed, c0 + 2_000e6);
    }

    /// Sibling: right after an anchor move (and after a report gap) swaps wait for minPriceStable.
    function test_M5_Sibling_SwapNeedsStableAnchor() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        uint256 ref = module.lastPrice();
        _moveTo(ref * 1003 / 1000);
        _report();
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.swap(a, false, 100e6, p, 0);
        _stable();
        vm.warp(vm.getBlockTimestamp() + 301); // no report for longer than minPriceStable
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.swap(a, false, 100e6, p, 0);
    }

    // ================================================================== Lows
    /// L-5 (1227) / L-4 (1226): a report after a gap longer than minPriceStable counts as a move.
    function test_L5_ReportAfterGapIsAMove() public {
        _report();
        uint256 t0 = module.lastPriceMoved();
        vm.warp(vm.getBlockTimestamp() + 200);
        _report();
        assertEq(module.lastPriceMoved(), t0, "a confirmation inside the window is not a move");
        vm.warp(vm.getBlockTimestamp() + 301);
        _report();
        assertEq(module.lastPriceMoved(), block.timestamp, "after a gap it is");
    }

    /// L-3: a keeper-only decrease that cannot happen (paused) changes nothing; a full return clears the flag.
    function test_L3_HedgeFlagOnlyWhileItMatters() public {
        address a = _withHype(ALICE_PK, 30_000e6);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 6_000e6);
        uint256 t0 = _acct(a).hedgeTime;
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(guardian);
        module.setPaused(true);
        _reportEquity(a, 1_000e6);
        assertEq(_acct(a).hedgeEquity, 6_000e6);
        assertFalse(_acct(a).hedgeClipped, "no flag while no decrease is possible");
        assertEq(_acct(a).hedgeTime, t0, "no report time either");
        _schedule(address(module), abi.encodeCall(LPManagerModule.setPaused, (false)));
        _report();
        _reportEquity(a, 0); // 6000 > 5% step: clipped
        assertTrue(_acct(a).hedgeClipped);
        uint256 h = _acct(a).hedgeEquity;
        vm.prank(keeper);
        module.returnHedgeMargin(a, h);
        assertFalse(_acct(a).hedgeClipped, "nothing left to overstate");
    }

    /// L-5 / L-7 (1226): a permit used through the front-run fallback cannot be used a second time.
    function test_L7_PermitFallbackOnce() public {
        address o = vm.addr(ALICE_PK);
        _deal(o, 20_000e6);
        address a = _deployHybrid(o);
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(ALICE_PK, address(module), 10_000e6, dl);
        IERC20Permit(address(usdc)).permit(o, address(module), 10_000e6, dl, v, r, s); // front-run
        vm.prank(relayer);
        module.onboard(d, 10_000e6, dl, v, r, s);
        assertEq(usdc.balanceOf(a), 10_000e6);
        vm.prank(o);
        usdc.approve(address(module), 10_000e6); // a standing allowance of the same amount
        vm.prank(relayer);
        vm.expectRevert(SALib.BadPermit.selector);
        module.onboard(d, 10_000e6, dl, v, r, s);
    }

    /// L-6 (1226): no pull into an account that is not live (DelegationManager paused); isActive says so.
    function test_L6_OnboardNeedsLive() public {
        address o = vm.addr(ALICE_PK);
        _deal(o, 10_000e6);
        address a = _deployHybrid(o);
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        vm.prank(relayer);
        module.register(d);
        vm.prank(DM_OWNER);
        IDMPause3(DM_ADDR).pause();
        assertFalse(module.isActive(a));
        (uint8 v, bytes32 r, bytes32 s) = _permit(ALICE_PK, address(module), 10_000e6, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(LPManagerModule.NotLive.selector);
        module.onboard(d, 10_000e6, block.timestamp + 1 hours, v, r, s);
        assertEq(usdc.balanceOf(o), 10_000e6);
    }

    /// L-14 (1226): an account can revoke before it is registered; the relayer then cannot register it, the client
    /// can.
    function test_L14_RevokeBeforeRegister() public {
        address o = vm.addr(ALICE_PK);
        address a = _deployHybrid(o);
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        vm.prank(a);
        module.revoke(a);
        vm.prank(relayer);
        vm.expectRevert(SALib.NotOwnAccount.selector);
        module.register(d);
        vm.prank(o);
        module.register(d);
        assertTrue(module.isActive(a));
    }

    /// transferOwnership(0) cancels a pending transfer; I-2: a repeated pause is refused (it would void approvals).
    function test_L_OwnershipCancelAndPauseRepeat() public {
        address n = makeAddr("newOwner");
        _schedule(address(module), abi.encodeCall(module.transferOwnership, (n)));
        assertEq(module.pendingOwner(), n);
        _schedule(address(module), abi.encodeCall(module.transferOwnership, (address(0))));
        assertEq(module.pendingOwner(), address(0));
        vm.prank(guardian);
        module.setPaused(true);
        vm.prank(guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.setPaused(true);
    }

    /// L-12 / I-3 / L-13: no operation with a delay above MAX_DELAY; an expired operation reports itself expired; the
    /// proposer role cannot be renounced.
    function test_L12_TimelockDelayCapExpiryRenounce() public {
        bytes memory data = abi.encodeCall(LPManagerModule.setPaused, (false));
        uint256 cap = timelock.MAX_DELAY();
        vm.prank(operator);
        vm.expectRevert(VaultTimelock.DelayAboveCap.selector);
        timelock.schedule(address(module), 0, data, bytes32(0), bytes32("x"), cap + 1);
        vm.prank(operator);
        timelock.schedule(address(module), 0, data, bytes32(0), bytes32("y"), 2 days);
        bytes32 id = timelock.hashOperation(address(module), 0, data, bytes32(0), bytes32("y"));
        vm.warp(vm.getBlockTimestamp() + 2 days + 7 days + 1);
        assertTrue(timelock.isExpired(id));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VaultTimelock.OperationExpired.selector, id));
        timelock.execute(address(module), 0, data, bytes32(0), bytes32("y"));
        bytes32 role = timelock.PROPOSER_ROLE();
        vm.prank(operator);
        vm.expectRevert(VaultTimelock.NoRenounce.selector);
        timelock.renounceRole(role, operator);
    }
}
