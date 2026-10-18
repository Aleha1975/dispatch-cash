// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockToken {
    string public name = "Mock"; string public symbol = "MOCK"; uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf; mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps;                                  // fee-on-transfer, burned
    function setFee(uint256 b) external { feeBps = b; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; require(al >= a, "allowance"); allowance[f][msg.sender] = al - a; _move(f, to, a); return true; }
    function _move(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "balance"); balanceOf[f] -= a; uint256 fee = a * feeBps / 10000; balanceOf[to] += a - fee; }
}

/// A router stand-in: on buy it mints `rate` tokens per ETH to `payTo`; on sell it pulls tokens and pays ETH at `rate`,
/// to `payTo` (the thief case) -- plus optional reentrancy.
contract MockRouter {
    MockToken public token; uint256 public ethPerToken;       // wei paid per whole token on sell
    uint256 public tokensPerEth;                              // tokens (whole) per 1 ETH on buy
    address public payTo; bool public reenter; address public guard; bool public reenterOk;
    constructor(MockToken t) { token = t; }
    receive() external payable {}
    function set(uint256 tpe, uint256 ept, address to) external { tokensPerEth = tpe; ethPerToken = ept; payTo = to; }
    function setReenter(address g) external { reenter = true; guard = g; }
    function buy() external payable {
        token.mint(payTo, msg.value * tokensPerEth);
        if (reenter) { (bool ok, ) = guard.call(abi.encodeWithSignature("buy(address,uint256,bytes)", address(token), uint256(1), abi.encodeWithSelector(MockRouter.buy.selector))); reenterOk = ok; }
    }
    function sell(uint256 amount) external {
        uint256 al = token.allowance(msg.sender, address(this)); if (al < amount) amount = al;   // a real router pulls what was approved
        token.transferFrom(msg.sender, address(this), amount);
        uint256 eth = amount * ethPerToken / 1e18;
        (bool ok, ) = payTo.call{value: eth}(""); require(ok, "pay");
    }
}

contract Wallet { receive() external payable {} }
