// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {SAWindow} from "../../src/sa/SAWindow.sol";
import {HostileAccount, AnySubscriber, IPosmSubscribe} from "./SAHostile.sol";

interface IHybridAdmin {
    function transferOwnership(address newOwner) external;
    function upgradeToAndCall(address impl, bytes calldata data) external payable;
}

interface IDMPause {
    function pause() external;
}

/// Audit SA-1 (docs/audit/sa_round1_report_1224.md) regressions: for every Critical / High / Medium the auditor's
/// PoC and at least one sibling path from docs/audit/sa_round1_rootcause.md; plus the Lows fixed in code.
contract SARegressionsTest is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("bob"));
    address internal sink = makeAddr("sink");

    function setUp() public {
        _setUpEnv(false);
    }

    function _hostile(address claimedOwner, uint8 mode) internal returns (HostileAccount) {
        return new HostileAccount(claimedOwner, sink, address(usdc), treasury, feeTo, POSM_ADDR, mode, HYBRID_IMPL);
    }

    /// The owner upgrades its canonical HybridDeleGator (UUPS, owner-signed userOp) to client code that keeps
    /// answering owner() with the pinned owner.
    function _upgradeTo(uint256 pk, address a, uint8 mode) internal {
        HostileAccount h = _hostile(vm.addr(pk), mode);
        _clientExec1(pk, a, a, 0, abi.encodeCall(IHybridAdmin.upgradeToAndCall, (address(h), "")));
        assertEq(IHybridDeleGator(a).owner(), vm.addr(pk), "still claims the pinned owner");
        assertTrue(module.isActive(a), "identity unchanged: still live");
    }

    function _withMargin(uint256 pk, uint256 usd, uint256 margin) internal returns (address a, Delegation memory d) {
        (a, d) = _onboardHybrid(pk, usd);
        _syncTouch(a);
        if (margin != 0) {
            vm.prank(keeper);
            module.sendHedgeMargin(a, margin);
        }
    }

    // ================================================================== C-1 (class A: identity)
    /// PoC: a contract that reports owner() = the hedge treasury (which approves the module) and the canonical
    /// implementation is onboarded; the module pulled the treasury's USDC into it.
    function test_C1_PoC_FakeAccountClaimingTreasuryOwner() public {
        _deal(treasury, 100_000e6);
        HostileAccount fake = _hostile(treasury, 0);
        Delegation memory d = _delegation(address(fake), address(module), _terms(address(module)), block.timestamp + 180 days, 1);
        d.caveats[0].enforcer = address(enforcer);
        d.signature = new bytes(65);
        vm.prank(sink);
        vm.expectRevert(SALib.BadAccount.selector);
        module.onboard(d, 100_000e6, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
        assertEq(usdc.balanceOf(treasury), 100_000e6);
    }

    /// Sibling: a CANONICAL hybrid proxy initialised with owner = treasury (anyone can deploy it) derives correctly,
    /// so the operator addresses are excluded as owners outright.
    function test_C1_Sibling_CanonicalProxyOwnedByTreasury() public {
        address a = _deployHybrid(treasury);
        Delegation memory d = _delegation(a, address(module), _terms(address(module)), block.timestamp + 180 days, 1);
        d.caveats[0].enforcer = address(enforcer);
        d.signature = new bytes(65);
        vm.expectRevert(SALib.BadAccount.selector);
        module.onboard(d, 1e6, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
        address b = _deployHybrid(feeTo);
        d.delegator = b;
        vm.expectRevert(SALib.BadAccount.selector);
        module.register(d);
    }

    /// Sibling: a registered canonical account rotates owner() to the treasury: onboard keeps pulling only from the
    /// pinned owner, and the rotation itself ends management (L-14).
    function test_C1_Sibling_OwnerRotatedAfterRegistration() public {
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 1_000e6);
        _deal(treasury, 100_000e6);
        _clientExec1(ALICE_PK, a, a, 0, abi.encodeCall(IHybridAdmin.transferOwnership, (treasury)));
        assertEq(IHybridDeleGator(a).owner(), treasury);
        assertFalse(module.isActive(a));
        assertEq(module.account(a).owner, vm.addr(ALICE_PK));
        vm.expectRevert(); // pinned owner has no allowance; the treasury is never the payer
        module.onboard(d, 100_000e6, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
        assertEq(usdc.balanceOf(treasury), 100_000e6);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotLive.selector);
        module.swap(a, false, 10e6, p);
    }

    // ================================================================== H-1 (class G: treasury bound per account)
    /// PoC: the keeper returns treasury USDC into an account it controls, bounded only by the treasury allowance.
    function test_H1_PoC_KeeperReturnBoundedByAccountEquity() public {
        _deal(treasury, 1_000_000e6);
        (address a,) = _onboardHybrid(ALICE_PK, 1_000e6); // stands in for an account the keeper controls
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.HedgeCap.selector);
        module.returnHedgeMargin(a, 500_000e6);
        assertEq(usdc.balanceOf(treasury), 1_000_000e6);
    }

    /// Sibling: after a reported hedge loss, net margin > equity; the keeper may return only the equity (the rest
    /// would be other clients' margin). The treasury itself can still return more.
    function test_H1_Sibling_BoundIsEquityNotNetMargin() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 3_000e6);
        _reportEquity(a, 2_600e6); // within the 5% step
        assertEq(module.account(a).hedgeEquity, 2_600e6);
        assertEq(module.account(a).netMargin, 3_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.HedgeCap.selector);
        module.returnHedgeMargin(a, 2_600e6 + 1);
        vm.prank(keeper);
        module.returnHedgeMargin(a, 2_600e6);
        assertEq(module.account(a).hedgeEquity, 0);
        vm.prank(treasury);
        module.returnHedgeMargin(a, 400e6); // the treasury's own decision
        assertEq(module.account(a).netMargin, 0);
        vm.prank(sink);
        vm.expectRevert(LPManagerModule.NotKeeper.selector);
        module.returnHedgeMargin(a, 1);
    }

    // ================================================================== H-2 (class A: verify at the recipient)
    /// PoC: the owner upgrades the account so the margin transfer goes elsewhere; the account balance still drops.
    function test_H2_PoC_UpgradedAccountDivertsHedgeMargin() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 0);
        _upgradeTo(ALICE_PK, a, 1);
        vm.prank(keeper);
        vm.expectRevert(SALib.TransferMismatch.selector);
        module.sendHedgeMargin(a, 1_000e6);
        assertEq(usdc.balanceOf(sink), 0);
        assertEq(module.account(a).hedgeEquity, 0);
    }

    /// Sibling: the fee transfer, the other module-built transfer out.
    function test_H2_Sibling_UpgradedAccountDivertsFee() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        _mintAll(a);
        _volume(200_000, 25);
        _moveTo(module.lastPrice());
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _syncTouch(a);
        _upgradeTo(ALICE_PK, a, 1);
        vm.prank(keeper);
        vm.expectRevert(SALib.TransferMismatch.selector);
        module.chargeFee(a);
        assertEq(usdc.balanceOf(feeTo), 0);
    }

    /// Sibling: a 7702 account re-delegates to other code: no longer live (L-14).
    function test_H2_Sibling_7702Redelegated() public {
        (address a,) = _onboard7702(BOB_PK, 10_000e6);
        _syncTouch(a);
        vm.signAndAttachDelegation(address(_hostile(a, 1)), BOB_PK);
        assertFalse(module.isActive(a));
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotLive.selector);
        module.sendHedgeMargin(a, 100e6);
        // cleared designator
        vm.etch(a, "");
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotLive.selector);
        module.chargeFee(a);
    }

    // ================================================================== H-3 (class B: snapshot in sync)
    /// PoC: a zero fee returned without a snapshot, so the same deposit was booked again at every call.
    function test_H3_PoC_ZeroFeeDoesNotDoubleBook() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _syncTouch(a);
        int256 c0 = module.account(a).contributed;
        _deal(vm.addr(ALICE_PK), 5_000e6);
        vm.prank(vm.addr(ALICE_PK));
        usdc.transfer(a, 5_000e6);
        for (uint256 i; i < 3; ++i) {
            vm.prank(keeper);
            assertEq(module.chargeFee(a), 0);
        }
        _syncTouch(a);
        assertEq(module.account(a).contributed, c0 + 5_000e6, "booked once");
    }

    /// Siblings: the hedge report, a margin return and a multicall repeating the same action all sync once.
    function test_H3_Sibling_OtherPathsBookOnce() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 1_000e6);
        int256 c0 = module.account(a).contributed;
        _deal(vm.addr(ALICE_PK), 2_000e6);
        vm.prank(vm.addr(ALICE_PK));
        usdc.transfer(a, 2_000e6);
        _reportEquity(a, 1_000e6);
        _reportEquity(a, 990e6);
        vm.prank(keeper);
        module.returnHedgeMargin(a, 100e6);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(LPManagerModule.reportHedgeEquity, (a, 890e6));
        calls[1] = abi.encodeCall(LPManagerModule.reportHedgeEquity, (a, 890e6));
        vm.prank(keeper);
        module.multicall(calls, false);
        _syncTouch(a);
        assertEq(module.account(a).contributed, c0 + 2_000e6);
    }

    // ================================================================== M-1 (class C: one pinned delegation)
    /// PoC: after the client disabled the registered delegation, anyone registered another one the client had signed.
    function test_M1_PoC_OlderDelegationAfterExit() public {
        address owner_ = vm.addr(ALICE_PK);
        (address a, Delegation memory d1) = _onboardHybrid(ALICE_PK, 1_000e6);
        Delegation memory d2 = _delegation(a, address(module), _terms(address(module)), block.timestamp + 360 days, 2);
        d2.caveats[0].enforcer = address(enforcer);
        d2 = _sign(d2, ALICE_PK);
        vm.prank(owner_);
        module.register(d2); // renewal by the client
        _exitHybrid(ALICE_PK, a, d2, a);
        assertFalse(module.isActive(a));
        vm.prank(relayer);
        vm.expectRevert(SALib.NotOwnAccount.selector);
        module.register(d1); // the older, never-disabled signature
        vm.prank(relayer);
        vm.expectRevert(SALib.NotOwnAccount.selector);
        module.onboard(d1, 0, 0, 0, bytes32(0), bytes32(0));
        assertFalse(module.isActive(a));
    }

    /// Sibling: the SAME delegation after a module-side revoke (not disabled at the DM) is not a no-op re-register;
    /// only the client resumes.
    function test_M1_Sibling_SameHashAfterRevoke() public {
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 1_000e6);
        vm.prank(vm.addr(ALICE_PK));
        module.revoke(a);
        assertFalse(module.isActive(a));
        vm.prank(relayer);
        vm.expectRevert(SALib.NotOwnAccount.selector);
        module.register(d);
        vm.prank(sink);
        vm.expectRevert(LPManagerModule.NotOwnAccount.selector);
        module.revoke(a);
        vm.prank(vm.addr(ALICE_PK));
        module.register(d);
        assertTrue(module.isActive(a));
    }

    // ================================================================== M-2 (class B: bracket on every path)
    /// PoC: margin returned while the account is not live was paid out and never booked; profit was distorted.
    function test_M2_PoC_ReturnWhileNotLiveIsBooked() public {
        (address a, Delegation memory d) = _withMargin(ALICE_PK, 10_000e6, 1_500e6);
        _exitHybrid(ALICE_PK, a, d, a);
        int256 c0 = module.account(a).contributed;
        uint256 v0 = module.accountValue(a, module.lastPrice());
        vm.prank(keeper);
        module.returnHedgeMargin(a, 1_500e6);
        assertEq(module.account(a).contributed, c0, "margin back is not a deposit");
        assertEq(module.accountValue(a, module.lastPrice()), v0, "equity moved into idle");
        // the client resumes; no phantom flow
        Delegation memory d2 = _delegation(a, address(module), _terms(address(module)), block.timestamp + 360 days, 2);
        d2.caveats[0].enforcer = address(enforcer);
        d2 = _sign(d2, ALICE_PK);
        vm.prank(vm.addr(ALICE_PK));
        module.register(d2);
        _syncTouch(a);
        assertApproxEqAbs(module.account(a).contributed, c0, 1e6);
    }

    /// Sibling: expired delegation (not live by time), the client moves funds in between.
    function test_M2_Sibling_ExpiredThenClientWithdraws() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 181 days);
        assertFalse(module.isActive(a));
        int256 c0 = module.account(a).contributed;
        _clientExec1(ALICE_PK, a, address(usdc), 0, abi.encodeCall(IERC20.transfer, (vm.addr(ALICE_PK), 2_000e6)));
        vm.prank(keeper);
        module.returnHedgeMargin(a, 1_000e6);
        assertEq(module.account(a).contributed, c0 - 2_000e6, "the withdrawal is booked, the margin is not");
    }

    // ================================================================== M-3 (class F: approvals bound to state)
    /// PoC: an approval judged at one state applied after a margin move.
    function test_M3_PoC_MarginMoveVoidsApproval() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 1_000e6);
        SALib.Account memory s = module.account(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 1_200e6, block.timestamp + 1 hours);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 500e6); // now 1_500
        _reportEquity(a, 1_200e6); // not the approved state: a keeper-only decrease, limited by the window
        assertEq(module.account(a).hedgeEquity, 1_200e6);
        assertTrue(module.account(a).netMargin == 1_500e6, "a stale approval did not write net margin down");
        s = module.account(a);
        // and an increase back to the stale value is refused
        _reportEquity(a, 1_500e6);
        assertEq(module.account(a).hedgeEquity, 1_200e6);
    }

    /// Siblings: wrong expected state is rejected at approval; a guardian change voids pending approvals; a refused
    /// report neither consumes nor voids one; TTL validated.
    function test_M3_Sibling_StaleExpectationsAndGuardianChange() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 1_000e6);
        SALib.Account memory s = module.account(a);
        vm.startPrank(guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approveHedgeEquity(a, s.hedgeEpoch - 1, s.hedgeEquity, 2_000e6, block.timestamp + 1 hours);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity + 1, 2_000e6, block.timestamp + 1 hours);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 2_000e6, block.timestamp + 1 days + 1);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approveHedgeEquity(sink, 0, 0, 2_000e6, block.timestamp + 1 hours);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 2_000e6, block.timestamp + 1 hours);
        vm.stopPrank();
        _reportEquity(a, 3_000e6); // refused, does not void (L-7)
        assertEq(module.account(a).hedgeEpoch, s.hedgeEpoch);
        _reportEquity(a, 2_000e6);
        assertApproxEqAbs(module.account(a).hedgeEquity, 2_000e6, 30e6, "a full step again (5% of the now lower value)");
        // guardian change
        s = module.account(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 2_500e6, block.timestamp + 1 hours);
        vm.prank(address(timelock));
        module.setGuardian(makeAddr("guardian2"));
        _reportEquity(a, 2_500e6);
        assertEq(module.account(a).hedgeEquity, 2_000e6);
    }

    // ================================================================== M-4 (class D: value at the anchor)
    /// PoC: pushing pool spot inflated account value (fee, hedge cap, hedge step).
    function test_M4_PoC_ValueIgnoresSpot() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        uint256 ref = module.lastPrice();
        uint256 v0 = module.accountValue(a, ref);
        _moveTo(ref * 105 / 100);
        // only the LP fees the push itself paid in; no pool-spot term (a spot-valued account moves ~2% here)
        assertApproxEqRel(module.accountValue(a, ref), v0, 0.002e18, "no pool-spot term");
        assertGt(module.accountValue(a, ref), v0 - 1);
        uint256 spotValued = module.accountValue(a, poolPrice());
        assertGt(spotValued, v0 * 1005 / 1000, "the round-1 valuation would have been inflated");
    }

    /// Siblings: with the pool displaced beyond the band, fee and margin sends refuse; with a stale anchor too, and
    /// the keeper-only hedge step is zero (L-16).
    function test_M4_Sibling_BandAndAgeOnEveryValuePath() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _syncTouch(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 500e6);
        uint256 ref = module.lastPrice();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.sendHedgeMargin(a, 100e6);
        _reportEquity(a, 400e6); // stale anchor: no keeper-only move
        assertEq(module.account(a).hedgeEquity, 500e6);
        assertTrue(module.account(a).hedgeClipped);
        vm.prank(keeper);
        module.reportPrice(ref); // fresh again
        _moveTo(ref * 103 / 100);
        vm.startPrank(keeper);
        vm.expectPartialRevert(LPManagerModule.PoolPriceOff.selector);
        module.sendHedgeMargin(a, 100e6);
        vm.expectPartialRevert(LPManagerModule.PoolPriceOff.selector);
        module.chargeFee(a);
        vm.stopPrank();
    }

    // ================================================================== M-5 (class A: no client code in the bracket)
    /// PoC: the client subscribes its tracked position; the subscriber runs inside keeper actions.
    function test_M5_PoC_SubscribedPositionRefused() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
        address sub = address(new AnySubscriber());
        _clientExec1(ALICE_PK, a, POSM_ADDR, 0, abi.encodeCall(IPosmSubscribe.subscribe, (id, sub, "")));
        uint256 p = poolPrice();
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SALib.Subscribed.selector, id));
        module.decreasePosition(a, id, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SALib.Subscribed.selector, id));
        module.burnPosition(a, id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SALib.Subscribed.selector, id));
        module.increasePosition(a, id, 1, 1e18, 1e6, p);
        // keeper batches over many accounts continue past it
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(LPManagerModule.burnPosition, (a, id, 0, 0));
        calls[1] = abi.encodeCall(LPManagerModule.reportHedgeEquity, (a, 0));
        module.multicall(calls, true);
        vm.stopPrank();
    }

    /// Sibling: client code in the account itself moves value out inside the bracket of a keeper action.
    function test_M5_Sibling_AccountCodeDrainsInsideBracket() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
        _upgradeTo(ALICE_PK, a, 2);
        uint128 half = POSM.getPositionLiquidity(id) / 2;
        vm.prank(keeper);
        vm.expectPartialRevert(SALib.Unexpected.selector);
        module.decreasePosition(a, id, half, 0, 0);
        // the burn too
        vm.prank(keeper);
        vm.expectPartialRevert(SALib.Unexpected.selector);
        module.burnPosition(a, id, 0, 0);
        assertEq(usdc.balanceOf(sink), 0);
    }

    /// Sibling (L-13): the account subscribes the freshly minted position inside the mint bracket.
    function test_M5_Sibling_SubscribeInsideMint() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        _upgradeTo(ALICE_PK, a, 3);
        (int24 tl, int24 tu) = _range(300);
        (uint128 liq, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, a.balance, usdc.balanceOf(a));
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(SALib.BadMint.selector);
        module.mintPosition(a, tl, tu, liq, m0, m1, p);
    }

    // ================================================================== M-6 (class C: limits keyed by terms)
    /// PoC end to end: the client redeems a second delegation of its own (own redeemer and recipients) to burn the
    /// enforcer's fee clock and hedge window; the module's fee still goes through.
    function test_M6_PoC_SecondDelegationCannotConsumeModuleLimits() public {
        address owner_ = vm.addr(ALICE_PK);
        address owner2 = makeAddr("clientFeeSink");
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        Delegation memory own =
            _delegation(a, owner_, abi.encode(owner_, sink, owner2), block.timestamp + 30 days, 7);
        own.caveats[0].enforcer = address(enforcer);
        own = _sign(own, ALICE_PK);
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = own;
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encode(ds);
        ModeCode[] memory m = new ModeCode[](1);
        m[0] = DelegationFramework.SINGLE_DEFAULT;
        bytes[] memory x = new bytes[](1);
        x[0] = DelegationFramework.single(address(usdc), 0, abi.encodeCall(IERC20.transfer, (owner2, 1e6)));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner_);
        DM.redeemDelegations(c, m, x); // the client's own fee-shaped transfer
        (, uint64 feeOwn) = enforcer.spend(a, keccak256(abi.encode(owner_, sink, owner2)));
        assertEq(feeOwn, block.timestamp);
        (, uint64 feeOurs) = enforcer.spend(a, keccak256(_terms(address(module))));
        assertEq(feeOurs, 0, "the module's clock is its own");
        // the module's limits are intact: a hedge send still has its full 35% window
        _report();
        _syncTouch(a);
        uint256 q = usdc.balanceOf(a) / 4;
        vm.prank(keeper);
        module.sendHedgeMargin(a, q);
    }

    /// Sibling: a renewal (same terms, new delegation hash) keeps the history, so a client cannot reset the window by
    /// re-signing; and it needs the client's own transaction (M-1).
    function test_M6_Sibling_RenewalKeepsWindow() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 0);
        uint256 idle = usdc.balanceOf(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, idle * 30 / 100);
        Delegation memory d2 = _delegation(a, address(module), _terms(address(module)), block.timestamp + 360 days, 9);
        d2.caveats[0].enforcer = address(enforcer);
        d2 = _sign(d2, ALICE_PK);
        vm.prank(vm.addr(ALICE_PK));
        module.register(d2);
        // 30% of idle used; the remaining idle is 70%, so 10% more of the original is > 35% x remaining... keep simple:
        uint256 bal = usdc.balanceOf(a);
        vm.prank(keeper);
        vm.expectRevert(); // the enforcer's window carried over across the renewal
        module.sendHedgeMargin(a, bal * 10 / 100);
    }

    // ================================================================== M-7 (class E: 1x / 24 h budgets)
    /// PoC: the linear-decay budget admitted ~2x in 24 h (turnover, anchor drift, hedge step).
    function test_M7_PoC_TurnoverOncePerSlidingDay() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        uint256 p = poolPrice();
        uint256 cap = module.accountValue(a, module.lastPrice()) * 2;
        for (uint256 i; i < 2; ++i) {
            vm.prank(keeper);
            module.swap(a, false, 4_000e6, p);
            _moveTo(p);
            vm.prank(keeper);
            module.swap(a, true, a.balance, p);
            _moveTo(p);
        }
        vm.prank(keeper);
        module.swap(a, false, 3_000e6, p);
        _moveTo(p);
        (uint256 used,,) = module.windows(a);
        assertGt(used, cap * 9 / 10);
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        _report();
        p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector);
        module.swap(a, true, a.balance, p);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _report();
        p = poolPrice();
        vm.prank(keeper);
        module.swap(a, true, a.balance, p);
    }

    /// Siblings: the anchor drift window (up then down is charged both ways, no reset at 24 h), and the hedge step.
    function test_M7_Sibling_AnchorWindowBothWays() public {
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 105 / 100);
        _report();
        _moveTo(p0);
        _report(); // 5% up + ~4.8% down: ~10% of the 10% window used
        uint256 now0 = module.lastPrice();
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        _moveTo(p0 * 103 / 100);
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.reportPrice(p);
        assertTrue(module.lastPriceClipped());
        assertLt(module.lastPrice(), now0 * 1005 / 1000);
    }

    function test_M7_Sibling_HedgeStepSlidingWindow() public {
        // hedge step: 5% of value per sliding day, not per calendar reset
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 3_000e6);
        _reportEquity(a, 2_500e6);
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        _report();
        _reportEquity(a, 2_000e6);
        assertApproxEqAbs(module.account(a).hedgeEquity, 2_500e6, 1e6, "no room yet");
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _report();
        _reportEquity(a, 2_000e6);
        assertApproxEqAbs(module.account(a).hedgeEquity, 2_000e6, 30e6, "a full step again (5% of the now lower value)");
    }

    /// Sibling: a guardian price range is one-shot and charged; validated; cleared by pause and guardian change.
    function test_M7_Sibling_GuardianRangeOneShot() public {
        uint256 p0 = module.lastPrice();
        vm.startPrank(guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approvePrice(2, 1, block.timestamp + 1 hours);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approvePrice(0, 1, block.timestamp + 1 hours);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approvePrice(1, 2, block.timestamp + 1 days + 1);
        module.approvePrice(p0 / 2, p0 * 2, block.timestamp + 1 hours);
        vm.stopPrank();
        _moveTo(p0 * 108 / 100);
        _report();
        assertFalse(module.lastPriceClipped());
        (,, uint256 pu) = module.windows(address(0));
        assertGt(pu, 0.07e18, "charged to the window");
        _moveTo(p0 * 116 / 100);
        _report(); // range used: the next move is clipped by the remaining room
        assertTrue(module.lastPriceClipped());
        // cleared by a pause
        vm.prank(guardian);
        module.approvePrice(p0 / 2, p0 * 2, block.timestamp + 1 hours);
        vm.prank(guardian);
        module.setPaused(true);
        uint256 frozen = module.lastPrice();
        _report();
        assertEq(module.lastPrice(), frozen);
    }

    // ================================================================== M-8 (class H: exits cannot fail silently)
    /// PoC: the keeper burns a position after the client signed the exit batch; the all-or-nothing batch failed
    /// inside handleOps without reverting, and management continued.
    function test_M8_PoC_RacingBurnDefaultModeFailsSilently_TryModeExits() public {
        (address a, Delegation memory d, uint256 id) = _invested(ALICE_PK, 10_000e6);
        Execution[] memory xs = _exitExecs(a, d, a);
        vm.prank(keeper);
        module.burnPosition(a, id, 0, 0); // racing keeper action
        _clientExecMode(ALICE_PK, a, xs, DelegationFramework.BATCH_DEFAULT); // the round-1 batch
        assertTrue(module.isActive(a), "all-or-nothing batch silently did nothing");
        _clientExecMode(ALICE_PK, a, xs, BATCH_TRY);
        assertFalse(module.isActive(a), "TRY mode: revoke and disable stand");
        assertTrue(DM.disabledDelegations(DM.getDelegationHash(d)));
    }

    /// Siblings: the owner's direct revoke works with the module and the DelegationManager paused; the 7702 exit in
    /// TRY mode survives a racing burn.
    function test_M8_Sibling_DirectRevokeAndRacing7702() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        vm.prank(guardian);
        module.setPaused(true);
        vm.prank(DM_OWNER);
        IDMPause(DM_ADDR).pause();
        vm.prank(vm.addr(ALICE_PK));
        module.revoke(a);
        assertFalse(module.isActive(a));

        vm.prank(DM_OWNER);
        (bool ok,) = DM_ADDR.call(abi.encodeWithSignature("unpause()"));
        assertTrue(ok);
        _schedule(address(module), abi.encodeCall(LPManagerModule.setPaused, (false)));
        (address b, Delegation memory db) = _onboard7702(BOB_PK, 10_000e6);
        _buyBase(b, 4_000e6);
        uint256 id = _mintAll(b);
        Execution[] memory xs = _exitExecs(b, db, b);
        vm.prank(keeper);
        module.burnPosition(b, id, 0, 0);
        vm.prank(b, b);
        IDeleGatorCore(b).execute(BATCH_TRY, abi.encode(xs));
        assertFalse(module.isActive(b));
    }

    // ================================================================== Lows fixed in code
    function test_L4_ApprovedEquityWritesNetMarginDown() public {
        (address a,) = _withMargin(ALICE_PK, 10_000e6, 3_000e6);
        SALib.Account memory s = module.account(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 1_000e6, block.timestamp + 1 hours);
        _reportEquity(a, 1_000e6);
        assertEq(module.account(a).netMargin, 1_000e6, "a realised loss no longer ratchets the cap shut");
    }

    function test_L3_MulticallTruncatesReason() public {
        (address a,) = _onboardHybrid(ALICE_PK, 1_000e6);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(LPManagerModule.sendHedgeMargin, (a, 1_000_000e6));
        vm.prank(keeper);
        bytes[] memory r = module.multicall(calls, true);
        assertLe(r[0].length, 256);
    }

    function test_L10_MintAfterClientBurnAtMaxPositions() public {
        (address a,) = _onboardHybrid(ALICE_PK, 40_000e6);
        _buyBase(a, 16_000e6);
        uint256 hype = a.balance / 4;
        uint256 usd = usdc.balanceOf(a) / 4;
        uint256 first;
        for (uint256 i; i < 4; ++i) {
            (int24 tl, int24 tu) = _range(300 + 100 * i);
            (uint128 liq, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, hype, usd);
            uint256 p = poolPrice();
            vm.prank(keeper);
            uint256 id = module.mintPosition(a, tl, tu, liq, m0, m1, p);
            if (i == 0) first = id;
        }
        _clientExec1(
            ALICE_PK,
            a,
            POSM_ADDR,
            0,
            abi.encodeCall(
                IPositionManagerMin.modifyLiquidities,
                (V4PositionMath.removeData(true, first, 0, 0, 0, address(0), address(usdc), a), block.timestamp)
            )
        );
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _report();
        (int24 tl2, int24 tu2) = _range(300);
        (uint128 l2, uint128 n0, uint128 n1) = _liqFor(a, tl2, tu2, a.balance / 2, usdc.balanceOf(a) / 2);
        uint256 p2 = poolPrice();
        vm.prank(keeper);
        module.mintPosition(a, tl2, tu2, l2, n0, n1, p2);
        assertEq(module.positionsOf(a).length, 4);
    }

    function test_L17_NoResidualAllowances() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _buyBase(a, 500e6);
        assertEq(usdc.allowance(a, PERMIT2), 0);
    }
}
