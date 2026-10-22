// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../src/GuardedSwapRH.sol";

contract MockToken {
    string public name = "Mock"; string public symbol = "MOCK"; uint8 public decimals = 18;
    mapping(address => uint256) internal _bal; mapping(address => mapping(address => uint256)) internal _allow;
    mapping(address => bool) public bricked;                 // balanceOf(a) reverts for a bricked address (round-11 H-1)
    function setBricked(address a, bool b) external { bricked[a] = b; }
    function balanceOf(address a) public view returns (uint256) { if (bricked[a]) revert("bricked"); return _bal[a]; }
    function allowance(address o, address s) external view returns (uint256) { return _allow[o][s]; }
    uint256 public feeBps; bool public revertOnZeroApprove; bool public zeroFirst;
    function setZeroFirst(bool b) external { zeroFirst = b; }
    function setRevertOnZeroApprove(bool b) external { revertOnZeroApprove = b; }
    function setFee(uint256 b) external { feeBps = b; }
    function mint(address to, uint256 a) external { _bal[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { if (revertOnZeroApprove && a == 0) revert("zero"); if (zeroFirst && a != 0 && _allow[msg.sender][s] != 0) revert("zero first"); _allow[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = _allow[f][msg.sender]; require(al >= a, "allowance"); _allow[f][msg.sender] = al - a; _move(f, to, a); return true; }
    function _move(address f, address to, uint256 a) internal { require(_bal[f] >= a, "balance"); _bal[f] -= a; uint256 fee = a * feeBps / 10000; _bal[to] += a - fee; }
}

/// A v3 factory stand-in answering both getPool shapes: (a,b,uint24 fee) and (a,b,int24 tickSpacing).
contract MockFactory {
    mapping(bytes32 => address) public pools;
    function set(address a, address b, uint24 key, address pool) external { pools[keccak256(abi.encode(a, b, key))] = pool; pools[keccak256(abi.encode(b, a, key))] = pool; }
    function getPool(address a, address b, uint24 fee) external view returns (address) { return pools[keccak256(abi.encode(a, b, fee))]; }
    function getPool(address a, address b, int24 ts) external view returns (address) { return pools[keccak256(abi.encode(a, b, uint24(ts)))]; }
}

/// A Robinhood-router stand-in: the same ABI (swap(RouterHop[],address,uint256,uint256,uint256)), pays msg.sender, refuses a
/// non-zero recipient (BAD_ARGS, as the live router). Buy (first tokenIn native or WETH): mints tokensPerEth per ETH of the last
/// tokenOut to msg.sender (or `payTo`). Sale: pulls amountIn of the first tokenIn from msg.sender and pays ETH at ethPerToken
/// (or WETH when `payWeth`). Records the last call for the encoding tests.
contract MockRouterRH {
    address public WETH; address public V4_POOL_MANAGER;
    uint256 public ethPerToken; uint256 public tokensPerEth; address public payTo; bool public reenter; address public guard; bool public reenterOk; uint256 public overpay; bool public pullLess; bool public pullNone; uint256 public refund; bool public payWeth;
    // last call
    uint256 public lastN; address public lastRecipient; uint256 public lastAmountIn; uint256 public lastMinOut; uint256 public lastDeadline; uint256 public lastValue;
    GuardedSwapRH.RouterHop[] internal _last;
    constructor(address weth, address pm) { WETH = weth; V4_POOL_MANAGER = pm; }
    function lastHop(uint256 i) external view returns (GuardedSwapRH.RouterHop memory) { return _last[i]; }
    function setPullNone(bool b) external { pullNone = b; }
    function setRefund(uint256 w) external { refund = w; }
    function setOverpay(uint256 w) external { overpay = w; }
    function setPullLess(bool b) external { pullLess = b; }
    function setPayWeth(bool b) external { payWeth = b; }
    receive() external payable {}
    function set(uint256 tpe, uint256 ept, address to) external { tokensPerEth = tpe; ethPerToken = ept; payTo = to; }
    function setReenter(address g) external { reenter = true; guard = g; }
    function swap(GuardedSwapRH.RouterHop[] calldata hops, address recipient, uint256 amountIn, uint256 minOut, uint256 deadline) external payable {
        require(recipient == address(0), "BAD_ARGS");
        require(deadline == 0 || deadline >= block.timestamp, "Transaction too old");
        lastN = hops.length; lastRecipient = recipient; lastAmountIn = amountIn; lastMinOut = minOut; lastDeadline = deadline; lastValue = msg.value;
        delete _last; for (uint256 i = 0; i < hops.length; i++) _last.push(hops[i]);
        address to = payTo != address(0) ? payTo : msg.sender;
        address tin = hops[0].tokenIn; address tout = hops[hops.length - 1].tokenOut;
        if (tin == address(0) || tin == WETH) {
            MockToken(tout).mint(to, msg.value * tokensPerEth);
            if (overpay > 0) { (bool okp, ) = msg.sender.call{value: msg.value + overpay}(""); require(okp, "overpay"); }
            if (refund > 0) { (bool okr, ) = msg.sender.call{value: refund}(""); require(okr, "refund"); }
            if (reenter) { GuardedSwapRH.Hop[] memory h = new GuardedSwapRH.Hop[](0); (bool ok, ) = guard.call(abi.encodeWithSelector(GuardedSwapRH.sell.selector, tout, uint256(1), uint256(1), h)); reenterOk = ok; }
            return;
        }
        if (!pullNone) MockToken(tin).transferFrom(msg.sender, address(this), pullLess ? amountIn / 2 : amountIn);
        uint256 eth = amountIn * ethPerToken / 1e18;
        if (payWeth) { MockToken(WETH).mint(to, eth); return; }
        (bool ok2, ) = to.call{value: eth}(""); require(ok2, "pay");
    }
}

contract Wallet { receive() external payable {} }

/// A caller that reads the guard's view of its own lot from inside the ETH-refund hook (round-6 L-2: state must be final by then).
contract SpyWallet {
    GuardedSwapRH public g; address public tok; uint256 public seenTokens; uint256 public hooks;
    function set(GuardedSwapRH g_, address t) external { g = g_; tok = t; }
    receive() external payable { hooks += 1; (seenTokens, ) = g.basis(address(this), tok); }
    function buy(uint256 eth, uint256 minOut, GuardedSwapRH.Hop[] calldata h) external returns (uint256) { return g.buy{value: eth}(tok, minOut, h); }
    function sell(uint256 amount, uint256 minOut, GuardedSwapRH.Hop[] calldata h) external returns (uint256) { MockToken(tok).approve(address(g), amount); return g.sell(tok, amount, minOut, h); }
}

/// A smart-account stand-in: forwards a call and bubbles its revert (what a delegation redemption does, minus the caveats).
contract SmartAccount {
    receive() external payable {}
    function exec(address target, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}
