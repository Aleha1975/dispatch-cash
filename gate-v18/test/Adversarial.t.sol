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
    function _exitSellData(MockToken t, uint256 amt, uint256 minOut) internal view returns (bytes memory) { return abi.encodeCall(GuardedGate.exitSell, (address(t), amt, minOut, route(address(t), K_ETH, amt), type(uint256).max)); }
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


    // F3 (was Medium/High): budget griefing. The thief still burns the executor's budget, but the client's honest exit no longer depends on it.
    function test_FIXED_budget_exhausted_by_fake_lot_does_not_block_owner_exit() public {
        _hours(0); _buy(17.5 ether);
        MockToken fake = new MockToken(); _approveGate(acct, fake);
        _hours(2); _buyT(acct, fake, 17.5 ether);
        router.set(1000, 1, address(0));
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(fake), 17_500 ether, 1, route(address(fake), K_ETH, 17_500 ether), type(uint256).max)));
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
