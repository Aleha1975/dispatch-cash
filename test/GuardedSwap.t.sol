// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

contract GuardedSwapTest is Test {
    MockToken tok; MockRouter router; GuardedSwap guard; Wallet acct; address thief = address(0x1111111111111111111111111111111111111111);
    function setUp() public {
        tok = new MockToken(); router = new MockRouter(tok); guard = new GuardedSwap(address(router), address(this), 1000, 1000 ether); /* generous limits; the rate-limit tests deploy their own */ acct = new Wallet();
        vm.deal(address(router), 100 ether); vm.deal(address(acct), 10 ether);
        router.set(1000, 1e15, address(acct));          // 1 ETH -> 1000 tokens; 1 token -> 0.001 ETH (entry price)
    }
    function _buy(uint256 eth) internal returns (uint256) { vm.prank(address(acct)); return guard.buy{value: eth}(address(tok), 1, abi.encodeWithSelector(MockRouter.buy.selector)); }
    function _sell(uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.startPrank(address(acct)); tok.approve(address(guard), amount);
        uint256 out = guard.sell(address(tok), amount, minOut, abi.encodeWithSelector(MockRouter.sell.selector, amount)); vm.stopPrank(); return out; }

    function test_buy_pays_caller_and_records_basis() public {
        uint256 out = _buy(1 ether);
        assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
        (uint256 ethIn, uint256 tokens) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 1 ether); assertEq(tokens, 1000e18);
    }
    function test_buy_output_held_by_guard_is_forwarded() public {
        router.set(1000, 1e15, address(guard));            // router pays the guard instead of the account
        uint256 out = _buy(1 ether); assertEq(out, 1000e18); assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(guard)), 0);
    }
    function test_buy_to_thief_reverts() public {
        router.set(1000, 1e15, thief);
        vm.prank(address(acct)); vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.buy{value: 1 ether}(address(tok), 1, abi.encodeWithSelector(MockRouter.buy.selector));
        assertEq(address(acct).balance, 10 ether);           // nothing left the account
    }
    function test_buy_minOut_zero_reverts() public {
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.MinOutZero.selector);
        guard.buy{value: 1 ether}(address(tok), 0, abi.encodeWithSelector(MockRouter.buy.selector));
    }
    function test_sell_at_entry_price_passes_and_reduces_basis() public {
        _buy(1 ether);
        uint256 out = _sell(500e18, 1);
        assertEq(out, 0.5 ether); assertEq(address(acct).balance, 9.5 ether);
        (uint256 ethIn, uint256 tokens) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 0.5 ether); assertEq(tokens, 500e18);
    }
    function test_sell_to_thief_reverts() public {
        _buy(1 ether); router.set(1000, 1e15, thief);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0, 1));
        guard.sell(address(tok), 500e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 500e18)); vm.stopPrank();
        assertEq(tok.balanceOf(address(acct)), 1000e18);     // tokens never left (whole call reverted)
    }
    function test_sell_below_floor_needs_announcement() public {
        _buy(1 ether); router.set(1000, 1e14, address(acct));   // price fell to 10% of entry (floor is 20%)
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(GuardedSwap.NotAnnounced.selector);
        guard.sell(address(tok), 500e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 500e18));
        guard.announce(address(tok));
        vm.expectRevert(GuardedSwap.NotAnnounced.selector);     // too early
        guard.sell(address(tok), 500e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 500e18));
        vm.warp(block.timestamp + 1 hours);
        uint256 out = guard.sell(address(tok), 500e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 500e18));
        assertEq(out, 0.05 ether);
        assertEq(guard.slowFrom(address(acct), address(tok)), 0);   // one announcement = one slow sale
        tok.approve(address(guard), 500e18);
        vm.expectRevert(GuardedSwap.NotAnnounced.selector);
        guard.sell(address(tok), 500e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 500e18)); vm.stopPrank();
    }
    function test_sell_at_floor_exactly_passes() public {
        _buy(1 ether); router.set(1000, 5e14, address(acct));   // exactly 50% of entry
        uint256 out = _sell(500e18, 1); assertEq(out, 0.25 ether);
    }
    function test_sell_unknown_token_needs_announcement() public {
        tok.mint(address(acct), 100e18);                         // airdropped / bought before the guard existed
        vm.startPrank(address(acct)); tok.approve(address(guard), 100e18);
        vm.expectRevert(GuardedSwap.NotAnnounced.selector);
        guard.sell(address(tok), 100e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 100e18));
        guard.announce(address(tok)); vm.warp(block.timestamp + 1 hours);
        uint256 out = guard.sell(address(tok), 100e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 100e18)); vm.stopPrank();
        assertEq(out, 0.1 ether);
    }
    function test_sell_more_than_basis_applies_floor_to_known_part() public {
        _buy(1 ether); tok.mint(address(acct), 1000e18);         // 1000 bought here + 1000 from elsewhere
        router.set(1000, 6e14, address(acct));                   // 60% of entry: above the floor
        uint256 out = _sell(2000e18, 1); assertEq(out, 1.2 ether);
        (uint256 ethIn, uint256 tokens) = guard.basis(address(acct), address(tok)); assertEq(ethIn, 0); assertEq(tokens, 0);
    }
    function test_fee_on_transfer_token_sells_what_arrived() public {
        _buy(1 ether); tok.setFee(1000);                         // 10% burned on every transfer
        uint256 out = _sell(500e18, 1);                           // 450 arrive at the guard, router pays for 450
        assertEq(out, 0.45 ether);
    }
    function test_sell_minOut_enforced() public {
        _buy(1 ether);
        vm.startPrank(address(acct)); tok.approve(address(guard), 500e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BelowMinOut.selector, 0.5 ether, 0.6 ether));
        guard.sell(address(tok), 500e18, 0.6 ether, abi.encodeWithSelector(MockRouter.sell.selector, 500e18)); vm.stopPrank();
    }
    function test_reentrancy_blocked() public {
        router.setReenter(address(guard));
        _buy(1 ether);                                            // the router re-enters buy() during the swap
        assertFalse(router.reenterOk());                          // and is refused
        (uint256 ethIn, ) = guard.basis(address(router), address(tok)); assertEq(ethIn, 0);
    }
    function testFuzz_basis_tracks_sales(uint96 price, uint8 fracBps) public {
        vm.assume(price > 1e9 && price < 5e16); uint256 frac = uint256(fracBps) % 100 + 1;     // 1..100 %; router holds 100 ETH
        router.set(1000, price, address(acct)); _buy(1 ether);
        uint256 sellAmt = 1000e18 * frac / 100;
        uint256 floor = guard.floorFor(address(acct), address(tok), sellAmt);
        uint256 expectOut = sellAmt * price / 1e18;
        if (expectOut >= floor) { uint256 out = _sell(sellAmt, 1); assertEq(out, expectOut);
            (uint256 ethIn, uint256 tokens) = guard.basis(address(acct), address(tok));
            assertEq(tokens, 1000e18 - sellAmt); assertEq(ethIn, 1 ether - 1 ether * sellAmt / 1000e18); }
        else { vm.startPrank(address(acct)); tok.approve(address(guard), sellAmt); vm.expectRevert(GuardedSwap.NotAnnounced.selector);
            guard.sell(address(tok), sellAmt, 1, abi.encodeWithSelector(MockRouter.sell.selector, sellAmt)); vm.stopPrank(); }
    }
    function test_guard_keeps_nothing() public {
        _buy(1 ether); _sell(100e18, 1);
        assertEq(address(guard).balance, 0); assertEq(tok.balanceOf(address(guard)), 0);
    }
    function test_pause_blocks_trading_and_only_guardian_toggles() public {
        _buy(0.1 ether);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.NotGuardian.selector); guard.setPaused(true);
        guard.setPaused(true);
        vm.startPrank(address(acct));
        vm.expectRevert(GuardedSwap.IsPaused.selector); guard.buy{value: 0.1 ether}(address(tok), 1, abi.encodeWithSelector(MockRouter.buy.selector));
        tok.approve(address(guard), 10e18);
        vm.expectRevert(GuardedSwap.IsPaused.selector); guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 10e18));
        vm.expectRevert(GuardedSwap.IsPaused.selector); guard.announce(address(tok));
        vm.stopPrank();
        guard.setPaused(false);
        uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether);          // trading resumes
        assertEq(address(guard).balance, 0);
    }
    function test_guardian_cannot_touch_funds() public {
        _buy(1 ether);
        // the guardian has no function that moves tokens or ETH: the only state it can set is `paused`
        guard.setPaused(true); guard.setPaused(false);
        assertEq(tok.balanceOf(address(acct)), 1000e18); assertEq(tok.balanceOf(address(this)), 0); assertEq(address(guard).balance, 0);
    }
    function _tight() internal { guard = new GuardedSwap(address(router), address(this), 12, 0.3 ether); }
    function test_rate_limit_sells_per_hour() public {
        _tight(); _buy(0.3 ether);
        for (uint256 i = 0; i < 12; i++) _sell(10e18, 1);
        vm.startPrank(address(acct)); tok.approve(address(guard), 10e18);
        vm.expectRevert(GuardedSwap.RateLimited.selector);
        guard.sell(address(tok), 10e18, 1, abi.encodeWithSelector(MockRouter.sell.selector, 10e18)); vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        uint256 out = _sell(10e18, 1); assertEq(out, 0.01 ether);          // new hour, new budget
    }
    function test_rate_limit_buy_eth_per_hour() public {
        _tight(); _buy(0.2 ether); _buy(0.1 ether);                                     // 0.3 ETH: exactly the budget
        vm.prank(address(acct)); vm.expectRevert(GuardedSwap.RateLimited.selector);
        guard.buy{value: 1}(address(tok), 1, abi.encodeWithSelector(MockRouter.buy.selector));
        vm.warp(block.timestamp + 1 hours);
        _buy(0.3 ether);
    }
    function test_rate_limit_is_per_account() public {
        _tight(); _buy(0.3 ether);
        Wallet other = new Wallet(); vm.deal(address(other), 1 ether); router.set(1000, 1e15, address(other));
        vm.prank(address(other)); uint256 out = guard.buy{value: 0.3 ether}(address(tok), 1, abi.encodeWithSelector(MockRouter.buy.selector));
        assertEq(out, 300e18);
    }
    function test_router_revert_bubbles() public {
        vm.prank(address(acct)); vm.expectRevert();
        guard.buy{value: 1 ether}(address(tok), 1, hex"deadbeef");
    }
}
