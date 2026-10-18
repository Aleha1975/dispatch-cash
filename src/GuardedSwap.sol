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
///         1. Price floor. Every buy is recorded in the account's lot for that token: the lot's REFERENCE price (its first
///            buy) and its cost-weighted AVERAGE price (all buys, reduced pro rata by sales). The floor price is the
///            higher of the two, so a cheap repeat buy cannot pull the floor below the reference and an expensive one
///            raises it. A fast sell() refuses to return less than FLOOR_BPS of the floor price for the tokens sold.
///         2. Only the lot is for sale. sell() handles at most the tokens this contract saw bought for the account;
///            tokens that reached the account any other way (airdrops, positions opened before this gate) are not the
///            executor's to sell -- the account owner sells them directly. There is no price to protect those with.
///         3. Slow path. A sale below the floor, or under a pause, is allowed only after announce(token, amount) at
///            least SLOW_DELAY earlier, within ANNOUNCE_TTL and up to that amount, and must still return SLOW_FLOOR_BPS
///            of the floor price. The announcement is the operator's hour of warning; it never licenses a sale for dust.
///         4. Rate limit. Per account and fixed hour window: at most MAX_SELLS_PER_HOUR sales, MAX_BUY_ETH_PER_HOUR of
///            ETH spent on buys and MAX_SELL_ETH_PER_HOUR of ETH taken out of sales (a burst at the window edge can
///            reach twice that across two windows).
///         5. Pause. A guardian can pause buys; under a pause every sale takes the announced slow path, so a pause can
///            delay an exit by an hour but never block it. A pause lifts itself after PAUSE_MAX and a new one may start
///            only PAUSE_COOLDOWN after the last one ended, so a hostile guardian cannot keep the fast path shut. The
///            guardian has no other power, cannot move funds and cannot touch announcements; withdrawals never pass
///            through here. It is rotated in two steps (propose, accept within PENDING_TTL) and should be a multisig.
///         6. Only this call's funds. Token and ETH balances are measured as deltas around the router call: anything sent
///            to this contract outside a call is neither swept, nor counted, nor recoverable. State is written before
///            any ETH leaves, so a caller's receive() hook sees the post-trade state.
///         7. The router's executor is pinned (EXECUTOR); only the router's swap(SwapExecutionParams) entry point is
///            accepted, its permit hook is refused, buys may not name any srcReceivers. A repeat buy may not price the
///            token below half or above four times the lot's reference, so repeats cannot compound.
///         8. Residual, by design: a sale's srcReceivers are chosen by the aggregator (often the first pool) and cannot be
///            told apart from a planted sink on-chain; what such a sink can take is bounded by the floors above. The
///            first buy of a lot has no price reference other than the hourly ETH budget. The floor is relative to what
///            was paid, not to the market: a position that has appreciated can be sold fast for FLOOR_BPS of its cost.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GuardedSwap {
    // KyberSwap MetaAggregationRouterV2 calldata shape (decoded, never trusted blindly)
    struct SwapDescriptionV2 { address srcToken; address dstToken; address[] srcReceivers; uint256[] srcAmounts; address[] feeReceivers; uint256[] feeAmounts; address dstReceiver; uint256 amount; uint256 minReturnAmount; uint256 flags; bytes permit; }
    struct SwapExecutionParams { address callTarget; address approveTarget; bytes targetData; SwapDescriptionV2 desc; bytes clientData; }
    bytes4 private constant SEL_SWAP = 0xe21fd0e9;           // swap(SwapExecutionParams); swapSimpleMode is not accepted (its pools live in a field this contract would not check)
    address private constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable ROUTER;
    address public immutable EXECUTOR;                // the router's aggregation executor the calldata must call
    uint256 public constant FLOOR_BPS = 5000;       // a fast sale may return no less than 50% of the floor price...
    uint256 public constant SLOW_FLOOR_BPS = 2000;  // ...an announced one no less than 20%: the slow path is for drops, not dust
    uint256 public constant REF_MAX_X = 4;          // a repeat buy may not price the token above 4x the reference entry
    uint256 public constant SLOW_DELAY = 1 hours;   // a slow sale must have been announced this long before
    uint256 public constant ANNOUNCE_TTL = 24 hours; // an announcement is good for this long after the delay
    uint256 public constant PAUSE_MAX = 7 days;     // a pause lifts itself after this
    uint256 public constant PAUSE_COOLDOWN = 1 days; // and a new pause may start only this long after the last one ended
    uint256 public constant PENDING_TTL = 7 days;   // a proposed guardian must accept within this
    uint256 public constant MAX_RECEIVERS = 8;      // srcReceivers a sale route may name
    uint256 public constant MAX_LOT = 1e40;         // raw token units a lot may hold (keeps the floor arithmetic far from overflow)

    struct Basis { uint256 tokens; uint256 ethIn; uint256 refEthIn; uint256 refTokens; }   // the lot: tokens held, their running cost, and the first buy (reference)
    mapping(address => mapping(address => Basis)) public basis;
    struct Slow { uint64 from; uint192 amount; }        // an announced slow sale: allowed from `from`, up to `amount`
    mapping(address => mapping(address => Slow)) public slow;

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
    event Sold(address indexed account, address indexed token, uint256 tokensIn, uint256 ethOut, bool slow);
    event SlowSaleArmed(address indexed account, address indexed token, uint256 amount, uint256 allowedFrom);
    event SlowSaleCancelled(address indexed account, address indexed token);
    event Paused(bool paused);
    event GuardianProposed(address indexed current, address indexed proposed);
    event GuardianChanged(address indexed previous, address indexed current);

    error Reentrancy();
    error ZeroAmount();
    error MinOutZero();
    error BelowMinOut(uint256 got, uint256 minOut);
    error BelowFloor(uint256 got, uint256 floor);
    error NotAnnounced();
    error NotInLot(uint256 lot, uint256 asked);
    error RouterFailed(bytes reason);
    error RouterOverpaid();
    error TransferFailed();
    error EthSendFailed();
    error IsPaused();
    error PauseCooldown();
    error NotGuardian();
    error BadGuardian();
    error RateLimited();
    error BadRoute();
    error NotAContract();
    error DilutesBasis();
    error TooLarge();
    error NotPendingGuardian();
    error NoDirectEth();

    constructor(address router, address executor, address guardian_, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour, uint256 maxSellEthPerHour) {
        require(router != address(0) && executor != address(0) && guardian_ != address(0), "zero address");
        require(guardian_ != router && guardian_ != executor, "guardian");
        require(router.code.length > 0 && executor.code.length > 0, "not a contract");
        require(maxSellsPerHour > 0 && maxBuyEthPerHour > 0 && maxSellEthPerHour > 0, "zero limit");
        require(maxBuyEthPerHour <= type(uint128).max && maxSellEthPerHour <= type(uint128).max, "limit too large");
        ROUTER = router; EXECUTOR = executor; guardian = guardian_;
        MAX_SELLS_PER_HOUR = maxSellsPerHour; MAX_BUY_ETH_PER_HOUR = maxBuyEthPerHour; MAX_SELL_ETH_PER_HOUR = maxSellEthPerHour;
    }

    /// @dev Only the router may send ETH here (the proceeds of a sale). Anything else is refused rather than stranded.
    receive() external payable { if (msg.sender != ROUTER) revert NoDirectEth(); }

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }

    /// @notice Paused while the guardian's pause is younger than PAUSE_MAX: a lost key can never freeze buys for good.
    function paused() public view returns (bool) { return pausedAt != 0 && block.timestamp < pausedAt + PAUSE_MAX; }
    /// @notice The guardian stops and resumes buys and fast sales. Announced sales are never blocked. A pause lasts at most
    ///         PAUSE_MAX and the next may start only PAUSE_COOLDOWN after the last one ended: the fast path is open at
    ///         least one day in eight however the guardian behaves.
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
        if (next == address(0) || next == guardian || next == ROUTER || next == EXECUTOR) revert BadGuardian();
        pendingGuardian = next; pendingAt = block.timestamp; emit GuardianProposed(guardian, next);
    }
    function acceptGuardian() external lock {
        if (msg.sender != pendingGuardian || msg.sender == address(0)) revert NotPendingGuardian();
        if (block.timestamp > pendingAt + PENDING_TTL) revert NotPendingGuardian();
        emit GuardianChanged(guardian, msg.sender); guardian = msg.sender; pendingGuardian = address(0); pendingAt = 0;
    }

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

    /// @dev The lot's floor price as a fraction: the higher of the reference price and the running average. Returned as
    ///      (eth, tokens) so callers divide once, rounding up.
    function _floorPair(Basis storage b) private view returns (uint256 e, uint256 t) {
        // average >= reference  <=>  ethIn / tokens >= refEthIn / refTokens
        if (b.ethIn * b.refTokens >= b.refEthIn * b.tokens) return (b.ethIn, b.tokens);
        return (b.refEthIn, b.refTokens);
    }
    function _floor(Basis storage b, uint256 amount, uint256 bps) private view returns (uint256) {
        (uint256 e, uint256 t) = _floorPair(b);
        return _ceil(e * amount * bps, t * 10000);
    }

    /// @dev The router calldata must be swap(SwapExecutionParams) run by EXECUTOR, pay this contract or the caller, carry
    ///      no fee receivers and no permit, move exactly `tokenIn` -> `tokenOut` for `amount`, and demand at least `minOut`
    ///      from the router itself. A buy (ETH in) may not hand the input to any srcReceiver; a sale may, because the
    ///      router delivers the sold tokens straight to the first pool -- the floors bound what that can cost.
    function _checkRoute(bytes calldata routerData, address tokenIn, address tokenOut, uint256 amount, uint256 minOut) private view {
        if (routerData.length < 4 || bytes4(routerData[:4]) != SEL_SWAP) revert BadRoute();
        SwapExecutionParams memory p = abi.decode(routerData[4:], (SwapExecutionParams)); SwapDescriptionV2 memory d = p.desc;
        if (p.callTarget != EXECUTOR) revert BadRoute();
        if (p.approveTarget != address(0) && p.approveTarget != EXECUTOR) revert BadRoute();
        if (d.dstReceiver != msg.sender && d.dstReceiver != address(this)) revert BadRoute();
        if (d.feeReceivers.length != 0 || d.feeAmounts.length != 0) revert BadRoute();
        if (d.permit.length != 0) revert BadRoute();                                   // this contract pulls and approves itself; the router's permit hook is never needed
        if (d.srcToken != tokenIn || d.dstToken != tokenOut) revert BadRoute();
        if (d.amount != amount) revert BadRoute();
        if (d.minReturnAmount < minOut) revert BadRoute();
        if (d.srcReceivers.length != d.srcAmounts.length || d.srcReceivers.length > MAX_RECEIVERS) revert BadRoute();
        if (tokenIn == K_ETH) { if (d.srcReceivers.length != 0) revert BadRoute(); }
        else { uint256 sum; for (uint256 i = 0; i < d.srcReceivers.length; i++) { if (d.srcReceivers[i].code.length == 0 || d.srcReceivers[i] == msg.sender) revert BadRoute(); sum += d.srcAmounts[i]; } if (sum > amount) revert BadRoute(); }
    }

    /// @notice Spend msg.value of ETH on `token` through the router. Output and any unspent ETH go to msg.sender.
    function buy(address token, uint256 minOut, bytes calldata routerData) external payable lock returns (uint256 out) {
        if (paused()) revert IsPaused();
        if (msg.value == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
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
        if (spent == 0) revert ZeroAmount();                        // a free lot would have no price to protect
        _countBuy(spent);                                           // hourly budget counts what was actually spent
        Basis storage b = basis[msg.sender][token];
        // the first buy of a lot sets the reference; every repeat is compared with THAT reference, not with the running
        // average, and may neither halve it (dilution) nor exceed four times it (inflation). The running cost takes every buy.
        if (b.tokens == 0) { b.refEthIn = spent; b.refTokens = out; b.ethIn = 0; delete slow[msg.sender][token]; }   // a new lot needs its own announcement
        else if (spent * b.refTokens * 10000 < b.refEthIn * out * FLOOR_BPS || spent * b.refTokens > b.refEthIn * out * REF_MAX_X) revert DilutesBasis();
        b.ethIn += spent;
        b.tokens += out;
        if (b.tokens > MAX_LOT) revert TooLarge();
        emit Bought(msg.sender, token, spent, out);
        if (change > 0) _sendEth(msg.sender, change);               // state is final before any ETH leaves
    }

    /// @notice Sell `amount` of `token` (at most the lot) for ETH through the router. ETH and any unsold tokens go to msg.sender.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        { uint256 lot = basis[msg.sender][token].tokens; if (amount > lot) revert NotInLot(lot, amount); }   // only what this gate saw bought
        _countSell(0);
        uint256 tokBase = IERC20(token).balanceOf(address(this));   // tokens that were here before this call stay untouched
        uint256 got = _pull(token, msg.sender, amount);             // what actually arrived (fee-on-transfer aware)
        _checkRoute(routerData, token, K_ETH, got, minOut);
        _approveForRouter(token, got);
        uint256 ethBase = address(this).balance;
        uint256 before = msg.sender.balance;
        _callRouter(routerData, 0);
        _approveSoft(token, ROUTER, 0);                             // cleanup only; a token that rejects approve(0) must not undo the sale
        uint256 sold = got - _sweepToken(token, tokBase);
        uint256 mine = address(this).balance - ethBase;             // ETH the router paid to this contract in this call, forwarded last
        out = msg.sender.balance - before + mine;
        if (out < minOut) revert BelowMinOut(out, minOut);
        _countSell(out);
        _settle(token, sold, out);
        if (mine > 0) _sendEth(msg.sender, mine);                   // state is final before any ETH leaves
    }

    /// @dev Price floor against the lot's floor price. A sale below it (or under a pause) must have been announced
    ///      SLOW_DELAY earlier for at least that amount and still clear SLOW_FLOOR_BPS. Then the lot is reduced pro rata.
    function _settle(address token, uint256 sold, uint256 out) private {
        Basis storage b = basis[msg.sender][token];
        if (sold > b.tokens) revert NotInLot(b.tokens, sold);      // cannot happen (checked on entry); kept as the invariant
        // under a pause every sale is a slow one: announced an hour ahead, so a pause can delay an exit but never block it
        bool isSlow = paused() || out < _floor(b, sold, FLOOR_BPS);
        if (isSlow) {
            Slow storage s = slow[msg.sender][token];
            if (s.from == 0 || block.timestamp < s.from || block.timestamp > s.from + ANNOUNCE_TTL || sold > s.amount) { if (paused()) revert IsPaused(); revert NotAnnounced(); }
            uint256 fl = _floor(b, sold, SLOW_FLOOR_BPS);          // the slow path has a floor of its own: a delay, never a licence for dust
            if (out < fl) revert BelowFloor(out, fl);
            if (sold == s.amount) delete slow[msg.sender][token]; else s.amount -= uint192(sold);   // the rest of the announcement stays usable
        }
        uint256 cost = b.ethIn * sold / b.tokens;                   // released cost rounded DOWN: the remainder's average never drops, never zeroes
        b.ethIn -= cost;
        b.tokens -= sold;
        if (b.tokens == 0) { b.ethIn = 0; b.refEthIn = 0; b.refTokens = 0; delete slow[msg.sender][token]; }  // full exit: the next buy starts a new lot
        emit Sold(msg.sender, token, sold, out, isSlow);
    }

    /// @notice Announce a slow sale of up to `amount` of `token`; possible after SLOW_DELAY, for ANNOUNCE_TTL. Watched by the operator.
    function announce(address token, uint256 amount) external lock {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint192).max) revert TooLarge();
        if (token.code.length == 0) revert NotAContract();
        uint256 from = block.timestamp + SLOW_DELAY;
        slow[msg.sender][token] = Slow(uint64(from), uint192(amount));
        emit SlowSaleArmed(msg.sender, token, amount, from);
    }

    /// @notice Withdraw an announcement (the account's own).
    function cancelAnnounce(address token) external lock {
        delete slow[msg.sender][token];
        emit SlowSaleCancelled(msg.sender, token);
    }

    /// @notice The lowest ETH `sell()` would accept right now for `amount` of `token` on the fast path (0 = not in the lot).
    function floorFor(address account, address token, uint256 amount) external view returns (uint256) {
        Basis storage b = basis[account][token];
        if (b.tokens == 0 || amount > b.tokens) return 0;
        return _floor(b, amount, FLOOR_BPS);
    }
    /// @notice The lowest ETH an ANNOUNCED sale of `amount` would accept (0 = not in the lot).
    function slowFloorFor(address account, address token, uint256 amount) external view returns (uint256) {
        Basis storage b = basis[account][token];
        if (b.tokens == 0 || amount > b.tokens) return 0;
        return _floor(b, amount, SLOW_FLOOR_BPS);
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
