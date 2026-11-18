// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {SAWindow} from "../../src/sa/SAWindow.sol";

interface IPosmModify5 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// Audit SA-5 (report 1249 of commit 30aae1e, docs/audit/sa_round5_response.md) regressions. Every Medium PoC here,
/// and the Low ones marked so, fails on 30aae1e and passes after the fix (checked by running this file against the old
/// sources; the file uses only interfaces that exist there, reading new getters raw).
contract SARound5Test is SATestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    address internal _alice;

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
        xs[2] = Execution(POSM_ADDR, value, abi.encodeCall(IPosmModify5.modifyLiquidities, (data, vm.getBlockTimestamp() + 60)));
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

    function _snapLiq(uint256 id) internal view returns (uint128) {
        (, bytes memory r) = address(module).staticcall(abi.encodeWithSignature("snapPos(uint256)", id));
        return uint128(abi.decode(r, (uint256)));
    }

    /// Invested account whose tracked position earned fees that the keeper collected (a module touch: marks current).
    function _marked() internal returns (address a, uint256 id) {
        (a,, id) = _invested(ALICE_PK, 30_000e6);
        _alice = a;
        uint256 ref = module.lastPrice();
        _volume(20_000, 10);
        _moveTo(ref);
        _syncTouch(a);
    }

    function _keeperSync(address a) internal {
        vm.prank(keeper);
        module.sync(a);
    }

    /// The guardian confirms the market (+-0.5%); the keeper's next report consumes it.
    function _confirm5() internal {
        uint256 p = poolPrice();
        vm.prank(guardian);
        module.approvePrice(p * 995 / 1000, p * 1005 / 1000, vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        module.reportPrice(p);
    }

    function _feeReady() internal {
        _moveTo(module.lastPrice() * 1001 / 1000);
        _stable();
    }

    function _hold(uint256 hours_) internal {
        for (uint256 i; i < hours_ / 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 3 hours);
            _stable();
        }
    }

    // ================================================================== M-1: dip and restore of a tracked position
    /// PoC (report trace, attack agent 10): the client lowers its tracked position to a sliver, the market trades
    /// through the range, and the client restores the liquidity at a different price. The fee mark grew for the whole
    /// interval, PoolManager paid almost nothing (the position was nearly empty), and the restore at another price
    /// left a surplus of HYPE (paid for with USDC). The per-token idle cap let that HYPE through as yield: profit rose
    /// by the HYPE half of growth x L and the fee took a share of principal. Now a mix change (one token below the
    /// snapshot) credits nothing.
    function test_M1_PoC_DipRestoreAtAnotherPriceNoYield() public {
        (address a, uint256 id) = _marked();
        uint256 ref = module.lastPrice();
        int256 p0 = _profit(a);
        uint128 liq = _snapLiq(id);
        uint128 dip = liq - liq / 1000;
        _clientDecrease(ALICE_PK, a, id, dip); // a sliver stays: the ticks stay initialised (no re-base)
        _volume(20_000, 10); // the range's fee growth runs while the account is out
        _moveTo(ref * 1004 / 1000); // the restore happens at another price (inside the booking band)
        _clientIncrease(ALICE_PK, a, id, dip);
        assertEq(POSM.getPositionLiquidity(id), liq, "back to the books' liquidity");
        _stable();
        _keeperSync(a);
        // the sliver earned almost nothing; the restore's price gain is a few USDC; no hundreds of USDC of "fees"
        assertLe(_profit(a) - p0, 5e6, "a dip and restore at another price books no yield");
    }

    /// Sibling (Option B of the report): the dip was seen by a sync (an unpriced keeper action), the client then
    /// restores at the same price and tops the account up directly (no deposit). The per-token cap let the top-up
    /// through as yield; now a position whose PoolManager liquidity differed at the last look credits nothing.
    function test_M1_Sibling_DipSeenThenTopUpNoYield() public {
        (address a, uint256 id) = _marked();
        uint256 ref = module.lastPrice();
        int256 p0 = _profit(a);
        uint128 liq = _snapLiq(id);
        uint128 dip = liq - liq / 1000;
        _clientDecrease(ALICE_PK, a, id, dip);
        vm.warp(vm.getBlockTimestamp() + 301); // not trusted: the next keeper action syncs at price 0
        _reportEquity(a, 0); // the look that sees the dip
        _volume(20_000, 10);
        _moveTo(ref);
        _clientIncrease(ALICE_PK, a, id, dip);
        assertEq(POSM.getPositionLiquidity(id), liq);
        _deal(a, 2_000e6); // a direct top-up in both tokens (not through deposit)
        vm.deal(a, a.balance + 50 ether);
        _stable();
        int256 c0 = _acct(a).contributed;
        _keeperSync(a);
        assertGe(_acct(a).contributed - c0, int256(2_000e6 + 50 * ref) - 5e6, "the top-up is a contribution");
        assertLe(_profit(a) - p0, 5e6, "no yield for liquidity the position did not hold");
    }

    /// L-2: a plain client collect after a keeper sync that followed fee accrual stays yield again (the global mark
    /// moves only with the position's mark, so both span the same interval). SA-8 L-1: the credit is USDC only and
    /// only in a booking where idle base did not change, so the client takes its fees to its wallet and returns the
    /// USDC part (the base fees leave the profit: yield taken out).
    function test_L2_PlainCollectAfterSyncIsYield() public {
        (address a, uint256 id) = _marked();
        uint256 ref = module.lastPrice();
        _volume(20_000, 5); // accrual after the last touch
        _moveTo(ref);
        _stable();
        _keeperSync(a); // a look with no touch
        _volume(20_000, 5);
        _moveTo(ref);
        _stable();
        int256 c0 = _acct(a).contributed;
        int256 p0 = _profit(a);
        address eoa = vm.addr(ALICE_PK);
        (uint256 u0, uint256 h0) = (usdc.balanceOf(eoa), eoa.balance);
        _clientPosm(ALICE_PK, a, V4PositionMath.removeData(false, id, 0, 0, 0, address(0), address(usdc), eoa), 0);
        uint256 fu = usdc.balanceOf(eoa) - u0;
        uint256 fh = eoa.balance - h0;
        assertGt(fu, 1e6);
        vm.prank(eoa);
        usdc.transfer(a, fu);
        _keeperSync(a);
        assertApproxEqAbs(_acct(a).contributed, c0, 2, "the collect is not a contribution");
        assertApproxEqAbs(_profit(a), p0 - int256(fh * ref / 1e18), 2, "the USDC fees stay profit");
    }

    // ================================================================== M-2: anchor bound to a confirmed level
    /// PoC (report scenario): a stolen keeper walks the anchor 10% a day; once the trailing 24 h range has forgotten
    /// the old level the next 10% opened, without limit. Now the anchor stays within refDriftBps of the
    /// guardian-confirmed level (the first report here) over any number of days.
    function test_M2_PoC_MultiDayWalkBoundedByConfirmedLevel() public {
        uint256 p0 = module.lastPrice();
        uint256 floor = p0 * 10_000 / 11_000;
        _moveTo(p0 * 75 / 100); // the thin pool held at the attacker's level
        uint256 p = poolPrice();
        for (uint256 day; day < 3; ++day) {
            _reportSteps(p, 12);
            assertGe(module.lastPrice(), floor, "never more than refDriftBps from the confirmed level");
            vm.warp(vm.getBlockTimestamp() + 27 hours);
        }
        _reportSteps(p, 12);
        assertApproxEqRel(module.lastPrice(), floor, 0.001e18);
    }

    /// Sibling: the guardian's confirmation moves the level; the keeper then walks within refDriftBps of the new one.
    function test_M2_Sibling_GuardianConfirmMovesLevel() public {
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 108 / 100);
        _reportTo();
        _confirm5();
        uint256 c = module.lastPrice();
        (,,, uint256 base) = _priceBudget();
        assertEq(base, c, "the confirmed level");
        _moveTo(p0 * 125 / 100);
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _reportSteps(poolPrice(), 12);
        assertApproxEqRel(module.lastPrice(), c * 110 / 100, 0.001e18, "10% from the new level, not from p0");
    }

    /// M-2 (LP term): an LP add is charged to the turnover window at its whole principal (it was principal x slip /
    /// (slip + band), half at the pilot values, so a narrow add next to a pushed pool doubled the stolen-keeper route).
    function test_M2_LP_AddChargedAtFullPrincipal() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _stable();
        (int24 tl, int24 tu) = _range(300);
        (uint128 liq, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, a.balance / 4, usdc.balanceOf(a) / 4);
        uint256 kp = poolPrice();
        (uint256 u0, uint256 h0) = (usdc.balanceOf(a), a.balance);
        uint256 t0 = _turnoverUsed(a);
        vm.prank(keeper);
        module.mintPosition(a, tl, tu, liq, m0, m1, kp);
        uint256 paid = (u0 - usdc.balanceOf(a)) + (h0 - a.balance) * module.lastPrice() / 1e18;
        assertApproxEqRel(_turnoverUsed(a) - t0, paid, 0.002e18, "charged at the principal paid");
    }

    function _priceBudget() internal view returns (uint256 lo, uint256 hi, uint256 until, uint256 base) {
        (, bytes memory r) = address(module).staticcall(abi.encodeWithSignature("priceBudget()"));
        (lo, hi, until, base) = abi.decode(r, (uint256, uint256, uint256, uint256));
    }

    // ================================================================== M-3: fee gate on the confirmed level
    /// PoC (report scenario): the keeper walks the anchor and the pool up, holds the level for 27 h so that the
    /// trailing 24 h low is the walked anchor, and charges a fee on the phantom gain of the account's HYPE. Now the
    /// fee is measured at most poolBandBps above the guardian-confirmed level.
    function test_M3_PoC_WalkedLowCarriesNoFee() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _syncTouch(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 108 / 100); // pool pushed
        _reportTo(); // anchor walked in steps
        _hold(30); // held until the trailing low is the walked anchor
        _feeReady();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
    }

    // ================================================================== M-4: late booking after an untrusted period
    /// PoC (report scenario): the client sends all its HYPE out; the market moves 8% before the anchor is trusted
    /// again; the withdrawal is booked at the later anchor, so contributed falls by more than the HYPE was worth when
    /// it left, and the fee is charged on that phantom profit. Now the booking raises the high-water mark by the
    /// largest gain the flow can have between the account's last priced booking and this one.
    function test_M4_PoC_LateBookedFlowCarriesNoFee() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _syncTouch(a); // last priced booking at P0
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _stable();
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), a.balance, ""); // all HYPE out, nobody books it now
        _moveTo(module.lastPrice() * 108 / 100); // the market moves: the anchor is not trusted until it follows
        _reportTo();
        _confirm5(); // the guardian confirms the new level (so only the late booking is under test)
        _stable();
        _keeperSync(a); // booked at P1
        _hold(30);
        _feeReady();
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        assertEq(f, 0, "no fee on the gain the withdrawn HYPE made after it left");
    }

    // ================================================================== Lows
    /// L-1: one wei-scale native transfer by anyone does not defer the fee. SA-7: there is no day of waiting at all
    /// (a priced change, dust included, resets the fee baseline instead: our fee only).
    function test_L1_DustDoesNotDelayFee() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _syncTouch(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _feeReady();
        vm.deal(a, a.balance + 1e12); // a stranger's dust
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        module.chargeFee(a); // no FeeTooEarly
    }

    /// L-3: a third party can no longer choose the booking moment; the client and the keeper can.
    function test_L3_ThirdPartyCannotSync() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _stable();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LPManagerModule.NotOwnAccount.selector);
        module.sync(a);
        vm.prank(vm.addr(ALICE_PK));
        module.sync(a);
        vm.prank(a);
        module.sync(a);
        _keeperSync(a);
    }

    /// L-4: the parameters' product (the stolen-keeper bound per 24 h) and the stable-window floor are bounded.
    function test_L4_ParamProductAndStableFloor() public {
        LPManagerModule.Params memory p = defaultParams();
        p.swapTurnoverBps = 50_000;
        vm.prank(address(timelock));
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.setParams(p);
        p = defaultParams();
        p.minPriceStable = 120;
        vm.prank(address(timelock));
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.setParams(p);
        vm.prank(address(timelock));
        module.setParams(defaultParams());
    }

    /// I-1: a guardian range is bounded in width (SA-6 L-4: 2 x poolBandBps, 3% at these params; was 10%).
    function test_I1_GuardianRangeWidthBounded() public {
        uint256 p = module.lastPrice();
        vm.prank(guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.approvePrice(p, p * 2, vm.getBlockTimestamp() + 1 hours);
        vm.prank(guardian);
        module.approvePrice(p, p * 103 / 100, vm.getBlockTimestamp() + 1 hours);
    }
}
