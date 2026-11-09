// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../src/GuardedGate.sol";

contract MockToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    mapping(address => uint256) internal _bal; mapping(address => mapping(address => uint256)) internal _allow;
    uint256 public feeBps;                       // fee-on-transfer, burned
    mapping(address => bool) public blacklisted;     // issuer blacklist: transfers TO this address revert
    function setBlocked(address a, bool b) external { blacklisted[a] = b; }
    function setFee(uint256 b) external { feeBps = b; }
    function balanceOf(address a) public view virtual returns (uint256) { return _bal[a]; }
    function mint(address to, uint256 a) external { _bal[to] += a; emit Transfer(address(0), to, a); }
    function burn(address from, uint256 a) external { _bal[from] -= a; }   // test helper: a negative rebase / hidden burn
    // mode: 0 normal; 1 return-data bomb (2 MB returned); 2 returns nothing (USDT style); 3 transfer returns false without moving
    uint8 public mode;
    function setMode(uint8 m) external { mode = m; }
    function _ret() internal view {
        uint8 m = mode;
        assembly { switch m case 1 { return(0, 2000000) } case 2 { return(0, 0) } default { mstore(0, 1) return(0, 32) } }
    }
    function approve(address s, uint256 a) external returns (bool) { _allow[msg.sender][s] = a; _ret(); return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (mode == 3) { assembly { mstore(0, 0) return(0, 32) } }
        _move(msg.sender, to, a); _ret(); return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = _allow[f][msg.sender]; require(al >= a, "allowance"); _allow[f][msg.sender] = al - a; _move(f, to, a); return true; }
    function _move(address f, address to, uint256 a) internal virtual { require(!blacklisted[to], "blacklisted"); require(_bal[f] >= a, "balance"); _bal[f] -= a; uint256 fee = a * feeBps / 10000; _bal[to] += a - fee; emit Transfer(f, to, a - fee); }
}

/// ERC-777 style: tries to re-enter the gate while a transfer is in progress; records whether the gate refused.
contract HookToken is MockToken {
    address public gate; bytes public payload; bool public armed; bool public blocked; bool public hit;
    function arm(address g, bytes calldata p) external { gate = g; payload = p; armed = true; }
    function _move(address f, address to, uint256 a) internal override {
        super._move(f, to, a);
        if (armed && f == gate) { armed = false; hit = true; (bool ok, bytes memory r) = gate.call(payload); blocked = !ok && r.length >= 4 && bytes4(r) == GuardedGate.Reentrancy.selector; }
    }
}

contract MockRouter {
    address constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public ethPerToken; uint256 public tokensPerEth; address public payTo;
    address public reenterGate; bytes public reenterData; bool public reentered; bool public reentryBlocked;
    uint256 public kickWei; address public kickTo; bool public pullHalf; uint256 public refund;
    receive() external payable {}
    function set(uint256 tpe, uint256 ept, address to) external { tokensPerEth = tpe; ethPerToken = ept; payTo = to; }
    function setReenter(address g, bytes calldata d) external { reenterGate = g; reenterData = d; }
    function setKickback(address to, uint256 w) external { kickTo = to; kickWei = w; }
    function setPullHalf(bool b) external { pullHalf = b; }
    function setRefund(uint256 w) external { refund = w; }
    function swap(GuardedGate.SwapExecutionParams calldata p) external payable returns (uint256, uint256) { return _run(p.desc); }
    function _run(GuardedGate.SwapDescriptionV2 memory d) internal returns (uint256, uint256) {
        address to = payTo != address(0) ? payTo : d.dstReceiver;
        if (reenterGate != address(0)) { reentered = true; (bool ok, bytes memory r) = reenterGate.call(reenterData); reentryBlocked = !ok && r.length >= 4 && bytes4(r) == GuardedGate.Reentrancy.selector; }
        if (d.srcToken == K_ETH) {
            require(msg.value == d.amount, "value");
            MockToken(d.dstToken).mint(to, msg.value * tokensPerEth);
            if (refund > 0) { (bool okr, ) = msg.sender.call{value: refund}(""); require(okr, "refund"); }
            if (kickWei > 0) { (bool okk, ) = kickTo.call{value: kickWei}(""); require(okk, "kick"); }
            return (msg.value * tokensPerEth, 0);
        }
        uint256 pull = pullHalf ? d.amount / 2 : d.amount;
        MockToken(d.srcToken).transferFrom(msg.sender, address(this), pull);
        uint256 eth = pull * ethPerToken / 1e18;
        (bool ok2, ) = to.call{value: eth}(""); require(ok2, "pay");
        return (eth, 0);
    }
}

/// A smart account stand-in: owner() like the Hybrid account; exec() plays the DelegationManager (anyone may call it in tests).
contract MockAccount {
    address public owner;
    constructor(address o) { owner = o; }
    receive() external payable {}
    function setOwner(address o) external { owner = o; }
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
    }
}
/// A contract with no owner() at all.
contract NoOwnerAccount {
    receive() external payable {}
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
    }
}
/// FEE_TO that re-enters the gate when paid.
contract ReenteringSink {
    address public gate; bytes public payload; bool public blocked; bool public hit;
    function set(address g, bytes calldata p) external { gate = g; payload = p; }
    receive() external payable { if (gate != address(0)) { hit = true; (bool ok, bytes memory r) = gate.call(payload); blocked = !ok && r.length >= 4 && bytes4(r) == GuardedGate.Reentrancy.selector; } }
}

/// An account whose owner() always reverts (contract-wallet owner / passkey-only), but which can call the gate.
contract RevertingOwnerAccount {
    receive() external payable {}
    function owner() external pure returns (address) { revert("no owner"); }
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
    }
}
/// owner() burns lots of gas before answering (cold proxy style): needs more than the old 30k.
contract SlowOwnerAccount {
    address public o; constructor(address o_) { o = o_; }
    receive() external payable {}
    function owner() external view returns (address) { uint256 x; for (uint256 i = 0; i < 250; i++) { x += uint256(keccak256(abi.encode(i, x))) & 1; } x; return o; }
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
    }
}
