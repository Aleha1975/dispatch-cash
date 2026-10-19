# -*- coding: utf-8 -*-
# v13 (round 11 fixes): C-1 frozen refill rate, H-1 balanceOf that stops answering, M-1 outbound sweep measured on the
# account, L-3 constructor self-checks. Applies to src/GuardedSwap.sol once.
p = "src/GuardedSwap.sol"; s = open(p, encoding="utf-8").read()
assert "uint256 rate;" not in s, "already v13"
def rep(old, new, n=1):
    global s
    assert s.count(old) >= 1, "missing: " + old[:90]
    s = s.replace(old, new, n)

# --- C-1: the refill speed is fixed when a loss is booked and never rises while it is outstanding
rep("    struct Loss { uint256 amount; uint64 at; }         // losses accumulated, as of `at` (decaying linearly since)",
    "    struct Loss { uint256 amount; uint256 rate; uint64 at; }   // losses accumulated, as of `at`, refilling at `rate` per REFILL: the budget in\n"
    "                                                                 // force when the loss was booked, never raised while a loss is outstanding (round 11, C-1)")
rep("        uint256 back = _budget(account) * (block.timestamp - l.at) / REFILL;",
    "        uint256 back = l.rate * (block.timestamp - l.at) / REFILL;   // against the rate frozen at booking, not today's cost basis")
rep("""            uint256 total = _decayed(msg.sender) + added; uint256 budget = _budget(msg.sender);   // the budget is measured before this sale's cost leaves the base
            if (total > budget) revert BudgetExceeded(total, budget);
            loss[msg.sender] = Loss(total, uint64(block.timestamp));""",
    """            uint256 carried = _decayed(msg.sender); uint256 total = carried + added; uint256 budget = _budget(msg.sender);   // the budget is measured before this sale's cost leaves the base
            if (total > budget) revert BudgetExceeded(total, budget);
            // the refill speed is the budget in force now, but never more than the speed already running: a buy after a loss
            // cannot make the loss fade faster, and a loss outlives the lots it came from (round 11, C-1 mechanisms B-D)
            uint256 rate = loss[msg.sender].rate; if (carried == 0 || rate > budget) rate = budget;
            loss[msg.sender] = Loss(total, rate, uint64(block.timestamp));""")

# --- H-1: a token whose balanceOf stops answering keeps its last lot instead of blocking sell() and exit()
rep("""        uint256 bal = IERC20(token).balanceOf(msg.sender);
        if (bal == 0) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; return b; }""",
    """        (bool ok, uint256 bal) = _balanceOf(token, msg.sender);
        if (!ok) return b;                                          // unreadable balance: keep the last lot; the sale or the cold key's exit must not die here (round 11, H-1)
        if (bal == 0) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; return b; }""")
rep("""        uint256 bal = IERC20(token).balanceOf(account);
        if (bal == 0) return (0, 0);""",
    """        (bool ok, uint256 bal) = _balanceOf(token, account);
        if (!ok) return (tokens, ethIn);
        if (bal == 0) return (0, 0);""")
rep("        if (b.tokens == 0 || IERC20(token).balanceOf(msg.sender) == 0) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; }   // full exit",
    "        (bool okb, uint256 left) = _balanceOf(token, msg.sender);\n        if (b.tokens == 0 || (okb && left == 0)) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; }   // full exit (an unreadable balance is not taken as empty)")

# --- M-1: the outbound sweep is measured on the recipient, as buy() measures its output
rep("""    function _sweepToken(address token, uint256 base) private returns (uint256 held) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        held = bal > base ? bal - base : 0;
        if (held > 0) _send(token, msg.sender, held);
    }""",
    """    function _sweepToken(address token, uint256 base) private returns (uint256 delivered) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 held = bal > base ? bal - base : 0;
        if (held == 0) return 0;
        (bool ok, uint256 before) = _balanceOf(token, msg.sender);
        _send(token, msg.sender, held);
        if (!ok) return held;                                       // the account's balance does not answer: count what left this contract
        (bool ok2, uint256 after_) = _balanceOf(token, msg.sender);
        delivered = ok2 && after_ >= before ? after_ - before : held;   // measured on the account, as buy() does (round 11, M-1): a fee on the way out shrinks what came back
    }
    /// @dev balanceOf that reports whether the token answered instead of reverting the whole call.
    function _balanceOf(address token, address who) private view returns (bool ok, uint256 bal) {
        (bool s_, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (!s_ || r.length < 32) return (false, 0);
        return (true, abi.decode(r, (uint256)));
    }""")
rep("    /// @dev What this call added to the contract's `token` balance (above `base`) goes to msg.sender; returns the amount moved.",
    "    /// @dev What this call added to the contract's `token` balance (above `base`) goes to msg.sender; returns what the account received.")

# --- L-3: constructor distinctness vs address(this)
rep('        require(router != executor, "router == executor");',
    '        require(router != executor, "router == executor");\n        require(router != address(this) && executor != address(this), "self");')

# --- docs
rep("///            not go through. Sales at or above cost never touch the budget, so taking profit is never delayed; a market",
    "///            not go through. The refill speed is fixed when a loss is booked (the budget in force then) and never rises\n"
    "///            while a loss is outstanding, so neither new buys nor closing the lot can make a loss fade faster or freeze it.\n"
    "///            Sales at or above cost never touch the budget, so taking profit is never delayed; a market")
open(p, "w", encoding="utf-8").write(s); print("v13 contract patched")
