// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./GateBase.sol";
import "./Adversarial.t.sol";

/// Round 2: fixes for external audit job 1205 (L-1, L-3, L-4; the reference tests were removed in round 4); each test reproduces the auditor's scenario and asserts the safe outcome.
contract Round2Test is GateBase {
    function _fee(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.payFee, ())); }
    function _gas(MockAccount a, uint256 v) internal { a.exec(address(gate), v, abi.encodeCall(GuardedGate.refundGas, ())); }
    function _sellRaw(MockAccount a, MockToken t, uint256 amt) internal returns (bytes memory) { return a.exec(address(gate), 0, _sellData(t, amt, 1)); }


      // 1 ETH buys 0.3 token of 6 decimals

    // L-1: the auditor's test_window2x. Spend at the end of two adjacent slots is counted in full.
    function test_window2x_buys_now_refused() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours + 3599);
        _buy(17.5 ether);
        vm.warp(block.timestamp + 3599);                                  // inside one hour of the first buy, next slot's last second
        vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.4 ether, _buyData(tok, 17.4 ether));
        vm.warp(block.timestamp + 1 hours); _buy(17.4 ether);             // a full span later it is allowed
    }
    function test_window2x_fees_now_refused() public {
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 30 days - 1);
        _fee(acct, 20 ether);
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 16 ether);
    }
    function test_window2x_gas_now_refused() public {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1 days - 1);
        for (uint256 i = 0; i < 5; i++) _gas(acct, GAS_CALL);             // 0.1 = GAS_DAY at the end of a day slot
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(GuardedGate.GasLimit.selector); _gas(acct, GAS_CALL);
    }

    // L-3: the sold token's lot is reconciled even when the gas-bounded walk never reaches it.
    function test_L3_sold_token_lot_reconciled_despite_stuffed_registry() public {
        _buy(2 ether);                                                    // index 0 of the registry
        for (uint256 i = 0; i < 31; i++) { GasBurnToken j = new GasBurnToken(); _buyT(acct, MockToken(address(j)), 0.001 ether); }
        tok.burn(address(acct), 1000 ether);                              // the owner moved half the tokens out
        _sellRaw(acct, tok, 500 ether);
        (uint256 tk, uint256 cost) = gate.basis(address(acct), address(tok));
        assertEq(tk, 500 ether); assertEq(cost, 0.5 ether);               // trimmed to 1000 / 1.0 first, then 500 / 0.5 released (stale lot: 1500 / 1.5)
    }

    // L-4: time stepping backward across a bucket no longer resets the windows.
    function test_L4_backward_time_buys_do_not_reset() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours + 10);
        uint256 t0 = block.timestamp;
        _buy(17.4 ether); vm.warp(t0 + 40 minutes); _buy(0.1 ether);        // stored head moves ahead (round 3: ring slots of 10 min)
        vm.warp(t0);                                                      // clock steps back into the earlier slot
        vm.expectRevert(GuardedGate.RateLimited.selector); acct.exec(address(gate), 17.4 ether, _buyData(tok, 17.4 ether));
    }
    function test_L4_backward_time_fees_do_not_reset() public {
        vm.warp((block.timestamp / 30 days + 1) * 30 days + 5);
        uint256 t0 = block.timestamp;
        _fee(acct, 18 ether); vm.warp(t0 + 30 days); _fee(acct, 0.5 ether);
        vm.warp(t0);
        vm.expectRevert(GuardedGate.FeeLimit.selector); _fee(acct, 4 ether);
    }
}
