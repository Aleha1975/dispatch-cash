// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedGate.sol";
import "./Mocks.sol";

abstract contract GateBase is Test {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    MockToken public tok; MockRouter public router; GuardedGate public gate; MockAccount public acct; MockAccount public acct2; address public exec;
    address owner1 = address(0xA11CE); address owner2 = address(0xB0B); address cold = address(0xC01D); address guardian = address(0x6A12D);
    address feeTo = address(0xFEE); address thief = address(0x1111111111111111111111111111111111111111);
    uint256 constant BUY_H = 17.5 ether; uint256 constant GAS_CALL = 0.02 ether; uint256 constant GAS_DAY = 0.1 ether;

    function _params(address feeTo_) internal view returns (GuardedGate.Params memory p) {
        p = GuardedGate.Params(address(router), exec, guardian, cold, feeTo_, BUY_H, GAS_CALL, GAS_DAY);
    }
    function setUp() public virtual {
        tok = new MockToken(); router = new MockRouter(); exec = address(new MockAccount(address(0)));   // any contract works as the aggregation executor
        gate = new GuardedGate(_params(feeTo));
        acct = new MockAccount(owner1); acct2 = new MockAccount(owner2);
        vm.deal(address(router), 1000 ether); vm.deal(address(acct), 100 ether); vm.deal(address(acct2), 100 ether);
        router.set(1000, 1e15, address(0));      // 1 ETH -> 1000 tokens; 1 token -> 0.001 ETH (the entry price)
        vm.warp(1_800_000_000);
        _approveGate(acct, tok); _approveGate(acct2, tok);
    }
    /// the client's second delegation: the account approves the gate (spender pinned to the gate) -- here simulated as the account's own call
    function _approveGate(MockAccount a, MockToken t) internal { a.exec(address(t), 0, abi.encodeCall(MockToken.approve, (address(gate), type(uint128).max))); }
    function routeMin(address tin, address tout, uint256 amount, address recipient, uint256 minRet, address callTarget) internal pure returns (bytes memory) {
        GuardedGate.SwapDescriptionV2 memory d; d.srcToken = tin; d.dstToken = tout; d.dstReceiver = recipient; d.amount = amount; d.minReturnAmount = minRet;
        GuardedGate.SwapExecutionParams memory p; p.desc = d; p.callTarget = callTarget;
        return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function route(address tin, address tout, uint256 amount) internal view returns (bytes memory) { return routeMin(tin, tout, amount, address(gate), 1, exec); }
    function _buyData(MockToken t, uint256 eth) internal view returns (bytes memory) { return abi.encodeCall(GuardedGate.buy, (address(t), 1, route(K_ETH, address(t), eth))); }
    function _sellData(MockToken t, uint256 amt, uint256 minOut) internal view returns (bytes memory) { return abi.encodeCall(GuardedGate.sell, (address(t), amt, minOut, route(address(t), K_ETH, amt))); }
    function _buyT(MockAccount a, MockToken t, uint256 eth) internal returns (uint256) { return abi.decode(a.exec(address(gate), eth, _buyData(t, eth)), (uint256)); }
    function _buy(uint256 eth) internal returns (uint256) { return _buyT(acct, tok, eth); }
    function _sell(uint256 amt) internal returns (uint256) { return abi.decode(acct.exec(address(gate), 0, _sellData(tok, amt, 1)), (uint256)); }
    function _lot(address a, MockToken t) internal view returns (uint256 tk, uint256 cost) { return gate.lotOf(a, address(t)); }
}
