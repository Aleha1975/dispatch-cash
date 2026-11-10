// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// Round 7: fixes for external audit job 1212 (M-1 pause allowance burn, L-2 / L-3 / L-10 withdrawTo and the fee base, L-4 emptied lots, L-6 pauseUsed, L-9 gas floor in the walk).
contract Round7Test is GateBase {
    function _pause(bool p) internal { vm.prank(guardian); gate.setPaused(p); }

    // ---------- M-1: same-second pause/lift pairs cannot burn the allowance ----------
    function test_M1_same_second_pairs_cannot_book_more_seconds_than_elapse() public {
        uint256 t0 = block.timestamp;
        _pause(true); _pause(false);
        assertEq(gate.pauseUsed(), 1);
        for (uint256 i = 0; i < 50; i++) {                                              // the burn loop: pairs in one timestamp
            vm.prank(guardian);
            try gate.setPaused(true) { vm.prank(guardian); gate.setPaused(false); } catch {}
        }
        assertLe(gate.pauseUsed(), block.timestamp - t0 + 1);                           // old code: 51
        vm.expectRevert(GuardedGate.PauseCooldown.selector); _pause(true);              // still inside the booked second
        vm.warp(block.timestamp + 1); _pause(true); assertTrue(gate.paused());
    }
    function test_M1_booked_seconds_never_exceed_elapsed_seconds_over_a_long_loop() public {
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 200; i++) {
            vm.prank(guardian); try gate.setPaused(true) {} catch {}
            vm.prank(guardian); gate.setPaused(false);
            if (i % 3 == 0) vm.warp(block.timestamp + 1);
            assertLe(gate.pauseUsed(), block.timestamp - t0 + 1);
        }
        vm.warp(block.timestamp + 1 hours); _pause(true); assertTrue(gate.paused());     // the guard still has an allowance
    }

    // ---------- L-6: the view counts the running pause ----------
    function test_L6_pauseUsed_includes_a_running_and_an_expired_unbooked_pause() public {
        _pause(true); vm.warp(block.timestamp + 3 days); assertEq(gate.pauseUsed(), 3 days);
        vm.warp(block.timestamp + 4.5 days); assertEq(gate.pauseUsed(), 7 days);          // expired, never lifted
        _pause(false); assertEq(gate.pauseUsed(), 7 days);                               // the same figure once booked
    }

    // ---------- L-2 / L-3 / L-10 ----------
    function test_L2_L3_withdrawTo_is_not_credited_to_the_fee_base() public {
        vm.prank(owner1, owner1); acct.exec(address(gate), 90 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE))));
        uint256 paid;
        for (uint256 i = 0; i < 30; i++) { uint256 room = gate.feeRoom(address(acct)); if (room == 0) break; acct.exec(address(gate), room, abi.encodeCall(GuardedGate.payFee, ())); paid += room; }
        assertLe(paid, 2 ether);                                                         // old code: 9.885 of the 10 left
    }
    function test_L10_withdrawTo_with_a_resolved_owner_needs_the_owner_origin() public {
        vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE))));   // executor-like origin
        vm.prank(owner1, owner1); acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE)))); assertEq(address(0xCAFE).balance, 1 ether);
    }

    // ---------- L-4: an executor sale reads one more registry entry ----------
    function test_L4_executor_sales_close_a_lot_the_owner_emptied_without_a_reconcile() public {
        MockToken t2 = new MockToken(); _approveGate(acct, t2);
        _buy(1 ether); acct.exec(address(gate), 1 ether, _buyData(t2, 1 ether));         // registry [tok, t2]
        t2.burn(address(acct), t2.balanceOf(address(acct)));       // the owner empties t2; nobody reconciles
        assertEq(gate.lotsOf(address(acct)).length, 2);            // gate.lotsOf is the raw registry
        for (uint256 i = 0; i < 2; i++) { router.set(1000, 1, address(0)); acct.exec(address(gate), 0, _sellData(tok, 1 ether, 1)); }   // two small sales of tok
        assertEq(gate.lotsOf(address(acct)).length, 1);                                  // t2 was closed on the way
    }
}
