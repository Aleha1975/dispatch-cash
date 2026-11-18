// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";

/// Audit SA-7 (report 1255 of commit e6a2de5, docs/audit/sa_round7_response.md) regressions. Every test marked
/// "fails on e6a2de5" fails there and passes after the fix (checked by running this file and SATestBase.sol against
/// the old sources; the file uses only interfaces that exist there).
///
/// SA-7 replaces the late-booking machinery of rounds 4-6 (the 1-day wait after a priced flow, the 1% dust rule, the
/// report ring and its raise) with one rule in SABook.sync: a booking with any price-dependent change (or after a
/// `flowSeen` mark) sets hwm = max(profit after the booking, hwm + priced).
contract SARound7Test is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant FEE_BPS = 1500;

    function setUp() public {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ helpers
    function _keeperSync(address a) internal {
        vm.prank(keeper);
        module.sync(a);
    }

    /// The keeper looks at the account while the anchor is not trusted (e6a2de5: reverts StalePrice; now it marks a
    /// pending price-dependent change, SABook `flowSeen`).
    function _look(address a) internal {
        vm.prank(keeper);
        try module.sync(a) {} catch {}
    }

    function _hold(uint256 hours_) internal {
        for (uint256 i; i < hours_ / 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 3 hours);
            _stable();
        }
    }

    function _feeReady() internal {
        _moveTo(module.lastPrice() * 1001 / 1000);
        _stable();
        _fresh();
    }

    function _fee(address a) internal returns (uint256) {
        vm.prank(keeper);
        return module.chargeFee(a);
    }

    function _keeperReports(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            _report();
        }
    }

    /// A real gain paid into the account (the treasury returns more than the account sent).
    function _gain(address a, uint256 amount) internal {
        _deal(treasury, amount);
        vm.prank(treasury);
        module.returnHedgeMargin(a, amount);
    }

    /// Account invested in HYPE, booked at P0, with an uncharged real gain of `y` USDC.
    function _setup(uint256 y) internal returns (address a, uint256 p0, uint256 hype) {
        (a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _stable();
        _keeperSync(a);
        p0 = module.lastPrice();
        hype = a.balance;
        if (y != 0) _gain(a, y);
    }

    /// The fee is at most feeBps of the profit measured at the flows' own prices (`hidden` = what the late booking
    /// hid from the books).
    function _assertNoFeeOnPhantom(address a, uint256 hidden) internal {
        _hold(30);
        _feeReady();
        int256 atFlow = _profit(a) - int256(hidden) - _acct(a).hwm;
        uint256 cap = atFlow > 0 ? uint256(atFlow) * FEE_BPS / 10_000 : 0;
        uint256 f = _fee(a);
        assertLe(f, cap + 1e6, "fee only on the profit at the flows' own prices");
    }

    // ================================================================== M-1: opposite flows net to zero
    /// PoC (report trace, scaled): the account holds HYPE and an uncharged real gain. The market wicks 30% down; the
    /// anchor cannot follow (not trusted), the honest keeper keeps reporting. The client sends all its HYPE out at the
    /// bottom; the keeper sees the pending flow but cannot book it. The market recovers, the client sends the same
    /// HYPE back. The booking sees no net change, so on e6a2de5 there is no raise and the fee takes a share of the
    /// hidden loss (feeBps x HYPE x the wick). Now the keeper's look marks the account (`flowSeen`) and the booking
    /// sets hwm to the profit after it: the gain up to then carries no fee. Fails on e6a2de5.
    function test_M1_PoC_OppositeFlowsSeenByKeeper() public {
        (address a, uint256 p0, uint256 hype) = _setup(8_000e6);
        _moveTo(p0 * 70 / 100); // the wick
        _keeperReports(2);
        uint256 low = poolPrice();
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), hype, ""); // all HYPE out at the bottom
        _look(a); // the keeper sees it; the anchor is not trusted
        _moveTo(p0);
        _reportTo();
        vm.deal(a, a.balance + hype); // the same HYPE back at P0
        _stable();
        _keeperSync(a); // books a net change of 0
        _assertNoFeeOnPhantom(a, hype * (p0 - low) / 1e18);
    }

    /// Variant (report: partial netting): all HYPE out at the bottom, half of it back after the recovery, nobody
    /// looks in between. The net change is a price-dependent outflow, so the booking resets the mark. e6a2de5 sized
    /// its raise on the net only (about 0.21 of the HYPE's value for a phantom of 0.30). Fails on e6a2de5.
    function test_M1_Sibling_PartialNettingNoLook() public {
        (address a, uint256 p0, uint256 hype) = _setup(8_000e6);
        _moveTo(p0 * 70 / 100);
        _keeperReports(2);
        uint256 low = poolPrice();
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), hype, "");
        _moveTo(p0);
        _reportTo();
        vm.deal(a, a.balance + hype / 2);
        _stable();
        _keeperSync(a);
        _assertNoFeeOnPhantom(a, hype * (p0 - low) / 1e18);
    }

    /// Variant (report: deposit first): HYPE brought in at a spike and taken out (all but a little) in the dip, while
    /// the anchor is not trusted. Fails on e6a2de5.
    function test_M1_Sibling_DepositFirstRoundTrip() public {
        (address a, uint256 p0,) = _setup(8_000e6);
        uint256 extra = 100 ether;
        _moveTo(p0 * 110 / 100);
        _keeperReports(1);
        uint256 high = poolPrice();
        vm.deal(a, a.balance + extra); // in at the spike
        _moveTo(p0 * 85 / 100);
        _keeperReports(1);
        uint256 low = poolPrice();
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), extra - 1 ether, ""); // out in the dip, 1 HYPE stays
        _moveTo(p0);
        _reportTo();
        _stable();
        _keeperSync(a);
        _assertNoFeeOnPhantom(a, (extra - 1 ether) * (high - low) / 1e18);
    }

    /// The adjustment to "hwm = max(hwm, profit)": below the mark that alone would not cover a late outflow (here
    /// the account has no uncharged gain at all). The floor hwm + priced does: an outflow's value at its own price is
    /// never below 0. Passes on both commits (e6a2de5 covered it with the report ring).
    function test_M1_BelowMarkOutflowCoveredByFloor() public {
        (address a, uint256 p0, uint256 hype) = _setup(0);
        _moveTo(p0 * 70 / 100);
        _keeperReports(2);
        uint256 low = poolPrice();
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), hype, "");
        _moveTo(p0);
        _reportTo();
        _stable();
        _keeperSync(a);
        uint256 hidden = hype * (p0 - low) / 1e18;
        _gain(a, hidden); // a real gain that only makes the hidden loss good
        _assertNoFeeOnPhantom(a, hidden);
    }

    /// Stated residual: an exact round trip (same amount, to the wei) that nobody sees leaves the books exactly as if
    /// no flow happened (contributed and hwm unchanged): the fee is that of an account that made neither flow.
    function test_Residual_ExactUnseenRoundTripIsNoFlow() public {
        (address a, uint256 p0, uint256 hype) = _setup(8_000e6);
        SALib.Account memory s0 = _acct(a);
        _moveTo(p0 * 70 / 100);
        _keeperReports(2);
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), hype, "");
        _moveTo(p0);
        _reportTo();
        vm.deal(a, a.balance + hype);
        _stable();
        _keeperSync(a);
        assertEq(_acct(a).contributed, s0.contributed);
        assertEq(_acct(a).hwm, s0.hwm);
    }

    // ================================================================== the rule, both directions of cost
    /// Any price-dependent change, however small (here 1 wei of HYPE from anyone), forgoes the uncharged gain up to
    /// the booking: no dust threshold (a threshold on the net cannot see opposite flows). Our fee only. Fails on
    /// e6a2de5 (the mark stayed and the gain was charged).
    function test_Rule_AnyPricedChangeForgoesUnchargedGain() public {
        (address a,,) = _setup(8_000e6);
        int256 p = _profit(a);
        vm.deal(a, a.balance + 1);
        _stable();
        _keeperSync(a);
        assertGe(_acct(a).hwm, p, "the gain up to the booking carries no fee");
    }

    /// A USDC flow is booked at face value: no phantom, no reset, the gain stays chargeable. Passes on both.
    function test_Rule_UsdcFlowKeepsMark() public {
        (address a,,) = _setup(8_000e6);
        int256 h = _acct(a).hwm;
        _deal(a, usdc.balanceOf(a) + 1_000e6);
        _stable();
        _keeperSync(a);
        assertEq(_acct(a).hwm, h);
    }

    /// The 1-day wait after a priced flow (SA-4 M-2) is gone: after a booking the fee is on later gains only. Fails
    /// on e6a2de5 (FeeTooEarly).
    function test_Rule_NoDayWaitAfterPricedFlow() public {
        (address a,,) = _setup(8_000e6);
        _hold(30);
        vm.deal(a, a.balance + 10 ether);
        _feeReady();
        vm.prank(keeper);
        uint256 f = module.chargeFee(a); // books the deposit, then charges on what is above the new mark
        assertLe(f, 1e6, "nothing above the mark the booking set");
    }

    // ================================================================== Lows / Infos
    /// L-2: the 1-day confirmation counts from the guardian's approvePrice, not from the keeper's consumption.
    /// Approved at T, consumed at T + 23 h, fee at T + 25 h: refused. Fails on e6a2de5 (counted from T + 23 h).
    function test_L2_ConfirmationCountsFromApproval() public {
        (address a,,) = _setup(0);
        _moveTo(module.lastPrice() * 1001 / 1000);
        _stable();
        uint256 p = module.lastPrice();
        vm.prank(guardian);
        module.approvePrice(p * 995 / 1000, p * 1005 / 1000, vm.getBlockTimestamp() + 1 days);
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        vm.prank(keeper);
        module.reportPrice(p); // consumes the range
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _stable();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
        _fresh();
        _fee(a); // a fresh confirmation: no revert
    }

    /// I-1: lowering poolBandBps clears an open guardian range (it was judged against the wider band). Fails on
    /// e6a2de5.
    function test_I1_LowerBandClearsOpenRange() public {
        (uint16 f, uint16 hc, uint16 band, uint16 ms, uint16 hs, uint16 rd, uint32 st, uint32 fi, uint32 ma,
            uint32 mps, uint16 ex) = module.params();
        bytes memory data = abi.encodeCall(
            LPManagerModule.setParams, (LPManagerModule.Params(f, hc, band - 50, ms, hs, rd, st, fi, ma, mps, ex))
        );
        vm.prank(operator);
        timelock.schedule(address(module), 0, data, bytes32(0), bytes32(0), 2 days);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        uint256 p = module.lastPrice();
        vm.prank(guardian);
        module.approvePrice(p * 990 / 1000, p * 1010 / 1000, vm.getBlockTimestamp() + 1 hours);
        vm.prank(operator);
        timelock.execute(address(module), 0, data, bytes32(0), bytes32(0));
        (,, uint256 until,,,,) = module.priceBudget();
        assertEq(until, 0);
    }

    /// I-3: while paused nothing is booked (the anchor is frozen); the flow stays pending. Fails on e6a2de5.
    function test_I3_PausedBooksNothing() public {
        (address a,,) = _setup(0);
        int256 c = _acct(a).contributed;
        vm.deal(a, a.balance + 10 ether);
        vm.prank(guardian);
        module.setPaused(true);
        _stable();
        _look(a);
        assertEq(_acct(a).contributed, c, "nothing booked at a frozen anchor");
    }
}
