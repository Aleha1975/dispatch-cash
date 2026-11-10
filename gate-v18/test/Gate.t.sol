// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

contract GateTest is GateBase {
    // ---------------- no custody: tokens stay in the account, sale pulls via the account's approve ----------------
    function test_buy_leaves_tokens_in_the_account_and_nothing_in_gate() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(gate)), 0);
        (uint256 t, uint256 c) = _lot(address(acct), tok); assertEq(t, 1000e18); assertEq(c, 1 ether);
        assertEq(address(gate).balance, 0);
    }
    function test_buy_may_pay_account_or_gate_not_a_third_party() public {
        bytes memory d = abi.encodeCall(GuardedGate.buy, (address(tok), 1, routeMin(K_ETH, address(tok), 1 ether, address(acct), 1, exec), type(uint256).max));
        acct.exec(address(gate), 1 ether, d);
        d = abi.encodeCall(GuardedGate.buy, (address(tok), 1, routeMin(K_ETH, address(tok), 1 ether, thief, 1, exec), type(uint256).max));
        vm.expectRevert(GuardedGate.BadRoute.selector); acct.exec(address(gate), 1 ether, d);
    }
    function test_sell_pulls_with_approve_and_pays_account() public {
        _buy(1 ether); uint256 before = address(acct).balance;
        uint256 out = _sell(400e18);
        assertEq(out, 0.4 ether); assertEq(address(acct).balance, before + 0.4 ether);
        (uint256 t, uint256 c) = _lot(address(acct), tok); assertEq(t, 600e18); assertEq(c, 0.6 ether);
        assertEq(tok.balanceOf(address(acct)), 600e18); assertEq(tok.balanceOf(address(gate)), 0); assertEq(tok.balanceOf(address(router)), 400e18);
        _sell(600e18); (t, c) = _lot(address(acct), tok); assertEq(t, 0); assertEq(c, 0); assertEq(gate.costOf(address(acct)), 0);
    }
    function test_sell_without_the_approve_delegation_fails() public {
        MockAccount a3 = new MockAccount(owner1); vm.deal(address(a3), 10 ether); a3.exec(address(gate), 1 ether, _buyData(tok, 1 ether));
        vm.expectRevert(); a3.exec(address(gate), 0, _sellData(tok, 100e18, 1));          // no allowance for the gate -> nothing moves
        assertEq(tok.balanceOf(address(a3)), 1000e18);
    }
    function test_sale_must_pay_gate_not_account_or_thief() public {
        _buy(1 ether);
        for (uint256 i = 0; i < 2; i++) {
            bytes memory d = abi.encodeCall(GuardedGate.sell, (address(tok), 500e18, 1, routeMin(address(tok), K_ETH, 500e18, i == 0 ? thief : address(acct), 1, exec), type(uint256).max));
            vm.expectRevert(GuardedGate.BadRoute.selector); acct.exec(address(gate), 0, d);
        }
    }
    function test_wrong_executor_and_minout_rejected() public {
        bytes memory d = abi.encodeCall(GuardedGate.buy, (address(tok), 1, routeMin(K_ETH, address(tok), 1 ether, address(gate), 1, thief), type(uint256).max));
        vm.expectRevert(GuardedGate.BadRoute.selector); acct.exec(address(gate), 1 ether, d);
        d = abi.encodeCall(GuardedGate.buy, (address(tok), 5, routeMin(K_ETH, address(tok), 1 ether, address(gate), 1, exec), type(uint256).max));
        vm.expectRevert(GuardedGate.BadRoute.selector); acct.exec(address(gate), 1 ether, d);
        vm.expectRevert(GuardedGate.MinOutZero.selector); acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.buy, (address(tok), 0, route(K_ETH, address(tok), 1 ether), type(uint256).max)));
        _buy(1 ether);
        vm.expectRevert(GuardedGate.MinOutZero.selector); acct.exec(address(gate), 0, _sellData(tok, 1e18, 0));
        router.set(1000, 1e12, address(0));
        vm.expectRevert(); acct.exec(address(gate), 0, _sellData(tok, 1000e18, 0.5 ether));    // router/gate minOut enforced
    }
    function test_only_own_lot_and_accounts_are_isolated() public {
        _buy(1 ether); _buyT(acct2, tok, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(GuardedGate.NotInLot.selector, 1000e18, 1001e18)); acct.exec(address(gate), 0, _sellData(tok, 1001e18, 1));
        // tokens that reached the account any other way are not for sale
        tok.mint(address(acct), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedGate.NotInLot.selector, 1000e18, 1500e18)); acct.exec(address(gate), 0, _sellData(tok, 1500e18, 1));
        vm.prank(thief); vm.expectRevert(abi.encodeWithSelector(GuardedGate.NotInLot.selector, 0, 1)); gate.sell(address(tok), 1, 1, route(address(tok), K_ETH, 1), type(uint256).max);
    }
    function test_router_pulling_less_returns_the_rest_to_account() public {
        _buy(1 ether); router.setPullHalf(true);
        _sell(400e18);
        (uint256 t, ) = _lot(address(acct), tok); assertEq(t, 800e18); assertEq(tok.balanceOf(address(acct)), 800e18); assertEq(tok.balanceOf(address(gate)), 0);
    }
    function test_buy_refund_returned_and_home_kickback_not_cost() public {
        router.setRefund(0.3 ether); uint256 b0 = address(acct).balance;
        _buy(1 ether); (, uint256 c) = _lot(address(acct), tok); assertEq(c, 0.7 ether); assertEq(address(acct).balance, b0 - 0.7 ether); assertEq(address(gate).balance, 0);
        router.setRefund(0); router.setKickback(address(acct), 0.4 ether);
        _buy(1 ether); (, c) = _lot(address(acct), tok); assertEq(c, 0.7 ether + 0.6 ether);
    }
    function test_direct_eth_refused() public { vm.expectRevert(GuardedGate.NoDirectEth.selector); payable(address(gate)).transfer(1 ether); }

    // ---------------- reconciliation (as v17.2): owner moves tokens out ----------------
    function test_owner_moving_tokens_out_shrinks_the_lot() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(owner1, 600e18);
        (uint256 t, uint256 c) = _lot(address(acct), tok); assertEq(t, 400e18); assertEq(c, 0.4 ether);   // view quotes the trimmed lot
        vm.expectRevert(abi.encodeWithSelector(GuardedGate.NotInLot.selector, 400e18, 500e18)); acct.exec(address(gate), 0, _sellData(tok, 500e18, 1));
        vm.prank(address(acct)); tok.transfer(owner1, 400e18);
        gate.lotsOf(address(acct)); vm.prank(cold); gate.reconcile(address(acct)); assertEq(gate.costOf(address(acct)), 0);
        vm.prank(thief); vm.expectRevert(GuardedGate.NotReconciler.selector); gate.reconcile(address(acct));
    }

    // ---------------- hourly buy cap only (sells are never capped) ----------------
    function test_buy_cap_17_5_per_hour_per_account() public {
        _buy(5 ether); _buy(5 ether); _buy(5 ether); _buy(2.5 ether);
        vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 1, _buyData(tok, 1));
        _buyT(acct2, tok, 5 ether);
        vm.warp(block.timestamp + 2 hours); _buy(5 ether);
    }
    function test_single_buy_above_hour_cap_refused() public { vm.deal(address(acct), 100 ether); vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.5 ether + 1, _buyData(tok, 17.5 ether + 1)); }
    function test_sells_have_no_count_and_no_proceeds_cap() public {
        router.set(1000, 1 ether, address(0));                                   // 1 token = 1 ETH on the way out (profit)
        vm.deal(address(router), 100000 ether);
        _buy(5 ether); _buy(5 ether); _buy(5 ether); _buy(2.5 ether);            // 17500 tokens
        for (uint256 i = 0; i < 30; i++) _sell(1e18);                            // 30 sells in one hour (old cap 24)
        _sell(300e18);                                                           // 330 ETH of proceeds in the hour (old cap 100)
        (uint256 la, ) = gate.loss(address(acct)); assertEq(la, 0);
    }

    // ---------------- native withdrawal: no cap, owner only, never paused ----------------
    function test_withdraw_whole_balance_in_one_call_pays_owner() public {
        vm.deal(address(acct), 400 ether);
        acct.exec(address(gate), 400 ether, abi.encodeCall(GuardedGate.withdraw, ()));
        assertEq(owner1.balance, 400 ether); assertEq(address(acct).balance, 0); assertEq(address(gate).balance, 0);
        vm.expectRevert(GuardedGate.ZeroAmount.selector); acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.withdraw, ()));
        acct.setOwner(owner2); vm.deal(address(acct), 1 ether);
        acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ())); assertEq(owner2.balance, 1 ether);   // follows owner()
    }
    function test_plain_wallet_and_7702_account_are_their_own_owner() public {
        vm.deal(thief, 10 ether); vm.prank(thief); gate.withdraw{value: 1 ether}(); assertEq(thief.balance, 10 ether);
        address d7702 = address(0x7702); vm.etch(d7702, abi.encodePacked(hex"ef0100", address(0xDEAD))); vm.deal(d7702, 3 ether);
        vm.prank(d7702); gate.withdraw{value: 1 ether}(); assertEq(d7702.balance, 3 ether);
        assertEq(gate.ownerOf(d7702), d7702);
    }
    function test_account_without_usable_owner_cannot_withdraw_via_delegation() public {
        NoOwnerAccount n = new NoOwnerAccount(); vm.deal(address(n), 1 ether);
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); n.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ()));
        MockAccount bad = new MockAccount(address(0)); vm.deal(address(bad), 1 ether);
        address[4] memory owners = [address(0), address(acct), address(bad), address(router)];
        for (uint256 i = 0; i < 4; i++) { bad.setOwner(owners[i]); vm.expectRevert(GuardedGate.NoBeneficiary.selector); bad.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ())); }
    }
    function test_withdrawTo_is_the_account_only_fallback() public {
        RevertingOwnerAccount a = new RevertingOwnerAccount(); vm.deal(address(a), 10 ether);
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); a.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ()));
        address dest = address(0xD00D);
        a.exec(address(gate), 10 ether, abi.encodeCall(GuardedGate.withdrawTo, (dest))); assertEq(dest.balance, 10 ether);
        vm.deal(address(a), 1 ether);
        vm.expectRevert(GuardedGate.BadRecipient.selector); a.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(0))));
        vm.expectRevert(GuardedGate.BadRecipient.selector); a.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(gate))));
        vm.expectRevert(GuardedGate.BadRecipient.selector); a.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdrawTo, (address(router))));
        vm.expectRevert(GuardedGate.ZeroAmount.selector); a.exec(address(gate), 0, abi.encodeCall(GuardedGate.withdrawTo, (dest)));
    }
    function test_owner_call_gas_is_100k() public {
        assertEq(gate.OWNER_GAS(), 100_000);
        SlowOwnerAccount s = new SlowOwnerAccount(owner1); vm.deal(address(s), 5 ether);
        uint256 g0 = gasleft(); s.owner(); uint256 used = g0 - gasleft(); assertGt(used, 31_000); assertLt(used, 99_000);
        s.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ())); assertEq(owner1.balance, 1 ether);
    }
    function test_no_native_path_to_anyone_but_router_feeTo_owner_account() public {
        // every entry with value: buy -> router (mock) / change back, payFee,refundGas -> feeTo, withdraw -> owner. Gate never keeps any.
        vm.deal(address(acct), 100 ether);
        _buy(1 ether);
        acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.payFee, ()));
        acct.exec(address(gate), 0.01 ether, abi.encodeCall(GuardedGate.refundGas, ()));
        acct.exec(address(gate), 2 ether, abi.encodeCall(GuardedGate.withdraw, ()));
        _sell(500e18);
        assertEq(address(gate).balance, 0); assertEq(feeTo.balance, 1.01 ether); assertEq(owner1.balance, 2 ether); assertEq(thief.balance, 0);
    }

    // ---------------- pause ----------------
    function test_pause_blocks_executor_paths_not_withdrawals_or_exit() public {
        _buy(1 ether); vm.deal(address(acct), 10 ether);
        vm.prank(guardian); gate.setPaused(true);
        vm.expectRevert(GuardedGate.IsPaused.selector); acct.exec(address(gate), 1 ether, _buyData(tok, 1 ether));
        vm.expectRevert(GuardedGate.IsPaused.selector); acct.exec(address(gate), 0, _sellData(tok, 1e18, 1));
        vm.expectRevert(GuardedGate.IsPaused.selector); acct.exec(address(gate), 1, abi.encodeCall(GuardedGate.payFee, ()));
        vm.expectRevert(GuardedGate.IsPaused.selector); acct.exec(address(gate), 1, abi.encodeCall(GuardedGate.refundGas, ()));
        acct.exec(address(gate), 10 ether, abi.encodeCall(GuardedGate.withdraw, ())); assertEq(owner1.balance, 10 ether);   // the whole balance, paused
        vm.warp(block.timestamp + 7 days); assertFalse(gate.paused()); vm.deal(address(acct), 5 ether); _buy(1 ether);
        vm.prank(guardian); vm.expectRevert(GuardedGate.PauseCooldown.selector); gate.setPaused(true);
        vm.warp(block.timestamp + 1 days); vm.prank(guardian); gate.setPaused(true);
        vm.prank(thief); vm.expectRevert(GuardedGate.NotGuardian.selector); gate.setPaused(false);
    }
    function test_guardian_rotation() public {
        address g2 = address(0x6A12D2);
        vm.prank(guardian); gate.proposeGuardian(g2);
        vm.prank(g2); gate.acceptGuardian(); assertEq(gate.guardian(), g2);
        vm.prank(guardian); vm.expectRevert(GuardedGate.NotGuardian.selector); gate.setPaused(true);
        vm.prank(thief); vm.expectRevert(GuardedGate.NotExitKey.selector); gate.replaceGuardian(thief);
        vm.prank(cold); gate.replaceGuardian(guardian); assertEq(gate.guardian(), guardian);
        vm.prank(guardian); vm.expectRevert(GuardedGate.BadGuardian.selector); gate.proposeGuardian(feeTo);
        vm.prank(guardian); gate.proposeGuardian(g2); vm.warp(block.timestamp + 7 days + 1); vm.prank(g2); vm.expectRevert(GuardedGate.NotPendingGuardian.selector); gate.acceptGuardian();
    }

    // ---------------- exit key, exit mode, loss budget ----------------
    function test_exit_by_cold_key() public {
        _buy(1 ether); router.set(1000, 1e12, address(0)); bytes memory d = abi.encodeCall(GuardedGate.exit, (address(tok), 1000e18, 1, route(address(tok), K_ETH, 1000e18)));
        vm.expectRevert(GuardedGate.NotExitKey.selector); acct.exec(address(gate), 0, d);
        vm.prank(guardian); gate.setPaused(true);
        vm.startPrank(address(0xBEEF), cold); acct.exec(address(gate), 0, d); vm.stopPrank();
        (uint256 t, ) = _lot(address(acct), tok); assertEq(t, 0); (uint256 la, ) = gate.loss(address(acct)); assertEq(la, 0);
    }
    function test_loss_budget_30pct_and_unlock() public {
        vm.deal(address(acct), 3 ether); _buy(1 ether);                         // base 2 + 1 = 3 -> budget 0.9
        router.set(1000, 1e12, address(0));
        acct.exec(address(gate), 0, _sellData(tok, 500e18, 1));
        (uint256 lost, uint256 budget) = gate.budgetOf(address(acct), address(tok)); assertGt(lost, 0.49 ether); assertLt(budget, 0.8 ether);
        vm.expectRevert(); acct.exec(address(gate), 0, _sellData(tok, 500e18, 1));
        address[] memory a = new address[](1); a[0] = address(acct);
        vm.prank(thief); vm.expectRevert(GuardedGate.NotExitKey.selector); gate.unlock(a);
        vm.prank(cold); gate.unlock(a);
        acct.exec(address(gate), 0, _sellData(tok, 500e18, 1));
    }
    function test_sale_at_or_above_cost_never_books_loss() public {
        _buy(1 ether); router.set(1000, 2e15, address(0)); _sell(1000e18); (uint256 la, ) = gate.loss(address(acct)); assertEq(la, 0);
    }
    function _exitSellData(MockToken t, uint256 amt, uint256 minOut) internal view returns (bytes memory) { return abi.encodeCall(GuardedGate.exitSell, (address(t), amt, minOut, route(address(t), K_ETH, amt), type(uint256).max)); }
    function test_exitSell_lets_an_honest_full_exit_through_the_budget() public {
        vm.deal(address(acct), 0); vm.deal(address(acct), 0.1 ether); _buy(0.1 ether); router.set(1000, 1e12, address(0));   // base 0.1 -> budget 0.03, loss ~0.1
        vm.expectRevert(); acct.exec(address(gate), 0, _sellData(tok, 100e18, 1));      // executor sell: refused by the budget
        vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 0, _exitSellData(tok, 100e18, 1));   // the executor (any other origin) cannot exitSell
        vm.prank(thief, thief); vm.expectRevert(); gate.exitSell(address(tok), 1, 1, route(address(tok), K_ETH, 1), type(uint256).max);   // another account has no lot
        vm.prank(owner1, owner1); acct.exec(address(gate), 0, _exitSellData(tok, 100e18, 1));   // the owner's own transaction: no budget, no loss booked
        (uint256 la, ) = gate.loss(address(acct)); assertEq(la, 0); (uint256 t, ) = _lot(address(acct), tok); assertEq(t, 0);
    }
    function test_exitSell_works_while_paused_and_sell_does_not() public {
        _buy(1 ether); vm.prank(guardian); gate.setPaused(true);
        vm.expectRevert(GuardedGate.IsPaused.selector); acct.exec(address(gate), 0, _sellData(tok, 1e18, 1));
        vm.prank(owner2, owner2); vm.expectRevert(GuardedGate.NotOwnerOrigin.selector); acct.exec(address(gate), 0, _exitSellData(tok, 1e18, 1));   // someone else's owner
        vm.prank(owner1, owner1); acct.exec(address(gate), 0, _exitSellData(tok, 1e18, 1));
        (uint256 t, ) = _lot(address(acct), tok); assertEq(t, 999e18);
    }
    function testFuzz_partial_sells_conserve_lot_and_cost(uint96 eth, uint64[5] memory cuts) public {
        router.set(1000, 1 ether, address(0)); vm.deal(address(router), 1e5 ether);   // sells at 1 ETH per token: every slice pays at least 1 wei
        uint256 e = bound(eth, 1e15, 10 ether); _buy(e); (uint256 t0, uint256 c0) = _lot(address(acct), tok);
        uint256 soldT; uint256 costOut;
        for (uint256 i = 0; i < 5; i++) {
            (uint256 t, uint256 c) = _lot(address(acct), tok); if (t == 0) break;
            uint256 x = bound(cuts[i], 1, t); _sell(x); (uint256 t2, uint256 c2) = _lot(address(acct), tok);
            soldT += x; costOut += c - c2; assertEq(t2, t - x); assertLe(c2, c);
        }
        (uint256 tf, uint256 cf) = _lot(address(acct), tok); assertEq(tf + soldT, t0); assertEq(cf + costOut, c0);
        assertEq(tok.balanceOf(address(acct)), tf); assertEq(tok.balanceOf(address(gate)), 0); assertEq(address(gate).balance, 0);
    }
}
