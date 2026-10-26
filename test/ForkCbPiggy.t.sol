// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";

/// The 23.10 case on a Base fork, one block before the cold key's exit: the live v15 gate refuses the account's sale of its
/// only position (cbPIGGY, -63%) with BudgetExceeded, unlock or not; the same sale, with the same Kyber calldata, the same
/// lot and the same account, goes through once v16's code sits at that address (storage untouched: lots, costOf, losses).
/// Run: forge test --match-path test/ForkCbPiggy.t.sol   (BASE_RPC overrides the public endpoint; it must serve that block)
contract ForkCbPiggyTest is Test {
    address constant V15 = 0x2C894b3A726B49d9e68e71d548157964E5e0fbb6;
    address constant ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant EXECUTOR = 0x8F10B468b06c6FD214B65F87778827F7D113f996;
    address constant COLD = 0xe90E76A6e5AC772193826218821D89e0aB0CEaBD;
    address constant GUARDIAN = 0x5550C8E49616C15B89FdD1DaECddc493009e039B;
    address account; address token; uint256 amount; uint256 minOut; bytes data;

    function setUp() public {
        string memory j = vm.readFile("test/fixture_cbpiggy.json");
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")), vm.parseJsonUint(j, ".block"));
        account = vm.parseJsonAddress(j, ".account"); token = vm.parseJsonAddress(j, ".token");
        amount = vm.parseJsonUint(j, ".amount"); minOut = vm.parseJsonUint(j, ".minOut"); data = vm.parseJsonBytes(j, ".data");
    }
    function _sell() internal returns (bool ok, bytes memory ret) {
        vm.startPrank(account);
        (bool a, ) = token.call(abi.encodeWithSelector(0x095ea7b3, V15, amount)); require(a, "approve");
        (ok, ret) = V15.call(abi.encodeWithSelector(GuardedSwap.sell.selector, token, amount, minOut, data));
        vm.stopPrank();
    }
    function _v16here() internal {   // the current runtime (v16, now v17) at the v15 address, built with v15's own constructor arguments (production limits)
        deployCodeTo("GuardedSwap.sol:GuardedSwap", abi.encode(ROUTER, EXECUTOR, GUARDIAN, COLD, uint256(12), uint256(0.3 ether), uint256(1 ether)), V15);
        _register(account, token);
    }
    /// v17 keeps the earlier storage layout and adds the lot registry after it (slots 10 and 11): the lot v15 recorded is
    /// registered here as a fresh v17 would have registered it on the buy.
    function _register(address acct, address tok) internal {
        bytes32 arr = keccak256(abi.encode(acct, uint256(10))); uint256 n = uint256(vm.load(V15, arr));
        vm.store(V15, bytes32(uint256(keccak256(abi.encode(arr))) + n), bytes32(uint256(uint160(tok)))); vm.store(V15, arr, bytes32(n + 1));
        vm.store(V15, keccak256(abi.encode(tok, keccak256(abi.encode(acct, uint256(11))))), bytes32(n + 1));
        GuardedSwap g = GuardedSwap(payable(V15)); assertEq(g.lotsOf(acct).length, n + 1); assertEq(g.lotsOf(acct)[n], tok);
    }

    function test_fork_cbpiggy_v15_refuses_v16_sells() public {
        GuardedSwap g = GuardedSwap(payable(V15));
        uint256 cost = g.costOf(account); (uint256 lotTokens, uint256 lotCost) = g.lotOf(account, token);
        assertEq(lotTokens, amount); assertEq(lotCost, cost);                                        // one position, the whole cost basis
        uint256 eth0 = account.balance; assertGt(eth0, 15 * cost);                                   // the account is mostly ETH

        // v15, as deployed: refused, and unlock does not help (the sale alone exceeds 30% of the lot)
        (bool ok, bytes memory ret) = _sell(); assertFalse(ok); assertEq(bytes4(ret), GuardedSwap.BudgetExceeded.selector);
        address[] memory a = new address[](1); a[0] = account; vm.prank(COLD); g.unlock(a);
        (ok, ret) = _sell(); assertFalse(ok); assertEq(bytes4(ret), GuardedSwap.BudgetExceeded.selector);

        // v16 at the same address, same state: the same sale goes through and books the loss against the account
        _v16here();
        (, uint256 budget) = g.budgetOf(account); assertEq(budget, (cost + eth0) * 3000 / 10000);
        (ok, ret) = _sell(); assertTrue(ok);
        uint256 out = abi.decode(ret, (uint256)); assertGe(out, minOut);
        assertEq(account.balance, eth0 + out);
        (uint256 lost, ) = g.budgetOf(account); assertEq(lost, cost - out); assertGt(lost * 2, cost);   // a loss of more than half the position...
        assertLt(lost, budget);                                                                      // ...inside 30% of the account
        assertEq(g.costOf(account), 0); assertEq(address(g).balance, 0);
        emit log_named_decimal_uint("cost basis (ETH)", cost, 18); emit log_named_decimal_uint("account ETH", eth0, 18);
        emit log_named_decimal_uint("sale out (ETH)", out, 18); emit log_named_decimal_uint("loss booked (ETH)", lost, 18);
        emit log_named_decimal_uint("v15 budget (ETH)", cost * 3000 / 10000, 18); emit log_named_decimal_uint("v16 budget (ETH)", budget, 18);
    }

    /// Same fork, v16 in place: the guardian's pause still stops the executor's sale, and the cold key's exit still runs.
    function test_fork_v16_keeps_paused_semantics_and_exit() public {
        _v16here(); GuardedSwap g = GuardedSwap(payable(V15));
        vm.prank(GUARDIAN); g.setPaused(true);
        (bool ok, bytes memory ret) = _sell(); assertFalse(ok); assertEq(bytes4(ret), GuardedSwap.IsPaused.selector);   // the pause stops the executor's sale
        vm.startPrank(account, COLD);                                                                 // the cold key's exit still runs
        (bool a, ) = token.call(abi.encodeWithSelector(0x095ea7b3, V15, amount)); require(a);
        uint256 out = g.exit(token, amount, minOut, data); vm.stopPrank();
        assertGe(out, minOut);
    }
}
