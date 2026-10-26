// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../src/GuardedSwap.sol";

contract MockToken {
    string public name = "Mock"; string public symbol = "MOCK"; uint8 public decimals = 18;
    mapping(address => uint256) internal _bal; mapping(address => mapping(address => uint256)) internal _allow;
    mapping(address => bool) public bricked;                 // balanceOf(a) reverts for a bricked address (blacklist that also kills reads, round-11 H-1)
    function setBricked(address a, bool b) external { bricked[a] = b; }
    bool public burnsGas;                                    // balanceOf that burns every unit of gas it is given (v17: a registry entry must not block the walk)
    function setBurnsGas(bool b) external { burnsGas = b; }
    function balanceOf(address a) public view returns (uint256) { if (bricked[a]) revert("bricked"); if (burnsGas) { uint256 i; while (true) { i++; } } return _bal[a]; }
    function allowance(address o, address s) external view returns (uint256) { if (allowanceReverts) revert("no"); return _allow[o][s]; }
    uint256 public feeBps;                                  // fee-on-transfer, burned
    bool public revertOnZeroApprove;                        // BNB-style approve(spender, 0) revert
    bool public zeroFirst;                                  // USDT-style: a non-zero allowance may only be set from zero
    bool public allowanceReverts;                           // allowance() that does not answer (round-5 I-4)
    function setAllowanceReverts(bool b) external { allowanceReverts = b; }
    function setZeroFirst(bool b) external { zeroFirst = b; }
    function setRevertOnZeroApprove(bool b) external { revertOnZeroApprove = b; }
    function setFee(uint256 b) external { feeBps = b; }
    function mint(address to, uint256 a) external { _bal[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { if (revertOnZeroApprove && a == 0) revert("zero"); if (zeroFirst && a != 0 && _allow[msg.sender][s] != 0) revert("zero first"); _allow[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = _allow[f][msg.sender]; require(al >= a, "allowance"); _allow[f][msg.sender] = al - a; _move(f, to, a); return true; }
    function _move(address f, address to, uint256 a) internal virtual { require(_bal[f] >= a, "balance"); _bal[f] -= a; uint256 fee = a * feeBps / 10000; _bal[to] += a - fee; }
}

/// v17: a token that pays ETH to `home` whenever tokens are transferred to it (an ETH refund hidden in the token transfer).
contract RefundingToken is MockToken {
    address public home; uint256 public refundWei;
    receive() external payable {}
    function setRefund(address h, uint256 w) external { home = h; refundWei = w; }
    function _move(address f, address to, uint256 a) internal override {
        super._move(f, to, a);
        if (to == home && refundWei > 0) { (bool ok, ) = home.call{value: refundWei}(""); require(ok, "refund"); }
    }
}

/// A token whose balanceOf lies: reports `fake` for `victim` after `arm()` (H-1 proof of concept helper).
contract LyingToken {
    uint256 public fake; address public victim; bool public armed;
    function arm(address v, uint256 f) external { victim = v; fake = f; armed = true; }
    function balanceOf(address a) external view returns (uint256) { return (armed && a == victim) ? fake : 0; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

/// A Kyber-shaped router stand-in: decodes the same calldata the real router takes. Buy: mints tokensPerEth per ETH of
/// desc.dstToken to desc.dstReceiver (or `payTo` when set: a dishonest executor path). Sell: pulls desc.amount of
/// desc.srcToken from msg.sender and pays ETH at ethPerToken to desc.dstReceiver (or `payTo`). Optional re-entrancy.
contract MockRouter {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public ethPerToken; uint256 public tokensPerEth; address public payTo; bool public reenter; address public guard; bool public reenterOk; uint256 public overpay; bool public pullLess; bool public pullNone; uint256 public refund; address public kickTo; uint256 public kickWei;
    function setKickback(address to, uint256 w) external { kickTo = to; kickWei = w; }   // v17: on a buy, pays `w` of the input straight to `to` (the account), past the gate
    function setPullNone(bool b) external { pullNone = b; }
    function setRefund(uint256 w) external { refund = w; }
    function setOverpay(uint256 w) external { overpay = w; }
    function setPullLess(bool b) external { pullLess = b; }
    receive() external payable {}
    function set(uint256 tpe, uint256 ept, address to) external { tokensPerEth = tpe; ethPerToken = ept; payTo = to; }
    function setReenter(address g) external { reenter = true; guard = g; }
    function swap(GuardedSwap.SwapExecutionParams calldata p) external payable returns (uint256, uint256) { return _run(p.desc); }
    function swapSimpleMode(address, GuardedSwap.SwapDescriptionV2 calldata d, bytes calldata, bytes calldata) external payable returns (uint256, uint256) { return _run(d); }
    function _run(GuardedSwap.SwapDescriptionV2 memory d) internal returns (uint256, uint256) {
        address to = payTo != address(0) ? payTo : d.dstReceiver;
        if (d.srcToken == K_ETH) {
            require(msg.value == d.amount, "value");
            MockToken(d.dstToken).mint(to, msg.value * tokensPerEth);
            if (overpay > 0) { (bool okp, ) = msg.sender.call{value: msg.value + overpay}(""); require(okp, "overpay"); }   // refunds more than it was sent
            if (refund > 0) { (bool okr, ) = msg.sender.call{value: refund}(""); require(okr, "refund"); }                   // returns part of the input as change
            if (kickWei > 0) { (bool okk, ) = kickTo.call{value: kickWei}(""); require(okk, "kick"); }                        // returns part of the input to the account itself
            if (reenter) { (bool ok, ) = guard.call(abi.encodeWithSignature("sell(address,uint256,uint256,bytes)", d.dstToken, uint256(1), uint256(1), bytes(""))); reenterOk = ok; }
            return (msg.value * tokensPerEth, 0);
        }
        if (!pullNone) MockToken(d.srcToken).transferFrom(msg.sender, address(this), pullLess ? d.amount / 2 : d.amount);   // pullLess: a route that leaves half the allowance behind; pullNone: takes nothing
        uint256 eth = d.amount * ethPerToken / 1e18;
        (bool ok2, ) = to.call{value: eth}(""); require(ok2, "pay");
        return (eth, 0);
    }
}

contract Wallet { receive() external payable {} }

/// A caller that reads the guard's view of its own lot from inside the ETH-refund hook (round-6 L-2: state must be final by then).
contract SpyWallet {
    GuardedSwap public g; address public tok; uint256 public seenTokens; uint256 public hooks;
    function set(GuardedSwap g_, address t) external { g = g_; tok = t; }
    receive() external payable { hooks += 1; (seenTokens, ) = g.basis(address(this), tok); }
    function buy(uint256 eth, uint256 minOut, bytes calldata data) external returns (uint256) { return g.buy{value: eth}(tok, minOut, data); }
    function sell(uint256 amount, uint256 minOut, bytes calldata data) external returns (uint256) { MockToken(tok).approve(address(g), amount); return g.sell(tok, amount, minOut, data); }
}
