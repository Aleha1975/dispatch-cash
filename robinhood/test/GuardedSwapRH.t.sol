// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwapRH.sol";
import "./Mocks.sol";

/// v15's unit suite, ported: the same scenarios and numbers, with structured hops in place of Kyber calldata. Tests marked
/// (RH) are new: the route rule, the encoding the gate sends, the factory check, WETH-paid sales.
contract GuardedSwapRHTest is Test {
    address constant NATIVE = address(0);
    MockToken tok; MockToken weth; MockRouterRH router; MockFactory fac; MockFactory facTick; GuardedSwapRH guard; Wallet acct; address pm;
    address thief = address(0x1111111111111111111111111111111111111111);
    address cold = address(0xC01D);
    address pool = address(0xB001);                    // a v3 pool the factory knows (WETH/tok, fee 10000)
    function _deploy(uint256 sells, uint256 buyEth, uint256 sellEth) internal returns (GuardedSwapRH) {
        address[] memory f = new address[](2); f[0] = address(fac); f[1] = address(facTick);
        bool[] memory k = new bool[](2); k[1] = true;
        return new GuardedSwapRH(address(router), address(weth), pm, f, k, address(this), cold, sells, buyEth, sellEth);
    }
    function setUp() public {
        tok = new MockToken(); weth = new MockToken(); pm = address(new Wallet()); router = new MockRouterRH(address(weth), pm);
        fac = new MockFactory(); facTick = new MockFactory(); fac.set(address(weth), address(tok), 10000, pool);
        guard = _deploy(1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(router), 100 ether); vm.deal(address(acct), 10 ether);
        router.set(1000, 1e15, address(0));          // 1 ETH -> 1000 tokens; 1 token -> 0.001 ETH (entry price)
    }
    // ---- hop builders ----
    function v4(address tin, address tout) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 2; h.tokenIn = tin; h.tokenOut = tout; h.fee = 3000; h.tickSpacing = 60; }
    function v3(address tin, address tout, address p, uint24 fee) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 1; h.tokenIn = tin; h.tokenOut = tout; h.pool = p; h.fee = fee; h.tickSpacing = 200; }
    function one(GuardedSwapRH.Hop memory a) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](1); h[0] = a; }
    function two(GuardedSwapRH.Hop memory a, GuardedSwapRH.Hop memory b) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](2); h[0] = a; h[1] = b; }
    function buyRoute() internal view returns (GuardedSwapRH.Hop[] memory) { return one(v4(NATIVE, address(tok))); }
    function sellRoute() internal view returns (GuardedSwapRH.Hop[] memory) { return one(v4(address(tok), NATIVE)); }
    function _buy(uint256 eth) internal returns (uint256) { vm.prank(address(acct)); return guard.buy{value: eth}(address(tok), 1, buyRoute()); }
    function _sell(uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount);
        uint256 out = guard.sell(address(tok), amount, minOut, sellRoute()); vm.stopPrank(); return out; }
    function _expectSell(uint256 amount, bytes memory err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount); vm.expectRevert(err);
        guard.sell(address(tok), amount, 1, sellRoute()); vm.stopPrank(); }
    function _expectSellRoute(GuardedSwapRH.Hop[] memory h, bytes4 err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18); vm.expectRevert(err);
        guard.sell(address(tok), 10e18, 1, h); vm.stopPrank(); }
    function _expectBuyRoute(GuardedSwapRH.Hop[] memory h, bytes4 err) internal {
        vm.prank(address(acct)); vm.expectRevert(err); guard.buy{value: 1 ether}(address(tok), 1, h); }
    function _exit(uint256 amount) internal returns (uint256) {
        vm.startPrank(address(acct), cold); tok.approve(address(guard), amount);
        uint256 out = guard.exit(address(tok), amount, 1, sellRoute()); vm.stopPrank(); return out; }

    // ---- recipient rule ----
    function test_buy_pays_caller_and_records_lot() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);   // paid to the gate by the router, forwarded
        (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18); assertEq(ethIn, 1 ether); assertEq(guard.costOf(address(acct)), 1 ether);
    }
    /// (RH) the gate, not the executor, writes the router call: recipient zero, amount = what it holds, PoolManager pinned, no hook data
    function test_the_gate_encodes_the_router_call_itself() public {
        GuardedSwapRH.Hop memory h = v4(NATIVE, address(tok)); h.hooks = address(0x4004);
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 7, one(h));
        assertEq(router.lastN(), 1); assertEq(router.lastRecipient(), address(0)); assertEq(router.lastAmountIn(), 1 ether); assertEq(router.lastValue(), 1 ether);
        assertEq(router.lastMinOut(), 7); assertEq(router.lastDeadline(), block.timestamp);
        GuardedSwapRH.RouterHop memory r = router.lastHop(0);
        assertEq(r.version, 2); assertEq(r.poolManager, pm); assertEq(r.hookData.length, 0); assertEq(r.extra, bytes32(0)); assertEq(r.hooks, address(0x4004)); assertEq(r.pool, address(0));
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        guard.sell(address(tok), 100e18, 1, one(v3(address(tok), address(weth), pool, 10000))); vm.stopPrank();
        r = router.lastHop(0); assertEq(r.version, 1); assertEq(r.poolManager, address(0)); assertEq(r.pool, pool); assertEq(router.lastAmountIn(), 100e18); assertEq(router.lastValue(), 0);
        assertEq(tok.allowance(address(guard), address(router)), 0);                                  // no allowance outlives the call
    }
    function test_router_paying_elsewhere_reverts() public {
        router.set(1000, 1e15, thief);
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.BelowMinOut.selector, 0, 1));
        guard.buy{value: 1 ether}(address(tok), 1, buyRoute());
        router.set(1000, 1e15, address(0)); _buy(1 ether); router.set(1000, 1e15, thief);
        _expectSell(500e18, abi.encodeWithSelector(GuardedSwapRH.BelowMinOut.selector, 0, 1));
        assertEq(tok.balanceOf(thief), 0);
    }
    /// (RH) a sale the router pays in WETH instead of native ETH is refused (the WETH would be stranded here)
    function test_sale_paid_in_weth_refused() public {
        _buy(1 ether); router.setPayWeth(true);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.BadRoute.selector));
    }

    // ---- route rule (RH) ----
    function test_buy_route_rules() public {
        GuardedSwapRH.Hop[] memory none = new GuardedSwapRH.Hop[](0);
        _expectBuyRoute(none, GuardedSwapRH.BadRoute.selector);                                                     // no hops
        GuardedSwapRH.Hop[] memory four = new GuardedSwapRH.Hop[](4);
        four[0] = v4(NATIVE, address(0xA1)); four[1] = v4(address(0xA1), address(0xA2)); four[2] = v4(address(0xA2), address(0xA3)); four[3] = v4(address(0xA3), address(tok));
        _expectBuyRoute(four, GuardedSwapRH.BadRoute.selector);                                                     // more than MAX_HOPS
        _expectBuyRoute(one(v4(address(0xA1), address(tok))), GuardedSwapRH.BadRoute.selector);                      // does not start at the ETH side
        _expectBuyRoute(one(v4(NATIVE, address(0xA1))), GuardedSwapRH.BadRoute.selector);                            // does not end at the token
        _expectBuyRoute(two(v4(NATIVE, address(0xA1)), v4(address(0xA2), address(tok))), GuardedSwapRH.BadRoute.selector);   // broken chain
        _expectBuyRoute(two(v4(NATIVE, address(weth)), v4(address(weth), address(tok))), GuardedSwapRH.BadRoute.selector);    // ETH side in the middle
        _expectBuyRoute(two(v4(NATIVE, address(tok)), v4(address(tok), address(tok))), GuardedSwapRH.BadRoute.selector);      // through the traded token
        GuardedSwapRH.Hop memory h = v4(NATIVE, address(tok));
        for (uint8 v = 0; v <= 5; v++) { if (v == 1 || v == 2) continue; h.version = v; _expectBuyRoute(one(h), GuardedSwapRH.BadRoute.selector); }   // only versions 1 and 2 (4 = Virtuals path on the live router)
        h = v4(NATIVE, address(tok)); h.pool = address(0xB001); _expectBuyRoute(one(h), GuardedSwapRH.BadRoute.selector);                          // v4 hop naming a pool
        GuardedSwapRH.Hop memory x = v3(address(weth), address(tok), pool, 10000); x.hooks = address(0x4004); _expectBuyRoute(one(x), GuardedSwapRH.BadRoute.selector);   // v3 hop naming hooks
        _expectBuyRoute(one(v3(NATIVE, address(tok), pool, 10000)), GuardedSwapRH.BadRoute.selector);                // v3 pools hold WETH, not native
        _expectBuyRoute(one(v3(address(weth), address(tok), address(0xBAD), 10000)), GuardedSwapRH.BadRoute.selector);   // a pool no allowed factory knows
        _expectBuyRoute(one(v3(address(weth), address(tok), pool, 3000)), GuardedSwapRH.BadRoute.selector);           // the right pool under the wrong key
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.BadRoute.selector); guard.buy{value: 1 ether}(address(weth), 1, one(v4(NATIVE, address(weth))));   // WETH is not a position
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, one(v3(address(weth), address(tok), pool, 10000))); assertEq(out, 1000e18);   // the factory's pool passes
    }
    function test_tick_keyed_factory_and_multi_hop() public {
        address usd = address(new MockToken()); address p2 = address(0xB002);
        facTick.set(usd, address(tok), 50, p2);                                                                      // Slipstream-style: keyed by tick spacing
        GuardedSwapRH.Hop[] memory h = two(v3(address(weth), usd, pool, 10000), v3(usd, address(tok), p2, 50));
        _expectBuyRoute(h, GuardedSwapRH.BadRoute.selector);                                                         // hop 0: pool is not WETH/usd on any factory
        fac.set(address(weth), usd, 100, address(0xB003));
        h[0] = v3(address(weth), usd, address(0xB003), 100);
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, h); assertEq(out, 1000e18);
        h[1].pool = address(0xB003); _expectBuyRoute(h, GuardedSwapRH.BadRoute.selector);                          // a known pool for the wrong pair
        GuardedSwapRH.Hop[] memory three = new GuardedSwapRH.Hop[](3);
        three[0] = v3(address(weth), usd, address(0xB003), 100); three[1] = v4(usd, address(0xA1)); three[2] = v4(address(0xA1), address(tok));
        vm.prank(address(acct)); out = guard.buy{value: 1 ether}(address(tok), 1, three); assertEq(out, 1000e18);   // v3 -> v4 -> v4, as live routes run
    }
    function test_sale_route_rules() public {
        _buy(1 ether);
        _expectSellRoute(one(v4(NATIVE, address(tok))), GuardedSwapRH.BadRoute.selector);                            // a buy route
        _expectSellRoute(one(v4(address(tok), address(0xA1))), GuardedSwapRH.BadRoute.selector);                     // does not end at the ETH side (the output would land here, stranded)
        _expectSellRoute(one(v4(address(0xA1), NATIVE)), GuardedSwapRH.BadRoute.selector);                           // does not start at the token
        _expectSellRoute(one(v3(address(tok), address(weth), address(0xBAD), 10000)), GuardedSwapRH.BadRoute.selector);   // unknown pool
        _expectSellRoute(two(v4(address(tok), address(weth)), v4(address(weth), NATIVE)), GuardedSwapRH.BadRoute.selector);   // ETH side in the middle
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18);
        uint256 out = guard.sell(address(tok), 10e18, 1, one(v3(address(tok), address(weth), pool, 10000))); vm.stopPrank(); assertEq(out, 0.01 ether);   // ending in WETH is paid native
        assertEq(tok.balanceOf(address(acct)), 990e18);
    }
    function test_minOut_zero_and_non_contract_token() public {
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwapRH.MinOutZero.selector); guard.buy{value: 1 ether}(address(tok), 0, buyRoute());
        vm.expectRevert(GuardedSwapRH.NotAContract.selector); guard.buy{value: 1 ether}(thief, 1, one(v4(NATIVE, thief)));
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
        router.setRefund(1 ether); vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.ZeroAmount.selector);
        guard.buy{value: 1 ether}(address(tok), 1, buyRoute());
        router.setRefund(0); router.setOverpay(1 wei); vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RouterOverpaid.selector);
        guard.buy{value: 1 ether}(address(tok), 1, buyRoute());
    }
    function test_state_is_final_before_eth_leaves() public {
        SpyWallet spy = new SpyWallet(); spy.set(guard, address(tok)); vm.deal(address(spy), 2 ether); router.setRefund(0.1 ether);
        uint256 out = spy.buy(1 ether, 1, buyRoute());
        assertEq(spy.hooks(), 1); assertEq(spy.seenTokens(), out);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(spy), address(tok)); assertEq(tokens, out); assertEq(ethIn, 0.9 ether);
        router.setRefund(0); spy.sell(100e18, 1, sellRoute());
        assertEq(spy.hooks(), 2); assertEq(spy.seenTokens(), out - 100e18);
    }
    function test_reentrancy_blocked() public { router.setReenter(address(guard)); _buy(1 ether); assertFalse(router.reenterOk()); }
    function test_guard_keeps_nothing() public { _buy(1 ether); _sell(100e18, 1); assertEq(address(guard).balance, 0); assertEq(tok.balanceOf(address(guard)), 0); assertEq(tok.allowance(address(guard), address(router)), 0); }

    // ---- only the lot ----
    function test_only_the_lot_is_for_sale() public {
        tok.mint(address(acct), 100e18);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 0, 100e18));
        _buy(1 ether);
        _expectSell(1100e18, abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 1000e18, 1100e18));
        assertEq(tok.balanceOf(address(acct)), 1100e18);
    }
    function test_tokens_the_owner_moved_out_leave_the_lot_pro_rata() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 700e18);
        (uint256 tokens, uint256 ethIn) = guard.lotOf(address(acct), address(tok)); assertEq(tokens, 300e18); assertEq(ethIn, 0.3 ether);
        _expectSell(1000e18, abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 300e18, 1000e18));
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
        uint256 out = guard.sell(address(tok), 1000e18, 1, sellRoute()); vm.stopPrank();   // 900 arrive; the gate sells what arrived
        assertEq(out, 0.9 ether); (uint256 tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0); assertEq(guard.costOf(address(acct)), 0);
        assertEq(router.lastAmountIn(), 900e18);
    }
    function test_a_sale_that_moves_nothing_is_refused() public {
        _buy(1 ether); router.setPullNone(true);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.ZeroAmount.selector));
        (, uint64 sells,,) = guard.window(address(acct)); assertEq(sells, 0);
    }
    function test_zero_first_token_with_a_leftover_allowance_still_sells() public {
        _buy(1 ether); tok.setZeroFirst(true); router.setPullLess(true); tok.setRevertOnZeroApprove(true);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether); assertGt(tok.allowance(address(guard), address(router)), 0);   // the route took half; half came back
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.TransferFailed.selector));
        tok.setRevertOnZeroApprove(false); vm.prank(address(acct)); tok.approve(address(guard), 0);
        out = _sell(100e18, 1); assertEq(out, 0.1 ether);
    }

    // ---- loss budget (numbers identical to v15) ----
    function test_profit_and_at_cost_sales_never_touch_the_budget() public {
        _buy(1 ether); router.set(1000, 2e15, address(0)); _sell(500e18, 1);
        router.set(1000, 1e15, address(0)); _sell(500e18, 1);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_losses_accumulate_up_to_30_percent_of_cost_then_block() public {
        _buy(1 ether);
        router.set(1000, 5e14, address(0)); uint256 out = _sell(400e18, 1); assertEq(out, 0.2 ether);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.2 ether); assertEq(budget, 0.18 ether);
        _expectSell(300e18, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, 0.35 ether, 0.18 ether));
        router.set(1000, 1e15, address(0)); out = _sell(300e18, 1); assertEq(out, 0.3 ether);
        router.set(1000, 2e15, address(0)); out = _sell(300e18, 1); assertEq(out, 0.6 ether);
    }
    function test_a_single_crash_is_inside_the_budget() public {
        vm.deal(address(acct), 20 ether); for (uint256 i = 0; i < 12; i++) _buy(1 ether);
        router.set(1000, 5e13, address(0));
        uint256 out = _sell(1000e18, 1); assertEq(out, 0.05 ether);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.95 ether); assertEq(budget, 3.3 ether);
    }
    function test_budget_refills_linearly_over_a_week() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, 0.3 ether, 0.15 ether));
        vm.warp(block.timestamp + 3.5 days);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.125 ether);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
    }
    function test_unlock_only_by_the_cold_key() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);
        address[] memory a = new address[](1); a[0] = address(acct);
        vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.unlock(a);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.unlock(a);
        vm.prank(address(acct), cold); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.unlock(a);
        vm.prank(cold); guard.unlock(a);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
        address[] memory many = new address[](65); vm.prank(cold); vm.expectRevert(GuardedSwapRH.TooLarge.selector); guard.unlock(many);
    }

    // ---- exit ----
    function test_exit_only_when_the_cold_key_sent_the_transaction() public {
        _buy(1 ether); router.set(1000, 1e14, address(0));
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18); vm.expectRevert(GuardedSwapRH.NotExitKey.selector);
        guard.exit(address(tok), 1000e18, 1, sellRoute()); vm.stopPrank();
        vm.startPrank(address(acct), thief); vm.expectRevert(GuardedSwapRH.NotExitKey.selector);
        guard.exit(address(tok), 1000e18, 1, sellRoute()); vm.stopPrank();
        uint256 out = _exit(1000e18); assertEq(out, 0.1 ether);
        assertEq(address(acct).balance, 9.1 ether); (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        (uint256 tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0); assertEq(guard.costOf(address(acct)), 0);
    }
    function test_exit_ignores_hourly_limits_but_not_the_route_rules() public {
        guard = _deploy(1, 1000 ether, 0.01 ether);
        _buy(1 ether); _sell(10e18, 1);
        _expectSell(10e18, abi.encodeWithSelector(GuardedSwapRH.RateLimited.selector));
        uint256 out = _exit(500e18); assertEq(out, 0.5 ether);
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwapRH.BadRoute.selector);
        guard.exit(address(tok), 100e18, 1, one(v4(address(tok), address(0xA1)))); vm.stopPrank();   // it can only ever end in ETH paid to the account
        router.set(1000, 1e15, thief);
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 100e18); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.BelowMinOut.selector, 0, 1));
        guard.exit(address(tok), 100e18, 1, sellRoute()); vm.stopPrank();
        router.set(1000, 1e15, address(0));
        vm.startPrank(address(acct), cold); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 490e18, 1000e18));
        guard.exit(address(tok), 1000e18, 1, sellRoute()); vm.stopPrank();
    }

    // ---- pause, limits, guardian ----
    function test_pause_stops_the_executor_not_the_exit_and_is_bounded() public {
        _buy(1 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.setPaused(true);
        guard.setPaused(true);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.IsPaused.selector); guard.buy{value: 0.1 ether}(address(tok), 1, buyRoute());
        router.set(1000, 5e14, address(0)); _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.IsPaused.selector));
        { GuardedSwapRH.Hop[] memory h = sellRoute();
          vm.startPrank(address(acct), cold); tok.approve(address(guard), 100e18); uint256 out = guard.exit(address(tok), 100e18, 1, h); vm.stopPrank(); assertEq(out, 0.05 ether); }
        vm.expectRevert(GuardedSwapRH.PauseCooldown.selector); guard.setPaused(true);
        vm.warp(block.timestamp + 7 days + 1); assertFalse(guard.paused());
        vm.expectRevert(GuardedSwapRH.PauseCooldown.selector); guard.setPaused(true);
        vm.warp(block.timestamp + 1 days); guard.setPaused(true); guard.setPaused(false);
        vm.expectRevert(GuardedSwapRH.PauseCooldown.selector); guard.setPaused(true);
    }
    function test_guardian_and_exit_key_cannot_touch_funds() public {
        _buy(1 ether); guard.setPaused(true); guard.setPaused(false);
        address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); guard.unlock(a);
        assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(this)), 0); assertEq(tok.balanceOf(cold), 0); assertEq(address(guard).balance, 0);
    }
    function test_guardian_rotation_two_step_with_rules_and_expiry() public {
        address g2 = address(0xBEEF);
        vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.proposeGuardian(cold);
        vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.proposeGuardian(address(guard));
        vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.proposeGuardian(address(router));
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.proposeGuardian(g2);
        guard.proposeGuardian(g2); vm.warp(block.timestamp + 7 days + 1);
        vm.prank(g2); vm.expectRevert(GuardedSwapRH.NotPendingGuardian.selector); guard.acceptGuardian();
        guard.proposeGuardian(g2); vm.prank(g2); guard.acceptGuardian(); assertEq(guard.guardian(), g2);
        vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.setPaused(true);
    }
    function test_constructor_hygiene() public {
        address[] memory f = new address[](1); f[0] = address(fac); bool[] memory k = new bool[](1);
        vm.expectRevert(bytes("exit key must be an EOA")); new GuardedSwapRH(address(router), address(weth), pm, f, k, address(this), address(tok), 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("exit key")); new GuardedSwapRH(address(router), address(weth), pm, f, k, cold, cold, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("router WETH")); new GuardedSwapRH(address(router), address(tok), pm, f, k, address(this), cold, 12, 0.3 ether, 1 ether);           // the router's own WETH
        vm.expectRevert(bytes("router PoolManager")); new GuardedSwapRH(address(router), address(weth), address(fac), f, k, address(this), cold, 12, 0.3 ether, 1 ether);   // the router's own PoolManager
        vm.expectRevert(bytes("not a contract")); new GuardedSwapRH(address(router), address(weth), address(0xD00D), f, k, address(this), cold, 12, 0.3 ether, 1 ether);
        address[] memory f2 = new address[](2); f2[0] = address(fac); f2[1] = address(fac); bool[] memory k2 = new bool[](2);
        vm.expectRevert(bytes("factory twice")); new GuardedSwapRH(address(router), address(weth), pm, f2, k2, address(this), cold, 12, 0.3 ether, 1 ether);
        f2[1] = address(0xD00D); vm.expectRevert(bytes("factory")); new GuardedSwapRH(address(router), address(weth), pm, f2, k2, address(this), cold, 12, 0.3 ether, 1 ether);
        address[] memory f5 = new address[](5); bool[] memory k5 = new bool[](5);
        vm.expectRevert(bytes("factories")); new GuardedSwapRH(address(router), address(weth), pm, f5, k5, address(this), cold, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("factories")); new GuardedSwapRH(address(router), address(weth), pm, f, k2, address(this), cold, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("guardian")); new GuardedSwapRH(address(router), address(weth), pm, f, k, address(router), cold, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("zero limit")); new GuardedSwapRH(address(router), address(weth), pm, f, k, address(this), cold, 0, 0.3 ether, 1 ether);
    }
    function _tight() internal { guard = _deploy(12, 0.3 ether, 1 ether); }
    function test_rate_limits() public {
        _tight(); _buy(0.3 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); guard.buy{value: 1}(address(tok), 1, buyRoute());
        for (uint256 i = 0; i < 12; i++) _sell(10e18, 1);
        _expectSell(10e18, abi.encodeWithSelector(GuardedSwapRH.RateLimited.selector));
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether); _buy(0.3 ether);
        Wallet other = new Wallet(); vm.deal(address(other), 1 ether);
        vm.prank(address(other)); out = guard.buy{value: 0.3 ether}(address(tok), 1, buyRoute()); assertEq(out, 300e18);
    }
    function test_sell_eth_per_hour_is_capped() public {
        _tight(); vm.deal(address(acct), 100 ether);
        for (uint256 i = 0; i < 4; i++) { _buy(0.3 ether); vm.warp(block.timestamp + 1 hours); }
        _sell(900e18, 1); _expectSell(200e18, abi.encodeWithSelector(GuardedSwapRH.RateLimited.selector));
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(200e18, 1); assertEq(out, 0.2 ether);
    }
    function test_floorFor_quotes_the_room_left() public {
        _buy(1 ether); assertEq(guard.floorFor(address(acct), address(tok), 1000e18), 0.7 ether);
        router.set(1000, 5e14, address(0)); _sell(400e18, 1);
        assertEq(guard.floorFor(address(acct), address(tok), 100e18), 0.1 ether);
    }
    function testFuzz_cost_tracks_sales(uint96 price, uint8 fracBps) public {
        vm.assume(price > 1e9 && price < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;
        router.set(1000, price, address(0)); _buy(1 ether);
        uint256 sellAmt = 1000e18 * frac / 100; uint256 expectOut = sellAmt * price / 1e18; uint256 cost = 1 ether * sellAmt / 1000e18;
        uint256 lossIf = expectOut < cost ? cost - expectOut : 0;
        if (lossIf <= 0.3 ether) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18 - sellAmt); assertEq(ethIn, tokens == 0 ? 0 : 1 ether - cost);
            (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, lossIf); }
        else _expectSell(sellAmt, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, lossIf, (1 ether) * 3000 / 10000));
    }

    // ---- round 11..13 regressions (v13..v15) ----
    function test_a_loss_fades_over_a_week_whatever_the_base_does() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(500e18, 1);
        vm.deal(address(acct), 20 ether); router.set(1000, 1e15, address(0)); for (uint256 i = 0; i < 10; i++) _buy(1 ether);
        vm.warp(block.timestamp + 3.5 days);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(budget, 3.15 ether);
        assertEq(lost, 0.125 ether);
    }
    function test_a_loss_keeps_fading_after_the_lot_is_closed() public {
        _buy(1 ether); router.set(1000, 7e14, address(0)); _sell(1000e18, 1);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.3 ether); assertEq(budget, 0);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.15 ether);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_booking_more_resets_the_clock_on_the_whole_amount() public {
        _buy(1 ether); router.set(1000, 5e14, address(0)); _sell(400e18, 1);
        vm.warp(block.timestamp + 3.5 days);
        router.set(1000, 5e14, address(0)); _sell(100e18, 1);
        (uint256 amt, uint64 at) = guard.loss(address(acct)); assertEq(amt, 0.15 ether); assertEq(at, uint64(block.timestamp));
        vm.warp(block.timestamp + 7 days); (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_the_cold_key_can_replace_a_guardian_that_holds_the_pause() public {
        guard.setPaused(true); assertTrue(guard.paused());
        address g2 = address(0x6002);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.replaceGuardian(g2);
        vm.prank(cold); vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.replaceGuardian(address(this));
        vm.prank(cold); guard.replaceGuardian(g2); assertEq(guard.guardian(), g2);
        vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.setPaused(false);
        vm.prank(g2); guard.setPaused(false); assertFalse(guard.paused());
    }
    function test_bricked_balance_does_not_block_sell_or_exit() public {
        _buy(1 ether); tok.setBricked(address(acct), true);
        router.set(1000, 1e15, address(0)); uint256 out = _sell(400e18, 1); assertEq(out, 0.4 ether);
        (uint256 lot, ) = guard.lotOf(address(acct), address(tok)); assertEq(lot, 600e18);
        GuardedSwapRH.Hop[] memory h = sellRoute();
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 600e18); out = guard.exit(address(tok), 600e18, 1, h); vm.stopPrank();
        assertEq(out, 0.6 ether); (lot, ) = guard.lotOf(address(acct), address(tok)); assertEq(lot, 0); assertEq(guard.costOf(address(acct)), 0);
    }
    function test_bricked_balance_refused_on_buy() public {
        tok.setBricked(address(acct), true);
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.BelowMinOut.selector, 0, 1)); guard.buy{value: 1 ether}(address(tok), 1, buyRoute());
    }
    function test_tokens_lost_to_a_fee_on_the_way_back_count_as_given_up() public {
        _buy(1 ether); router.setPullLess(true); tok.setFee(1000);
        router.set(1000, 1e15, address(0));
        vm.startPrank(address(acct)); tok.approve(address(guard), 400e18);
        guard.sell(address(tok), 400e18, 1, sellRoute());     // 400 leave the account, 360 arrive; the route pulls 180; 180 go back as 162
        vm.stopPrank();
        (uint256 lot, uint256 cost) = guard.lotOf(address(acct), address(tok));
        assertEq(tok.balanceOf(address(acct)), 600e18 + 162e18);
        assertEq(lot, 762e18); assertEq(cost, 0.762 ether);
    }
}
