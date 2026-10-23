// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../src/GuardedSwapRH.sol";

contract MockToken {
    string public name = "Mock"; string public symbol = "MOCK"; uint8 public decimals = 18;
    mapping(address => uint256) internal _bal; mapping(address => mapping(address => uint256)) internal _allow;
    mapping(address => bool) public bricked;                 // balanceOf(a) reverts for a bricked address
    function setBricked(address a, bool b) external { bricked[a] = b; }
    function balanceOf(address a) public view virtual returns (uint256) { if (bricked[a]) revert("bricked"); return _bal[a]; }
    function allowance(address o, address s) external view returns (uint256) { return _allow[o][s]; }
    uint256 public feeBps;
    function setFee(uint256 b) external { feeBps = b; }
    function mint(address to, uint256 a) external { _bal[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { _allow[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = _allow[f][msg.sender]; require(al >= a, "allowance"); _allow[f][msg.sender] = al - a; _move(f, to, a); return true; }
    function _move(address f, address to, uint256 a) internal virtual { require(_bal[f] >= a, "balance"); _bal[f] -= a; uint256 fee = a * feeBps / 10000; _bal[to] += a - fee; }
}

/// WETH stand-in: deposit/withdraw against real ETH held here.
contract MockWETH is MockToken {
    function deposit() external payable { _bal[msg.sender] += msg.value; }
    function withdraw(uint256 a) external { require(_bal[msg.sender] >= a, "balance"); _bal[msg.sender] -= a; (bool ok, ) = msg.sender.call{value: a}(""); require(ok, "eth"); }
    receive() external payable { _bal[msg.sender] += msg.value; }
}

/// A v3 factory stand-in answering both getPool shapes: (a,b,uint24 fee) and (a,b,int24 tickSpacing).
contract MockFactory {
    mapping(bytes32 => address) public pools;
    function set(address a, address b, uint24 key, address pool) external { pools[keccak256(abi.encode(a, b, key))] = pool; pools[keccak256(abi.encode(b, a, key))] = pool; }
    function getPool(address a, address b, uint24 fee) external view returns (address) { return pools[keccak256(abi.encode(a, b, fee))]; }
    function getPool(address a, address b, int24 ts) external view returns (address) { return pools[keccak256(abi.encode(a, b, uint24(ts)))]; }
}

/// Prices shared by the pool and PoolManager stand-ins: `ethSide` in -> `rateBuy` out per unit (1e18-scaled);
/// any other token in -> `rateSell` out per unit (1e18-scaled). Outputs are minted (tokens) or paid from held ETH.
abstract contract Priced {
    address public ethSide; uint256 public rateBuy = 1000e18; uint256 public rateSell = 1e15;
    function setRates(uint256 b, uint256 s) external { rateBuy = b; rateSell = s; }
    function _out(address tin, uint256 amt) internal view returns (uint256) { return tin == ethSide || tin == address(0) ? amt * rateBuy / 1e18 : amt * rateSell / 1e18; }
}

/// A Uniswap-v3-style pool stand-in (token0 < token1): exact input only, pays `recipient`, then asks the caller to pay in
/// the callback and checks it was paid. Misbehaviours for the tests are switches.
contract MockV3Pool is Priced {
    address public token0; address public token1; address public weth;
    address public payTo; bool public consumeHalf; bool public skipCallback; uint256 public askMore; bool public askBoth; bool public askWrongSide; address public reenterTarget; bytes public reenterData; bool public reenterOk; uint256 public calls;
    constructor(address a, address b, address weth_, address eth_) { (token0, token1) = a < b ? (a, b) : (b, a); weth = weth_; ethSide = eth_; }
    function setPayTo(address t) external { payTo = t; }
    function setConsumeHalf(bool b) external { consumeHalf = b; }
    function setSkipCallback(bool b) external { skipCallback = b; }
    function setAskMore(uint256 x) external { askMore = x; }
    function setAskBoth(bool b) external { askBoth = b; }
    function setAskWrongSide(bool b) external { askWrongSide = b; }
    function setReenter(address t, bytes calldata d) external { reenterTarget = t; reenterData = d; }
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata) external returns (int256 a0, int256 a1) {
        calls++;
        require(amountSpecified > 0, "exact input only");
        uint256 inAmt = uint256(amountSpecified); if (consumeHalf) inAmt /= 2;
        address tin = zeroForOne ? token0 : token1;
        uint256 out = _out(tin, inAmt);
        _pay(zeroForOne ? token1 : token0, payTo != address(0) ? payTo : recipient, out);
        if (reenterTarget != address(0)) { (reenterOk, ) = reenterTarget.call(reenterData); }
        if (skipCallback) return (0, 0);
        (a0, a1) = _deltas(zeroForOne, inAmt + askMore, out);
        uint256 before = MockToken(tin).balanceOf(address(this));
        GuardedSwapRH(payable(msg.sender)).uniswapV3SwapCallback(a0, a1, "");
        require(MockToken(tin).balanceOf(address(this)) >= before + inAmt, "IIA");
    }
    function _deltas(bool zeroForOne, uint256 owed, uint256 out) internal view returns (int256 a0, int256 a1) {
        (a0, a1) = zeroForOne ? (int256(owed), -int256(out)) : (-int256(out), int256(owed));
        if (askBoth) { a0 = int256(owed); a1 = int256(owed); }
        if (askWrongSide) (a0, a1) = (a1, a0);
    }
    function _pay(address t, address to, uint256 a) internal { MockToken(t).mint(to, a); }
    receive() external payable {}
}

/// A Uniswap v4 PoolManager stand-in: unlock -> unlockCallback; swap books deltas for msg.sender; sync/settle/take as v4.
/// Every currency's delta must be zero when unlock returns.
contract MockPoolManager is Priced {
    struct Key { address c0; address c1; uint24 fee; int24 ts; address hooks; }
    struct Params { bool zeroForOne; int256 amountSpecified; uint160 limit; }
    bool public unlocked; address public locker; mapping(address => int256) public delta; address[] internal touched;
    address public synced; uint256 public reserves; address public weth;
    // misbehaviours
    bool public consumeHalf; int256 public outOverride; bool public hookSkim; bool public skipCallback; bool public flipSign; address public reenterTarget; bytes public reenterData; bool public reenterOk;
    Key public lastKey; Params public lastParams; bytes public lastHookData; uint256 public swaps;
    mapping(bytes32 => bool) public initialized;
    constructor(address weth_) { weth = weth_; }
    function init(address c0, address c1, uint24 fee, int24 ts, address hooks) external { initialized[keccak256(abi.encode(c0, c1, fee, ts, hooks))] = true; }
    function setEthSide(address e) external { ethSide = e; }
    function setConsumeHalf(bool b) external { consumeHalf = b; }
    function setOutOverride(int256 x) external { outOverride = x; }
    function setHookSkim(bool b) external { hookSkim = b; }
    function setSkipCallback(bool b) external { skipCallback = b; }
    function setReenter(address t, bytes calldata d) external { reenterTarget = t; reenterData = d; }
    function _touch(address c) internal { touched.push(c); }
    function unlock(bytes calldata data) external returns (bytes memory r) {
        require(!unlocked, "AlreadyUnlocked"); unlocked = true; locker = msg.sender; delete touched;
        if (!skipCallback) r = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i = 0; i < touched.length; i++) require(delta[touched[i]] == 0, "CurrencyNotSettled");
        unlocked = false;
    }
    function swap(Key calldata key, Params calldata p, bytes calldata hookData) external returns (int256) {
        require(unlocked && msg.sender == locker, "ManagerLocked");
        require(initialized[keccak256(abi.encode(key.c0, key.c1, key.fee, key.ts, key.hooks))], "PoolNotInitialized");
        swaps++; lastKey = key; lastParams = p; lastHookData = hookData;
        require(p.amountSpecified < 0, "exact input only");
        uint256 inAmt = uint256(-p.amountSpecified); if (consumeHalf) inAmt /= 2;
        (address tin, address tout) = p.zeroForOne ? (key.c0, key.c1) : (key.c1, key.c0);
        int256 out = int256(_out(tin, inAmt)); if (outOverride != 0) out = outOverride; if (hookSkim) out = out * 97 / 100;
        if (reenterTarget != address(0)) { (reenterOk, ) = reenterTarget.call(reenterData); }
        delta[tin] -= int256(inAmt); delta[tout] += out; _touch(tin); _touch(tout);
        int128 dIn = -int128(int256(inAmt)); int128 dOut = int128(out);
        (int128 a0, int128 a1) = p.zeroForOne ? (dIn, dOut) : (dOut, dIn);
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }
    function sync(address c) external { synced = c; reserves = c == address(0) ? 0 : MockToken(c).balanceOf(address(this)); }
    function settle() external payable returns (uint256 paid) {
        require(unlocked, "ManagerLocked");
        if (synced == address(0)) { paid = msg.value; delta[address(0)] += int256(paid); _touch(address(0)); }
        else { require(msg.value == 0, "NonzeroNativeValue"); paid = MockToken(synced).balanceOf(address(this)) - reserves; delta[synced] += int256(paid); _touch(synced); }
        synced = address(0); reserves = 0;
    }
    function take(address c, address to, uint256 amt) external {
        require(unlocked, "ManagerLocked");
        delta[c] -= int256(amt); _touch(c);
        if (c == address(0)) { (bool ok, ) = to.call{value: amt}(""); require(ok, "native"); }
        else MockToken(c).mint(to, amt);
    }
    receive() external payable {}
}
interface IUnlockCallback { function unlockCallback(bytes calldata) external returns (bytes memory); }

contract Wallet { receive() external payable {} }

/// A caller that reads the gate's view of its own lot from inside the ETH payment (state must be final by then).
contract SpyWallet {
    GuardedSwapRH public g; address public tok; uint256 public seenTokens; uint256 public hooks;
    function set(GuardedSwapRH g_, address t) external { g = g_; tok = t; }
    receive() external payable { hooks += 1; (seenTokens, ) = g.basis(address(this), tok); }
    function buy(uint256 eth, uint256 minOut, GuardedSwapRH.Hop[] calldata h) external returns (uint256) { return g.buy{value: eth}(tok, minOut, block.timestamp, h); }
    function sell(uint256 amount, uint256 minOut, GuardedSwapRH.Hop[] calldata h) external returns (uint256) { MockToken(tok).approve(address(g), amount); return g.sell(tok, amount, minOut, block.timestamp, h); }
}

/// A smart-account stand-in: forwards a call and bubbles its revert (what a delegation redemption does, minus the caveats).
contract SmartAccount {
    receive() external payable {}
    function exec(address target, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}
