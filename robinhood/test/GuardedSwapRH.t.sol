// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwapRH.sol";
import "./Mocks.sol";

/// v4's unit suite ported to v5 (direct pools instead of the router): the same scenarios; budget numbers follow the v16
/// base (account ETH + open lots). Tests marked (v5) are new: pool calls, callbacks, hooks, the account-based budget.
contract GuardedSwapRHTest is Test {
    address constant NATIVE = address(0);
    MockToken tok; MockWETH weth; MockPoolManager pm; MockV3Pool pool; MockFactory fac; MockFactory facTick; GuardedSwapRH guard; Wallet acct;
    address thief = address(0x1111111111111111111111111111111111111111);
    address cold = address(0xC01D);
    address hookOk = address(uint160((uint256(1) << 156) | 0xc0));    // beforeSwap|afterSwap, no return-delta bits
    address hookRD = address(uint160((uint256(2) << 156) | 0x4c));    // afterSwap + both return-delta bits
    address hookListed;                                                               // a return-delta hook fixed at deployment
    function _deploy(uint256 sells, uint256 buyEth, uint256 sellEth) internal returns (GuardedSwapRH) { return _deployB(sells, 1000, buyEth, sellEth); }
    function _deployB(uint256 sells, uint256 buys, uint256 buyEth, uint256 sellEth) internal returns (GuardedSwapRH) {
        address[] memory f = new address[](2); f[0] = address(fac); f[1] = address(facTick);
        bool[] memory k = new bool[](2); k[1] = true;
        return _deployWith(f, k, cold, sells, buys, buyEth, sellEth);
    }
    function _deployWith(address[] memory f, bool[] memory k, address exitKey, uint256 sells, uint256 buys, uint256 buyEth, uint256 sellEth) internal returns (GuardedSwapRH) {
        address[] memory h = new address[](1); h[0] = hookListed;
        return new GuardedSwapRH(address(weth), address(pm), f, k, h, address(this), exitKey, sells, buys, buyEth, sellEth);
    }
    function setUp() public {
        tok = new MockToken(); weth = new MockWETH(); pm = new MockPoolManager(address(weth));
        pool = new MockV3Pool(address(weth), address(tok), address(weth), address(weth));
        fac = new MockFactory(); facTick = new MockFactory(); fac.set(address(weth), address(tok), 10000, address(pool));
        hookListed = address(uint160((uint256(3) << 156) | 0x0c)); vm.etch(hookListed, hex"00"); vm.etch(hookOk, hex"00"); vm.etch(hookRD, hex"00");
        pm.init(NATIVE, address(tok), 3000, 60, address(0));
        guard = _deploy(1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(pm), 1000 ether); vm.deal(address(weth), 1000 ether); vm.deal(address(acct), 10 ether);
    }
    // ---- hop builders ----
    function v4(address tin, address tout) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 2; h.tokenIn = tin; h.tokenOut = tout; h.fee = 3000; h.tickSpacing = 60; }
    function v3(address tin, address tout, address p, uint24 fee) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 1; h.tokenIn = tin; h.tokenOut = tout; h.pool = p; h.fee = fee; h.tickSpacing = 200; }
    function one(GuardedSwapRH.Hop memory a) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](1); h[0] = a; }
    function two(GuardedSwapRH.Hop memory a, GuardedSwapRH.Hop memory b) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](2); h[0] = a; h[1] = b; }
    function buyRoute() internal view returns (GuardedSwapRH.Hop[] memory) { return one(v4(NATIVE, address(tok))); }
    function sellRoute() internal view returns (GuardedSwapRH.Hop[] memory) { return one(v4(address(tok), NATIVE)); }
    function price(uint256 ethPerToken) internal { pm.setRates(1000e18, ethPerToken); pool.setRates(1000e18, ethPerToken); }
    function _buy(uint256 eth) internal returns (uint256) { vm.prank(address(acct)); return guard.buy{value: eth}(address(tok), 1, block.timestamp, buyRoute()); }
    function _sell(uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount);
        uint256 out = guard.sell(address(tok), amount, minOut, block.timestamp, sellRoute()); vm.stopPrank(); return out; }
    function _expectSell(uint256 amount, bytes memory err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount); vm.expectRevert(err);
        guard.sell(address(tok), amount, 1, block.timestamp, sellRoute()); vm.stopPrank(); }
    function _expectSellRoute(GuardedSwapRH.Hop[] memory h, bytes4 err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18); vm.expectRevert(err);
        guard.sell(address(tok), 10e18, 1, block.timestamp, h); vm.stopPrank(); }
    function _expectBuyRoute(GuardedSwapRH.Hop[] memory h, bytes4 err) internal {
        vm.prank(address(acct)); vm.expectRevert(err); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, h); }
    function _exit(uint256 amount) internal returns (uint256) {
        vm.startPrank(address(acct), cold); tok.approve(address(guard), amount);
        uint256 out = guard.exit(address(tok), amount, 1, block.timestamp, sellRoute()); vm.stopPrank(); return out; }
    /// the account holds exactly what it buys: its base is its cost basis (the v15 numbers apply until ETH comes back)
    function _lean(uint256 eth) internal { vm.deal(address(acct), eth); }

    // ---- recipient rule, the swaps themselves (v5) ----
    function test_buy_pays_caller_and_records_lot() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18); assertEq(ethIn, 1 ether); assertEq(guard.costOf(address(acct)), 1 ether);
        assertEq(address(guard).balance, 0); assertEq(weth.balanceOf(address(guard)), 0);
    }
    /// (v5) the gate calls the PoolManager itself: exact input, the PoolKey sorted, no hook data; the v3 pool with the gate as recipient
    function test_the_gate_makes_the_pool_calls_itself() public {
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 7, block.timestamp, buyRoute());
        (address c0, address c1, uint24 fee, int24 ts, address hooks) = pm.lastKey();
        assertEq(c0, NATIVE); assertEq(c1, address(tok)); assertEq(fee, 3000); assertEq(ts, 60); assertEq(hooks, address(0));
        (bool zf1, int256 spec, ) = pm.lastParams(); assertTrue(zf1); assertEq(spec, -1 ether); assertEq(pm.lastHookData().length, 0);
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000)));
        assertEq(out, 1000e18); assertEq(pool.calls(), 1); assertEq(weth.balanceOf(address(pool)), 1 ether);
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        out = guard.sell(address(tok), 100e18, 1, block.timestamp, one(v3(address(tok), address(weth), address(pool), 10000))); vm.stopPrank();
        assertEq(out, 0.1 ether); assertEq(tok.balanceOf(address(pool)), 100e18);                                   // paid native, after unwrapping
        assertEq(tok.allowance(address(guard), address(pool)), 0); assertEq(tok.allowance(address(guard), address(pm)), 0);
    }
    function test_a_pool_paying_elsewhere_reverts() public {
        pool.setPayTo(thief);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.ZeroAmount.selector);
        guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000)));
        pool.setPayTo(address(0)); _buy(1 ether); pool.setPayTo(thief);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18); vm.expectRevert(GuardedSwapRH.ZeroAmount.selector);
        guard.sell(address(tok), 500e18, 1, block.timestamp, one(v3(address(tok), address(weth), address(pool), 10000))); vm.stopPrank();
        assertEq(tok.balanceOf(thief), 0); assertEq(weth.balanceOf(thief), 0);
    }
    /// (v5) the v3 callback: only the pool being swapped with, once, the input token, at most the input
    function test_v3_callback_rules() public {
        vm.prank(thief); vm.expectRevert(GuardedSwapRH.BadCallback.selector); guard.uniswapV3SwapCallback(1 ether, 0, "");    // nobody outside a swap
        vm.prank(address(pool)); vm.expectRevert(GuardedSwapRH.BadCallback.selector); guard.uniswapV3SwapCallback(1 ether, 0, "");   // not even the pool
        GuardedSwapRH.Hop[] memory h = one(v3(address(weth), address(tok), address(pool), 10000));
        pool.setAskMore(1); _expectBuyRoute(h, GuardedSwapRH.BadCallback.selector); pool.setAskMore(0);              // more than the hop's input
        pool.setAskBoth(true); _expectBuyRoute(h, GuardedSwapRH.BadCallback.selector); pool.setAskBoth(false);        // both sides
        pool.setSkipCallback(true); _expectBuyRoute(h, GuardedSwapRH.BadCallback.selector); pool.setSkipCallback(false);   // no payment asked: refused, nothing paid
        Rogue rogue = new Rogue(); pool.setReenter(address(rogue), abi.encodeWithSelector(Rogue.hit.selector, address(guard)));
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, h);
        assertFalse(rogue.ok()); assertTrue(pool.reenterOk());                                                         // a third contract calling back mid-swap is refused
        pool.setReenter(address(guard), abi.encodeWithSelector(GuardedSwapRH.uniswapV3SwapCallback.selector, int256(1 ether), int256(0), bytes("")));
        _expectBuyRoute(h, GuardedSwapRH.BadCallback.selector);                                                         // the pool's own early call is the one callback: the swap's real one then fails
    }
    /// (v5) the v4 callback: only the pinned PoolManager, only during the gate's own unlock; the answer must be "input in full, output positive"
    function test_v4_callback_and_delta_rules() public {
        vm.prank(thief); vm.expectRevert(GuardedSwapRH.BadCallback.selector); guard.unlockCallback(abi.encode(NATIVE, address(tok), uint24(3000), int24(60), address(0), uint256(1)));
        vm.prank(address(pm)); vm.expectRevert(GuardedSwapRH.BadCallback.selector); guard.unlockCallback(abi.encode(NATIVE, address(tok), uint24(3000), int24(60), address(0), uint256(1)));
        pm.setConsumeHalf(true); _expectBuyRoute(buyRoute(), GuardedSwapRH.PartialFill.selector); pm.setConsumeHalf(false);
        pm.setOutOverride(-1); _expectBuyRoute(buyRoute(), GuardedSwapRH.ZeroAmount.selector); pm.setOutOverride(0);
        pm.setSkipCallback(true); _expectBuyRoute(buyRoute(), GuardedSwapRH.BadCallback.selector); pm.setSkipCallback(false);
        GuardedSwapRH.Hop memory u = v4(NATIVE, address(tok)); u.fee = 500;
        vm.prank(address(acct)); vm.expectRevert(bytes("PoolNotInitialized")); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(u));   // unknown PoolKey
        _buy(1 ether);
    }
    /// (v5) hooks: zero, no return-delta permission, or fixed at deployment
    function test_hook_rule() public {
        pm.init(NATIVE, address(tok), 3000, 60, hookOk); pm.init(NATIVE, address(tok), 3000, 60, hookRD); pm.init(NATIVE, address(tok), 3000, 60, hookListed);
        GuardedSwapRH.Hop memory h = v4(NATIVE, address(tok));
        h.hooks = hookOk; vm.prank(address(acct)); assertEq(guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(h)), 1000e18);
        h.hooks = hookRD; _expectBuyRoute(one(h), GuardedSwapRH.BadHook.selector);
        h.hooks = hookListed; vm.prank(address(acct)); assertEq(guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(h)), 1000e18);
        pm.setHookSkim(true); vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.BelowMinOut.selector, 970e18, 1000e18));
        guard.buy{value: 1 ether}(address(tok), 1000e18, block.timestamp, one(h));                                     // what a hook keeps is price: minOut catches it
        GuardedSwapRH.Hop memory s = v4(address(tok), NATIVE); s.hooks = hookRD; _buy(1 ether); _expectSellRoute(one(s), GuardedSwapRH.BadHook.selector);
        assertEq(guard.allowedHooks()[0], hookListed);
    }
    /// (v5) a WETH-quoted v4 pool: the gate wraps on a buy and unwraps on a sale
    function test_v4_weth_pool_wraps_and_unwraps() public {
        (address a, address b) = address(weth) < address(tok) ? (address(weth), address(tok)) : (address(tok), address(weth));
        pm.init(a, b, 3000, 60, address(0)); pm.setEthSide(address(weth));
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v4(address(weth), address(tok))));
        assertEq(out, 1000e18); assertEq(weth.balanceOf(address(pm)), 1 ether);
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        uint256 e0 = address(acct).balance; out = guard.sell(address(tok), 100e18, 1, block.timestamp, one(v4(address(tok), address(weth)))); vm.stopPrank();
        assertEq(out, 0.1 ether); assertEq(address(acct).balance - e0, 0.1 ether); assertEq(weth.balanceOf(address(guard)), 0); assertEq(address(guard).balance, 0);
    }

    // ---- route rule ----
    function test_buy_route_rules() public {
        GuardedSwapRH.Hop[] memory none = new GuardedSwapRH.Hop[](0);
        _expectBuyRoute(none, GuardedSwapRH.BadRoute.selector);
        GuardedSwapRH.Hop[] memory four = new GuardedSwapRH.Hop[](4);
        four[0] = v4(NATIVE, address(0xA1)); four[1] = v4(address(0xA1), address(0xA2)); four[2] = v4(address(0xA2), address(0xA3)); four[3] = v4(address(0xA3), address(tok));
        _expectBuyRoute(four, GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(one(v4(address(0xA1), address(tok))), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(one(v4(NATIVE, address(0xA1))), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(two(v4(NATIVE, address(0xA1)), v4(address(0xA2), address(tok))), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(two(v4(NATIVE, address(weth)), v4(address(weth), address(tok))), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(two(v4(NATIVE, address(tok)), v4(address(tok), address(tok))), GuardedSwapRH.BadRoute.selector);
        GuardedSwapRH.Hop memory h = v4(NATIVE, address(tok));
        for (uint8 v = 0; v <= 5; v++) { if (v == 1 || v == 2) continue; h.version = v; _expectBuyRoute(one(h), GuardedSwapRH.BadRoute.selector); }
        h = v4(NATIVE, address(tok)); h.pool = address(pool); _expectBuyRoute(one(h), GuardedSwapRH.BadRoute.selector);
        GuardedSwapRH.Hop memory x = v3(address(weth), address(tok), address(pool), 10000); x.hooks = address(0x4004); _expectBuyRoute(one(x), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(one(v3(NATIVE, address(tok), address(pool), 10000)), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(one(v3(address(weth), address(tok), address(0xBAD), 10000)), GuardedSwapRH.BadRoute.selector);
        _expectBuyRoute(one(v3(address(weth), address(tok), address(pool), 3000)), GuardedSwapRH.BadRoute.selector);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.BadRoute.selector); guard.buy{value: 1 ether}(address(weth), 1, block.timestamp, one(v4(NATIVE, address(weth))));
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000))); assertEq(out, 1000e18);
    }
    /// (v5) a fake pool -- a contract that is not the factory's pool for the pair -- is never called
    function test_a_fake_pool_is_never_called() public {
        MockV3Pool fake = new MockV3Pool(address(weth), address(tok), address(weth), address(weth));
        _expectBuyRoute(one(v3(address(weth), address(tok), address(fake), 10000)), GuardedSwapRH.BadRoute.selector);
        assertEq(fake.calls(), 0);
    }
    function test_tick_keyed_factory_and_multi_hop() public {
        MockToken usd = new MockToken();
        MockV3Pool p1 = new MockV3Pool(address(weth), address(usd), address(weth), address(weth));           // WETH -> 1000 usd per WETH
        MockV3Pool p2 = new MockV3Pool(address(usd), address(tok), address(weth), address(usd)); p2.setRates(1e18, 1e18);   // usd -> tok 1:1
        facTick.set(address(usd), address(tok), 50, address(p2));
        GuardedSwapRH.Hop[] memory h = two(v3(address(weth), address(usd), address(pool), 10000), v3(address(usd), address(tok), address(p2), 50));
        _expectBuyRoute(h, GuardedSwapRH.BadRoute.selector);
        fac.set(address(weth), address(usd), 100, address(p1));
        h[0] = v3(address(weth), address(usd), address(p1), 100);
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, h); assertEq(out, 1000e18);
        assertEq(usd.balanceOf(address(guard)), 0); assertEq(weth.balanceOf(address(guard)), 0);
        h[1].pool = address(p1); _expectBuyRoute(h, GuardedSwapRH.BadRoute.selector);
        pm.init(address(usd) < address(0xA1) ? address(usd) : address(0xA1), address(usd) < address(0xA1) ? address(0xA1) : address(usd), 3000, 60, address(0));
        MockToken a1 = MockToken(address(0xA1)); vm.etch(address(a1), address(tok).code);
        pm.init(address(0xA1) < address(tok) ? address(0xA1) : address(tok), address(0xA1) < address(tok) ? address(tok) : address(0xA1), 3000, 60, address(0));
        GuardedSwapRH.Hop[] memory three = new GuardedSwapRH.Hop[](3);
        three[0] = v3(address(weth), address(usd), address(p1), 100); three[1] = v4(address(usd), address(0xA1)); three[2] = v4(address(0xA1), address(tok));
        vm.prank(address(acct)); out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, three); assertGt(out, 0);   // v3 -> v4 -> v4
        assertEq(usd.balanceOf(address(guard)), 0); assertEq(a1.balanceOf(address(guard)), 0);
    }
    function test_sale_route_rules() public {
        _buy(1 ether);
        _expectSellRoute(one(v4(NATIVE, address(tok))), GuardedSwapRH.BadRoute.selector);
        _expectSellRoute(one(v4(address(tok), address(0xA1))), GuardedSwapRH.BadRoute.selector);
        _expectSellRoute(one(v4(address(0xA1), NATIVE)), GuardedSwapRH.BadRoute.selector);
        _expectSellRoute(one(v3(address(tok), address(weth), address(0xBAD), 10000)), GuardedSwapRH.BadRoute.selector);
        _expectSellRoute(two(v4(address(tok), address(weth)), v4(address(weth), NATIVE)), GuardedSwapRH.BadRoute.selector);
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18);
        uint256 out = guard.sell(address(tok), 10e18, 1, block.timestamp, one(v3(address(tok), address(weth), address(pool), 10000))); vm.stopPrank(); assertEq(out, 0.01 ether);
        assertEq(tok.balanceOf(address(acct)), 990e18);
    }
    function test_minOut_zero_and_non_contract_token() public {
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwapRH.MinOutZero.selector); guard.buy{value: 1 ether}(address(tok), 0, block.timestamp, buyRoute());
        vm.expectRevert(GuardedSwapRH.NotAContract.selector); guard.buy{value: 1 ether}(thief, 1, block.timestamp, one(v4(NATIVE, thief)));
        vm.stopPrank();
    }

    // ---- only this call's funds ----
    function test_stray_tokens_and_eth_are_neither_swept_nor_counted() public {
        tok.mint(address(guard), 500e18); vm.deal(address(guard), 5 ether); weth.mint(address(guard), 3 ether);
        uint256 out = _buy(1 ether); assertEq(out, 1000e18);
        (, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 1 ether);
        assertEq(tok.balanceOf(address(guard)), 500e18); assertEq(address(guard).balance, 5 ether); assertEq(address(acct).balance, 9 ether);
        uint256 got = _sell(500e18, 1); assertEq(got, 0.5 ether); assertEq(tok.balanceOf(address(guard)), 500e18); assertEq(address(guard).balance, 5 ether); assertEq(weth.balanceOf(address(guard)), 3 ether);
    }
    function test_direct_eth_refused_outside_a_trade() public {
        vm.prank(address(acct)); (bool ok, ) = address(guard).call{value: 1 ether}(""); assertFalse(ok);
        vm.prank(address(pm)); (ok, ) = address(guard).call{value: 1 ether}(""); assertFalse(ok);
    }
    /// (v5) ETH sent to the gate mid-buy (by a pool, a hook, anyone) goes back to the account and lowers the recorded cost;
    ///      sent during a native-input hop it breaks that hop's full-fill measure and the buy reverts (fail closed)
    function test_eth_sent_during_a_buy_goes_back_to_the_account() public {
        Donor d = new Donor(); vm.deal(address(d), 2 ether);
        GuardedSwapRH.Hop[] memory h = one(v3(address(weth), address(tok), address(pool), 10000));
        pool.setReenter(address(d), abi.encodeWithSelector(Donor.give.selector, address(guard), 0.1 ether));
        uint256 e0 = address(acct).balance; vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, h); assertEq(out, 1000e18);
        (, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 0.9 ether); assertEq(address(acct).balance, e0 - 0.9 ether);
        pool.setReenter(address(d), abi.encodeWithSelector(Donor.give.selector, address(guard), 0.9 ether));
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.Overpaid.selector); guard.buy{value: 0.5 ether}(address(tok), 1, block.timestamp, h);
        pm.setReenter(address(d), abi.encodeWithSelector(Donor.give.selector, address(guard), 0.1 ether));
        _expectBuyRoute(buyRoute(), GuardedSwapRH.PartialFill.selector);
    }
    function test_state_is_final_before_eth_leaves() public {
        SpyWallet spy = new SpyWallet(); spy.set(guard, address(tok)); vm.deal(address(spy), 2 ether);
        uint256 out = spy.buy(1 ether, 1, buyRoute());
        spy.sell(100e18, 1, sellRoute());
        assertEq(spy.hooks(), 1); assertEq(spy.seenTokens(), out - 100e18);
    }
    function test_reentrancy_blocked() public {
        GuardedSwapRH.Hop[] memory h = new GuardedSwapRH.Hop[](0);
        pm.setReenter(address(guard), abi.encodeWithSelector(GuardedSwapRH.sell.selector, address(tok), uint256(1), uint256(1), block.timestamp, h));
        _buy(1 ether); assertFalse(pm.reenterOk());
        pool.setReenter(address(guard), abi.encodeWithSelector(GuardedSwapRH.buy.selector, address(tok), uint256(1), block.timestamp, h));
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000))); assertFalse(pool.reenterOk());
    }
    function test_guard_keeps_nothing_and_grants_no_allowance() public {
        _buy(1 ether); _sell(100e18, 1);
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000)));
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18); guard.sell(address(tok), 100e18, 1, block.timestamp, one(v3(address(tok), address(weth), address(pool), 10000))); vm.stopPrank();
        assertEq(address(guard).balance, 0); assertEq(tok.balanceOf(address(guard)), 0); assertEq(weth.balanceOf(address(guard)), 0);
        assertEq(tok.allowance(address(guard), address(pool)), 0); assertEq(tok.allowance(address(guard), address(pm)), 0); assertEq(weth.allowance(address(guard), address(pool)), 0);
    }

    // ---- only the lot ----
    function test_only_the_lot_is_for_sale() public {
        tok.mint(address(acct), 100e18);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 0, 100e18));
        _buy(1 ether);
        _expectSell(1100e18, abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 1000e18, 1100e18));
    }
    function test_tokens_the_owner_moved_out_leave_the_lot_pro_rata() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 700e18);
        (uint256 tokens, uint256 ethIn) = guard.lotOf(address(acct), address(tok)); assertEq(tokens, 300e18); assertEq(ethIn, 0.3 ether);
        uint256 out = _sell(300e18, 1); assertEq(out, 0.3 ether);
        assertEq(guard.costOf(address(acct)), 0); (tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0);
    }
    function test_an_emptied_lot_closes() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 1000e18);
        pm.setRates(100000e18, 1e15); _buy(0.1 ether);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 10000e18); assertEq(ethIn, 0.1 ether); assertEq(guard.costOf(address(acct)), 0.1 ether);
    }
    /// (v5) a fee-on-transfer token cannot be paid into a pool in full (the pool or the PoolManager sees less than owed):
    ///      the sale reverts, the lot is untouched; such tokens are sold from the owner's wallet (unsupported, as before)
    function test_fee_on_transfer_token_sale_reverts_and_the_lot_stays() public {
        _buy(1 ether); tok.setFee(1000);
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18); vm.expectRevert(bytes("CurrencyNotSettled"));
        guard.sell(address(tok), 1000e18, 1, block.timestamp, sellRoute());
        vm.expectRevert(bytes("IIA")); guard.sell(address(tok), 1000e18, 1, block.timestamp, one(v3(address(tok), address(weth), address(pool), 10000))); vm.stopPrank();
        (uint256 tokens,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18);
    }
    function test_partial_fill_refused() public {
        _buy(1 ether); pm.setConsumeHalf(true);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.PartialFill.selector));
        (, uint64 sells,,,) = guard.window(address(acct)); assertEq(sells, 0);
        pm.setConsumeHalf(false); pool.setConsumeHalf(true);
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwapRH.PartialFill.selector);
        guard.sell(address(tok), 100e18, 1, block.timestamp, one(v3(address(tok), address(weth), address(pool), 10000))); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 1000e18);
    }

    /// (v5) a middle hop that takes only part of its input is refused: nothing of a route may stay on the gate
    function test_a_partial_middle_hop_is_refused() public {
        MockToken usd = new MockToken();
        MockV3Pool p1 = new MockV3Pool(address(weth), address(usd), address(weth), address(weth));
        MockV3Pool p2 = new MockV3Pool(address(usd), address(tok), address(weth), address(usd)); p2.setRates(1e18, 1e18);
        fac.set(address(weth), address(usd), 100, address(p1)); fac.set(address(usd), address(tok), 500, address(p2));
        GuardedSwapRH.Hop[] memory h = two(v3(address(weth), address(usd), address(p1), 100), v3(address(usd), address(tok), address(p2), 500));
        p2.setConsumeHalf(true); _expectBuyRoute(h, GuardedSwapRH.PartialFill.selector);
        p2.setConsumeHalf(false); vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, h);
        assertEq(usd.balanceOf(address(guard)), 0);
    }

    // ---- loss budget: v15 numbers on a lean account, then the v16 base (v5) ----
    function test_profit_and_at_cost_sales_never_touch_the_budget() public {
        _buy(1 ether); price(2e15); _sell(500e18, 1); price(1e15); _sell(500e18, 1);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
    }
    function test_losses_accumulate_up_to_30_percent_of_the_account_then_block() public {
        _lean(1 ether); _buy(1 ether);                                                          // base: 0 ETH + 1 ETH of lots
        price(5e14); uint256 out = _sell(400e18, 1); assertEq(out, 0.2 ether);
        (uint256 lost, uint256 budget) = guard.budgetOf(address(acct)); assertEq(lost, 0.2 ether); assertEq(budget, 0.24 ether);   // base 0.2 ETH + 0.6 lots
        _expectSell(300e18, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, 0.35 ether, 0.24 ether));
        price(1e15); out = _sell(300e18, 1); assertEq(out, 0.3 ether);
        price(2e15); out = _sell(300e18, 1); assertEq(out, 0.6 ether);
    }
    /// (v5, the 23 Oct 2026 case on Base) an account holding mostly ETH sells one crashed position: v4's base (open lots) refused it
    function test_a_crash_of_a_small_position_sells_when_the_account_holds_eth() public {
        vm.deal(address(acct), 0.78 ether); _buy(0.04 ether);                                     // 0.74 ETH + 0.04 of lots
        price(37e13); uint256 out = _sell(40e18, 1); assertEq(out, 0.0148 ether);                // -63%
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.0252 ether);          // v4 would have refused: 0.0252 > 0.3 x 0.04
    }
    function test_buys_leave_the_base_unchanged_and_a_withdrawal_shrinks_it() public {
        (, uint256 b0) = guard.budgetOf(address(acct)); assertEq(b0, 3 ether);
        _buy(1 ether); (, uint256 b1) = guard.budgetOf(address(acct)); assertEq(b1, b0);
        vm.deal(address(acct), 0);                                                                   // the owner withdraws the ETH
        (, uint256 b2) = guard.budgetOf(address(acct)); assertEq(b2, 0.3 ether);
        price(1e14); _expectSell(1000e18, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, 0.9 ether, 0.3 ether));
    }
    /// (v5) a thief dumping everything at once books at most 30% of the account; every loss also shrinks the base
    function test_a_burst_books_at_most_30_percent_of_the_account() public {
        _lean(1 ether); _buy(1 ether); price(1e12);                                               // the thief's sink pays 0.1% of cost
        uint256 booked; uint256 chunk = 50e18;
        for (uint256 i = 0; i < 20; i++) {
            vm.startPrank(address(acct)); tok.approve(address(guard), chunk);
            try guard.sell(address(tok), chunk, 1, block.timestamp, sellRoute()) returns (uint256) {} catch { vm.stopPrank(); break; }
            vm.stopPrank();
        }
        (booked, ) = guard.loss(address(acct)); assertLe(booked, uint256(0.3 ether) * 10000 / 13000 + 0.05 ether);  // ≤ base·0.3/1.3, plus one chunk of granularity
        assertGe(booked, 0.19 ether);
    }
    function test_budget_refills_linearly_over_a_week() public {
        _lean(1 ether); _buy(1 ether); price(5e14); _sell(500e18, 1);
        _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, 0.3 ether, 0.225 ether));
        vm.warp(block.timestamp + 3.5 days);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.125 ether);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
    }
    function test_unlock_only_by_the_cold_key() public {
        _lean(1 ether); _buy(1 ether); price(5e14); _sell(500e18, 1);
        address[] memory a = new address[](1); a[0] = address(acct);
        vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.unlock(a);
        vm.prank(address(acct), cold); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.unlock(a);
        vm.prank(cold); guard.unlock(a);
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.05 ether);
        address[] memory many = new address[](65); vm.prank(cold); vm.expectRevert(GuardedSwapRH.TooLarge.selector); guard.unlock(many);
    }

    // ---- exit ----
    function test_exit_only_when_the_cold_key_sent_the_transaction() public {
        _buy(1 ether); price(1e14);
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18); vm.expectRevert(GuardedSwapRH.NotExitKey.selector);
        guard.exit(address(tok), 1000e18, 1, block.timestamp, sellRoute()); vm.stopPrank();
        vm.startPrank(address(acct), thief); vm.expectRevert(GuardedSwapRH.NotExitKey.selector);
        guard.exit(address(tok), 1000e18, 1, block.timestamp, sellRoute()); vm.stopPrank();
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
        guard.exit(address(tok), 100e18, 1, block.timestamp, one(v4(address(tok), address(0xA1)))); vm.stopPrank();
        vm.startPrank(address(acct), cold); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.NotInLot.selector, 490e18, 1000e18));
        guard.exit(address(tok), 1000e18, 1, block.timestamp, sellRoute()); vm.stopPrank();
    }

    // ---- pause, limits, guardian ----
    function test_pause_stops_the_executor_not_the_exit_and_is_bounded() public {
        _buy(1 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.setPaused(true);
        guard.setPaused(true);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.IsPaused.selector); guard.buy{value: 0.1 ether}(address(tok), 1, block.timestamp, buyRoute());
        price(5e14); _expectSell(100e18, abi.encodeWithSelector(GuardedSwapRH.IsPaused.selector));
        { GuardedSwapRH.Hop[] memory h = sellRoute();
          vm.startPrank(address(acct), cold); tok.approve(address(guard), 100e18); uint256 out = guard.exit(address(tok), 100e18, 1, block.timestamp, h); vm.stopPrank(); assertEq(out, 0.05 ether); }
        vm.expectRevert(GuardedSwapRH.PauseCooldown.selector); guard.setPaused(true);
        vm.warp(block.timestamp + 7 days + 1); assertFalse(guard.paused());
        vm.expectRevert(GuardedSwapRH.PauseCooldown.selector); guard.setPaused(true);
        vm.warp(block.timestamp + 1 days); guard.setPaused(true); guard.setPaused(false);
        vm.expectRevert(GuardedSwapRH.PauseCooldown.selector); guard.setPaused(true);
    }
    function test_guardian_rotation_two_step_with_rules_and_expiry() public {
        address g2 = address(0xBEEF);
        vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.proposeGuardian(cold);
        vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.proposeGuardian(address(guard));
        vm.expectRevert(GuardedSwapRH.BadGuardian.selector); guard.proposeGuardian(address(pm));
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.proposeGuardian(g2);
        guard.proposeGuardian(g2); vm.warp(block.timestamp + 7 days + 1);
        vm.prank(g2); vm.expectRevert(GuardedSwapRH.NotPendingGuardian.selector); guard.acceptGuardian();
        guard.proposeGuardian(g2); vm.prank(g2); guard.acceptGuardian(); assertEq(guard.guardian(), g2);
        vm.expectRevert(GuardedSwapRH.NotGuardian.selector); guard.setPaused(true);
    }
    function test_the_cold_key_can_replace_a_guardian_that_holds_the_pause() public {
        guard.setPaused(true); address g2 = address(0x6002);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.replaceGuardian(g2);
        vm.prank(cold); guard.replaceGuardian(g2); assertEq(guard.guardian(), g2);
        vm.prank(g2); guard.setPaused(false); assertFalse(guard.paused());
    }
    function test_constructor_hygiene() public {
        address[] memory f = new address[](1); f[0] = address(fac); bool[] memory k = new bool[](1); address[] memory h = new address[](0);
        vm.expectRevert(bytes("exit key must be an EOA")); new GuardedSwapRH(address(weth), address(pm), f, k, h, address(this), address(tok), 12, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("exit key")); new GuardedSwapRH(address(weth), address(pm), f, k, h, cold, cold, 12, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("not a contract")); new GuardedSwapRH(address(weth), address(0xD00D), f, k, h, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        address[] memory f2 = new address[](2); f2[0] = address(fac); f2[1] = address(fac); bool[] memory k2 = new bool[](2);
        vm.expectRevert(bytes("factory twice")); new GuardedSwapRH(address(weth), address(pm), f2, k2, h, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        f2[1] = address(0xD00D); vm.expectRevert(bytes("factory")); new GuardedSwapRH(address(weth), address(pm), f2, k2, h, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        address[] memory f5 = new address[](5); bool[] memory k5 = new bool[](5);
        vm.expectRevert(bytes("factories")); new GuardedSwapRH(address(weth), address(pm), f5, k5, h, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        address[] memory h5 = new address[](5); vm.expectRevert(bytes("hooks")); new GuardedSwapRH(address(weth), address(pm), f, k, h5, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        address[] memory h1 = new address[](1); vm.expectRevert(bytes("hook")); new GuardedSwapRH(address(weth), address(pm), f, k, h1, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        address[] memory h2 = new address[](2); h2[0] = hookListed; h2[1] = hookListed; vm.expectRevert(bytes("hook twice")); new GuardedSwapRH(address(weth), address(pm), f, k, h2, address(this), cold, 12, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("guardian")); new GuardedSwapRH(address(weth), address(pm), f, k, h, address(pm), cold, 12, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("zero limit")); new GuardedSwapRH(address(weth), address(pm), f, k, h, address(this), cold, 12, 0, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("limit too large")); new GuardedSwapRH(address(weth), address(pm), f, k, h, address(this), cold, type(uint64).max, 12, 0.3 ether, 1 ether);
    }
    function _tight() internal { guard = _deploy(12, 0.3 ether, 1 ether); }
    function test_rate_limits() public {
        _tight(); _buy(0.3 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); guard.buy{value: 1}(address(tok), 1, block.timestamp, buyRoute());
        for (uint256 i = 0; i < 12; i++) _sell(10e18, 1);
        _expectSell(10e18, abi.encodeWithSelector(GuardedSwapRH.RateLimited.selector));
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether); _buy(0.3 ether);
        Wallet other = new Wallet(); vm.deal(address(other), 1 ether);
        vm.prank(address(other)); out = guard.buy{value: 0.3 ether}(address(tok), 1, block.timestamp, buyRoute()); assertEq(out, 300e18);
    }
    function test_sell_eth_per_hour_is_capped() public {
        _tight(); vm.deal(address(acct), 100 ether);
        for (uint256 i = 0; i < 4; i++) { _buy(0.3 ether); vm.warp(block.timestamp + 1 hours); }
        _sell(900e18, 1); _expectSell(200e18, abi.encodeWithSelector(GuardedSwapRH.RateLimited.selector));
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(200e18, 1); assertEq(out, 0.2 ether);
    }
    function test_buys_are_counted_per_hour() public {
        guard = _deployB(1000, 3, 1000 ether, 1000 ether);
        for (uint256 i = 0; i < 3; i++) { vm.prank(address(acct)); guard.buy{value: 1000}(address(tok), 1, block.timestamp, buyRoute()); }
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); guard.buy{value: 1000}(address(tok), 1, block.timestamp, buyRoute());
        vm.warp(block.timestamp + 1 hours); vm.prank(address(acct)); guard.buy{value: 1000}(address(tok), 1, block.timestamp, buyRoute());
    }
    function test_any_hour_sees_at_most_twice_a_cap() public {
        guard = _deployB(1000, 2, 1000 ether, 1000 ether);
        vm.warp(1_000_000); uint256 t0 = block.timestamp;
        _buy(0.1 ether); _buy(0.1 ether);
        vm.warp(t0 + 1 hours - 1); vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); guard.buy{value: 1}(address(tok), 1, block.timestamp, buyRoute());
        vm.warp(t0 + 1 hours); _buy(0.1 ether); _buy(0.1 ether);
        vm.warp(t0 + 2 hours - 1); vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); guard.buy{value: 1}(address(tok), 1, block.timestamp, buyRoute());
    }
    function test_floorFor_quotes_the_room_left() public {
        _lean(1 ether); _buy(1 ether); assertEq(guard.floorFor(address(acct), address(tok), 1000e18), 0.7 ether);
        price(5e14); _sell(400e18, 1);
        assertEq(guard.floorFor(address(acct), address(tok), 100e18), 0.06 ether);     // cost 0.1, room 0.24 - 0.2 = 0.04
    }
    function testFuzz_cost_tracks_sales(uint96 p, uint8 fracBps) public {
        vm.assume(p > 1e9 && p < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;
        _lean(1 ether); price(p); _buy(1 ether);
        uint256 sellAmt = 1000e18 * frac / 100; uint256 expectOut = sellAmt * p / 1e18; uint256 cost = 1 ether * sellAmt / 1000e18;
        uint256 lossIf = expectOut < cost ? cost - expectOut : 0;
        if (lossIf <= 0.3 ether) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18 - sellAmt); assertEq(ethIn, tokens == 0 ? 0 : 1 ether - cost);
            (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, lossIf); }
        else _expectSell(sellAmt, abi.encodeWithSelector(GuardedSwapRH.BudgetExceeded.selector, lossIf, 0.3 ether));
    }
    function test_a_loss_is_charged_rounded_up() public {
        _lean(100); pm.setRates(7e17 * 1e18, 1);                                                // 100 wei buy 7e19 tokens; 1e18 tokens sell for 1 wei
        vm.prank(address(acct)); guard.buy{value: 100}(address(tok), 1, block.timestamp, buyRoute());
        uint256 out = _sell(1e18, 1); assertEq(out, 1);
        (uint256 amt, ) = guard.loss(address(acct)); assertEq(amt, 1);
        (uint256 tokens, uint256 ethIn) = guard.basis(address(acct), address(tok)); assertEq(tokens, 69e18); assertEq(ethIn, 99);
    }
    function test_bricked_balance_does_not_block_sell_or_exit() public {
        _buy(1 ether); tok.setBricked(address(acct), true);
        uint256 out = _sell(400e18, 1); assertEq(out, 0.4 ether);
        GuardedSwapRH.Hop[] memory h = sellRoute();
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 600e18); out = guard.exit(address(tok), 600e18, 1, block.timestamp, h); vm.stopPrank();
        assertEq(out, 0.6 ether); assertEq(guard.costOf(address(acct)), 0);
    }
    function test_bricked_balance_refused_on_buy() public {
        tok.setBricked(address(acct), true);
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwapRH.BelowMinOut.selector, 0, 1)); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, buyRoute());
    }
    function test_a_dirty_factory_cannot_brick_v3_hops() public {
        DirtyFactory dirty = new DirtyFactory(address(pool));
        address[] memory f = new address[](2); f[0] = address(dirty); f[1] = address(fac); bool[] memory k = new bool[](2);
        guard = _deployWith(f, k, cold, 1000, 1000, 1000 ether, 1000 ether);
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000))); assertEq(out, 1000e18);
    }
    function test_a_long_factory_answer_reads_the_first_word() public {
        FatFactory fat = new FatFactory(address(pool));
        address[] memory f = new address[](1); f[0] = address(fat); bool[] memory k = new bool[](1);
        guard = _deployWith(f, k, cold, 1000, 1000, 1000 ether, 1000 ether);
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(pool), 10000))); assertEq(out, 1000e18);
    }
    function test_cold_key_paths_eoa_and_7702() public {
        uint256 pk = 0xC0FFEE; address key = vm.addr(pk);
        address[] memory f = new address[](0); bool[] memory k = new bool[](0);
        guard = _deployWith(f, k, key, 1000, 1000, 1000 ether, 1000 ether);
        SmartAccount sa = new SmartAccount(); vm.deal(address(sa), 1 ether);
        vm.prank(address(sa)); guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, buyRoute());
        sa.exec(address(tok), abi.encodeWithSelector(MockToken.approve.selector, address(guard), 1000e18));
        bytes memory ex = abi.encodeWithSelector(GuardedSwapRH.exit.selector, address(tok), 100e18, uint256(1), block.timestamp, sellRoute());
        address[] memory a = new address[](1); a[0] = address(sa);
        vm.prank(key, key); sa.exec(address(guard), ex);
        vm.prank(key); guard.unlock(a);
        Wallet7702 impl = new Wallet7702(); vm.signAndAttachDelegation(address(impl), pk);
        vm.prank(key, key); sa.exec(address(guard), ex);
        vm.prank(key, key); Wallet7702(payable(key)).execute(address(guard), abi.encodeWithSelector(GuardedSwapRH.unlock.selector, a));
        vm.prank(address(0x7E1A), address(0x7E1A)); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); sa.exec(address(guard), ex);
        vm.prank(address(sa), key); vm.expectRevert(GuardedSwapRH.NotExitKey.selector); guard.unlock(a);
        assertEq(tok.balanceOf(address(sa)), 800e18); assertEq(key.balance, 0);
        vm.expectRevert(bytes("exit key must be an EOA")); _deployWith(f, k, key, 1000, 1000, 1000 ether, 1000 ether);
    }
    function test_a_trade_past_its_deadline_reverts() public {
        uint256 t = block.timestamp;
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.Expired.selector); guard.buy{value: 1 ether}(address(tok), 1, t - 1, buyRoute());
        vm.prank(address(acct)); guard.buy{value: 1 ether}(address(tok), 1, t, buyRoute());
        vm.warp(t + 60);
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        vm.expectRevert(GuardedSwapRH.Expired.selector); guard.sell(address(tok), 100e18, 1, t + 59, sellRoute()); vm.stopPrank();
        vm.startPrank(address(acct), cold); vm.expectRevert(GuardedSwapRH.Expired.selector); guard.exit(address(tok), 100e18, 1, t + 59, sellRoute()); vm.stopPrank();
    }
    /// a pool or PoolManager revert is passed on with at most 256 bytes of its data
    function test_swap_revert_data_is_capped() public {
        Loud loud = new Loud(); fac.set(address(weth), address(tok), 500, address(loud));
        vm.prank(address(acct));
        try guard.buy{value: 1 ether}(address(tok), 1, block.timestamp, one(v3(address(weth), address(tok), address(loud), 500))) { fail(); }
        catch (bytes memory e) { assertEq(e.length, 256); }
    }
}

/// answers getPool with the right pool in its first word and 10 KB of padding after it
contract FatFactory {
    address immutable p; constructor(address p_) { p = p_; }
    fallback(bytes calldata) external returns (bytes memory r) { r = new bytes(10240); bytes32 w = bytes32(uint256(uint160(p))); assembly { mstore(add(r, 32), w) } }
}
/// answers getPool with the right pool in the low 160 bits and garbage above them
contract DirtyFactory {
    address immutable p; constructor(address p_) { p = p_; }
    fallback(bytes calldata) external returns (bytes memory) { return abi.encode(uint256(uint160(p)) | (uint256(1) << 200)); }
}
/// a pool that reverts with 10 KB
contract Loud { fallback() external { bytes memory big = new bytes(10000); assembly { revert(add(big, 32), mload(big)) } } }
/// a third contract that tries the gate's v3 callback while a swap is in flight
contract Rogue { bool public ok; function hit(address g) external { (ok, ) = g.call(abi.encodeWithSelector(GuardedSwapRH.uniswapV3SwapCallback.selector, int256(1 ether), int256(0), bytes(""))); } }
/// sends ETH to the gate mid-trade
contract Donor { receive() external payable {} function give(address g, uint256 a) external { (bool ok, ) = g.call{value: a}(""); require(ok); } }
/// a minimal EIP-7702 wallet: the EOA may call out through its own code
contract Wallet7702 {
    receive() external payable {}
    function execute(address target, bytes calldata data) external returns (bytes memory r) {
        require(msg.sender == address(this), "only the key itself");
        bool ok; (ok, r) = target.call(data); if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}
