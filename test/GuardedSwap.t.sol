// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

contract GuardedSwapTest is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    MockToken tok; MockRouter router; GuardedSwap guard; Wallet acct; address exec; address thief = address(0x1111111111111111111111111111111111111111);
    function setUp() public {
        tok = new MockToken(); router = new MockRouter(); exec = address(new Wallet()); guard = new GuardedSwap(address(router), exec, address(this), 1000, 1000 ether, 1000 ether); acct = new Wallet();
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
    function _expectSell(uint256 amount, bytes4 err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount); vm.expectRevert(err);
        guard.sell(address(tok), amount, 1, route(address(tok), K_ETH, amount, address(guard))); vm.stopPrank(); }

    // ---- recipient rule ----
    function test_buy_pays_caller_and_records_basis() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
        (uint256 tokens,, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18); assertEq(refEth, 1 ether); assertEq(refTok, 1000e18);
    }
    function test_buy_simple_mode_rejected() public {            // v8: swapSimpleMode keeps its pools in a field this contract would not check (round-6 L-3)
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, routeSimple(K_ETH, address(tok), 1 ether, address(acct)));
    }
    function test_buy_output_held_by_guard_is_forwarded() public {
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(guard)));
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
    }
    function test_H1_calldata_recipient_thief_rejected() public {
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, thief));
        assertEq(address(acct).balance, 10 ether);
    }
    function test_H1_lying_token_cannot_hide_a_theft() public {
        LyingToken liar = new LyingToken(); liar.arm(address(acct), 1e30);
        // route pays the thief in a real token while `token` is the liar -> dstToken mismatch is caught before anything moves
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.buy{value: 1 ether}(address(liar), 1, route(K_ETH, address(tok), 1 ether, thief));
        // route names the liar itself and the account as recipient: the router executor still pays the thief -> output is measured on the liar...
        router.set(1000, 1e15, thief);
        vm.prank(address(acct)); vm.expectRevert();            // ...but the liar is not a MockToken: the router cannot mint it, the call reverts
        guard.buy{value: 1 ether}(address(liar), 1, route(K_ETH, address(liar), 1 ether, address(acct)));
        assertEq(address(acct).balance, 10 ether);
    }
    function test_buy_router_paying_elsewhere_reverts() public {
        router.set(1000, 1e15, thief);                       // honest calldata, dishonest executor path
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
    }
    function test_route_checks_tokens_amount_selector_fees() public {
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, routeMin(K_ETH, address(tok), 1 ether, address(acct), 1, thief));          // wrong executor
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 5, routeMin(K_ETH, address(tok), 1 ether, address(acct), 1, exec));           // router minimum below ours
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0x8af033fb), thief, GuardedSwap.SwapDescriptionV2(K_ETH, address(tok), new address[](0), new uint256[](0), new address[](0), new uint256[](0), address(acct), 1 ether, 1, 0, ""), bytes(""), bytes("")));  // simple mode, wrong caller
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(0xBEEF), 1 ether, address(acct)));   // wrong dstToken
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 2 ether, address(acct)));      // amount mismatch
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, hex"deadbeef");                                            // unknown selector
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = K_ETH; d.dstToken = address(tok); d.dstReceiver = address(acct); d.amount = 1 ether; d.minReturnAmount = 1;
        d.feeReceivers = new address[](1); d.feeReceivers[0] = thief; d.feeAmounts = new uint256[](1); d.feeAmounts[0] = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));             // fee receivers
        d.feeReceivers = new address[](0); d.feeAmounts = new uint256[](0); d.srcReceivers = new address[](1); d.srcReceivers[0] = thief; d.srcAmounts = new uint256[](1); d.srcAmounts[0] = 0.9 ether; p.desc = d;
        vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));             // R2-2: input diverted on a buy
        vm.stopPrank();
    }
    function test_R2_1_stray_tokens_are_not_swept_or_counted() public {
        tok.mint(address(guard), 500e18);                        // stray tokens sitting in the contract (flash-loan planting)
        uint256 out = _buy(1 ether); assertEq(out, 1000e18);
        (uint256 tokens,, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1000e18); assertEq(refEth, 1 ether); assertEq(refTok, 1000e18);
        assertEq(tok.balanceOf(address(guard)), 500e18);         // untouched, uncredited
        uint256 got = _sell(500e18, 1); assertEq(got, 0.5 ether); assertEq(tok.balanceOf(address(guard)), 500e18);
    }
    function test_R2_3_repeat_buy_cannot_dilute_basis() public {
        _buy(1 ether); router.set(100000, 1e15, address(0));       // 10x cheaper than the recorded entry
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.DilutesBasis.selector);
        guard.buy{value: 0.1 ether}(address(tok), 1, route(K_ETH, address(tok), 0.1 ether, address(acct)));
        router.set(1500, 1e15, address(0)); _buy(0.1 ether);     // 1.5x cheaper (above half the entry) is fine
    }
    function test_R3_H1_repeats_compare_with_the_reference_not_the_running_average() public {
        _buy(1 ether);                                           // reference 1 ETH / 1000 tokens
        router.set(1990, 1e15, address(0)); _buy(1 ether);       // 1.99x cheaper than the reference: allowed
        // v4 would now compare with the running average (~1.5x diluted) and let a further 1.99x step through; v5 compares
        // with the reference: 2.5x cheaper than the reference is refused however many steps were taken
        router.set(2500, 1e15, address(0));
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.DilutesBasis.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
    }
    function test_R3_M1_repeat_buy_cannot_inflate_basis_above_4x() public {
        _buy(1 ether); router.set(200, 1e15, address(0));          // 5x more expensive than the reference
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.DilutesBasis.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
        router.set(300, 1e15, address(0)); _buy(1 ether);        // 3.3x is within the band
    }
    function test_R3_full_exit_resets_the_reference() public {
        _buy(1 ether); _sell(1000e18, 1);
        (uint256 tokens,, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok));
        assertEq(tokens, 0); assertEq(refEth, 0); assertEq(refTok, 0);
        router.set(100000, 1e15, address(0)); _buy(0.1 ether);  // a new lot may start at any price
    }
    function test_R3_C1_slow_path_keeps_a_floor_of_its_own() public {
        _buy(1 ether); router.set(1000, 1e14, address(0));       // 10% of entry: below the 20% slow floor
        vm.prank(address(acct)); guard.announce(address(tok), 500e18); vm.warp(block.timestamp + 1 hours);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowFloor.selector, 0.05 ether, 0.1 ether));
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, address(guard))); vm.stopPrank();
        router.set(1000, 25e13, address(0));                     // 25% of entry: announced sale passes
        uint256 out = _sell(500e18, 1); assertEq(out, 0.125 ether);
    }
    function test_R3_M2_pause_expires_by_itself() public {
        guard.setPaused(true); assertTrue(guard.paused());
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.IsPaused.selector); guard.buy{value: 0.1 ether}(address(tok), 1, route(K_ETH, address(tok), 0.1 ether, address(acct)));
        vm.warp(block.timestamp + 7 days + 1); assertFalse(guard.paused());
        uint256 out = _buy(0.1 ether); assertEq(out, 100e18);   // a lost guardian key cannot freeze buys forever
    }
    function test_R3_L1_announce_rejects_oversized_amount() public {
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.TooLarge.selector); guard.announce(address(tok), uint256(type(uint192).max) + 1);
    }
    function test_R2_4_guardian_rotation_two_step() public {
        address g2 = address(0xBEEF);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.proposeGuardian(g2);
        guard.proposeGuardian(g2);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotPendingGuardian.selector); guard.acceptGuardian();
        vm.prank(g2); guard.acceptGuardian(); assertEq(guard.guardian(), g2); assertEq(guard.pendingGuardian(), address(0));
        vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.setPaused(true);          // the old guardian is out
        vm.prank(g2); guard.setPaused(true); assertTrue(guard.paused());
    }
    function test_R2_5_cancel_and_partial_announcement() public {
        _buy(1 ether); router.set(1000, 25e13, address(0));
        vm.startPrank(address(acct)); guard.announce(address(tok), 500e18); guard.cancelAnnounce(address(tok));
        (uint64 from, ) = guard.slow(address(acct), address(tok)); assertEq(from, 0);
        guard.announce(address(tok), 500e18); vm.stopPrank(); vm.warp(block.timestamp + 1 hours);
        _sell(200e18, 1);
        (, uint192 left) = guard.slow(address(acct), address(tok)); assertEq(left, 300e18);   // remainder stays usable
        _sell(300e18, 1);
        (from, ) = guard.slow(address(acct), address(tok)); assertEq(from, 0);
    }
    function test_R2_6_zero_approve_reverting_token_still_sells() public {
        _buy(1 ether); tok.setRevertOnZeroApprove(true);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether);
    }
    function test_R2_8_direct_eth_refused() public {
        vm.prank(address(acct)); (bool ok, ) = address(guard).call{value: 1 ether}(""); assertFalse(ok);
        vm.deal(address(router), 101 ether); vm.prank(address(router)); (ok, ) = address(guard).call{value: 1 ether}(""); assertFalse(ok);   // not even the router, outside a trade
    }
    function test_buy_minOut_zero_and_non_contract_token() public {
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwap.MinOutZero.selector); guard.buy{value: 1 ether}(address(tok), 0, route(K_ETH, address(tok), 1 ether, address(acct)));
        vm.expectRevert(GuardedSwap.NotAContract.selector); guard.buy{value: 1 ether}(thief, 1, route(K_ETH, thief, 1 ether, address(acct)));
        vm.stopPrank();
    }
    function test_M2_stray_eth_does_not_break_or_skew_buys() public {
        vm.deal(address(guard), 5 ether);                    // force-sent ETH sitting in the contract
        uint256 out = _buy(1 ether); assertEq(out, 1000e18);
        (,, uint256 refEth,) = guard.basis(address(acct), address(tok)); assertEq(refEth, 1 ether);   // spent = msg.value, not skewed by the stray
        assertEq(address(guard).balance, 5 ether);           // the stray is neither swept to the caller nor counted
        assertEq(address(acct).balance, 9 ether);
    }
    // ---- sells, floor, slow path ----
    function test_sell_at_entry_price_passes_and_reduces_basis() public {
        _buy(1 ether); uint256 out = _sell(500e18, 1);
        assertEq(out, 0.5 ether); assertEq(address(acct).balance, 9.5 ether);
        (uint256 tokens,, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok)); assertEq(tokens, 500e18); assertEq(refEth, 1 ether); assertEq(refTok, 1000e18);   // the reference does not move
    }
    function test_sell_calldata_recipient_thief_rejected() public {
        _buy(1 ether); vm.startPrank(address(acct)); tok.approve(address(guard), 500e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, thief)); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 1000e18);
    }
    function test_sell_router_paying_elsewhere_reverts() public {
        _buy(1 ether); router.set(1000, 1e15, thief);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, address(guard))); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 1000e18);
    }
    function test_sell_below_floor_needs_announcement() public {
        _buy(1 ether); router.set(1000, 25e13, address(0));  // price fell to 25% of entry (fast floor 50%, slow floor 20%)
        _expectSell(500e18, GuardedSwap.NotAnnounced.selector);
        vm.prank(address(acct)); guard.announce(address(tok), 500e18);
        _expectSell(500e18, GuardedSwap.NotAnnounced.selector);                       // too early
        vm.warp(block.timestamp + 1 hours);
        uint256 out = _sell(500e18, 1); assertEq(out, 0.125 ether);
        (uint64 from, ) = guard.slow(address(acct), address(tok)); assertEq(from, 0);   // one announcement = one slow sale
        _expectSell(500e18, GuardedSwap.NotAnnounced.selector);
    }
    function test_sell_at_floor_exactly_passes() public { _buy(1 ether); router.set(1000, 5e14, address(0)); uint256 out = _sell(500e18, 1); assertEq(out, 0.25 ether); }
    function test_L2_announcement_bound_to_amount_and_expires() public {
        _buy(1 ether); router.set(1000, 1e14, address(0));
        vm.prank(address(acct)); guard.announce(address(tok), 100e18);
        vm.warp(block.timestamp + 1 hours);
        _expectSell(500e18, GuardedSwap.NotAnnounced.selector);                       // more than announced
        vm.prank(address(acct)); guard.announce(address(tok), 500e18);
        vm.warp(block.timestamp + 1 hours + 24 hours + 1);
        _expectSell(500e18, GuardedSwap.NotAnnounced.selector);                       // expired
    }
    function test_fee_on_transfer_token_sells_what_arrived() public {
        _buy(1 ether); tok.setFee(1000);                     // 10% burned on every transfer: 450 arrive, the route must be for 450
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        uint256 out = guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 450e18, address(guard))); vm.stopPrank();
        assertEq(out, 0.45 ether);
    }
    function test_sell_minOut_enforced() public {
        _buy(1 ether); vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0.5 ether, 0.6 ether));
        guard.sell(address(tok), 500e18, 0.6 ether, routeMin(address(tok), K_ETH, 500e18, address(guard), 0.6 ether, exec)); vm.stopPrank();
    }
    // ---- pause, limits, misc ----
    function test_L3_pause_blocks_buys_and_fast_sales_but_not_announced_exits() public {
        _buy(1 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.setPaused(true);
        guard.setPaused(true);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.IsPaused.selector); guard.buy{value: 0.1 ether}(address(tok), 1, route(K_ETH, address(tok), 0.1 ether, address(acct)));
        _expectSell(10e18, GuardedSwap.IsPaused.selector);
        vm.prank(address(acct)); guard.announce(address(tok), 10e18); vm.warp(block.timestamp + 1 hours);
        uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether);                    // an announced exit works even under pause
        _expectSell(10e18, GuardedSwap.IsPaused.selector);                            // the announcement was consumed
        guard.setPaused(false); out = _sell(10e18, 1); assertEq(out, 0.01 ether);
    }
    function test_guardian_cannot_touch_funds() public {
        _buy(1 ether); guard.setPaused(true); guard.setPaused(false);
        assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(this)), 0); assertEq(address(guard).balance, 0);
    }
    function _tight() internal { guard = new GuardedSwap(address(router), exec, address(this), 12, 0.3 ether, 1 ether); }
    function test_rate_limit_sells_per_hour() public {
        _tight(); _buy(0.3 ether);
        for (uint256 i = 0; i < 12; i++) _sell(10e18, 1);
        _expectSell(10e18, GuardedSwap.RateLimited.selector);
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether);
    }
    function test_rate_limit_buy_eth_per_hour() public {
        _tight(); _buy(0.2 ether); _buy(0.1 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.RateLimited.selector); guard.buy{value: 1}(address(tok), 1, route(K_ETH, address(tok), 1, address(acct)));
        vm.warp(block.timestamp + 1 hours); _buy(0.3 ether);
    }
    function test_rate_limit_is_per_account() public {
        _tight(); _buy(0.3 ether);
        Wallet other = new Wallet(); vm.deal(address(other), 1 ether);
        vm.prank(address(other)); uint256 out = guard.buy{value: 0.3 ether}(address(tok), 1, route(K_ETH, address(tok), 0.3 ether, address(other))); assertEq(out, 300e18);
    }
    function test_reentrancy_blocked() public {
        router.setReenter(address(guard)); _buy(1 ether);
        assertFalse(router.reenterOk());                     // the router's re-entrant call into the guard is refused
        (uint64 from, ) = guard.slow(address(router), address(tok)); assertEq(from, 0);
    }
    function test_guard_keeps_nothing() public { _buy(1 ether); _sell(100e18, 1); assertEq(address(guard).balance, 0); assertEq(tok.balanceOf(address(guard)), 0); }
    function test_M2_stray_eth_does_not_break_or_skew_buys_v4() public {
        vm.deal(address(guard), 5 ether); uint256 out = _buy(1 ether); assertEq(out, 1000e18); assertEq(address(guard).balance, 5 ether);
    }
    function test_router_revert_bubbles() public {
        router.set(0, 0, address(0));                        // a router that mints nothing -> output 0 -> BelowMinOut; and a failing router -> RouterFailed
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
    }

    // ---- round 4 ----
    function test_R4_H2_full_exit_and_new_lot_clear_the_announcement() public {
        _buy(0.01 ether);
        vm.prank(address(acct)); guard.announce(address(tok), 10e18); vm.warp(block.timestamp + 1 hours);
        _sell(10e18, 1);                                             // full exit of lot A
        (uint64 from, ) = guard.slow(address(acct), address(tok)); assertEq(from, 0);     // the stale announcement is gone
        _buy(1 ether); vm.prank(address(acct)); guard.announce(address(tok), 1000e18);
        _buy(0.1 ether);                                             // any buy clears it too (round-7 M-1)
        (from, ) = guard.slow(address(acct), address(tok)); assertEq(from, 0);
        router.set(1000, 2e14, address(0));                          // 20% of entry: slow, and nothing is announced
        _expectSell(1000e18, GuardedSwap.NotAnnounced.selector);
    }
    function test_R4_H1_pause_cannot_be_rearmed_and_cancel_is_bounded() public {
        _buy(1 ether);
        guard.setPaused(true);
        vm.expectRevert(GuardedSwap.PauseCooldown.selector); guard.setPaused(true);          // no re-stamping an active pause
        vm.warp(block.timestamp + 7 days + 1); assertFalse(guard.paused());
        vm.expectRevert(GuardedSwap.PauseCooldown.selector); guard.setPaused(true);          // one day of open fast path after an expiry
        vm.warp(block.timestamp + 1 days); guard.setPaused(true); assertTrue(guard.paused());
        guard.setPaused(false);
        vm.expectRevert(GuardedSwap.PauseCooldown.selector); guard.setPaused(true);          // and after an unpause
        vm.warp(block.timestamp + 1 days); guard.setPaused(true); guard.setPaused(false);
    }
    function test_R4_M1_sell_eth_per_hour_is_capped() public {
        _tight(); vm.deal(address(acct), 100 ether);
        for (uint256 i = 0; i < 4; i++) { _buy(0.3 ether); vm.warp(block.timestamp + 1 hours); }   // 1.2 ETH of basis over four hours
        router.set(1000, 1e15, address(0));
        _sell(900e18, 1);                                            // 0.9 ETH out
        _expectSell(200e18, GuardedSwap.RateLimited.selector);        // 1.1 ETH would exceed 1 ETH an hour
        vm.warp(block.timestamp + 1 hours); uint256 out = _sell(200e18, 1); assertEq(out, 0.2 ether);
    }
    function test_R4_M2_permit_in_the_route_is_refused() public {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = K_ETH; d.dstToken = address(tok); d.dstReceiver = address(acct); d.amount = 1 ether; d.minReturnAmount = 1; d.permit = hex"01";
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));
    }
    function test_R4_M3_leftover_allowance_does_not_brick_a_zero_first_token() public {
        _buy(1 ether); tok.setZeroFirst(true); tok.setRevertOnZeroApprove(true); router.setPullLess(true);   // the route pulls half, approve(0) fails -> allowance stays
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        guard.sell(address(tok), 100e18, 1, route(address(tok), K_ETH, 100e18, address(guard))); vm.stopPrank();
        assertGt(tok.allowance(address(guard), address(router)), 0);
        tok.setRevertOnZeroApprove(false);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether);   // the next sale resets to zero first and goes through (the mock pays for the whole amount)
    }
    function test_R4_L1_floors_round_up_never_to_zero() public {
        router.set(1e21, 1, address(0)); _buy(1);                    // 1 wei of ETH for 1e21 tokens
        assertEq(guard.floorFor(address(acct), address(tok), 1), 1); // v5 truncated this to 0
        router.set(1e21, 0, address(0));
        vm.startPrank(address(acct)); tok.approve(address(guard), 1); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.sell(address(tok), 1, 1, route(address(tok), K_ETH, 1, address(guard))); vm.stopPrank();   // a zero-return sale never passes (minOut >= 1, and the floor is 1 wei, not 0)
    }
    function test_R4_L2_too_many_receivers_rejected() public {
        _buy(1 ether);
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = address(tok); d.dstToken = K_ETH; d.dstReceiver = address(guard); d.amount = 10e18; d.minReturnAmount = 1;
        d.srcReceivers = new address[](9); d.srcAmounts = new uint256[](9); for (uint256 i = 0; i < 9; i++) { d.srcReceivers[i] = address(router); d.srcAmounts[i] = 1; }
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); vm.stopPrank();
    }
    function test_R4_L4_guardian_proposal_rules_and_expiry() public {
        vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.proposeGuardian(address(0));
        vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.proposeGuardian(address(this));
        vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.proposeGuardian(address(router));
        vm.expectRevert(GuardedSwap.BadGuardian.selector); guard.proposeGuardian(exec);
        address g2 = address(0xBEEF); guard.proposeGuardian(g2); vm.warp(block.timestamp + 7 days + 1);
        vm.prank(g2); vm.expectRevert(GuardedSwap.NotPendingGuardian.selector); guard.acceptGuardian();   // a forgotten proposal lapses
        guard.proposeGuardian(g2); vm.prank(g2); guard.acceptGuardian(); assertEq(guard.guardian(), g2);
    }
    function test_R4_L6_router_overpaying_is_a_named_error() public {
        router.setOverpay(1 wei);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.RouterOverpaid.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
    }

    // ---- round 5 ----
    function test_R5_C2_partial_sales_never_erode_the_floor() public {
        router.set(3, 0, address(0)); _buy(1);                                // a dust lot: 1 wei of ETH for 3 tokens (reference 1/3 wei per token)
        router.set(3, 333333333333333333, address(0));                       // the router pays 1 wei for 3 tokens, 0 for 1 or 2 (rounding)
        vm.startPrank(address(acct)); tok.approve(address(guard), 1); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.sell(address(tok), 1, 1, route(address(tok), K_ETH, 1, address(guard))); vm.stopPrank();
        assertEq(guard.floorFor(address(acct), address(tok), 2), 1);         // v6 could zero the recorded cost on a partial sale and with it every later floor
    }
    function test_R5_C2_real_lot_partial_sales_keep_the_reference_floor() public {
        _buy(1 ether); _sell(999e18, 1);                                     // sell almost everything at the entry price
        assertEq(guard.floorFor(address(acct), address(tok), 1e18), 0.0005 ether);   // the last token is still protected at 50% of the reference
        router.set(1000, 4e14, address(0)); _expectSell(1e18, GuardedSwap.NotAnnounced.selector);
    }
    function test_R5_C3_a_repeat_buy_at_the_boundary_cannot_move_the_floor() public {
        _buy(1 ether);                                                       // reference: 0.001 ETH per token, 1000 tokens
        router.set(2000, 1e15, address(0)); _buy(0.3 ether);                 // a repeat at exactly half the reference: 600 tokens (allowed)
        (uint256 tokens,, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok)); assertEq(tokens, 1600e18); assertEq(refEth, 1 ether); assertEq(refTok, 1000e18);
        // v6 took the floor from the blended average (1.3 ETH / 1600 = 0.0008125 per token): the whole lot could go for 0.65 ETH on the fast path.
        // v7 takes it from the reference: selling all 1600 tokens needs 50% of 0.001 each = 0.8 ETH
        assertEq(guard.floorFor(address(acct), address(tok), 1600e18), 0.8 ether);
        router.set(2000, 5e14 - 1, address(0)); _expectSell(1600e18, GuardedSwap.NotAnnounced.selector);   // just under 50% of the reference: slow
        router.set(2000, 5e14, address(0)); uint256 out = _sell(1600e18, 1); assertEq(out, 0.8 ether);     // exactly 50%: fast
    }
    function test_R5_I4_allowance_that_misbehaves_does_not_block_sales() public {
        _buy(1 ether); tok.setAllowanceReverts(true);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether);
    }

    // ---- round 6 / v8 ----
    function test_R6_H1_expensive_repeat_buys_raise_the_floor_with_their_cost() public {
        _buy(0.01 ether);                                                    // reference: 0.001 ETH per token, 10 tokens
        router.set(250, 1e15, address(0)); _buy(4 ether);                    // a repeat at exactly 4x the reference: 1000 tokens for 4 ETH (allowed)
        (uint256 tokens, uint256 ethIn, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok));
        assertEq(tokens, 1010e18); assertEq(ethIn, 4.01 ether); assertEq(refEth, 0.01 ether); assertEq(refTok, 10e18);
        // v7 froze the floor at the reference: the whole lot could go for 0.505 ETH (12.6% of the 4.01 ETH paid).
        // v8 takes the higher of the reference and the running average: 50% of what was actually paid
        assertEq(guard.floorFor(address(acct), address(tok), 1010e18), 2.005 ether);
        router.set(250, 198e13, address(0)); _expectSell(1010e18, GuardedSwap.NotAnnounced.selector);   // 1.9998 ETH: below
        router.set(250, 2e15, address(0)); uint256 out = _sell(1010e18, 1); assertEq(out, 2.02 ether);   // 2.02 ETH: fast
    }
    function test_R6_cheap_repeat_cannot_pull_the_floor_below_the_reference() public {
        _buy(1 ether); router.set(2000, 1e15, address(0)); _buy(0.3 ether);   // a repeat at half the reference (round-5 C-3 shape)
        assertEq(guard.floorFor(address(acct), address(tok), 1600e18), 0.8 ether);   // 50% of the reference for every token, not of the diluted average
    }
    function test_R6_only_the_lot_is_for_sale() public {
        tok.mint(address(acct), 100e18);                                     // untracked tokens: an airdrop, or a position opened before the gate
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 0, 100e18));
        guard.sell(address(tok), 100e18, 1, route(address(tok), K_ETH, 100e18, address(guard))); vm.stopPrank();
        _buy(1 ether);                                                       // a lot of 1000: selling 1100 is refused outright, announced or not
        vm.prank(address(acct)); guard.announce(address(tok), 1000e18); vm.warp(block.timestamp + 1 hours);
        vm.startPrank(address(acct)); tok.approve(address(guard), 1100e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 1000e18, 1100e18));
        guard.sell(address(tok), 1100e18, 1, route(address(tok), K_ETH, 1100e18, address(guard))); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 1100e18);                     // nothing moved
    }
    function test_R6_dust_lot_does_not_unlock_untracked_tokens() public {
        tok.mint(address(acct), 1000e18); _buy(1);                           // 1 wei buys a dust lot of 1000 units; the 1000 untracked tokens stay out of reach
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 1000, 1000e18));
        guard.sell(address(tok), 1000e18, 1, route(address(tok), K_ETH, 1000e18, address(guard))); vm.stopPrank();
    }
    function test_R6_no_guardian_power_over_announcements() public {
        _buy(1 ether); vm.prank(address(acct)); guard.announce(address(tok), 500e18);
        (bool ok, ) = address(guard).call(abi.encodeWithSignature("cancelSlow(address,address)", address(acct), address(tok))); assertFalse(ok);
        vm.warp(block.timestamp + 1 hours); router.set(1000, 3e14, address(0)); uint256 out = _sell(500e18, 1); assertEq(out, 0.15 ether);   // an announced exit always matures
    }
    function test_R6_M1_zero_first_token_with_a_leftover_allowance_still_sells() public {
        _buy(1 ether); tok.setZeroFirst(true); router.setPullLess(true); tok.setRevertOnZeroApprove(true);   // every route leaves half the allowance behind and the cleanup approve(0) fails
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether);
        assertGt(tok.allowance(address(guard), address(router)), 0);
        // a token that refuses approve(0) AND wants zero first is the one unsupported combination: it fails closed, nothing moves
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwap.TransferFailed.selector);
        guard.sell(address(tok), 100e18, 1, route(address(tok), K_ETH, 100e18, address(guard))); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 950e18);                     // the route pulled 50, the other 50 came back; the refused sale moved nothing
        tok.setRevertOnZeroApprove(false); vm.prank(address(acct)); tok.approve(address(guard), 0);   // the account's own leftover approval to the guard is reset too
        out = _sell(100e18, 1); assertEq(out, 0.1 ether);                     // direct approve fails (zero first), zero, approve again: the sale goes through
    }
    function test_R6_L2_state_is_final_before_eth_leaves() public {
        SpyWallet spy = new SpyWallet(); spy.set(guard, address(tok)); vm.deal(address(spy), 2 ether); router.setRefund(0.1 ether);
        uint256 out = spy.buy(1 ether, 1, route(K_ETH, address(tok), 1 ether, address(spy)));
        assertEq(spy.hooks(), 1); assertEq(spy.seenTokens(), out);           // the refund hook already sees the new lot
        (uint256 tokens, uint256 ethIn,,) = guard.basis(address(spy), address(tok)); assertEq(tokens, out); assertEq(ethIn, 0.9 ether);   // and the change was not counted as spent
    }
    function test_R6_zero_cost_lot_refused() public {
        router.setRefund(1 ether); vm.prank(address(acct)); vm.expectRevert(GuardedSwap.ZeroAmount.selector);
        guard.buy{value: 1 ether}(address(tok), 1, route(K_ETH, address(tok), 1 ether, address(acct)));
    }
    function test_R6_L1_lot_size_bounded() public {
        router.set(2e40, 1e15, address(0));                                  // 2e40 raw units per wei of ETH
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.TooLarge.selector);
        guard.buy{value: 1}(address(tok), 1, route(K_ETH, address(tok), 1, address(acct)));
    }

    // ---- round 7 / v9 ----
    function test_R7_C1_any_router_flag_is_refused() public {
        _buy(1 ether);
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = address(tok); d.dstToken = K_ETH; d.dstReceiver = address(guard); d.amount = 100e18; d.minReturnAmount = 1; d.flags = 0x20;   // _SIMPLE_SWAP: the router would take its pools from targetData
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 100e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); vm.stopPrank();
        d.srcToken = K_ETH; d.dstToken = address(tok); d.dstReceiver = address(acct); d.amount = 1 ether; d.flags = 1; p.desc = d;
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p));
        for (uint256 f = 2; f <= 0x100; f <<= 1) { d.flags = f; p.desc = d; vm.prank(address(acct)); vm.expectRevert(GuardedSwap.BadRoute.selector); guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); }
        assertEq(tok.balanceOf(address(acct)), 1000e18);
        d.flags = 0x200; p.desc = d;                                          // the inert bit live routes carry is the only one accepted
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); assertEq(out, 1000e18);
    }
    function test_R7_L1_a_sale_is_paid_through_the_guard_only() public {
        _buy(1 ether);
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 100e18, 1, route(address(tok), K_ETH, 100e18, address(acct))); vm.stopPrank();   // paid to the account directly: refused
        uint256 before = address(acct).balance; uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether); assertEq(address(acct).balance - before, 0.1 ether); assertEq(address(guard).balance, 0);
    }
    function test_R7_M1_announcement_never_exceeds_the_lot() public {
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 0, 1)); guard.announce(address(tok), 1);
        _buy(1 ether);
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 1000e18, 1001e18)); guard.announce(address(tok), 1001e18);
        vm.prank(address(acct)); guard.announce(address(tok), 1000e18);
        (, uint192 amt) = guard.slow(address(acct), address(tok)); assertEq(amt, 1000e18);
    }
    function test_R7_M3_fee_on_transfer_lot_closes_on_a_full_sale() public {
        _buy(1 ether); tok.setFee(1000);                             // 10% burned on every transfer: 900 arrive, the route is for 900
        vm.startPrank(address(acct)); tok.approve(address(guard), 1000e18);
        uint256 out = guard.sell(address(tok), 1000e18, 1, route(address(tok), K_ETH, 900e18, address(guard))); vm.stopPrank();
        assertEq(out, 0.9 ether);
        (uint256 tokens,,,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0);   // v8 left 100 in the lot forever
    }
    function test_R7_M3_lot_closes_when_the_account_holds_nothing() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 600e18);   // a negative rebase, or tokens moved away by the owner
        uint256 out = _sell(400e18, 1); assertEq(out, 0.4 ether);
        (uint256 tokens,,,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0);   // the lot closes with the balance, not at 600 stale units
        router.set(100000, 1e15, address(0)); _buy(0.1 ether);     // and a new lot may start at any price
    }
    function test_R7_sale_state_is_final_before_eth_leaves() public {
        SpyWallet spy = new SpyWallet(); spy.set(guard, address(tok)); vm.deal(address(spy), 2 ether);
        uint256 got = spy.buy(1 ether, 1, route(K_ETH, address(tok), 1 ether, address(spy)));
        spy.sell(100e18, 1, route(address(tok), K_ETH, 100e18, address(guard)));
        assertEq(spy.hooks(), 1); assertEq(spy.seenTokens(), got - 100e18);   // the payout hook already sees the reduced lot
    }

    // ---- round 8 / v10 ----
    function test_R8_L1_tokens_the_owner_moved_out_leave_the_lot() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 700e18);   // the owner moved 700 out directly
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 300e18, 1000e18)); guard.announce(address(tok), 1000e18);   // the lot is 300 now
        vm.startPrank(address(acct)); tok.approve(address(guard), 300e18); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.NotInLot.selector, 300e18, 1000e18));
        guard.sell(address(tok), 1000e18, 1, route(address(tok), K_ETH, 1000e18, address(guard))); vm.stopPrank();
        vm.prank(address(acct)); guard.announce(address(tok), 300e18);                                               // a call that goes through reconciles the lot
        (uint256 tokens, uint256 ethIn,,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 300e18); assertEq(ethIn, 0.3 ether);   // pro rata, as if sold at cost
        assertEq(guard.floorFor(address(acct), address(tok), 300e18), 0.15 ether);
        uint256 out = _sell(300e18, 1); assertEq(out, 0.3 ether);                                                      // and the rest sells at the entry price as before
        (tokens,,,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 0);
    }
    function test_R8_L1_an_emptied_lot_closes_and_rebuys_are_not_bricked() public {
        _buy(1 ether); vm.prank(address(acct)); tok.transfer(address(0xdead), 1000e18);   // everything moved out directly
        router.set(100000, 1e15, address(0)); _buy(0.1 ether);                            // 100x cheaper: v9 would revert DilutesBasis against the stale reference
        (uint256 tokens,, uint256 refEth,) = guard.basis(address(acct), address(tok)); assertEq(tokens, 10000e18); assertEq(refEth, 0.1 ether);
    }
    function test_R8_L4_a_sale_that_moves_nothing_is_refused() public {
        _buy(1 ether); router.setPullNone(true); vm.deal(address(router), 100 ether);
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18); vm.expectRevert(GuardedSwap.ZeroAmount.selector);
        guard.sell(address(tok), 100e18, 1, route(address(tok), K_ETH, 100e18, address(guard))); vm.stopPrank();
        (, uint64 sells,,) = guard.window(address(acct)); assertEq(sells, 0);            // no slot spent, no floor dodged
    }
    function test_R8_I4_the_gate_itself_is_not_a_receiver() public {
        _buy(1 ether);
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = address(tok); d.dstToken = K_ETH; d.dstReceiver = address(guard); d.amount = 10e18; d.minReturnAmount = 1;
        d.srcReceivers = new address[](1); d.srcAmounts = new uint256[](1); d.srcReceivers[0] = address(guard); d.srcAmounts[0] = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec;
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(bytes4(0xe21fd0e9), p)); vm.stopPrank();
    }
    function testFuzz_basis_tracks_sales(uint96 price, uint8 fracBps) public {
        vm.assume(price > 1e9 && price < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;     // 1..100 %; router holds 100 ETH
        router.set(1000, price, address(0)); _buy(1 ether);
        uint256 sellAmt = 1000e18 * frac / 100;
        uint256 floor = guard.floorFor(address(acct), address(tok), sellAmt);
        uint256 expectOut = sellAmt * price / 1e18;
        if (expectOut >= floor) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 tokens,, uint256 refEth,) = guard.basis(address(acct), address(tok));
            assertEq(tokens, 1000e18 - sellAmt); assertEq(refEth, tokens == 0 ? 0 : 1 ether); }   // the reference moves only on a full exit
        else _expectSell(sellAmt, GuardedSwap.NotAnnounced.selector);
    }
}
