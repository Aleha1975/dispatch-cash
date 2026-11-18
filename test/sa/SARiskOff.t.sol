// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {SAWindow} from "../../src/sa/SAWindow.sol";

/// R4 (risk-off product, docs/ARCHITECTURE.md): the exit window. A sell of base while the account holds no tracked
/// position is charged to `exitTurnoverBps` (own sliding 24 h window), every other swap and every LP add to
/// `swapTurnoverBps`. At the pilot Params (turnover 5000, exit 10000) a full exit to USDC fits one day even right
/// after a re-range used the turnover window; re-entry (buy + mint) stays on the turnover window.
contract SARiskOffTest is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("bob"));

    function setUp() public {
        _setUpEnv(false);
    }

    function _setParams(uint32 turnoverBps, uint16 exitBps) internal {
        LPManagerModule.Params memory p = defaultParams();
        p.swapTurnoverBps = turnoverBps;
        p.exitTurnoverBps = exitBps;
        vm.prank(address(timelock));
        module.setParams(p);
    }

    function _exitUsed(address a) internal view returns (uint256 u) {
        (,,, u) = module.windows(a);
    }

    function _burnAll(address a) internal {
        V4PositionMath.Position[] memory ps = module.positionsOf(a);
        for (uint256 i; i < ps.length; ++i) {
            vm.prank(keeper);
            module.burnPosition(a, ps[i].tokenId, 0, 0);
        }
        assertEq(module.positionsOf(a).length, 0);
    }

    /// Sell `hype` of the account's base in chunks, re-centring the pool (arbitrage) between chunks.
    function _sellAll(address a, uint256 chunks) internal {
        uint256 p0 = poolPrice();
        for (uint256 i; i < chunks; ++i) {
            _stable();
            uint256 amt = i + 1 == chunks ? a.balance : a.balance / (chunks - i);
            uint256 kp = poolPrice();
            vm.prank(keeper);
            module.swap(a, true, amt, kp, 0);
            _moveTo(p0);
            _report();
        }
    }

    function test_R4_ExitFitsOneDayAtPilotParams() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
        id;
        _setParams(5000, 10000);
        uint256 nav = module.accountValue(a, module.lastPrice());
        uint256 tBefore = _turnoverUsed(a);
        assertGt(tBefore, nav * 5000 / 10_000, "the onboarding buy + mint already used the whole pilot turnover");
        _burnAll(a); // burns are free and allowed in every state
        uint256 hype = a.balance;
        assertGt(hype, 0);
        _sellAll(a, 3);
        assertEq(a.balance, 0, "all base sold into USDC");
        assertEq(_turnoverUsed(a), tBefore, "exit sells are not charged to the turnover window");
        assertGt(_exitUsed(a), 0);
        assertLe(_exitUsed(a), nav);
        // holding USDC: value is idle USDC only
        assertEq(module.accountValue(a, module.lastPrice()), usdc.balanceOf(a));
    }

    function test_R4_SellWithPositionStaysOnTurnover() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 5_000e6);
        // a small position keeps the account "in": a further sell is a rebalance, charged to turnover
        _report();
        _stable();
        (int24 tl, int24 tu) = _range(300);
        (uint128 liq,,) = _liqFor(a, tl, tu, a.balance / 10, 500e6);
        uint256 kp = poolPrice();
        vm.prank(keeper);
        module.mintPosition(a, tl, tu, liq, uint128(a.balance), 1_000e6, kp);
        _setParams(5000, 10000);
        uint256 e0 = _exitUsed(a);
        _report();
        _stable();
        uint256 p = poolPrice();
        uint256 sell = a.balance / 2;
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector); // turnover already used by the buy and the mint
        module.swap(a, true, sell, p, 0);
        assertEq(_exitUsed(a), e0);
    }

    function test_R4_ExitWindowCapAndOff() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        _moveTo(module.lastPrice());
        _report();
        _setParams(5000, 2000); // 20% of value per 24 h
        _stable();
        uint256 p = poolPrice();
        uint256 all = a.balance;
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector); // ~40% of value > 20%
        module.swap(a, true, all, p, 0);
        vm.prank(keeper);
        module.swap(a, true, all / 3, p, 0); // ~13%: fits
        _setParams(5000, 0); // SA-4 L-6: off = the sale goes to the turnover window (no longer refused outright)
        _moveTo(p);
        _report();
        _stable();
        p = poolPrice();
        (uint256 t0,,, uint256 e0) = module.windows(a);
        vm.prank(keeper);
        module.swap(a, true, a.balance / 4, p, 0);
        (uint256 t1,,, uint256 e1) = module.windows(a);
        assertGt(t1, t0, "charged to the turnover window");
        assertEq(e1, e0, "not to the exit window");
        uint256 rest = a.balance;
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector); // beyond the turnover room left
        module.swap(a, true, rest, p, 0);
    }

    function test_R4_BuysWithoutPositionStayOnTurnover() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _setParams(5000, 10000);
        _stable();
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector); // re-entry buy is risk-adding: turnover (50%) only
        module.swap(a, false, 6_000e6, p, 0);
        vm.prank(keeper);
        module.swap(a, false, 4_500e6, p, 0);
        assertEq(_exitUsed(a), 0);
    }

    function test_R4_ExitWindowSlidesAndIsPerAccount() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        (address b,) = _onboardHybrid(BOB_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        _moveTo(module.lastPrice());
        _report();
        _buyBase(b, 4_000e6);
        _moveTo(module.lastPrice());
        _report();
        _setParams(5000, 3000);
        _stable();
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.swap(a, true, a.balance * 2 / 3, p, 0); // ~27% of value
        _moveTo(p);
        _report();
        _stable();
        p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector);
        module.swap(a, true, a.balance, p, 0);
        vm.prank(keeper);
        module.swap(b, true, b.balance * 2 / 3, p, 0); // bob's window is his own
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _moveTo(p);
        _report();
        _stable();
        p = poolPrice();
        vm.prank(keeper);
        module.swap(a, true, a.balance, p, 0);
    }

    function test_R4_ExitParamBound() public {
        LPManagerModule.Params memory p = defaultParams();
        p.exitTurnoverBps = 10_001;
        vm.prank(address(timelock));
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.setParams(p);
    }

    /// The whole risk-off cycle at the pilot Params: exit to USDC in one day, re-enter over the turnover window.
    function test_R4_RiskOffCycle() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _setParams(5000, 10000);
        _burnAll(a);
        _sellAll(a, 2);
        uint256 out = usdc.balanceOf(a);
        vm.warp(vm.getBlockTimestamp() + 27 hours); // min 24 h out; the turnover window is free again
        _moveTo(poolPrice());
        _report();
        _stable();
        uint256 nav = module.accountValue(a, module.lastPrice());
        assertEq(nav, out);
        // re-entry day 1: buy ~40% of value in base, then mint what the rest of the turnover window pays for
        uint256 kp = poolPrice();
        vm.prank(keeper);
        module.swap(a, false, nav * 2 / 5, kp, 0);
        _moveTo(poolPrice());
        _report();
        _stable();
        (int24 tl, int24 tu) = _range(300);
        (uint128 liq, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, a.balance, usdc.balanceOf(a));
        kp = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector); // 40% + 0.5 x ~80% > 50%: not all on day 1
        module.mintPosition(a, tl, tu, liq, m0, m1, kp);
        vm.prank(keeper);
        module.mintPosition(a, tl, tu, liq / 5, m0, m1, kp); // a part fits
        // day 2: the rest
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _report();
        _stable();
        V4PositionMath.Position[] memory ps = module.positionsOf(a);
        (liq, m0, m1) = _liqFor(a, tl, tu, a.balance, usdc.balanceOf(a));
        kp = poolPrice();
        vm.prank(keeper);
        module.increasePosition(a, ps[0].tokenId, liq, m0, m1, kp);
        assertEq(_exitUsed(a), 0, "the exit window has expired; re-entry used only turnover");
        assertGt(module.accountValue(a, module.lastPrice()), nav * 99 / 100);
    }
}
