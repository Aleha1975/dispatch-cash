// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/GuardedSwapRH.sol";
import "./Mocks.sol";

interface IV3Factory { function createPool(address, address, uint24) external returns (address); function getPool(address, address, uint24) external view returns (address); }
interface IV3Pool { function initialize(uint160) external; function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256); function token0() external view returns (address); }
interface IWETH { function deposit() external payable; function transfer(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IERC20A { function approve(address, uint256) external returns (bool); function allowance(address, address) external view returns (uint256); }

/// A contract posing as a pool: it answers the pool getters and would call back for a payment.
contract NotAPool {
    address public token0; address public token1; uint24 public fee = 10000; address public factory = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    function swap(address, bool, int256 a, uint160, bytes calldata) external returns (int256, int256) { GuardedSwapRH(payable(msg.sender)).uniswapV3SwapCallback(a, 0, ""); return (a, 0); }
}
/// The attacker's own GENUINE Uniswap v3 pool at a ruinous price: a sink the factory check cannot tell from a thin market.
contract SinkLP {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    function seed(address pool, int24 lo, int24 hi, uint128 liq) external payable { IWETH(WETH).deposit{value: msg.value}(); IV3Pool(pool).mint(address(this), lo, hi, liq, ""); }
    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        if (a0 > 0) IWETH(IV3Pool(msg.sender).token0()).transfer(msg.sender, a0);
        require(a1 == 0, "range must sit above the price: WETH only");
    }
}

/// Robinhood Chain fork: real pools, the real PoolManager, the gate deployed with the proposed production parameters, and
/// the Robinhood "SwapX" router for the cost comparison.
/// Run: forge test --match-path test/Fork.t.sol -vv   (RH_RPC / RH_BLOCK override the defaults)
contract ForkTest is Test {
    address constant ROUTER = 0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc;     // only for the comparison; v5 never calls it
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant UNI_V3 = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;   // fee-keyed
    address constant CL_E0C4 = 0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8;  // tick-keyed (Slipstream-style)
    address constant CL_1AC9 = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3;  // tick-keyed
    address constant COLD = 0xe90E76A6e5AC772193826218821D89e0aB0CEaBD;
    address constant THIEF = 0x1111111111111111111111111111111111111111;
    address constant WETH_USDG_001 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;   // Uniswap v3 0.01%
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; address constant NVDA_USDG_005 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;   // Uniswap v3 0.05%
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d; address constant TSLA_USDG_03 = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3;      // Uniswap v3 0.3%
    address constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18; address constant BONER_POOL = 0xBd5cd6515ca6285941FbC177381dC8ED4844e6b8;
    address constant SGT = 0x238E40b75Ae78A1388A14e517D855893e92e58db; address constant HOOK_E5 = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant QUBIT = 0xd1E92BA7c7355c2698addD894919Cba198601E18; address constant X2E08 = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3; address constant HOOK_4E34 = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant HOOK_48B8 = 0x48B8F6AD3A1b4aA477314c9a23035b8F84dDe8cc;   // return-delta hook, not on the list
    GuardedSwapRH g; SmartAccount acct;

    struct RouterHop { uint8 version; address tokenIn; address tokenOut; address pool; uint24 fee; int24 tickSpacing; address hooks; bytes hookData; address poolManager; bytes32 extra; }

    receive() external payable {}
    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 blk = vm.envOr("RH_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, blk);
        address[] memory f = new address[](3); f[0] = UNI_V3; f[1] = CL_E0C4; f[2] = CL_1AC9;
        bool[] memory k = new bool[](3); k[1] = true; k[2] = true;
        address[] memory h = new address[](2); h[0] = HOOK_E5; h[1] = HOOK_4E34;
        g = new GuardedSwapRH(WETH, PM, f, k, h, address(this), COLD, 24, 12, 0.05 ether, 0.5 ether);   // proposed production limits
        acct = new SmartAccount(); vm.deal(address(acct), 1 ether);
    }
    // ---- hops ----
    function v3(address tin, address tout, address p, uint24 key) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 1; h.tokenIn = tin; h.tokenOut = tout; h.pool = p; h.fee = key; }
    function v4(address tin, address tout, uint24 fee, int24 ts, address hooks) internal pure returns (GuardedSwapRH.Hop memory h) { h.version = 2; h.tokenIn = tin; h.tokenOut = tout; h.fee = fee; h.tickSpacing = ts; h.hooks = hooks; }
    function arr(GuardedSwapRH.Hop memory a) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](1); h[0] = a; }
    function arr2(GuardedSwapRH.Hop memory a, GuardedSwapRH.Hop memory b) internal pure returns (GuardedSwapRH.Hop[] memory h) { h = new GuardedSwapRH.Hop[](2); h[0] = a; h[1] = b; }
    function rev(GuardedSwapRH.Hop[] memory h) internal pure returns (GuardedSwapRH.Hop[] memory r) { r = new GuardedSwapRH.Hop[](h.length); for (uint256 i = 0; i < h.length; i++) { GuardedSwapRH.Hop memory x = h[h.length - 1 - i]; r[i] = GuardedSwapRH.Hop(x.version, x.tokenOut, x.tokenIn, x.pool, x.fee, x.tickSpacing, x.hooks); } }
    function _sd(address t, uint256 amt, GuardedSwapRH.Hop[] memory h) internal view returns (bytes memory) { return abi.encodeWithSelector(GuardedSwapRH.sell.selector, t, amt, uint256(1), block.timestamp, h); }
    function bal(address t, address w) internal view returns (uint256) { return IERC20(t).balanceOf(w); }
    // ---- the account's own calls (what a delegation redemption runs) ----
    function _buy(address token, uint256 eth, GuardedSwapRH.Hop[] memory h) internal returns (uint256) { vm.prank(address(acct)); return g.buy{value: eth}(token, 1, block.timestamp, h); }
    function _sell(address token, uint256 amount, uint256 minOut, GuardedSwapRH.Hop[] memory h, bool asExit) internal returns (uint256) {
        acct.exec(token, abi.encodeWithSelector(0x095ea7b3, address(g), amount));
        bytes memory c = abi.encodeWithSelector(asExit ? GuardedSwapRH.exit.selector : GuardedSwapRH.sell.selector, token, amount, minOut, block.timestamp, h);
        if (asExit) vm.prank(COLD, COLD);
        return abi.decode(acct.exec(address(g), c), (uint256));
    }
    /// buy `eth` through the gate and sell all of it back; returns the ETH that came back. Checks every promise on the way.
    function _gateRoundTrip(address token, uint256 eth, GuardedSwapRH.Hop[] memory h) internal returns (uint256 out, uint256 gasBuy, uint256 gasSell) {
        uint256 e0 = address(acct).balance;
        uint256 g0 = gasleft(); uint256 got = _buy(token, eth, h); gasBuy = g0 - gasleft();
        assertGt(got, 0); assertEq(bal(token, address(acct)), got);
        (uint256 tokens, uint256 ethIn) = g.lotOf(address(acct), token); assertEq(tokens, got); assertEq(ethIn, eth);
        assertEq(bal(token, address(g)), 0); assertEq(address(g).balance, 0); assertEq(bal(WETH, address(g)), 0); assertEq(bal(USDG, address(g)), 0);
        acct.exec(token, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        g0 = gasleft(); out = abi.decode(acct.exec(address(g), _sd(token, got, rev(h))), (uint256)); gasSell = g0 - gasleft();
        assertGt(out, 0); assertEq(address(acct).balance, e0 - eth + out);
        assertEq(bal(token, address(acct)), 0); assertEq(bal(token, address(g)), 0); assertEq(address(g).balance, 0); assertEq(bal(WETH, address(g)), 0); assertEq(bal(USDG, address(g)), 0);
        (tokens, ) = g.lotOf(address(acct), token); assertEq(tokens, 0); assertEq(g.costOf(address(acct)), 0);
    }
    // ---- the router, for the comparison (paid to msg.sender = this test) ----
    function _rh(GuardedSwapRH.Hop memory h) internal pure returns (RouterHop memory r) {
        r = h.version == 2 ? RouterHop(2, h.tokenIn, h.tokenOut, address(0), h.fee, h.tickSpacing, h.hooks, "", PM, bytes32(0))
                           : RouterHop(1, h.tokenIn, h.tokenOut, h.pool, h.fee, int24(0), address(0), "", address(0), bytes32(0));
    }
    function _rhs(GuardedSwapRH.Hop[] memory h) internal pure returns (RouterHop[] memory r) { r = new RouterHop[](h.length); for (uint256 i = 0; i < h.length; i++) r[i] = _rh(h[i]); }
    uint256 routerGas;
    function _routerRoundTrip(address token, uint256 eth, GuardedSwapRH.Hop[] memory h) internal returns (uint256 out) {
        vm.deal(address(this), 1 ether); uint256 e0 = address(this).balance; uint256 t0 = bal(token, address(this));
        uint256 g0 = gasleft();
        (bool ok, bytes memory e) = ROUTER.call{value: eth}(abi.encodeWithSelector(0x4d819a2a, _rhs(h), address(0), eth, uint256(1), block.timestamp));
        require(ok, string(e));
        uint256 got = bal(token, address(this)) - t0;
        IERC20A(token).approve(ROUTER, got);
        (ok, e) = ROUTER.call(abi.encodeWithSelector(0x4d819a2a, _rhs(rev(h)), address(0), got, uint256(1), block.timestamp));
        require(ok, string(e)); routerGas = g0 - gasleft();
        out = address(this).balance - (e0 - eth);
    }
    /// the same round trip through the gate (pools directly) and through the router, from the same state
    function _compare(string memory name, address token, uint256 eth, GuardedSwapRH.Hop[] memory h) internal {
        uint256 snap = vm.snapshotState();
        (uint256 viaGate, uint256 gb, uint256 gs) = _gateRoundTrip(token, eth, h);
        vm.revertToState(snap);
        uint256 viaRouter = _routerRoundTrip(token, eth, h);
        emit log_string(name);
        emit log_named_decimal_uint("  round trip cost via pools (gate v5), % of ticket", (eth - viaGate) * 1e6 / eth, 4);
        emit log_named_decimal_uint("  round trip cost via router,          % of ticket", (eth - viaRouter) * 1e6 / eth, 4);
        emit log_named_decimal_uint("  saved per round trip,                % of ticket", viaGate > viaRouter ? (viaGate - viaRouter) * 1e6 / eth : 0, 4);
        emit log_named_uint("  gas buy+sell (gate, incl. account checks)", gb + gs); emit log_named_uint("  gas buy+approve+sell (router, direct)", routerGas);
        assertGt(viaGate, viaRouter);                                                    // the router's two 1% fees are gone
    }

    // ---- round trips on live pools, compared with the router ----
    function test_fork_meme_v3_single_hop() public { _compare("BONER, Uniswap v3 1%", BONER, 0.01 ether, arr(v3(WETH, BONER, BONER_POOL, 10000))); }
    function test_fork_meme_v4_native_hooked_pool() public { _compare("SGT, v4 native, hook 0xe5e7 (allowed by list)", SGT, 0.01 ether, arr(v4(address(0), SGT, 0, 200, HOOK_E5))); }
    function test_fork_three_hops_v3_v3_v4_dynamic_fee_hook() public {
        GuardedSwapRH.Hop[] memory h = new GuardedSwapRH.Hop[](3);
        h[0] = v3(WETH, USDG, WETH_USDG_001, 100);
        h[1] = v3(USDG, X2E08, 0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7, 500);
        h[2] = v4(X2E08, QUBIT, 8388608, 8, HOOK_4E34);
        _compare("QUBIT, WETH-v3-USDG-v3-X-v4(hook 0x4e34)-QUBIT", QUBIT, 0.01 ether, h);
    }
    function test_fork_tick_keyed_factory() public {
        _compare("PONS, WETH-uni v3-USDG-CL(E0c4, ts 50)-PONS", PONS, 0.01 ether, arr2(v3(WETH, USDG, WETH_USDG_001, 100), v3(USDG, PONS, 0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269, 50)));
    }
    function test_fork_second_tick_keyed_factory_hop() public {
        GuardedSwapRH.Hop[] memory h = arr2(v3(WETH, USDG, 0x16679e2ac1A798865eCf1c1639e67693ddB1C220, 10), v3(USDG, PONS, 0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269, 50));
        uint256 got = _buy(PONS, 0.001 ether, h); assertGt(got, 0);
    }
    /// tokenized stocks: WETH -> USDG on the 0.01% pool, USDG -> stock on a Uniswap v3 pool
    function test_fork_stock_nvda_two_hops() public {
        _compare("NVDA, WETH-v3 0.01%-USDG-v3 0.05%-NVDA", NVDA, 0.01 ether, arr2(v3(WETH, USDG, WETH_USDG_001, 100), v3(USDG, NVDA, NVDA_USDG_005, 500)));
    }
    function test_fork_stock_tsla_two_hops() public {
        _compare("TSLA, WETH-v3 0.01%-USDG-v3 0.3%-TSLA", TSLA, 0.01 ether, arr2(v3(WETH, USDG, WETH_USDG_001, 100), v3(USDG, TSLA, TSLA_USDG_03, 3000)));
    }
    /// the stock path at the largest ticket the hourly cap allows (0.05 ETH) and a mid ticket
    function test_fork_stock_nvda_ticket_sizes() public {
        _compare("NVDA at 0.002 ETH", NVDA, 0.002 ether, arr2(v3(WETH, USDG, WETH_USDG_001, 100), v3(USDG, NVDA, NVDA_USDG_005, 500)));
        _compare("NVDA at 0.05 ETH", NVDA, 0.05 ether, arr2(v3(WETH, USDG, WETH_USDG_001, 100), v3(USDG, NVDA, NVDA_USDG_005, 500)));
    }

    // ---- exit, attacks ----
    function test_fork_exit_by_the_cold_key() public {
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        uint256 got = _buy(BONER, 0.01 ether, h);
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        vm.expectRevert(GuardedSwapRH.NotExitKey.selector);
        acct.exec(address(g), abi.encodeWithSelector(GuardedSwapRH.exit.selector, BONER, got, uint256(1), block.timestamp, rev(h)));
        g.setPaused(true);
        uint256 e0 = address(acct).balance; uint256 c0 = COLD.balance;
        uint256 out = _sell(BONER, got, 1, rev(h), true);
        assertGt(out, 0); assertEq(address(acct).balance - e0, out); assertEq(COLD.balance, c0);
    }
    function test_fork_fake_and_wrong_pools_refused() public {
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        uint256 got = _buy(BONER, 0.01 ether, h);
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        bytes4 BAD = GuardedSwapRH.BadRoute.selector;
        address fake = address(new NotAPool());
        vm.prank(address(acct)); vm.expectRevert(BAD); g.buy{value: 0.01 ether}(BONER, 1, block.timestamp, arr(v3(WETH, BONER, fake, 10000)));
        vm.expectRevert(BAD); acct.exec(address(g), _sd(BONER, got, arr(v3(BONER, WETH, fake, 10000))));
        vm.expectRevert(BAD); acct.exec(address(g), _sd(BONER, got, arr(v3(BONER, WETH, WETH_USDG_001, 10000))));   // a real pool of another pair
        vm.expectRevert(BAD); acct.exec(address(g), _sd(BONER, got, arr(v3(BONER, WETH, BONER_POOL, 3000))));       // the right pool, the wrong key
        GuardedSwapRH.Hop memory x = v3(BONER, WETH, BONER_POOL, 10000); x.version = 4;
        vm.expectRevert(BAD); acct.exec(address(g), _sd(BONER, got, arr(x)));
        vm.expectRevert(BAD); acct.exec(address(g), _sd(BONER, got, arr(v4(BONER, USDG, 3000, 60, address(0)))));   // a sale ending elsewhere than ETH
        vm.expectRevert(GuardedSwapRH.BadHook.selector); acct.exec(address(g), _sd(BONER, got, arr(v4(BONER, address(0), 3000, 60, HOOK_48B8))));   // a return-delta hook not on the list
    }
    /// the callbacks cannot be driven from outside a swap: not by a thief, not by a real pool, not by a hook pretending to be the PoolManager
    function test_fork_callbacks_only_from_the_pool_in_flight() public {
        vm.deal(address(g), 0); deal(WETH, address(g), 1 ether);                          // even with funds parked on the gate
        vm.prank(THIEF); vm.expectRevert(GuardedSwapRH.BadCallback.selector); g.uniswapV3SwapCallback(1 ether, 0, "");
        vm.prank(BONER_POOL); vm.expectRevert(GuardedSwapRH.BadCallback.selector); g.uniswapV3SwapCallback(1 ether, 0, "");
        vm.prank(HOOK_E5); vm.expectRevert(GuardedSwapRH.BadCallback.selector); g.unlockCallback(abi.encode(WETH, BONER, uint24(3000), int24(60), address(0), uint256(1 ether)));
        vm.prank(PM); vm.expectRevert(GuardedSwapRH.BadCallback.selector); g.unlockCallback(abi.encode(WETH, BONER, uint24(3000), int24(60), address(0), uint256(1 ether)));
        assertEq(bal(WETH, address(g)), 1 ether);
    }
    /// limits cannot be bypassed: per-call ETH cap, per-hour buy count, a sale above the lot
    function test_fork_limits() public {
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); g.buy{value: 0.051 ether}(BONER, 1, block.timestamp, h);
        for (uint256 i = 0; i < 12; i++) _buy(BONER, 0.001 ether, h);
        vm.prank(address(acct)); vm.expectRevert(GuardedSwapRH.RateLimited.selector); g.buy{value: 0.001 ether}(BONER, 1, block.timestamp, h);
        uint256 b = bal(BONER, address(acct)); deal(BONER, address(acct), b * 2);           // tokens that did not come through the gate
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), b * 2));
        vm.expectPartialRevert(GuardedSwapRH.NotInLot.selector); acct.exec(address(g), _sd(BONER, b * 2, rev(h)));
    }
    /// The residual, measured: a stolen executor key routes the account's lot into the thief's own genuine Uniswap v3 pool
    /// at a ruinous price. The factory check passes (the pool is real); the loss budget (30% of ETH + lots) is what stops it.
    function test_fork_genuine_sink_pool_is_bounded_by_the_loss_budget() public {
        vm.deal(address(acct), 0.01 ether);                                                 // the whole account goes into the position
        GuardedSwapRH.Hop[] memory h = arr(v3(WETH, BONER, BONER_POOL, 10000));
        uint256 got = _buy(BONER, 0.01 ether, h);
        address sink = IV3Factory(UNI_V3).createPool(WETH, BONER, 500);
        IV3Pool(sink).initialize(2505414483750479311864138015696063);                      // ~1e9 BONER per WETH: thousands of times worse
        SinkLP lp = new SinkLP(); vm.deal(address(lp), 1 ether); vm.prank(THIEF); lp.seed{value: 0.001 ether}(sink, 207250, 208250, 1e19);
        GuardedSwapRH.Hop[] memory s = arr(v3(BONER, WETH, sink, 500));
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got));
        (, uint256 budget) = g.budgetOf(address(acct)); assertEq(budget, 0.003 ether);
        vm.expectPartialRevert(GuardedSwapRH.BudgetExceeded.selector);
        acct.exec(address(g), _sd(BONER, got, s));
        uint256 out = abi.decode(acct.exec(address(g), _sd(BONER, got / 5, s)), (uint256));
        (uint256 lost, ) = g.budgetOf(address(acct)); assertGt(lost, 0.0019 ether); assertLe(lost, 0.002 ether); emit log_named_uint("sink paid for a fifth of the lot", out);
        acct.exec(BONER, abi.encodeWithSelector(0x095ea7b3, address(g), got / 5));
        vm.expectPartialRevert(GuardedSwapRH.BudgetExceeded.selector);
        acct.exec(address(g), _sd(BONER, got / 5, s));
        assertEq(address(g).balance, 0); assertEq(bal(BONER, address(g)), 0); assertEq(bal(BONER, THIEF), 0);
    }
}
