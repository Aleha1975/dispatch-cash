// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// payFee (20% of balance, per call and per 30 days), refundGas caps, and the stolen-key bounds on native money.
contract FeeTest is GateBase {
    function _fee(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.payFee, ())); }
    function _wd(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.withdraw, ())); }

    function test_fee_within_20pct_pays_feeTo_only() public {
        _fee(acct, 20 ether); assertEq(feeTo.balance, 20 ether); assertEq(address(gate).balance, 0); assertEq(address(acct).balance, 80 ether);
    }
    function test_fee_over_20pct_of_balance_refused() public {
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 20 ether + 1);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 100 ether);
        vm.expectRevert(GuardedGate.ZeroAmount.selector); _fee(acct, 0);
        assertEq(feeTo.balance, 0);
    }
    function test_repeated_20pct_calls_cannot_compound() public {
        _fee(acct, 20 ether);                                                    // 100 -> 80
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 16 ether);    // 20% of 80, but 36 > 20% of the 100 base
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 1);
        _fee(acct2, 20 ether);                                                   // another account has its own window
        vm.warp(block.timestamp + 60 days); _fee(acct, 16 ether);               // new window: 20% of 80
        assertEq(feeTo.balance, 56 ether);
    }
    function test_thief_loop_is_bounded_by_20pct_of_base_per_window() public {
        uint256 paid;
        for (uint256 i = 0; i < 60; i++) { uint256 room = gate.feeRoom(address(acct)); if (room == 0) break; _fee(acct, room); paid += room; }
        assertLe(paid, 20 ether); assertGt(paid, 19.9 ether);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 0.5 ether);
    }
    function test_honest_sequence_with_profits_and_withdrawals_clamps_to_feeRoom() public {
        // withdraw() to the owner no longer widens the aggregate (item 6): the engine charges min(owed, feeRoom) and the rest later
        _fee(acct, 6 ether); _wd(acct, 90 ether);                                // balance 4
        vm.deal(address(acct), 44 ether);                                        // second profit 40 realised (proceeds arrive); owed 6
        assertEq(gate.feeRoom(address(acct)), 4 ether);                          // aggregate: 20% of (44 + 6) - 6
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 6 ether);
        _fee(acct, 4 ether);
        assertEq(feeTo.balance, 10 ether);
    }
    function test_withdraw_to_owner_does_not_widen_but_selfowned_cannot_inflate() public {
        address self = address(0x7702); vm.etch(self, abi.encodePacked(hex"ef0100", address(0xDEAD))); vm.deal(self, 100 ether);
        vm.startPrank(self);
        for (uint256 i = 0; i < 20; i++) gate.withdraw{value: 100 ether}();     // value returns to the account: base must not grow
        gate.payFee{value: 20 ether}();
        vm.expectRevert(GuardedGate.FeeLimit.selector); gate.payFee{value: 1 ether}();
        vm.stopPrank();
        (, , uint256 wdn, ) = gate.windows(self); assertEq(wdn, 0);
    }
    // round 7 (L-2, L-3): no withdrawal widens the fee base; withdrawTo needs the owner's own transaction where owner() resolves (L-10)
    function test_withdrawTo_widens_nothing_and_needs_owner_origin() public {
        _fee(acct, 20 ether);                                                    // 100 -> 80, aggregate used up
        vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 40 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE))));   // origin is the test, not owner1
        vm.prank(owner1, owner1); acct.exec(address(gate), 40 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE))));   // the owner himself, to somebody else
        vm.deal(address(acct), 80 ether);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 1 ether);     // nothing was credited to the fee base
        assertEq(gate.feeRoom(address(acct)), 0);
    }
    function test_L2_payFee_after_a_large_withdrawTo_cannot_take_the_remainder() public {
        vm.prank(owner1, owner1); acct.exec(address(gate), 90 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0xCAFE))));   // 100 -> 10
        uint256 paid;
        for (uint256 i = 0; i < 30; i++) { uint256 room = gate.feeRoom(address(acct)); if (room == 0) break; _fee(acct, room); paid += room; }
        assertLe(paid, 2 ether);                                                 // 20% of the 10 left (it was 9.885 of 10 with the old credit)
    }
    function test_sliding_window_has_no_edge_burst_for_fees() public {
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 1);                  // just after a bucket boundary
        _fee(acct, 20 ether);
        vm.warp(block.timestamp + 30 days);                                      // one span later: the old bucket still weighs ~ (1 - elapsed/span)
        vm.deal(address(acct), 80 ether);
        uint256 room = gate.feeRoom(address(acct)); assertLt(room, 1 ether);     // nearly nothing yet, not a fresh 16
        vm.warp(block.timestamp + 30 days); vm.deal(address(acct), 80 ether); assertEq(gate.feeRoom(address(acct)), 16 ether);
    }
    function test_gas_refund_also_capped_at_5pct_of_balance() public {
        vm.deal(address(acct), 0.2 ether);                                       // 5% = 0.01
        acct.exec(address(gate), 0.01 ether, abi.encodeCall(GuardedGate.refundGas, ()));
        vm.expectRevert(GuardedGate.GasLimit.selector); acct.exec(address(gate), 0.005 ether, abi.encodeCall(GuardedGate.refundGas, ()));
    }
    function test_pause_blocks_fee_and_gas() public {
        vm.prank(guardian); gate.setPaused(true);
        vm.expectRevert(GuardedGate.IsPaused.selector); _fee(acct, 1 ether);
    }
    function test_gas_refund_bounded_per_call_and_day() public {
        acct.exec(address(gate), 0.02 ether, abi.encodeCall(GuardedGate.refundGas, ()));
        vm.expectRevert(GuardedGate.GasLimit.selector); acct.exec(address(gate), 0.02 ether + 1, abi.encodeCall(GuardedGate.refundGas, ()));
        for (uint256 i = 0; i < 4; i++) acct.exec(address(gate), 0.02 ether, abi.encodeCall(GuardedGate.refundGas, ()));
        vm.expectRevert(GuardedGate.GasLimit.selector); acct.exec(address(gate), 1, abi.encodeCall(GuardedGate.refundGas, ()));
        assertEq(feeTo.balance, 0.1 ether);
        vm.warp(block.timestamp + 2 days); acct.exec(address(gate), 0.02 ether, abi.encodeCall(GuardedGate.refundGas, ()));
        vm.expectRevert(GuardedGate.ZeroAmount.selector); acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.refundGas, ()));
    }
    function test_feeRoom_view_matches_what_payFee_accepts() public {
        uint256 room = gate.feeRoom(address(acct)); assertEq(room, 20 ether);
        _fee(acct, room); assertEq(gate.feeRoom(address(acct)), 0);
        vm.warp(block.timestamp + 60 days); assertEq(gate.feeRoom(address(acct)), 16 ether);
    }

    /// Property: whatever mix of fee attempts, deposits and withdrawals to the owner happens inside one 30-day window,
    /// the fees paid never exceed 20% of (opening balance + deposits).
    function testFuzz_fees_never_exceed_20pct_of_opening_plus_deposits(uint8[16] memory kind, uint96[16] memory amt) public {
        MockAccount a = new MockAccount(owner1); uint256 opening = 100 ether; vm.deal(address(a), opening); uint256 deposits; uint256 paid;
        for (uint256 i = 0; i < 16; i++) {
            uint256 bal = address(a).balance; uint256 k = kind[i] % 3;
            if (k == 0) { uint256 v = bound(amt[i], 1, bal == 0 ? 1 : bal); try this.feeExt(a, v) { paid += v; } catch {} }
            else if (k == 1) { uint256 v = bound(amt[i], 1, 50 ether); vm.deal(address(a), bal + v); deposits += v; }
            else if (bal > 0) { uint256 v = bound(amt[i], 1, bal); _wd(a, v); }
            assertLe(paid * 10000, (opening + deposits) * 2000);
        }
    }
    function feeExt(MockAccount a, uint256 v) external { _fee(a, v); }
}
