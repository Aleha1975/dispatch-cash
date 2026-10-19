// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardedSwap
/// @notice A one-purpose gate between a client's smart account and the KyberSwap aggregator router.
///         The account grants its executor the right to call THIS contract instead of the router. Whatever a swap
///         returns goes to the calling account and nobody else. The router calldata is decoded here and must name the
///         caller (or this contract) as the recipient and the declared tokens; it is never forwarded unchecked.
///         No owner, no upgrade, no funds kept between calls. Anyone may call it; it can only ever pay the caller.
///
///         Guards on top of the recipient rule, because an executor key that is stolen could still trade badly:
///         1. Loss budget. Every buy is recorded in the account's lot for that token at cost. A sale that returns less
///            than the cost of the tokens it gives up is a LOSS; losses accumulate per account and must stay within
///            BUDGET_BPS of the account's total cost basis, refilling linearly over REFILL. A sale beyond the budget does
///            not go through. Sales at or above cost never touch the budget, so taking profit is never delayed; a market
///            crash of one position is far inside the budget; a thief dumping everything hits it within minutes.
///         2. Only the lot is for sale. sell() handles at most the tokens this contract saw bought for the account;
///            tokens that reached the account any other way (airdrops, positions opened before this gate) are not the
///            executor's to sell -- the account owner sells them directly. The lot shrinks by what the account gave up,
///            never exceeds what the account holds (tokens the owner moved out leave the lot pro rata, as if sold at
///            cost), and closes when the account holds none of the token.
///         3. Rate limit. Per account and fixed hour window: at most MAX_SELLS_PER_HOUR sales, MAX_BUY_ETH_PER_HOUR of
///            ETH spent on buys and MAX_SELL_ETH_PER_HOUR of ETH taken out of sales (a burst at the window edge can
///            reach twice that across two windows).
///         4. Two keys kept off the executor's machine. The GUARDIAN can pause buys (at most PAUSE_MAX, then a day of
///            cooldown); it never blocks a sale and cannot move funds. The EXIT key -- the operator's cold key -- can
///            reset an account's loss budget (unlock, when a crash was the market and not a theft) and can run exit():
///            a sale paid to the account, outside the loss budget and the hourly limits, used to turn every position
///            into ETH on the clients' own accounts when the executor key is known to be compromised. Neither key can
///            send anything anywhere but the account. Withdrawals never pass through here.
///         5. Only this call's funds. Token and ETH balances are measured as deltas around the router call: anything sent
///            to this contract outside a call is neither swept, nor counted, nor recoverable. A sale is paid to this
///            contract and forwarded after settlement, so state is written before any ETH leaves.
///         6. The router's executor is pinned (EXECUTOR); only the router's swap(SwapExecutionParams) entry point is
///            accepted, with no flag bit the router dispatches on, no permit, no fee receivers, no srcReceivers on a buy.
///         7. Residual, by design: a sale's srcReceivers are chosen by the aggregator (often the first pool) and cannot be
///            told apart from a planted sink on-chain; what such a sink can take is bounded by the loss budget. A buy has
///            no price reference other than the hourly ETH budget. The budget is relative to what was paid, not to the
///            market: a position that has appreciated can be sold at cost without touching the budget.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GuardedSwap {
    // KyberSwap MetaAggregationRouterV2 calldata shape (decoded, never trusted blindly)
    struct SwapDescriptionV2 { address srcToken; address dstToken; address[] srcReceivers; uint256[] srcAmounts; address[] feeReceivers; uint256[] feeAmounts; address dstReceiver; uint256 amount; uint256 minReturnAmount; uint256 flags; bytes permit; }
    struct SwapExecutionParams { address callTarget; address approveTarget; bytes targetData; SwapDescriptionV2 desc; bytes clientData; }
    bytes4 private constant SEL_SWAP = 0xe21fd0e9;           // swap(SwapExecutionParams); swapSimpleMode (its own selector, or flag 0x20 inside swap) takes its pools from targetData, which this contract does not check
    uint256 private constant FLAGS_ALLOWED = 0x200;          // the one flag bit live routes carry and the router never reads (verified in its source); every bit the router dispatches on is refused
    address private constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable ROUTER;
    address public immutable EXECUTOR;                // the router's aggregation executor the calldata must call
    address public immutable EXIT_KEY;                // the operator's cold key: unlock and exit, nothing else
    uint256 public constant BUDGET_BPS = 3000;      // losses may reach 30% of the account's cost basis...
    uint256 public constant REFILL = 7 days;        // ...and that room comes back linearly over a week
    uint256 public constant PAUSE_MAX = 7 days;     // a pause lifts itself after this
    uint256 public constant PAUSE_COOLDOWN = 1 days; // and a new pause may start only this long after the last one ended
    uint256 public constant PENDING_TTL = 7 days;   // a proposed guardian must accept within this
    uint256 public constant MAX_RECEIVERS = 8;      // srcReceivers a sale route may name
    uint256 public constant MAX_LOT = 1e40;         // raw token units a lot may hold (keeps the arithmetic far from overflow)

    struct Basis { uint256 tokens; uint256 ethIn; }     // the lot: tokens held and their running cost
    mapping(address => mapping(address => Basis)) public basis;
    mapping(address => uint256) public costOf;        // the account's total cost basis across lots (the budget's base)
    struct Loss { uint256 amount; uint64 at; }         // losses accumulated, as of `at` (decaying linearly since)
    mapping(address => Loss) public loss;

    uint256 public immutable MAX_SELLS_PER_HOUR;      // set at deployment (production: 12)
    uint256 public immutable MAX_BUY_ETH_PER_HOUR;    // set at deployment (production: 0.3 ether)
    uint256 public immutable MAX_SELL_ETH_PER_HOUR;   // set at deployment (production: 1 ether)
    struct Window { uint64 start; uint64 sells; uint128 buyEth; uint128 sellEth; }      // per account, resets when the hour is over
    mapping(address => Window) public window;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingAt;                          // when the pending guardian was proposed
    uint256 public pausedAt;                           // 0 = not paused; a pause expires PAUSE_MAX after this
    uint256 public pauseEnd;                           // when the last pause ended (0 = never paused, or paused now)

    uint256 private _lock;

    event Bought(address indexed account, address indexed token, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed account, address indexed token, uint256 tokensIn, uint256 ethOut, uint256 lossAdded, bool exit);
    event Unlocked(address indexed account, uint256 lossCleared);
    event Paused(bool paused);
    event GuardianProposed(address indexed current, address indexed proposed);
    event GuardianChanged(address indexed previous, address indexed current);

    error Reentrancy();
    error ZeroAmount();
    error MinOutZero();
    error BelowMinOut(uint256 got, uint256 minOut);
    error BudgetExceeded(uint256 lossAfter, uint256 budget);
    error NotInLot(uint256 lot, uint256 asked);
    error RouterFailed(bytes reason);
    error RouterOverpaid();
    error TransferFailed();
    error EthSendFailed();
    error IsPaused();
    error PauseCooldown();
    error NotGuardian();
    error NotExitKey();
    error BadGuardian();
    error RateLimited();
    error BadRoute();
    error NotAContract();
    error TooLarge();
    error NotPendingGuardian();
    error NoDirectEth();

    constructor(address router, address executor, address guardian_, address exitKey, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour, uint256 maxSellEthPerHour) {
        require(router != address(0) && executor != address(0) && guardian_ != address(0) && exitKey != address(0), "zero address");
        require(guardian_ != router && guardian_ != executor && guardian_ != address(this), "guardian");
        require(exitKey != router && exitKey != executor && exitKey != guardian_ && exitKey != address(this), "exit key");
        require(router != executor, "router == executor");
        require(router.code.length > 0 && executor.code.length > 0, "not a contract");
        require(exitKey.code.length == 0, "exit key must be an EOA");    // it submits transactions itself: tx.origin is how exit() recognises it
        require(maxSellsPerHour > 0 && maxBuyEthPerHour > 0 && maxSellEthPerHour > 0, "zero limit");
        require(maxSellsPerHour <= type(uint64).max && maxBuyEthPerHour <= type(uint128).max && maxSellEthPerHour <= type(uint128).max, "limit too large");
        ROUTER = router; EXECUTOR = executor; guardian = guardian_; EXIT_KEY = exitKey;
        MAX_SELLS_PER_HOUR = maxSellsPerHour; MAX_BUY_ETH_PER_HOUR = maxBuyEthPerHour; MAX_SELL_ETH_PER_HOUR = maxSellEthPerHour;
    }

    /// @dev ETH is accepted only while a trade is in progress (the proceeds of a sale, paid by the router or its executor on
    ///      unwrapping). Outside a call it is refused rather than stranded.
    receive() external payable { if (_lock == 0) revert NoDirectEth(); }

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }

    // ---- guardian: pause buys, rotate itself ----
    /// @notice Paused while the guardian's pause is younger than PAUSE_MAX: a lost key can never freeze buys for good.
    function paused() public view returns (bool) { return pausedAt != 0 && block.timestamp < pausedAt + PAUSE_MAX; }
    /// @notice The guardian stops and resumes buys. Sales are never blocked by a pause. A pause lasts at most PAUSE_MAX and
    ///         the next may start only PAUSE_COOLDOWN after the last one ended.
    function setPaused(bool p) external lock onlyGuardian {
        if (p) {
            if (paused()) revert PauseCooldown();
            uint256 end = pausedAt != 0 ? pausedAt + PAUSE_MAX : pauseEnd;     // an expired pause ended at its expiry
            if (end != 0 && block.timestamp < end + PAUSE_COOLDOWN) revert PauseCooldown();
            pausedAt = block.timestamp; pauseEnd = 0;
        } else if (pausedAt != 0) {
            uint256 exp = pausedAt + PAUSE_MAX; pauseEnd = block.timestamp < exp ? block.timestamp : exp; pausedAt = 0;
        }
        emit Paused(p);
    }
    /// @notice Two-step guardian rotation: the current guardian proposes, the proposed address accepts within PENDING_TTL.
    function proposeGuardian(address next) external lock onlyGuardian {
        if (next == address(0) || next == guardian || next == ROUTER || next == EXECUTOR || next == EXIT_KEY || next == address(this)) revert BadGuardian();
        pendingGuardian = next; pendingAt = block.timestamp; emit GuardianProposed(guardian, next);
    }
    function acceptGuardian() external lock {
        if (msg.sender != pendingGuardian || msg.sender == address(0)) revert NotPendingGuardian();
        if (block.timestamp > pendingAt + PENDING_TTL) revert NotPendingGuardian();
        emit GuardianChanged(guardian, msg.sender); guardian = msg.sender; pendingGuardian = address(0); pendingAt = 0;
    }

    // ---- exit key: unlock a budget, run an exit ----
    /// @notice The cold key clears the accumulated losses of these accounts (a crash was the market, not a theft).
    function unlock(address[] calldata accounts) external lock {
        if (msg.sender != EXIT_KEY) revert NotExitKey();
        for (uint256 i = 0; i < accounts.length; i++) { uint256 l = loss[accounts[i]].amount; delete loss[accounts[i]]; emit Unlocked(accounts[i], l); }
    }

    // ---- windows, budget ----
    /// @dev The caller's hour window, reset when the hour is over.
    function _window() private returns (Window storage w) {
        w = window[msg.sender];
        if (block.timestamp >= w.start + 1 hours) { w.start = uint64(block.timestamp); w.sells = 0; w.buyEth = 0; w.sellEth = 0; }
    }
    function _countBuy(uint256 spent) private { Window storage w = _window(); if (w.buyEth + spent > MAX_BUY_ETH_PER_HOUR) revert RateLimited(); w.buyEth += uint128(spent); }
    /// @dev ethOut == 0: count the sale itself (before the router call); ethOut > 0: count what it took out (after it).
    function _countSell(uint256 ethOut) private {
        Window storage w = _window();
        if (ethOut == 0) { if (w.sells + 1 > MAX_SELLS_PER_HOUR) revert RateLimited(); w.sells += 1; return; }
        if (ethOut > type(uint128).max) revert TooLarge();
        if (w.sellEth + ethOut > MAX_SELL_ETH_PER_HOUR) revert RateLimited(); w.sellEth += uint128(ethOut);
    }
    function _ceil(uint256 a, uint256 b) private pure returns (uint256) { return (a + b - 1) / b; }
    /// @dev The account's budget: BUDGET_BPS of its cost basis. Losses decay towards zero at budget / REFILL per second.
    function _budget(address account) private view returns (uint256) { return costOf[account] * BUDGET_BPS / 10000; }
    function _decayed(address account) private view returns (uint256) {
        Loss storage l = loss[account];
        if (l.amount == 0) return 0;
        uint256 back = _budget(account) * (block.timestamp - l.at) / REFILL;
        return back >= l.amount ? 0 : l.amount - back;
    }
    /// @notice Losses on the account's record right now, and the budget they must stay within.
    function budgetOf(address account) external view returns (uint256 lost, uint256 budget) { return (_decayed(account), _budget(account)); }

    /// @dev The lot never exceeds what the account holds: tokens the owner moved out (or a negative rebase) leave the lot
    ///      pro rata, as if sold at cost (rounded so the average never drops). An empty balance closes the lot. Tokens that
    ///      arrive before the next call are indistinguishable from the lot and carried at its cost.
    function _trim(address token) private returns (Basis storage b) {
        b = basis[msg.sender][token];
        if (b.tokens == 0) return b;
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        if (bal == 0) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; return b; }
        if (bal < b.tokens) { uint256 keep = _ceil(b.ethIn * bal, b.tokens); costOf[msg.sender] -= b.ethIn - keep; b.ethIn = keep; b.tokens = bal; }
    }
    /// @dev What _trim would make of the lot, without writing: the views quote the reconciled lot.
    function _trimmed(address account, address token) private view returns (uint256 tokens, uint256 ethIn) {
        Basis storage b = basis[account][token];
        (tokens, ethIn) = (b.tokens, b.ethIn);
        if (tokens == 0) return (0, 0);
        uint256 bal = IERC20(token).balanceOf(account);
        if (bal == 0) return (0, 0);
        if (bal < tokens) { ethIn = _ceil(ethIn * bal, tokens); tokens = bal; }
    }

    /// @dev The router calldata must be swap(SwapExecutionParams) with no flag the router dispatches on, run by EXECUTOR,
    ///      carry no fee receivers and no permit, move exactly `tokenIn` -> `tokenOut` for `amount`, and demand at least
    ///      `minOut` from the router itself. A buy pays this contract or the caller and may not hand the input to any
    ///      srcReceiver; a sale pays this contract only (forwarded after settlement) and may name srcReceivers, because
    ///      the router delivers the sold tokens straight to the first pool -- the loss budget bounds what that can cost.
    function _checkRoute(bytes calldata routerData, address tokenIn, address tokenOut, uint256 amount, uint256 minOut) private view {
        if (routerData.length < 4 || bytes4(routerData[:4]) != SEL_SWAP) revert BadRoute();
        SwapExecutionParams memory p = abi.decode(routerData[4:], (SwapExecutionParams)); SwapDescriptionV2 memory d = p.desc;
        if (p.callTarget != EXECUTOR) revert BadRoute();
        if (p.approveTarget != address(0) && p.approveTarget != EXECUTOR) revert BadRoute();
        if (d.flags & ~FLAGS_ALLOWED != 0) revert BadRoute();                          // every router mode but the plain one is refused (0x20 = simple mode, routed by targetData; 0x01..0x100 = partial fill, extra ETH, claim, burn, fees, approve)
        if (d.dstReceiver != address(this) && (tokenIn != K_ETH || d.dstReceiver != msg.sender)) revert BadRoute();   // sales are paid here, forwarded after settlement
        if (d.feeReceivers.length != 0 || d.feeAmounts.length != 0) revert BadRoute();
        if (d.permit.length != 0) revert BadRoute();                                   // this contract pulls and approves itself; the router's permit hook is never needed
        if (d.srcToken != tokenIn || d.dstToken != tokenOut) revert BadRoute();
        if (d.amount != amount) revert BadRoute();
        if (d.minReturnAmount < minOut) revert BadRoute();
        if (d.srcReceivers.length != d.srcAmounts.length || d.srcReceivers.length > MAX_RECEIVERS) revert BadRoute();
        if (tokenIn == K_ETH) { if (d.srcReceivers.length != 0) revert BadRoute(); }
        else { uint256 sum; for (uint256 i = 0; i < d.srcReceivers.length; i++) { if (d.srcReceivers[i].code.length == 0 || d.srcReceivers[i] == msg.sender || d.srcReceivers[i] == address(this)) revert BadRoute(); sum += d.srcAmounts[i]; } if (sum > amount) revert BadRoute(); }
    }

    /// @notice Spend msg.value of ETH on `token` through the router. Output and any unspent ETH go to msg.sender.
    function buy(address token, uint256 minOut, bytes calldata routerData) external payable lock returns (uint256 out) {
        if (paused()) revert IsPaused();
        if (msg.value == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        _trim(token);                                               // the lot is reconciled with what the account holds before this buy
        _checkRoute(routerData, K_ETH, token, msg.value, minOut);
        if (msg.value > MAX_BUY_ETH_PER_HOUR) revert RateLimited();   // the net spend is counted below, once known
        uint256 ethBase = address(this).balance - msg.value;        // ETH that was here before this call stays untouched
        uint256 tokBase = IERC20(token).balanceOf(address(this));   // tokens that were here before this call stay untouched
        uint256 before = IERC20(token).balanceOf(msg.sender);
        _callRouter(routerData, msg.value);
        _sweepToken(token, tokBase);
        out = IERC20(token).balanceOf(msg.sender) - before;
        if (out < minOut) revert BelowMinOut(out, minOut);
        uint256 change = address(this).balance - ethBase;           // unspent part of msg.value, returned to the caller last
        if (change > msg.value) revert RouterOverpaid();
        uint256 spent = msg.value - change;
        if (spent == 0) revert ZeroAmount();                        // a free lot would have no cost to protect
        _countBuy(spent);                                           // hourly budget counts what was actually spent
        Basis storage b = basis[msg.sender][token];
        b.ethIn += spent; b.tokens += out; costOf[msg.sender] += spent;
        if (b.tokens > MAX_LOT) revert TooLarge();
        emit Bought(msg.sender, token, spent, out);
        if (change > 0) _sendEth(msg.sender, change);               // state is final before any ETH leaves
    }

    /// @notice Sell `amount` of `token` (at most the lot) for ETH through the router, within the loss budget.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        return _sale(token, amount, minOut, routerData, false);
    }
    /// @notice The cold key's exit: the same sale, outside the loss budget and the hourly limits, paid to the account.
    ///         Reached through the account's delegation to the exit key: the account is msg.sender, the key is tx.origin.
    function exit(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (tx.origin != EXIT_KEY) revert NotExitKey();
        return _sale(token, amount, minOut, routerData, true);
    }

    function _sale(address token, uint256 amount, uint256 minOut, bytes calldata routerData, bool isExit) private returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        { uint256 lot = _trim(token).tokens; if (amount > lot) revert NotInLot(lot, amount); }   // only what this gate saw bought, and still holds
        if (!isExit) _countSell(0);
        uint256 tokBase = IERC20(token).balanceOf(address(this));   // tokens that were here before this call stay untouched
        uint256 got = _pull(token, msg.sender, amount);             // what actually arrived (fee-on-transfer aware)
        _checkRoute(routerData, token, K_ETH, got, minOut);
        _approveForRouter(token, got);
        uint256 ethBase = address(this).balance;
        _callRouter(routerData, 0);
        _approveSoft(token, ROUTER, 0);                             // cleanup only; a token that rejects approve(0) must not undo the sale
        uint256 back = _sweepToken(token, tokBase);                 // whatever the router did not take goes back
        out = address(this).balance - ethBase;                      // the sale is paid here and forwarded last
        if (out < minOut) revert BelowMinOut(out, minOut);
        if (!isExit) _countSell(out);
        if (back >= amount) revert ZeroAmount();                    // nothing was sold: no cost released, no slot spent
        _settle(token, amount - back, out, isExit);                 // the lot shrinks by what the account gave up (pull-side fees included)
        if (out > 0) _sendEth(msg.sender, out);                     // state is final before any ETH leaves
    }

    /// @dev Release the cost of what was sold; a sale below that cost is a loss charged to the account's budget (unless it
    ///      is the cold key's exit). The lot is reduced pro rata and closed when the account holds none of the token.
    function _settle(address token, uint256 sold, uint256 out, bool isExit) private {
        Basis storage b = basis[msg.sender][token];
        if (sold > b.tokens) revert NotInLot(b.tokens, sold);      // cannot happen (checked on entry); kept as the invariant
        uint256 cost = b.ethIn * sold / b.tokens;                   // released cost rounded DOWN: the remainder's average never drops, never zeroes
        uint256 added;
        if (!isExit && out < cost) {
            added = cost - out;
            uint256 total = _decayed(msg.sender) + added; uint256 budget = _budget(msg.sender);   // the budget is measured before this sale's cost leaves the base
            if (total > budget) revert BudgetExceeded(total, budget);
            loss[msg.sender] = Loss(total, uint64(block.timestamp));
        }
        b.ethIn -= cost; b.tokens -= sold; costOf[msg.sender] -= cost;
        if (b.tokens == 0 || IERC20(token).balanceOf(msg.sender) == 0) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; }   // full exit
        emit Sold(msg.sender, token, sold, out, added, isExit);
    }

    /// @notice The lot as the next call will see it: tokens still held and their cost.
    function lotOf(address account, address token) external view returns (uint256 tokens, uint256 ethIn) { return _trimmed(account, token); }
    /// @notice The lowest ETH a sale of `amount` of `token` would accept right now without exceeding the budget (0 = any, or not in the lot).
    function floorFor(address account, address token, uint256 amount) external view returns (uint256) {
        (uint256 tokens, uint256 ethIn) = _trimmed(account, token);
        if (tokens == 0 || amount > tokens) return 0;
        uint256 cost = ethIn * amount / tokens; uint256 room = _budget(account); uint256 lost = _decayed(account);
        room = room > lost ? room - lost : 0;
        return cost > room ? cost - room : 0;
    }

    function _callRouter(bytes calldata data, uint256 value) private {
        (bool ok, bytes memory err) = ROUTER.call{value: value}(data);
        if (!ok) revert RouterFailed(err);
    }
    /// @dev What this call added to the contract's `token` balance (above `base`) goes to msg.sender; returns the amount moved.
    function _sweepToken(address token, uint256 base) private returns (uint256 held) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        held = bal > base ? bal - base : 0;
        if (held > 0) _send(token, msg.sender, held);
    }

    // ---- token helpers: low-level calls so tokens that return nothing (USDT-style) work too ----
    function _pull(address token, address from, uint256 amount) private returns (uint256 got) {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
        got = IERC20(token).balanceOf(address(this)) - before;
        if (got == 0) revert ZeroAmount();
    }
    function _send(address token, address to, uint256 amount) private {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }
    function _approveTry(address token, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        return ok && (r.length == 0 || abi.decode(r, (bool)));
    }
    /// @dev Approve the router for this sale: try directly; a token that wants zero first (and may still hold a leftover
    ///      allowance from a route that did not pull everything) gets a zero in between. Only a token that refuses both
    ///      orders is unsupported.
    function _approveForRouter(address token, uint256 amount) private {
        if (_approveTry(token, ROUTER, amount)) return;
        _approveSoft(token, ROUTER, 0);
        if (!_approveTry(token, ROUTER, amount)) revert TransferFailed();
    }
    function _approveSoft(address token, address spender, uint256 amount) private {
        (bool ok, ) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount)); ok;
    }
    function _sendEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }
}
