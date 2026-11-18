// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {SAWindow} from "../../src/sa/SAWindow.sol";

interface IPosmModify4 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// Audit SA-4 (reports 1240 and 1241 of commit 04420ec, docs/audit/sa_round4_response.md) regressions. Every test here
/// fails on 04420ec and passes after the fix (checked by running this file against the old sources).
contract SARound4Test is SATestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("bob"));

    function setUp() public {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ helpers
    /// The client's own PositionManager call `data` (native `value` attached), after Permit2 approvals for USDC.
    function _clientPosm(uint256 pk, address a, bytes memory data, uint256 value) internal {
        Execution[] memory xs = new Execution[](3);
        xs[0] = Execution(address(usdc), 0, abi.encodeCall(IERC20.approve, (PERMIT2, type(uint256).max)));
        xs[1] = Execution(
            PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, type(uint160).max, uint48(block.timestamp + 1 hours)))
        );
        xs[2] = Execution(POSM_ADDR, value, abi.encodeCall(IPosmModify4.modifyLiquidities, (data, block.timestamp + 60)));
        _clientExec(pk, a, xs);
    }

    /// DECREASE_LIQUIDITY(all) + INCREASE_LIQUIDITY(all) + CLOSE_CURRENCY x2 + SWEEP(native) in ONE PositionManager
    /// call: the position is emptied (its ticks cleared) and refilled to exactly the books' liquidity.
    function _clientEmptyRefill(uint256 pk, address a, uint256 id, uint128 liq) internal {
        bytes[] memory ps = new bytes[](5);
        ps[0] = abi.encode(id, uint256(liq), uint128(0), uint128(0), bytes(""));
        ps[1] = abi.encode(id, uint256(liq), type(uint128).max, type(uint128).max, bytes(""));
        ps[2] = abi.encode(address(0));
        ps[3] = abi.encode(address(usdc));
        ps[4] = abi.encode(address(0), a);
        bytes memory data = abi.encode(abi.encodePacked(uint8(0x01), uint8(0x00), uint8(0x12), uint8(0x12), uint8(0x14)), ps);
        _clientPosm(pk, a, data, 1 ether);
    }

    function _clientDecrease(uint256 pk, address a, uint256 id, uint128 liq) internal {
        _clientPosm(pk, a, V4PositionMath.removeData(false, id, liq, 0, 0, address(0), address(usdc), a), 0);
    }

    function _clientIncrease(uint256 pk, address a, uint256 id, uint128 liq) internal {
        _clientPosm(
            pk, a, V4PositionMath.increaseData(id, liq, type(uint128).max, type(uint128).max, address(0), address(usdc), a), a.balance
        );
    }

    /// Invested account (exclusive ticks: the seed LP is full range) whose position has earned and been collected by
    /// the keeper (the books' fee mark > 0), with new uncollected fees; anchor trusted, pool at the anchor.
    function _marked(uint256 pk) internal returns (address a, uint256 id) {
        (a,, id) = _invested(pk, 30_000e6);
        _alice = a;
        uint256 ref = module.lastPrice();
        _volume(20_000, 10);
        _moveTo(ref);
        _syncTouch(a); // keeper collect: the books' mark is PoolManager's feeGrowthInsideLast > 0
        _volume(20_000, 5);
        _moveTo(ref);
        _stable();
        vm.prank(keeper);
        module.sync(a);
        assertEq(_pending(a), 0);
    }

    /// The books' liquidity of `id` (first word of snapPos; read raw so this file also compiles on 04420ec).
    function _snapLiq(uint256 id) internal view returns (uint128) {
        (, bytes memory r) = address(module).staticcall(abi.encodeWithSignature("snapPos(uint256)", id));
        return uint128(abi.decode(r, (uint256)));
    }

    /// Trusted anchor with the pool just above it (SALib.feeGate: the anchor not above the pool).
    function _feeReady() internal {
        _moveTo(module.lastPrice() * 1001 / 1000);
        _stable();
    }

    /// Uncollected fees of tracked position `id` of `a` valued at the anchor (PoolManager's own accounting).
    function _owed(uint256 id) internal view returns (uint256) {
        (, int24 tl, int24 tu) = _ticksOf(id);
        (uint128 l, uint256 g0, uint256 g1) = PM.getPositionInfo(key.toId(), POSM_ADDR, tl, tu, bytes32(id));
        (uint256 i0, uint256 i1) = PM.getFeeGrowthInside(key.toId(), tl, tu);
        uint256 f0;
        uint256 f1;
        unchecked {
            f0 = FullMath.mulDiv(i0 - g0, l, 1 << 128);
            f1 = FullMath.mulDiv(i1 - g1, l, 1 << 128);
        }
        return f1 + f0 * module.lastPrice() / 1e18;
    }

    function _ticksOf(uint256 id) internal view returns (uint256, int24, int24) {
        V4PositionMath.Position[] memory ps = module.positionsOf(_alice);
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].tokenId == id) return (id, ps[i].tickLower, ps[i].tickUpper);
        }
        revert("unknown");
    }

    address internal _alice;

    function _setParams(LPManagerModule.Params memory p) internal {
        _schedule(address(module), abi.encodeCall(LPManagerModule.setParams, (p)));
    }

    // ================================================================== H-1 (both): empty and refill
    /// PoC (1240 H-1 / 1241 H-1): the client empties its tracked position directly and adds the same liquidity back
    /// in one batch. Uniswap clears and re-initialises the ticks, PoolManager's fee mark restarts at 0, and the old
    /// unchecked difference wrapped to about n x 2^128 "fees": contributed went to about -3.4e53 and every fee took
    /// 20% of idle USDC. Now the difference is credited only up to the pool's global growth, so nothing is credited.
    function test_H1_PoC_EmptyRefillOneBatch() public {
        (address a, uint256 id) = _marked(ALICE_PK);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _feeReady();
        uint256 snap = vm.snapshotState();
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        uint256 fHonest = module.chargeFee(a);
        vm.revertToState(snap);

        int256 c0 = _acct(a).contributed;
        uint128 liq = _snapLiq(id);
        _clientEmptyRefill(ALICE_PK, a, id, liq);
        assertEq(POSM.getPositionLiquidity(id), liq, "refilled to the books' liquidity");
        vm.prank(keeper);
        module.sync(a);
        int256 c1 = _acct(a).contributed;
        assertGe(c1, c0 - 2, "no phantom yield: contributed not driven negative");
        assertLe(c1, c0 + 1_000e6, "at most the collected fees are booked (as a contribution)");
        vm.warp(vm.getBlockTimestamp() + 1 days); // SA-4 M-2: the client's flow had a price-dependent term
        _feeReady();
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        assertLe(f, fHonest + 1, "no fee beyond the honest one");
    }

    /// Sibling (the second trace of both reports): decrease to 0 and increase in two transactions with an
    /// unpriced sync in between (an untrusted keeper action moves the marks but not the books' liquidity).
    function test_H1_Sibling_EmptyUnpricedSyncRefill() public {
        (address a, uint256 id) = _marked(ALICE_PK);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _stable();
        int256 c0 = _acct(a).contributed;
        int256 p0 = _profit(a);
        uint128 liq = _snapLiq(id);
        _clientDecrease(ALICE_PK, a, id, liq);
        vm.warp(vm.getBlockTimestamp() + 301); // no report within minPriceStable: not trusted
        _reportEquity(a, 0); // a keeper action that syncs at price 0
        _clientIncrease(ALICE_PK, a, id, liq);
        assertEq(POSM.getPositionLiquidity(id), liq, "refilled");
        _feeReady();
        vm.prank(keeper);
        module.sync(a);
        assertGe(_acct(a).contributed, c0 - 2, "no phantom yield");
        assertLe(_profit(a), p0 + 2, "profit not raised by the client's empty / refill");
        vm.warp(vm.getBlockTimestamp() + 1 days); // SA-4 M-2
        _feeReady();
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        assertLe(f, uint256(p0 > 0 ? p0 : int256(0)) * 1500 / 10_000 + 1, "fee only on the real profit");
    }

    /// 1240 L-1 / 1241 (dip and return): L -> L/2 -> L with no priced sync in between: the fees of the missing half
    /// were credited as yield. Now a changed position credits nothing (fees become a contribution: our fee lower).
    function test_H1_Sibling_DipAndReturnCountsNoExtra() public {
        (address a, uint256 id) = _marked(ALICE_PK);
        uint256 ref = module.lastPrice();
        _syncTouch(a); // keeper collect: the mark is current, no uncollected fees
        int256 p0 = _profit(a);
        uint128 liq = _snapLiq(id);
        _clientDecrease(ALICE_PK, a, id, liq / 2);
        vm.warp(vm.getBlockTimestamp() + 301);
        _reportEquity(a, 0); // unpriced sync
        _volume(20_000, 5); // fees accrue on the remaining half only
        _moveTo(ref);
        uint256 owed = _owed(id); // what PoolManager pays the remaining half at the increase
        assertGt(owed, 10e6);
        _clientIncrease(ALICE_PK, a, id, liq / 2); // pays those fees into the account
        assertEq(POSM.getPositionLiquidity(id), liq, "back to the books' liquidity");
        _stable();
        vm.prank(keeper);
        module.sync(a);
        // the old rule credited (growth) x liq, twice what PoolManager paid; now the credit is at most what reached
        // the account above the snapshot (idle-surplus cap), i.e. the fees the half that stayed really earned
        assertLe(_profit(a) - p0, int256(owed) + 10e6, "no fee income counted for liquidity the position did not hold");
    }

    // ================================================================== M-3 (1240) / M-2 (1241): sync before registration
    /// PoC: anyone opened the books of a future client (a 7702 EOA holding HYPE) at today's anchor; appreciation
    /// before registration was then charged as profit. Now sync refuses an unregistered address, and a first
    /// registration starts the books from zero.
    function test_M3_PoC_SyncRefusesUnregistered() public {
        address eoa = vm.addr(BOB_PK);
        vm.deal(eoa, 10 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LPManagerModule.NotRegistered.selector);
        module.sync(eoa);
        assertEq(_acct(eoa).contributed, 0);
        assertEq(_acct(eoa).snapBase, 0);
    }

    // ================================================================== M-2 (1240): fee a day after a priced flow
    /// PoC (trace B): the client sends HYPE out; the flow is booked at the anchor of that moment. SA-7 (replaces the
    /// day of waiting): the booking sets the high-water mark to at least the profit after it, so a fee right after
    /// it has nothing to charge, whatever price the flow really had.
    function test_M2_PoC_NoFeeOnGainBeforePricedFlow() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _syncTouch(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _feeReady();
        uint256 snap = vm.snapshotState();
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        module.chargeFee(a); // nothing in the way without a flow (a zero fee is fine)
        vm.revertToState(snap);
        _clientExec1(ALICE_PK, a, vm.addr(ALICE_PK), a.balance / 2, "");
        vm.prank(keeper);
        module.sync(a);
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        assertEq(module.chargeFee(a), 0, "no fee on anything before the priced booking");
    }

    /// Sibling: a USDC-only flow is price-free and does not delay the fee.
    function test_M2_Sibling_UsdcFlowDoesNotDelay() public {
        (address a,) = _onboardHybrid(ALICE_PK, 30_000e6);
        _buyBase(a, 12_000e6);
        _report();
        _syncTouch(a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _feeReady();
        _clientExec1(ALICE_PK, a, address(usdc), 0, abi.encodeCall(IERC20.transfer, (vm.addr(ALICE_PK), 1_000e6)));
        vm.prank(keeper);
        module.sync(a);
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        module.chargeFee(a); // no FeeTooEarly
    }

    // ================================================================== M-3 (1241) / L-5 (1240): approved equity
    /// PoC (trace c): keeper + guardian approve a large hedge equity for an account and the keeper pulls treasury
    /// USDC into it. Now the keeper returns at most the net margin the account really sent.
    function test_M3b_PoC_KeeperReturnCappedByNetMargin() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _report();
        _stable();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 1_000e6);
        _deal(treasury, 100_000e6);
        SALib.Account memory s = _acct(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 50_000e6, block.timestamp + 1 hours);
        _reportEquity(a, 50_000e6);
        assertEq(_acct(a).hedgeEquity, 50_000e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LPManagerModule.HedgeCap.selector, 50_000e6, 1_000e6));
        module.returnHedgeMargin(a, 50_000e6);
        vm.prank(keeper);
        module.returnHedgeMargin(a, 1_000e6);
        vm.prank(treasury); // the treasury itself may return more (realised hedge profit)
        module.returnHedgeMargin(a, 1_000e6);
    }

    /// Sibling (trace a / b): the approved equity above the net margin widens no window and carries no fee.
    function test_M3b_Sibling_ApprovedEquityWidensNoWindowNoFee() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 3_000e6);
        _report();
        _syncTouch(a);
        _stable();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _feeReady();
        _reportEquity(a, 1_000e6); // the fee needs a recent hedge report
        uint256 snap = vm.snapshotState();
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        uint256 f0 = module.chargeFee(a);
        vm.revertToState(snap);
        SALib.Account memory s = _acct(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 1_000_000e6, block.timestamp + 1 hours);
        _reportEquity(a, 1_000_000e6);
        _fresh(); // SA-6 L-3
        vm.prank(keeper);
        assertEq(module.chargeFee(a), f0, "no fee on approved equity above the net margin");
        // the turnover window is still measured on the real value (about 10k; 2x at the test params)
        (uint256 used,,,) = module.windows(a);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector);
        module.swap(a, false, 25_000e6 - used, p, 0);
    }

    // ================================================================== Lows
    /// L-3 (1240): a keeper burn after a direct client decrease books only the liquidity it removes; the rest stays
    /// tracked until the next priced sync books it as the client's outflow at the anchor.
    function test_L3_BurnAfterClientDecreaseBooksLive() public {
        (address a, uint256 id) = _marked(ALICE_PK);
        uint128 liq = _snapLiq(id);
        _clientDecrease(ALICE_PK, a, id, liq / 2);
        vm.warp(vm.getBlockTimestamp() + 301);
        vm.prank(keeper);
        module.burnPosition(a, id, 0, 0); // allowed untrusted: its sync is unpriced
        assertEq(module.positionsOf(a).length, 1, "kept until a priced sync books the rest");
        assertEq(_snapLiq(id), liq / 2, "the client's part");
        _stable();
        vm.prank(keeper);
        module.sync(a);
        assertEq(module.positionsOf(a).length, 0);
        assertApproxEqAbs(_pending(a), 0, 2);
    }

    /// L-11 (1240) / L-10 (1241): the executor role cannot be renounced either.
    function test_L11_NoExecutorRenounce() public {
        bytes32 role = timelock.EXECUTOR_ROLE();
        vm.prank(operator);
        vm.expectRevert(VaultTimelock.NoRenounce.selector);
        timelock.renounceRole(role, operator);
    }

    /// L-8 (both): after refDriftBps is lowered, a report of the stored anchor does not move it against the report.
    function test_L8_LoweredCapNoMoveAgainstReport() public {
        uint256 p0 = module.lastPrice();
        LPManagerModule.Params memory p = defaultParams();
        p.refDriftBps = 200;
        bytes memory call = abi.encodeCall(LPManagerModule.setParams, (p));
        vm.prank(operator);
        timelock.schedule(address(module), 0, call, bytes32(0), bytes32(0), 2 days);
        vm.warp(vm.getBlockTimestamp() + 2 days - 2 hours);
        _moveTo(p0 * 1035 / 1000);
        _reportTo();
        _moveTo(p0);
        _reportTo(); // trailing range [p0, 1.035 p0], anchor p0
        assertEq(module.lastPrice(), poolPrice());
        uint256 a0 = module.lastPrice();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(operator);
        timelock.execute(address(module), 0, call, bytes32(0), bytes32(0)); // cap 10% -> 2%
        vm.warp(vm.getBlockTimestamp() + 300);
        vm.prank(keeper);
        module.reportPrice(a0);
        assertEq(module.lastPrice(), a0, "not moved to high / 1.02 against the report");
    }

    /// L-6 (1240) / L-5 (1241): an exit sale that does not fit the exit window falls back to the turnover window.
    function test_L6_ExitWindowFullFallsBackToTurnover() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        _moveTo(module.lastPrice());
        _report();
        LPManagerModule.Params memory p = defaultParams();
        p.swapTurnoverBps = 20000;
        p.exitTurnoverBps = 1000; // 10% of value
        _setParams(p);
        _stable();
        uint256 kp = poolPrice();
        (uint256 t0,,,) = module.windows(a);
        vm.prank(keeper);
        module.swap(a, true, a.balance / 2, kp, 0); // ~20% of value: more than the exit window
        (uint256 t1,,, uint256 e1) = module.windows(a);
        assertEq(e1, 0, "not charged to the exit window");
        assertGt(t1, t0, "charged to the turnover window");
    }

    /// I-3 (1241): no delegation lifetime above 400 days.
    function test_I3_DelegationLifetimeCapped() public {
        address o = vm.addr(ALICE_PK);
        address a = _deployHybrid(o);
        Delegation memory d = _delegation(a, address(module), _terms(address(module)), block.timestamp + 401 days, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, ALICE_PK);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, uint8(6)));
        module.register(d);
    }

    /// I-5 (1241): a base sale too small to be worth one asset unit is refused (it would charge no turnover).
    function test_I5_DustSellRefused() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 1_000e6);
        _report();
        _stable();
        uint256 kp = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.ZeroAmount.selector);
        module.swap(a, true, 1e9, kp, 1);
    }

    /// I-2 (1240) / I-4 (1241): the owner EOA of a hybrid account can revoke before registration, deployed or not.
    function test_I2_HybridOwnerPreRevoke() public {
        address o = vm.addr(ALICE_PK);
        address a = _hybridAddress(o);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LPManagerModule.NotOwnAccount.selector);
        module.revoke(a);
        vm.prank(o);
        module.revoke(a);
        assertTrue(_acct(a).revoked);
        _deployHybrid(o);
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        vm.prank(relayer);
        vm.expectRevert(SALib.NotOwnAccount.selector);
        module.register(d);
    }
}
