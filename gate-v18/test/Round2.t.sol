// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";
import "./Adversarial.t.sol";

/// Round 2: fixes for external audit job 1205 (H-1, L-1, L-2, L-3, L-4); each test reproduces the auditor's scenario and asserts the safe outcome.
contract Round2Test is GateBase {
    function _fee(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.payFee, ())); }
    function _gas(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.refundGas, ())); }
    function _sellRaw(MockAccount a, MockToken t, uint256 amt) internal returns (bytes memory) { return a.exec(address(gate), 0, _sellData(t, amt, 1)); }

    // H-1: the auditor's test_poison. The attacker poisons the reference with its OWN account; the victim is not affected.
    function test_poison_attacker_account_does_not_touch_victim_reference() public {
        router.setFixedOut(12_700);                                       // attacker's pool hands over 12 700 raw units for 0.001 ETH
        _buyT(acct2, tok, 0.001 ether);                                   // acct2 = the attacker's own account
        router.setFixedOut(0);
        (uint256 pa, ) = gate.ref(address(acct2), address(tok)); assertGt(pa, 0);       // it poisoned only itself
        (uint256 pv, ) = gate.ref(address(acct), address(tok)); assertEq(pv, 0);
        (uint256 pt, ) = gate.ref(thief, address(tok)); assertEq(pt, 0);
        _buy(1 ether);                                                    // victim: fair price 1 ETH -> 1000 tokens
        uint256 out = _sell(1000 ether); assertEq(out, 1 ether);          // sells fine at t+0 ...
        _buy(1 ether); vm.warp(block.timestamp + 1.9 days);
        out = _sell(1000 ether); assertEq(out, 1 ether);                  // ... and at t+1.9 days
        (uint256 lost, ) = gate.budgetOf(address(acct)); assertEq(lost, 0);
    }
    // H-1: even the attacker's own first note is capped at 1.5x its own lot's cost price (here: equal to its own price), and a third party
    // calling buy() only writes its own key.
    function test_third_party_buy_writes_only_its_own_key() public {
        vm.deal(thief, 10 ether); router.setFixedOut(1);
        vm.prank(thief); try gate.buy{value: 0.01 ether}(address(tok), 1, route(K_ETH, address(tok), 0.01 ether)) {} catch {}
        (uint256 pv, ) = gate.ref(address(acct), address(tok)); assertEq(pv, 0);
    }
    // H-1: the step cap applies to the faded value; a note with no live reference may not exceed 1.5x the lot's cost-basis price.
    function test_faded_step_rule() public {
        _buy(1 ether); (uint256 p0, ) = gate.ref(address(acct), address(tok)); assertEq(p0, 1e27);
        vm.warp(block.timestamp + 1.5 days);                              // ref faded to 25%
        uint256 live = uint256(1e27) * (2 days - 1.5 days) / 2 days;
        router.set(100, 1e16, address(0)); _buy(1 ether);                 // 10x price buy
        (uint256 p1, ) = gate.ref(address(acct), address(tok)); assertEq(p1, live * 15000 / 10000);   // 3.75e26, NOT 2.25e27 (1.5x the stored value)
        vm.warp(block.timestamp + 3 days);                                // reference expired
        (uint256 tk, uint256 cost) = gate.lotOf(address(acct), address(tok));
        uint256 avg = cost * 1e30 / tk;
        router.set(10, 1e17, address(0)); _buy(1 ether);                  // 100x price buy against an expired reference
        (uint256 p2, ) = gate.ref(address(acct), address(tok));
        (tk, cost) = gate.lotOf(address(acct), address(tok));
        assertLe(p2, (cost * 1e30 / tk) * 15000 / 10000); assertGt(p2, 0);    // bounded by 1.5x the lot's cost-basis price (now incl. this buy)
        assertLt(p2, 10 * avg);                                           // far below the 100x price that was paid
    }

    // L-2: tokens with high value per raw unit (6 and 8 decimals) get a reference; with the old 2^96 limit they got none.
    function _hiPrice(uint256 rawPerEth) internal {
        MockToken t = new MockToken(); _approveGate(acct, t);
        assertGe(uint256(1 ether) * 1e18 / rawPerEth, 1 << 96);          // the old rule would have dropped this price
        router.setFixedOut(rawPerEth); acct.exec(address(gate), 1 ether, _buyData(t, 1 ether));
        (uint256 p, ) = gate.ref(address(acct), address(t)); assertEq(p, 1 ether * 1e30 / rawPerEth);
        vm.warp(block.timestamp + 11 minutes); router.setFixedOut(rawPerEth / 7); acct.exec(address(gate), 0.2 ether, _buyData(t, 0.2 ether)); router.setFixedOut(0);   // a pricier buy lifts it, stepwise
        (uint256 p2, ) = gate.ref(address(acct), address(t)); assertGt(p2, p);
        // and the 70% floor works: a sale at 25% of the reference books the reference shortfall on top of the cost shortfall
        (uint256 tk, ) = gate.lotOf(address(acct), address(t));
        router.set(1000, 0.25 ether * 1e18 / tk, address(0));             // pays 0.25 ETH for the whole lot
        acct.exec(address(gate), 0, _sellData(t, tk, 1));
        (uint256 lost, ) = gate.budgetOf(address(acct)); assertGt(lost, 0.7 ether * p2 * tk / 1e30 / 1 ether - 0.25 ether - 1);
    }
    function test_L2_eight_decimal_high_value_token_gets_a_reference() public { _hiPrice(1e6); }     // 1 ETH buys 0.01 token of 8 decimals
    function test_L2_six_decimal_high_value_token_gets_a_reference() public { _hiPrice(3e5); }       // 1 ETH buys 0.3 token of 6 decimals

    // L-1: the auditor's test_window2x. Spend at the end of two adjacent slots is counted in full.
    function test_window2x_buys_now_refused() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours + 3599);
        _buy(17.5 ether);
        vm.warp(block.timestamp + 3599);                                  // inside one hour of the first buy, next slot's last second
        vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.4 ether, _buyData(tok, 17.4 ether));
        vm.warp(block.timestamp + 1 hours); _buy(17.4 ether);             // a full span later it is allowed
    }
    function test_window2x_fees_now_refused() public {
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 30 days - 1);
        _fee(acct, 20 ether);
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 16 ether);
    }
    function test_window2x_gas_now_refused() public {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1 days - 1);
        for (uint256 i = 0; i < 5; i++) _gas(acct, GAS_CALL);             // 0.1 = GAS_DAY at the end of a day slot
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(GuardedGate.GasLimit.selector); _gas(acct, GAS_CALL);
    }

    // L-3: the sold token's lot is reconciled even when the gas-bounded walk never reaches it.
    function test_L3_sold_token_lot_reconciled_despite_stuffed_registry() public {
        _buy(2 ether);                                                    // index 0 of the registry
        for (uint256 i = 0; i < 31; i++) { GasBurnToken j = new GasBurnToken(); _buyT(acct, MockToken(address(j)), 0.001 ether); }
        tok.burn(address(acct), 1000 ether);                              // the owner moved half the tokens out
        _sellRaw(acct, tok, 500 ether);
        (uint256 tk, uint256 cost) = gate.basis(address(acct), address(tok));
        assertEq(tk, 500 ether); assertEq(cost, 0.5 ether);               // trimmed to 1000 / 1.0 first, then 500 / 0.5 released (stale lot: 1500 / 1.5)
    }

    // L-4: time stepping backward across a bucket no longer resets the windows.
    function test_L4_backward_time_buys_do_not_reset() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours + 10);
        uint256 t0 = block.timestamp;
        _buy(17.4 ether); vm.warp(t0 + 40 minutes); _buy(0.1 ether);        // stored head moves ahead (round 3: ring slots of 10 min)
        vm.warp(t0);                                                      // clock steps back into the earlier slot
        vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.4 ether, _buyData(tok, 17.4 ether));
    }
    function test_L4_backward_time_fees_do_not_reset() public {
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 5);
        uint256 t0 = block.timestamp;
        _fee(acct, 18 ether); vm.warp(t0 + 30 days); _fee(acct, 0.5 ether);
        vm.warp(t0);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 4 ether);
    }
}
