# -*- coding: utf-8 -*-
# v13 tests: C-1 frozen rate (3 tests), H-1 bricked balanceOf (sell + exit), M-1 fee on the way back, L-3 self check,
# plus a stateful fuzz (invariant) suite over buy/sell/warp/unlock.
import re
# ---- Mocks: balanceOf that can be bricked per address (blacklist-style), keeping the public getter shape
m = open("test/Mocks.sol", encoding="utf-8").read()
assert "bricked" not in m
m = m.replace("    mapping(address => uint256) public balanceOf; mapping(address => mapping(address => uint256)) internal _allow;",
              "    mapping(address => uint256) internal _bal; mapping(address => mapping(address => uint256)) internal _allow;\n"
              "    mapping(address => bool) public bricked;                 // balanceOf(a) reverts for a bricked address (blacklist that also kills reads, round-11 H-1)\n"
              "    function setBricked(address a, bool b) external { bricked[a] = b; }\n"
              "    function balanceOf(address a) public view returns (uint256) { if (bricked[a]) revert(\"bricked\"); return _bal[a]; }", 1)
m = m.replace("    function mint(address to, uint256 a) external { balanceOf[to] += a; }", "    function mint(address to, uint256 a) external { _bal[to] += a; }", 1)
m = m.replace("    function _move(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, \"balance\"); balanceOf[f] -= a; uint256 fee = a * feeBps / 10000; balanceOf[to] += a - fee; }",
              "    function _move(address f, address to, uint256 a) internal { require(_bal[f] >= a, \"balance\"); _bal[f] -= a; uint256 fee = a * feeBps / 10000; _bal[to] += a - fee; }", 1)
assert "_bal[to] += a - fee" in m and "function balanceOf(address a) public view" in m
open("test/Mocks.sol", "w", encoding="utf-8").write(m)

# ---- unit tests
t = open("test/GuardedSwap.t.sol", encoding="utf-8").read()
assert "test_refill_speed_is_fixed_when_the_loss_is_booked" not in t
old = """        vm.warp(block.timestamp + 3.5 days);                                                         // half a week: 0.075 of room came back
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.175 ether);
        vm.warp(block.timestamp + 8.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);   // 0.25 of loss against a 0.15/week refill: gone after ~11.7 days"""
assert old in t
t = t.replace(old, """        vm.warp(block.timestamp + 3.5 days);                                                         // half a week at the 0.3/week rate booked with the loss: 0.15 of room came back
        (uint256 lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0.1 ether);
        vm.warp(block.timestamp + 3.5 days); (lost, ) = guard.budgetOf(address(acct)); assertEq(lost, 0);   // a loss never outlives REFILL at the rate it was booked with""", 1)
new_tests = r'''
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
        router.set(1000, 5e14, address(0)); _sell(50e18, 1);                                         // a new small loss: rate drops to today's budget
        (, uint256 rate, ) = guard.loss(address(acct)); assertLt(rate, 0.3 ether); assertEq(rate, 0.03 ether);
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
        _buy(1 ether); router.setPullLess(true); tok.setFee(1000);                                    // the route takes half; the other half comes back minus a 10% transfer fee
        router.set(1000, 1e15, address(0)); _sell(400e18, 1);
        (uint256 lot, uint256 cost) = guard.lotOf(address(acct), address(tok));
        assertEq(tok.balanceOf(address(acct)), 600e18 + 180e18);                                     // 200 came back as 180
        assertEq(lot, 780e18); assertEq(cost, 0.78 ether);                                           // the lot shrank by 220 (200 sold + 20 burned), not by 200 (M-1)
    }
    function test_constructor_refuses_itself_as_router_or_executor() public {
        address self_ = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("self")); new GuardedSwap(self_, exec, address(this), cold, 12, 0.3 ether, 1 ether);
        vm.expectRevert(bytes("self")); new GuardedSwap(address(router), self_, address(this), cold, 12, 0.3 ether, 1 ether);
    }
'''
# insert before the last closing brace of the test contract
i = t.rstrip().rfind("}")
t = t[:i] + new_tests + "}\n"
open("test/GuardedSwap.t.sol", "w", encoding="utf-8").write(t)

# ---- stateful fuzz: random buy/sell/warp/unlock sequences against the budget invariants
inv = r'''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

/// Drives one account through random buys, sales at random prices, time jumps and unlocks; records the largest budget
/// ever in force when a loss was booked.
contract Handler is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    GuardedSwap public g; MockToken public tok; MockRouter public router; address public exec; address public cold; Wallet public acct;
    uint256 public maxRateSeen; uint256 public lastAmount; uint256 public bookings; uint256 public buys; uint256 public sells; uint256 public refused;
    constructor(GuardedSwap g_, MockToken t_, MockRouter r_, address exec_, address cold_, Wallet a_) { g = g_; tok = t_; router = r_; exec = exec_; cold = cold_; acct = a_; }
    function _route(address tin, address tout, uint256 amount, address to) internal view returns (bytes memory) {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = to; d.amount = amount; d.minReturnAmount = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec; return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function buy(uint256 eth) external {
        eth = bound(eth, 0.001 ether, 5 ether); vm.deal(address(acct), eth);
        vm.prank(address(acct)); try g.buy{value: eth}(address(tok), 1, _route(K_ETH, address(tok), eth, address(acct))) { buys++; } catch {}
    }
    function sell(uint256 frac, uint256 priceBps) external {
        (uint256 lot, ) = g.lotOf(address(acct), address(tok)); if (lot == 0) return;
        uint256 amount = bound(frac, 1, lot); priceBps = bound(priceBps, 100, 30000);               // 1% .. 300% of entry
        router.set(1000, 1e15 * priceBps / 10000, address(0));
        (uint256 carried, uint256 budget) = g.budgetOf(address(acct)); (, uint256 rateBefore, ) = g.loss(address(acct));
        vm.startPrank(address(acct)); tok.approve(address(g), amount);
        try g.sell(address(tok), amount, 1, _route(address(tok), K_ETH, amount, address(g))) { sells++;
            (uint256 amt, uint256 rate, ) = g.loss(address(acct));
            if (amt > carried) { bookings++; if (rate > maxRateSeen) maxRateSeen = rate; assertLe(amt, budget);          // a booked loss never exceeds the budget it was checked against
                if (carried > 0) assertLe(rate, rateBefore); else assertEq(rate, budget); }                              // the refill speed never rises while a loss is outstanding
        } catch { refused++; }
        vm.stopPrank(); router.set(1000, 1e15, address(0));
    }
    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1, 10 days)); }
    function unlock() external { address[] memory a = new address[](1); a[0] = address(acct); vm.prank(cold); g.unlock(a); }
}

contract GuardedSwapInvariants is Test {
    GuardedSwap g; MockToken tok; MockRouter router; Handler h; Wallet acct; address cold = address(0xC01D);
    function setUp() public {
        tok = new MockToken(); router = new MockRouter(); address exec = address(new Wallet());
        g = new GuardedSwap(address(router), exec, address(this), cold, 1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(router), 10000 ether); router.set(1000, 1e15, address(0));
        h = new Handler(g, tok, router, exec, cold, acct); targetContract(address(h));
    }
    /// I-1: the account's cost basis is exactly the sum of its lots (one token here)
    function invariant_cost_basis_equals_the_lot() public view { (, uint256 ethIn) = g.basis(address(acct), address(tok)); assertEq(g.costOf(address(acct)), ethIn); }
    /// I-2: the lot never exceeds what the account holds
    function invariant_lot_within_balance() public view { (uint256 lot, ) = g.lotOf(address(acct), address(tok)); assertLe(lot, tok.balanceOf(address(acct))); }
    /// C-1: what is outstanding never exceeds what was booked, and the booked amount never exceeded a budget in force
    function invariant_outstanding_never_exceeds_booked() public view { (uint256 amt, , ) = g.loss(address(acct)); (uint256 lost, ) = g.budgetOf(address(acct)); assertLe(lost, amt); }
    /// C-1: the running refill rate is one of the budgets that was in force at a booking (never invented later)
    function invariant_rate_was_a_real_budget() public view { (, uint256 rate, ) = g.loss(address(acct)); assertLe(rate, h.maxRateSeen()); }
}
'''
open("test/Invariants.t.sol", "w", encoding="utf-8").write(inv)
print("tests patched; new unit tests:", len(re.findall(r"function test_", new_tests)))
