// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// Round 3: fixes for external audit job 1206 (M-1 reference ratchet, L-1 window lock-out, L-2 stale reference, L-3 floorFor).
contract Round3Test is GateBase {
    function _fee(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.payFee, ())); }
    function _gas(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.refundGas, ())); }
    function _ref(MockAccount a) internal view returns (uint256 p) { (p, ) = gate.ref(address(a), address(tok)); }
    function _costPrice(MockAccount a) internal view returns (uint256) { (uint256 tk, uint256 c) = gate.lotOf(address(a), address(tok)); return c * 1e30 / tk; }
    function _tryBuy(uint256 eth) internal returns (bool ok) { (ok, ) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), eth, _buyData(tok, eth)))); }

    // ---------- M-1: the auditor's dust ratchet (20 dust buys in one tx) and the phantom-loss variant ----------
    function test_M1_dust_ratchet_is_ignored_and_a_fair_sale_books_no_phantom_loss() public {
        _buy(1 ether); uint256 p0 = _ref(acct); assertEq(p0, 1e27);
        vm.warp(block.timestamp + 11 minutes);                            // past REF_GAP: the first rigged note would be allowed ...
        router.setFixedOut(1);                                            // ... but the route delivers one raw unit per buy
        for (uint256 i = 0; i < 20; i++) _buy(0.001 ether);               // 20 dust buys in the same instant (auditor: 1.5^20 = 3,300x)
        router.setFixedOut(0);
        assertEq(_ref(acct), p0);                                         // 0.001 < 5% of the 1 ETH lot: not one note counted
        uint256 out = _sell(1000 ether); assertEq(out, 1 ether);          // the honest, fair sale is not refused ...
        (uint256 lost, ) = gate.budgetOf(address(acct));
        assertLe(lost, 0.02 ether);                                       // ... and books at most the self-inflicted dust cost, not a phantom reference loss
    }
    function test_M1_twenty_qualifying_rigged_buys_in_one_instant_raise_the_reference_once_and_stay_under_3x_cost() public {
        _buy(1 ether); uint256 p0 = _ref(acct);
        vm.warp(block.timestamp + 11 minutes);
        router.setFixedOut(1e18);                                         // 0.05 ETH for 1e18 raw units: a price 50x the market
        for (uint256 i = 0; i < 20; i++) _buy(0.06 ether);               // each >= 5% of the lot
        router.setFixedOut(0);
        uint256 r = _ref(acct);
        uint256 live0 = p0 * (2 days - 11 minutes) / 2 days;
        assertLe(r, live0 * 15000 / 10000);                               // ONE 1.5x step (old code: 1.5^20), the other 19 notes fall inside REF_GAP
        assertLe(r, 3 * _costPrice(acct));                                // and never above 3x the lot's cost-basis price
        // one more qualifying note only after the gap: still one step
        vm.warp(block.timestamp + 11 minutes); router.setFixedOut(1e18); _buy(0.1 ether); router.setFixedOut(0);
        assertLe(_ref(acct), 3 * _costPrice(acct));
        assertLe(_ref(acct), r * 15000 / 10000 + 1);
    }
    function test_M1_reference_never_exceeds_3x_cost_price_even_after_many_gaps() public {
        _buy(1 ether);
        for (uint256 i = 0; i < 12; i++) { vm.warp(block.timestamp + 11 minutes); router.setFixedOut(1e18); _buy(0.1 ether); router.setFixedOut(0); assertLe(_ref(acct), 3 * _costPrice(acct)); }
    }
    function test_M1_phantom_variant_is_bounded() public {
        // stolen key ramps the reference in steps of 10 minutes; the sale at the honest price books at most (0.7 * 3 - 1) of the lot's cost
        _buy(1 ether);
        for (uint256 i = 0; i < 6; i++) { vm.warp(block.timestamp + 11 minutes); router.setFixedOut(5e17); _buy(0.1 ether); router.setFixedOut(0); }
        (uint256 tk, uint256 cost) = gate.lotOf(address(acct), address(tok));
        router.set(1000, cost * 1e18 / tk, address(0));                   // the market pays exactly the lot's cost price
        _sell(tk);
        (uint256 lost, ) = gate.budgetOf(address(acct));
        assertLe(lost, cost * 11 / 10 + 1);                               // <= 1.1x cost: the reference is capped at 3x cost, not 3,300x
    }

    // ---------- L-1: ring windows ----------
    function test_L1_full_spend_then_buy_after_about_70_minutes_not_at_59() public {
        vm.warp((block.timestamp / 600 + 1) * 600);                       // start of a 10-minute slot (worst case: the spend stays counted for span + 1 slot)
        uint256 t0 = block.timestamp; _buy(17.5 ether);
        vm.warp(t0 + 59 minutes); assertFalse(_tryBuy(1 ether));
        vm.warp(t0 + 69 minutes); assertFalse(_tryBuy(1 ether));
        vm.warp(t0 + 70 minutes); assertTrue(_tryBuy(1 ether));
    }
    function test_L1_spend_at_the_end_of_a_slot_frees_after_an_hour_never_before() public {
        vm.warp((block.timestamp / 600 + 1) * 600 + 599);
        uint256 t0 = block.timestamp; _buy(17.5 ether);
        vm.warp(t0 + 59 minutes); assertFalse(_tryBuy(1 ether));
        vm.warp(t0 + 60 minutes + 1); assertTrue(_tryBuy(1 ether));
    }
    function test_L1_sustained_rate_with_bursts_over_five_hours() public {
        vm.deal(address(acct), 1000 ether);
        uint256 t0 = block.timestamp; uint256 total; uint256 bursts;
        for (uint256 t = 0; t <= 5 hours; t += 1 minutes) {
            vm.warp(t0 + t);
            if (_tryBuy(17.5 ether)) { total += 17.5 ether; bursts++; }
        }
        assertGe(bursts, 5); assertGe(total, 87.5 ether);                 // one full burst every 70 minutes (the old two-bucket rule: about half)
        // and a steady 2.5 HYPE every 10 minutes is never refused
        vm.warp(t0 + 7 hours);
        for (uint256 i = 0; i < 30; i++) { vm.warp(block.timestamp + 10 minutes); assertTrue(_tryBuy(2.5 ether)); }
    }
    function test_L1_no_hour_ever_carries_more_than_the_cap() public {
        vm.deal(address(acct), 1000 ether);
        uint256 t0 = block.timestamp; uint256[] memory at = new uint256[](400); uint256[] memory amt = new uint256[](400); uint256 n;
        for (uint256 t = 0; t <= 6 hours; t += 3 minutes) {
            vm.warp(t0 + t); uint256 v = 1 ether + (t / 180 % 5) * 2 ether;
            if (_tryBuy(v)) { at[n] = t0 + t; amt[n] = v; n++; }
            uint256 s; for (uint256 j = 0; j < n; j++) if (at[j] + 1 hours > block.timestamp) s += amt[j];
            assertLe(s, 17.5 ether);
        }
        assertGt(n, 20);
    }
    function test_L1_gas_full_spend_refused_inside_a_day_allowed_after_28_hours() public {
        vm.warp((block.timestamp / 4 hours + 1) * 4 hours);
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 5; i++) _gas(acct, GAS_CALL);              // 0.1 = GAS_DAY
        vm.warp(t0 + 23 hours); vm.expectRevert(GuardedGate.GasLimit.selector); _gas(acct, GAS_CALL);
        vm.warp(t0 + 28 hours); _gas(acct, GAS_CALL);
    }
    function test_L1_fee_full_spend_refused_inside_30_days_allowed_after_35() public {
        vm.warp((block.timestamp / 5 days + 1) * 5 days);
        uint256 t0 = block.timestamp; _fee(acct, 20 ether);
        vm.warp(t0 + 29 days); vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 5 ether);
        vm.warp(t0 + 35 days); _fee(acct, 5 ether);
    }
    function test_L1_window2x_still_refused_all_three() public {
        vm.warp((block.timestamp / 600 + 1) * 600 + 599); _buy(17.5 ether);
        vm.warp(block.timestamp + 59 minutes + 59); vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.4 ether, _buyData(tok, 17.4 ether));
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 30 days - 1); _fee(acct2, 20 ether);
        vm.warp(block.timestamp + 30 days - 1); vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct2, 16 ether);
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1 days - 1);
        for (uint256 i = 0; i < 5; i++) _gas(acct2, GAS_CALL);
        vm.warp(block.timestamp + 1 days - 1); vm.expectRevert(GuardedGate.GasLimit.selector); _gas(acct2, GAS_CALL);
    }

    // ---------- L-2: the reference dies with its lot ----------
    function test_L2_auditor_honest_reentry_sequence() public {
        _buy(1 ether);                                                    // buy at P = 1e27
        vm.warp(block.timestamp + 11 minutes);
        router.setFixedOut(uint256(1000 ether) * 2 / 3); _buy(1 ether);             // spike: second buy at 1.5P -> reference 1.5P
        router.setFixedOut(0);
        assertGt(_ref(acct), 1.4e27);
        (uint256 tk, ) = gate.lotOf(address(acct), address(tok));
        router.set(1000, 1.5e15, address(0)); _sell(tk);                    // the lot is closed by a full sale
        assertEq(_ref(acct), 0);                                          // reference deleted with the lot
        vm.warp(block.timestamp + 1 hours);
        router.set(2000, 5e14, address(0)); _buy(1 ether);                 // re-entry at P/2 within 2 days
        uint256 out = _sell(2000 ether); assertEq(out, 1 ether);          // a sale at cost: no phantom loss, no revert
        (uint256 lost, ) = gate.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_L2_forgetLot_and_fresh_lot_delete_the_reference() public {
        _buy(1 ether); assertGt(_ref(acct), 0);
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.forgetLot, (address(tok))));
        assertEq(_ref(acct), 0);
        _buy(1 ether); assertEq(_ref(acct), 1e27);                        // a fresh lot starts from its own price
    }

    // ---------- L-3: floorFor includes the reference ----------
    function test_L3_floorFor_includes_reference_floor_and_matches_the_budget_edge() public {
        MockAccount a = new MockAccount(owner1); vm.deal(address(a), 3 ether); _approveGate(a, tok);
        router.setFixedOut(1000 ether); _buyT(a, tok, 1 ether);
        vm.warp(block.timestamp + 11 minutes); router.setFixedOut(uint256(0.1 ether) * 1e30 / 1.5e27); _buyT(a, tok, 0.1 ether);
        vm.warp(block.timestamp + 11 minutes); router.setFixedOut(uint256(0.1 ether) * 1e30 / 2.2e27); _buyT(a, tok, 0.1 ether);
        router.setFixedOut(0);
        (uint256 tk, uint256 cost) = gate.lotOf(address(a), address(tok));
        (, uint256 budget) = gate.budgetOf(address(a));
        uint256 costFloor = cost > budget ? cost - budget : 0;
        uint256 f = gate.floorFor(address(a), address(tok), tk);
        assertGt(f, costFloor);                                           // the reference binds (before round 3 the view returned costFloor)
        router.set(1000, (f + 1e9) * 1e18 / tk + 1, address(0));          // pays just above the floor: accepted
        a.exec(address(gate), 0, _sellData(tok, tk, 1));
    }
    function test_L3_floorFor_edge_below_is_refused() public {
        MockAccount a = new MockAccount(owner1); vm.deal(address(a), 3 ether); _approveGate(a, tok);
        router.setFixedOut(1000 ether); _buyT(a, tok, 1 ether);
        vm.warp(block.timestamp + 11 minutes); router.setFixedOut(uint256(0.1 ether) * 1e30 / 1.5e27); _buyT(a, tok, 0.1 ether);
        vm.warp(block.timestamp + 11 minutes); router.setFixedOut(uint256(0.1 ether) * 1e30 / 2.2e27); _buyT(a, tok, 0.1 ether);
        router.setFixedOut(0);
        (uint256 tk, ) = gate.lotOf(address(a), address(tok));
        uint256 f = gate.floorFor(address(a), address(tok), tk);
        router.set(1000, (f - 1e12) * 1e18 / tk, address(0));
        vm.expectRevert(); a.exec(address(gate), 0, _sellData(tok, tk, 1));
    }
}
