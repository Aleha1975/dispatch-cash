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
    address constant EXECUTOR = 0x8F10B468b06c6FD214B65F87778827F7D113f996;   // Kyber aggregation executor on Base (callTarget of every real route)
    GuardedSwap guard;
    address constant GUARD_AT = 0x1000000000000000000000000000000000000001;
    address constant COLD = 0xe90E76A6e5AC772193826218821D89e0aB0CEaBD;   // the operator's cold key   // fixed, so the sell fixture (built before the run) can name the gate as recipient
    function setUp() public {
        deployCodeTo("GuardedSwap.sol:GuardedSwap", abi.encode(ROUTER, EXECUTOR, address(this), COLD, uint256(12), uint256(0.3 ether), uint256(1 ether)), GUARD_AT);   // production limits
        guard = GuardedSwap(payable(GUARD_AT)); vm.deal(ACCOUNT, 1 ether);
    }
    function _fx(string memory k) internal view returns (bytes memory data, uint256 minOut) {
        string memory j = vm.readFile("test/fixtures.json");
        data = vm.parseJsonBytes(j, string.concat(".", k, ".data")); minOut = vm.parseJsonUint(j, string.concat(".", k, ".minOut")) * 99 / 100;   // just under the route's own minimum
    }
    function test_fork_buy_then_sell_usdc() public {
        (bytes memory b, uint256 bmin) = _fx("buy");
        uint256 gTok = IERC20(USDC).balanceOf(address(guard)); uint256 gEth = address(guard).balance;   // the pinned address may hold dust on mainnet: it must stay untouched
        vm.prank(ACCOUNT); uint256 got = guard.buy{value: 0.0005 ether}(USDC, bmin, b);
        assertGe(got, bmin); assertEq(IERC20(USDC).balanceOf(address(guard)), gTok);
        (uint256 tokens, uint256 ethIn) = guard.basis(ACCOUNT, USDC); assertEq(tokens, got); assertEq(ethIn, 0.0005 ether);
        (bytes memory s, uint256 smin) = _fx("sell");                 // sells exactly 1 USDC
        vm.startPrank(ACCOUNT); (bool ok, ) = USDC.call(abi.encodeWithSelector(0x095ea7b3, address(guard), 1_000_000)); require(ok);
        uint256 before = ACCOUNT.balance;
        uint256 eth = guard.sell(USDC, 1_000_000, smin, s); vm.stopPrank();
        assertGe(eth, smin); assertEq(ACCOUNT.balance - before, eth); assertEq(address(guard).balance, gEth); assertEq(IERC20(USDC).balanceOf(address(guard)), gTok);
    }
    function test_fork_exit_by_the_cold_key() public {
        (bytes memory b, uint256 bmin) = _fx("buy");
        vm.prank(ACCOUNT); uint256 got = guard.buy{value: 0.0005 ether}(USDC, bmin, b);
        (bytes memory s, uint256 smin) = _fx("sell");
        vm.startPrank(ACCOUNT); (bool ok, ) = USDC.call(abi.encodeWithSelector(0x095ea7b3, address(guard), 1_000_000)); require(ok);
        vm.expectRevert(GuardedSwap.NotExitKey.selector); guard.exit(USDC, 1_000_000, smin, s); vm.stopPrank();   // the account alone cannot exit
        vm.startPrank(ACCOUNT, COLD); uint256 before = ACCOUNT.balance;
        uint256 eth = guard.exit(USDC, 1_000_000, smin, s); vm.stopPrank();
        assertGe(eth, smin); assertEq(ACCOUNT.balance - before, eth); assertGe(got, 1_000_000);
    }
    function test_fork_buy_paid_to_thief_reverts() public {
        (bytes memory b, uint256 bmin) = _fx("buyThief");
        vm.prank(ACCOUNT); vm.expectRevert(GuardedSwap.BadRoute.selector);      // decoded on-chain: dstReceiver is not the account
        guard.buy{value: 0.0005 ether}(USDC, bmin, b);
        assertEq(ACCOUNT.balance, 1 ether);
    }
}
