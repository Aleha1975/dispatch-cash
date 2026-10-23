// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardedSwapRH (v5: direct pool swaps, no router)
/// @notice A one-purpose gate between a client's smart account and the pools of Robinhood Chain (chain id 4663). The
///         account grants its executor the right to call THIS contract; the gate swaps against the pools itself -- a
///         Uniswap-v3-style pool through pool.swap and its callback, a Uniswap v4 pool through the PoolManager's
///         unlock/swap/settle/take -- and whatever a swap returns goes to the calling account and nobody else. There is no
///         router, no aggregator and no calldata from the caller: the executor names structured hops, the gate checks them
///         and makes every call itself. No owner, no upgrade, no funds kept between calls, no allowance ever granted.
///         Anyone may call it; it can only ever pay the caller.
///
///         v5 versus v4 (which called the Robinhood "SwapX" router 0x65050a9b…, an upgradeable proxy charging 1% per swap):
///         the router and its fee are gone; the pools are called directly; the loss budget is measured against the
///         account (its native ETH plus its open lots at cost), as GuardedSwap v16 on Base. Everything else is v4.
///
///         Guards on top of the recipient rule, because an executor key that is stolen could still trade badly:
///         1. Loss budget. Every buy is recorded in the account's lot for that token at cost. A sale that returns less
///            than the cost of the tokens it gives up is a LOSS; losses accumulate per account and must stay within
///            BUDGET_BPS of the account's value at cost -- the native ETH it holds plus the cost of its open lots, read
///            once when the sale starts (v5, as Base v16: the base was the open lots alone, so an account holding mostly
///            ETH and one small position could not sell that position after an ordinary crash). What is outstanding fades
///            linearly over REFILL from the last booking -- nothing but time (or the cold key's unlock) moves it. Sales at
///            or above cost never touch the budget. A thief dumping everything at once books at most
///            BUDGET_BPS / (1 + BUDGET_BPS) of the base, because every loss also shrinks the base it is measured against.
///         2. Only the lot is for sale. sell() handles at most the tokens this contract saw bought for the account; the lot
///            shrinks by what the account gave up, never exceeds what the account holds and closes when the account holds none.
///         3. Rate limit. Per account and fixed hour window: at most MAX_SELLS_PER_HOUR sales, MAX_BUYS_PER_HOUR buys,
///            MAX_BUY_ETH_PER_HOUR of ETH spent on buys and MAX_SELL_ETH_PER_HOUR of ETH taken out of sales. Any 60 minutes
///            can see at most twice each cap. The delegation's 24-hour cap bounds the total.
///         4. Two keys kept off the executor's machine. The GUARDIAN can pause the executor -- buys and sells -- for at most
///            PAUSE_MAX, then PAUSE_COOLDOWN before the next; it cannot move funds and never blocks exit(). The EXIT key --
///            the operator's cold key -- can unlock() an account's loss budget, replaceGuardian(), and run exit(): a sale
///            paid to the account, outside the loss budget and the hourly limits, not blocked by a pause.
///            Every trade carries a deadline: past it the call reverts before anything moves.
///         5. Only this call's funds. Balances are measured as deltas around every pool call. A sale is paid to this
///            contract and forwarded after settlement, so state is written before any ETH leaves. Every hop must consume
///            exactly what it was given (PartialFill otherwise), so nothing of the input stays here; no WETH may remain.
///         6. Route rule. 1..MAX_HOPS hops, each version 1 (v3-style pool) or 2 (Uniswap v4 PoolKey); a buy starts at the
///            ETH side (native or WETH) and ends at `token`, a sale the reverse; every hop starts where the previous one
///            ended; no intermediate token is the ETH side or the traded token. A v3 hop's pool must be the pool an allowed
///            factory returns for (tokenIn, tokenOut, key) -- the gate asks the factory, never the pool -- and only that pool
///            can be paid in the swap callback, only once, only the input token, at most the hop's input. A v4 hop names no
///            pool: its PoolKey goes to the pinned PoolManager, which resolves it (an unknown key reverts there); its hook
///            must be zero, or have no swap-time return-delta permission (it cannot take part of a swap), or be one of at
///            most MAX_HOOKS hooks fixed at deployment. The PoolManager's answer must be exactly "the input in full, a
///            positive output", else the hop reverts.
///         7. Residual, by design: v3 pools and v4 pools are permissionless -- anyone can open a genuine pool at any price.
///            Such a pool is a sink that cannot be told apart on-chain from a thin market; what it can take is bounded by
///            minOut, measured here, and by the loss budget. A hook that is allowed can still set a dynamic fee; that is
///            price, bounded the same way. The budget is relative to what was paid, not to the market.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GuardedSwapRH {
    /// @notice One hop as the executor names it. version 1 = v3-style pool (pool set; tickSpacing and hooks unused, hooks
    ///         must be zero); `fee` is the key the factory is asked with: the fee tier on fee-keyed factories, the tick
    ///         spacing on tick-keyed (Slipstream-style) ones. version 2 = Uniswap v4 (pool zero; fee, tickSpacing and hooks
    ///         are the PoolKey; the ETH side may be native, address(0)).
    struct Hop { uint8 version; address tokenIn; address tokenOut; address pool; uint24 fee; int24 tickSpacing; address hooks; }
    /// @dev Uniswap v4 types, as the PoolManager takes them.
    struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    address private constant NATIVE = address(0);
    uint160 private constant MIN_SQRT = 4295128739 + 1;                                                   // TickMath MIN_SQRT_RATIO + 1 (v3 and v4)
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;            // TickMath MAX_SQRT_RATIO - 1
    uint160 private constant RETURNS_DELTA_SWAP = (1 << 3) | (1 << 2);   // v4 hook permission bits BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
    // transient slots (EIP-1153): what the one callback in flight may do
    uint256 private constant T_POOL = uint256(keccak256("GuardedSwapRH.v5.pool"));   // the v3 pool whose callback is expected (zero: none)
    uint256 private constant T_TIN = uint256(keccak256("GuardedSwapRH.v5.tin"));     // the token it may be paid in
    uint256 private constant T_MAX = uint256(keccak256("GuardedSwapRH.v5.max"));     // at most this much
    uint256 private constant T_V4 = uint256(keccak256("GuardedSwapRH.v5.v4"));       // 1 while this contract's own unlock is in flight

    address public immutable WETH;
    address public immutable POOL_MANAGER;
    address public immutable EXIT_KEY;                // the operator's cold key: unlock, exit and replaceGuardian, nothing else
    address private immutable F0; address private immutable F1; address private immutable F2; address private immutable F3;   // allowed v3 factories
    uint256 private immutable TICK_KEYED;             // bit i: factory i is keyed by tick spacing (getPool(a,b,int24)), else by fee (getPool(a,b,uint24))
    address private immutable H0; address private immutable H1; address private immutable H2; address private immutable H3;   // v4 hooks allowed although they may return deltas
    uint256 public constant MAX_FACTORIES = 4;
    uint256 public constant MAX_HOOKS = 4;
    uint256 public constant MAX_HOPS = 3;           // the longest route in use: WETH -> USDG -> X -> token
    uint256 public constant BUDGET_BPS = 3000;      // losses may reach 30% of the account's value at cost (ETH + open lots)...
    uint256 public constant REFILL = 7 days;        // ...and that room comes back linearly over a week
    uint256 public constant PAUSE_MAX = 7 days;     // a pause lifts itself after this
    uint256 public constant PAUSE_COOLDOWN = 1 days; // and a new pause may start only this long after the last one ended
    uint256 public constant PENDING_TTL = 7 days;   // a proposed guardian must accept within this
    uint256 public constant MAX_UNLOCK = 64;        // accounts one unlock() may clear
    uint256 public constant MAX_LOT = 1e40;         // raw token units a lot may hold (keeps the arithmetic far from overflow)

    struct Basis { uint256 tokens; uint256 ethIn; }     // the lot: tokens held and their running cost
    mapping(address => mapping(address => Basis)) public basis;
    mapping(address => uint256) public costOf;        // the account's total cost basis across lots (with its ETH: the budget's base)
    struct Loss { uint256 amount; uint64 at; }         // losses outstanding as of `at`; the whole amount fades linearly over REFILL from then
    mapping(address => Loss) public loss;

    uint256 public immutable MAX_SELLS_PER_HOUR;
    uint256 public immutable MAX_BUYS_PER_HOUR;
    uint256 public immutable MAX_BUY_ETH_PER_HOUR;
    uint256 public immutable MAX_SELL_ETH_PER_HOUR;
    struct Window { uint64 start; uint64 sells; uint64 buys; uint128 buyEth; uint128 sellEth; }      // per account, resets when the hour is over
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
    error SwapFailed();
    error Overpaid();
    error TransferFailed();
    error EthSendFailed();
    error IsPaused();
    error PauseCooldown();
    error NotGuardian();
    error NotExitKey();
    error BadGuardian();
    error RateLimited();
    error BadRoute();
    error BadHook();
    error BadCallback();
    error NotAContract();
    error TooLarge();
    error NotPendingGuardian();
    error NoDirectEth();
    error PartialFill();
    error Expired();

    constructor(address weth, address poolManager, address[] memory v3Factories, bool[] memory tickKeyed, address[] memory hooks, address guardian_, address exitKey, uint256 maxSellsPerHour, uint256 maxBuysPerHour, uint256 maxBuyEthPerHour, uint256 maxSellEthPerHour) {
        require(weth != address(0) && poolManager != address(0) && guardian_ != address(0) && exitKey != address(0), "zero address");
        require(weth != address(this) && poolManager != address(this) && weth != poolManager, "distinct");
        require(weth.code.length > 0 && poolManager.code.length > 0, "not a contract");
        require(v3Factories.length == tickKeyed.length && v3Factories.length <= MAX_FACTORIES, "factories");
        address[4] memory f; uint256 bits;
        for (uint256 i = 0; i < v3Factories.length; i++) {
            address fi = v3Factories[i];
            require(fi != address(0) && fi.code.length > 0 && fi != weth && fi != poolManager && fi != address(this), "factory");
            for (uint256 j = 0; j < i; j++) require(f[j] != fi, "factory twice");
            f[i] = fi; if (tickKeyed[i]) bits |= 1 << i;
        }
        require(hooks.length <= MAX_HOOKS, "hooks");
        address[4] memory h;
        for (uint256 i = 0; i < hooks.length; i++) {
            address hi = hooks[i];
            require(hi != address(0) && hi.code.length > 0 && hi != weth && hi != poolManager && hi != address(this), "hook");
            for (uint256 j = 0; j < i; j++) require(h[j] != hi, "hook twice");
            h[i] = hi;
        }
        require(guardian_ != weth && guardian_ != poolManager && guardian_ != address(this), "guardian");
        require(exitKey != weth && exitKey != poolManager && exitKey != guardian_ && exitKey != address(this), "exit key");
        require(exitKey.code.length == 0, "exit key must be an EOA");    // it submits transactions itself: tx.origin is how exit() recognises it
        require(maxSellsPerHour > 0 && maxBuysPerHour > 0 && maxBuyEthPerHour > 0 && maxSellEthPerHour > 0, "zero limit");
        require(maxSellsPerHour < type(uint64).max && maxBuysPerHour < type(uint64).max && maxBuyEthPerHour <= type(uint128).max && maxSellEthPerHour <= type(uint128).max, "limit too large");
        WETH = weth; POOL_MANAGER = poolManager; guardian = guardian_; EXIT_KEY = exitKey;
        F0 = f[0]; F1 = f[1]; F2 = f[2]; F3 = f[3]; TICK_KEYED = bits;
        H0 = h[0]; H1 = h[1]; H2 = h[2]; H3 = h[3];
        MAX_SELLS_PER_HOUR = maxSellsPerHour; MAX_BUYS_PER_HOUR = maxBuysPerHour; MAX_BUY_ETH_PER_HOUR = maxBuyEthPerHour; MAX_SELL_ETH_PER_HOUR = maxSellEthPerHour;
    }
    /// @notice The allowed v3 factories and whether each is keyed by tick spacing.
    function factories() external view returns (address[4] memory f, uint256 tickKeyedBits) { return ([F0, F1, F2, F3], TICK_KEYED); }
    /// @notice The v4 hooks allowed although their permissions let them return swap deltas.
    function allowedHooks() external view returns (address[4] memory) { return [H0, H1, H2, H3]; }

    /// @dev ETH is accepted only while a trade is in progress (WETH unwrapping, the PoolManager paying native ETH). Outside a call it is refused.
    receive() external payable { if (_lock == 0) revert NoDirectEth(); }

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }

    // ---- guardian: pause the executor, rotate itself (as v4) ----
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
        return next == address(0) || next == guardian || next == WETH || next == POOL_MANAGER || next == EXIT_KEY || next == address(this);
    }
    /// @notice The cold key may replace the guardian outright. It cannot pause or trade.
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
        if (msg.sender != EXIT_KEY) revert NotExitKey();       // the key itself, directly
        if (accounts.length > MAX_UNLOCK) revert TooLarge();
        for (uint256 i = 0; i < accounts.length; i++) { uint256 l = loss[accounts[i]].amount; delete loss[accounts[i]]; emit Unlocked(accounts[i], l); }
    }

    // ---- windows, budget ----
    function _window() private returns (Window storage w) {
        w = window[msg.sender];
        if (block.timestamp >= w.start + 1 hours) { w.start = uint64(block.timestamp); w.sells = 0; w.buys = 0; w.buyEth = 0; w.sellEth = 0; }
    }
    function _countBuy(uint256 spent) private {
        Window storage w = _window();
        if (w.buys + 1 > MAX_BUYS_PER_HOUR || w.buyEth + spent > MAX_BUY_ETH_PER_HOUR) revert RateLimited();
        w.buys += 1; w.buyEth += uint128(spent);
    }
    function _countSell(uint256 ethOut) private {
        Window storage w = _window();
        if (ethOut == 0) { if (w.sells + 1 > MAX_SELLS_PER_HOUR) revert RateLimited(); w.sells += 1; return; }
        if (ethOut > type(uint128).max) revert TooLarge();
        if (w.sellEth + ethOut > MAX_SELL_ETH_PER_HOUR) revert RateLimited(); w.sellEth += uint128(ethOut);
    }
    function _ceil(uint256 a, uint256 b) private pure returns (uint256) { return (a + b - 1) / b; }
    /// @dev The budget's base, the one definition every reader uses (as Base v16): the account's native ETH plus the cost of
    ///      its open lots. A buy moves ETH into a lot at cost and a sale at cost moves it back, so the gate's own trades leave
    ///      the base where it was; a loss lowers it by the loss, a profit raises it by the profit, a deposit or a withdrawal
    ///      (the owner's alone) by its amount.
    function _base(address account) private view returns (uint256) { return costOf[account] + account.balance; }
    function _budget(address account) private view returns (uint256) { return _base(account) * BUDGET_BPS / 10000; }
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

    // ---- route ----
    function _isEth(address a) private view returns (bool) { return a == NATIVE || a == WETH; }
    /// @dev The hops must run from the ETH side to `token` (buy) or from `token` to the ETH side (sale), contiguously,
    ///      through versions 1 and 2 only, with no intermediate ETH side or traded token; every v3 pool must be the one an
    ///      allowed factory returns, every v4 hook must pass _hookOk. Checked in full before anything moves.
    function _check(Hop[] calldata hops, address token, bool isBuy) private view {
        uint256 n = hops.length;
        if (n == 0 || n > MAX_HOPS) revert BadRoute();
        if (isBuy ? !_isEth(hops[0].tokenIn) : hops[0].tokenIn != token) revert BadRoute();
        if (isBuy ? hops[n - 1].tokenOut != token : !_isEth(hops[n - 1].tokenOut)) revert BadRoute();
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
                if (!_hookOk(h.hooks)) revert BadHook();
            } else revert BadRoute();
        }
    }
    /// @dev A v4 hook is acceptable when it is zero, when its address grants no swap-time return-delta permission (the
    ///      PoolManager then never lets it take part of a swap's input or output), or when it was fixed at deployment.
    function _hookOk(address h) private view returns (bool) {
        if (h == address(0) || uint160(h) & RETURNS_DELTA_SWAP == 0) return true;
        return h == H0 || h == H1 || h == H2 || h == H3;
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
            if (_askFactory(f[i], q) == uint256(uint160(pool))) return true;   // a dirty word is a mismatch, never a revert
        }
        return false;
    }
    /// @dev The factory's first answer word, copying at most 32 bytes of return data; 0 when it fails or is short.
    function _askFactory(address f, bytes memory q) private view returns (uint256 word) {
        assembly {
            let ok := staticcall(gas(), f, add(q, 32), mload(q), 0, 0)
            if and(ok, iszero(lt(returndatasize(), 32))) { let m := mload(0x40) returndatacopy(m, 0, 32) word := mload(m) }
        }
    }

    // ---- trades ----
    /// @notice Spend msg.value of ETH on `token` along `hops`, not after `deadline`. Output goes to msg.sender.
    function buy(address token, uint256 minOut, uint256 deadline, Hop[] calldata hops) external payable lock returns (uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        if (paused()) revert IsPaused();
        if (msg.value == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        if (token == WETH) revert BadRoute();
        _check(hops, token, true);
        _trim(token);
        if (msg.value > MAX_BUY_ETH_PER_HOUR) revert RateLimited();
        uint256 ethBase = address(this).balance - msg.value;
        out = _swapForToken(token, minOut, hops);
        if (out < minOut) revert BelowMinOut(out, minOut);
        uint256 change = address(this).balance - ethBase;           // every hop spends its input in full, so 0 unless someone sent ETH
        if (change > msg.value) revert Overpaid();
        uint256 spent = msg.value - change;
        if (spent == 0) revert ZeroAmount();
        _countBuy(spent);
        Basis storage b = basis[msg.sender][token];
        b.ethIn += spent; b.tokens += out; costOf[msg.sender] += spent;
        if (b.tokens > MAX_LOT) revert TooLarge();
        emit Bought(msg.sender, token, spent, out);
        if (change > 0) _sendEth(msg.sender, change);
    }

    /// @dev Run the hops with msg.value and forward what arrived; returns what the account received, measured on the account.
    function _swapForToken(address token, uint256 minOut, Hop[] calldata hops) private returns (uint256) {
        uint256 wethBase = IERC20(WETH).balanceOf(address(this));
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        (bool okB, uint256 before) = _balanceOf(token, msg.sender);
        if (!okB) revert BelowMinOut(0, minOut);
        if (hops[0].tokenIn == WETH) _wrap(msg.value);
        _run(hops, msg.value);
        if (IERC20(WETH).balanceOf(address(this)) != wethBase) revert BadRoute();
        _sweepToken(token, tokBase);                                // paid to this contract by the last pool; forwarded to the caller
        (bool okA, uint256 after_) = _balanceOf(token, msg.sender);
        return okA && after_ > before ? after_ - before : 0;
    }

    /// @notice Sell `amount` of `token` (at most the lot) for ETH along `hops`, within the loss budget.
    function sell(address token, uint256 amount, uint256 minOut, uint256 deadline, Hop[] calldata hops) external lock returns (uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        if (paused()) revert IsPaused();
        return _sale(token, amount, minOut, hops, false);
    }
    /// @notice The cold key's exit: the same sale, outside the loss budget and the hourly limits, paid to the account.
    ///         Reached through the account's delegation to the exit key: the account is msg.sender, the key is tx.origin.
    ///         msg.sender binds the lot, the payee and every write to the calling account (exit takes no account argument),
    ///         tx.origin proves the cold key started the transaction. The cold key submits its own transactions.
    function exit(address token, uint256 amount, uint256 minOut, uint256 deadline, Hop[] calldata hops) external lock returns (uint256 out) {
        if (tx.origin != EXIT_KEY) revert NotExitKey();
        if (block.timestamp > deadline) revert Expired();
        return _sale(token, amount, minOut, hops, true);
    }

    function _sale(address token, uint256 amount, uint256 minOut, Hop[] calldata hops, bool isExit) private returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        if (token == WETH) revert BadRoute();
        _check(hops, token, false);
        { uint256 lot = _trim(token).tokens; if (amount > lot) revert NotInLot(lot, amount); }
        uint256 budget = isExit ? 0 : _budget(msg.sender);          // measured once, on the reconciled lot, before anything moves
        if (!isExit) _countSell(0);
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        uint256 wethBase = IERC20(WETH).balanceOf(address(this));
        uint256 ethBase = address(this).balance;
        uint256 got = _pull(token, msg.sender, amount);
        uint256 last = _run(hops, got);
        if (hops[hops.length - 1].tokenOut == WETH) _unwrap(last);
        if (IERC20(token).balanceOf(address(this)) != tokBase) revert PartialFill();   // all of `got` was swapped
        if (IERC20(WETH).balanceOf(address(this)) != wethBase) revert BadRoute();
        out = address(this).balance - ethBase;
        if (out < minOut) revert BelowMinOut(out, minOut);
        if (!isExit) _countSell(out);
        _settle(token, amount, out, isExit, budget);                // the lot shrinks by what left the account
        if (out > 0) _sendEth(msg.sender, out);                     // state is final before any ETH leaves
    }

    function _settle(address token, uint256 sold, uint256 out, bool isExit, uint256 budget) private {
        Basis storage b = basis[msg.sender][token];
        if (sold > b.tokens) revert NotInLot(b.tokens, sold);
        uint256 cost = b.ethIn * sold / b.tokens;                    // released from the lot rounded down: the remainder's cost never zeroes
        uint256 charged = _ceil(b.ethIn * sold, b.tokens);            // measured against the budget rounded up: a loss is never under-booked
        uint256 added;
        if (!isExit && out < charged) {
            added = charged - out;
            uint256 total = _decayed(msg.sender) + added;            // against the budget measured when the sale started
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
        uint256 cost = _ceil(ethIn * amount, tokens); uint256 room = _budget(account); uint256 lost = _decayed(account);
        room = room > lost ? room - lost : 0;
        return cost > room ? cost - room : 0;
    }

    // ---- swaps ----
    /// @dev Run the checked hops; each hop must consume exactly its input; returns what the last hop delivered here.
    function _run(Hop[] calldata hops, uint256 amountIn) private returns (uint256 amt) {
        amt = amountIn;
        for (uint256 i = 0; i < hops.length; i++) {
            Hop calldata h = hops[i];
            uint256 inBase = _held(h.tokenIn); uint256 outBase = _held(h.tokenOut);
            if (h.version == 1) _v3(h, amt); else _v4(h, amt);
            uint256 inNow = _held(h.tokenIn); uint256 outNow = _held(h.tokenOut);
            if (inNow > inBase || inBase - inNow != amt) revert PartialFill();
            if (outNow <= outBase) revert ZeroAmount();
            amt = outNow - outBase;
        }
    }
    function _held(address t) private view returns (uint256) { return t == NATIVE ? address(this).balance : IERC20(t).balanceOf(address(this)); }

    /// @dev One v3 hop: exact input, any price, paid to this contract. The pool may call back once, for at most `amt` of tokenIn.
    function _v3(Hop calldata h, uint256 amt) private {
        if (amt > uint256(type(int256).max)) revert TooLarge();
        bool zf1 = h.tokenIn < h.tokenOut;
        _tset(T_POOL, uint256(uint160(h.pool))); _tset(T_TIN, uint256(uint160(h.tokenIn))); _tset(T_MAX, amt);
        _call(h.pool, 0, abi.encodeWithSelector(0x128acb08, address(this), zf1, int256(amt), zf1 ? MIN_SQRT : MAX_SQRT, bytes("")));   // swap(address,bool,int256,uint160,bytes)
        if (_tget(T_POOL) != 0) revert BadCallback();               // the pool did not call back: nothing was paid
        _tset(T_TIN, 0); _tset(T_MAX, 0);
    }
    /// @notice The v3 swap callback. Only the pool this contract is swapping with right now may call it, once; it is paid
    ///         the input token, at most the hop's input, and nothing else.
    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        uint256 p = _tget(T_POOL);
        if (p == 0 || msg.sender != address(uint160(p))) revert BadCallback();
        _tset(T_POOL, 0);
        if (d0 > 0 && d1 > 0) revert BadCallback();
        uint256 owed = d0 > 0 ? uint256(d0) : d1 > 0 ? uint256(d1) : 0;
        if (owed == 0 || owed > _tget(T_MAX)) revert BadCallback();
        _send(address(uint160(_tget(T_TIN))), msg.sender, owed);
    }

    /// @dev One v4 hop through this contract's own unlock of the pinned PoolManager.
    function _v4(Hop calldata h, uint256 amt) private {
        if (amt > uint256(uint128(type(int128).max))) revert TooLarge();
        _tset(T_V4, 1);
        _call(POOL_MANAGER, 0, abi.encodeWithSelector(0x48c89491, abi.encode(h.tokenIn, h.tokenOut, h.fee, h.tickSpacing, h.hooks, amt)));   // unlock(bytes)
        if (_tget(T_V4) != 0) revert BadCallback();                 // the PoolManager did not call back
    }
    /// @notice The v4 unlock callback. Only the pinned PoolManager, only during this contract's own unlock: one exact-input
    ///         swap whose result must be "all of the input owed, a positive output", then settle the input and take the output.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _tget(T_V4) != 1) revert BadCallback();
        _tset(T_V4, 0);
        (address tin, address tout, uint256 amt, uint256 got) = _v4swap(data);
        if (tin == NATIVE) _call(POOL_MANAGER, amt, abi.encodeWithSelector(0x11da60b4));                         // settle()
        else { _call(POOL_MANAGER, 0, abi.encodeWithSelector(0xa5841194, tin)); _send(tin, POOL_MANAGER, amt); _call(POOL_MANAGER, 0, abi.encodeWithSelector(0x11da60b4)); }   // sync, pay, settle
        _call(POOL_MANAGER, 0, abi.encodeWithSelector(0x0b0d9c09, tout, address(this), got));                       // take(currency,to,amount)
        return "";
    }

    /// @dev The swap inside the unlock: exact input `amt`, any price, no hook data. Returns the output owed to this contract.
    function _v4swap(bytes calldata data) private returns (address tin, address tout, uint256 amt, uint256 got) {
        uint24 fee; int24 ts; address hooks;
        (tin, tout, fee, ts, hooks, amt) = abi.decode(data, (address, address, uint24, int24, address, uint256));
        bool zf1 = tin < tout;
        PoolKey memory key = zf1 ? PoolKey(tin, tout, fee, ts, hooks) : PoolKey(tout, tin, fee, ts, hooks);
        bytes memory q = abi.encodeWithSelector(0xf3cd914c, key, SwapParams(zf1, -int256(amt), zf1 ? MIN_SQRT : MAX_SQRT), bytes(""));   // swap(PoolKey,SwapParams,bytes)
        int256 d = abi.decode(_call(POOL_MANAGER, 0, q), (int256));
        (int128 dIn, int128 dOut) = zf1 ? (int128(d >> 128), int128(d)) : (int128(d), int128(d >> 128));
        if (int256(dIn) != -int256(amt)) revert PartialFill();        // all of the input owed, nothing more, nothing less
        if (dOut <= 0) revert ZeroAmount();                          // and something positive to take
        got = uint256(uint256(int256(dOut)));
    }

    /// @dev A call that copies at most 64 bytes of a success and passes a revert on as it came, cut to 256 bytes (so the
    ///      gate's own errors raised inside a callback reach the caller unchanged); a revert without data is SwapFailed.
    function _call(address target, uint256 value, bytes memory data) private returns (bytes memory ret) {
        bool ok;
        assembly {
            ok := call(gas(), target, value, add(data, 32), mload(data), 0, 0)
            let n := returndatasize()
            if iszero(ok) { if gt(n, 0) { if gt(n, 256) { n := 256 } let m := mload(0x40) returndatacopy(m, 0, n) revert(m, n) } }
            if gt(n, 64) { n := 64 }
            ret := mload(0x40) mstore(ret, n) returndatacopy(add(ret, 32), 0, n)
            mstore(0x40, add(add(ret, 32), and(add(n, 31), not(31))))
        }
        if (!ok) revert SwapFailed();
    }
    function _tset(uint256 slot, uint256 v) private { assembly { tstore(slot, v) } }
    function _tget(uint256 slot) private view returns (uint256 v) { assembly { v := tload(slot) } }
    function _wrap(uint256 amt) private { _call(WETH, amt, abi.encodeWithSelector(0xd0e30db0)); }                 // deposit()
    function _unwrap(uint256 amt) private { _call(WETH, 0, abi.encodeWithSelector(0x2e1a7d4d, amt)); }           // withdraw(uint256)

    function _sweepToken(address token, uint256 base) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > base) _send(token, msg.sender, bal - base);
    }
    function _balanceOf(address token, address who) private view returns (bool ok, uint256 bal) {
        (bool s_, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (!s_ || r.length < 32) return (false, 0);
        return (true, abi.decode(r, (uint256)));
    }

    // ---- token helpers ----
    function _pull(address token, address from, uint256 amount) private returns (uint256 got) {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
        if (!ok || (r.length != 0 && (r.length < 32 || !abi.decode(r, (bool))))) revert TransferFailed();
        got = IERC20(token).balanceOf(address(this)) - before;
        if (got == 0) revert ZeroAmount();
    }
    function _send(address token, address to, uint256 amount) private {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (r.length != 0 && (r.length < 32 || !abi.decode(r, (bool))))) revert TransferFailed();
    }
    function _sendEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }
}
