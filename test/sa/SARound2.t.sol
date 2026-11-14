// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HostileAccount} from "./SAHostile.sol";

interface IHybridUpgrade {
    function upgradeToAndCall(address impl, bytes calldata data) external payable;
}

interface IPermit2Allowance {
    function allowance(address owner, address token, address spender) external view returns (uint160, uint48, uint48);
}

/// Audit SA-2 (docs/audit/sa_round2_report_1225.md) regressions. For every High / Medium: the auditor's PoC and at
/// least one sibling of the same root cause (docs/audit/sa_round2_rootcause.md); then the Lows fixed in code.
/// The structural claim under test (class B'): live state - snapshot is exactly the client's flow, wherever it
/// happened, and it is booked once, at the anchor, only while the anchor is trusted; so a client flow never changes
/// profit and nothing the keeper or the account's code does to pool spot or inside a bracket becomes a fee.
contract SARound2Test is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("bob"));
    address internal sink = makeAddr("sink");

    function setUp() public {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ helpers
    function _upgradeTo(uint256 pk, address a, uint8 mode, uint256 aux, uint128 auxLiq) internal {
        HostileAccount h = new HostileAccount(
            vm.addr(pk), sink, address(usdc), treasury, feeTo, POSM_ADDR, mode, HYBRID_IMPL, address(executor), PERMIT2, aux, auxLiq
        );
        _clientExec1(pk, a, a, 0, abi.encodeCall(IHybridUpgrade.upgradeToAndCall, (address(h), "")));
        assertTrue(module.isActive(a));
    }

    /// Hybrid account with `usd` onboarded, ~40% bought as HYPE (idle), every flow booked.
    function _withHype(uint256 pk, uint256 usd) internal returns (address a, Delegation memory d) {
        (a, d) = _onboardHybrid(pk, usd);
        _buyBase(a, usd * 2 / 5);
        _report();
        _syncTouch(a);
        assertEq(_pending(a), 0);
    }

    function _sendNative(uint256 pk, address a, address to, uint256 amt) internal {
        _clientExec1(pk, a, to, amt, "");
    }

    function _settleAt(uint256 price) internal {
        _moveTo(price);
        _report();
        _stable();
    }

    // ================================================================== H-1: flows at unbanded spot / lagging anchor
    /// PoC path 1: the client takes 10 HYPE out; the keeper pushes spot +60% around a pure-sync call
    /// (reportHedgeEquity with the stored value). Round 2 booked the outflow at the displaced spot (a fee on
    /// principal). Now nothing is booked while the pool is off the anchor band; the outflow is booked later at the
    /// anchor, profit is unchanged and no fee follows.
    function test_H1_PoC_KeeperSyncAtDisplacedSpot() public {
        (address a,) = _withHype(ALICE_PK, 30_000e6);
        uint256 ref = module.lastPrice();
        int256 c0 = _acct(a).contributed;
        int256 profit0 = _profit(a);
        _sendNative(ALICE_PK, a, vm.addr(ALICE_PK), 10 ether);
        _moveTo(ref * 160 / 100);
        _reportEquity(a, 0); // equal value: a pure sync
        assertEq(_acct(a).contributed, c0, "nothing booked at a displaced spot");
        _moveTo(ref);
        _reportEquity(a, 0);
        assertEq(_acct(a).contributed, c0 - int256(10 * ref), "booked at the anchor");
        assertApproxEqAbs(_profit(a), profit0, 2, "a client flow does not move profit");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _settleAt(ref);
        vm.prank(keeper);
        assertEq(module.chargeFee(a), 0, "no fee on principal");
    }

    /// PoC path 2: the first registration wrapped in a spot push. Registration books nothing; the first trusted
    /// keeper sync books the holdings at the anchor.
    function test_H1_PoC_FirstRegistrationAtDisplacedSpot() public {
        address a = _upgrade7702(BOB_PK);
        vm.deal(a, 1_000 ether);
        _deal(a, 10_000e6);
        Delegation memory d = _moduleDelegation(a, BOB_PK);
        uint256 ref = module.lastPrice();
        _moveTo(ref / 2);
        vm.prank(relayer);
        module.register(d);
        assertEq(_acct(a).contributed, 0);
        _moveTo(ref);
        _stable();
        _syncTouch(a);
        assertEq(_acct(a).contributed, int256(10_000e6 + 1_000 * ref), "at the anchor, not at the pushed spot");
        assertApproxEqAbs(_profit(a), 0, 1e6, "only the touch's own swap fee");
    }

    /// PoC path 3 (no attacker): the market runs +30%, the anchor is clipped by the drift window; a client HYPE
    /// deposit is not booked at the lagging anchor but at the anchor that has caught up.
    function test_H1_PoC_LaggingAnchorNoAttacker() public {
        (address a,) = _onboard7702(BOB_PK, 10_000e6);
        _stable();
        _syncTouch(a);
        uint256 ref = module.lastPrice();
        _moveTo(ref * 130 / 100);
        _report();
        assertTrue(module.lastPriceClipped(), "anchor clipped by the drift window");
        int256 c0 = _acct(a).contributed;
        vm.deal(a, a.balance + 100 ether); // the client deposits 100 HYPE
        vm.warp(vm.getBlockTimestamp() + 600);
        _report();
        _reportEquity(a, 0);
        assertEq(_acct(a).contributed, c0, "not booked at a clipped anchor");
        vm.prank(guardian);
        module.approvePrice(ref, ref * 2, block.timestamp + 1 hours);
        _report();
        assertFalse(module.lastPriceClipped());
        _stable();
        _reportEquity(a, 0);
        assertApproxEqAbs(_acct(a).contributed, c0 + int256(100 * module.lastPrice()), 1e6, "at the caught-up anchor");
    }

    /// Sibling: on EVERY path that syncs (decrease, burn, returnHedgeMargin, reportHedgeEquity, and the paths
    /// that were already gated), a spot displaced WITHIN the band changes nothing: the flow is booked at the anchor.
    function test_H1_Sibling_EverySyncPathBooksAtTheAnchor() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 40_000e6);
        _report();
        _syncTouch(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 2_000e6);
        uint256 ref = module.lastPrice();
        for (uint256 k; k < 4; ++k) {
            int256 c0 = _acct(a).contributed;
            _sendNative(ALICE_PK, a, vm.addr(ALICE_PK), 0.1 ether);
            _moveTo(ref * (k % 2 == 0 ? 10_120 : 9_880) / 10_000); // inside the 1.5% band
            vm.startPrank(keeper);
            if (k == 0) module.decreasePosition(a, id, 0, 0, 0);
            if (k == 1) module.returnHedgeMargin(a, 100e6);
            if (k == 2) module.reportHedgeEquity(a, 1_900e6);
            if (k == 3) module.burnPosition(a, id, 0, 0);
            vm.stopPrank();
            assertEq(_acct(a).contributed, c0 - int256((ref + 9) / 10), "0.1 HYPE out, at the anchor, whatever the spot");
            _moveTo(ref);
        }
    }

    /// Sibling (the converse bias): deposit / withdraw cycles at spots on either edge of the band book nothing net,
    /// because inflows and outflows use one price (no min/max spread to farm).
    function test_H1_Sibling_DepositWithdrawCyclesNetZero() public {
        (address a,) = _onboard7702(BOB_PK, 10_000e6);
        _stable();
        _syncTouch(a);
        uint256 ref = module.lastPrice();
        int256 c0 = _acct(a).contributed;
        for (uint256 i; i < 3; ++i) {
            vm.deal(a, a.balance + 100 ether);
            _moveTo(ref * 10_130 / 10_000);
            _reportEquity(a, 0);
            vm.deal(a, a.balance - 100 ether);
            _moveTo(ref * 9_870 / 10_000);
            _reportEquity(a, 0);
        }
        assertEq(_acct(a).contributed, c0);
    }

    /// Sibling (L-16): an anchor walked inside the transaction cannot be booked or charged on: booking and fees
    /// need the anchor unchanged for minPriceStable.
    function test_H1_Sibling_WalkAndChargeInOneTransaction() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _volume(200_000, 10);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _settleAt(module.lastPrice());
        uint256 ref = module.lastPrice();
        _moveTo(ref * 10_400 / 10_000);
        vm.startPrank(keeper);
        module.reportPrice(poolPrice());
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
        vm.stopPrank();
        int256 c0 = _acct(a).contributed;
        _sendNative(ALICE_PK, a, vm.addr(ALICE_PK), 0.1 ether);
        uint256 id = module.positionsOf(a)[0].tokenId;
        vm.prank(keeper);
        module.decreasePosition(a, id, 0, 0, 0);
        assertEq(_acct(a).contributed, c0, "not booked at an anchor moved in this transaction");
    }

    // ================================================================== M-1: increase not read back
    /// PoC: an upgraded account skips the increase and sends its funds out, then deposits them back. Round 2 booked
    /// the redeposit as new capital (contributed inflated by the whole add). Now the skipped liquidity is an outflow
    /// at the next trusted sync and the redeposit an inflow: contributed ends where it started.
    function test_M1_PoC_SkippedIncreaseThenRedeposit() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 40_000e6);
        _report();
        _syncTouch(a);
        int256 c0 = _acct(a).contributed;
        int256 v0 = int256(module.accountValue(a, module.lastPrice()));
        _upgradeTo(ALICE_PK, a, 4, 0, 0);
        V4PositionMath.Position memory p = module.positionsOf(a)[0];
        uint128 liq = POSM.getPositionLiquidity(id) / 5;
        uint256 pr = poolPrice();
        uint128 m0 = uint128(a.balance);
        uint128 m1 = uint128(usdc.balanceOf(a));
        vm.prank(keeper);
        module.increasePosition(a, id, liq, m0, m1, pr);
        uint256 outU = usdc.balanceOf(sink);
        uint256 outH = sink.balance;
        assertGt(outU, 0);
        // the money comes back in as a "deposit"
        vm.prank(sink);
        usdc.transfer(a, outU);
        vm.deal(a, a.balance + outH);
        _report();
        _stable();
        _reportEquity(a, 0); // a sync that runs no account code
        uint256 lv = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, module.lastPrice(), true);
        assertApproxEqAbs(_acct(a).contributed, c0, lv / 500, "no capital was added");
        assertLt(_acct(a).contributed, c0 + int256(lv) / 2, "round 2: c0 + the whole add");
        // the books are whole: value - contributed moved only by the touch itself
        assertApproxEqAbs(int256(module.accountValue(a, module.lastPrice())) - _acct(a).contributed, v0 - c0, lv / 500 + 2e6);
    }

    /// Sibling: the same account code on a swap: no executor record, so the swap reverts instead of booking a
    /// swap that did not happen.
    function test_M1_Sibling_SkippedSwapReverts() public {
        (address a,) = _withHype(ALICE_PK, 10_000e6);
        _upgradeTo(ALICE_PK, a, 4, 0, 0);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.BelowMinOutOrBadSwap.selector);
        module.swap(a, false, 100e6, p, 0);
    }

    // ================================================================== M-2: proceeds into another tracked position
    function _twoPositions(uint256 usd) internal returns (address a, uint256 A, uint256 B) {
        (a,) = _onboardHybrid(ALICE_PK, usd);
        _buyBase(a, usd * 2 / 5);
        (int24 tl, int24 tu) = _range(300);
        (uint128 liq, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, a.balance / 2, usdc.balanceOf(a) / 2);
        uint256 p = poolPrice();
        vm.startPrank(keeper);
        A = module.mintPosition(a, tl, tu, liq, m0, m1, p);
        (liq, m0, m1) = _liqFor(a, tl, tu, a.balance, usdc.balanceOf(a));
        B = module.mintPosition(a, tl, tu, liq, m0, m1, p);
        vm.stopPrank();
        _report();
        _syncTouch(a);
    }

    /// PoC: the keeper burns A; the account's code adds the proceeds to B inside the bracket. Round 2 snapshotted
    /// only A and booked B's growth as a new contribution. Now both halves (idle out, B in) are pending and net out.
    function test_M2_PoC_BurnProceedsIntoOtherTrackedPosition() public {
        (address a, uint256 A, uint256 B) = _twoPositions(40_000e6);
        int256 c0 = _acct(a).contributed;
        uint128 lA = POSM.getPositionLiquidity(A);
        uint128 lB = POSM.getPositionLiquidity(B);
        _upgradeTo(ALICE_PK, a, 5, B, lA * 99 / 100);
        vm.prank(keeper);
        module.burnPosition(a, A, 0, 0);
        assertEq(POSM.getPositionLiquidity(B), lB + lA * 99 / 100, "the proceeds went into B");
        V4PositionMath.Position memory p = module.positionsOf(a)[0];
        uint256 vA = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, lA, module.lastPrice(), true);
        _report();
        _stable();
        _reportEquity(a, 0); // a sync that runs no account code
        assertApproxEqAbs(_acct(a).contributed, c0, vA / 1000, "round 2 booked +value(A)");
    }

    /// Sibling: the same move on a partial decrease.
    function test_M2_Sibling_DecreaseProceedsIntoOtherTrackedPosition() public {
        (address a, uint256 A, uint256 B) = _twoPositions(40_000e6);
        int256 c0 = _acct(a).contributed;
        uint128 half = POSM.getPositionLiquidity(A) / 2;
        _upgradeTo(ALICE_PK, a, 5, B, half * 99 / 100);
        vm.prank(keeper);
        module.decreasePosition(a, A, half, 0, 0);
        V4PositionMath.Position memory p = module.positionsOf(a)[0];
        uint256 v = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, half, module.lastPrice(), true);
        _report();
        _stable();
        _reportEquity(a, 0);
        assertApproxEqAbs(_acct(a).contributed, c0, v / 1000);
    }

    /// Sibling (L-14, the swap bracket): output kept above min-out is a booked outflow, exactly.
    function test_M2_Sibling_SwapOutputSkimmedIsBooked() public {
        (address a,) = _withHype(ALICE_PK, 20_000e6);
        int256 c0 = _acct(a).contributed;
        _upgradeTo(ALICE_PK, a, 6, 0, 0);
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.swap(a, true, 50 ether, p, 0);
        uint256 skim = usdc.balanceOf(sink);
        assertGt(skim, 0);
        assertEq(_pending(a), -int256(skim), "exactly the skim is pending");
        _report();
        _syncTouch(a);
        assertEq(_acct(a).contributed, c0 - int256(skim));
    }

    // ================================================================== M-3: onboard allowance
    function _permitAt(uint256 pk, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                vm.addr(pk),
                address(module),
                amount,
                nonce,
                deadline
            )
        );
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", IERC20Permit(address(usdc)).DOMAIN_SEPARATOR(), sh)));
    }

    /// PoC: an owner with a standing allowance (it used `deposit`) is pulled by anyone through `onboard` with the
    /// public stored delegation, in a keeper multicall too. Now only a fresh permit moves funds.
    function test_M3_PoC_StandingAllowanceNotPullable() public {
        address o = vm.addr(ALICE_PK);
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 10_000e6);
        _deal(o, 101_000e6);
        vm.startPrank(o);
        usdc.approve(address(module), type(uint256).max);
        module.deposit(a, 1_000e6);
        vm.stopPrank();
        vm.prank(sink);
        vm.expectRevert(SALib.BadPermit.selector);
        module.onboard(d, 100_000e6, 0, 0, bytes32(0), bytes32(0));
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(LPManagerModule.onboard, (d, 100_000e6, 0, 0, bytes32(0), bytes32(0)));
        vm.prank(keeper);
        vm.expectRevert(SALib.BadPermit.selector);
        module.multicall(calls, false);
        assertEq(usdc.balanceOf(o), 100_000e6);
    }

    /// Siblings: a used permit cannot be replayed; a front-run permit is honoured only for its own amount and
    /// before its deadline; a fresh permit tops up and is booked at once.
    function test_M3_Sibling_PermitReplayAmountAndDeadline() public {
        address o = vm.addr(ALICE_PK);
        uint256 dl = block.timestamp + 1 hours;
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 1_000e6); // used nonce 0
        _deal(o, 50_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _permitAt(ALICE_PK, 1_000e6, 0, dl);
        vm.expectRevert(SALib.BadPermit.selector);
        module.onboard(d, 1_000e6, dl, v, r, s); // replay of the consumed permit
        // front-run of a fresh permit: accepted for exactly its amount
        (v, r, s) = _permitAt(ALICE_PK, 5_000e6, 1, dl);
        IERC20Permit(address(usdc)).permit(o, address(module), 5_000e6, dl, v, r, s);
        vm.expectRevert(SALib.BadPermit.selector);
        module.onboard(d, 6_000e6, dl, v, r, s);
        int256 c0 = _acct(a).contributed;
        module.onboard(d, 5_000e6, dl, v, r, s);
        assertEq(_acct(a).contributed, c0 + 5_000e6, "booked at face value at once");
        assertEq(usdc.allowance(o, address(module)), 0, "nothing standing");
        // a front-run permit past its deadline is not honoured
        uint256 dl2 = block.timestamp + 60;
        (v, r, s) = _permitAt(ALICE_PK, 1_000e6, 2, dl2);
        IERC20Permit(address(usdc)).permit(o, address(module), 1_000e6, dl2, v, r, s);
        vm.warp(dl2 + 1);
        vm.expectRevert(SALib.BadPermit.selector);
        module.onboard(d, 1_000e6, dl2, v, r, s);
    }

    // ================================================================== M-4: clipped flag and window saturation
    /// PoC: a guardian-approved jump fills the window; a later report one unit away from the anchor used to set
    /// the global clipped flag and block sends and fees for a day. Now the anchor counts as clipped only while it
    /// is outside the band of the report.
    function test_M4_PoC_SaturatedWindowOneUnitDoesNotBlock() public {
        (address a,) = _withHype(ALICE_PK, 20_000e6);
        uint256 p0 = module.lastPrice();
        vm.prank(guardian);
        module.approvePrice(p0, p0 * 2, block.timestamp + 1 hours);
        _moveTo(p0 * 125 / 100);
        _report();
        (,, uint256 pu) = module.windows(address(0));
        assertEq(pu, 0.1e18, "window full");
        uint256 anchor = module.lastPrice();
        vm.prank(keeper);
        module.reportPrice(anchor + 1);
        assertEq(module.lastPrice(), anchor);
        assertFalse(module.lastPriceClipped());
        _stable();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 500e6);
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.FeeTooEarly.selector); // past the price gate
        module.chargeFee(a);
    }

    /// Sibling: no guardian; oscillation uses the whole window; a report within the band of the anchor does not
    /// block, one outside it does, and the anchor un-clips by itself when the market comes back.
    function test_M4_Sibling_OscillationAndAutoClear() public {
        (address a,) = _withHype(ALICE_PK, 20_000e6);
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 105 / 100);
        _report();
        _moveTo(p0);
        _report();
        _moveTo(p0 * 101 / 100);
        _report(); // ~0.2% of room left: clipped, but in band
        assertFalse(module.lastPriceClipped());
        _stable();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 100e6);
        _moveTo(p0 * 104 / 100);
        _report();
        assertTrue(module.lastPriceClipped());
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.sendHedgeMargin(a, 100e6);
        _moveTo(p0 * 1005 / 1000);
        _report();
        assertFalse(module.lastPriceClipped(), "auto-clears");
    }

    // ================================================================== Lows fixed in code
    /// L-1: an equal report does not clear hedgeClipped; a decrease applied in full does.
    function test_L1_EqualReportDoesNotClearHedgeClipped() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _stable();
        _syncTouch(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 3_000e6);
        _reportEquity(a, 2_400e6); // 600 down > 5% step (~500): clipped
        assertTrue(_acct(a).hedgeClipped);
        uint256 stored = _acct(a).hedgeEquity;
        _reportEquity(a, stored);
        assertTrue(_acct(a).hedgeClipped, "equal report keeps the flag");
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _report();
        _reportEquity(a, 2_400e6);
        assertEq(_acct(a).hedgeEquity, 2_400e6);
        assertFalse(_acct(a).hedgeClipped, "a decrease applied in full clears it");
    }

    /// L-2: the keeper-only hedge step is zero while the anchor is clipped (fresh by age only).
    function test_L2_HedgeStepNeedsAFreshAnchor() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _stable();
        _syncTouch(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 3_000e6);
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 130 / 100);
        _report();
        assertTrue(module.lastPriceClipped());
        _reportEquity(a, 2_900e6);
        assertEq(_acct(a).hedgeEquity, 3_000e6);
    }

    /// L-5: the band is measured against the pool.
    function test_L5_BandMeasuredAgainstThePool() public {
        uint256 pool = poolPrice();
        vm.startPrank(keeper);
        vm.expectPartialRevert(LPManagerModule.PoolPriceOff.selector);
        module.reportPrice(pool * 10_152 / 10_000); // the argument-relative rule accepted up to +1.523%
        module.reportPrice(pool * 10_149 / 10_000);
        vm.stopPrank();
    }

    /// L-6: the ownership path keeps the roles distinct.
    function test_L6_OwnershipTransferKeepsRolesDistinct() public {
        vm.prank(address(timelock));
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.transferOwnership(keeper);
        address p = makeAddr("nextOwner");
        vm.prank(address(timelock));
        module.transferOwnership(p);
        vm.prank(address(timelock));
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.setKeeper(p);
    }

    /// L-7: a pause voids pending hedge approvals.
    function test_L7_PauseVoidsHedgeApprovals() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _stable();
        _syncTouch(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 1_000e6);
        SALib.Account memory s = _acct(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 3_000e6, block.timestamp + 1 hours);
        vm.prank(guardian);
        module.setPaused(true);
        _reportEquity(a, 3_000e6);
        assertEq(_acct(a).hedgeEquity, 1_000e6);
    }

    /// L-11: a top-up in the delegation's last day goes through (the no-op path checks nothing).
    function test_L11_TopUpInTheLastDay() public {
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 1_000e6);
        vm.warp(block.timestamp + 180 days - 12 hours);
        _report();
        _deal(vm.addr(ALICE_PK), 500e6);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(ALICE_PK, address(module), 500e6, dl);
        module.onboard(d, 500e6, dl, v, r, s);
        assertEq(usdc.balanceOf(a), 1_500e6);
    }

    /// L-13: no Permit2-side allowance remains after a swap or an add.
    function test_L13_NoPermit2AllowanceLeft() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        (uint160 x,,) = IPermit2Allowance(PERMIT2).allowance(a, address(usdc), address(executor));
        (uint160 y,,) = IPermit2Allowance(PERMIT2).allowance(a, address(usdc), POSM_ADDR);
        assertEq(x, 0);
        assertEq(y, 0);
        assertEq(usdc.allowance(a, PERMIT2), 0);
    }

    /// L-15: the keeper can tighten min-out.
    function test_L15_KeeperMinOut() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        uint256 p = poolPrice();
        uint256 fair = 1_000e6 * 1e18 / p;
        vm.prank(keeper);
        vm.expectRevert(); // the executor's own BelowMinOut bubbles up
        module.swap(a, false, 1_000e6, p, fair * 2);
        vm.prank(keeper);
        uint256 out = module.swap(a, false, 1_000e6, p, fair * 99 / 100);
        assertGe(out, fair * 99 / 100);
    }

    /// L-9: revoke + register is no longer an on-demand sync for the client.
    function test_L9_ReRegisterBooksNothing() public {
        (address a, Delegation memory d) = _withHype(ALICE_PK, 10_000e6);
        int256 c0 = _acct(a).contributed;
        _sendNative(ALICE_PK, a, vm.addr(ALICE_PK), 5 ether);
        vm.startPrank(vm.addr(ALICE_PK));
        module.revoke(a);
        module.register(d);
        vm.stopPrank();
        assertEq(_acct(a).contributed, c0);
        _syncTouch(a);
        assertEq(_acct(a).contributed, c0 - int256(5 * module.lastPrice()));
    }

    /// The fee runs after a sync that books every pending flow, on the lower of value at the anchor and at the pool.
    function test_Fee_PendingFlowsBookedFirst() public {
        (address a,,) = _invested(ALICE_PK, 20_000e6);
        _volume(200_000, 25);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 ref = module.lastPrice();
        _settleAt(ref);
        _syncTouch(a);
        _deal(vm.addr(ALICE_PK), 5_000e6);
        vm.prank(vm.addr(ALICE_PK));
        usdc.transfer(a, 5_000e6); // pending at the fee
        int256 profit = _profit(a) - _pending(a);
        uint256 vp = module.accountValue(a, poolPrice());
        uint256 v = module.accountValue(a, module.lastPrice());
        int256 conservative = int256(Math.min(v, vp)) - _acct(a).contributed - _pending(a);
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        assertEq(f, uint256(conservative) * 1500 / 10_000);
        assertLe(conservative, profit);
    }
}
