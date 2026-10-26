// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

contract GuardedSwapTest is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    MockToken tok; MockRouter router; GuardedSwap guard; Wallet acct; address exec; address thief = address(0x1111111111111111111111111111111111111111);
    address cold = address(0xC01D);                     // the operator's cold key (an EOA)
    function setUp() public {
        tok = new MockToken(); router = new MockRouter(); exec = address(new Wallet());
        guard = new GuardedSwap(address(router), exec, address(this), cold, 1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(router), 100 ether); vm.deal(address(acct), 10 ether);
        router.set(1000, 1e15, address(0));          // 1 ETH -> 1000 tokens; 1 token -> 0.001 ETH (entry price); pays the calldata recipient
    }
    // ---- Kyber-shaped calldata builders ----
    function routeMin(address tin, address tout, uint256 amount, address recipient, uint256 minRet, address callTarget) internal pure returns (bytes memory) {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = recipient; d.amount = amount; d.minReturnAmount = minRet;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = callTarget;
        return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function route(address tin, address tout, uint256 amount, address recipient) internal view returns (bytes memory) { return routeMin(tin, tout, amount, recipient, 1, exec); }
    function routeSimple(address tin, address tout, uint256 amount, address recipient) internal view returns (bytes memory) {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = recipient; d.amount = amount; d.minReturnAmount = 1;
        return abi.encodeWithSelector(0x8af033fb, exec, d, bytes(""), bytes(""));
    }
    function _buy(uint256 eth) internal returns (uint256) { vm.prank(address(acct)); return guard.buy{value: eth}(address(tok), 1, route(K_ETH, address(tok), eth, address(acct))); }
    function _sell(uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount);
        uint256 out = guard.sell(address(tok), amount, minOut, route(address(tok), K_ETH, amount, address(guard))); vm.stopPrank(); return out; }
    function _expectSell(uint256 amount, bytes memory err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount); vm.expectRevert(err);
        guard.sell(address(tok), amount, 1, route(address(tok), K_ETH, amount, address(guard))); vm.stopPrank(); }
    function _exit(uint256 amount) internal returns (uint256) {
        vm.startPrank(address(acct), cold); tok.approve(address(guard), amount);
        uint256 out = guard.exit(address(tok), amount, 1, route(address(tok), K_ETH, amount, address(guard))); vm.stopPrank(); return out; }

    // ---- recipient rule ----
    function test_buy_pays_caller_and_records_lot() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18); assertEq(ethIn, 1 ether); assertEq(guard.costOf(address(acct)), 1 ether);
    }
    function test_buy_simple_mode_rejected() public {
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, routeSimple(K_ETH, address(tok), 1 ether, address(acct)));
    }
    function test_buy_output_held_by_guard_is_forwarded() public {
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(guard)));
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
    }
    function test_calldata_recipient_thief_rejected() public {
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, thief));
        _buy(1 ether); vm.startPrank(address(acct)); tok.approve(address(guard), 500e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, thief)); vm.stopPrank();
        vm.startPrank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, address(acct))); vm.stopPrank();   // a sale paid to the account directly is refused too: paid here, forwarded after settlement
        assertEq(tok.balanceOf(address(acct)), 1000e18);
    }
    function test_router_paying_elsewhere_reverts() public {
        router.set(1000, 1e15, thief);                       // honest calldata, dishonest executor path
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
        router.set(1000, 1e15, address(0)); _buy(1 ether); router.set(1000, 1e15, thief);
        _expectSell(500e18, abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
    }
    function test_route_checks() public {
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, routeMin(K_ETH, address(tok), 1 ether, address(acct), 1, thief));          // wrong executor
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 5, routeMin(K_ETH, address(tok), 1 ether, address(acct), 1, exec));           // router minimum below ours
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(0xBEEF), 1 ether, address(acct)));   // wrong dstToken
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 2 ether, address(acct)));      // amount mismatch
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, hex"deadbeef");                                            // unknown selector
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = K_ETH; d.dstToken = address(tok); d.dstReceiver = address(acct); d.amount = 1 ether; d.minReturnAmount = 1;
        d.feeReceivers = new address[](1); d.feeReceivers[0] = thief; d.feeAmounts = new uint256[](1); d.feeAmounts[0] = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));             // fee receivers
        d.feeReceivers = new address[](0); d.feeAmounts = new uint256[](0); d.permit = hex"01"; p.desc = d;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));             // permit
        d.permit = ""; d.srcReceivers = new address[](1); d.srcReceivers[0] = thief; d.srcAmounts = new uint256[](1); d.srcAmounts[0] = 0.9 ether; p.desc = d;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));             // input diverted on a buy
        d.srcReceivers = new address[](0); d.srcAmounts = new uint256[](0);
        for (uint256 f = 1; f <= 0x100; f <<= 1) { d.flags = f; p.desc = d; vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); }   // every router flag
        d.flags = 0x200; p.desc = d; uint256 out = guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); assertEq(out, 1000e18);   // the inert bit live routes carry
        vm.stopPrank();
    }
    function test_sale_receivers_rules() public {
        _buy(1 ether);
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = address(tok); d.dstToken = K_ETH; d.dstReceiver = address(guard); d.amount = 10e18; d.minReturnAmount = 1;
        d.srcReceivers = new address[](9); d.srcAmounts = new uint256[](9); for (uint256 i = 0; i < 9; i++) { d.srcReceivers[i] = address(router); d.srcAmounts[i] = 1; }
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18);
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));   // too many
        d.srcReceivers = new address[](1); d.srcAmounts = new uint256[](1); d.srcReceivers[0] = address(guard); d.srcAmounts[0] = 1; p.desc = d;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));   // the gate itself
        d.srcReceivers[0] = thief; p.desc = d;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));   // not a contract
        d.srcReceivers[0] = address(router); d.srcAmounts[0] = 11e18; p.desc = d;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));   // more than the input
        vm.stopPrank();
    }
    function test_minOut_zero_and_non_contract_token() public {
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwap.MinOutZero.selector); guard.buy{value: 1 ether}(address(tok), 0, route(K_ETH, address(tok), 1 ether, address(acct)));
        vm.expectRevert(GuardedSwap.NotAContract.selector); guard.buy{value: 1 ether}(thief, 1, route(K_ETH, thief, 1 ether, address(acct)));
        vm.stopPrank();
    }

    // ---- only this call's funds ----
    function test_stray_tokens_and_eth_are_neither_swept_nor_counted() public {
        tok.mint(address(guard), 500e18); vm.deal(address(guard), 5 ether);
        uint256 out = _buy(1 ether); assertEq(out, 1000e18);
        (, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 1 ether);
        assertEq(tok.balanceOf(address(guard)), 500e18); assertEq(address(guard).balance, 5 ether); assertEq(address(acct).balance, 9 ether);
        uint256 got = _sell(500e18, 1); assertEq(got, 0.5 ether); assertEq(tok.balanceOf(address(guard)), 500e18); assertEq(address(guard).balance, 5 ether);
    }
    function test_direct_eth_refused_outside_a_trade() public {
        vm.prank(address(acct)); (bool ok, ) = address(guard).call{value: 1 ether}(""); assertFalse(ok);
        vm.deal(address(router), 101 ether); vm.prank(address(router)); (ok, ) = address(guard).call{value: 1 ether}(""); assertFalse(ok);
    }
    function test_zero_cost_lot_and_router_overpay_refused() public {
        router.setRefund(1 ether); vm.prank(address(acct)); vm.expectRevert(GuardedSwap.ZeroAmount.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
        router.setRefund(0); router.setOverpay(1 wei); vm.prank(address(acct)); vm.expectRevert(GuardedSwap.RouterOverpaid.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
    }
    function test_state_is_final_before_eth_leaves() public {
        SpyWallet spy = new SpyWallet(); spy.set(guard, address(tok)); vm.deal(address(spy), 2 ether); router.setRefund(0.1 ether);
        uint256 out = spy.buy(1 ether, 1, route(K_ETH, address(tok), 1 ether, address(spy)));
        assertEq(spy.hooks(), 1); assertEq(spy.seenTokens(), out);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(spy), address(tok)); assertEq(tokens, out); assertEq(ethIn, 0.9 ether);
        router.setRefund(0); spy.sell(100e18, 1, route(address(tok), K_ETH, 100e18, address(guard)));
        assertEq(spy.hooks(), 2); assertEq(spy.seenTokens(), out - 100e18);
    }
    function test_reentrancy_blocked() public { router.setReenter(address(guard)); _buy(1 ether); assertFalse(router.reenterOk()); }
    function test_guard_keeps_nothing() public { _buy(1 ether); _sell(100e18, 1); assertEq(address(guard).balance, 0); assertEq(tok.balanceOf(address(guard)), 0); }

    // ---- only the lot ----
    function test_only_the_lot_is_for_sale() public {
        tok.mint(address(acct), 100e18);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 0, 100e18));
        _buy(1 ether);
        _expectSell(1100e18, abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 1000e18, 1100e18));
        assertEq(tok.balanceOf(address(acct)), 1100e18);
    }
    function test_tokens_the_owner_moved_out_leave_the_lot_pro_rata() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 700e18);
        (uint256 tokens, uint256 ethIn) = guard.lotOf(address(acct), address(tok)); assertEq(tokens, 300e18); assertEq(ethIn, 0.3 ether);
        _expectSell(1000e18, abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 300e18, 1000e18));
        uint256 out = _sell(300e18, 1); assertEq(out, 0.3 ether);
        assertEq(guard.costOf(address(acct)), 0); (tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0);
    }
    function test_an_emptied_lot_closes() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 1000e18);
        router.set(100000, 1e15, address(0)); _buy(0.1 ether);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 10000e18); assertEq(ethIn, 0.1 ether); assertEq(guard.costOf(address(acct)), 0.1 ether);
    }
    function test_fee_on_transfer_lot_closes_on_a_full_sale() public {
        _buy(1 ether); tok.setFee(1000);
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18);
        uint256 out = guard.sell(address(tok), 1000e18, 1, route(address(tok), K_ETH, 900e18, address(guard))); vm.stopPrank();
        assertEq(out, 0.9 ether); (uint256 tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0); assertEq(guard.costOf(address(acct)), 0);
    }
    function test_a_sale_that_moves_nothing_is_refused() public {
        _buy(1 ether); router.setPullNone(true);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwap.ZeroAmount.selector));
        (, uint64 sells,,) = guard.window(address(acct)); assertEq(sells, 0);
    }
    function test_zero_first_token_with_a_leftover_allowance_still_sells() public {
        _buy(1 ether); tok.setZeroFirst(true); router.setPullLess(true); tok.setRevertOnZeroApprove(true);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether); assertGt(tok.allowance(address(guard), address(router)), 0);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwap.TransferFailed.selector));          // refuses approve(0) AND wants zero first: unsupported, fails closed
        tok.setRevertOnZeroApprove(false); vm.prank(address(acct)); tok.approve(address(guard), 0);
        out = _sell(100e18, 1); assertEq(out, 0.1 ether);
    }

    // ---- loss budget ----
    function test_profit_and_at_cost_sales_never_touch_the_budget() public {
        _buy(1 ether); router.set(1000, 2e15, address(0)); _sell(500e18, 1);                        // 2x
        router.set(1000, 1e15, address(0)); _sell(500e18, 1);                                        // at cost
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_losses_accumulate_up_to_30_percent_of_the_account_then_block() public {
        vm.deal(address(acct), 1 ether); _buy(1 ether);                                              // all in: no ETH left, cost 1 ETH, base 1, budget 0.3
        router.set(1000, 5e14, address(0)); uint256 out = _sell(400e18, 1); assertEq(out, 0.2 ether); // cost 0.4, got 0.2: loss 0.2
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.2 ether); assertEq(budget, 0.24 ether);   // v16: 30% of what the account is worth at cost (0.6 lot + 0.2 ETH)
        // the next losing sale: cost 0.3, got 0.15 -> loss 0.15, total 0.35 > budget (30% of 0.8 = 0.24) -> refused
        _expectSell(300e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.35 ether, 0.24 ether));
        router.set(1000, 1e15, address(0)); out = _sell(300e18, 1); assertEq(out, 0.3 ether);        // selling at cost still goes
        router.set(1000, 2e15, address(0)); out = _sell(300e18, 1); assertEq(out, 0.6 ether);        // and above cost
    }
    function test_a_single_crash_is_inside_the_budget() public {
        vm.deal(address(acct), 20 ether); for (uint256 i = 0; i < 12; i++) _buy(1 ether);              // 12 ETH of cost
        router.set(1000, 5e13, address(0));                                                          // -95%
        uint256 out = _sell(1000e18, 1); assertEq(out, 0.05 ether);                                  // one position (1/12 of cost) dumped: loss 0.95 of a 6.0 budget (30% of 12 cost + 8 ETH)
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.95 ether); assertEq(budget, 5.715 ether);   // 30% of 11 cost + 8.05 ETH
    }
    function test_budget_refills_linearly_over_a_week() public {
        vm.deal(address(acct), 1 ether);
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);                         // loss 0.25 of base 1 -> budget now 30% of (0.5 + 0.25) = 0.225, lost 0.25 (over, as the base shrank)
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.3 ether, 0.225 ether));
        vm.warp(block.timestamp + 3.5 days);                                                         // half a week: half of the booked loss has faded
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.125 ether);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);   // and all of it within REFILL of the booking
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
    }
    function test_unlock_only_by_the_cold_key() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);
        address[] memory a = new address[](1); a[0] = address(acct);
        vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.unlock(a);                          // not the guardian (this test contract)
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.unlock(a);  // not the account
        vm.prank(address(acct), cold); vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.unlock(a);   // (round 13, F-1) the key as origin but a contract as sender: refused
        vm.prank(cold); guard.unlock(a);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
    }

    // ---- exit ----
    function test_exit_only_when_the_cold_key_sent_the_transaction() public {
        _buy(1 ether); router.set(1000, 1e14, address(0));                                           // -90%
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18); vm.expectRevert(GuardedSwap.NotExitKey.selector);
        guard.exit(address(tok), 1000e18, 1, route(address(tok), K_ETH, 1000e18, address(guard))); vm.stopPrank();   // tx.origin is not the cold key
        vm.startPrank(address(acct), thief); vm.expectRevert(GuardedSwap.NotExitKey.selector);
        guard.exit(address(tok), 1000e18, 1, route(address(tok), K_ETH, 1000e18, address(guard))); vm.stopPrank();
        uint256 out = _exit(1000e18); assertEq(out, 0.1 ether);                                      // the cold key: everything to ETH, budget ignored, paid to the account
        assertEq(address(acct).balance, 9.1 ether); (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        (uint256 tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0); assertEq(guard.costOf(address(acct)), 0);
    }
    function test_exit_ignores_hourly_limits_but_not_the_route_rules() public {
        guard = new GuardedSwap(address(router), exec, address(this), cold, 1, 1000 ether, 0.01 ether);   // 1 sale an hour, 0.01 ETH out an hour
        _buy(1 ether); _sell(10e18, 1);
        _expectSell(10e18, abi.encodeWithSelector(GuardedSwap.RateLimited.selector));
        uint256 out = _exit(500e18); assertEq(out, 0.5 ether);                                       // neither the count nor the ETH cap applies
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.exit(address(tok), 100e18, 1, route(address(tok), K_ETH, 100e18, thief)); vm.stopPrank();   // but it can only ever pay the account
        vm.startPrank(address(acct), cold); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 490e18, 1000e18));
        guard.exit(address(tok), 1000e18, 1, route(address(tok), K_ETH, 1000e18, address(guard))); vm.stopPrank();  // and only the lot
    }

    // ---- pause, limits, guardian ----
    function test_pause_stops_the_executor_not_the_exit_and_is_bounded() public {
        _buy(1 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.setPaused(true);
        guard.setPaused(true);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.IsPaused.selector); guard.buy{value: 0.1 ether}(address(tok), 1, route(K_ETH, address(tok), 0.1 ether, address(acct)));
        router.set(1000, 5e14, address(0)); _expectSell(100e18, abi.encodeWithSelector(GuardedSwap.IsPaused.selector));   // v14: the executor's sales stop too
        { bytes memory d = route(address(tok), K_ETH, 100e18, address(guard));                        // ...but the cold key's exit does not
          vm.startPrank(address(acct), cold); tok.approve(address(guard), 100e18); uint256 out = guard.exit(address(tok), 100e18, 1, d); vm.stopPrank(); assertEq(out, 0.05 ether); }
        vm.expectRevert(GuardedSwap.PauseCooldown.selector); guard.setPaused(true);
        vm.warp(block.timestamp + 7 days + 1); assertFalse(guard.paused());
        vm.expectRevert(GuardedSwap.PauseCooldown.selector); guard.setPaused(true);
        vm.warp(block.timestamp + 1 days); guard.setPaused(true); guard.setPaused(false);
        vm.expectRevert(GuardedSwap.PauseCooldown.selector); guard.setPaused(true);
    }
    function test_guardian_and_exit_key_cannot_touch_funds() public {
        _buy(1 ether); guard.setPaused(true); guard.setPaused(false);
        address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); guard.unlock(a);
        assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(this)), 0); assertEq(tok.balanceOf(cold), 0); assertEq(address(guard).balance, 0);
    }
    function test_guardian_rotation_two_step_with_rules_and_expiry() public {
        address g2 = address(0xBEEF);
        vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.proposeGuardian(cold);
        vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.proposeGuardian(address(guard));
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.proposeGuardian(g2);
        guard.proposeGuardian(g2); vm.warp(block.timestamp + 7 days + 1);
        vm.prank(g2); vm.expectRevert(GuardedSwap.NotPendingGuardian.selector); guard.acceptGuardian();
        guard.proposeGuardian(g2); vm.prank(g2); guard.acceptGuardian(); assertEq(guard.guardian(), g2);
        vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.setPaused(true);
    }
    function test_constructor_hygiene() public {
        vm.expectRevert(bytes("router == executor")); new GuardedSwap(address(router), address(router), address(this), cold, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("exit key must be an EOA")); new GuardedSwap(address(router), exec, address(this), address(tok), 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("exit key")); new GuardedSwap(address(router), exec, cold, cold, 12, 0.3 ether, 1 ether);
    }
    function _tight() internal { guard = new GuardedSwap(address(router), exec, address(this), cold, 12, 0.3 ether, 1 ether); }
    function test_rate_limits() public {
        _tight(); _buy(0.3 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.RateLimited.selector); guard.buy{value: 1}(address(tok), 1, route(K_ETH, address(tok), 1, address(acct)));
        for (uint256 i = 0; i < 12; i++) _sell(10e18, 1);
        _expectSell(10e18, abi.encodeWithSelector(GuardedSwap.RateLimited.selector));
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether); _buy(0.3 ether);
        Wallet other = new Wallet(); vm.deal(address(other), 1 ether);
        vm.prank(address(other)); out = guard.buy{value: 0.3 ether}(address(tok), 1, route(K_ETH, address(tok), 0.3 ether, address(other))); assertEq(out, 300e18);   // per account
    }
    function test_sell_eth_per_hour_is_capped() public {
        _tight(); vm.deal(address(acct), 100 ether);
        for (uint256 i = 0; i < 4; i++) { _buy(0.3 ether); vm.warp(block.timestamp + 1 hours); }
        _sell(900e18, 1); _expectSell(200e18, abi.encodeWithSelector(GuardedSwap.RateLimited.selector));
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(200e18, 1); assertEq(out, 0.2 ether);
    }
    function test_floorFor_quotes_the_room_left() public {
        vm.deal(address(acct), 1 ether);
        _buy(1 ether); assertEq(guard.floorFor(address(acct), address(tok), 1000e18), 0.7 ether);     // base 1 (no ETH left), room 0.3: may return 0.7
        router.set(1000, 5e14, address(0)); _sell(400e18, 1);                                        // loss 0.2; base 0.6 + 0.2 ETH, budget 0.24, room 0.04
        assertEq(guard.floorFor(address(acct), address(tok), 100e18), 0.06 ether);                    // cost 0.1 minus the room left
        vm.deal(address(acct), 10 ether);                                                            // the owner tops up: the base follows the account
        assertEq(guard.floorFor(address(acct), address(tok), 100e18), 0);
    }
    function testFuzz_cost_tracks_sales(uint96 price, uint8 fracBps) public {
        vm.assume(price > 1e9 && price < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;
        vm.deal(address(acct), 1 ether); router.set(1000, price, address(0)); _buy(1 ether);          // all in: base = cost = 1 ETH
        uint256 sellAmt = 1000e18 * frac / 100; uint256 expectOut = sellAmt * price / 1e18; uint256 cost = 1 ether * sellAmt / 1000e18;
        uint256 lossIf = expectOut < cost ? cost - expectOut : 0;
        if (lossIf <= 0.3 ether) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18 - sellAmt); assertEq(ethIn, tokens == 0 ? 0 : 1 ether - cost);
            (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, lossIf); }
        else _expectSell(sellAmt, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, lossIf, (1 ether) * 3000 / 10000));
    }

    // ---- round 11 (v13) ----
    function test_a_loss_fades_over_a_week_whatever_the_base_does() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);                         // loss 0.25 booked now
        vm.deal(address(acct), 20 ether); router.set(1000, 1e15, address(0)); for (uint256 i = 0; i < 10; i++) _buy(1 ether);   // a deposit and 10 ETH of buys: base 10.5 cost + 10 ETH
        vm.warp(block.timestamp + 3.5 days);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 6.15 ether);
        assertEq(lost, 0.125 ether);                                                                 // half of 0.25 after half a week: the new capital changed nothing (C-1 B)
    }
    function test_a_loss_keeps_fading_after_the_lot_is_closed() public {
        vm.deal(address(acct), 1 ether);
        _buy(1 ether); router.set(1000, 7e14, address(0)); _sell(1000e18, 1);                        // full exit at -30%: loss 0.3 == budget, lot closed, cost basis 0
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.3 ether); assertEq(budget, 0.21 ether);   // only the 0.7 ETH that came back is left in the base
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.15 ether);   // fades although costOf is 0 (C-1 D)
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_booking_more_resets_the_clock_on_the_whole_amount() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(400e18, 1);                         // loss 0.2
        vm.warp(block.timestamp + 3.5 days);                                                         // 0.1 left
        router.set(1000, 5e14, address(0)); _sell(100e18, 1);                                        // +0.05: 0.15 outstanding, clock reset
        (uint256 amt, uint64 at) = guard.loss(address(acct)); assertEq(amt, 0.15 ether); assertEq(at, uint64(block.timestamp));
        vm.warp(block.timestamp + 7 days); (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);   // and the whole 0.15 is gone within REFILL of that booking (F-4)
    }
    function test_the_cold_key_can_replace_a_guardian_that_holds_the_pause() public {
        guard.setPaused(true); assertTrue(guard.paused());
        address g2 = address(0x6002);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.replaceGuardian(g2);   // only the cold key
        vm.prank(cold); vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.replaceGuardian(address(this));   // not the same guardian
        vm.prank(cold); guard.replaceGuardian(g2); assertEq(guard.guardian(), g2);
        vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.setPaused(false);                   // the old key has no power left
        vm.prank(g2); guard.setPaused(false); assertFalse(guard.paused());                           // the new guardian lifts the pause at once (F-3 / I-1)
    }
    function test_bricked_balance_does_not_block_sell_or_exit() public {
        _buy(1 ether); tok.setBricked(address(acct), true);                                          // the account can no longer be read (blacklist); the gate can
        router.set(1000, 1e15, address(0)); uint256 out = _sell(400e18, 1); assertEq(out, 0.4 ether);   // sell() still works on the last-known lot
        (uint256 lot, ) = guard.lotOf(address(acct), address(tok)); assertEq(lot, 600e18);
        bytes memory d = route(address(tok), K_ETH, 600e18, address(guard));
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 600e18); out = guard.exit(address(tok), 600e18, 1, d); vm.stopPrank();   // and so does the cold key's exit
        assertEq(out, 0.6 ether); (lot, ) = guard.lotOf(address(acct), address(tok)); assertEq(lot, 0); assertEq(guard.costOf(address(acct)), 0);
    }
    function test_tokens_lost_to_a_fee_on_the_way_back_count_as_given_up() public {
        _buy(1 ether); router.setPullLess(true); tok.setFee(1000);                                    // 10% burned on every transfer; the route takes half of what arrives
        router.set(1000, 1e15, address(0));
        vm.startPrank(address(acct)); tok.approve(address(guard), 400e18);
        guard.sell(address(tok), 400e18, 1, route(address(tok), K_ETH, 360e18, address(guard)));     // 400 leave the account, 360 arrive; the route pulls 180; 180 go back as 162
        vm.stopPrank();
        (uint256 lot, uint256 cost) = guard.lotOf(address(acct), address(tok));
        assertEq(tok.balanceOf(address(acct)), 600e18 + 162e18);
        assertEq(lot, 762e18); assertEq(cost, 0.762 ether);                                          // the lot shrank by what the account gave up: 400 - 162 (M-1), and matches the balance
    }
    // ---- v16: the budget's base is the account (ETH + open lots), not the open lots alone ----
    /// The 23.10 case (cbPIGGY): an account of ~0.82 ETH holds one small position (0.04 ETH at cost); it crashes 63%. Under v15
    /// the loss (0.0255) exceeded 30% of the lot (0.0121) and the sale was refused, unlock or not; under v16 it is 3% of the account.
    function test_v16_one_small_crashed_position_on_a_cash_account_sells() public {
        vm.deal(address(acct), 0.82483 ether); _buy(0.04046 ether);                                  // 0.78437 ETH stays in the account
        (, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 0.247449 ether);         // 30% of 0.82483
        assertLt(uint256(0.04046 ether) * 3000 / 10000, uint256(0.0255 ether));                                        // what v15 measured against: 0.012138 < the loss
        router.set(1000, 3.7e14, address(0));                                                        // -63%
        uint256 out = _sell(40.46e18, 1); assertEq(out, 0.0149702 ether);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.0254898 ether);
        assertEq(guard.costOf(address(acct)), 0); assertEq(address(acct).balance, 0.7993402 ether);
    }
    /// A buy moves ETH into a lot at cost: the base does not move, whatever the bought token is worth. (Round 12 H-1 inflated a
    /// cost-only base with self-dealt buys; with the ETH in the base the same buys move value between the two terms only.)
    function test_v16_buys_do_not_move_the_base() public {
        (, uint256 b0) = guard.budgetOf(address(acct));
        router.set(1, 1e15, address(0)); _buy(3 ether);                                              // a worthless token bought for 3 ETH
        (, uint256 b1) = guard.budgetOf(address(acct)); assertEq(b1, b0); assertEq(b0, 3 ether);
        router.setRefund(0.4 ether); router.set(1000, 1e15, address(0)); _buy(1 ether);              // change returned: only what was spent moves
        (, uint256 b2) = guard.budgetOf(address(acct)); assertEq(b2, b0);
    }
    /// No high-water mark: the base is the account now. Money the owner takes out leaves the base at once, so a budget can never
    /// exceed 30% of what is still there.
    function test_v16_a_withdrawal_shrinks_the_budget_at_once() public {
        _buy(1 ether); (, uint256 b0) = guard.budgetOf(address(acct)); assertEq(b0, 3 ether);       // 1 cost + 9 ETH
        router.set(1000, 2e14, address(0));                                                          // -80%: loss 0.8
        vm.deal(address(acct), 0); (, uint256 b1) = guard.budgetOf(address(acct)); assertEq(b1, 0.3 ether);   // the owner withdrew everything but the lot
        _expectSell(1000e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.8 ether, 0.3 ether));
        vm.deal(address(acct), 9 ether); uint256 out = _sell(1000e18, 1); assertEq(out, 0.2 ether);   // back in: the same sale goes
    }
    /// A stolen executor key dumps every position at once: each loss also shrinks the base it is measured against, so the burst
    /// books at most 30% / 1.3 of the account and leaves it with at least 70%.
    function test_v16_thief_burst_is_bounded_by_the_account() public {
        vm.deal(address(acct), 10 ether); for (uint256 i = 0; i < 6; i++) _buy(1 ether);             // 6 cost + 4 ETH: base 10
        router.set(1000, 1e13, address(0));                                                          // the thief's sink pays 1%
        uint256 booked; uint256 refused;
        for (uint256 i = 0; i < 60; i++) {
            (uint256 lot, ) = guard.lotOf(address(acct), address(tok)); if (lot == 0) break;
            uint256 amt = lot < 100e18 ? lot : 100e18;
            vm.startPrank(address(acct)); tok.approve(address(guard), amt);
            try guard.sell(address(tok), amt, 1, route(address(tok), K_ETH, amt, address(guard))) { (booked, ) = guard.loss(address(acct)); } catch { refused++; amt = amt / 2; }
            vm.stopPrank(); if (refused > 8) break;
        }
        assertGt(booked, 2 ether);                                                                  // the thief did get to the bound (2.277 ETH booked)
        assertGt(refused, 0); assertLe(booked, uint256(10 ether) * 3000 / 13000 + 1);                        // <= 2.3077 ETH of 10
        assertGe(guard.costOf(address(acct)) + address(acct).balance, 10 ether - booked);            // what was not booked as a loss is still the account's
        assertGe(guard.costOf(address(acct)) + address(acct).balance, 7 ether);
    }
    /// The same thief with production limits, over two days: buy junk each hour, dump it at 1%. The budget refills over a week,
    /// so what is booked over T stays within 30% of the starting account times (1 + T / week).
    function test_v16_thief_buy_and_dump_for_two_days_is_bounded() public {
        _tight(); vm.deal(address(acct), 10 ether);
        uint256 base0 = 10 ether; uint256 booked;
        for (uint256 h = 0; h < 48; h++) {
            router.set(1000, 1e15, address(0));
            vm.prank(address(acct)); try guard.buy{value: 0.3 ether}(address(tok), 1, route(K_ETH, address(tok), 0.3 ether, address(acct))) {} catch {}
            router.set(1000, 1e13, address(0));
            (uint256 lot, ) = guard.lotOf(address(acct), address(tok));
            if (lot > 0) { (uint256 before, ) = guard.budgetOf(address(acct));
              vm.startPrank(address(acct)); tok.approve(address(guard), lot);
              try guard.sell(address(tok), lot, 1, route(address(tok), K_ETH, lot, address(guard))) { (uint256 amt, ) = guard.loss(address(acct)); booked += amt - before; } catch {}
              vm.stopPrank(); }
            vm.warp(block.timestamp + 1 hours);
        }
        assertGt(booked, 2 ether);                                                                  // and was active throughout (2.376 ETH booked)
        assertLe(booked, base0 * 3000 / 10000 * (7 days + 48 hours) / 7 days);                       // <= 3.857 ETH over 48 h
        assertGe(guard.costOf(address(acct)) + address(acct).balance + booked, base0 - 1e6);          // every wei not on the account was booked as a loss
    }
    /// unlock() clears what is outstanding; it never raises the budget itself (the 23.10 case could not be helped by it).
    function test_v16_unlock_clears_losses_but_not_the_rule() public {
        vm.deal(address(acct), 1 ether); _buy(1 ether); router.set(1000, 1e14, address(0));          // all in, -90%
        _expectSell(1000e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.9 ether, 0.3 ether));
        address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); guard.unlock(a);
        _expectSell(1000e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.9 ether, 0.3 ether));
        uint256 out = _exit(1000e18); assertEq(out, 0.1 ether);                                      // the cold key's exit is the remedy for an all-in account
    }

    // ---- v17 (round 15): every lot reconciled before the base is read; ETH that came back to the account is not cost ----
    function _buyT(MockToken t, uint256 eth) internal returns (uint256) { vm.prank(address(acct)); return guard.buy{value: eth}(address(t), 1, route(K_ETH, address(t), eth, address(acct))); }
    function _sellT(MockToken t, uint256 amount, uint256 minOut) internal returns (uint256 out) {
        vm.startPrank(address(acct)); t.approve(address(guard), amount);
        out = guard.sell(address(t), amount, minOut, route(address(t), K_ETH, amount, address(guard))); vm.stopPrank(); }
    function _expectSellT(MockToken t, uint256 amount, bytes memory err) internal {
        vm.startPrank(address(acct)); t.approve(address(guard), amount); vm.expectRevert(err);
        guard.sell(address(t), amount, 1, route(address(t), K_ETH, amount, address(guard))); vm.stopPrank(); }
    function _exitT(MockToken t, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(address(acct), cold); t.approve(address(guard), amount);
        out = guard.exit(address(t), amount, 1, route(address(t), K_ETH, amount, address(guard))); vm.stopPrank(); }
    function _sumLots() internal view returns (uint256 c) { address[] memory l = guard.lotsOf(address(acct)); for (uint256 i = 0; i < l.length; i++) { (, uint256 e) = guard.basis(address(acct), l[i]); c += e; } }
    function _listed(address t) internal view returns (bool) { address[] memory l = guard.lotsOf(address(acct)); for (uint256 i = 0; i < l.length; i++) if (l[i] == t) return true; return false; }

    /// Round 15, H: lot A (0.20) was withdrawn by the owner, lot B (0.02) is all the account has. v16 kept A's 0.20 in the base
    /// (only the traded token was reconciled) and let a stolen key dump B for 1 wei (loss 0.02 within 30% of 0.22).
    function test_v17_stale_cost_of_a_withdrawn_lot_cannot_fund_a_dump() public {
        MockToken b = new MockToken(); vm.deal(address(acct), 0.22 ether);
        _buy(0.2 ether);                                                                             // A: 200 tokens at 0.20
        router.set(50, 1e15, address(0)); _buyT(b, 0.02 ether);                                      // B: 1 token at 0.02; no ETH left
        vm.prank(address(acct)); tok.transfer(address(0xdead), 200e18);                              // the owner withdraws all of A
        (, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 0.006 ether);            // 30% of B alone (v16 quoted 0.066)
        router.set(50, 1, address(0));                                                               // the thief's sink: 1 wei for all of B
        _expectSellT(b, 1e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.02 ether - 1, 0.006 ether));
        assertEq(guard.costOf(address(acct)), 0.22 ether);                                          // refused: nothing written
    }
    function test_v17_partial_withdrawal_of_another_lot_shrinks_the_base() public {
        MockToken b = new MockToken(); vm.deal(address(acct), 0.22 ether);
        _buy(0.2 ether); router.set(50, 1e15, address(0)); _buyT(b, 0.02 ether);
        vm.prank(address(acct)); tok.transfer(address(0xdead), 180e18);                              // 90% of A out: A now carries 0.02
        (, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 0.012 ether);            // 30% of (0.02 + 0.02)
        router.set(50, 1, address(0));
        _expectSellT(b, 1e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.02 ether - 1, 0.012 ether));
        router.set(50, 0.02 ether, address(0)); assertEq(_sellT(b, 1e18, 1), 0.02 ether);            // at cost it goes, and the sale writes A's reconciliation
        (uint256 ta, uint256 ea) = guard.basis(address(acct), address(tok)); assertEq(ta, 20e18); assertEq(ea, 0.02 ether);
        assertEq(guard.costOf(address(acct)), 0.02 ether); assertEq(guard.lotsOf(address(acct)).length, 1);
    }
    /// v15 finding "reversible purchases manufacture allowance" (lot A 0.04, 0.20 cash; buy B 0.20; sell A for 0.001; sell B for
    /// 0.199). Under v15 the buy of B raised the base from 0.04 to 0.24 and so admitted the A sale. Since v16 the cash is in the base
    /// already and the buy moves it into a lot: the budget is the same with or without step 1, and so is the verdict on the A sale.
    function test_v17_reversible_purchase_manufactures_no_allowance() public {
        MockToken b = new MockToken(); vm.deal(address(acct), 0.24 ether);
        _buy(0.04 ether);                                                                            // A: 40 tokens at 0.04; 0.20 cash
        (, uint256 b0) = guard.budgetOf(address(acct)); assertEq(b0, 0.072 ether);
        uint256 snap = vm.snapshotState();
        _buyT(b, 0.2 ether); (, uint256 b1) = guard.budgetOf(address(acct)); assertEq(b1, b0);        // step 1 moves nothing
        router.set(1000, 2.5e13, address(0)); assertEq(_sell(40e18, 1), 0.001 ether);                // step 2: loss 0.039
        (uint256 l2, ) = guard.loss(address(acct)); assertEq(l2, 0.039 ether);
        router.set(1000, 9.95e14, address(0)); assertEq(_sellT(b, 200e18, 1), 0.199 ether);          // step 3: loss 0.001
        (uint256 l3, ) = guard.loss(address(acct)); assertEq(l3, 0.04 ether);                         // 16.7% of the 0.24 account, all of it real loss
        vm.revertToState(snap);                                                                      // without step 1
        router.set(1000, 2.5e13, address(0)); assertEq(_sell(40e18, 1), 0.001 ether);
        (uint256 l2b, ) = guard.loss(address(acct)); assertEq(l2b, l2);                               // the same sale, the same verdict
        vm.revertToState(snap); vm.deal(address(acct), 0); router.set(1000, 2.5e13, address(0));     // the A sale is refused only when the cash is not the account's
        _expectSell(40e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.039 ether, 0.012 ether));
    }
    /// Round 15, M: ETH paid straight back to the account during a buy was counted as spent (only the gate's balance was measured).
    function test_v17_eth_returned_to_the_account_during_a_buy_is_not_cost() public {
        router.setKickback(address(acct), 1 ether);                                                  // the whole input comes back past the gate
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.ZeroAmount.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
        router.setKickback(address(acct), 0.4 ether); _buy(1 ether);                                 // 0.4 of 1 comes back
        (, uint256 e1) = guard.basis(address(acct), address(tok)); assertEq(e1, 0.6 ether); assertEq(address(acct).balance, 9.4 ether);
        (, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 3 ether);                 // the base did not move
        router.setRefund(0.3 ether); router.setKickback(address(acct), 0.2 ether); _buy(1 ether);    // change through the gate AND past it: each counted once
        (, uint256 e2) = guard.basis(address(acct), address(tok)); assertEq(e2, 1.1 ether); assertEq(address(acct).balance, 8.9 ether);
        (, , uint128 buyEth, ) = guard.window(address(acct)); assertEq(buyEth, 1.1 ether);           // the hourly cap counts the net spend too
        (, budget) = guard.budgetOf(address(acct)); assertEq(budget, 3 ether);
    }
    function test_v17_eth_refunded_by_the_token_transfer_is_not_cost() public {
        RefundingToken r = new RefundingToken(); vm.deal(address(r), 2 ether); r.setRefund(address(acct), 0.25 ether);
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(r), 1, route(K_ETH, address(r), 1 ether, address(guard)));   // paid to the gate; the sweep to the account pays 0.25 back
        (uint256 t1, uint256 e1) = guard.basis(address(acct), address(r)); assertEq(t1, 1000e18); assertEq(e1, 0.75 ether);
        r.setRefund(address(acct), 1 ether); vm.prank(address(acct)); vm.expectRevert(GuardedSwap.ZeroAmount.selector);
        guard.buy{value: 1 ether}(address(r), 1, route(K_ETH, address(r), 1 ether, address(guard)));
    }
    /// Round 15, L: floorFor quoted the base before reconciliation. It now quotes exactly the threshold the sale enforces.
    function test_v17_floorFor_is_the_threshold_the_sale_enforces() public {
        MockToken b = new MockToken(); vm.deal(address(acct), 1.2 ether);
        _buy(1 ether); _buyT(b, 0.2 ether);                                                          // A 1000 at 1.0, B 200 at 0.2, no ETH
        vm.prank(address(acct)); tok.transfer(address(0xdead), 600e18);                              // A now carries 0.4: base 0.6, budget 0.18
        uint256 floor = guard.floorFor(address(acct), address(b), 200e18); assertEq(floor, 0.02 ether);
        uint256 px = floor * 1e18 / 200e18;
        router.set(1000, px - 1, address(0));                                                        // 200 wei under the quote
        _expectSellT(b, 200e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.18 ether + 200, 0.18 ether));
        router.set(1000, px, address(0)); assertEq(_sellT(b, 200e18, 1), floor);                     // at the quote it goes
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.18 ether);
    }
    function test_v17_open_lots_are_capped_and_an_emptied_lot_frees_its_slot() public {
        uint256 n = guard.MAX_LOTS(); assertEq(n, 32); MockToken[] memory ts = new MockToken[](n + 1);
        for (uint256 i = 0; i <= n; i++) ts[i] = new MockToken();
        for (uint256 i = 0; i < n; i++) _buyT(ts[i], 0.001 ether);
        assertEq(guard.lotsOf(address(acct)).length, n);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.TooManyLots.selector);
        guard.buy{value: 0.001 ether}(address(ts[n]), 1, route(K_ETH, address(ts[n]), 0.001 ether, address(acct)));
        _buyT(ts[0], 0.001 ether);                                                                   // more of an open lot takes no new slot
        vm.prank(address(acct)); ts[5].transfer(address(0xdead), 1e18);                              // the owner empties one lot
        _buyT(ts[n], 0.001 ether);                                                                   // the buy reconciles first: the slot is free
        assertEq(guard.lotsOf(address(acct)).length, n); assertFalse(_listed(address(ts[5]))); assertTrue(_listed(address(ts[n])));
        assertEq(guard.costOf(address(acct)), 0.033 ether); assertEq(_sumLots(), 0.033 ether);
        for (uint256 i = 0; i <= n; i++) vm.cool(address(ts[i])); vm.cool(address(guard)); vm.cool(address(acct));   // as in a fresh transaction
        uint256 g0 = gasleft(); _sellT(ts[1], 1e18, 1); uint256 used = g0 - gasleft();               // a sale walks all 32 lots
        assertLt(used, 800_000); emit log_named_uint("sale with 32 open lots, gas", used);
    }
    function test_v17_a_lot_that_will_not_answer_does_not_block_the_others() public {
        MockToken b = new MockToken(); MockToken c = new MockToken();
        _buy(1 ether); _buyT(b, 1 ether); _buyT(c, 1 ether);
        tok.setBricked(address(acct), true);                                                         // A's balanceOf reverts for the account
        c.setBurnsGas(true);                                                                         // C's burns every unit of gas it is given
        uint256 g0 = gasleft(); assertEq(_sellT(b, 500e18, 1), 0.5 ether); uint256 used = g0 - gasleft();
        assertLt(used, 600_000);                                                                     // each unreadable lot costs at most BALANCE_GAS
        assertEq(guard.costOf(address(acct)), 2.5 ether);                                            // A and C keep their last cost (documented residual)
        (, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, (2.5 ether + 7.5 ether) * 3000 / 10000);   // the views answer too
        assertEq(_exitT(b, 500e18), 0.5 ether); assertFalse(_listed(address(b)));                   // and the cold key's exit
    }
    function test_v17_registry_follows_the_lots() public {
        MockToken b = new MockToken();
        _buy(1 ether); assertTrue(_listed(address(tok)));
        _sell(400e18, 1); assertTrue(_listed(address(tok)));                                         // a partial sale keeps the lot
        _buyT(b, 1 ether); assertEq(guard.lotsOf(address(acct)).length, 2);
        _sell(600e18, 1); assertFalse(_listed(address(tok))); assertEq(guard.costOf(address(acct)), _sumLots());   // a full sale closes it
        _buy(1 ether); assertTrue(_listed(address(tok)));
        vm.prank(address(acct)); tok.transfer(address(0xdead), 1000e18);                             // emptied by the owner: listed until a call reconciles
        assertTrue(_listed(address(tok))); (uint256 lt, ) = guard.lotOf(address(acct), address(tok)); assertEq(lt, 0);
        assertEq(_exitT(b, 400e18), 0.4 ether);                                                      // the exit reconciles every lot too
        assertFalse(_listed(address(tok))); assertTrue(_listed(address(b)));
        assertEq(guard.costOf(address(acct)), 0.6 ether); assertEq(_sumLots(), 0.6 ether);
        assertEq(_exitT(b, 600e18), 0.6 ether); assertEq(guard.lotsOf(address(acct)).length, 0); assertEq(guard.costOf(address(acct)), 0);
    }

    function test_constructor_refuses_itself_as_router_or_executor() public {
        address self_ = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("self")); new GuardedSwap(self_, exec, address(this), cold, 12, 0.3 ether, 1 ether);
        self_ = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("self")); new GuardedSwap(address(router), self_, address(this), cold, 12, 0.3 ether, 1 ether);
    }
}
