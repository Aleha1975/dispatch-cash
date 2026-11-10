// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";
import "./Adversarial.t.sol";

/// Round 4: fixes for external audit job 1208 (M-2 budget base, L-1 pause cooldown, L-4 trim wrap, L-6 loss accumulator, L-7 revert data, L-9 deadline).
/// The price reference was removed (DESIGN.md section 7), so M-1, L-2, L-3 and I-10 of that report no longer exist.
contract Round4Test is GateBase {
    function _hours(uint256 n) internal { vm.warp(block.timestamp + n * 1 hours + 1); }
    function _ownerSell(MockAccount a, address ow, MockToken t, uint256 amt, uint256 dl) internal {
        vm.prank(ow, ow); a.exec(address(gate), 0, abi.encodeCall(GuardedGate.exitSell, (address(t), amt, 1, route(address(t), K_ETH, amt), dl)));
    }
    function _trimPos(address a) internal view returns (uint256) { return uint256(vm.load(address(gate), keccak256(abi.encode(a, uint256(17))))); }

    // ---------- M-2: the auditor's 12-cycle base inflation ----------
    function test_M2_twelve_junk_buy_cycles_do_not_let_a_rigged_sale_of_lot_R_through() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok);
        MockToken junk = new MockToken(); _approveGate(a, junk);
        vm.deal(address(a), 40 ether);
        _buyT(a, tok, 17.5 ether); _hours(2); _buyT(a, tok, 17.5 ether);                   // lot R: cost 35, native 5
        (uint256 rt, uint256 rc) = gate.lotOf(address(a), address(tok)); assertEq(rc, 35 ether);
        for (uint256 i = 0; i < 12; i++) {
            _hours(2);
            vm.deal(address(a), 22.5 ether);                                               // the pool's return of the previous cycle (5 + 17.5)
            _buyT(a, junk, 17.5 ether);                                                    // junk buy: cost +17.5, native back to 5
            vm.deal(address(a), 22.5 ether);                                               // the attacker's pool sends the native back after the call
        }
        assertEq(gate.costOf(address(a)), 35 ether + 12 * 17.5 ether);                      // the fake cost sits in costOf (old base: 245 + 22.5 = 267.5, budget 80)
        (, uint256 budget) = gate.budgetOf(address(a), address(tok));
        assertEq(budget, (22.5 ether + 35 ether) * 3000 / 10000);                           // option A: native + the cost of lot R only = 17.25
        router.set(1000, 1, address(0));                                                   // rigged route: the lot sells for dust
        uint256 fq = ((rc - rt * 1 / 1e18) * 1e18 + budget - 1) / budget;                  // round 6: the share of the budget, rounded up, reported back in HYPE
        vm.expectRevert(abi.encodeWithSelector(GuardedGate.BudgetExceeded.selector, (fq * budget + 1e18 - 1) / 1e18, budget));
        a.exec(address(gate), 0, _sellData(tok, rt, 1));
    }
    function test_M2_floorFor_uses_the_same_base_and_the_edge_is_exact() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 10 ether);
        _buyT(a, tok, 5 ether);                                                             // native 5, lot cost 5, budget 3
        (uint256 tk, ) = gate.lotOf(address(a), address(tok));
        uint256 f = gate.floorFor(address(a), address(tok), tk); assertEq(f, 2 ether);
        router.set(1000, 4e14 - 1, address(0));                                             // pays 1.999..: refused
        vm.expectRevert(); a.exec(address(gate), 0, _sellData(tok, tk, 1));
        router.set(1000, 4e14, address(0)); a.exec(address(gate), 0, _sellData(tok, tk, 1));   // pays exactly the floor: accepted
        assertEq(gate.floorFor(address(a), address(tok), 0), 0);
    }
    // L-5: stale cost of an emptied lot (not yet reconciled) is not in the base any more.
    function test_L5_cost_of_other_lots_gives_no_room() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok);
        MockToken h = new MockToken(); _approveGate(a, h); vm.deal(address(a), 40 ether);
        _buyT(a, h, 17.5 ether); _hours(2); _buyT(a, h, 17.5 ether); _hours(2);            // big lot H, cost 35, native 5
        _buyT(a, tok, 3 ether);                                                             // small lot T2, cost 3
        h.burn(address(a), h.balanceOf(address(a)));                                        // the owner moved H out; nobody reconciled yet
        router.set(1000, 1, address(0));
        (, uint256 budget) = gate.budgetOf(address(a), address(tok)); assertEq(budget, (2 ether + 3 ether) * 3000 / 10000);
        vm.expectRevert(); a.exec(address(gate), 0, _sellData(tok, 3000 ether, 1));       // the stale 35 gives no room
    }

    // ---------- L-1: pause ----------
    function test_L1_early_lift_starts_no_cooldown_and_a_new_pause_works_at_once() public {
        vm.prank(guardian); gate.setPaused(true); vm.prank(guardian); gate.setPaused(false);   // false alarm, lifted in the same block
        assertEq(gate.pauseUsed(), 1);                                                      // lifted in the same second: still costs one second
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // round 7 (M-1): not before the booked second is over
        vm.warp(block.timestamp + 1); vm.prank(guardian); gate.setPaused(true); assertTrue(gate.paused());   // the real one is not blocked after it
    }
    function test_L1_pause_that_ran_to_expiry_still_has_the_cooldown() public {
        vm.prank(guardian); gate.setPaused(true); vm.warp(block.timestamp + 7 days); assertFalse(gate.paused());
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
        vm.warp(block.timestamp + 3 days); vm.prank(guardian); gate.setPaused(true); assertTrue(gate.paused());   // round 6: the old days have left the sliding window
        // lifted after it expired counts as expired
        uint256 exp2 = gate.pauseExp();
        vm.warp(block.timestamp + 7.5 days); vm.prank(guardian); gate.setPaused(false);
        assertEq(gate.pauseEnd(), exp2);                                                    // booked at its expiry, not at the late lift
    }
    function test_L1_malicious_guardian_cannot_pause_lift_pause_forever() public {
        uint256 t0 = block.timestamp;
        vm.prank(guardian); gate.setPaused(true);
        vm.warp(t0 + 7 days - 10); vm.prank(guardian); gate.setPaused(false);              // lifted 10 s before the end
        vm.prank(guardian); gate.setPaused(true); assertTrue(gate.paused());                // only 10 s of allowance are left
        vm.warp(t0 + 7 days + 1); assertFalse(gate.paused());
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // ran to expiry: cooldown
        vm.warp(t0 + 10 days); vm.prank(guardian); gate.setPaused(true); assertTrue(gate.paused()); // the days have left the sliding window
    }
    function test_L1_small_pauses_do_not_eat_the_next_episode() public {
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 6; i++) { vm.warp(t0 + i * 1 days); vm.prank(guardian); gate.setPaused(true); vm.warp(t0 + i * 1 days + 20 hours); vm.prank(guardian); gate.setPaused(false); }
        vm.warp(t0 + 14 days);                                                              // round 6: sliding window; every one of those days has left it: full allowance again
        vm.prank(guardian); gate.setPaused(true);
        vm.warp(t0 + 14 days + 6 days); assertTrue(gate.paused());
    }
    function test_L1_replacement_guardian_does_not_inherit_the_cooldown() public {
        vm.prank(guardian); gate.setPaused(true); vm.warp(block.timestamp + 7 days);
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
        address g2 = address(0x6A12E); vm.prank(cold); gate.replaceGuardian(g2);
        vm.prank(g2); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // round 6 (L-2): a replacement does not reset the window
    }
    function test_L1_replacement_keeps_a_running_pause() public {
        vm.prank(guardian); gate.setPaused(true);
        address g2 = address(0x6A12E); vm.prank(cold); gate.replaceGuardian(g2);
        assertTrue(gate.paused()); vm.prank(g2); gate.setPaused(false); assertFalse(gate.paused());
    }

    // ---------- L-4: _trimAll wraps ----------
    function test_L4_trim_wraps_so_a_freed_slot_above_the_cursor_is_found() public {
        MockToken[] memory ts = new MockToken[](32);
        for (uint256 i = 0; i < 32; i++) {
            ts[i] = i < 8 ? MockToken(address(new GasBurnToken())) : new MockToken();
            _approveGate(acct, ts[i]); vm.deal(address(acct), address(acct).balance + 0.01 ether);
            vm.warp(block.timestamp + 11 minutes);
            acct.exec(address(gate), 0.0011 ether, _buyData(ts[i], 0.0011 ether));
        }
        assertEq(gate.lotsOf(address(acct)).length, 32);
        vm.prank(guardian); gate.reconcile(address(acct));                                     // round 6: the walk is reconcile's; it stops on gas inside the slow lots
        uint256 cur = _trimPos(address(acct)); assertGt(cur, 0); assertLt(cur, 20);       // cursor stored below index 20
        ts[20].burn(address(acct), ts[20].balanceOf(address(acct)));                        // the owner empties the lot at index 20 (above the cursor)
        MockToken fresh = new MockToken(); _approveGate(acct, fresh); vm.deal(address(acct), address(acct).balance + 1 ether);
        acct.exec(address(gate), 0.01 ether, _buyData(fresh, 0.01 ether));                 // old code: TooManyLots again and again; now the walk wraps and frees it
        assertEq(gate.lotsOf(address(acct)).length, 32);
    }

    // ---------- L-6 (round 4), replaced in round 5 by the leaky bucket (M-1 of job 1209); see Round5.t.sol ----------
    function _share(address a) internal view returns (uint256) { (uint256 lost, uint256 b) = gate.budgetOf(a, address(tok)); return lost * 1e18 / b; }   // round 6: the record as a share of the budget
    function test_L6_one_wei_loss_does_not_restart_the_refill() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 1 ether);
        router.setFixedOut(6); _buyT(a, tok, 1 ether); router.setFixedOut(0);               // lot 6 raw units, cost 1 HYPE, native 0
        router.set(1000, 1e35, address(0));                                                 // 1 raw unit pays 0.1 HYPE
        uint256 t0 = block.timestamp; a.exec(address(gate), 0, _sellData(tok, 4, 1));       // 4 units: cost 0.6667, out 0.4 -> loss 0.2667 of a budget of 0.3
        uint256 f0 = _share(address(a)); assertApproxEqAbs(f0, 888888888888888889, 200);
        vm.warp(t0 + 3.5 days);
        uint256 half = _share(address(a)); assertApproxEqAbs(half, f0 - 0.5e18, 200);      // drains at one budget per 7 days
        (uint256 tk, uint256 ci) = gate.lotOf(address(a), address(tok)); assertEq(tk, 2);
        router.set(1000, (ci / tk - 1) * 1e18, address(0));                                 // pays exactly cost - 1 wei for 1 unit
        a.exec(address(gate), 0, _sellData(tok, 1, 1));                                     // books 1 wei
        uint256 after1 = _share(address(a)); assertApproxEqAbs(after1, half, 1e4);
        vm.warp(block.timestamp + 1 days);                                                  // the clock was NOT restarted: it keeps draining
        uint256 after2 = _share(address(a)); assertApproxEqAbs(after2, after1 - uint256(1e18) / 7, 1e4);
    }
    function test_L6_new_loss_adds_to_the_drained_value() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 100 ether);
        router.setFixedOut(1000 ether); _buyT(a, tok, 10 ether); router.setFixedOut(0);
        router.set(1000, 5e15, address(0));                                                 // pays half
        (, uint256 b1) = gate.budgetOf(address(a), address(tok));
        a.exec(address(gate), 0, _sellData(tok, 200 ether, 1));                             // loss 1 (cost 2, out 1)
        (, uint256 b2) = gate.budgetOf(address(a), address(tok));
        a.exec(address(gate), 0, _sellData(tok, 200 ether, 1));                             // loss 1 more, same block: no drain between
        (uint256 fill, uint64 at) = gate.loss(address(a));
        assertEq(fill, (1e18 * 1e18 + b1 - 1) / b1 + (1e18 * 1e18 + b2 - 1) / b2); assertEq(at, block.timestamp);
    }

    // ---------- L-7: bounded router revert data ----------
    function test_L7_router_revert_data_is_copied_up_to_256_bytes() public {
        router.setRevertLen(200_000);
        (bool ok, bytes memory r) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), 1 ether, _buyData(tok, 1 ether))));
        assertFalse(ok); assertEq(bytes4(r), GuardedGate.RouterFailed.selector);
        bytes memory inner = abi.decode(_tail(r), (bytes)); assertEq(inner.length, 256);
        router.setRevertLen(10);
        (ok, r) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), 1 ether, _buyData(tok, 1 ether))));
        inner = abi.decode(_tail(r), (bytes)); assertEq(inner.length, 10);
        router.setRevertLen(0); _buy(1 ether);                                              // and a normal buy still works
    }
    function _tail(bytes memory r) internal pure returns (bytes memory t) { t = new bytes(r.length - 4); for (uint256 i = 0; i < t.length; i++) t[i] = r[i + 4]; }

    // ---------- L-9: deadline ----------
    function test_L9_deadline_buy_sell_exitSell_revert_Expired_exit_keeps_its_interface() public {
        uint256 dl = block.timestamp + 120;
        acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.buy, (address(tok), 1, route(K_ETH, address(tok), 1 ether), dl)));     // inside the window
        vm.warp(dl);                                                                         // block.timestamp == deadline still passes
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(tok), 100 ether, 1, route(address(tok), K_ETH, 100 ether), dl)));
        vm.warp(dl + 1);
        vm.expectRevert(GuardedGate.Expired.selector);
        acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.buy, (address(tok), 1, route(K_ETH, address(tok), 1 ether), dl)));
        vm.expectRevert(GuardedGate.Expired.selector);
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(tok), 100 ether, 1, route(address(tok), K_ETH, 100 ether), dl)));
        vm.prank(owner1, owner1); vm.expectRevert(GuardedGate.Expired.selector);
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.exitSell, (address(tok), 100 ether, 1, route(address(tok), K_ETH, 100 ether), dl)));
        _ownerSell(acct, owner1, tok, 100 ether, dl + 600);                                  // a fresh deadline works, paused or not
        vm.prank(cold, cold); acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.exit, (address(tok), 100 ether, 1, route(address(tok), K_ETH, 100 ether))));   // exit(): no deadline argument
    }
}
