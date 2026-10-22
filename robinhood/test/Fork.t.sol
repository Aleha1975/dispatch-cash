// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwapRH.sol";
import "./Mocks.sol";

interface IV3Factory { function createPool(address, address, uint24) external returns (address); function getPool(address, address, uint24) external view returns (address); }
interface IV3Pool { function initialize(uint160) external; function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256); function token0() external view returns (address); }
interface IWETH { function deposit() external payable; function transfer(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// A pool that is not a pool (for the malicious-hop test).
contract NotAPool { address public token0; address public token1; uint24 public fee = 10000; address public factory = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; }

/// The attacker's own GENUINE Uniswap v3 pool at a ruinous price: a sink the factory check cannot tell from a thin market.
contract SinkLP {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    function seed(address pool, int24 lo, int24 hi, uint128 liq) external payable { IWETH(WETH).deposit{value: msg.value}(); IV3Pool(pool).mint(address(this), lo, hi, liq, ""); }
    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        if (a0 > 0) IWETH(IV3Pool(msg.sender).token0()).transfer(msg.sender, a0);
        require(a1 == 0, "range must sit above the price: WETH only");
    }
}

/// Robinhood Chain fork: the live router, real pools, the gate deployed with the proposed production parameters.
/// Run: forge test --match-path test/Fork.t.sol   (RH_RPC / RH_BLOCK override the defaults)
contract ForkTest is Test {
    address constant ROUTER = 0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant UNI_V3 = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;   // fee-keyed
    address constant CL_E0C4 = 0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8;  // tick-keyed (Slipstream-style)
    address constant CL_1AC9 = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3;  // tick-keyed
    address constant COLD = 0xe90E76A6e5AC772193826218821D89e0aB0CEaBD;     // the operator's cold key (same as Dispatch)
    address constant THIEF = 0x1111111111111111111111111111111111111111;
    address constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18; address constant BONER_POOL = 0xBd5cd6515ca6285941FbC177381dC8ED4844e6b8;
    address constant SGT = 0x238E40b75Ae78A1388A14e517D855893e92e58db; address constant HOOK_E5 = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant QUBIT = 0xd1E92BA7c7355c2698addD894919Cba198601E18; address constant X2E08 = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3; address constant HOOK_4E34 = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    GuardedSwapRH g; SmartAccount acct;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RH_RPC", string("https://rpc.mainnet.chain.robinhood.com")), vm.envOr("RH_BLOCK", uint256(94996000)));
        address[] memory f = new address[](3); f[0] = UNI_V3; f[1] = CL_E0C4; f[2] = CL_1AC9;
        bool[] memory k = new bool[](3); k[1] = true; k[2] = true;
        g = new GuardedSwapRH(ROUTER, WETH, PM, f, k, address(this), COLD, 24, 0.1 ether, 0.5 ether);   // proposed production limits
        acct = new SmartAccount(); vm.deal(address(acct), 1 ether);
    }
    // ---- hops ----
    function v3(address tin, address tout, address p, uint24 key) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 1; h.tokenIn = tin; h.tokenOut = tout; h.pool = p; h.fee = key; h.tickSpacing = int24(key); }
    function v4(address tin, address tout, uint24 fee, int24 ts, address hooks) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 2; h.tokenIn = tin; h.tokenOut = tout; h.fee = fee; h.tickSpacing = ts; h.hooks = hooks; }
    function arr(GuardedSwapRH.Hop memory a) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](1); h[0] = a; }
    /// the sale route: the buy route reversed, as a copy (the buy route stays intact)
    function rev(GuardedSwapRH.Hop[] memory h) internal pure returns (GuardedSwapRH.Hop[] memory r) { r = new GuardedSwapRH.Hop[](h.length); for (uint256 i = 0; i < h.length; i++) { GuardedSwapRH.Hop memory x = h[h.length - 1 - i]; r[i] = GuardedSwapRH.Hop(x.version, x.tokenOut, x.tokenIn, x.pool, x.fee, x.tickSpacing, x.hooks); } }
    function bal(address t, address w) internal view returns (uint256) { return IERC20(t).balanceOf(w); }
    // ---- the account's own calls (what a delegation redemption runs) ----
    function _buy(address token, uint256 eth, GuardedSwapRH.Hop[] memory h) internal returns (uint256) {
        // the account sends value: fund it through a payable path -- the SmartAccount forwards with value 0, so call the gate as the account directly
        vm.prank(address(acct)); return g.buy{value: eth}(token, 1, h);
    }
    function _sell(address token, uint256 amount, uint256 minOut, GuardedSwapRH.Hop[] memory h, bool asExit) internal returns (uint256) {
        acct.exec(token, abi.encodeWithSelector(0x095ea7b3, address(g), amount));
        bytes memory c = abi.encodeWithSelector(asExit ? GuardedSwapRH.exit.selector : GuardedSwapRH.sell.selector, token, amount, minOut, h);
        if (asExit) vm.prank(COLD, COLD);
        return abi.decode(acct.exec(address(g), c), (uint256));
    }
    function _roundTrip(address token, GuardedSwapRH.Hop[] memory h) internal {
        uint256 e0 = address(acct).balance;
        uint256 got = _buy(token, 0.01 ether, h);
        assertGt(got, 0); assertEq(bal(token, address(acct)), got);
        (uint256 tokens, uint256 ethIn) = g.lotOf(address(acct), token); assertEq(tokens, got); assertEq(ethIn, 0.01 ether);   // the router's 1% fee is part of the cost
        assertEq(bal(token, address(g)), 0); assertEq(address(g).balance, 0);
        uint256 out = _sell(token, got, 1, rev(h), false);
        assertGt(out, 0); assertEq(address(acct).balance, e0 - 0.01 ether + out);                                           // proceeds landed on the account, natively
        assertEq(bal(token, address(acct)), 0); assertEq(bal(token, address(g)), 0); assertEq(address(g).balance, 0); assertEq(bal(WETH, address(g)), 0);
        assertEq(IERC20Allow(token).allowance(address(g), ROUTER), 0);
        (tokens, ) = g.lotOf(address(acct), token); assertEq(tokens, 0); assertEq(g.costOf(address(acct)), 0);
        (uint256 lost, ) = g.budgetOf(address(acct)); assertEq(lost, out < 0.01 ether ? 0.01 ether - out : 0);              // the round trip's cost (two router fees, pool fees, price impact) is a booked loss
        emit log_named_uint("round trip: ETH back of 0.01", out);
    }

    function test_fork_v3_single_hop_round_trip() public { _roundTrip(BONER, arr(v3(WETH, BONER, BONER_POOL, 10000))); }
    function test_fork_v4_native_hooked_pool_round_trip() public { _roundTrip(SGT, arr(v4(address(0), SGT, 0, 200, HOOK_E5))); }
    function test_fork_three_hops_v3_v3_v4_round_trip() public {
        GuardedSwapRH.Hop[] memory h = new GuardedSwapRH.Hop[](3);
        h[0] = v3(WETH, USDG, 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, 100);
        h[1] = v3(USDG, X2E08, 0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7, 500);
        h[2] = v4(X2E08, QUBIT, 8388608, 8, HOOK_4E34);
        _roundTrip(QUBIT, h);
    }
    function test_fork_tick_keyed_factory_round_trip() public {                           // PONS: WETH -uni v3-> USDG -E0c4 CL (key = tick spacing 50)-> PONS
        GuardedSwapRH.Hop[] memory h = new GuardedSwapRH.Hop[](2);
        h[0] = v3(WETH, USDG, 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, 100);
        h[1] = v3(USDG, PONS, 0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269, 50);
        _roundTrip(PONS, h);
    }
    function test_fork_second_tick_keyed_factory_hop() public {                           // WETH -1ac9 CL (tick spacing 10)-> USDG -E0c4-> PONS
        GuardedSwapRH.Hop[] memory h = new GuardedSwapRH.Hop[](2);
        h[0] = v3(WETH, USDG, 0x16679e2ac1A798865eCf1c1639e67693ddB1C220, 10);
        h[1] = v3(USDG, PONS, 0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269, 50);
        uint256 got = _buy(PONS, 0.001 ether, h); assertGt(got, 0);
    }
    function test_fork_exit_by_the_cold_key() public {
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        uint256 got = _buy(BONER, 0.01 ether, h);
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        vm.expectRevert(GuardedSwapRH.NotExitKey.selector);
        acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.exit.selector, BONER, got, uint256(1), rev(h)));   // the account (executor path) alone cannot exit
        g.setPaused(true);                                                                                               // and the guardian's pause does not stop the cold key
        uint256 e0 = address(acct).balance;
        uint256 out = _sell(BONER, got, 1, rev(h), true);
        assertGt(out, 0); assertEq(address(acct).balance - e0, out); assertEq(address(COLD).balance, 0);
    }
    function test_fork_malicious_hops_revert() public {
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        uint256 got = _buy(BONER, 0.01 ether, h);
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        bytes4 BAD = GuardedSwapRH.BadRoute.selector;
        // 1. a contract posing as the pool
        address fake = address(new NotAPool());
        vm.prank(address(acct)); vm.expectRevert(BAD); g.buy{value: 0.01 ether}(BONER, 1, arr(v3(WETH, BONER, fake, 10000)));
        vm.expectRevert(BAD); acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got, uint256(1), arr(v3(BONER, WETH, fake, 10000))));
        // 2. a router code path other than v3/v4 (version 4 = the router's Virtuals library)
        GuardedSwapRH.Hop memory x = v3(BONER, WETH, BONER_POOL, 10000); x.version = 4;
        vm.expectRevert(BAD); acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got, uint256(1), arr(x)));
        // 3. a sale that ends in another token (it would land on the gate, not the account)
        vm.expectRevert(BAD); acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got, uint256(1), arr(v4(BONER, USDG, 3000, 60, address(0)))));
        // 4. a real pool for another pair named for this one
        vm.expectRevert(BAD); acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got, uint256(1), arr(v3(BONER, WETH, 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, 10000))));
        // 5. a thief-chosen minOut below what the route pays is fine for the gate, but nothing lands anywhere but the account
        uint256 e0 = address(acct).balance; uint256 t0 = THIEF.balance;
        uint256 out = abi.decode(acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got / 10, uint256(1), rev(h))), (uint256));
        assertEq(address(acct).balance - e0, out); assertEq(THIEF.balance, t0); assertEq(bal(BONER, THIEF), 0);
    }
    /// The residual, measured: a stolen executor key routes the account's lot into the thief's own genuine Uniswap v3 pool
    /// at a ruinous price. The factory check passes (the pool is real); the loss budget is what stops it.
    function test_fork_genuine_sink_pool_is_bounded_by_the_loss_budget() public {
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        uint256 got = _buy(BONER, 0.01 ether, h);
        address sink = IV3Factory(UNI_V3).createPool(WETH, BONER, 500);                  // permissionless
        assertEq(IV3Pool(sink).token0(), WETH);
        IV3Pool(sink).initialize(2505414483750479311864138015696063);                    // ~1e9 BONER per WETH (live price ~1.4e5): ~7000x worse
        SinkLP lp = new SinkLP(); vm.deal(address(lp), 1 ether); vm.prank(THIEF); lp.seed{value: 0.001 ether}(sink, 207250, 208250, 1e19);
        GuardedSwapRH.Hop[] memory s = arr(v3(BONER, WETH, sink, 500));
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        (, uint256 budget) = g.budgetOf(address(acct)); assertEq(budget, 0.003 ether);
        vm.expectPartialRevert(GuardedSwapRH.BudgetExceeded.selector);                   // the whole lot into the sink: BudgetExceeded (loss ~0.01 > 0.003)
        acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got, uint256(1), s));
        uint256 out = abi.decode(acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got / 5, uint256(1), s)), (uint256));   // a fifth fits the budget
        (uint256 lost, ) = g.budgetOf(address(acct)); assertGt(lost, 0.0019 ether); assertLe(lost, 0.002 ether); emit log_named_uint("sink paid for a fifth of the lot", out);
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got / 5));
        vm.expectPartialRevert(GuardedSwapRH.BudgetExceeded.selector);                   // the next fifth does not: 0.004 > 30% of the 0.008 left
        acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.sell.selector, BONER, got / 5, uint256(1), s));
        assertEq(address(g).balance, 0); assertEq(bal(BONER, address(g)), 0);
    }
    /// What the router does with the fields the gate pins: a non-zero recipient is refused, the PoolManager field is ignored.
    function test_fork_router_refuses_a_recipient() public {
        GuardedSwapRH.RouterHop[] memory r = new GuardedSwapRH.RouterHop[](1);
        r[0] = GuardedSwapRH.RouterHop(1, WETH, BONER, BONER_POOL, 10000, 200, address(0), "", address(0), bytes32(0));
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory e) = ROUTER.call{value: 0.01 ether}(abi.encodeWithSelector(0x4d819a2a, r, THIEF, 0.01 ether, 1, block.timestamp));
        assertFalse(ok); assertEq(keccak256(e), keccak256(abi.encodeWithSignature("Error(string)", "BAD_ARGS")));
    }
}
interface IERC20Allow { function allowance(address, address) external view returns (uint256); }
