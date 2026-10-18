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
///         1. Price floor. buy() records the ETH paid per token for the calling account; sell() refuses to return less
///            than FLOOR_BPS of that entry price. Tokens beyond what this contract saw bought take the slow path.
///         2. Slow path. A sale below the floor, or of tokens this contract never saw bought, is allowed only after
///            announce(token, amount) at least SLOW_DELAY earlier, within ANNOUNCE_TTL and up to that amount.
///         3. Rate limit. Per account and fixed hour window: at most MAX_SELLS_PER_HOUR sales and MAX_BUY_ETH_PER_HOUR of
///            ETH spent on buys (a burst at the window edge can reach twice that across two windows).
///         4. Pause. A guardian address can pause buys; under a pause every sale takes the announced slow path, so a
///            pause can delay an exit by an hour but never block it. The guardian cannot move funds; withdrawals never
///            pass through here.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GuardedSwap {
    // KyberSwap MetaAggregationRouterV2 calldata shapes (decoded, never trusted blindly)
    struct SwapDescriptionV2 { address srcToken; address dstToken; address[] srcReceivers; uint256[] srcAmounts; address[] feeReceivers; uint256[] feeAmounts; address dstReceiver; uint256 amount; uint256 minReturnAmount; uint256 flags; bytes permit; }
    struct SwapExecutionParams { address callTarget; address approveTarget; bytes targetData; SwapDescriptionV2 desc; bytes clientData; }
    bytes4 private constant SEL_SWAP = 0xe21fd0e9;           // swap(SwapExecutionParams)
    bytes4 private constant SEL_SIMPLE = 0x8af033fb;         // swapSimpleMode(address,SwapDescriptionV2,bytes,bytes)
    address private constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable ROUTER;
    uint256 public constant FLOOR_BPS = 5000;       // a sale may return no less than 50% of the entry price...
    uint256 public constant SLOW_DELAY = 1 hours;   // ...unless announced this long before
    uint256 public constant ANNOUNCE_TTL = 24 hours; // an announcement is good for this long after the delay

    struct Basis { uint256 ethIn; uint256 tokens; }     // ETH paid and tokens received through buy(), per account and token
    mapping(address => mapping(address => Basis)) public basis;
    struct Slow { uint64 from; uint192 amount; }        // an announced slow sale: allowed from `from`, up to `amount`
    mapping(address => mapping(address => Slow)) public slow;

    uint256 public immutable MAX_SELLS_PER_HOUR;      // set at deployment (production: 12)
    uint256 public immutable MAX_BUY_ETH_PER_HOUR;    // set at deployment (production: 0.3 ether)
    struct Window { uint64 start; uint64 sells; uint128 buyEth; }      // per account, resets when the hour is over
    mapping(address => Window) public window;

    address public immutable GUARDIAN;
    bool public paused;

    uint256 private _lock;

    event Bought(address indexed account, address indexed token, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed account, address indexed token, uint256 tokensIn, uint256 ethOut, bool slow);
    event SlowSaleArmed(address indexed account, address indexed token, uint256 amount, uint256 allowedFrom);
    event Paused(bool paused);

    error Reentrancy();
    error ZeroAmount();
    error MinOutZero();
    error BelowMinOut(uint256 got, uint256 minOut);
    error NotAnnounced();
    error RouterFailed(bytes reason);
    error TransferFailed();
    error EthSendFailed();
    error IsPaused();
    error NotGuardian();
    error RateLimited();
    error BadRoute();
    error NotAContract();

    constructor(address router, address guardian, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour) {
        require(router != address(0) && guardian != address(0), "zero address");
        require(maxSellsPerHour > 0 && maxBuyEthPerHour > 0, "zero limit");
        ROUTER = router; GUARDIAN = guardian;
        MAX_SELLS_PER_HOUR = maxSellsPerHour; MAX_BUY_ETH_PER_HOUR = maxBuyEthPerHour;
    }

    receive() external payable {}

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }

    /// @notice The guardian stops and resumes buys and fast sales. Announced sales are never blocked.
    function setPaused(bool p) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        paused = p;
        emit Paused(p);
    }

    /// @dev Hour-window counters per account: `sells` sales and `buyEth` wei spent since `start`.
    function _count(bool isSell, uint256 ethIn) private {
        Window storage w = window[msg.sender];
        if (block.timestamp >= w.start + 1 hours) { w.start = uint64(block.timestamp); w.sells = 0; w.buyEth = 0; }
        if (isSell) { if (w.sells + 1 > MAX_SELLS_PER_HOUR) revert RateLimited(); w.sells += 1; }
        else { if (w.buyEth + ethIn > MAX_BUY_ETH_PER_HOUR) revert RateLimited(); w.buyEth += uint128(ethIn); }
    }

    /// @dev The router calldata must be one of the two swap entry points, pay this contract or the caller, carry no fee
    ///      receivers, and move exactly `tokenIn` -> `tokenOut` for `amount`.
    function _checkRoute(bytes calldata routerData, address tokenIn, address tokenOut, uint256 amount) private view {
        if (routerData.length < 4) revert BadRoute();
        bytes4 sel = bytes4(routerData[:4]);
        SwapDescriptionV2 memory d;
        if (sel == SEL_SWAP) { SwapExecutionParams memory p = abi.decode(routerData[4:], (SwapExecutionParams)); d = p.desc; }
        else if (sel == SEL_SIMPLE) { (, d, , ) = abi.decode(routerData[4:], (address, SwapDescriptionV2, bytes, bytes)); }
        else revert BadRoute();
        if (d.dstReceiver != msg.sender && d.dstReceiver != address(this)) revert BadRoute();
        if (d.feeReceivers.length != 0 || d.feeAmounts.length != 0) revert BadRoute();
        if (d.srcToken != tokenIn || d.dstToken != tokenOut) revert BadRoute();
        if (d.amount != amount) revert BadRoute();
    }

    /// @notice Spend msg.value of ETH on `token` through the router. Output and any unspent ETH go to msg.sender.
    function buy(address token, uint256 minOut, bytes calldata routerData) external payable lock returns (uint256 out) {
        if (paused) revert IsPaused();
        if (msg.value == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        _checkRoute(routerData, K_ETH, token, msg.value);
        _count(false, msg.value);
        uint256 ethBase = address(this).balance - msg.value;        // ETH that was here before this call stays untouched
        uint256 before = IERC20(token).balanceOf(msg.sender);
        _callRouter(routerData, msg.value);
        _sweepToken(token);
        out = IERC20(token).balanceOf(msg.sender) - before;
        if (out < minOut) revert BelowMinOut(out, minOut);
        uint256 change = address(this).balance - ethBase;           // unspent part of msg.value, returned to the caller
        if (change > 0) _sendEth(msg.sender, change);
        uint256 spent = msg.value - change;
        Basis storage b = basis[msg.sender][token];
        b.ethIn += spent;
        b.tokens += out;
        emit Bought(msg.sender, token, spent, out);
    }

    /// @notice Sell `amount` of `token` for ETH through the router. ETH and any unsold tokens go to msg.sender.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        _count(true, 0);
        uint256 got = _pull(token, msg.sender, amount);             // what actually arrived (fee-on-transfer aware)
        _checkRoute(routerData, token, K_ETH, got);
        _approve(token, ROUTER, got);
        uint256 ethBase = address(this).balance;
        uint256 before = msg.sender.balance;
        _callRouter(routerData, 0);
        _approve(token, ROUTER, 0);
        uint256 sold = got - _sweepToken(token);
        uint256 mine = address(this).balance - ethBase;             // ETH the router paid to this contract in this call
        if (mine > 0) _sendEth(msg.sender, mine);
        out = msg.sender.balance - before;
        if (out < minOut) revert BelowMinOut(out, minOut);
        _settle(token, sold, out);
    }

    /// @dev Price floor against the entry price recorded by buy(). A sale of more than the recorded basis, or below the
    ///      floor, must have been announced SLOW_DELAY earlier for at least that amount. Then the basis is reduced.
    function _settle(address token, uint256 sold, uint256 out) private {
        Basis storage b = basis[msg.sender][token];
        // under a pause every sale is a slow one: announced an hour ahead, so a pause can delay an exit but never block it
        bool isSlow = paused || b.tokens == 0 || sold > b.tokens || out < b.ethIn * sold * FLOOR_BPS / (b.tokens * 10000);
        if (isSlow) {
            Slow storage s = slow[msg.sender][token];
            if (s.from == 0 || block.timestamp < s.from || block.timestamp > s.from + ANNOUNCE_TTL || sold > s.amount) { if (paused) revert IsPaused(); revert NotAnnounced(); }
            delete slow[msg.sender][token];
        }
        if (b.tokens > 0) {
            uint256 fromBasis = sold > b.tokens ? b.tokens : sold;
            b.ethIn -= b.ethIn * fromBasis / b.tokens;
            b.tokens -= fromBasis;
        }
        emit Sold(msg.sender, token, sold, out, isSlow);
    }

    /// @notice Announce a slow sale of up to `amount` of `token`; possible after SLOW_DELAY, for ANNOUNCE_TTL. Watched by the operator.
    function announce(address token, uint256 amount) external lock {
        if (amount == 0) revert ZeroAmount();
        uint256 from = block.timestamp + SLOW_DELAY;
        slow[msg.sender][token] = Slow(uint64(from), uint192(amount));
        emit SlowSaleArmed(msg.sender, token, amount, from);
    }

    /// @notice The lowest ETH `sell()` would accept right now for `amount` of `token` on the fast path (0 = slow path only).
    function floorFor(address account, address token, uint256 amount) external view returns (uint256) {
        Basis storage b = basis[account][token];
        if (b.tokens == 0 || amount > b.tokens) return 0;
        return b.ethIn * amount * FLOOR_BPS / (b.tokens * 10000);
    }

    function _callRouter(bytes calldata data, uint256 value) private {
        (bool ok, bytes memory err) = ROUTER.call{value: value}(data);
        if (!ok) revert RouterFailed(err);
    }
    /// @dev Everything of `token` this contract holds goes to msg.sender; returns the amount moved.
    function _sweepToken(address token) private returns (uint256 held) {
        held = IERC20(token).balanceOf(address(this));
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
    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }
    function _sendEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }
}
