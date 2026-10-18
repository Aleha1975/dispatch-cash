// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../src/GuardedSwap.sol";

contract MockToken {
    string public name = "Mock"; string public symbol = "MOCK"; uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf; mapping(address => mapping(address => uint256)) internal _allow;
    function allowance(address o, address s) external view returns (uint256) { if (allowanceReverts) revert("no"); return _allow[o][s]; }
    uint256 public feeBps;                                  // fee-on-transfer, burned
    bool public revertOnZeroApprove;                        // BNB-style approve(spender, 0) revert
    bool public zeroFirst;                                  // USDT-style: a non-zero allowance may only be set from zero
    bool public allowanceReverts;                           // allowance() that does not answer (round-5 I-4)
    function setAllowanceReverts(bool b) external { allowanceReverts = b; }
    function setZeroFirst(bool b) external { zeroFirst = b; }
    function setRevertOnZeroApprove(bool b) external { revertOnZeroApprove = b; }
    function setFee(uint256 b) external { feeBps = b; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { if (revertOnZeroApprove && a == 0) revert("zero"); if (zeroFirst && a != 0 && _allow[msg.sender][s] != 0) revert("zero first"); _allow[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = _allow[f][msg.sender]; require(al >= a, "allowance"); _allow[f][msg.sender] = al - a; _move(f, to, a); return true; }
    function _move(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "balance"); balanceOf[f] -= a; uint256 fee = a * feeBps / 10000; balanceOf[to] += a - fee; }
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
    uint256 public ethPerToken; uint256 public tokensPerEth; address public payTo; bool public reenter; address public guard; bool public reenterOk; uint256 public overpay; bool public pullLess;
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
            if (reenter) { (bool ok, ) = guard.call(abi.encodeWithSignature("announce(address,uint256,uint256)", d.dstToken, uint256(1), uint256(1))); reenterOk = ok; }
            return (msg.value * tokensPerEth, 0);
        }
        MockToken(d.srcToken).transferFrom(msg.sender, address(this), pullLess ? d.amount / 2 : d.amount);   // pullLess: a route that leaves half the allowance behind
        uint256 eth = d.amount * ethPerToken / 1e18;
        (bool ok2, ) = to.call{value: eth}(""); require(ok2, "pay");
        return (eth, 0);
    }
}

contract Wallet { receive() external payable {} }
