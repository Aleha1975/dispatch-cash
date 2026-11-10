// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// A token whose balanceOf burns (almost) the whole 100,000 gas it is given, then answers 0 once `emptied`.
contract BurnToken is MockToken {
    bool public burning; bool public emptied;
    function set(bool b, bool e) external { burning = b; emptied = e; }
    function balanceOf(address a) public view override returns (uint256) {
        if (burning) { while (gasleft() > 9000) {} }
        return emptied ? 0 : _bal[a];
    }
}

/// Round 8: fixes for external audit job 1213 (L-1 gas reserve, L-2 pauseUsed view, L-3 _trimNext cursor, L-4 reconcile no-op, L-6 withdrawTo for an owner nobody controls).
contract Round8Test is GateBase {
    function _pause(bool p) internal { vm.prank(guardian); gate.setPaused(p); }

    // ---------- L-6: the controller of an account whose resolved owner is dead still has a way out ----------
    function test_L6_exit_key_relays_withdrawTo_for_a_resolved_owner_nobody_controls() public {
        acct.setOwner(address(0xDEAD0001));                                    // retired signer / undeployed Safe: no code, resolves, can never be tx.origin
        address mine = address(0xBEEF);
        vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 5 ether, abi.encodeCall(GuardedGate.withdrawTo, (mine)));   // a random / executor origin: still refused
        vm.prank(address(0x6A12D), address(0x6A12D)); vm.expectRevert(GuardedGate.NotOwnerOrigin.selector);
        acct.exec(address(gate), 5 ether, abi.encodeCall(GuardedGate.withdrawTo, (mine)));                      // the guardian is not a proof either
        vm.prank(cold, cold); acct.exec(address(gate), 100 ether, abi.encodeCall(GuardedGate.withdrawTo, (mine)));   // the cold key, through a delegation the controller signed
        assertEq(mine.balance, 100 ether); assertEq(address(acct).balance, 0);
    }
    function test_L6_withdrawTo_cold_key_works_while_paused() public {
        acct.setOwner(address(0xDEAD0001)); _pause(true);
        vm.prank(cold, cold); acct.exec(address(gate), 7 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xBEEF)))); assertEq(address(0xBEEF).balance, 7 ether);
    }
    function test_L6_owner_origin_still_works_and_executor_origin_still_refused() public {
        vm.prank(owner1, owner1); acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE)))); assertEq(address(0xCAFE).balance, 1 ether);
        vm.prank(thief, thief); vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (thief)));
    }

    // ---------- L-2: an expired, never-booked pause leaves the view when it leaves the window ----------
    function test_L2_pauseUsed_of_an_old_unbooked_pause_slides_out() public {
        _pause(true);
        vm.warp(block.timestamp + 9 days); assertLt(gate.pauseUsed(), 7 days);      // old code: 7 days (6 days and a bit are left in the 8-day window)
        vm.warp(block.timestamp + 21 days); assertEq(gate.pauseUsed(), 0);          // old code: 7 days for ever
        _pause(true); assertTrue(gate.paused()); assertEq(gate.pauseExp() - block.timestamp, 7 days);   // the write path agreed all along
    }
    function test_L2_view_matches_the_write_path_for_an_expired_pause_at_every_age() public {
        _pause(true);
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 1 days + 7 hours);
            if (gate.paused()) continue;
            uint256 used = gate.pauseUsed();
            uint256 snap = vm.snapshotState();
            try this._tryPause() { assertEq(gate.pauseExp() - block.timestamp, 7 days - used); } catch { assertGe(used, 7 days); }
            vm.revertToState(snap);
        }
    }
    function _tryPause() external { vm.prank(guardian); gate.setPaused(true); }

    // ---------- L-3: the entry a close moves into the cursor slot is visited next ----------
    function test_L3_trimNext_visits_the_entry_moved_into_the_cursor_slot() public {
        MockToken t2 = new MockToken(); MockToken t3 = new MockToken(); MockToken t4 = new MockToken();
        _buy(1 ether); acct.exec(address(gate), 1 ether, _buyData(t2, 1 ether)); acct.exec(address(gate), 1 ether, _buyData(t3, 1 ether)); acct.exec(address(gate), 1 ether, _buyData(t4, 1 ether));
        assertEq(gate.lotsOf(address(acct)).length, 4);                                      // [tok, t2, t3, t4]
        router.set(1000, 1, address(0));
        acct.exec(address(gate), 0, _sellData(tok, 1 ether, 1));                             // sale 1 reads t4 (unchanged)
        t4.burn(address(acct), t4.balanceOf(address(acct))); t3.burn(address(acct), t3.balanceOf(address(acct)));   // the owner empties both afterwards
        acct.exec(address(gate), 0, _sellData(tok, 1 ether, 1));                             // sale 2 reads t3: closed, t4 is moved into its slot
        assertEq(gate.lotsOf(address(acct)).length, 3);
        acct.exec(address(gate), 0, _sellData(tok, 1 ether, 1));                             // sale 3 must read the moved entry (old code: t2)
        assertEq(gate.lotsOf(address(acct)).length, 2);                                      // [tok, t2]
    }

    // ---------- L-1 / L-4: reconcile with any sensible gas limit makes and stores progress; with too little gas it reverts ----------
    function _burnRegistry(uint256 n) internal returns (BurnToken[] memory ts) {
        ts = new BurnToken[](n);
        for (uint256 i = 0; i < n; i++) { ts[i] = new BurnToken(); acct.exec(address(gate), 0.01 ether, _buyData(ts[i], 0.01 ether)); }
        assertEq(gate.lotsOf(address(acct)).length, n);
        for (uint256 i = 0; i < n; i++) { ts[i].set(true, true); }                           // every lot: emptied by the owner, balanceOf burns its gas, then says 0
    }
    function test_L4_reconcile_with_too_little_gas_reverts_instead_of_doing_nothing() public {
        _burnRegistry(3);
        vm.prank(guardian); vm.expectRevert(GuardedGate.GasTooLow.selector); gate.reconcile{gas: 150_000}(address(acct));   // old code: succeeds, closes nothing
    }
    function test_L1_L4_gas_sweep_success_means_progress_failure_means_GasTooLow_and_nothing_above_240k_fails() public {
        BurnToken[] memory ts = _burnRegistry(8);
        uint256 snap = vm.snapshotState();
        uint256 bad;
        for (uint256 g = 200_000; g <= 800_000; g += 1_500) {
            vm.cool(address(gate)); for (uint256 i = 0; i < ts.length; i++) vm.cool(address(ts[i]));
            vm.prank(guardian);
            (bool ok, bytes memory r) = address(gate).call{gas: g}(abi.encodeCall(GuardedGate.reconcile, (address(acct))));
            bool loud = !ok && r.length == 4 && bytes4(r) == GuardedGate.GasTooLow.selector;     // a refusal for lack of gas is fine; running out of gas inside is not
            if (ok ? gate.lotsOf(address(acct)).length == 8 : (!loud || g >= 240_000)) { bad++; emit log_named_uint(ok ? "no-op" : "reverts", g); }                         // reverted (out of gas) or silently did nothing
            vm.revertToState(snap); snap = vm.snapshotState();
        }
        assertEq(bad, 0);                                                                    // old code: dozens of failing limits
    }
    function test_L1_after_a_partial_walk_the_cursor_is_stored_and_the_next_call_continues() public {
        BurnToken[] memory ts = _burnRegistry(8);
        for (uint256 i = 0; i < ts.length; i++) vm.cool(address(ts[i]));
        vm.prank(guardian); gate.reconcile{gas: 300_000}(address(acct));
        uint256 left = gate.lotsOf(address(acct)).length; assertLt(left, 8);
        vm.prank(guardian); gate.reconcile{gas: 300_000}(address(acct));
        assertLt(gate.lotsOf(address(acct)).length, left);
    }
}
