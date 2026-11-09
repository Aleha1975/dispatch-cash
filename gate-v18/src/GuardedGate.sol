// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardedGate (v18)
/// @notice Successor of GuardedSwap v17.2 for the Elysium copy-trading product. NO CUSTODY: bought tokens stay in the client's own
///         smart account, exactly as in v17.2; a sale pulls them from the account with transferFrom (the client's second delegation
///         is the `approve` permission pinned to this gate, as today). Native HYPE never stays here.
///
///         The gate delegation targets this contract only, methods buy / sell / payFee / refundGas / withdraw, and carries NO value
///         limit: every outflow of native HYPE is pinned in code here -- buy -> ROUTER (per-account hourly cap), payFee / refundGas ->
///         FEE_TO (code caps), withdraw -> owner() of the calling account (no cap), sale proceeds / change -> the account.
///
///         Changes against v17.2 (see DESIGN.md):
///         1. payFee: at most 20% of the account's native balance per call and 20% of its balance base per 30 days; refundGas: code caps
///            per call and per day. Both pay FEE_TO only (never the executor key).
///         2. withdraw: native, no cap, never paused, pays owner() of the calling account only (no recipient argument).
///            withdrawTo (account-only, NOT in the delegation) is the fallback when owner() cannot be resolved.
///         3. Sells are not limited by count or proceeds; buys keep the hourly HYPE cap. The executor's sell() keeps the loss budget and
///            adds a per-token price reference (a sale far below a recent market price books the shortfall as loss). The client's own
///            sale is exitSell(): not delegated, proven by tx.origin == owner, outside the budget and the reference, works while paused.
///         4. FEE_TO is a constructor immutable; the pause also stops fee and gas payments, never withdraw / exit / exitSell.
///         5. Fee / buy / gas limits use a two-bucket weighted sliding window instead of fixed windows.
///
///         Kept from v17.2: loss budget (30% of ETH + cost of open lots, 7-day linear refill, cold-key unlock), only-the-lot rule with
///         reconciliation against the account's holdings (_trim/_trimAll, 32-lot registry), pinned router executor and decoded route,
///         minOut, bounded balanceOf with gas floor, guardian pause (<= 7 days, 1 day cooldown), two-step guardian rotation, cold-key
///         replaceGuardian and exit() through tx.origin. No owner, no upgrade. `ETH` means the chain's native token (HYPE on Elysium).
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GuardedGate {
    // KyberSwap MetaAggregationRouterV2 calldata shape (decoded, never trusted blindly)
    struct SwapDescriptionV2 { address srcToken; address dstToken; address[] srcReceivers; uint256[] srcAmounts; address[] feeReceivers; uint256[] feeAmounts; address dstReceiver; uint256 amount; uint256 minReturnAmount; uint256 flags; bytes permit; }
    struct SwapExecutionParams { address callTarget; address approveTarget; bytes targetData; SwapDescriptionV2 desc; bytes clientData; }
    bytes4 private constant SEL_SWAP = 0xe21fd0e9;           // swap(SwapExecutionParams); swapSimpleMode (its own selector, or flag 0x20 inside swap) takes its pools from targetData, which this contract does not check
    uint256 private constant FLAGS_ALLOWED = 0x200;          // the one flag bit live routes carry and the router never reads (verified in its source); every bit the router dispatches on is refused
    address private constant K_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable ROUTER;
    address public immutable EXECUTOR;                // the router's aggregation executor the calldata must call
    address public immutable EXIT_KEY;                // the operator's cold key: unlock, exit, replaceGuardian
    address public immutable FEE_TO;                  // the only recipient of fees and gas refunds
    uint256 public constant BUDGET_BPS = 3000;      // losses may reach 30% of the account's value at cost (ETH + open lots)...
    uint256 public constant REFILL = 7 days;        // ...and that room comes back linearly over a week
    uint256 public constant PAUSE_MAX = 7 days;     // a pause lifts itself after this
    uint256 public constant PAUSE_COOLDOWN = 1 days; // and a new pause may start only this long after the last one ended
    uint256 public constant PENDING_TTL = 7 days;   // a proposed guardian must accept within this
    uint256 public constant MAX_RECEIVERS = 8;      // srcReceivers a sale route may name
    uint256 public constant FEE_MAX_BPS = 2000;     // payFee: at most 20% of the account's native balance (per call, and per FEE_WINDOW in total)
    uint256 public constant FEE_WINDOW = 30 days;   // span of the sliding fee window (two buckets of this length, weighted)
    uint256 public constant BUY_WINDOW = 1 hours;
    uint256 public constant GAS_WINDOW = 1 days;
    uint256 public constant GAS_BAL_BPS = 500;      // refundGas: the weighted day total also stays <= 5% of the account's balance
    uint256 public constant MIN_NEW_LOT = 0.001 ether;   // a new lot must have cost at least this (no 1-wei junk lots)
    uint256 public constant TRIM_GAS = 600_000;     // _trimAll stops after this much gas and resumes on the next call
    uint256 public constant MAX_DROP_BPS = 3000;    // an executor sale may not realise less than (1 - 30%) of the token's price reference without booking the shortfall
    uint256 public constant REF_DECAY = 2 days;     // the reference fades linearly to zero over this
    uint256 public constant REF_STEP_BPS = 15000;   // a trade may raise the stored reference by at most 1.5x
    uint256 public constant MIN_REF_ETH = 0.001 ether;   // trades smaller than this do not move the reference
    uint256 internal constant MAX_REF_PRICE = 1 << 96;
    uint256 public constant OWNER_GAS = 100_000;    // bound of the owner() read
    uint256 public constant MAX_UNLOCK = 64;        // accounts one unlock() may clear
    uint256 public constant MAX_LOT = 1e40;         // raw token units a lot may hold (keeps the arithmetic far from overflow)
    uint256 public constant MAX_LOTS = 32;          // v17: open lots per account (every sale reconciles all of them before it reads the base)
    uint256 internal constant GAS_FLOOR = 102_000;   // v17.1: BALANCE_GAS * 64 / 63 plus a margin; below it a balance read reverts instead of running starved
    uint256 public constant BALANCE_GAS = 100_000;  // v17: gas one balanceOf read may use; a token that needs more (or burns it) reads as unreadable

    struct Basis { uint256 tokens; uint256 ethIn; }     // the lot: tokens held and their running cost
    mapping(address => mapping(address => Basis)) public basis;
    mapping(address => uint256) public costOf;        // the account's total cost basis across lots (with its ETH: the budget's base)
    struct Loss { uint256 amount; uint64 at; }         // losses outstanding as of `at`; the whole amount fades linearly over REFILL from then (since v15: no
                                                        // rate, no budget in the decay -- a later buy, sale or closed lot cannot speed it up or freeze it)
    mapping(address => Loss) public loss;

    uint256 public immutable MAX_BUY_ETH_PER_HOUR;    // set at deployment (production: 17.5 ether). Sells have no count / proceeds cap (DESIGN.md 1.4)
    struct Window { uint64 bucket; uint128 cur; uint128 prev; }   // per account: buy HYPE in this hour bucket and the previous one (sliding, weighted)
    mapping(address => Window) public window;

    uint256 public immutable GAS_CALL_MAX;
    uint256 public immutable GAS_DAY_MAX;
    /// fee window (30-day buckets): fees paid and native withdrawn through withdrawTo to a non-owner; gas window (day buckets): gas refunded.
    /// Each is a (current bucket, previous bucket) pair; the previous one counts with the weight of the time left in the current one.
    struct Pay { uint64 feeBucket; uint128 feeCur; uint128 feePrev; uint128 wdCur; uint128 wdPrev; uint64 gasBucket; uint128 gasCur; uint128 gasPrev; }
    mapping(address => Pay) public pay;
    /// per-token market price reference, global across accounts: highest implied price (wei per 1e18 raw units) of recent executor trades
    struct Ref { uint128 price; uint64 at; }
    mapping(address => Ref) public ref;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingAt;                          // when the pending guardian was proposed
    uint256 public pausedAt;                           // 0 = not paused; a pause expires PAUSE_MAX after this
    uint256 public pauseEnd;                           // when the last pause ended (0 = never paused, or paused now)

    uint256 private _lock;
    mapping(address => address[]) private _lots;      // v17: the tokens of the account's open lots (basis tokens > 0), unordered (declared last: earlier slots keep v16's layout)
    mapping(address => mapping(address => uint256)) private _lotIdx;   // position in _lots + 1 (0 = no open lot)
    mapping(address => uint256) private _trimPos;     // _trimAll cursor: entries of _lots still to visit in this round (0 = start a round)

    event Bought(address indexed account, address indexed token, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed account, address indexed token, uint256 tokensIn, uint256 ethOut, uint256 lossAdded, bool exit);
    event FeePaid(address indexed account, uint256 amount);
    event GasPaid(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);
    event LotForgotten(address indexed account, address indexed token);
    event Unlocked(address indexed account, uint256 lossCleared);
    event Reconciled(address indexed account, address indexed token, uint256 tokens, uint256 ethIn);   // a lot lowered to the account's balance (0, 0 = closed)
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
    error TooManyLots();
    error NotReconciler();
    error GasTooLow();
    error FeeLimit();
    error GasLimit();
    error TokenUnreadable();
    error NoBeneficiary();
    error BadRecipient();
    error NotOwnerOrigin();
    error DustLot();

    struct Params { address router; address executor; address guardian; address exitKey; address feeTo; uint256 maxBuyEthPerHour; uint256 gasCallMax; uint256 gasDayMax; }

    constructor(Params memory p) {
        require(p.router != address(0) && p.executor != address(0) && p.guardian != address(0) && p.exitKey != address(0) && p.feeTo != address(0), "zero address");
        require(p.guardian != p.router && p.guardian != p.executor && p.guardian != address(this), "guardian");
        require(p.exitKey != p.router && p.exitKey != p.executor && p.exitKey != p.guardian && p.exitKey != address(this), "exit key");
        require(p.feeTo != p.router && p.feeTo != p.executor && p.feeTo != address(this) && p.feeTo != p.guardian && p.feeTo != p.exitKey, "fee to");
        require(p.router != p.executor, "router == executor");
        require(p.router != address(this) && p.executor != address(this), "self");
        require(p.router.code.length > 0 && p.executor.code.length > 0, "not a contract");
        require(p.exitKey.code.length == 0, "exit key must be an EOA");    // it submits transactions itself: tx.origin is how exit() recognises it
        require(p.maxBuyEthPerHour > 0 && p.gasCallMax > 0 && p.gasDayMax >= p.gasCallMax, "zero limit");
        require(p.maxBuyEthPerHour <= type(uint128).max && p.gasDayMax <= type(uint128).max, "limit too large");
        ROUTER = p.router; EXECUTOR = p.executor; guardian = p.guardian; EXIT_KEY = p.exitKey; FEE_TO = p.feeTo;
        MAX_BUY_ETH_PER_HOUR = p.maxBuyEthPerHour; GAS_CALL_MAX = p.gasCallMax; GAS_DAY_MAX = p.gasDayMax;
    }

    /// @dev ETH is accepted only while a trade is in progress (the proceeds of a sale, paid by the router or its executor on
    ///      unwrapping). Outside a call it is refused rather than stranded.
    receive() external payable { if (_lock == 0) revert NoDirectEth(); }

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }

    // ---- guardian: pause the executor, rotate itself ----
    /// @notice Paused while the guardian's pause is younger than PAUSE_MAX: a lost key can never freeze the executor for good.
    function paused() public view returns (bool) { return pausedAt != 0 && block.timestamp < pausedAt + PAUSE_MAX; }
    /// @notice The guardian stops and resumes the executor (buys and sells; exit() is never blocked). A pause lasts at most PAUSE_MAX and
    ///         the next may start only PAUSE_COOLDOWN after the last one ended.
    function setPaused(bool p) external lock onlyGuardian {
        if (p) {
            if (paused()) revert PauseCooldown();
            uint256 end = pausedAt != 0 ? pausedAt + PAUSE_MAX : pauseEnd;     // an expired pause ended at its expiry
            if (end != 0 && block.timestamp < end + PAUSE_COOLDOWN) revert PauseCooldown();
            pausedAt = block.timestamp; pauseEnd = 0; emit Paused(true);
        } else if (pausedAt != 0) {
            uint256 exp = pausedAt + PAUSE_MAX; pauseEnd = block.timestamp < exp ? block.timestamp : exp; pausedAt = 0; emit Paused(false);
        }                                                               // (free audit, I-4) resuming when nothing was paused changes nothing and emits nothing
    }
    /// @notice The cold key may replace the guardian outright: a lost or hostile guardian key cannot hold the executor in a
    ///         pause cycle for good (round 13, F-3). The new guardian lifts the pause itself. (`replaceGuardian` is the only
    ///         power the cold key has over the guardian; it cannot pause or trade.)
    function replaceGuardian(address next) external lock {
        if (msg.sender != EXIT_KEY) revert NotExitKey();
        if (next == address(0) || next == guardian || next == ROUTER || next == EXECUTOR || next == EXIT_KEY || next == FEE_TO || next == address(this)) revert BadGuardian();
        emit GuardianChanged(guardian, next); guardian = next; pendingGuardian = address(0); pendingAt = 0;
    }
    /// @notice Two-step guardian rotation: the current guardian proposes, the proposed address accepts within PENDING_TTL.
    function proposeGuardian(address next) external lock onlyGuardian {
        if (next == address(0) || next == guardian || next == ROUTER || next == EXECUTOR || next == EXIT_KEY || next == FEE_TO || next == address(this)) revert BadGuardian();
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
        if (msg.sender != EXIT_KEY) revert NotExitKey();       // the key itself, directly: no contract between the key and this call may clear budgets (round 13, F-1)
        if (accounts.length > MAX_UNLOCK) revert TooLarge();
        for (uint256 i = 0; i < accounts.length; i++) { uint256 l = loss[accounts[i]].amount; delete loss[accounts[i]]; emit Unlocked(accounts[i], l); }
    }

    // ---- windows, budget ----
    /// @dev Two-bucket sliding window: buckets are aligned slots of `span` seconds. The previous bucket counts with the share of the
    ///      current slot still to run, so an edge burst cannot double the limit (it reads full weight right after the boundary).
    function _roll(uint64 bucket, uint128 cur, uint128 prev, uint256 span) private view returns (uint64 nb, uint128 c, uint128 p) {
        nb = uint64(block.timestamp / span);
        if (bucket == nb) return (nb, cur, prev);
        if (bucket + 1 == nb && bucket != 0) return (nb, 0, cur);
        return (nb, 0, 0);
    }
    function _weigh(uint128 cur, uint128 prev, uint256 span) private view returns (uint256) {
        return uint256(prev) * (span - block.timestamp % span) / span + cur;
    }
    function _countBuy(uint256 spent) private {
        Window storage w = window[msg.sender];
        (uint64 nb, uint128 c, uint128 p) = _roll(w.bucket, w.cur, w.prev, BUY_WINDOW);
        if (_weigh(c, p, BUY_WINDOW) + spent > MAX_BUY_ETH_PER_HOUR) revert RateLimited();
        w.bucket = nb; w.prev = p; w.cur = c + uint128(spent);
    }
    function _ceil(uint256 a, uint256 b) private pure returns (uint256) { return (a + b - 1) / b; }
    /// @dev The budget's base: the account's native ETH plus the cost of its open lots, every lot reconciled with what the
    ///      account holds. A buy moves ETH into a lot at cost and a sale at cost moves it back, so the gate's own trades leave
    ///      the base where it was; a loss lowers it by the loss, a profit raises it by the profit, a deposit or a withdrawal
    ///      (the owner's alone) by its amount, tokens the owner moved out by their cost. A sale reads it from storage right
    ///      after _trimAll, when costOf is exactly that sum; the views compute the same sum through _trimmed without writing.
    function _base(address account) private view returns (uint256) { return costOf[account] + account.balance; }
    function _quotedBase(address account) private view returns (uint256 b) {
        b = account.balance; address[] storage a = _lots[account];
        for (uint256 i = 0; i < a.length; i++) { (, uint256 ethIn) = _trimmed(account, a[i]); b += ethIn; }
    }
    /// @dev The budget on a base: BUDGET_BPS of it. What is outstanding decays on its own clock (_decayed), not the budget's.
    function _budgetOn(uint256 base) private pure returns (uint256) { return base * BUDGET_BPS / 10000; }
    function _decayed(address account) private view returns (uint256) {
        Loss storage l = loss[account];
        if (l.amount == 0) return 0;
        if (block.timestamp <= l.at) return l.amount;                   // (round 13, L-2) no backward time
        uint256 back = l.amount * (block.timestamp - l.at) / REFILL;  // the booked amount itself is the rate: gone within REFILL of its booking
        return back >= l.amount ? 0 : l.amount - back;
    }
    /// @notice Losses on the account's record right now, and the budget they must stay within.
    function budgetOf(address account) external view returns (uint256 lost, uint256 budget) { return (_decayed(account), _budgetOn(_quotedBase(account))); }

    /// @dev The lot never exceeds what the account holds: tokens the owner moved out (or a negative rebase) leave the lot
    ///      pro rata, as if sold at cost (rounded so the average never drops). An empty balance closes the lot. Tokens that
    ///      arrive before the next call are indistinguishable from the lot and carried at its cost.
    function _trim(address account, address token) private {
        Basis storage b = basis[account][token];
        if (b.tokens == 0) return;
        (bool ok, uint256 bal) = _balanceOf(token, account);
        if (!ok) return;                                            // unreadable balance: keep the last lot; the sale or the cold key's exit must not die here (round 11, H-1)
        if (bal == 0) { _closeLot(account, token); return; }
        if (bal < b.tokens) { uint256 keep = _ceil(b.ethIn * bal, b.tokens); costOf[account] -= b.ethIn - keep; b.ethIn = keep; b.tokens = bal; emit Reconciled(account, token, bal, keep); }
    }
    /// @dev v17: every open lot of the account reconciled, so the base a sale reads carries no cost of tokens the account no
    ///      longer holds (round 15, H). Walked from the end: closing a lot moves the last entry, which is already done.
    ///      Bounded by MAX_LOTS reads of at most BALANCE_GAS each; a token that does not answer is skipped, never fatal.
    ///      v18: a total gas budget (TRIM_GAS) per call -- a cursor remembers where the walk stopped and the next call resumes there, so a
    ///      registry stuffed with slow tokens cannot make every sale cost 32 slow reads.
    function _trimAll(address account) private {
        address[] storage a = _lots[account];
        uint256 pos = _trimPos[account]; uint256 n = a.length;
        if (pos == 0 || pos > n) pos = n;
        uint256 g0 = gasleft();
        while (pos > 0 && g0 - gasleft() < TRIM_GAS) { _trim(account, a[pos - 1]); pos--; }
        _trimPos[account] = pos;
    }
    /// @notice ACCOUNT-ONLY (not delegated): drop an open lot from the books without reading the token at all -- the escape from junk
    ///         lots whose balanceOf burns gas or reverts. The tokens (if any) stay in the account; the gate just stops tracking them.
    function forgetLot(address token) external lock {
        if (basis[msg.sender][token].tokens == 0 && _lotIdx[msg.sender][token] == 0) return;
        _closeLot(msg.sender, token); emit LotForgotten(msg.sender, token);
    }
    /// @notice Reconcile an account's lots with what it holds (free audit F-1): a lot the owner emptied is closed now, not at the
    ///         next sale, so tokens given back to the account later cannot bring its old cost back into the base. It only lowers or
    ///         closes lots, never raises one, and never closes a lot whose balance does not answer. v17.1 (round 16, L-1): closing is
    ///         irreversible, so only the account itself (its UI batches it with the transfer), the guardian (the watcher) or the cold
    ///         key may call it; nobody can close a lot on a balance that reads low only for a moment.
    function reconcile(address account) external lock {
        if (msg.sender != account && msg.sender != guardian && msg.sender != EXIT_KEY) revert NotReconciler();
        _trimAll(account);
    }
    /// @dev The registry follows the lots: an entry is added when a lot opens and removed wherever one is deleted.
    function _openLot(address account, address token) private {
        if (_lotIdx[account][token] != 0) return;
        if (_lots[account].length >= MAX_LOTS) { _trimAll(account); if (_lots[account].length >= MAX_LOTS) revert TooManyLots(); }   // lots the owner emptied free their slots first
        _lots[account].push(token); _lotIdx[account][token] = _lots[account].length;
    }
    function _closeLot(address account, address token) private {
        costOf[account] -= basis[account][token].ethIn; delete basis[account][token]; emit Reconciled(account, token, 0, 0);   // (free audit, I-2)
        uint256 i = _lotIdx[account][token]; if (i == 0) return;
        address[] storage a = _lots[account]; address last = a[a.length - 1];
        a[i - 1] = last; _lotIdx[account][last] = i; a.pop(); delete _lotIdx[account][token];
    }
    /// @dev What _trim would make of the lot, without writing: the views quote the reconciled lot.
    function _trimmed(address account, address token) private view returns (uint256 tokens, uint256 ethIn) {
        Basis storage b = basis[account][token];
        (tokens, ethIn) = (b.tokens, b.ethIn);
        if (tokens == 0) return (0, 0);
        (bool ok, uint256 bal) = _balanceOf(token, account);
        if (!ok) return (tokens, ethIn);
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
        if (p.approveTarget != address(0) && p.approveTarget != EXECUTOR) revert BadRoute();   // swap() never reads approveTarget (only swapGeneric does); kept so the field cannot name anyone else
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
        _trim(msg.sender, token);                                   // the lot is reconciled with what the account holds before this buy
        bool fresh = basis[msg.sender][token].tokens == 0;
        if (fresh) _openLot(msg.sender, token);                     // a new lot takes a registry slot (TooManyLots past MAX_LOTS)
        _checkRoute(routerData, K_ETH, token, msg.value, minOut);
        if (msg.value > MAX_BUY_ETH_PER_HOUR) revert RateLimited();   // the net spend is counted below, once known
        uint256 ethBase = address(this).balance - msg.value;        // ETH that was here before this call stays untouched
        uint256 tokBase = _gateBal(token);   // tokens that were here before this call stay untouched
        (bool okB, uint256 before) = _balanceOf(token, msg.sender);
        if (!okB) revert BelowMinOut(0, minOut);                   // a token that will not report the account's balance cannot be bought (round 12, L-2)
        uint256 home = msg.sender.balance;                          // v17: the account's ETH once msg.value has left it...
        _callRouter(routerData, msg.value);
        _sweepToken(token, tokBase);
        home = msg.sender.balance > home ? msg.sender.balance - home : 0;   // ...and what came back to it during the router call and the token transfer, before any change is forwarded
        { (bool okA, uint256 after_) = _balanceOf(token, msg.sender); out = okA && after_ > before ? after_ - before : 0; }
        if (out < minOut) revert BelowMinOut(out, minOut);
        uint256 change = address(this).balance - ethBase;           // unspent part of msg.value, returned to the caller last
        if (change > msg.value) revert RouterOverpaid();
        uint256 spent = msg.value - change;
        spent = home >= spent ? 0 : spent - home;                   // v17: ETH that came straight back to the account was not spent (round 15, M)
        if (spent == 0) revert ZeroAmount();                        // a free lot would have no cost to protect
        if (fresh && spent < MIN_NEW_LOT) revert DustLot();         // v18: no 1-wei junk lots to fill the registry
        _countBuy(spent);                                           // hourly budget counts what was actually spent
        Basis storage b = basis[msg.sender][token];
        b.ethIn += spent; b.tokens += out; costOf[msg.sender] += spent;
        if (b.tokens > MAX_LOT) revert TooLarge();
        emit Bought(msg.sender, token, spent, out);
        _refNote(token, spent, out);                                // the price this buy paid feeds the token's reference
        if (change > 0) _sendEth(msg.sender, change);               // state is final before any ETH leaves
    }

    /// @notice Sell `amount` of `token` (at most the lot) for ETH through the router, within the loss budget.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (paused()) revert IsPaused();                            // v14: a pause stops the executor's sales too -- once the watcher pauses, a thief cannot keep selling; exit() and the owner's own wallet are unaffected
        return _sale(token, amount, minOut, routerData, false);
    }
    /// @notice The CLIENT's own sale: the same sale as sell(), outside the loss budget and the price reference, books no loss, works while
    ///         paused. NOT in the delegation's AllowedMethods. Proof of the owner, as in exit(): tx.origin must be ownerOf(msg.sender)
    ///         (the owner's own transaction redeeming a delegation his account signed to him). The executor key is never the owner.
    function exitSell(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (tx.origin != ownerOf(msg.sender)) revert NotOwnerOrigin();
        return _sale(token, amount, minOut, routerData, true);
    }
    /// @notice The cold key's exit: the same sale, outside the loss budget and the reference, paid to the account.
    ///         Reached through the account's delegation to the exit key: the account is msg.sender, the key is tx.origin.
    function exit(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (tx.origin != EXIT_KEY) revert NotExitKey();
        return _sale(token, amount, minOut, routerData, true);
    }

    function _sale(address token, uint256 amount, uint256 minOut, bytes calldata routerData, bool isExit) private returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token.code.length == 0) revert NotAContract();
        _trimAll(msg.sender);                                       // v17: every lot reconciled -- the exit too, so the books stay true; it still ignores the budget
        { uint256 lot = basis[msg.sender][token].tokens; if (amount > lot) revert NotInLot(lot, amount); }   // only what this gate saw bought, and still holds
        uint256 budget = isExit ? 0 : _budgetOn(_base(msg.sender)); // measured once, on the reconciled lots, before anything moves (the router call cannot raise it)
        uint256 tokBase = _gateBal(token);   // tokens that were here before this call stay untouched
        uint256 got = _pull(token, msg.sender, amount);             // what actually arrived (fee-on-transfer aware)
        _checkRoute(routerData, token, K_ETH, got, minOut);
        _approveForRouter(token, got);
        uint256 ethBase = address(this).balance;
        _callRouter(routerData, 0);
        _approveSoft(token, ROUTER, 0);                             // cleanup only; a token that rejects approve(0) must not undo the sale
        uint256 back = _sweepToken(token, tokBase);                 // whatever the router did not take goes back
        out = address(this).balance - ethBase;                      // the sale is paid here and forwarded last
        if (out < minOut) revert BelowMinOut(out, minOut);
        if (back >= amount) revert ZeroAmount();                    // nothing was sold: no cost released, no slot spent
        _settle(token, amount - back, out, isExit, budget);         // the lot shrinks by what the account gave up (pull-side fees included)
        if (out > 0) _sendEth(msg.sender, out);                     // state is final before any ETH leaves
    }

    /// @dev Release the cost of what was sold; a sale below that cost is a loss charged to the account's budget (unless it
    ///      is the cold key's exit). The lot is reduced pro rata and closed when the account holds none of the token.
    function _settle(address token, uint256 sold, uint256 out, bool isExit, uint256 budget) private {
        Basis storage b = basis[msg.sender][token];
        if (sold > b.tokens) revert NotInLot(b.tokens, sold);      // cannot happen (checked on entry); kept as the invariant
        uint256 cost = b.ethIn * sold / b.tokens;                   // released cost rounded DOWN: the remainder's average never drops, never zeroes
        uint256 added;
        if (!isExit) {
            if (out < cost) added = cost - out;
            uint256 rp = _refPrice(token);                          // price reference: a sale far under a recent market price books the shortfall as loss
            if (rp != 0) { uint256 fl = rp * sold / 1e18 * (10000 - MAX_DROP_BPS) / 10000; if (out < fl && fl - out > added) added = fl - out; }
        }
        if (added != 0) {
            uint256 carried = _decayed(msg.sender); uint256 total = carried + added;   // against the budget measured when the sale started
            if (total > budget) revert BudgetExceeded(total, budget);
            // what is outstanding now fades over REFILL from now: booking more resets the clock on a larger amount (slower overall),
            // nothing else moves it -- not new buys, not closed lots, not a shrinking base (round 11 C-1, round 13 F-4)
            loss[msg.sender] = Loss(total, uint64(block.timestamp));
        }
        if (!isExit) _refNote(token, out, sold);
        b.ethIn -= cost; b.tokens -= sold; costOf[msg.sender] -= cost;
        (bool okb, uint256 left) = _balanceOf(token, msg.sender);
        if (b.tokens == 0 || (okb && left == 0)) _closeLot(msg.sender, token);   // full exit (an unreadable balance is not taken as empty)
        emit Sold(msg.sender, token, sold, out, added, isExit);
    }

    // ---- per-token price reference ----
    /// @dev Reference price of `token` now: the stored high-water price faded linearly to zero over REF_DECAY (0 = none).
    function _refPrice(address token) private view returns (uint256) {
        Ref storage r = ref[token];
        uint256 dt = block.timestamp > r.at ? block.timestamp - r.at : 0;
        if (r.price == 0 || dt >= REF_DECAY) return 0;
        return uint256(r.price) * (REF_DECAY - dt) / REF_DECAY;
    }
    /// @dev Record an executor trade's implied price (ETH per 1e18 raw token units). It only ever raises the reference (high-water), and a
    ///      single trade lifts a live reference by at most REF_STEP_BPS, so one rigged trade cannot jump it. Dust trades are ignored.
    function _refNote(address token, uint256 eth, uint256 tokens) private {
        if (eth < MIN_REF_ETH || tokens == 0) return;
        uint256 pr = eth * 1e18 / tokens;
        if (pr >= MAX_REF_PRICE) return;
        if (pr <= _refPrice(token)) return;
        Ref storage r = ref[token];
        if (r.price != 0 && block.timestamp < r.at + REF_DECAY) { uint256 cap = uint256(r.price) * REF_STEP_BPS / 10000; if (pr > cap) pr = cap; }
        r.price = uint128(pr); r.at = uint64(block.timestamp);
    }

    // ---- money out of the account: fee, gas, withdrawal ----
    /// @dev Roll the fee window (30-day buckets) and return the weighted fee total and the weighted non-owner withdrawals.
    function _feeRoll(Pay storage p) private returns (uint256 feeW, uint256 wdW) {
        uint64 nb = uint64(block.timestamp / FEE_WINDOW);
        if (p.feeBucket != nb) {
            if (p.feeBucket != 0 && p.feeBucket + 1 == nb) { p.feePrev = p.feeCur; p.wdPrev = p.wdCur; } else { p.feePrev = 0; p.wdPrev = 0; }
            p.feeCur = 0; p.wdCur = 0; p.feeBucket = nb;
        }
        return (_weigh(p.feeCur, p.feePrev, FEE_WINDOW), _weigh(p.wdCur, p.wdPrev, FEE_WINDOW));
    }
    /// @notice The performance fee, paid from the calling account (msg.value) to FEE_TO only. Two limits, both measured on the account's
    ///         native balance: (1) this call <= 20% of the balance the account had before it (msg.sender.balance + msg.value);
    ///         (2) fees of the sliding 30-day window <= 20% of (that balance + fees already paid + native withdrawn through withdrawTo
    ///         to a non-owner in the window), so repeated 20% calls cannot compound into a drain. The window is two weighted buckets:
    ///         no 2x burst at a boundary. withdraw() to the owner does NOT widen (2). Paused: refused.
    function payFee() external payable lock {
        if (paused()) revert IsPaused();
        uint256 v = msg.value;
        if (v == 0) revert ZeroAmount();
        uint256 before = msg.sender.balance + v;                    // the account's balance before this transfer
        if (v * 10000 > before * FEE_MAX_BPS) revert FeeLimit();
        Pay storage p = pay[msg.sender]; (uint256 feeW, uint256 wdW) = _feeRoll(p);
        if ((feeW + v) * 10000 > (before + feeW + wdW) * FEE_MAX_BPS) revert FeeLimit();
        p.feeCur += _u128(v);
        emit FeePaid(msg.sender, v);
        _sendEth(FEE_TO, v);
    }
    /// @notice The fee the account could be charged right now (a view for the engine; the same two limits as payFee).
    function feeRoom(address account) external view returns (uint256 room) {
        Pay storage p = pay[account]; uint256 bal = account.balance;
        (, uint128 fc, uint128 fp) = _roll(p.feeBucket, p.feeCur, p.feePrev, FEE_WINDOW);
        (, uint128 wc, uint128 wp) = _roll(p.feeBucket, p.wdCur, p.wdPrev, FEE_WINDOW);
        uint256 feeSum = _weigh(fc, fp, FEE_WINDOW); uint256 wd = _weigh(wc, wp, FEE_WINDOW);
        room = bal * FEE_MAX_BPS / 10000;
        uint256 agg = (bal + feeSum + wd) * FEE_MAX_BPS / 10000; agg = agg > feeSum ? agg - feeSum : 0;
        if (agg < room) room = agg;
    }
    /// @notice Refund of the network fees the operator advanced, paid from the calling account to FEE_TO (never to a key). Limits: per call
    ///         GAS_CALL_MAX; per sliding day (two weighted buckets) GAS_DAY_MAX and also <= 5% of the account's balance.
    function refundGas() external payable lock {
        if (paused()) revert IsPaused();
        uint256 v = msg.value;
        if (v == 0) revert ZeroAmount();
        if (v > GAS_CALL_MAX) revert GasLimit();
        Pay storage p = pay[msg.sender];
        (uint64 nb, uint128 c, uint128 pv) = _roll(p.gasBucket, p.gasCur, p.gasPrev, GAS_WINDOW);
        uint256 day = _weigh(c, pv, GAS_WINDOW) + v;
        if (day > GAS_DAY_MAX) revert GasLimit();
        if (day * 10000 > (msg.sender.balance + v) * GAS_BAL_BPS) revert GasLimit();
        p.gasBucket = nb; p.gasPrev = pv; p.gasCur = c + _u128(v);
        emit GasPaid(msg.sender, v);
        _sendEth(FEE_TO, v);
    }
    /// @notice Native withdrawal: msg.value of the calling account goes to that account's owner(), whatever the amount. No cap, never paused.
    ///         A plain wallet / 7702 account is its own owner (the value returns to it). Does not touch the fee aggregate.
    function withdraw() external payable lock {
        uint256 v = msg.value;
        if (v == 0) revert ZeroAmount();
        address to = ownerOf(msg.sender);
        emit Withdrawn(msg.sender, to, v);
        _sendEth(to, v);
    }
    /// @notice ACCOUNT-ONLY fallback for an account whose owner() cannot be resolved (rotated to a contract wallet, passkey-only, reverting):
    ///         the account's owner, acting through his own account, names the recipient. NOT in the delegation's AllowedMethods, so the
    ///         executor cannot reach it. Never paused. Value sent to somebody who is neither the account nor its owner widens the fee base.
    function withdrawTo(address to) external payable lock {
        if (msg.value == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this) || to == ROUTER) revert BadRecipient();
        emit Withdrawn(msg.sender, to, msg.value);
        if (to != msg.sender) {
            (bool okO, address o) = _owner(msg.sender);
            if (!okO || to != o) { Pay storage p = pay[msg.sender]; _feeRoll(p); p.wdCur += _u128(msg.value); }
        }
        _sendEth(to, msg.value);
    }
    function _u128(uint256 v) private pure returns (uint128) { if (v > type(uint128).max) revert TooLarge(); return uint128(v); }

    // ---- the owner of an account ----
    /// @notice Where an account's money goes: a plain wallet (no code, or an EIP-7702 delegated EOA) is its own beneficiary;
    ///         a smart account pays its owner() (the Hybrid account's signer), which must itself be a plain wallet.
    function ownerOf(address account) public view returns (address to) {
        bool ok; (ok, to) = _owner(account);
        if (!ok) revert NoBeneficiary();
    }
    function _owner(address account) private view returns (bool, address to) {
        if (_plain(account)) return (true, account);
        bool ok; uint256 v;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x8da5cb5b))
            ok := staticcall(OWNER_GAS, account, p, 4, p, 32)
            ok := and(ok, gt(returndatasize(), 31))
            if ok { v := mload(p) }
        }
        if (!ok || v >> 160 != 0) return (false, address(0));
        to = address(uint160(v));
        if (to == address(0) || to == account || to == address(this) || to == ROUTER || !_plain(to)) return (false, address(0));
        return (true, to);
    }
    function _plain(address a) private view returns (bool) {
        uint256 n = a.code.length;
        if (n == 0) return true;
        if (n != 23) return false;
        bytes memory code = a.code;
        return code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
    }

    /// @notice The lot as the next call will see it: tokens still held and their cost.
    function lotOf(address account, address token) external view returns (uint256 tokens, uint256 ethIn) { return _trimmed(account, token); }
    /// @notice The tokens of the account's open lots as recorded (a lot the next call would find empty is still listed).
    function lotsOf(address account) external view returns (address[] memory) { return _lots[account]; }
    /// @notice The lowest ETH a sale of `amount` of `token` would accept right now without exceeding the budget (0 = any, or not in the lot).
    function floorFor(address account, address token, uint256 amount) external view returns (uint256) {
        (uint256 tokens, uint256 ethIn) = _trimmed(account, token);
        if (tokens == 0 || amount > tokens) return 0;
        uint256 cost = ethIn * amount / tokens; uint256 room = _budgetOn(_quotedBase(account)); uint256 lost = _decayed(account);   // v17: the base a sale would read (round 15, L)
        room = room > lost ? room - lost : 0;
        return cost > room ? cost - room : 0;
    }

    function _callRouter(bytes calldata data, uint256 value) private {
        (bool ok, bytes memory err) = ROUTER.call{value: value}(data);
        if (!ok) revert RouterFailed(err);
    }
    /// @dev What this call added to the contract's `token` balance (above `base`) goes to msg.sender; returns what the account received.
    function _sweepToken(address token, uint256 base) private returns (uint256 delivered) {
        uint256 bal = _gateBal(token);
        uint256 held = bal > base ? bal - base : 0;
        if (held == 0) return 0;
        (bool ok, uint256 before) = _balanceOf(token, msg.sender);
        _send(token, msg.sender, held);
        if (!ok) return held;                                       // the account's balance does not answer: count what left this contract
        (bool ok2, uint256 after_) = _balanceOf(token, msg.sender);
        delivered = ok2 && after_ >= before ? after_ - before : held;   // measured on the account, as buy() does (round 11, M-1): a fee on the way out shrinks what came back
    }
    /// @dev balanceOf that reports whether the token answered instead of reverting the whole call. v17: at most BALANCE_GAS and
    ///      32 bytes of answer copied, so a token in the registry cannot make the walk over all lots run out of gas (by burning
    ///      it or by returning a huge answer) and thereby block every sale and exit of the account.
    function _balanceOf(address token, address who) private view returns (bool ok, uint256 bal) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            if lt(gas(), GAS_FLOOR) { mstore(0, shl(224, 0x858c8974)) revert(0, 4) }   // v17.1 (round 16, L-2): the read gets its full allowance or the call reverts
            mstore(p, shl(224, 0x70a08231)) mstore(add(p, 4), and(who, 0xffffffffffffffffffffffffffffffffffffffff))
            let s_ := staticcall(BALANCE_GAS, token, p, 36, p, 32)
            ok := and(s_, gt(returndatasize(), 31))
            if ok { bal := mload(p) }
        }
    }

    // ---- token helpers: low-level calls so tokens that return nothing (USDT-style) work too ----
    /// @dev The gate's own balance of `token` through the bounded read; a token that does not answer cannot be traded.
    function _gateBal(address token) private view returns (uint256 bal) { bool ok; (ok, bal) = _balanceOf(token, address(this)); if (!ok) revert TokenUnreadable(); }
    /// @dev Bounded token call: at most 32 bytes of return data are copied (a return-data bomb cannot cost memory gas). True on success;
    ///      no return data counts as success (USDT style), anything else must be exactly one 32-byte word equal to 1.
    function _call3(address token, bytes4 sel, address x, address y, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            let n_ := 68
            switch y
            case 0 { mstore(add(p, 4), and(x, 0xffffffffffffffffffffffffffffffffffffffff)) mstore(add(p, 36), amount) }
            default { mstore(add(p, 4), and(x, 0xffffffffffffffffffffffffffffffffffffffff)) mstore(add(p, 36), and(y, 0xffffffffffffffffffffffffffffffffffffffff)) mstore(add(p, 68), amount) n_ := 100 }
            ok := call(gas(), token, 0, p, n_, p, 32)
            if ok { let n := returndatasize() if n { ok := and(eq(n, 32), eq(mload(p), 1)) } }
        }
    }
    function _pull(address token, address from, uint256 amount) private returns (uint256 got) {
        (bool ok0, uint256 before) = _balanceOf(token, address(this));
        if (!ok0 || !_call3(token, 0x23b872dd, from, address(this), amount)) revert TransferFailed();
        (bool ok1, uint256 after_) = _balanceOf(token, address(this));
        got = ok1 && after_ > before ? after_ - before : 0;
        if (got == 0) revert ZeroAmount();
    }
    function _send(address token, address to, uint256 amount) private {
        if (!_call3(token, 0xa9059cbb, to, address(0), amount)) revert TransferFailed();
    }
    function _approveTry(address token, address spender, uint256 amount) private returns (bool) {
        return _call3(token, 0x095ea7b3, spender, address(0), amount);
    }
    function _approveForRouter(address token, uint256 amount) private {
        if (_approveTry(token, ROUTER, amount)) return;
        _approveSoft(token, ROUTER, 0);
        if (!_approveTry(token, ROUTER, amount)) revert TransferFailed();
    }
    function _approveSoft(address token, address spender, uint256 amount) private {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x095ea7b3)) mstore(add(p, 4), and(spender, 0xffffffffffffffffffffffffffffffffffffffff)) mstore(add(p, 36), amount)
            pop(call(gas(), token, 0, p, 68, 0, 0))
        }
    }
    function _sendEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }
}
