// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwapRH.sol";
import "./Mocks.sol";

/// Drives one account through random buys and sales over a v3 pool and the v4 PoolManager at random prices, partial fills,
/// a pool paying a thief, exits, time jumps, unlocks and owner transfers; records every breach of the gate's promises.
contract Handler is Test {
    GuardedSwapRH public g; MockToken public tok; MockWETH public weth; MockPoolManager public pm; MockV3Pool public pool; address public cold; SmartAccount public acct; address public thief = address(0x7777);
    uint256 public buys; uint256 public sells; uint256 public refused; uint256 public bookings;
    uint256 public overBudget; uint256 public misPaid; uint256 public panics;
    constructor(GuardedSwapRH g_, MockToken t_, MockWETH w_, MockPoolManager pm_, MockV3Pool p_, address cold_, SmartAccount a_) { g = g_; tok = t_; weth = w_; pm = pm_; pool = p_; cold = cold_; acct = a_; }
    function _hops(bool isBuy, bool viaPool) internal view returns (GuardedSwapRH.Hop[] memory h) {
        h = new GuardedSwapRH.Hop[](1);
        if (viaPool) { h[0].version = 1; h[0].pool = address(pool); h[0].fee = 10000; (h[0].tokenIn, h[0].tokenOut) = isBuy ? (address(weth), address(tok)) : (address(tok), address(weth)); }
        else { h[0].version = 2; h[0].fee = 3000; h[0].tickSpacing = 60; (h[0].tokenIn, h[0].tokenOut) = isBuy ? (address(0), address(tok)) : (address(tok), address(0)); }
    }
    function _panic(bytes memory e) internal { if (e.length >= 4 && bytes4(e) == bytes4(0x4e487b71)) panics++; }
    function buy(uint256 eth, bool viaPool) external {
        eth = bound(eth, 0.001 ether, 5 ether); vm.deal(address(acct), address(acct).balance + eth);
        vm.prank(address(acct)); try g.buy{value: eth}(address(tok), 1, block.timestamp, _hops(true, viaPool)) { buys++; } catch (bytes memory e) { _panic(e); }
    }
    function sell(uint256 frac, uint256 priceBps, bool asExit, bool dishonest, bool partialFill, bool viaPool) external {
        (uint256 lot, ) = g.lotOf(address(acct), address(tok)); if (lot == 0) return;
        uint256 amount = bound(frac, 1, lot); priceBps = bound(priceBps, 100, 30000);
        uint256 px = 1e15 * priceBps / 10000; pm.setRates(1000e18, px); pool.setRates(1000e18, px);
        pool.setPayTo(dishonest ? thief : address(0)); pool.setConsumeHalf(partialFill); pm.setConsumeHalf(partialFill);
        (, uint256 budget) = g.budgetOf(address(acct)); (uint256 amtBefore, uint64 atBefore) = g.loss(address(acct));
        uint256 ethBefore = address(acct).balance;
        acct.exec(address(tok), abi.encodeWithSelector(MockToken.approve.selector, address(g), amount));
        bytes memory call_ = abi.encodeWithSelector(asExit ? GuardedSwapRH.exit.selector : GuardedSwapRH.sell.selector, address(tok), amount, uint256(1), block.timestamp, _hops(false, viaPool));
        if (asExit) vm.prank(cold, cold);
        try acct.exec(address(g), call_) returns (bytes memory r) {
            uint256 out = abi.decode(r, (uint256)); sells++;
            if (address(acct).balance - ethBefore != out || out == 0) misPaid++;
            (uint256 amt, uint64 at) = g.loss(address(acct));
            if (amt != amtBefore || at != atBefore) { bookings++; if (amt > budget) overBudget++; }
        } catch (bytes memory e) { refused++; _panic(e); }
        pm.setRates(1000e18, 1e15); pool.setRates(1000e18, 1e15); pool.setPayTo(address(0)); pool.setConsumeHalf(false); pm.setConsumeHalf(false);
    }
    function ownerMovesOut(uint256 frac) external { uint256 b = tok.balanceOf(address(acct)); if (b == 0) return; vm.prank(address(acct)); tok.transfer(address(0xdead), bound(frac, 1, b)); }
    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1, 10 days)); }
    function unlock() external { address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); g.unlock(a); }
}

contract GuardedSwapRHInvariants is Test {
    GuardedSwapRH g; MockToken tok; MockWETH weth; MockPoolManager pm; MockV3Pool pool; Handler h; SmartAccount acct; address cold = address(0xC01D);
    function setUp() public {
        tok = new MockToken(); weth = new MockWETH(); pm = new MockPoolManager(address(weth));
        pool = new MockV3Pool(address(weth), address(tok), address(weth), address(weth));
        MockFactory fac = new MockFactory(); fac.set(address(weth), address(tok), 10000, address(pool)); pm.init(address(0), address(tok), 3000, 60, address(0));
        address[] memory f = new address[](1); f[0] = address(fac); bool[] memory k = new bool[](1); address[] memory hk = new address[](0);
        g = new GuardedSwapRH(address(weth), address(pm), f, k, hk, address(this), cold, 1000, 1000, 1000 ether, 1000 ether); acct = new SmartAccount();
        vm.deal(address(pm), 1e9 ether); vm.deal(address(weth), 1e9 ether);
        h = new Handler(g, tok, weth, pm, pool, cold, acct); targetContract(address(h));
        bytes4[] memory s = new bytes4[](5); s[0] = Handler.buy.selector; s[1] = Handler.sell.selector; s[2] = Handler.warp.selector; s[3] = Handler.unlock.selector; s[4] = Handler.ownerMovesOut.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }
    function invariant_cost_basis_equals_the_lot() public view { (, uint256 ethIn) = g.basis(address(acct), address(tok)); assertEq(g.costOf(address(acct)), ethIn); }
    function invariant_lot_within_balance() public view { (uint256 lot, ) = g.lotOf(address(acct), address(tok)); assertLe(lot, tok.balanceOf(address(acct))); }
    function invariant_outstanding_never_exceeds_booked() public view { (uint256 amt, ) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); assertLe(lost, amt); }
    function invariant_outstanding_gone_within_refill() public view { (uint256 amt, uint64 at) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); if (amt > 0 && block.timestamp >= at + 7 days) assertEq(lost, 0); }
    function invariant_loss_never_exceeds_budget() public view { assertEq(h.overBudget(), 0); }
    /// proceeds only to the account; nothing to the thief; the gate keeps nothing (ETH, WETH, the token) and grants no allowance
    function invariant_proceeds_only_to_the_account() public view {
        assertEq(h.misPaid(), 0); assertEq(address(0x7777).balance, 0); assertEq(tok.balanceOf(address(0x7777)), 0); assertEq(weth.balanceOf(address(0x7777)), 0);
        assertEq(address(g).balance, 0); assertEq(tok.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
        assertEq(tok.allowance(address(g), address(pool)), 0); assertEq(tok.allowance(address(g), address(pm)), 0);
    }
    function invariant_no_underflow() public view { assertEq(h.panics(), 0); }
    function afterInvariant() public view { assertGt(h.buys(), 0); assertGt(h.sells(), 0); assertGt(h.bookings() + h.refused(), 0); }
}

/// (v5, as Base v16) a stolen executor key on one account -- random buys out of the account's own ETH at any price and sales
/// at 1%..300% of entry, with no time passing, no unlock and no money in or out.
contract ThiefHandler is Test {
    GuardedSwapRH public g; MockToken public tok; MockPoolManager public pm; SmartAccount public acct;
    uint256 public booked; uint256 public maxBase; uint256 public sells; uint256 public refused; uint256 public baseMoved;
    constructor(GuardedSwapRH g_, MockToken t_, MockPoolManager pm_, SmartAccount a_) { g = g_; tok = t_; pm = pm_; acct = a_; _seen(); }
    function _base() internal view returns (uint256) { return g.costOf(address(acct)) + address(acct).balance; }
    function _seen() internal { uint256 b = _base(); if (b > maxBase) maxBase = b; }
    function _hops(bool isBuy) internal view returns (GuardedSwapRH.Hop[] memory h) {
        h = new GuardedSwapRH.Hop[](1); h[0].version = 2; h[0].fee = 3000; h[0].tickSpacing = 60;
        (h[0].tokenIn, h[0].tokenOut) = isBuy ? (address(0), address(tok)) : (address(tok), address(0));
    }
    function buy(uint256 eth, uint256 tpe) external {
        uint256 have = address(acct).balance; if (have < 0.001 ether) return;
        eth = bound(eth, 0.001 ether, have); tpe = bound(tpe, 1, 100000);
        pm.setRates(tpe * 1e18, 1e15); uint256 b0 = _base();
        vm.prank(address(acct)); try g.buy{value: eth}(address(tok), 1, block.timestamp, _hops(true)) {} catch {}
        if (_base() != b0) baseMoved++;                                                     // a buy never moves the base
        pm.setRates(1000e18, 1e15);
    }
    function sell(uint256 frac, uint256 priceBps) external {
        (uint256 lot, uint256 cost) = g.lotOf(address(acct), address(tok)); if (lot == 0) return;
        uint256 amount = bound(frac, 1, lot); priceBps = bound(priceBps, 100, 30000);
        uint256 px = cost * 1e18 / lot * priceBps / 10000; if (px == 0) px = 1;
        pm.setRates(1000e18, px);
        (uint256 before, ) = g.loss(address(acct));
        acct.exec(address(tok), abi.encodeWithSelector(MockToken.approve.selector, address(g), amount));
        try acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, address(tok), amount, uint256(1), block.timestamp, _hops(false))) { sells++; (uint256 amt, ) = g.loss(address(acct)); booked += amt - before; }
        catch { refused++; }
        pm.setRates(1000e18, 1e15); _seen();
    }
}

contract GuardedSwapRHThiefInvariants is Test {
    GuardedSwapRH g; MockToken tok; MockPoolManager pm; ThiefHandler h; SmartAccount acct;
    function setUp() public {
        tok = new MockToken(); MockWETH weth = new MockWETH(); pm = new MockPoolManager(address(weth)); pm.init(address(0), address(tok), 3000, 60, address(0));
        address[] memory f = new address[](0); bool[] memory k = new bool[](0); address[] memory hk = new address[](0);
        g = new GuardedSwapRH(address(weth), address(pm), f, k, hk, address(this), address(0xC01D), 1000, 1000, 1000 ether, 1000 ether);
        acct = new SmartAccount(); vm.deal(address(pm), 1e9 ether); vm.deal(address(acct), 20 ether);
        h = new ThiefHandler(g, tok, pm, acct); targetContract(address(h));
        bytes4[] memory s = new bytes4[](2); s[0] = ThiefHandler.buy.selector; s[1] = ThiefHandler.sell.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }
    /// everything a thief can book as loss without time passing stays within 30% of the largest the account ever was
    function invariant_burst_losses_within_30_percent_of_the_account() public view { assertLe(h.booked(), h.maxBase() * 3000 / 10000); }
    /// nothing leaves the account but booked losses
    function invariant_account_keeps_what_was_not_booked() public view { assertGe(g.costOf(address(acct)) + address(acct).balance + h.booked(), 20 ether); }
    /// every buy leaves the base unchanged
    function invariant_buys_leave_the_base_unchanged() public view { assertEq(h.baseMoved(), 0); }
}
