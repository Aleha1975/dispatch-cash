// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwap.sol";

/// Base mainnet fork: real KyberSwap router, real calldata (fixtures built right before the run; recipient = ACCOUNT).
contract ForkTest is Test {
    address constant ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ACCOUNT = 0x2675604b10222309807Cbd3d8CdD2A1d7ac82ef4;   // the owner's live smart account (fork: no real effect)
    address constant THIEF = 0x1111111111111111111111111111111111111111;
    GuardedSwap guard;
    function setUp() public { guard = new GuardedSwap(ROUTER, address(this), 12, 0.3 ether); /* production limits */ vm.deal(ACCOUNT, 1 ether); }
    function _fx(string memory k) internal view returns (bytes memory data, uint256 minOut) {
        string memory j = vm.readFile("test/fixtures.json");
        data = vm.parseJsonBytes(j, string.concat(".", k, ".data")); minOut = vm.parseJsonUint(j, string.concat(".", k, ".minOut"));
    }
    function test_fork_buy_then_sell_usdc() public {
        (bytes memory b, uint256 bmin) = _fx("buy");
        vm.prank(ACCOUNT); uint256 got = guard.buy{value: 0.0005 ether}(USDC, bmin, b);
        assertGe(got, bmin); assertEq(IERC20(USDC).balanceOf(address(guard)), 0);
        (uint256 ethIn, uint256 tokens) = guard.basis(ACCOUNT, USDC); assertEq(ethIn, 0.0005 ether); assertEq(tokens, got);
        (bytes memory s, uint256 smin) = _fx("sell");                 // sells exactly 1 USDC
        vm.startPrank(ACCOUNT); (bool ok, ) = USDC.call(abi.encodeWithSelector(0x095ea7b3, address(guard), 1_000_000)); require(ok);
        uint256 before = ACCOUNT.balance;
        uint256 eth = guard.sell(USDC, 1_000_000, smin, s); vm.stopPrank();
        assertGe(eth, smin); assertEq(ACCOUNT.balance - before, eth); assertEq(address(guard).balance, 0);
    }
    function test_fork_buy_paid_to_thief_reverts() public {
        (bytes memory b, uint256 bmin) = _fx("buyThief");
        vm.prank(ACCOUNT); vm.expectRevert(GuardedSwap.BadRoute.selector);      // decoded on-chain: dstReceiver is not the account
        guard.buy{value: 0.0005 ether}(USDC, bmin, b);
        assertEq(ACCOUNT.balance, 1 ether);
    }
}
