// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwapRH.sol";
import "./Mocks.sol";

/// Drives one account through random buys, sales at random prices, exits, time jumps, unlocks, owner transfers and
/// attempts by a dishonest router path; records every breach of the gate's promises in ghost counters.
contract Handler is Test {
    GuardedSwapRH public g; MockToken public tok; MockRouterRH public router; address public cold; SmartAccount public acct; address public thief = address(0x7777);
    uint256 public buys; uint256 public sells; uint256 public refused; uint256 public bookings;
    uint256 public overBudget;      // a booked loss above the budget it was checked against
    uint256 public misPaid;         // a sale whose proceeds did not land on the account, exactly
    uint256 public panics;          // an arithmetic panic (an underflowing lot or cost basis)
    constructor(GuardedSwapRH g_, MockToken t_, MockRouterRH r_, address cold_, SmartAccount a_) { g = g_; tok = t_; router = r_; cold = cold_; acct = a_; }
    function _buyHops() internal view returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](1); h[0].version = 2; h[0].tokenIn = address(0); h[0].tokenOut = address(tok); }
    function _sellHops() internal view returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](1); h[0].version = 2; h[0].tokenIn = address(tok); h[0].tokenOut = address(0); }
    function _panic(bytes memory e) internal { if (e.length >= 4 && bytes4(e) == bytes4(0x4e487b71)) panics++; }
    function buy(uint256 eth) external {
        eth = bound(eth, 0.001 ether, 5 ether); vm.deal(address(acct), address(acct).balance + eth);
        vm.prank(address(acct)); try g.buy{value: eth}(address(tok), 1, _buyHops()) { buys++; } catch (bytes memory e) { _panic(e); }   // a pranked direct call: the gate sees the account
    }
    function sell(uint256 frac, uint256 priceBps, bool asExit, bool dishonest, bool partialFill) external {
        (uint256 lot, ) = g.lotOf(address(acct), address(tok)); if (lot == 0) return;
        uint256 amount = bound(frac, 1, lot); priceBps = bound(priceBps, 100, 30000);
        router.set(1000, 1e15 * priceBps / 10000, dishonest ? thief : address(0)); router.setPullLess(partialFill);   // v2: a partial fill must be refused
        (, uint256 budget) = g.budgetOf(address(acct)); (uint256 amtBefore, uint64 atBefore) = g.loss(address(acct));
        uint256 ethBefore = address(acct).balance;
        acct.exec(address(tok), abi.encodeWithSelector(MockToken.approve.selector, address(g), amount));
        bytes memory call_ = asExit ? abi.encodeWithSelector(GuardedSwapRH.exit.selector, address(tok), amount, uint256(1), _sellHops())
                                    : abi.encodeWithSelector(GuardedSwapRH.sell.selector, address(tok), amount, uint256(1), _sellHops());
        if (asExit) vm.prank(cold, cold);                 // the account runs the call; the cold key is the transaction's origin
        try acct.exec(address(g), call_) returns (bytes memory r) {
            uint256 out = abi.decode(r, (uint256)); sells++;
            if (address(acct).balance - ethBefore != out || out == 0) misPaid++;
            (uint256 amt, uint64 at) = g.loss(address(acct));
            if (amt != amtBefore || at != atBefore) { bookings++; if (amt > budget) overBudget++; }
        } catch (bytes memory e) { refused++; _panic(e); }
        router.set(1000, 1e15, address(0)); router.setPullLess(false);
    }
    function ownerMovesOut(uint256 frac) external { uint256 b = tok.balanceOf(address(acct)); if (b == 0) return; vm.prank(address(acct)); tok.transfer(address(0xdead), bound(frac, 1, b)); }
    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1, 10 days)); }
    function unlock() external { address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); g.unlock(a); }
}

contract GuardedSwapRHInvariants is Test {
    GuardedSwapRH g; MockToken tok; MockToken weth; MockRouterRH router; Handler h; SmartAccount acct; address cold = address(0xC01D);
    function setUp() public {
        tok = new MockToken(); weth = new MockToken(); address pm = address(new Wallet()); router = new MockRouterRH(address(weth), pm);
        address[] memory f = new address[](0); bool[] memory k = new bool[](0);
        g = new GuardedSwapRH(address(router), address(weth), pm, f, k, address(this), cold, 1000, 1000 ether, 1000 ether); acct = new SmartAccount();
        vm.deal(address(router), 1e9 ether); router.set(1000, 1e15, address(0));
        h = new Handler(g, tok, router, cold, acct); targetContract(address(h));
        bytes4[] memory s = new bytes4[](5); s[0] = Handler.buy.selector; s[1] = Handler.sell.selector; s[2] = Handler.warp.selector; s[3] = Handler.unlock.selector; s[4] = Handler.ownerMovesOut.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }
    /// the account's cost basis is exactly the sum of its lots (one token here)
    function invariant_cost_basis_equals_the_lot() public view { (, uint256 ethIn) = g.basis(address(acct), address(tok)); assertEq(g.costOf(address(acct)), ethIn); }
    /// the lot never exceeds what the account holds
    function invariant_lot_within_balance() public view { (uint256 lot, ) = g.lotOf(address(acct), address(tok)); assertLe(lot, tok.balanceOf(address(acct))); }
    /// what is outstanding never exceeds what was booked, and is gone within REFILL of the booking
    function invariant_outstanding_never_exceeds_booked() public view { (uint256 amt, ) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); assertLe(lost, amt); }
    function invariant_outstanding_gone_within_refill() public view { (uint256 amt, uint64 at) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); if (amt > 0 && block.timestamp >= at + 7 days) assertEq(lost, 0); }
    /// (RH) a booked loss never exceeds the budget it was checked against
    function invariant_loss_never_exceeds_budget() public view { assertEq(h.overBudget(), 0); }
    /// (RH) proceeds only to the account: every sale's ETH landed on the account exactly; nothing ever reached the thief; the gate keeps nothing
    function invariant_proceeds_only_to_the_account() public view {
        assertEq(h.misPaid(), 0); assertEq(address(0x7777).balance, 0); assertEq(tok.balanceOf(address(0x7777)), 0);
        assertEq(address(g).balance, 0); assertEq(tok.balanceOf(address(g)), 0); assertEq(tok.allowance(address(g), address(router)), 0);
    }
    /// every run exercised the paths: buys and sales went through, losses were booked or refused
    function afterInvariant() public view { assertGt(h.buys(), 0); assertGt(h.sells(), 0); assertGt(h.bookings() + h.refused(), 0); }
    /// (RH) lot never negative: no lot or cost-basis arithmetic ever underflows
    function invariant_no_underflow() public view { assertEq(h.panics(), 0); }
}
