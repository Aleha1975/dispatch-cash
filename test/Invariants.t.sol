// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

/// Drives one account through random buys, sales at random prices, owner withdrawals of tokens, time jumps and unlocks, over
/// three tokens (v17: lots of several tokens, reconciled together); records the largest budget ever in force when a loss was booked.
contract Handler is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    GuardedSwap public g; MockToken[3] public toks; MockRouter public router; address public exec; address public cold; Wallet public acct;
    uint256 public maxRateSeen; uint256 public lastAmount; uint256 public bookings; uint256 public buys; uint256 public sells; uint256 public refused; uint256 public moves;
    constructor(GuardedSwap g_, MockToken[3] memory t_, MockRouter r_, address exec_, address cold_, Wallet a_) { g = g_; toks = t_; router = r_; exec = exec_; cold = cold_; acct = a_; }
    function tok(uint256 i) external view returns (MockToken) { return toks[i]; }
    function _route(address tin, address tout, uint256 amount, address to) internal view returns (bytes memory) {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = to; d.amount = amount; d.minReturnAmount = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec; return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function buy(uint256 which, uint256 eth) external {
        MockToken tok = toks[which % 3]; eth = bound(eth, 0.001 ether, 5 ether); vm.deal(address(acct), address(acct).balance + eth);
        vm.prank(address(acct)); try g.buy{value: eth}(address(tok), 1, _route(K_ETH, address(tok), eth, address(acct))) { buys++; } catch {}
    }
    function sell(uint256 which, uint256 frac, uint256 priceBps) external {
        MockToken tok = toks[which % 3];
        (uint256 lot, ) = g.lotOf(address(acct), address(tok)); if (lot == 0) return;
        uint256 amount = bound(frac, 1, lot); priceBps = bound(priceBps, 100, 30000);               // 1% .. 300% of entry
        router.set(1000, 1e15 * priceBps / 10000, address(0));
        (, uint256 budget) = g.budgetOf(address(acct)); (uint256 amtBefore, uint64 atBefore) = g.loss(address(acct));
        vm.startPrank(address(acct)); tok.approve(address(g), amount);
        try g.sell(address(tok), amount, 1, _route(address(tok), K_ETH, amount, address(g))) { sells++;
            (uint256 amt, uint64 at) = g.loss(address(acct));
            if (amt != amtBefore || at != atBefore) { bookings++; assertLe(amt, budget); assertEq(at, uint64(block.timestamp)); }   // a booked loss never exceeds the budget quoted before the sale (v17: the quote is the reconciled base)
        } catch { refused++; }
        vm.stopPrank(); router.set(1000, 1e15, address(0));
    }
    /// The owner moves some or all of a token out of the account (a withdrawal outside the gate).
    function ownerMoves(uint256 which, uint256 frac) external {
        MockToken tok = toks[which % 3]; uint256 bal = tok.balanceOf(address(acct)); if (bal == 0) return;
        uint256 amount = bound(frac, 1, bal); vm.prank(address(acct)); tok.transfer(address(0xdead), amount); moves++;
    }
    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1, 10 days)); }
    function unlock() external { address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); g.unlock(a); }
}

contract GuardedSwapInvariants is Test {
    GuardedSwap g; MockToken[3] toks; MockRouter router; Handler h; Wallet acct; address cold = address(0xC01D);
    function setUp() public {
        for (uint256 i = 0; i < 3; i++) toks[i] = new MockToken();
        router = new MockRouter(); address exec = address(new Wallet());
        g = new GuardedSwap(address(router), exec, address(this), cold, 1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(router), 10000 ether); router.set(1000, 1e15, address(0));
        h = new Handler(g, toks, router, exec, cold, acct); targetContract(address(h));
    }
    /// I-1 (v17): the account's cost basis is exactly the sum of the lots in its registry
    function invariant_cost_basis_equals_the_registered_lots() public view {
        address[] memory l = g.lotsOf(address(acct)); uint256 sum;
        for (uint256 i = 0; i < l.length; i++) { (, uint256 ethIn) = g.basis(address(acct), l[i]); sum += ethIn; }
        assertEq(g.costOf(address(acct)), sum);
    }
    /// v17: a token is in the registry exactly when its lot is open, once, and nothing else is listed
    function invariant_registry_is_the_open_lots() public view {
        address[] memory l = g.lotsOf(address(acct)); uint256 open;
        for (uint256 i = 0; i < 3; i++) {
            (uint256 tokens, ) = g.basis(address(acct), address(toks[i])); uint256 seen;
            for (uint256 j = 0; j < l.length; j++) if (l[j] == address(toks[i])) seen++;
            assertEq(seen, tokens > 0 ? 1 : 0); if (tokens > 0) open++;
        }
        assertEq(l.length, open);
    }
    /// I-2: the lot never exceeds what the account holds
    function invariant_lot_within_balance() public view {
        for (uint256 i = 0; i < 3; i++) { (uint256 lot, ) = g.lotOf(address(acct), address(toks[i])); assertLe(lot, toks[i].balanceOf(address(acct))); }
    }
    /// C-1: what is outstanding never exceeds what was booked, and the booked amount never exceeded a budget in force
    function invariant_outstanding_never_exceeds_booked() public view { (uint256 amt, ) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); assertLe(lost, amt); }
    /// C-1/F-4: what is outstanding is never more than what was booked, and is gone within REFILL of the booking
    function invariant_outstanding_gone_within_refill() public view { (uint256 amt, uint64 at) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); if (amt > 0 && block.timestamp >= at + 7 days) assertEq(lost, 0); }
}

/// v16: a stolen executor key on one account -- random buys out of the account's own ETH and sales at 1%..300% of entry, with
/// no time passing, no unlock and no money in or out. Records every loss booked and the largest base (ETH + open lots) seen.
contract ThiefHandler is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    GuardedSwap public g; MockToken public tok; MockRouter public router; address public exec; Wallet public acct;
    uint256 public booked; uint256 public maxBase; uint256 public sells; uint256 public refused;
    constructor(GuardedSwap g_, MockToken t_, MockRouter r_, address exec_, Wallet a_) { g = g_; tok = t_; router = r_; exec = exec_; acct = a_; _seen(); }
    function _base() internal view returns (uint256) { return g.costOf(address(acct)) + address(acct).balance; }
    function _seen() internal { uint256 b = _base(); if (b > maxBase) maxBase = b; }
    function _route(address tin, address tout, uint256 amount, address to) internal view returns (bytes memory) {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = to; d.amount = amount; d.minReturnAmount = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec; return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function buy(uint256 eth, uint256 tpe) external {
        uint256 have = address(acct).balance; if (have < 0.001 ether) return;
        eth = bound(eth, 0.001 ether, have); tpe = bound(tpe, 1, 100000);                            // any price: junk or not
        router.set(tpe, 1e15, address(0)); uint256 b0 = _base();
        vm.prank(address(acct)); try g.buy{value: eth}(address(tok), 1, _route(K_ETH, address(tok), eth, address(acct))) {} catch {}
        assertEq(_base(), b0);                                                                       // a buy never moves the base
        router.set(1000, 1e15, address(0));
    }
    function sell(uint256 frac, uint256 priceBps) external {
        (uint256 lot, uint256 cost) = g.lotOf(address(acct), address(tok)); if (lot == 0) return;
        uint256 amount = bound(frac, 1, lot); priceBps = bound(priceBps, 100, 30000);
        uint256 px = cost * 1e18 / lot * priceBps / 10000; if (px == 0) px = 1;                       // price relative to the lot's average
        router.set(1000, px, address(0));
        (uint256 before, ) = g.loss(address(acct));
        vm.startPrank(address(acct)); tok.approve(address(g), amount);
        try g.sell(address(tok), amount, 1, _route(address(tok), K_ETH, amount, address(g))) { sells++; (uint256 amt, ) = g.loss(address(acct)); booked += amt - before; }
        catch { refused++; }
        vm.stopPrank(); router.set(1000, 1e15, address(0)); _seen();
    }
}

contract GuardedSwapThiefInvariants is Test {
    GuardedSwap g; MockToken tok; MockRouter router; ThiefHandler h; Wallet acct;
    function setUp() public {
        tok = new MockToken(); router = new MockRouter(); address exec = address(new Wallet());
        g = new GuardedSwap(address(router), exec, address(this), address(0xC01D), 1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(router), 100000 ether); router.set(1000, 1e15, address(0)); vm.deal(address(acct), 20 ether);
        h = new ThiefHandler(g, tok, router, exec, acct); targetContract(address(h));
    }
    /// v16: everything a thief can book as loss without time passing stays within 30% of the largest the account ever was
    function invariant_burst_losses_within_30_percent_of_the_account() public view { assertLe(h.booked(), h.maxBase() * 3000 / 10000); }
    /// v16: nothing leaves the account but booked losses (and the ETH stays in the account or its lots)
    function invariant_account_keeps_what_was_not_booked() public view { assertGe(g.costOf(address(acct)) + address(acct).balance + h.booked(), 20 ether); }
}
