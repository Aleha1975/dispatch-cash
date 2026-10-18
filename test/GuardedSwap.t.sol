// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

contract GuardedSwapTest is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    MockToken tok; MockRouter router; GuardedSwap guard; Wallet acct; address exec; address thief = address(0x1111111111111111111111111111111111111111);
    function setUp() public {
        tok = new MockToken(); router = new MockRouter(); exec = address(new Wallet()); guard = new GuardedSwap(address(router), exec, address(this), 1000, 1000 ether); acct = new Wallet();
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
        uint256 out = guard.sell(address(tok), amount, minOut, route(address(tok), K_ETH, amount, address(acct))); vm.stopPrank(); return out; }
    function _expectSell(uint256 amount, bytes4 err) internal {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount); vm.expectRevert(err);
        guard.sell(address(tok), amount, 1, route(address(tok), K_ETH, amount, address(acct))); vm.stopPrank(); }

    // ---- recipient rule ----
    function test_buy_pays_caller_and_records_basis() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
        (uint256 ethIn, uint256 tokens,,) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 1 ether); assertEq(tokens, 1000e18);
    }
    function test_buy_simple_mode_accepted() public {
        vm.prank(address(acct)); uint256 out = guard.buy{value: 1 ether}(address(tok), 1, routeSimple(K_ETH, address(tok), 1 ether, address(acct))); assertEq(out, 1000e18);
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
        (uint256 ethIn, uint256 tokens,,) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 1 ether); assertEq(tokens, 1000e18);
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
        (uint256 ethIn, uint256 tokens, uint256 refEth, uint256 refTok) = guard.basis(address(acct), address(tok));
        assertEq(ethIn, 0); assertEq(tokens, 0); assertEq(refEth, 0); assertEq(refTok, 0);
        router.set(100000, 1e15, address(0)); _buy(0.1 ether);  // a new lot may start at any price
    }
    function test_R3_C1_slow_path_keeps_a_floor_of_its_own() public {
        _buy(1 ether); router.set(1000, 1e14, address(0));       // 10% of entry: below the 20% slow floor
        vm.prank(address(acct)); guard.announce(address(tok), 500e18); vm.warp(block.timestamp + 1 hours);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowFloor.selector, 0.05 ether, 0.1 ether));
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, address(acct))); vm.stopPrank();
        router.set(1000, 25e13, address(0));                     // 25% of entry: announced sale passes
        uint256 out = _sell(500e18, 1); assertEq(out, 0.125 ether);
    }
    function test_R3_C1_guardian_can_cancel_an_armed_announcement() public {
        _buy(1 ether); vm.prank(address(acct)); guard.announce(address(tok), 500e18);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.cancelSlow(address(acct), address(tok));
        guard.cancelSlow(address(acct), address(tok));
        (uint64 from, ) = guard.slow(address(acct), address(tok)); assertEq(from, 0);
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
        (uint256 ethIn,,,) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 1 ether);   // spent = msg.value, not skewed by the stray
        assertEq(address(guard).balance, 5 ether);           // the stray is neither swept to the caller nor counted
        assertEq(address(acct).balance, 9 ether);
    }
    // ---- sells, floor, slow path ----
    function test_sell_at_entry_price_passes_and_reduces_basis() public {
        _buy(1 ether); uint256 out = _sell(500e18, 1);
        assertEq(out, 0.5 ether); assertEq(address(acct).balance, 9.5 ether);
        (uint256 ethIn, uint256 tokens,,) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 0.5 ether); assertEq(tokens, 500e18);
    }
    function test_sell_calldata_recipient_thief_rejected() public {
        _buy(1 ether); vm.startPrank(address(acct)); tok.approve(address(guard), 500e18); vm.expectRevert(GuardedSwap.BadRoute.selector);
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, thief)); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 1000e18);
    }
    function test_sell_router_paying_elsewhere_reverts() public {
        _buy(1 ether); router.set(1000, 1e15, thief);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 500e18, address(acct))); vm.stopPrank();
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
    function test_sell_unknown_token_needs_announcement() public {
        tok.mint(address(acct), 100e18);
        _expectSell(100e18, GuardedSwap.NotAnnounced.selector);
        vm.prank(address(acct)); guard.announce(address(tok), 100e18); vm.warp(block.timestamp + 1 hours);
        uint256 out = _sell(100e18, 1); assertEq(out, 0.1 ether);
    }
    function test_H2_dust_basis_does_not_unlock_the_rest() public {
        tok.mint(address(acct), 1000e18);                    // tokens the gate never saw bought
        _buy(1);                                             // dust buy: 1 wei of ETH -> basis of 1000 wei of tokens
        _expectSell(1000e18, GuardedSwap.NotAnnounced.selector);                      // the whole balance still takes the slow path
        vm.prank(address(acct)); guard.announce(address(tok), 1000e18); vm.warp(block.timestamp + 1 hours);
        uint256 out = _sell(1000e18, 1); assertEq(out, 1 ether);
    }
    function test_sell_more_than_basis_is_slow() public {
        _buy(1 ether); tok.mint(address(acct), 1000e18);
        _expectSell(2000e18, GuardedSwap.NotAnnounced.selector);
        vm.prank(address(acct)); guard.announce(address(tok), 2000e18); vm.warp(block.timestamp + 1 hours);
        uint256 out = _sell(2000e18, 1); assertEq(out, 2 ether);
        (uint256 ethIn, uint256 tokens,,) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 0); assertEq(tokens, 0);
    }
    function test_fee_on_transfer_token_sells_what_arrived() public {
        _buy(1 ether); tok.setFee(1000);                     // 10% burned on every transfer: 450 arrive, the route must be for 450
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        uint256 out = guard.sell(address(tok), 500e18, 1, route(address(tok), K_ETH, 450e18, address(acct))); vm.stopPrank();
        assertEq(out, 0.45 ether);
    }
    function test_sell_minOut_enforced() public {
        _buy(1 ether); vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0.5 ether, 0.6 ether));
        guard.sell(address(tok), 500e18, 0.6 ether, routeMin(address(tok), K_ETH, 500e18, address(acct), 0.6 ether, exec)); vm.stopPrank();
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
    function _tight() internal { guard = new GuardedSwap(address(router), exec, address(this), 12, 0.3 ether); }
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
    function testFuzz_basis_tracks_sales(uint96 price, uint8 fracBps) public {
        vm.assume(price > 1e9 && price < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;     // 1..100 %; router holds 100 ETH
        router.set(1000, price, address(0)); _buy(1 ether);
        uint256 sellAmt = 1000e18 * frac / 100;
        uint256 floor = guard.floorFor(address(acct), address(tok), sellAmt);
        uint256 expectOut = sellAmt * price / 1e18;
        if (expectOut >= floor) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 ethIn, uint256 tokens,,) = guard.basis(address(acct), address(tok));
            assertEq(tokens, 1000e18 - sellAmt); assertApproxEqAbs(ethIn, 1 ether - 1 ether * sellAmt / 1000e18, 1); }
        else _expectSell(sellAmt, GuardedSwap.NotAnnounced.selector);
    }
}
