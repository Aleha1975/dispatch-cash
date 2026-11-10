// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";
import "./Adversarial.t.sol";

/// An account whose owner() answers with raw bytes chosen by the test.
contract RawOwnerAccount {
    bytes public ret;
    function setRet(bytes calldata r) external { ret = r; }
    receive() external payable {}
    fallback() external { bytes memory r = ret; assembly { return(add(r, 32), mload(r)) } }
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
    }
}

/// Round 5: fixes for external audit job 1209 (M-1 leaky bucket, L-1 / L-3 / I-1 pause window, L-5 trim cursor, L-6 owner read, L-7 exits without the walk).
contract Round5Test is GateBase {
    function _ownerSell(MockAccount a, address ow, MockToken t, uint256 amt) internal {
        vm.prank(ow, ow); a.exec{gas: 700_000}(address(gate), 0, abi.encodeCall(GuardedGate.exitSell, (address(t), amt, 1, route(address(t), K_ETH, amt), type(uint256).max)));
    }
    function _trimPosSlot(address a) internal pure returns (bytes32) { return keccak256(abi.encode(a, uint256(17))); }
    function _pause(bool p) internal { vm.prank(guardian); gate.setPaused(p); }

    // ---------- M-1: the auditor's re-booking sequence ----------
    // Lot-only account (native 0): the auditor's test sold the free room every hour for 7 days and lost about 48% of the cost (asserted > 45%).
    // With the leaky bucket the sum stays within one initial budget plus one budget per 7 days (here below 60% of the cost).
    function test_M1_auditor_sequence_lot_only_stays_within_budget_plus_one_week() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 10 ether);
        router.setFixedOut(1000 ether); _buyT(a, tok, 10 ether); router.setFixedOut(0);
        router.set(1000, 1, address(0));                                                   // a sale pays about nothing
        (, uint256 cost0) = gate.lotOf(address(a), address(tok));
        uint256 t0 = block.timestamp;
        for (uint256 h = 0; h <= 7 * 24; h++) {
            vm.warp(t0 + h * 1 hours);
            (uint256 tk, uint256 ci) = gate.lotOf(address(a), address(tok));
            (uint256 lost, uint256 budget) = gate.budgetOf(address(a), address(tok));
            if (budget <= lost) continue;
            uint256 amt = (budget - lost) * tk / ci;
            if (amt < 1 ether) continue;
            a.exec(address(gate), 0, _sellData(tok, amt, 1));
        }
        (, uint256 cost1) = gate.lotOf(address(a), address(tok));
        assertLe(cost0 - cost1, cost0 * 60 / 100);
        assertGt(cost0 - cost1, cost0 * 30 / 100);                                          // and the first budget really went
    }
    // Constant-ish base (native topped up, lot refilled every 70 minutes): over 28 days the booked losses stay <= maxBudget * (1 + days / 7).
    function test_M1_sustained_rebooking_is_one_budget_per_7_days() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok);
        router.set(1000, 1, address(0));
        uint256 t0 = block.timestamp; uint256 bought; uint256 maxB; uint256 firstSale; uint256 lastSale;
        for (uint256 h = 0; h < 28 * 24 * 60 / 70; h++) {
            vm.warp(t0 + h * 70 minutes);
            vm.deal(address(a), 22.5 ether);
            router.setFixedOut(17_500 ether); _buyT(a, tok, 17.5 ether); router.setFixedOut(0); bought += 17.5 ether;
            (uint256 tk, uint256 ci) = gate.lotOf(address(a), address(tok));
            (uint256 lost, uint256 budget) = gate.budgetOf(address(a), address(tok));
            if (budget > maxB) maxB = budget;
            if (budget <= lost) continue;
            uint256 amt = (budget - lost) * tk / ci;
            if (amt < 1 ether) continue;
            a.exec(address(gate), 0, _sellData(tok, amt, 1));
            if (firstSale == 0) firstSale = block.timestamp; lastSale = block.timestamp;
        }
        (, uint256 ci1) = gate.lotOf(address(a), address(tok));
        uint256 soldCost = bought - ci1;                                                    // out is ~0, so the cost released is the loss booked
        assertGt(soldCost, maxB);
        assertLe(soldCost, maxB + maxB * (lastSale - firstSale) / 7 days + 1e12);
    }
    function test_M1_floorFor_uses_the_same_decay() public {
        MockAccount a = new MockAccount(owner1); _approveGate(a, tok); vm.deal(address(a), 10 ether);
        router.setFixedOut(1000 ether); _buyT(a, tok, 10 ether); router.setFixedOut(0);
        router.set(1000, 1, address(0));
        (uint256 tk, ) = gate.lotOf(address(a), address(tok));
        a.exec(address(gate), 0, _sellData(tok, tk * 25 / 100, 1));                         // books ~2.5 of a budget of 3 -> then smaller
        vm.warp(block.timestamp + 2 days);
        (uint256 tk2, uint256 ci2) = gate.lotOf(address(a), address(tok));
        (uint256 lost, uint256 budget) = gate.budgetOf(address(a), address(tok));
        uint256 amt = tk2 / 4; uint256 cost = ci2 * amt / tk2;
        uint256 room = budget > lost ? budget - lost : 0;
        assertEq(gate.floorFor(address(a), address(tok), amt), cost > room ? cost - room : 0);
        uint256 f = gate.floorFor(address(a), address(tok), amt);
        router.set(1000, f * 1e18 / amt, address(0)); if (f > 0) { router.set(1000, (f * 1e18 + amt - 1) / amt, address(0)); }
        a.exec(address(gate), 0, _sellData(tok, amt, 1));                                   // a sale at the floor passes
    }

    // ---------- L-7: exits do not walk the registry ----------
    function _junkRegistry() internal returns (MockToken real) {
        real = new MockToken(); _approveGate(acct, real); vm.deal(address(acct), address(acct).balance + 1 ether);
        acct.exec(address(gate), 0.0011 ether, _buyData(real, 0.0011 ether));
        for (uint256 i = 0; i < 31; i++) {
            MockToken j = MockToken(address(new GasBurnToken())); _approveGate(acct, j);
            vm.warp(block.timestamp + 11 minutes);
            acct.exec(address(gate), 0.0011 ether, _buyData(j, 0.0011 ether));
        }
        assertEq(gate.lotsOf(address(acct)).length, 32);
    }
    function test_L7_exitSell_and_exit_succeed_with_32_gas_burning_lots() public {
        MockToken real = _junkRegistry();
        uint256 g = gasleft();
        _ownerSell(acct, owner1, real, 5e17);                                               // limit 700k gas: no registry walk, no GasTooLow
        assertLt(g - gasleft(), 700_000);
        vm.prank(cold, cold); acct.exec{gas: 700_000}(address(gate), 0, abi.encodeCall(GuardedGate.exit, (address(real), 5e17, 1, route(address(real), K_ETH, 5e17))));
        assertEq(gate.lotsOf(address(acct)).length, 32);                                    // nothing was walked: the junk lots stay as they were
    }

    // ---------- L-1 / L-3 / I-1: pause window ----------
    function test_L1_auditor_chain_of_two_full_pauses_is_refused() public {
        uint256 T = block.timestamp;
        _pause(true); _pause(false);                                                        // zero-length "false alarm" at T
        vm.warp(T + 1 days + 1); _pause(true);                                              // the real one: gets 7 d - 1 s
        assertEq(gate.pauseExp(), T + 8 days);
        vm.warp(T + 8 days); assertFalse(gate.paused());
        _pause(false);                                                                      // lifted when the old window turns 8 days
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // no second full pause at once
        vm.warp(T + 10 days); _pause(true); assertTrue(gate.paused());                      // round 6: the old days have left the sliding window; the allowance is what the window allows
        assertLt(gate.pauseExp() - block.timestamp, 7 days);
    }
    function test_L1_any_8_days_hold_at_most_7_days_of_pause() public {
        uint256 T = block.timestamp; uint256 N = 60 * 24; bool[] memory on = new bool[](N);
        for (uint256 i = 0; i < N; i++) {                                                   // a guardian that pauses the moment it can
            vm.warp(T + i * 1 hours);
            if (!gate.paused()) { vm.prank(guardian); try gate.setPaused(true) {} catch {} }
            on[i] = gate.paused();
        }
        uint256 sum; uint256 maxSum; uint256 total;
        for (uint256 i = 0; i < N; i++) {
            if (on[i]) { sum++; total++; }
            if (i >= 192 && on[i - 192]) sum--;                                             // window of 192 hourly samples = 8 days
            if (sum > maxSum) maxSum = sum;
        }
        assertLe(maxSum, 7 * 24 + 1);                                                       // at most 7 days (+ one sample of rounding) in any 8 days
        assertGt(total, N * 6 / 8);                                                         // and the guardian really did use its allowance
    }
    function test_L3_replaceGuardian_does_not_move_a_running_pauses_expiry() public {
        uint256 T = block.timestamp;
        _pause(true); vm.warp(T + 6 days); _pause(false); _pause(true);                     // 6 d used, the second pause has 1 d
        assertEq(gate.pauseExp(), T + 7 days);
        vm.warp(T + 6.5 days); address g2 = address(0x6A12E); vm.prank(cold); gate.replaceGuardian(g2);
        assertEq(gate.pauseExp(), T + 7 days); assertTrue(gate.paused());
        vm.warp(T + 7 days); assertFalse(gate.paused());
        vm.prank(g2); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);   // round 6 (L-2): the replacement is no reset; 7 d are used in the window
        vm.warp(T + 10 days); vm.prank(g2); gate.setPaused(true); assertTrue(gate.paused());       // old days leave the window
    }
    function test_I1_a_pause_lifted_in_the_same_second_uses_one_second() public {
        for (uint256 i = 0; i < 5; i++) { _pause(true); _pause(false); }
        assertEq(gate.pauseUsed(), 5);
    }

    // ---------- L-5: a resumed round cannot skip a lot and store "finished" ----------
    function test_L5_resumed_round_visits_the_entry_a_close_moved_into_the_cursor_slot() public {
        MockToken t2 = new MockToken(); _approveGate(acct, t2);
        _buy(1 ether); acct.exec(address(gate), 1 ether, _buyData(t2, 1 ether));            // registry [tok, t2]
        vm.store(address(gate), _trimPosSlot(address(acct)), bytes32(uint256(1)));          // cursor 1: only index 0 is left in this round
        tok.burn(address(acct), tok.balanceOf(address(acct))); t2.burn(address(acct), t2.balanceOf(address(acct)));   // the owner emptied both
        vm.prank(guardian); gate.reconcile(address(acct));
        assertEq(gate.lotsOf(address(acct)).length, 0); assertEq(gate.costOf(address(acct)), 0);
        assertEq(uint256(vm.load(address(gate), _trimPosSlot(address(acct)))), 0);
    }

    // ---------- L-6: owner() must be exactly one word and not a precompile address ----------
    function test_L6_owner_read_needs_32_bytes_and_a_real_address() public {
        RawOwnerAccount r = new RawOwnerAccount(); vm.deal(address(r), 10 ether);
        r.setRet(abi.encode(uint256(1)));                                                   // a permissive fallback answering "true"
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); gate.ownerOf(address(r));
        r.setRet(abi.encode(uint256(0xffff)));
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); gate.ownerOf(address(r));
        r.setRet(abi.encode(uint256(0x20), uint256(1)));                                    // an ABI-encoded dynamic value
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); gate.ownerOf(address(r));
        r.setRet(abi.encode(owner1, uint256(0)));                                           // 64 bytes: refused
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); gate.ownerOf(address(r));
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); r.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ()));
        r.setRet(abi.encode(owner1));                                                       // exactly one word, a real address
        assertEq(gate.ownerOf(address(r)), owner1);
        r.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ())); assertEq(owner1.balance, 1 ether);
    }
}
