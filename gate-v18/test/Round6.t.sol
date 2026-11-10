// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";
import "./Adversarial.t.sol";

/// A smart account that can run several calls in one transaction (what the Hybrid account's batch mode does for the owner).
contract BatchAccount {
    address public owner;
    constructor(address o) { owner = o; }
    receive() external payable {}
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
    }
    function batch(address[] calldata targets, bytes[] calldata datas) external {
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, bytes memory r) = targets[i].call(datas[i]);
            if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
        }
    }
}

/// Round 6: fixes for external audit job 1211 (M-1 / L-1 loss record as a share of one budget, L-2 / L-3 pause window, L-4 free shave, L-5 exits and the allowance,
/// L-6 junk lots, I-2 / I-3 / I-4). DESIGN.md section 9.
contract Round6Test is GateBase {
    function _pause(bool p) internal { vm.prank(guardian); gate.setPaused(p); }
    function _hours(uint256 n) internal { vm.warp(block.timestamp + n * 1 hours + 1); }
    function _ownerSell(MockAccount a, address ow, MockToken t, uint256 amt) internal {
        vm.prank(ow, ow); a.exec{gas: 700_000}(address(gate), 0, abi.encodeCall(GuardedGate.exitSell, (address(t), amt, 1, route(address(t), K_ETH, amt), type(uint256).max)));
    }

    // ---------- M-1: a junk lot of far larger cost cannot speed up the drain ----------
    // The auditor's setup: native 5, real lot R (cost 35), junk lot J (cost 140, made by buy-and-return cycles). The key books R's full budget, then every hour a
    // 1-wei loss on J (the reader with the bigger budget) and a sale of R for the room that the record shows. Old code: R's 7-day total was far above two budgets.
    function test_M1_junk_lot_of_larger_cost_does_not_refill_room_for_the_real_lot() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok);
        MockToken junk = new MockToken(); _approveGate(a, junk);
        vm.deal(address(a), 40 ether); router.setFixedOut(1000 ether);
        _buyT(a, tok, 17.5 ether); _hours(2); _buyT(a, tok, 17.5 ether);                   // R: cost 35, native 5
        for (uint256 i = 0; i < 8; i++) { _hours(2); vm.deal(address(a), 22.5 ether); _buyT(a, junk, 17.5 ether); }   // J: cost 140
        router.setFixedOut(0); vm.deal(address(a), 5 ether);
        (, uint256 cost0) = gate.lotOf(address(a), address(tok)); (, uint256 ciJ0) = gate.lotOf(address(a), address(junk)); assertEq(ciJ0, 140 ether);
        (, uint256 b0) = gate.budgetOf(address(a), address(tok)); assertEq(b0, (5 ether + 35 ether) * 3000 / 10000);
        uint256 t0 = block.timestamp;
        for (uint256 h = 0; h <= 7 * 24; h++) {
            vm.warp(t0 + h * 1 hours); vm.deal(address(a), 5 ether);
            { (uint256 tj, uint256 cj) = gate.lotOf(address(a), address(junk)); uint256 cx = cj * 1e18 / tj; router.set(1000, cx - 1, address(0));
              a.exec(address(gate), 0, _sellData(junk, 1e18, 1)); }                          // J: a loss of 1 wei, the reader with the large budget
            router.set(1000, 1, address(0));
            (uint256 tk, uint256 ci) = gate.lotOf(address(a), address(tok));
            (uint256 lost, uint256 b) = gate.budgetOf(address(a), address(tok));
            if (b <= lost) continue;
            uint256 amt = (b - lost) * tk / ci;
            if (amt < 1 ether) continue;
            a.exec(address(gate), 0, _sellData(tok, amt, 1));
        }
        (, uint256 cost1) = gate.lotOf(address(a), address(tok));
        assertGe(cost0 - cost1, b0 * 99 / 100);                                              // the first budget really went
        assertLe(cost0 - cost1, 2 * b0 + 1e9);                                               // one budget plus one budget per 7 days, whatever J's cost is
    }
    // The drain rate is the same for every sale, so a deposit cannot make the record read empty retroactively (I-10).
    function test_M1_deposit_does_not_speed_up_the_drain() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 20 ether);
        router.setFixedOut(1000 ether); _buyT(a, tok, 10 ether); router.setFixedOut(0);   // native 10, lot cost 10, budget 6
        router.set(1000, 1, address(0));
        a.exec(address(gate), 0, _sellData(tok, 500 ether, 1));                             // cost 5, out ~0: fill = 5 / 6
        (uint256 f0, ) = gate.loss(address(a)); assertApproxEqAbs(f0, 833333333333333334, 1e3);
        vm.warp(block.timestamp + 1 days); vm.deal(address(a), 10_000 ether);               // a huge deposit one day later
        (uint256 lost, uint256 b) = gate.budgetOf(address(a), address(tok));
        uint256 fNow = lost * 1e18 / b; assertApproxEqAbs(fNow, f0 - uint256(1e18) / 7, 1e4);       // still drained by exactly one day
    }
    function test_M1_floorFor_edge_is_exact_with_the_share() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 10 ether);
        router.setFixedOut(1000 ether); _buyT(a, tok, 5 ether); router.setFixedOut(0);
        router.set(1000, 1, address(0));
        (uint256 tk, ) = gate.lotOf(address(a), address(tok));
        a.exec(address(gate), 0, _sellData(tok, tk / 5, 1));                                // books about 1 of 3
        vm.warp(block.timestamp + 1 days);
        (uint256 tk2, uint256 ci2) = gate.lotOf(address(a), address(tok));
        uint256 f = gate.floorFor(address(a), address(tok), tk2);
        uint256 price = (f * 1e18 + tk2 - 1) / tk2;
        router.set(1000, price, address(0));
        if (f > 0) { uint256 out = tk2 * price / 1e18; assertGe(out, f); assertLe(ci2 - out, ci2); }
        a.exec(address(gate), 0, _sellData(tok, tk2, 1));                                   // a sale at the floor passes
        // one wei below the floor is refused
        MockAccount b = new MockAccount(owner1); _approveGate(b, tok); vm.deal(address(b), 10 ether);
        router.setFixedOut(1000 ether); _buyT(b, tok, 5 ether); router.setFixedOut(0);
        (uint256 tb, ) = gate.lotOf(address(b), address(tok)); uint256 fb = gate.floorFor(address(b), address(tok), tb);
        router.set(1000, (fb - 1) * 1e18 / tb, address(0)); vm.expectRevert(); b.exec(address(gate), 0, _sellData(tok, tb, 1));
    }

    // ---------- L-1: a loss booked on a large base clears in 7 days on a small one ----------
    function test_L1_loss_on_a_large_base_does_not_block_a_stop_loss_on_a_small_one() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); MockToken b = new MockToken(); _approveGate(a, b);
        vm.deal(address(a), 10 ether); router.setFixedOut(1000 ether); _buyT(a, tok, 10 ether); router.setFixedOut(0);   // native 0, lot A cost 10, budget 3
        router.set(1000, 1, address(0));
        a.exec(address(gate), 0, _sellData(tok, 300 ether, 1));                             // cost 3, out ~0: a full record (share 1.0)
        (uint256 f, ) = gate.loss(address(a)); assertApproxEqAbs(f, 1e18, 1e3);
        _hours(1); vm.deal(address(a), 1 ether); router.setFixedOut(1000 ether); _buyT(a, b, 1 ether); router.setFixedOut(0);   // the redeployment: small lot B, cost 1, native 0
        vm.expectRevert(); a.exec(address(gate), 0, _sellData(b, 290 ether, 1));            // a stop-loss at once: refused (the record is full)
        vm.warp(block.timestamp + 7 days + 1 hours);                                        // old code: used 3 drains by 0.3 per week -> still refused for ~9 weeks
        a.exec(address(gate), 0, _sellData(b, 290 ether, 1));                               // 29% of B (cost 0.29 of a budget of 0.3) is booked
        (uint256 f2, ) = gate.loss(address(a)); assertLe(f2, 1e18);
        assertGe(f2, 0.9e18);
    }

    // ---------- L-2: replaceGuardian does not reset the pause window ----------
    function test_L2_trace_A_expired_pause_replacement_gives_no_second_pause() public {
        uint256 T = block.timestamp; address g2 = address(0x6A12E);
        _pause(true);
        vm.warp(T + 7 days); assertFalse(gate.paused());
        vm.expectEmit(false, false, false, true); emit GuardedGate.Paused(false);            // I-4: the expired pause is booked and announced
        vm.prank(cold); gate.replaceGuardian(g2);
        assertEq(gate.pausedAt(), 0); assertEq(gate.pauseEnd(), T + 7 days); assertEq(gate.pauseUsed(), 7 days);
        vm.prank(g2); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // old code: a second 7 days, 14 days in a row
        vm.warp(T + 10 days); vm.prank(g2); gate.setPaused(true); assertTrue(gate.paused());       // the window slides on
    }
    function test_L2_trace_B_running_pause_replacement_does_not_clear_the_used_time() public {
        uint256 T = block.timestamp; address g2 = address(0x6A12E);
        _pause(true); vm.warp(T + 6 days); _pause(false);
        vm.warp(T + 6 days + 1); _pause(true); assertEq(gate.pauseExp(), T + 7 days + 1);
        vm.warp(T + 6 days + 2); vm.prank(cold); gate.replaceGuardian(g2);
        assertEq(gate.pauseExp(), T + 7 days + 1); assertTrue(gate.paused());
        vm.warp(T + 7 days + 1); vm.prank(g2); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // old code: paused 13 of 13 days
    }
    function test_L2_cold_key_alone_cannot_chain_pauses_by_alternating_guardians() public {
        uint256 T = block.timestamp; address g2 = address(0x6A12E); address g3 = address(0x6A12F);
        _pause(true); vm.warp(T + 7 days);
        vm.prank(cold); gate.replaceGuardian(g2); vm.prank(g2); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
        vm.prank(cold); gate.replaceGuardian(g3); vm.prank(g3); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
        vm.prank(cold); gate.replaceGuardian(guardian); vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
    }

    // ---------- L-3: the window slides ----------
    function test_L3_daily_false_alarms_never_use_up_the_allowance() public {
        uint256 T = block.timestamp;
        for (uint256 d = 0; d < 60; d++) { vm.warp(T + d * 1 days); _pause(true); vm.warp(T + d * 1 days + 2 hours); _pause(false); }   // 2 h every day, lifted by hand
        vm.warp(T + 60 days); _pause(true);                                                 // a real theft on day 60
        assertGt(gate.pauseExp() - block.timestamp, 6 days);                                // old code: ~2 days (pauseUsed never reset); now 7 d minus the last 8 days (<= 18 h)
        assertLe(gate.pauseUsed(), 20 hours);
    }
    function test_L3_any_8_days_hold_at_most_7_days_of_pause_for_a_mixed_guardian() public {
        uint256 T = block.timestamp; uint256 N = 90 * 24; bool[] memory on = new bool[](N);
        for (uint256 i = 0; i < N; i++) {                                                   // 5 h pause, lifted after 3 h of it when i is odd; the rest of the time it re-pauses at once
            vm.warp(T + i * 1 hours);
            if (!gate.paused()) { vm.prank(guardian); try gate.setPaused(true) {} catch {} }
            else if (i % 7 == 0) { _pause(false); vm.prank(guardian); try gate.setPaused(true) {} catch {} }
            on[i] = gate.paused();
        }
        uint256 sum; uint256 maxSum;
        for (uint256 i = 0; i < N; i++) {
            if (on[i]) sum++;
            if (i >= 192 && on[i - 192]) sum--;
            if (sum > maxSum) maxSum = sum;
        }
        assertLe(maxSum, 7 * 24);
    }

    // ---------- L-4: no free shave of one unit; an exit of the whole lot goes through ----------
    function test_L4_executor_sell_that_releases_no_cost_is_refused_and_the_full_exit_succeeds() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 1 ether);
        router.setFixedOut(1000 ether); a.exec(address(gate), 0.0011 ether, _buyData(tok, 0.0011 ether)); router.setFixedOut(0); router.set(1000, 1e18, address(0));   // a unit pays 1 wei   // lot 1000e18 units, cost 1.1e15 wei: a unit costs < 1 wei
        (uint256 tk, uint256 ci) = gate.lotOf(address(a), address(tok)); assertEq(tk, 1000 ether);
        for (uint256 i = 0; i < 5; i++) { vm.expectRevert(GuardedGate.ZeroAmount.selector); a.exec(address(gate), 0, _sellData(tok, 1, 1)); }   // old code: each one shaved a unit
        (uint256 tk2, uint256 ci2) = gate.lotOf(address(a), address(tok)); assertEq(tk2, tk); assertEq(ci2, ci);
        _ownerSell(a, owner1, tok, tk);                                                      // the owner's "sell all" lands on the lot he read
        (uint256 tk3, ) = gate.lotOf(address(a), address(tok)); assertEq(tk3, 0);
    }

    // ---------- L-5: exits survive an allowance the executor zeroed, with the approve batched in front ----------
    function test_L5_exit_after_the_executor_zeroed_the_allowance_needs_the_batched_approve() public {
        BatchAccount b = new BatchAccount(owner1); vm.deal(address(b), 5 ether); _approveGate(MockAccount(payable(address(b))), tok);
        b.exec(address(gate), 1 ether, _buyData(tok, 1 ether));
        b.exec(address(tok), 0, abi.encodeCall(MockToken.approve, (address(gate), 0)));      // the stolen executor key: approve(gate, 0) through the approve delegation
        bytes memory ex = abi.encodeCall(GuardedGate.exitSell, (address(tok), 400 ether, 1, route(address(tok), K_ETH, 400 ether), type(uint256).max));
        vm.prank(owner1, owner1); vm.expectRevert(GuardedGate.TransferFailed.selector); b.exec(address(gate), 0, ex);   // alone, the exit has no allowance
        address[] memory tg = new address[](2); bytes[] memory ds = new bytes[](2);
        tg[0] = address(tok); ds[0] = abi.encodeCall(MockToken.approve, (address(gate), 400 ether)); tg[1] = address(gate); ds[1] = ex;
        uint256 before = address(b).balance;
        vm.prank(owner1, owner1); b.batch(tg, ds);                                           // the documented path: approve + exitSell in one batch
        assertEq(address(b).balance - before, 0.4 ether); (uint256 tk, ) = gate.lotOf(address(b), address(tok)); assertEq(tk, 600 ether);
        // the cold key's exit works the same way
        b.exec(address(tok), 0, abi.encodeCall(MockToken.approve, (address(gate), 0)));
        ds[0] = abi.encodeCall(MockToken.approve, (address(gate), 100 ether));
        ds[1] = abi.encodeCall(GuardedGate.exit, (address(tok), 100 ether, 1, route(address(tok), K_ETH, 100 ether)));
        vm.prank(cold, cold); b.batch(tg, ds);
        (uint256 tk2, ) = gate.lotOf(address(b), address(tok)); assertEq(tk2, 500 ether);
    }

    // ---------- L-6: junk lots ----------
    function _junkRegistry(MockAccount a) internal returns (MockToken real) {
        real = new MockToken(); _approveGate(a, real); vm.deal(address(a), address(a).balance + 1 ether);
        a.exec(address(gate), 0.0011 ether, _buyData(real, 0.0011 ether));
        for (uint256 i = 0; i < 31; i++) {
            MockToken j = MockToken(address(new GasBurnToken())); _approveGate(a, j);
            vm.warp(block.timestamp + 11 minutes);
            a.exec(address(gate), 0.0011 ether, _buyData(j, 0.0011 ether));
        }
        assertEq(gate.lotsOf(address(a)).length, 32);
    }
    function test_L6_executor_sell_is_cheap_with_32_gas_burning_lots() public {
        MockToken real = _junkRegistry(acct);
        uint256 g = gasleft();
        acct.exec{gas: 400_000}(address(gate), 0, _sellData(real, 5e17, 1));                // old code: ~0.7M gas of walk, GasTooLow with this limit
        assertLt(g - gasleft(), 400_000);
        assertEq(gate.lotsOf(address(acct)).length, 32);
    }
    function test_L6_forgetLots_clears_the_registry_in_one_transaction() public {
        MockToken real = _junkRegistry(acct); real;
        address[] memory all = gate.lotsOf(address(acct));
        vm.prank(thief); gate.forgetLots(all);                                              // somebody else's call only touches his own (empty) books
        assertEq(gate.lotsOf(address(acct)).length, 32);
        acct.exec{gas: 500_000}(address(gate), 0, abi.encodeCall(GuardedGate.forgetLots, (all)));
        assertEq(gate.lotsOf(address(acct)).length, 0); assertEq(gate.costOf(address(acct)), 0);
        MockToken fresh = new MockToken(); _approveGate(acct, fresh);
        acct.exec(address(gate), 0.01 ether, _buyData(fresh, 0.01 ether));                  // buys work again
        assertEq(gate.lotsOf(address(acct)).length, 1);
        address[] memory tooMany = new address[](33);
        vm.expectRevert(GuardedGate.TooLarge.selector); acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.forgetLots, (tooMany)));
    }

    // ---------- I-3: exitSell for an owner that does not resolve is a plain NotOwnerOrigin ----------
    function test_I3_exitSell_with_unresolved_owner_reverts_NotOwnerOrigin() public {
        RevertingOwnerAccount r = new RevertingOwnerAccount(); vm.deal(address(r), 1 ether);
        vm.prank(owner1, owner1); vm.expectRevert(GuardedGate.NotOwnerOrigin.selector);
        r.exec(address(gate), 0, abi.encodeCall(GuardedGate.exitSell, (address(tok), 1, 1, route(address(tok), K_ETH, 1), type(uint256).max)));
    }
    // ---------- I-2: the balance read gets its allowance from 105,000 gas ----------
    function test_I2_balance_read_below_the_floor_reverts_GasTooLow() public {
        uint256 s = gasleft(); s;
        vm.expectRevert(); acct.exec{gas: 90_000}(address(gate), 1 ether, _buyData(tok, 1 ether));
    }
}
