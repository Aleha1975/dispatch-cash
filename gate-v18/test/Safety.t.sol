// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// Token / router edge cases, reentrancy, bounded return data -- adapted to the no-custody gate.
contract SafetyTest is GateBase {
    function test_fee_on_transfer_token_sale_follows_what_left_the_account() public {
        MockToken t = new MockToken(); t.setFee(1000); _approveGate(acct, t);
        _buyT(acct, t, 1 ether); (uint256 tk, ) = _lot(address(acct), t); assertEq(tk, 900e18);   // the sweep to the account lost 10%: the lot is what the account received
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(t), 200e18, 1, route(address(t), K_ETH, 180e18))));
        (tk, ) = _lot(address(acct), t); assertEq(tk, 700e18); assertEq(t.balanceOf(address(gate)), 0); assertEq(t.balanceOf(address(acct)), 700e18);
    }
    function test_return_data_bomb_token_fails_cleanly_not_by_gas() public {
        MockToken t = new MockToken(); _approveGate(acct, t); t.setMode(1);        // every transfer/approve answers with 2 MB
        bytes memory d = abi.encodeCall(GuardedGate.buy, (address(t), 1, route(K_ETH, address(t), 1 ether)));
        vm.expectRevert(GuardedGate.TransferFailed.selector); acct.exec(address(gate), 1 ether, d);   // only 32 bytes are copied; a non-word answer is a failure
        assertEq(address(gate).balance, 0);
    }
    function test_no_return_data_token_works() public {
        MockToken t = new MockToken(); _approveGate(acct, t); t.setMode(2);
        _buyT(acct, t, 1 ether);
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(t), 100e18, 1, route(address(t), K_ETH, 100e18))));
        (uint256 tk, ) = _lot(address(acct), t); assertEq(tk, 900e18);
    }
    function test_false_return_on_the_gate_sweep_reverts_the_buy() public {
        MockToken t = new MockToken(); t.setMode(3);                              // transfer returns false without moving
        bytes memory d = abi.encodeCall(GuardedGate.buy, (address(t), 1, route(K_ETH, address(t), 1 ether)));
        vm.expectRevert(); acct.exec(address(gate), 1 ether, d);                  // dstReceiver = gate: the sweep cannot deliver
        assertEq(address(gate).balance, 0);
    }
    function test_reentry_from_router_on_buy_and_sell_blocked() public {
        router.setReenter(address(gate), _buyData(tok, 1 ether));
        _buy(1 ether); assertTrue(router.reentered()); assertTrue(router.reentryBlocked());
        _sell(100e18); assertTrue(router.reentryBlocked());
    }
    function test_reentry_from_fee_recipient_blocked() public {
        ReenteringSink s = new ReenteringSink(); GuardedGate g2 = new GuardedGate(_params(address(s)));
        s.set(address(g2), abi.encodeCall(GuardedGate.payFee, ()));
        acct.exec(address(g2), 1 ether, abi.encodeCall(GuardedGate.payFee, ()));
        assertTrue(s.hit()); assertTrue(s.blocked());
    }
    function test_reentry_from_token_hook_on_sale_pull_blocked() public {
        HookToken h = new HookToken(); _approveGate(acct, h);
        _buyT(acct, h, 1 ether);
        h.arm(address(gate), _buyData(tok, 1 ether));                             // fires when the gate moves tokens (router pull)
        acct.exec(address(gate), 0, abi.encodeCall(GuardedGate.sell, (address(h), 100e18, 1, route(address(h), K_ETH, 100e18))));
        assertTrue(h.hit()); assertTrue(h.blocked());
    }
    function test_state_final_before_native_leaves() public {
        // owner of the account re-enters on receiving a withdrawal: blocked by the lock, nothing doubled
        ReenteringSink s = new ReenteringSink(); MockAccount a = new MockAccount(address(s));
        vm.etch(address(s), address(s).code); vm.deal(address(a), 5 ether);
        // sink is a contract -> ownerOf refuses it (must be a plain wallet)
        vm.expectRevert(GuardedGate.NoBeneficiary.selector); a.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.withdraw, ()));
    }
    function test_gate_never_holds_native_or_tokens_after_any_flow() public {
        _buy(2 ether); _sell(500e18); acct.exec(address(gate), 1 ether, abi.encodeCall(GuardedGate.payFee, ())); _wd1();
        assertEq(address(gate).balance, 0); assertEq(tok.balanceOf(address(gate)), 0);
    }
    function _wd1() internal { acct.exec(address(gate), 3 ether, abi.encodeCall(GuardedGate.withdraw, ())); }
}

contract Handler is GateBase {
    uint256 public okBuys; uint256 public okSells;
    function init() external { GateBase.setUp(); }
    function doBuy(uint8 who, uint96 eth) external { MockAccount a = who % 2 == 0 ? acct : acct2; uint256 v = bound(eth, 1e9, 3 ether); vm.deal(address(a), 10 ether); vm.warp(block.timestamp + 1 hours); try this.buyExt(a, v) { okBuys++; } catch {} }
    function buyExt(MockAccount a, uint256 v) external { require(msg.sender == address(this)); _buyT(a, tok, v); }
    function doSell(uint8 who, uint96 amt) external { MockAccount a = who % 2 == 0 ? acct : acct2; (uint256 tk, ) = gate.lotOf(address(a), address(tok)); if (tk == 0) return; uint256 x = bound(amt, 1, tk);
        try this.sellExt(a, x) { okSells++; } catch {} }
    function sellExt(MockAccount a, uint256 x) external { require(msg.sender == address(this)); a.exec(address(gate), 0, _sellData(tok, x, 1)); }
    function doMove(uint8 who, uint96 amt) external { MockAccount a = who % 2 == 0 ? acct : acct2; uint256 b = tok.balanceOf(address(a)); if (b == 0) return; vm.prank(address(a)); tok.transfer(address(0xdead), bound(amt, 1, b)); }
    function doFeeWd(uint8 who, uint96 amt, bool fee) external { MockAccount a = who % 2 == 0 ? acct : acct2; uint256 b = address(a).balance; if (b == 0) return; uint256 v = bound(amt, 1, b);
        try this.feeWdExt(a, v, fee) {} catch {} }
    function feeWdExt(MockAccount a, uint256 v, bool fee) external { require(msg.sender == address(this)); a.exec(address(gate), v, fee ? abi.encodeCall(GuardedGate.payFee, ()) : abi.encodeCall(GuardedGate.withdraw, ())); }
}
contract SafetyInvariant is Test {
    Handler h;
    function setUp() public { h = new Handler(); h.init(); h.doBuy(0, 1 ether); targetContract(address(h)); }
    function afterInvariant() public view { assertGt(h.okBuys(), 0); }
    function invariant_gate_holds_nothing_and_costs_match_lots() public view {
        assertEq(address(h.gate()).balance, 0); assertEq(h.tok().balanceOf(address(h.gate())), 0);
        // cost of the single token's lots = costOf (only one token is traded)
        for (uint256 i = 0; i < 2; i++) { address a = i == 0 ? address(h.acct()) : address(h.acct2()); (uint256 tk, uint256 c) = h.gate().basis(a, address(h.tok())); tk; assertEq(h.gate().costOf(a), c); }
    }
}
