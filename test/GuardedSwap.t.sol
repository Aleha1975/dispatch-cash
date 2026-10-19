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
    function test_losses_accumulate_up_to_30_percent_of_cost_then_block() public {
        _buy(1 ether);                                                                               // cost 1 ETH, budget 0.3 ETH
        router.set(1000, 5e14, address(0)); uint256 out = _sell(400e18, 1); assertEq(out, 0.2 ether); // cost 0.4, got 0.2: loss 0.2
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.2 ether); assertEq(budget, 0.18 ether);   // budget is 30% of what is left (0.6)
        // the next losing sale: cost 0.3, got 0.15 -> loss 0.15, total 0.35 > budget (30% of 0.6 = 0.18) -> refused
        _expectSell(300e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.35 ether, 0.18 ether));
        router.set(1000, 1e15, address(0)); out = _sell(300e18, 1); assertEq(out, 0.3 ether);        // selling at cost still goes
        router.set(1000, 2e15, address(0)); out = _sell(300e18, 1); assertEq(out, 0.6 ether);        // and above cost
    }
    function test_a_single_crash_is_inside_the_budget() public {
        vm.deal(address(acct), 20 ether); for (uint256 i = 0; i < 12; i++) _buy(1 ether);              // 12 ETH of cost
        router.set(1000, 5e13, address(0));                                                          // -95%
        uint256 out = _sell(1000e18, 1); assertEq(out, 0.05 ether);                                  // one position (1/12 of cost) dumped: loss 0.95 of a 3.6 budget
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.95 ether); assertEq(budget, 3.3 ether);
    }
    function test_budget_refills_linearly_over_a_week() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);                         // loss 0.25 of cost 1 -> budget now 30% of 0.5 = 0.15, lost 0.25 (over, as the base shrank)
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 0.3 ether, 0.15 ether));
        vm.warp(block.timestamp + 3.5 days);                                                         // half a week at the 0.3/week rate booked with the loss: 0.15 of room came back
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.1 ether);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);   // a loss never outlives REFILL at the rate it was booked with
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
    }
    function test_unlock_only_by_the_cold_key() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);
        address[] memory a = new address[](1); a[0] = address(acct);
        vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.unlock(a);                          // not the guardian (this test contract)
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.unlock(a);  // not the account
        vm.prank(address(acct), cold); guard.unlock(a);                                                  // (round 12, L-1) the key as transaction origin through a contract: accepted, like exit()
        vm.prank(cold, cold); guard.unlock(a);
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
        address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold, cold); guard.unlock(a);
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
        _buy(1 ether); assertEq(guard.floorFor(address(acct), address(tok), 1000e18), 0.7 ether);     // cost 1, room 0.3: may return 0.7
        router.set(1000, 5e14, address(0)); _sell(400e18, 1);                                        // loss 0.2; cost left 0.6, budget 0.18, room 0
        assertEq(guard.floorFor(address(acct), address(tok), 100e18), 0.1 ether);                     // no room: a sale must return its full cost
    }
    function testFuzz_cost_tracks_sales(uint96 price, uint8 fracBps) public {
        vm.assume(price > 1e9 && price < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;
        router.set(1000, price, address(0)); _buy(1 ether);
        uint256 sellAmt = 1000e18 * frac / 100; uint256 expectOut = sellAmt * price / 1e18; uint256 cost = 1 ether * sellAmt / 1000e18;
        uint256 lossIf = expectOut < cost ? cost - expectOut : 0;
        if (lossIf <= 0.3 ether) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18 - sellAmt); assertEq(ethIn, tokens == 0 ? 0 : 1 ether - cost);
            (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, lossIf); }
        else _expectSell(sellAmt, abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, lossIf, (1 ether) * 3000 / 10000));
    }

    // ---- round 11 (v13) ----
    function test_refill_speed_is_fixed_when_the_loss_is_booked() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);                         // loss 0.25 booked at rate 0.3/week
        vm.deal(address(acct), 20 ether); router.set(1000, 1e15, address(0)); for (uint256 i = 0; i < 10; i++) _buy(1 ether);   // +10 ETH of cost: budget is now 3.15
        vm.warp(block.timestamp + 3.5 days);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 3.15 ether);
        assertEq(lost, 0.1 ether);                                                                   // 0.25 - 0.15: the new capital did not speed the refill (C-1 mechanism B)
    }
    function test_a_loss_keeps_fading_after_the_lot_is_closed() public {
        _buy(1 ether); router.set(1000, 7e14, address(0)); _sell(1000e18, 1);                        // full exit at -30%: loss 0.3 == budget, lot closed, cost basis 0
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.3 ether); assertEq(budget, 0);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.15 ether);   // fades at the booked 0.3/week although costOf is 0 (C-1 mechanism D)
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_refill_speed_never_rises_while_a_loss_is_outstanding() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(400e18, 1);                         // loss 0.2 at rate 0.3
        vm.deal(address(acct), 20 ether); router.set(1000, 1e15, address(0)); for (uint256 i = 0; i < 10; i++) _buy(1 ether);   // cost 10.6, budget 3.18
        router.set(1000, 5e14, address(0)); _sell(100e18, 1);                                        // a small new loss (0.05) while 0.2 is outstanding
        (, uint256 rate, ) = guard.loss(address(acct)); assertEq(rate, 0.3 ether);                   // the rate stayed 0.3, not 3.18
        vm.warp(block.timestamp + 3.5 days); (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.1 ether);   // 0.25 - 0.15
        // once the record is clean, a new loss books at the current (larger) budget
        vm.warp(block.timestamp + 3.5 days); router.set(1000, 5e14, address(0)); _sell(100e18, 1);
        (, rate, ) = guard.loss(address(acct)); assertGt(rate, 3 ether);
    }
    function test_refill_speed_follows_a_shrinking_budget() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(400e18, 1);                         // loss 0.2 at rate 0.3 (cost 0.6 left)
        router.set(1000, 1e15, address(0)); _sell(500e18, 1);                                        // at cost: 0.1 of cost left, budget 0.03
        vm.warp(block.timestamp + 4.5 days);                                                         // the 0.2 loss has faded to 0.007 at the 0.3/week rate
        router.set(1000, 5e14, address(0)); _sell(10e18, 1);                                         // a new small loss (0.005): rate drops to today's budget
        (, uint256 rate, ) = guard.loss(address(acct)); assertLt(rate, 0.3 ether); assertEq(rate, 0.03 ether);
    }
    function test_buy_refuses_a_token_that_hides_the_account_balance() public {
        tok.setBricked(address(acct), true);
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));   // (round 12, L-2) a clean refusal, not a bare revert
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
    function test_constructor_refuses_itself_as_router_or_executor() public {
        address self_ = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("self")); new GuardedSwap(self_, exec, address(this), cold, 12, 0.3 ether, 1 ether);
        self_ = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("self")); new GuardedSwap(address(router), self_, address(this), cold, 12, 0.3 ether, 1 ether);
    }
}
