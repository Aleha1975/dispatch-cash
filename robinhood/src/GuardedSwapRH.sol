// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardedSwapRH
/// @notice GuardedSwap v15 ported to Robinhood Chain (chain id 4663): a one-purpose gate between a client's smart account and
///         the Robinhood swap router (selector 0x4d819a2a, structured hops). The account grants its executor the right to
///         call THIS contract instead of the router. Whatever a swap returns goes to the calling account and nobody else.
///         Unlike the Kyber gate, this contract never receives router calldata: the executor names the hops (structured,
///         seven fields each), the gate checks them and encodes the router call itself -- recipient zero (the router then
///         pays msg.sender, i.e. this contract), PoolManager pinned, no hook data, no extra word. No owner, no upgrade, no
///         funds kept between calls. Anyone may call it; it can only ever pay the caller.
///
///         Guards on top of the recipient rule, because an executor key that is stolen could still trade badly
///         (identical to v15 unless marked RH):
///         1. Loss budget. Every buy is recorded in the account's lot for that token at cost. A sale that returns less
///            than the cost of the tokens it gives up is a LOSS; losses accumulate per account and must stay within
///            BUDGET_BPS of the account's total cost basis. What is outstanding fades linearly over REFILL from the last
///            booking -- nothing but time (or the cold key's unlock) moves it. Sales at or above cost never touch the budget.
///         2. Only the lot is for sale. sell() handles at most the tokens this contract saw bought for the account; the lot
///            shrinks by what the account gave up, never exceeds what the account holds and closes when the account holds none.
///         3. Rate limit. Per account and fixed hour window: at most MAX_SELLS_PER_HOUR sales, MAX_BUY_ETH_PER_HOUR of ETH
///            spent on buys and MAX_SELL_ETH_PER_HOUR of ETH taken out of sales.
///         4. Two keys kept off the executor's machine. The GUARDIAN can pause the executor -- buys and sells -- for at most
///            PAUSE_MAX, then a day of cooldown; it cannot move funds and never blocks exit(). The EXIT key -- the operator's
///            cold key -- can unlock() an account's loss budget, replaceGuardian(), and run exit(): a sale paid to the
///            account, outside the loss budget and the hourly limits.
///         5. Only this call's funds. Token and ETH balances are measured as deltas around the router call. A sale is paid
///            to this contract and forwarded after settlement, so state is written before any ETH leaves.
///         6. (RH) Route rule. 1..MAX_HOPS hops, each version 1 (v3-style pool) or 2 (Uniswap v4); a buy starts at the ETH
///            side (native or WETH) and ends at `token`, a sale the reverse; every hop starts where the previous one ended;
///            no intermediate token is the ETH side or the traded token. A v3 hop's pool must be the pool an allowed factory
///            returns for (tokenIn, tokenOut, fee) -- the gate asks the factory, never the pool. A v4 hop names no pool;
///            the router uses its own PoolManager (verified), and this contract pins POOL_MANAGER in the encoding anyway.
///         7. (RH) Residual, by design: v4 hooks and v3 pools are permissionless -- anyone can open a genuine pool (any
///            hook, any price) on an allowed factory or on the PoolManager. Such a pool is a sink that cannot be told apart
///            on-chain from a thin market; what it can take is bounded by minOut, measured here, and by the loss budget,
///            exactly as the Kyber gate's srcReceivers residual. The router charges 1% of every swap (feeRate 100 / 10000)
///            to its feeCollector; that fee is part of the price the account pays and the loss budget sees.
///         8. (RH) The router is an upgradeable proxy whose admin and owner is one EOA (verified on chain). Nothing here
///            trusts it: allowance is granted for the exact amount and reset, output is measured on this contract and on
///            the account, and a router that pays less than minOut reverts the whole call. A malicious upgrade can deny
///            service (including exit()), never move more than the one trade's input.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GuardedSwapRH {
    /// @notice One hop as the executor names it. version 1 = v3-style pool (pool set, hooks zero), 2 = Uniswap v4 (pool zero;
    ///         fee, tickSpacing and hooks are the PoolKey). For a v3 hop `fee` is the factory key the router validates its
    ///         callback with: the fee tier on fee-keyed factories, the tick spacing on tick-keyed (Slipstream-style) ones.
    struct Hop { uint8 version; address tokenIn; address tokenOut; address pool; uint24 fee; int24 tickSpacing; address hooks; }
    /// @dev The router's own hop: (version, tokenIn, tokenOut, pool, fee, tickSpacing, hooks, hookData, poolManager, extra).
    struct RouterHop { uint8 version; address tokenIn; address tokenOut; address pool; uint24 fee; int24 tickSpacing; address hooks; bytes hookData; address poolManager; bytes32 extra; }
    bytes4 private constant SEL_SWAP = 0x4d819a2a;         // swap(RouterHop[],address,uint256,uint256,uint256); the router pays msg.sender, a non-zero recipient reverts BAD_ARGS (verified)
    address private constant NATIVE = address(0);

    address public immutable ROUTER;
    address public immutable WETH;
    address public immutable POOL_MANAGER;
    address public immutable EXIT_KEY;                // the operator's cold key: unlock, exit and replaceGuardian, nothing else
    address private immutable F0; address private immutable F1; address private immutable F2; address private immutable F3;   // allowed v3 factories
    uint256 private immutable TICK_KEYED;             // bit i: factory i is keyed by tick spacing (getPool(a,b,int24)), else by fee (getPool(a,b,uint24))
    uint256 public constant MAX_FACTORIES = 4;
    uint256 public constant MAX_HOPS = 3;           // the engine's longest live route is 3 hops (WETH->USDG->X->token)
    uint256 public constant BUDGET_BPS = 3000;      // losses may reach 30% of the account's cost basis...
    uint256 public constant REFILL = 7 days;        // ...and that room comes back linearly over a week
    uint256 public constant PAUSE_MAX = 7 days;     // a pause lifts itself after this
    uint256 public constant PAUSE_COOLDOWN = 1 days; // and a new pause may start only this long after the last one ended
    uint256 public constant PENDING_TTL = 7 days;   // a proposed guardian must accept within this
    uint256 public constant MAX_UNLOCK = 64;        // accounts one unlock() may clear
    uint256 public constant MAX_LOT = 1e40;         // raw token units a lot may hold (keeps the arithmetic far from overflow)

    struct Basis { uint256 tokens; uint256 ethIn; }     // the lot: tokens held and their running cost
    mapping(address => mapping(address => Basis)) public basis;
    mapping(address => uint256) public costOf;        // the account's total cost basis across lots (the budget's base)
    struct Loss { uint256 amount; uint64 at; }         // losses outstanding as of `at`; the whole amount fades linearly over REFILL from then
    mapping(address => Loss) public loss;

    uint256 public immutable MAX_SELLS_PER_HOUR;
    uint256 public immutable MAX_BUY_ETH_PER_HOUR;
    uint256 public immutable MAX_SELL_ETH_PER_HOUR;
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

    constructor(address router, address weth, address poolManager, address[] memory v3Factories, bool[] memory tickKeyed, address guardian_, address exitKey, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour, uint256 maxSellEthPerHour) {
        require(router != address(0) && weth != address(0) && poolManager != address(0) && guardian_ != address(0) && exitKey != address(0), "zero address");
        require(router != address(this) && weth != address(this) && poolManager != address(this), "self");
        require(router != weth && router != poolManager && weth != poolManager, "distinct");
        require(router.code.length > 0 && weth.code.length > 0 && poolManager.code.length > 0, "not a contract");
        require(_readAddr(router, 0xad5c4648) == weth, "router WETH");                        // WETH(): the router's own wrapped ETH
        require(_readAddr(router, 0xe34e7283) == poolManager, "router PoolManager");          // V4_POOL_MANAGER(): the PoolManager the router actually calls
        require(v3Factories.length == tickKeyed.length && v3Factories.length <= MAX_FACTORIES, "factories");
        address[4] memory f; uint256 bits;
        for (uint256 i = 0; i < v3Factories.length; i++) {
            address fi = v3Factories[i];
            require(fi != address(0) && fi.code.length > 0 && fi != router && fi != weth && fi != poolManager && fi != address(this), "factory");
            for (uint256 j = 0; j < i; j++) require(f[j] != fi, "factory twice");
            f[i] = fi; if (tickKeyed[i]) bits |= 1 << i;
        }
        require(guardian_ != router && guardian_ != weth && guardian_ != poolManager && guardian_ != address(this), "guardian");
        require(exitKey != router && exitKey != weth && exitKey != poolManager && exitKey != guardian_ && exitKey != address(this), "exit key");
        require(exitKey.code.length == 0, "exit key must be an EOA");    // it submits transactions itself: tx.origin is how exit() recognises it
        require(maxSellsPerHour > 0 && maxBuyEthPerHour > 0 && maxSellEthPerHour > 0, "zero limit");
        require(maxSellsPerHour <= type(uint64).max && maxBuyEthPerHour <= type(uint128).max && maxSellEthPerHour <= type(uint128).max, "limit too large");
        ROUTER = router; WETH = weth; POOL_MANAGER = poolManager; guardian = guardian_; EXIT_KEY = exitKey;
        F0 = f[0]; F1 = f[1]; F2 = f[2]; F3 = f[3]; TICK_KEYED = bits;
        MAX_SELLS_PER_HOUR = maxSellsPerHour; MAX_BUY_ETH_PER_HOUR = maxBuyEthPerHour; MAX_SELL_ETH_PER_HOUR = maxSellEthPerHour;
    }
    function _readAddr(address target, bytes4 sel) private view returns (address a) {
        (bool ok, bytes memory r) = target.staticcall(abi.encodeWithSelector(sel));
        if (ok && r.length >= 32) a = abi.decode(r, (address));
    }
    /// @notice The allowed v3 factories and whether each is keyed by tick spacing.
    function factories() external view returns (address[4] memory f, uint256 tickKeyedBits) { return ([F0, F1, F2, F3], TICK_KEYED); }

    /// @dev ETH is accepted only while a trade is in progress (the proceeds of a sale, paid by the router). Outside a call it is refused.
    receive() external payable { if (_lock == 0) revert NoDirectEth(); }

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }

    // ---- guardian: pause the executor, rotate itself ----
    function paused() public view returns (bool) { return pausedAt != 0 && block.timestamp < pausedAt + PAUSE_MAX; }
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
    function _badGuardian(address next) private view returns (bool) {
        return next == address(0) || next == guardian || next == ROUTER || next == WETH || next == POOL_MANAGER || next == EXIT_KEY || next == address(this);
    }
    /// @notice The cold key may replace the guardian outright (v15, round 13 F-3). It cannot pause or trade.
    function replaceGuardian(address next) external lock {
        if (msg.sender != EXIT_KEY) revert NotExitKey();
        if (_badGuardian(next)) revert BadGuardian();
        emit GuardianChanged(guardian, next); guardian = next; pendingGuardian = address(0); pendingAt = 0;
    }
    function proposeGuardian(address next) external lock onlyGuardian {
        if (_badGuardian(next)) revert BadGuardian();
        pendingGuardian = next; pendingAt = block.timestamp; emit GuardianProposed(guardian, next);
    }
    function acceptGuardian() external lock {
        if (msg.sender != pendingGuardian || msg.sender == address(0)) revert NotPendingGuardian();
        if (block.timestamp > pendingAt + PENDING_TTL) revert NotPendingGuardian();
        emit GuardianChanged(guardian, msg.sender); guardian = msg.sender; pendingGuardian = address(0); pendingAt = 0;
    }

    // ---- exit key: unlock a budget ----
    function unlock(address[] calldata accounts) external lock {
        if (msg.sender != EXIT_KEY) revert NotExitKey();       // the key itself, directly (v15, round 13 F-1)
        if (accounts.length > MAX_UNLOCK) revert TooLarge();
        for (uint256 i = 0; i < accounts.length; i++) { uint256 l = loss[accounts[i]].amount; delete loss[accounts[i]]; emit Unlocked(accounts[i], l); }
    }

    // ---- windows, budget (identical to v15) ----
    function _window() private returns (Window storage w) {
        w = window[msg.sender];
        if (block.timestamp >= w.start + 1 hours) { w.start = uint64(block.timestamp); w.sells = 0; w.buyEth = 0; w.sellEth = 0; }
    }
    function _countBuy(uint256 spent) private { Window storage w = _window(); if (w.buyEth + spent > MAX_BUY_ETH_PER_HOUR) revert RateLimited(); w.buyEth += uint128(spent); }
    function _countSell(uint256 ethOut) private {
        Window storage w = _window();
        if (ethOut == 0) { if (w.sells + 1 > MAX_SELLS_PER_HOUR) revert RateLimited(); w.sells += 1; return; }
        if (ethOut > type(uint128).max) revert TooLarge();
        if (w.sellEth + ethOut > MAX_SELL_ETH_PER_HOUR) revert RateLimited(); w.sellEth += uint128(ethOut);
    }
    function _ceil(uint256 a, uint256 b) private pure returns (uint256) { return (a + b - 1) / b; }
    function _budget(address account) private view returns (uint256) { return costOf[account] * BUDGET_BPS / 10000; }
    function _decayed(address account) private view returns (uint256) {
        Loss storage l = loss[account];
        if (l.amount == 0) return 0;
        if (block.timestamp <= l.at) return l.amount;
        uint256 back = l.amount * (block.timestamp - l.at) / REFILL;
        return back >= l.amount ? 0 : l.amount - back;
    }
    function budgetOf(address account) external view returns (uint256 lost, uint256 budget) { return (_decayed(account), _budget(account)); }

    function _trim(address token) private returns (Basis storage b) {
        b = basis[msg.sender][token];
        if (b.tokens == 0) return b;
        (bool ok, uint256 bal) = _balanceOf(token, msg.sender);
        if (!ok) return b;
        if (bal == 0) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; return b; }
        if (bal < b.tokens) { uint256 keep = _ceil(b.ethIn * bal, b.tokens); costOf[msg.sender] -= b.ethIn - keep; b.ethIn = keep; b.tokens = bal; }
    }
    function _trimmed(address account, address token) private view returns (uint256 tokens, uint256 ethIn) {
        Basis storage b = basis[account][token];
        (tokens, ethIn) = (b.tokens, b.ethIn);
        if (tokens == 0) return (0, 0);
        (bool ok, uint256 bal) = _balanceOf(token, account);
        if (!ok) return (tokens, ethIn);
        if (bal == 0) return (0, 0);
        if (bal < tokens) { ethIn = _ceil(ethIn * bal, tokens); tokens = bal; }
    }

    // ---- route (RH) ----
    function _isEth(address a) private view returns (bool) { return a == NATIVE || a == WETH; }
    /// @dev The hops must run from the ETH side to `token` (buy) or from `token` to the ETH side (sale), contiguously, through
    ///      versions 1 and 2 only, with no intermediate ETH side or traded token, and every v3 pool must be the one an allowed
    ///      factory returns. Returns the router calldata, encoded here: recipient zero (the router pays msg.sender = this
    ///      contract), PoolManager pinned on v4 hops, no hook data, no extra word.
    function _route(Hop[] calldata hops, address token, bool isBuy, uint256 amountIn, uint256 minOut) private view returns (bytes memory) {
        uint256 n = hops.length;
        if (n == 0 || n > MAX_HOPS) revert BadRoute();
        if (isBuy ? !_isEth(hops[0].tokenIn) : hops[0].tokenIn != token) revert BadRoute();
        if (isBuy ? hops[n - 1].tokenOut != token : !_isEth(hops[n - 1].tokenOut)) revert BadRoute();
        RouterHop[] memory r = new RouterHop[](n);
        for (uint256 i = 0; i < n; i++) {
            Hop calldata h = hops[i];
            if (h.tokenIn == h.tokenOut) revert BadRoute();
            if (i > 0) {
                if (h.tokenIn != hops[i - 1].tokenOut) revert BadRoute();                     // contiguous
                if (_isEth(h.tokenIn) || h.tokenIn == token) revert BadRoute();               // no intermediate ETH side, no round through the traded token
            }
            if (h.version == 1) {
                if (h.hooks != address(0) || h.tokenIn == NATIVE || h.tokenOut == NATIVE) revert BadRoute();   // v3 pools hold WETH, never native
                if (!_isFactoryPool(h.pool, h.tokenIn, h.tokenOut, h.fee)) revert BadRoute();
            } else if (h.version == 2) {
                if (h.pool != address(0)) revert BadRoute();
            } else revert BadRoute();                                                        // 0, 3, 4 (Virtuals), ... dispatch to other code in the router
            r[i] = RouterHop(h.version, h.tokenIn, h.tokenOut, h.pool, h.fee, h.tickSpacing, h.hooks, "", h.version == 2 ? POOL_MANAGER : address(0), bytes32(0));
        }
        return abi.encodeWithSelector(SEL_SWAP, r, address(0), amountIn, minOut, block.timestamp);
    }
    /// @dev `pool` is the pool an allowed factory returns for (a, b, key). The factory is asked; the pool is never asked.
    function _isFactoryPool(address pool, address a, address b, uint24 key) private view returns (bool) {
        if (pool == address(0)) return false;
        address[4] memory f = [F0, F1, F2, F3];
        for (uint256 i = 0; i < MAX_FACTORIES; i++) {
            if (f[i] == address(0)) continue;
            bytes memory q;
            if (TICK_KEYED & (1 << i) != 0) { if (key > uint24(type(int24).max)) continue; q = abi.encodeWithSelector(0x28af8d0b, a, b, int24(key)); }   // getPool(address,address,int24)
            else q = abi.encodeWithSelector(0x1698ee82, a, b, key);                                                                                    // getPool(address,address,uint24)
            (bool ok, bytes memory ret) = f[i].staticcall(q);
            if (ok && ret.length >= 32 && abi.decode(ret, (address)) == pool) return true;
        }
        return false;
    }

    /// @notice Spend msg.value of ETH on `token` along `hops`. Output goes to msg.sender.
    function buy(address token, uint256 minOut, Hop[] calldata hops) external payable lock returns (uint256 out) {
        if (paused()) revert IsPaused();
        if (msg.value == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        if (token == WETH) revert BadRoute();
        _trim(token);
        if (msg.value > MAX_BUY_ETH_PER_HOUR) revert RateLimited();
        uint256 ethBase = address(this).balance - msg.value;
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        (bool okB, uint256 before) = _balanceOf(token, msg.sender);
        if (!okB) revert BelowMinOut(0, minOut);
        _callRouter(_route(hops, token, true, msg.value, minOut), msg.value);   // the route is checked and encoded here, never taken from the caller
        _sweepToken(token, tokBase);                                // the router pays this contract (recipient must be zero); forwarded to the caller
        (bool okA, uint256 after_) = _balanceOf(token, msg.sender);
        out = okA && after_ > before ? after_ - before : 0;
        if (out < minOut) revert BelowMinOut(out, minOut);
        uint256 change = address(this).balance - ethBase;           // the live router spends all of msg.value (verified); kept as in v15
        if (change > msg.value) revert RouterOverpaid();
        uint256 spent = msg.value - change;
        if (spent == 0) revert ZeroAmount();
        _countBuy(spent);
        Basis storage b = basis[msg.sender][token];
        b.ethIn += spent; b.tokens += out; costOf[msg.sender] += spent;
        if (b.tokens > MAX_LOT) revert TooLarge();
        emit Bought(msg.sender, token, spent, out);
        if (change > 0) _sendEth(msg.sender, change);
    }

    /// @notice Sell `amount` of `token` (at most the lot) for ETH along `hops`, within the loss budget.
    function sell(address token, uint256 amount, uint256 minOut, Hop[] calldata hops) external lock returns (uint256 out) {
        if (paused()) revert IsPaused();
        return _sale(token, amount, minOut, hops, false);
    }
    /// @notice The cold key's exit: the same sale, outside the loss budget and the hourly limits, paid to the account.
    ///         Reached through the account's delegation to the exit key: the account is msg.sender, the key is tx.origin.
    function exit(address token, uint256 amount, uint256 minOut, Hop[] calldata hops) external lock returns (uint256 out) {
        if (tx.origin != EXIT_KEY) revert NotExitKey();
        return _sale(token, amount, minOut, hops, true);
    }

    function _sale(address token, uint256 amount, uint256 minOut, Hop[] calldata hops, bool isExit) private returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        if (token == WETH) revert BadRoute();
        { uint256 lot = _trim(token).tokens; if (amount > lot) revert NotInLot(lot, amount); }
        if (!isExit) _countSell(0);
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        uint256 got = _pull(token, msg.sender, amount);
        out = _swapForEth(token, got, minOut, hops);
        uint256 back = _sweepToken(token, tokBase);
        if (out < minOut) revert BelowMinOut(out, minOut);
        if (!isExit) _countSell(out);
        if (back >= amount) revert ZeroAmount();
        _settle(token, amount - back, out, isExit);
        if (out > 0) _sendEth(msg.sender, out);
    }

    /// @dev Approve exactly `got`, run the route the gate encoded, reset the allowance; returns the native ETH this call added here.
    function _swapForEth(address token, uint256 got, uint256 minOut, Hop[] calldata hops) private returns (uint256) {
        bytes memory data = _route(hops, token, false, got, minOut);
        _approveForRouter(token, got);
        uint256 ethBase = address(this).balance;
        uint256 wethBase = IERC20(WETH).balanceOf(address(this));
        _callRouter(data, 0);
        _approveSoft(token, ROUTER, 0);                             // cleanup only; a token that rejects approve(0) must not undo the sale
        if (IERC20(WETH).balanceOf(address(this)) != wethBase) revert BadRoute();   // the router pays sales in native ETH (verified); WETH arriving here would be stranded
        return address(this).balance - ethBase;
    }

    function _settle(address token, uint256 sold, uint256 out, bool isExit) private {
        Basis storage b = basis[msg.sender][token];
        if (sold > b.tokens) revert NotInLot(b.tokens, sold);
        uint256 cost = b.ethIn * sold / b.tokens;
        uint256 added;
        if (!isExit && out < cost) {
            added = cost - out;
            uint256 carried = _decayed(msg.sender); uint256 total = carried + added; uint256 budget = _budget(msg.sender);
            if (total > budget) revert BudgetExceeded(total, budget);
            loss[msg.sender] = Loss(total, uint64(block.timestamp));
        }
        b.ethIn -= cost; b.tokens -= sold; costOf[msg.sender] -= cost;
        (bool okb, uint256 left) = _balanceOf(token, msg.sender);
        if (b.tokens == 0 || (okb && left == 0)) { costOf[msg.sender] -= b.ethIn; delete basis[msg.sender][token]; }
        emit Sold(msg.sender, token, sold, out, added, isExit);
    }

    function lotOf(address account, address token) external view returns (uint256 tokens, uint256 ethIn) { return _trimmed(account, token); }
    function floorFor(address account, address token, uint256 amount) external view returns (uint256) {
        (uint256 tokens, uint256 ethIn) = _trimmed(account, token);
        if (tokens == 0 || amount > tokens) return 0;
        uint256 cost = ethIn * amount / tokens; uint256 room = _budget(account); uint256 lost = _decayed(account);
        room = room > lost ? room - lost : 0;
        return cost > room ? cost - room : 0;
    }

    function _callRouter(bytes memory data, uint256 value) private {
        (bool ok, bytes memory err) = ROUTER.call{value: value}(data);
        if (!ok) revert RouterFailed(err);
    }
    function _sweepToken(address token, uint256 base) private returns (uint256 delivered) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 held = bal > base ? bal - base : 0;
        if (held == 0) return 0;
        (bool ok, uint256 before) = _balanceOf(token, msg.sender);
        _send(token, msg.sender, held);
        if (!ok) return held;
        (bool ok2, uint256 after_) = _balanceOf(token, msg.sender);
        delivered = ok2 && after_ >= before ? after_ - before : held;
    }
    function _balanceOf(address token, address who) private view returns (bool ok, uint256 bal) {
        (bool s_, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (!s_ || r.length < 32) return (false, 0);
        return (true, abi.decode(r, (uint256)));
    }

    // ---- token helpers (identical to v15) ----
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
