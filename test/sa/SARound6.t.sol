// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";

interface IPosmModify6 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IDMPause6 {
    function pause() external;
}

/// Audit SA-6 (report 1252 of commit 0fe4d85, docs/audit/sa_round6_response.md) regressions. Every test marked
/// "fails on 0fe4d85" fails there and passes after the fix (checked by running this file and SATestBase.sol against
/// the old sources; the file uses only interfaces that exist there).
contract SARound6Test is SATestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));

    function setUp() public {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ helpers
    function _clientPosm(uint256 pk, address a, bytes memory data, uint256 value) internal {
        Execution[] memory xs = new Execution[](3);
        xs[0] = Execution(address(usdc), 0, abi.encodeCall(IERC20.approve, (PERMIT2, type(uint256).max)));
        xs[1] = Execution(
            PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, type(uint160).max, uint48(vm.getBlockTimestamp() + 1 hours)))
        );
        xs[2] = Execution(POSM_ADDR, value, abi.encodeCall(IPosmModify6.modifyLiquidities, (data, vm.getBlockTimestamp() + 60)));
        _clientExec(pk, a, xs);
    }

    function _clientDecrease(uint256 pk, address a, uint256 id, uint128 liq) internal {
        _clientPosm(pk, a, V4PositionMath.removeData(false, id, liq, 0, 0, address(0), address(usdc), a), 0);
    }

    function _clientIncrease(uint256 pk, address a, uint256 id, uint128 liq) internal {
        _clientPosm(
            pk, a, V4PositionMath.increaseData(id, liq, type(uint128).max, type(uint128).max, address(0), address(usdc), a), a.balance
        );
    }

    function _keeperSync(address a) internal {
        vm.prank(keeper);
        module.sync(a);
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

    /// The keeper, honest, reports the pool every minPriceStable for `n` rounds (the anchor steps toward it).
    function _keeperReports(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            _report();
        }
    }

    // ================================================================== M-1: flow at a third price
    /// PoC (report trace, honest operator): the account is booked at P0. The market wicks 30% down; the anchor cannot
    /// follow (one step per report, so it is not trusted) but the keeper keeps reporting the market. The client takes
    /// all its HYPE out at the bottom. The market comes back and the withdrawal is booked at about P0: contributed
    /// falls by the HYPE's value at P0, not at the price it left at. A later real gain (here a hedge profit the
    /// treasury pays in) then only makes up the hidden loss, but the books show it as profit and the fee took a share
    /// of principal. Now the booking raises the high-water mark by the flow's largest gain at any price reported
    /// since the last priced sync. Fails on 0fe4d85 (fee about 540 USDC).
    function test_M1_PoC_WickRoundTripNoFeeOnPrincipal() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _stable();
        _keeperSync(a); // last priced booking at P0
        uint256 p0 = module.lastPrice();
        uint256 hype = a.balance;
        _moveTo(p0 * 70 / 100); // the wick
        _keeperReports(2); // the honest keeper reports the market; the anchor lags (not trusted)
        uint256 out = hype * poolPrice() / 1e18; // what the HYPE was worth when it left
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), hype, ""); // all HYPE out at the bottom
        _moveTo(p0); // the market comes back
        _reportTo();
        _stable();
        _keeperSync(a); // booked at about P0
        uint256 hidden = hype * p0 / 1e18 - out; // the market loss the books never saw
        _deal(treasury, hidden);
        vm.prank(treasury);
        module.returnHedgeMargin(a, hidden); // a real gain that only makes the hidden loss good
        _hold(30); // past the flow wait and the trailing low of the lagging anchor
        _feeReady();
        assertEq(_fee(a), 0, "no fee while the account is not above its value before the wick");
    }

    /// Sibling (report variant, agents 3 / 7): HYPE deposited while the market is up, booked after the market came
    /// back (at the lower anchor), then the market goes up to the deposit price again. The account made nothing on the
    /// HYPE, the books show the move from the booking price as profit. Fails on 0fe4d85 (fee about 48 USDC).
    function test_M1_Sibling_DepositInSpikeBookedAfterReturn() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6); // USDC only: the deposited HYPE is the only base
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _stable();
        _keeperSync(a);
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 108 / 100);
        _keeperReports(1);
        vm.deal(a, a.balance + 100 ether); // the client's deposit at the high
        _moveTo(p0);
        _reportTo();
        _stable();
        _keeperSync(a); // booked at P0
        _moveTo(p0 * 108 / 100);
        _reportTo();
        _confirm(); // the guardian confirms the new level
        _hold(30);
        _feeReady();
        assertLe(_fee(a), 1e6, "no fee on a round trip of the deposited HYPE");
    }

    /// The raise is sized by the market actually reported: a priced flow booked while every report since the last
    /// priced sync was at the booking anchor raises nothing (a flat market costs the operator no fee).
    function test_M1_FlatMarketPricedFlowRaisesNothing() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _stable();
        _keeperSync(a);
        int256 h0 = _acct(a).hwm;
        vm.deal(a, a.balance + 10 ether);
        _stable();
        _keeperSync(a);
        assertEq(_acct(a).hwm, h0, "no move reported: no raise");
        assertGt(_acct(a).contributed, int256(30_000e6), "the deposit is booked");
    }

    /// Beyond the 24 h ring without a priced sync, the raise is the whole priced value (the keeper refreshes every
    /// account's booking at least every few hours, so this is the outage case). Fails on 0fe4d85 (raise 0).
    function test_M1_LongGapRaisesWholePricedValue() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _stable();
        _keeperSync(a);
        int256 h0 = _acct(a).hwm;
        _hold(30); // reports continue, no priced sync of this account
        vm.deal(a, a.balance + 10 ether);
        _stable();
        _keeperSync(a);
        assertGe(_acct(a).hwm - h0, int256(10 * module.lastPrice()), "the whole priced value");
    }

    // ================================================================== Lows
    /// L-1 (report trace): two tracked positions. The client lowers A to a sliver, the range trades, restores A
    /// exactly and halves B directly. B's pending principal sits in idle and was room for A's credit of growth x L
    /// (fees PoolManager never paid A). Now no credit in a sync where any tracked position is pending. Fails on
    /// 0fe4d85.
    function test_L1_PoC_OtherPositionPendingIsNoRoom() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _stable();
        (int24 tl, int24 tu) = _range(300);
        (uint128 la, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, a.balance / 2, usdc.balanceOf(a) / 2);
        uint256 kp = poolPrice();
        vm.prank(keeper);
        uint256 idA = module.mintPosition(a, tl, tu, la, m0, m1, kp);
        (tl, tu) = _range(600);
        (uint128 lb, uint128 n0, uint128 n1) = _liqFor(a, tl, tu, a.balance, usdc.balanceOf(a));
        vm.prank(keeper);
        uint256 idB = module.mintPosition(a, tl, tu, lb, n0, n1, kp);
        uint256 ref = module.lastPrice();
        _stable();
        _keeperSync(a);
        int256 p0 = _profit(a);
        uint128 dip = la - la / 1000;
        _clientDecrease(ALICE_PK, a, idA, dip);
        _volume(20_000, 10);
        _moveTo(ref);
        _clientIncrease(ALICE_PK, a, idA, dip);
        assertEq(POSM.getPositionLiquidity(idA), la);
        _clientDecrease(ALICE_PK, a, idB, lb / 2);
        _stable();
        _keeperSync(a);
        // B earned real fees during the volume (it stayed in range at full size); those leave with B's principal as
        // a contribution (fee lower). A's sliver earned almost nothing: nothing beyond a few USDC is yield.
        assertLe(_profit(a) - p0, 5e6, "no credit while another tracked position is pending");
    }

    /// L-2 (report trace): an account registered holding HYPE, first booked after the market fell 8%: the first
    /// priced sync had no reference price, so the return to the registration price was profit. Now registration
    /// stores the anchor and its time. Fails on 0fe4d85 (fee about 48 USDC).
    function test_L2_PoC_FirstBookingAfterRegistrationAdjusted() public {
        address o = vm.addr(ALICE_PK);
        address a = _deployHybrid(o);
        vm.deal(a, 100 ether);
        _deal(a, 20_000e6);
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        vm.prank(relayer);
        module.register(d); // at the anchor P0, nothing booked
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 92 / 100);
        _reportTo();
        _stable();
        _keeperSync(a); // the first priced sync books the holdings at P0 x 0.92
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _moveTo(p0);
        _reportTo();
        _hold(30);
        _feeReady();
        assertLe(_fee(a), 1e6, "no fee: the account is worth what it held at registration");
    }

    /// L-3: the fee needs the guardian's confirmation within a day (a stale confirmed level above a market that
    /// drifted down must not carry a fee). Fails on 0fe4d85 (the fee is charged on a week-old confirmation).
    function test_L3_FeeNeedsRecentConfirmation() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _syncTouch(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _moveTo(module.lastPrice() * 1001 / 1000);
        _stable();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
        _fresh();
        _fee(a); // confirmed now: no revert
    }

    /// L-4: a guardian range is at most 2 x poolBandBps wide (3% at these params), so the keeper's report cannot pick
    /// the confirmed level 10% away from the guardian's bound. Fails on 0fe4d85 (10% was accepted).
    function test_L4_GuardianRangeAtMostTwoBands() public {
        uint256 p = module.lastPrice();
        vm.prank(guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approvePrice(p, p * 105 / 100, vm.getBlockTimestamp() + 1 hours);
        vm.prank(guardian);
        module.approvePrice(p, p * 103 / 100, vm.getBlockTimestamp() + 1 hours);
    }

    // ================================================================== exit (report section 4 recommendation)
    /// The hybrid client exits through EntryPoint.handleOps with the module AND the DelegationManager paused:
    /// revoke, disableDelegation (callable while the DM is paused) and the burn all go through.
    function test_Exit_HybridHandleOpsWithModuleAndDMPaused() public {
        (address a, Delegation memory d, uint256 id) = _invested(ALICE_PK, 10_000e6);
        vm.prank(guardian);
        module.setPaused(true);
        vm.prank(DM_OWNER);
        IDMPause6(DM_ADDR).pause();
        address o = vm.addr(ALICE_PK);
        uint256 u0 = usdc.balanceOf(o);
        _exitHybrid(ALICE_PK, a, d, o);
        assertFalse(module.isActive(a));
        assertTrue(DM.disabledDelegations(DM.getDelegationHash(d)), "disabled while the DM is paused");
        assertEq(POSM.getPositionLiquidity(id), 0, "burned");
        assertGt(usdc.balanceOf(o), u0, "principal out to the owner");
    }
}
