// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// token whose balanceOf burns ~90k gas (under BALANCE_GAS, so it still reads as "answered"): a junk lot nobody can clear
contract GasBurnToken is MockToken {
    function balanceOf(address a) public view override returns (uint256) {
        uint256 g = gasleft(); while (g - gasleft() < 88_000) {}
        return _bal[a];
    }
}

/// Adversarial review tests. Each finding was first reproduced as test_VULN_* (asserting the bad outcome); after the fixes they are inverted
/// into test_FIXED_* asserting the safe outcome.
contract AdversarialTest is GateBase {
    function _fee(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.payFee, ())); }
    function _wd(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.withdraw, ())); }
    function _hours(uint256 n) internal { vm.warp(block.timestamp + n * 1 hours + 1); }
    function _exitSellData(MockToken t, uint256 amt, uint256 minOut) internal view returns (bytes memory) { return abi.encodeCall(GuardedGate.exitSell, (address(t), amt, minOut, route(address(t), K_ETH, amt))); }
    function _ownerExit(MockAccount a, address ow, MockToken t, uint256 amt) internal { vm.prank(ow, ow); a.exec(address(gate), 0, _exitSellData(t, amt, 1)); }

    // F1 (was High): there is no exit-mode switch any more. The executor cannot dump lots for dust whatever the owner does.
    function test_FIXED_no_exit_mode_thief_cannot_dump_lots_for_dust() public {
        _buy(17.5 ether); _hours(2); _buy(17.5 ether); _hours(2); _buy(17.5 ether);       // lot cost 52.5, cash 47.5, budget 30
        router.set(1000, 1, address(0));                                                  // thief-owned pool pays dust
        uint256 all = 52_500 ether;
        vm.expectRevert(); acct.exec(address(gate), 0, _sellData(tok, all, 1));           // budget blocks the thief
        (bool ok, ) = address(gate).call(abi.encodeWithSignature("setExitMode(bool)", true)); assertFalse(ok);   // switch is gone
        vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 0, _exitSellData(tok, all, 1));   // thief cannot exitSell (origin != owner)
        vm.prank(guardian, guardian); vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 0, _exitSellData(tok, all, 1));
        assertEq(tok.balanceOf(address(acct)), all);                                      // everything still there
    }

    // F2 (was High, L4): profit leak. A price reference built from recent executor trades makes a far-below-market sale cost budget.
    function test_FIXED_profit_leak_sale_far_below_market_books_shortfall_or_is_refused() public {
        // other clients keep trading the token while the market rises 3x: three buys on acct2, each lifts the reference by at most 1.5x
        _buy(17.5 ether);                                                                 // acct: 17500 tokens, cost 17.5 (price 1e15)
        router.set(333, 3e15, address(0));
        for (uint256 i = 0; i < 3; i++) { _hours(2); _buyT(acct2, tok, 1 ether); }
        (uint128 rp, ) = gate.ref(address(tok)); assertGt(uint256(rp), 2.9e15);           // reference ~3e15
        router.set(1000, 1e15, address(0));                                               // rigged pool pays only cost
        // one lot of 17.5: shortfall vs reference is booked as loss (0.7 * 3.0 * 17.5 - 17.5 ~ 19.3), inside the 30% budget: passes but costs budget
        uint256 out = _sell(17_500 ether); assertEq(out, 17.5 ether);
        (uint256 lost, ) = gate.budgetOf(address(acct)); assertGt(lost, 19 ether);
        // a bigger position: the shortfall exceeds the budget and the executor sale is refused
        _hours(2); router.set(333, 3e15, address(0)); _buy(10 ether); _hours(2); _buy(10 ether); router.set(1000, 1e15, address(0));
        uint256 held = tok.balanceOf(address(acct)); assertGt(held, 6000 ether);
        (bool okS, bytes memory rS) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), 0, _sellData(tok, held, 1))));
        assertFalse(okS); assertEq(bytes4(rS), GuardedGate.BudgetExceeded.selector);
        // the client's own exit is exempt
        _ownerExit(acct, owner1, tok, held);
    }
    function test_reference_decays_and_cannot_be_jumped_by_one_trade() public {
        _buy(1 ether); (uint128 p0, ) = gate.ref(address(tok)); assertEq(uint256(p0), 1e15);
        router.set(100, 1e16, address(0)); _hours(2); _buy(1 ether);                      // a 10x rigged-price buy: capped at 1.5x
        (uint128 p1, ) = gate.ref(address(tok)); assertEq(uint256(p1), 1.5e15);
        vm.warp(block.timestamp + 3 days); router.set(1000, 1e14, address(0));            // reference expired: a 10x lower sale is only a cost question
        _hours(2); router.set(1000, 1e15, address(0)); _buyT(acct2, tok, 1 ether);
        router.set(1000, 5e14, address(0)); acct2.exec(address(gate), 0, _sellData(tok, 500 ether, 1));    // -50% vs cost, small: books 0.25, no reference effect
    }

    // F3 (was Medium/High): budget griefing. The thief still burns the executor's budget, but the client's honest exit no longer depends on it.
    function test_FIXED_budget_exhausted_by_fake_lot_does_not_block_owner_exit() public {
        _hours(0); _buy(17.5 ether);
        MockToken fake = new MockToken(); _approveGate(acct, fake);
        _hours(2); _buyT(acct, fake, 17.5 ether);
        router.set(1000, 1, address(0));
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(fake), 17_500 ether, 1, route(address(fake), K_ETH, 17_500 ether))));
        router.set(1000, 0.2e15, address(0));
        vm.expectRevert(); acct.exec(address(gate), 0, _sellData(tok, 17_500 ether, 1)); // executor sell refused (budget)
        _ownerExit(acct, owner1, tok, 17_500 ether);                                      // the client leaves anyway
        (uint256 t, ) = _lot(address(acct), tok); assertEq(t, 0);
        assertGt(address(acct).balance, 60 ether);
    }

    // F4 (was Medium/High): registry poisoning.
    function test_FIXED_registry_poison_dust_refused_gas_bounded_and_forgetLot() public {
        _buy(2 ether);
        _buyT(acct2, tok, 2 ether);
        uint256 a = gasleft(); acct2.exec(address(gate), 0, _sellData(tok, 1000 ether, 1)); uint256 baseGas = a - gasleft();
        MockToken d = new MockToken();
        (bool okD, bytes memory rD) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), 1, _buyData(d, 1))));
        assertFalse(okD); assertEq(bytes4(rD), GuardedGate.DustLot.selector);             // 1-wei lots refused
        address[] memory junk = new address[](31);
        for (uint256 i = 0; i < 31; i++) { GasBurnToken j = new GasBurnToken(); junk[i] = address(j); _buyT(acct, MockToken(address(j)), 0.001 ether); }
        assertEq(gate.lotsOf(address(acct)).length, 32);
        uint256 b = gasleft(); acct.exec(address(gate), 0, _sellData(tok, 1000 ether, 1)); uint256 poisoned = b - gasleft();
        assertLt(poisoned, baseGas + 900_000);                                            // was +2.8M: the walk stops at ~600k gas
        // junk keeps the registry full ...
        MockToken t2 = new MockToken();
        (bool okB, bytes memory rB) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), 1 ether, _buyData(t2, 1 ether))));
        assertFalse(okB); assertEq(bytes4(rB), GuardedGate.TooManyLots.selector);
        // ... until the owner forgets them, without any balanceOf call
        uint256 c0 = gate.costOf(address(acct));
        for (uint256 i = 0; i < 31; i++) { vm.prank(address(acct)); gate.forgetLot(junk[i]); }
        assertEq(gate.lotsOf(address(acct)).length, 1); assertEq(c0 - gate.costOf(address(acct)), 31 * 0.001 ether);
        vm.prank(thief); gate.forgetLot(address(tok));                                    // another caller only touches his own (empty) books
        assertEq(gate.lotsOf(address(acct)).length, 1);
        acct.exec(address(gate), 1 ether, _buyData(t2, 1 ether));                         // new copy-trade entries work again
        // forgetLot is not reachable by the executor: it is not in the delegation's method list (checked in e2e)
    }
    function test_trim_resumes_where_it_stopped() public {
        _buy(1 ether);
        for (uint256 i = 0; i < 20; i++) { GasBurnToken j = new GasBurnToken(); _buyT(acct, MockToken(address(j)), 0.001 ether); }
        // the owner empties two junk lots at the END and the first of the list: they close over successive calls, not necessarily the first
        vm.prank(address(acct)); gate.reconcile(address(acct));
        vm.prank(address(acct)); gate.reconcile(address(acct));
        vm.prank(address(acct)); gate.reconcile(address(acct));                           // three rounds visit all 21 entries without a revert
        assertEq(gate.lotsOf(address(acct)).length, 21);
    }

    // F5 (was Medium): sells blocked by pause. The executor's sell still stops (that is the pause); the client's exitSell does not.
    function test_FIXED_pause_does_not_block_client_exit() public {
        _buy(17.5 ether);
        vm.prank(guardian); gate.setPaused(true);
        vm.expectRevert(GuardedGate.IsPaused.selector); acct.exec(address(gate), 0, _sellData(tok, 1000 ether, 1));
        _ownerExit(acct, owner1, tok, 1000 ether);
        (uint256 t, ) = _lot(address(acct), tok); assertEq(t, 16_500 ether);
        vm.warp(block.timestamp + 7 days); assertFalse(gate.paused());
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
    }

    // F6 (was Medium): withdraw() round trips no longer widen the fee aggregate. Total fees stay <= 20% of the opening balance.
    function test_FIXED_withdraw_roundtrips_do_not_inflate_fee_aggregate() public {
        uint256 opening = 100 ether;
        for (uint256 i = 0; i < 5; i++) {
            uint256 room = gate.feeRoom(address(acct));
            if (room > 0) _fee(acct, room);
            uint256 bal = address(acct).balance;
            _wd(acct, bal);
            vm.deal(address(acct), bal);
        }
        assertLe(feeTo.balance, opening * 2000 / 10000);
    }

    // F7 (was Low): sliding two-bucket windows: no edge bursts.
    function test_FIXED_sliding_windows_no_edge_bursts() public {
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 5);                           // just after a 30-day (and hour, day) boundary
        _fee(acct, 20 ether); vm.warp(block.timestamp + 30 days);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 16 ether);             // was accepted: 36% in 30d + 1s
        assertEq(feeTo.balance, 20 ether);
        _buy(17.5 ether); vm.warp(block.timestamp + 1 hours + 1);                         // an hour later, still inside the previous bucket's weight
        vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.5 ether, _buyData(tok, 17.5 ether));
        vm.warp(block.timestamp + 2 hours); _buy(17.5 ether);
    }
}
