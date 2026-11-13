// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPVaultBase
/// @notice Venue-independent core of a client-facing (optionally hedged) LP vault with asynchronous, keeper-settled
///         deposits and redemptions (ERC-7540 style). One deployment = one strategy (one pool, one hedge treasury).
///
///         CLIENT FLOW
///         - Enter: `requestDepositWithPermit` (1 off-chain signature + 1 tx) or approve + `requestDeposit`. The USDC is
///           pulled into the vault at once and queued. Until the next settlement the client may `cancelDeposit`.
///         - Exit: `requestRedeem(shares)` (1 tx). The shares are locked in the vault. At the next settlement the
///           keeper prices them at a fresh NAV, burns them and PUSHES the USDC to the client: no claim tx. If the
///           vault lacks idle USDC the request stays queued (FIFO) until the keeper frees liquidity.
///         - There is no absolute withdrawal limit of any kind.
///
///         NAV (see `grossAssets`): idle asset (excluding queued deposits and unpaid claims) + idle base token valued at
///         the keeper price + LP positions (amounts from the pool's current sqrtPrice, valued at the keeper price) +
///         the keeper-reported off-chain hedge equity. Settlement reverts unless the pool price is within
///         `poolBandBps` of the keeper price, and the hedge equity may move at most `hedgeStepBps` of the last NAV per
///         settlement unless the guardian pre-approved the exact value for that epoch.
///
///         FEES: `feeBps` (default 15%, hard cap 20%) of the gain of price-per-share above the high-water mark, taken
///         at settlement by minting shares to `feeRecipient`. The HWM never decreases.
///
///         ROLES: owner (multisig; sets keeper/guardian/fee recipient and bounded parameters, can never move funds),
///         keeper (settles, manages LP and hedge margin through allowlisted, relatively bounded calls only),
///         guardian (pauses new deposits and risk-increasing keeper actions, co-signs large hedge equity jumps; can
///         never move funds). Pause never blocks redemptions, cancellations, liquidity removal or hedge returns.
///
///         LIVENESS: if no settlement happens for `SETTLE_TIMEOUT` (72 h) anyone may call `emergencyUnwind()`. It
///         removes all LP liquidity into tokens and switches the vault into permanent wind-down. Holders (and holders
///         of queued redeem requests, after `cancelRedeem`) then `emergencyRedeem` a pro-rata share of every token the
///         vault holds on-chain. The hedge margin sitting at `hedgeTreasury` (on Hyperliquid) is NOT on-chain: it is
///         the keeper operator's off-chain obligation to close the hedge and send that USDC back with
///         `returnHedgeMargin`, after which it is distributed pro-rata to the shares still outstanding. Holders who
///         want their part of the hedge margin should wait for that return before calling `emergencyRedeem`.
abstract contract LPVaultBase is ERC20, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;

    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant MAX_HEDGE_CAP_BPS = 5_000;
    uint256 public constant MAX_POOL_BAND_BPS = 500;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant MAX_HEDGE_STEP_BPS = 2_000;
    uint256 public constant MAX_REF_DRIFT_BPS = 3_000;
    uint256 public constant MAX_TURNOVER_BPS = 50_000;
    uint256 public constant SETTLE_TIMEOUT = 72 hours;
    uint256 public constant EMERGENCY_FORCE_DELAY = 7 days;
    uint256 public constant EMERGENCY_BAND_BPS = 1_000;

    // ------------------------------------------------------------------ immutables
    IERC20 public immutable asset;
    /// Base token of the pair (address(0) = native gas token, e.g. HYPE on Elysium).
    address public immutable baseToken;
    /// Optional wrapped form of the base token also counted as base (e.g. WHYPE when base is native). 0 = none.
    address public immutable wrappedBase;
    /// The only address hedge margin can ever be sent to. 0 = unhedged strategy.
    address public immutable hedgeTreasury;
    uint8 private immutable _assetDecimals;

    // ------------------------------------------------------------------ config
    struct Params {
        uint16 feeBps;
        uint16 hedgeCapBps;
        uint16 poolBandBps;
        uint16 maxSlippageBps;
        uint16 hedgeStepBps;
        uint16 refDriftBps;
        uint32 swapTurnoverBps;
        uint256 minDeposit;
    }

    Params public params;
    address public keeper;
    address public guardian;
    address public feeRecipient;
    bool public paused;
    bool public emergency;

    // ------------------------------------------------------------------ accounting
    struct DepositRequest {
        address owner;
        uint256 assets;
    }

    struct RedeemRequest {
        address owner;
        uint256 shares;
    }

    struct Report {
        uint256 epoch; // must equal `epoch` (replay / double-submit guard)
        uint256 price; // asset raw units per 1e18 raw units of base token
        uint256 hedgeEquity; // off-chain hedge account equity in asset raw units
        uint256 maxDeposits; // queue items to process this call (gas bound)
        uint256 maxRedeems;
    }

    mapping(uint256 => DepositRequest) public depositRequests;
    mapping(uint256 => RedeemRequest) public redeemRequests;
    uint256 public depositHead;
    uint256 public depositTail;
    uint256 public redeemHead;
    uint256 public redeemTail;

    uint256 public pendingDepositAssets; // asset held for queued deposits (not part of NAV)
    uint256 public lockedShares; // shares held by the vault for queued redeems
    uint256 public totalClaimable; // asset owed to redeemers whose push transfer failed
    mapping(address => uint256) public claimable;

    uint256 public hedgeEquity;
    uint256 public highWaterMark; // price per share, WAD-scaled assets per share unit
    uint256 public lastNav;
    uint256 public lastPrice;
    uint256 public lastSettleTime;
    uint256 public epoch;
    uint256 public swapNotionalUsed; // swap notional in the current rolling-day window
    uint256 public swapWindowStart;

    uint256 public approvedHedgeEquity;
    uint256 public approvedHedgeEpoch; // epoch + 1 when set (0 = none)
    uint256 public hedgeDriftStart; // rolling-day window for reported hedge equity drift
    uint256 public hedgeDriftUsed;

    // ------------------------------------------------------------------ events
    event DepositRequested(uint256 indexed id, address indexed owner, uint256 assets);
    event DepositCancelled(uint256 indexed id, address indexed owner, uint256 assets);
    event Deposited(uint256 indexed id, address indexed owner, uint256 assets, uint256 shares);
    event RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event Redeemed(uint256 indexed id, address indexed owner, uint256 shares, uint256 assets, bool pushed);
    event Claimed(address indexed owner, uint256 assets);
    event Settled(uint256 indexed epoch, uint256 nav, uint256 price, uint256 hedgeEquity, uint256 feeShares, uint256 pps);
    event HedgeMarginSent(uint256 amount, uint256 hedgeEquity);
    event HedgeMarginReturned(uint256 amount, uint256 hedgeEquity);
    event HedgeEquityApproved(uint256 indexed epoch, uint256 value);
    event Paused(bool paused, address indexed by);
    event EmergencyUnwind(address indexed by);
    event EmergencyRedeemed(address indexed owner, address to, uint256 shares, uint256 assetOut, uint256 baseOut, uint256 wrappedOut);
    event ParamsSet(Params p);
    event RoleSet(bytes32 indexed role, address account);

    // ------------------------------------------------------------------ errors
    error NotKeeper();
    error NotGuardian();
    error IsPaused();
    error InEmergency();
    error NotEmergency();
    error ZeroAmount();
    error BelowMinDeposit();
    error BadEpoch();
    error BadPrice();
    error PoolPriceOff(uint256 poolPrice, uint256 keeperPrice);
    error HedgeEquityJump(uint256 oldValue, uint256 newValue);
    error HedgeCap(uint256 after_, uint256 cap);
    error NoHedge();
    error NotRequestOwner();
    error TooEarly();
    error ReserveBreached();
    error TransferFailed();
    error BadParam();
    error Turnover();

    // ------------------------------------------------------------------ construction
    struct BaseConfig {
        IERC20 asset;
        address baseToken;
        address wrappedBase;
        address hedgeTreasury;
        address owner;
        address keeper;
        address guardian;
        address feeRecipient;
        string name;
        string symbol;
        Params params;
    }

    constructor(BaseConfig memory c) ERC20(c.name, c.symbol) Ownable(c.owner) {
        if (address(c.asset).code.length == 0) revert BadParam();
        if (c.keeper == address(0) || c.guardian == address(0) || c.feeRecipient == address(0)) revert BadParam();
        if (c.hedgeTreasury == address(this)) revert BadParam();
        asset = c.asset;
        baseToken = c.baseToken;
        wrappedBase = c.wrappedBase;
        hedgeTreasury = c.hedgeTreasury;
        _assetDecimals = IERC20Metadata(address(c.asset)).decimals();
        keeper = c.keeper;
        guardian = c.guardian;
        feeRecipient = c.feeRecipient;
        _setParams(c.params);
        highWaterMark = Math.mulDiv(1, WAD, VIRTUAL_SHARES);
        lastSettleTime = block.timestamp;
    }

    receive() external payable {}

    // ------------------------------------------------------------------ modifiers
    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier notEmergency() {
        if (emergency) revert InEmergency();
        _;
    }

    // ------------------------------------------------------------------ venue hooks
    /// @dev Pool spot price, asset raw units per 1e18 base raw units.
    function _poolPrice() internal view virtual returns (uint256);
    /// @dev Base and asset amounts held in LP positions (principal at current pool price + uncollected fees).
    function _positionAmounts() internal view virtual returns (uint256 baseAmt, uint256 assetAmt);
    /// @dev Remove all liquidity into tokens held by the vault. Must not revert on a single bad position.
    function _unwindAll() internal virtual;
    /// @dev Number of LP positions still open.
    function _positionCount() internal view virtual returns (uint256);

    // ------------------------------------------------------------------ views
    function decimals() public view override returns (uint8) {
        return _assetDecimals + DECIMALS_OFFSET;
    }

    function idleAsset() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        uint256 reserved = pendingDepositAssets + totalClaimable;
        return bal > reserved ? bal - reserved : 0;
    }

    function idleBase() public view returns (uint256 amt) {
        amt = baseToken == address(0) ? address(this).balance : IERC20(baseToken).balanceOf(address(this));
        if (wrappedBase != address(0)) amt += IERC20(wrappedBase).balanceOf(address(this));
    }

    function poolPrice() external view returns (uint256) {
        return _poolPrice();
    }

    function positionAmounts() external view returns (uint256 baseAmt, uint256 assetAmt) {
        return _positionAmounts();
    }

    /// @notice NAV at `price` with the currently stored hedge equity.
    function grossAssets(uint256 price) public view returns (uint256) {
        (uint256 b, uint256 a) = _positionAmounts();
        return idleAsset() + a + Math.mulDiv(idleBase() + b, price, WAD) + hedgeEquity;
    }

    /// @notice Price per share at the last settlement (WAD-scaled asset units per share unit).
    function lastPricePerShare() public view returns (uint256) {
        return _pps(lastNav, totalSupply());
    }

    /// @notice Asset value of `shares` at the last settled NAV (indicative; the real price is set at settlement).
    function previewRedeemLast(uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, lastNav + 1, totalSupply() + VIRTUAL_SHARES);
    }

    function previewDepositLast(uint256 assets) external view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, lastNav + 1);
    }

    function pendingDeposits() external view returns (uint256) {
        return depositTail - depositHead;
    }

    function pendingRedeems() external view returns (uint256) {
        return redeemTail - redeemHead;
    }

    function hedgeCap() public view returns (uint256) {
        return Math.mulDiv(lastNav, params.hedgeCapBps, BPS);
    }

    function canEmergencyUnwind() public view returns (bool) {
        return emergency || block.timestamp > lastSettleTime + SETTLE_TIMEOUT;
    }

    // ------------------------------------------------------------------ client: deposits
    /// @notice Queue a deposit using an EIP-2612 permit (1 signature + 1 tx). If the permit was front-run and the
    ///         allowance already exists the call still succeeds.
    function requestDepositWithPermit(uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 id)
    {
        try IERC20Permit(address(asset)).permit(msg.sender, address(this), assets, deadline, v, r, s) {} catch {}
        return _requestDeposit(assets);
    }

    function requestDeposit(uint256 assets) external nonReentrant returns (uint256 id) {
        return _requestDeposit(assets);
    }

    function _requestDeposit(uint256 assets) internal whenNotPaused notEmergency returns (uint256 id) {
        if (assets == 0) revert ZeroAmount();
        if (assets < params.minDeposit) revert BelowMinDeposit();
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        if (asset.balanceOf(address(this)) - before != assets) revert TransferFailed();
        id = depositTail++;
        depositRequests[id] = DepositRequest(msg.sender, assets);
        pendingDepositAssets += assets;
        emit DepositRequested(id, msg.sender, assets);
    }

    /// @notice Cancel a queued deposit and get the asset back. Never paused; works in emergency too.
    function cancelDeposit(uint256 id) external nonReentrant {
        DepositRequest storage d = depositRequests[id];
        if (d.owner != msg.sender) revert NotRequestOwner();
        uint256 a = d.assets;
        if (a == 0) revert ZeroAmount();
        d.assets = 0;
        pendingDepositAssets -= a;
        asset.safeTransfer(msg.sender, a);
        emit DepositCancelled(id, msg.sender, a);
    }

    // ------------------------------------------------------------------ client: redeems
    /// @notice Lock `shares` for redemption at the next settlement; USDC is pushed to the caller. Never paused.
    function requestRedeem(uint256 shares) external nonReentrant notEmergency returns (uint256 id) {
        if (shares == 0) revert ZeroAmount();
        _transfer(msg.sender, address(this), shares);
        lockedShares += shares;
        id = redeemTail++;
        redeemRequests[id] = RedeemRequest(msg.sender, shares);
        emit RedeemRequested(id, msg.sender, shares);
    }

    /// @notice Only in emergency wind-down: unlock a queued redeem so the owner can `emergencyRedeem`.
    function cancelRedeem(uint256 id) external nonReentrant {
        if (!emergency) revert NotEmergency();
        RedeemRequest storage q = redeemRequests[id];
        if (q.owner != msg.sender) revert NotRequestOwner();
        uint256 sh = q.shares;
        if (sh == 0) revert ZeroAmount();
        q.shares = 0;
        lockedShares -= sh;
        _transfer(address(this), msg.sender, sh);
        emit RedeemCancelled(id, msg.sender, sh);
    }

    /// @notice Pull asset owed from a redemption whose push transfer failed.
    function claim() external nonReentrant {
        uint256 a = claimable[msg.sender];
        if (a == 0) revert ZeroAmount();
        claimable[msg.sender] = 0;
        totalClaimable -= a;
        asset.safeTransfer(msg.sender, a);
        emit Claimed(msg.sender, a);
    }

    // ------------------------------------------------------------------ keeper: settlement
    /// @notice Apply a fresh NAV, take the performance fee, process queued deposits and redeems.
    /// @dev    Allowed while paused (then only redeems are processed) so a pause never blocks exits.
    function settle(Report calldata r) external nonReentrant onlyKeeper notEmergency {
        if (r.epoch != epoch) revert BadEpoch();
        _checkPoolBand(r.price);
        _checkHedgeEquity(r.hedgeEquity);
        hedgeEquity = r.hedgeEquity;

        uint256 nav = grossAssets(r.price);
        uint256 supply = totalSupply();
        uint256 feeShares = _accrueFee(nav, supply);
        supply += feeShares;

        if (!paused) (nav, supply) = _processDeposits(r.maxDeposits, nav, supply);
        (nav, supply) = _processRedeems(r.maxRedeems, nav, supply);

        lastNav = nav;
        lastPrice = r.price;
        lastSettleTime = block.timestamp;
        emit Settled(epoch, nav, r.price, r.hedgeEquity, feeShares, _pps(nav, supply));
        epoch++;
    }

    function _pps(uint256 nav, uint256 supply) internal pure returns (uint256) {
        return Math.mulDiv(nav + 1, WAD, supply + VIRTUAL_SHARES);
    }

    function _accrueFee(uint256 nav, uint256 supply) internal returns (uint256 feeShares) {
        uint256 pps = _pps(nav, supply);
        uint256 hwm = highWaterMark;
        if (supply == 0) {
            highWaterMark = pps; // nobody to charge; restart the mark
            return 0;
        }
        if (pps <= hwm) return 0;
        uint256 gain = Math.mulDiv(pps - hwm, supply, WAD);
        uint256 feeAssets = Math.mulDiv(gain, params.feeBps, BPS);
        if (feeAssets != 0 && feeAssets < nav) {
            feeShares = Math.mulDiv(feeAssets, supply + VIRTUAL_SHARES, nav + 1 - feeAssets);
            if (feeShares != 0) _mint(feeRecipient, feeShares);
        }
        uint256 newPps = _pps(nav, supply + feeShares);
        highWaterMark = newPps > hwm ? newPps : hwm;
    }

    function _processDeposits(uint256 max, uint256 nav, uint256 supply) internal returns (uint256, uint256) {
        uint256 head = depositHead;
        uint256 end = depositTail;
        if (end - head > max) end = head + max;
        for (; head < end; ++head) {
            DepositRequest storage d = depositRequests[head];
            uint256 a = d.assets;
            if (a == 0) continue; // cancelled
            uint256 sh = Math.mulDiv(a, supply + VIRTUAL_SHARES, nav + 1);
            d.assets = 0;
            pendingDepositAssets -= a;
            nav += a;
            if (sh != 0) {
                supply += sh;
                _mint(d.owner, sh);
            }
            emit Deposited(head, d.owner, a, sh);
        }
        depositHead = head;
        return (nav, supply);
    }

    function _processRedeems(uint256 max, uint256 nav, uint256 supply) internal returns (uint256, uint256) {
        uint256 head = redeemHead;
        uint256 end = redeemTail;
        if (end - head > max) end = head + max;
        uint256 idle = idleAsset();
        for (; head < end; ++head) {
            RedeemRequest storage q = redeemRequests[head];
            uint256 sh = q.shares;
            if (sh == 0) continue;
            uint256 a = Math.mulDiv(sh, nav + 1, supply + VIRTUAL_SHARES);
            if (a > nav) a = nav;
            if (a > idle) break; // FIFO: wait for the keeper to free liquidity
            q.shares = 0;
            lockedShares -= sh;
            _burn(address(this), sh);
            supply -= sh;
            nav -= a;
            idle -= a;
            bool pushed = true;
            if (a != 0 && !asset.trySafeTransfer(q.owner, a)) {
                pushed = false;
                claimable[q.owner] += a;
                totalClaimable += a;
            }
            emit Redeemed(head, q.owner, sh, a, pushed);
        }
        redeemHead = head;
        return (nav, supply);
    }

    function _checkPoolBand(uint256 price) internal view {
        if (price == 0) revert BadPrice();
        uint256 p = _poolPrice();
        uint256 diff = p > price ? p - price : price - p;
        if (diff * BPS > price * params.poolBandBps) revert PoolPriceOff(p, price);
    }

    /// @dev The reported off-chain equity may drift (in absolute terms, summed) by at most `hedgeStepBps` of the last
    ///      NAV per rolling day, so a compromised keeper cannot compound small jumps over many quick settlements.
    ///      Larger moves need the guardian's exact co-confirmation for this epoch (which does not consume budget).
    function _checkHedgeEquity(uint256 v) internal {
        uint256 old = hedgeEquity;
        uint256 diff = v > old ? v - old : old - v;
        if (diff == 0) return;
        if (block.timestamp >= hedgeDriftStart + 1 days) {
            hedgeDriftStart = block.timestamp;
            hedgeDriftUsed = 0;
        }
        uint256 used = hedgeDriftUsed + diff;
        if (used * BPS <= lastNav * params.hedgeStepBps) {
            hedgeDriftUsed = used;
            return;
        }
        if (approvedHedgeEpoch == epoch + 1 && approvedHedgeEquity == v) {
            approvedHedgeEpoch = 0;
            return;
        }
        revert HedgeEquityJump(old, v);
    }

    /// @dev Keeper-supplied price for an LP/swap action: near the pool and near the last settled price.
    function _checkKeeperPrice(uint256 price) internal view {
        _checkPoolBand(price);
        uint256 ref = lastPrice;
        if (ref == 0) return; // before the first settlement there is no NAV to protect
        uint256 diff = price > ref ? price - ref : ref - price;
        if (diff * BPS > ref * params.refDriftBps) revert BadPrice();
    }

    /// @dev After any keeper action: queued deposits and unpaid claims stay fully backed.
    function _checkReserve() internal view {
        if (asset.balanceOf(address(this)) < pendingDepositAssets + totalClaimable) revert ReserveBreached();
    }

    /// @dev Rolling-day window (not per settlement): settling is free for the keeper, so a per-epoch budget could
    ///      be reset at will by settling with empty queues between swaps.
    function _useTurnover(uint256 notional) internal {
        uint256 used = notional;
        if (block.timestamp < swapWindowStart + 1 days) used += swapNotionalUsed;
        else swapWindowStart = block.timestamp;
        if (used * BPS > lastNav * params.swapTurnoverBps) revert Turnover();
        swapNotionalUsed = used;
    }

    // ------------------------------------------------------------------ keeper: hedge margin
    /// @notice Send hedge margin to the fixed `hedgeTreasury`; total outstanding margin <= hedgeCapBps of last NAV.
    function sendHedgeMargin(uint256 amount) external nonReentrant onlyKeeper whenNotPaused notEmergency {
        if (hedgeTreasury == address(0)) revert NoHedge();
        if (amount == 0) revert ZeroAmount();
        uint256 after_ = hedgeEquity + amount;
        uint256 cap = hedgeCap();
        if (after_ > cap) revert HedgeCap(after_, cap);
        hedgeEquity = after_;
        asset.safeTransfer(hedgeTreasury, amount);
        _checkReserve();
        emit HedgeMarginSent(amount, after_);
    }

    /// @notice Pull hedge margin back from `hedgeTreasury` (which must approve the vault). Keeper or treasury.
    ///         Never paused; works in emergency (that is how the off-chain part reaches holders).
    function returnHedgeMargin(uint256 amount) external nonReentrant {
        if (msg.sender != keeper && msg.sender != hedgeTreasury) revert NotKeeper();
        if (amount == 0) revert ZeroAmount();
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(hedgeTreasury, address(this), amount);
        if (asset.balanceOf(address(this)) - before != amount) revert TransferFailed();
        uint256 h = hedgeEquity;
        hedgeEquity = amount >= h ? 0 : h - amount;
        emit HedgeMarginReturned(amount, hedgeEquity);
    }

    // ------------------------------------------------------------------ guardian
    function setPaused(bool p) external {
        if (p) {
            if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        } else {
            _checkOwner();
        }
        paused = p;
        emit Paused(p, msg.sender);
    }

    /// @notice Guardian co-confirms an off-chain hedge equity jump larger than `hedgeStepBps` for the current epoch.
    function approveHedgeEquity(uint256 value) external {
        if (msg.sender != guardian) revert NotGuardian();
        approvedHedgeEquity = value;
        approvedHedgeEpoch = epoch + 1;
        emit HedgeEquityApproved(epoch, value);
    }

    // ------------------------------------------------------------------ owner
    function setKeeper(address k) external onlyOwner {
        if (k == address(0)) revert BadParam();
        keeper = k;
        emit RoleSet("keeper", k);
    }

    function setGuardian(address g) external onlyOwner {
        if (g == address(0)) revert BadParam();
        guardian = g;
        emit RoleSet("guardian", g);
    }

    function setFeeRecipient(address f) external onlyOwner {
        if (f == address(0) || f == address(this)) revert BadParam();
        feeRecipient = f;
        emit RoleSet("feeRecipient", f);
    }

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function _setParams(Params memory p) internal {
        if (
            p.feeBps > MAX_FEE_BPS || p.hedgeCapBps > MAX_HEDGE_CAP_BPS || p.poolBandBps > MAX_POOL_BAND_BPS
                || p.poolBandBps == 0 || p.maxSlippageBps > MAX_SLIPPAGE_BPS || p.hedgeStepBps > MAX_HEDGE_STEP_BPS
                || p.refDriftBps > MAX_REF_DRIFT_BPS || p.swapTurnoverBps > MAX_TURNOVER_BPS
                || p.minDeposit > 100 * 10 ** _assetDecimals
        ) revert BadParam();
        if (hedgeTreasury == address(0) && p.hedgeCapBps != 0) revert BadParam();
        params = p;
        emit ParamsSet(p);
    }

    // ------------------------------------------------------------------ emergency
    /// @notice Permissionless after 72 h without settlement. Removes all LP liquidity into tokens and starts the
    ///         permanent wind-down. Between 72 h and 7 days the pool price must be within 10% of the last settled
    ///         price (anti-manipulation); after 7 days no price condition. Can be called again to retry positions
    ///         that failed to unwind. See contract NatSpec for the hedge-treasury part.
    function emergencyUnwind() external nonReentrant {
        if (!emergency) {
            if (block.timestamp <= lastSettleTime + SETTLE_TIMEOUT) revert TooEarly();
            if (block.timestamp <= lastSettleTime + EMERGENCY_FORCE_DELAY && lastPrice != 0) {
                uint256 p = _poolPrice();
                uint256 diff = p > lastPrice ? p - lastPrice : lastPrice - p;
                if (diff * BPS > lastPrice * EMERGENCY_BAND_BPS) revert PoolPriceOff(p, lastPrice);
            }
            emergency = true;
            emit EmergencyUnwind(msg.sender);
        }
        if (_positionCount() != 0) _unwindAll();
    }

    /// @notice Wind-down exit: burn `shares` for a pro-rata part of every token the vault holds on-chain.
    function emergencyRedeem(uint256 shares, address to) external nonReentrant {
        if (!emergency) revert NotEmergency();
        if (shares == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this)) revert BadParam();
        // shares locked in queued redeems still count: their owners cancelRedeem and claim the same pro-rata part
        uint256 supply = totalSupply();
        uint256 aOut = Math.mulDiv(idleAsset(), shares, supply);
        uint256 bOut = Math.mulDiv(
            baseToken == address(0) ? address(this).balance : IERC20(baseToken).balanceOf(address(this)), shares, supply
        );
        uint256 wOut = wrappedBase == address(0)
            ? 0
            : Math.mulDiv(IERC20(wrappedBase).balanceOf(address(this)), shares, supply);
        _burn(msg.sender, shares);
        if (aOut != 0) asset.safeTransfer(to, aOut);
        if (wOut != 0) IERC20(wrappedBase).safeTransfer(to, wOut);
        if (bOut != 0) {
            if (baseToken == address(0)) {
                (bool ok,) = to.call{value: bOut}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(baseToken).safeTransfer(to, bOut);
            }
        }
        emit EmergencyRedeemed(msg.sender, to, shares, aOut, bOut, wOut);
    }
}
