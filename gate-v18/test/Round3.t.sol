// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";

/// Round 3: fixes for external audit job 1206 (L-1 window lock-out; the reference tests were removed in round 4).
contract Round3Test is GateBase {
    function _fee(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.payFee, ())); }
    function _gas(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.refundGas, ())); }
    function _tryBuy(uint256 eth) internal returns (bool ok) { (ok, ) = address(acct).call(abi.encodeCall(MockAccount.exec, (address(gate), eth, _buyData(tok, eth)))); }


    // ---------- L-1: ring windows ----------
    function test_L1_full_spend_then_buy_after_about_70_minutes_not_at_59() public {
        vm.warp((block.timestamp / 600 + 1) * 600);                       // start of a 10-minute slot (worst case: the spend stays counted for span + 1 slot)
        uint256 t0 = block.timestamp; _buy(17.5 ether);
        vm.warp(t0 + 59 minutes); assertFalse(_tryBuy(1 ether));
        vm.warp(t0 + 69 minutes); assertFalse(_tryBuy(1 ether));
        vm.warp(t0 + 70 minutes); assertTrue(_tryBuy(1 ether));
    }
    function test_L1_spend_at_the_end_of_a_slot_frees_after_an_hour_never_before() public {
        vm.warp((block.timestamp / 600 + 1) * 600 + 599);
        uint256 t0 = block.timestamp; _buy(17.5 ether);
        vm.warp(t0 + 59 minutes); assertFalse(_tryBuy(1 ether));
        vm.warp(t0 + 60 minutes + 1); assertTrue(_tryBuy(1 ether));
    }
    function test_L1_sustained_rate_with_bursts_over_five_hours() public {
        vm.deal(address(acct), 1000 ether);
        uint256 t0 = block.timestamp; uint256 total; uint256 bursts;
        for (uint256 t = 0; t <= 5 hours; t += 1 minutes) {
            vm.warp(t0 + t);
            if (_tryBuy(17.5 ether)) { total += 17.5 ether; bursts++; }
        }
        assertGe(bursts, 5); assertGe(total, 87.5 ether);                 // one full burst every 70 minutes (the old two-bucket rule: about half)
        // and a steady 2.5 HYPE every 10 minutes is never refused
        vm.warp(t0 + 7 hours);
        for (uint256 i = 0; i < 30; i++) { vm.warp(block.timestamp + 10 minutes); assertTrue(_tryBuy(2.5 ether)); }
    }
    function test_L1_no_hour_ever_carries_more_than_the_cap() public {
        vm.deal(address(acct), 1000 ether);
        uint256 t0 = block.timestamp; uint256[] memory at = new uint256[](400); uint256[] memory amt = new uint256[](400); uint256 n;
        for (uint256 t = 0; t <= 6 hours; t += 3 minutes) {
            vm.warp(t0 + t); uint256 v = 1 ether + (t / 180 % 5) * 2 ether;
            if (_tryBuy(v)) { at[n] = t0 + t; amt[n] = v; n++; }
            uint256 s; for (uint256 j = 0; j < n; j++) if (at[j] + 1 hours > block.timestamp) s += amt[j];
            assertLe(s, 17.5 ether);
        }
        assertGt(n, 20);
    }
    function test_L1_gas_full_spend_refused_inside_a_day_allowed_after_28_hours() public {
        vm.warp((block.timestamp / 4 hours + 1) * 4 hours);
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 5; i++) _gas(acct, GAS_CALL);              // 0.1 = GAS_DAY
        vm.warp(t0 + 23 hours); vm.expectRevert(GuardedGate.GasLimit.selector); _gas(acct, GAS_CALL);
        vm.warp(t0 + 28 hours); _gas(acct, GAS_CALL);
    }
    function test_L1_fee_full_spend_refused_inside_30_days_allowed_after_35() public {
        vm.warp((block.timestamp / 5 days + 1) * 5 days);
        uint256 t0 = block.timestamp; _fee(acct, 20 ether);
        vm.warp(t0 + 29 days); vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 5 ether);
        vm.warp(t0 + 35 days); _fee(acct, 5 ether);
    }
    function test_L1_window2x_still_refused_all_three() public {
        vm.warp((block.timestamp / 600 + 1) * 600 + 599); _buy(17.5 ether);
        vm.warp(block.timestamp + 59 minutes + 59); vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.4 ether, _buyData(tok, 17.4 ether));
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 30 days - 1); _fee(acct2, 20 ether);
        vm.warp(block.timestamp + 30 days - 1); vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct2, 16 ether);
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1 days - 1);
        for (uint256 i = 0; i < 5; i++) _gas(acct2, GAS_CALL);
        vm.warp(block.timestamp + 1 days - 1); vm.expectRevert(GuardedGate.GasLimit.selector); _gas(acct2, GAS_CALL);
    }


}
