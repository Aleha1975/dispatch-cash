// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RiskBudgets} from "./RiskBudgets.sol";

/// @title LPVaultBase
/// @notice Venue-independent core of a client-facing (optionally hedged) LP vault with asynchronous, keeper-settled
///         deposits and redemptions (ERC-7540 style). One deployment = one strategy (one pool, one hedge treasury).
///
///         CLIENT FLOW
///         - Enter: `requestDepositWithPermit` (1 off-chain signature + 1 tx) or approve + `requestDeposit`. The USDC is
///           pulled into the vault at once and queued. Until the next settlement the client may `cancelDeposit`.
///         - Exit: `requestRedeem(shares)` (1 tx). The shares are locked in the vault. At the next settlement the
///           keeper prices them at a fresh NAV, burns them and PUSHES the USDC to the client: no claim tx. If the
///           vault lacks idle USDC the head request is paid partially with all idle USDC and the rest stays queued
///           (FIFO) until the keeper frees liquidity.
///         - There is no absolute withdrawal limit of any kind.
///
///         PRICE ANCHOR. `lastPrice` is the only price the vault trusts. Only `settle` moves it, toward the keeper's
///         report, by at most `refDriftBps` of cumulative movement per (decaying) day, and not at all while paused,
///         unless the guardian approved a price range for the report. Swaps and LP adds must quote within
///         `poolBandBps` of both the pool and the anchor; LP adds are valued at the anchor and count as turnover.
///
///         NAV (see `grossAssets`): idle asset (excluding queued deposits and unpaid claims) + idle base token valued at
///         the anchored settlement price + LP positions (amounts from the pool's current sqrtPrice, valued at the same
///         price) + the off-chain hedge equity. The keeper alone may only LOWER the hedge equity (at most
///         `hedgeStepBps` of the last NAV per decaying day); raising it needs the guardian's co-signature. A report
///         that the price or hedge budgets had to clip is applied conservatively: the clipped values are used, no
///         deposits are processed and no fee is taken in that settlement; redemptions are always processed.
///
///         FEES: `feeBps` (default 15%, hard cap 20%) of the gain of price-per-share above the high-water mark, taken
///         at settlement by minting shares to `feeRecipient`. The HWM never decreases while shares exist (it restarts
///         from the current pps after a full exit).
///
///         ROLES: owner (timelock; sets keeper/guardian/fee recipient and bounded parameters, can never move funds),
///         keeper (settles, manages LP and hedge margin through allowlisted, relatively bounded calls only),
///         guardian (pauses new deposits and risk-increasing keeper actions, freezes the price anchor and fees while
///         paused, co-signs hedge equity increases and price moves beyond the budget; can never move funds). Pause
///         never blocks redemptions, cancellations, liquidity removal, hedge sends/returns.
///
///         LIVENESS: if the redeem queue makes no progress (nothing paid while requests are pending) for
///         `SETTLE_TIMEOUT` (72 h) after the first settlement, anyone may arm `emergencyUnwind()` and execute it
///         `UNWIND_NOTICE` later unless a settlement made progress in between. It removes all LP liquidity into tokens
///         and switches the vault into permanent wind-down. Holders (and holders of queued redeem requests, after
///         `cancelRedeem`) then `emergencyRedeem` a pro-rata share of every token the vault holds on-chain. The hedge
///         margin sitting at `hedgeTreasury` (on Hyperliquid) is NOT on-chain: it is the keeper operator's off-chain
///         obligation to close the hedge and send that USDC back with `returnHedgeMargin`, after which it is
///         distributed pro-rata to the shares still outstanding.
abstract contract LPVaultBase is ERC20, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;

    // hard caps for `setParams` (fee 20%, hedge cap 50%, pool band 5%, slippage 5%, hedge step 20%/day, anchor drift
    // 20%/day, turnover 5x NAV/day)
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 internal constant MAX_HEDGE_CAP_BPS = 5_000;
    uint256 internal constant MAX_POOL_BAND_BPS = 500;
    uint256 internal constant MAX_SLIPPAGE_BPS = 500;
    uint256 internal constant MAX_HEDGE_STEP_BPS = 2_000;
    uint256 internal constant MAX_REF_DRIFT_BPS = 2_000;
    uint256 internal constant MAX_TURNOVER_BPS = 50_000;
    uint256 public constant SETTLE_TIMEOUT = 72 hours;
    uint256 public constant UNWIND_NOTICE = 6 hours;
    uint256 public constant EMERGENCY_GRACE = 7 days;

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
        uint16 hedgeStepBps; // keeper-only hedge equity decrease budget, of last NAV per decaying day
        uint16 refDriftBps; // price anchor movement budget per decaying day
        uint32 swapTurnoverBps; // swap + LP-add notional budget, of last NAV per decaying day
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
    uint256 public lockedShares; // shares held by the vault for queued redeems (== balanceOf(this))
    uint256 public totalClaimable; // asset owed to clients whose push transfer failed
    mapping(address => uint256) public claimable;

    uint256 public hedgeEquity;
    uint256 public netMargin; // margin sent to hedgeTreasury minus margin returned (floored at 0)
    uint256 public highWaterMark; // price per share, WAD-scaled assets per share unit
    uint256 public lastNav;
    uint256 public lastPrice; // the price anchor (see contract NatSpec)
    uint256 public lastSettleTime;
    uint256 public lastProgressTime; // last settlement after which the redeem queue was empty or had been paid from
    uint256 public epoch;

    /// Decaying-day budgets for anchor movement, keeper-only hedge decreases and turnover, and the guardian's
    /// co-signatures (see RiskBudgets).
    RiskBudgets.Budgets public budgets;

    uint256 public unwindArmedAt;
    uint256 public emergencySince;

    // ------------------------------------------------------------------ events
    event DepositRequested(uint256 indexed id, address indexed owner, uint256 assets);
    event DepositCancelled(uint256 indexed id, address indexed owner, uint256 assets);
    event Deposited(uint256 indexed id, address indexed owner, uint256 assets, uint256 shares);
    event RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event Redeemed(uint256 indexed id, address indexed owner, uint256 shares, uint256 assets, bool pushed);
    event Claimed(address indexed owner, uint256 assets);
    /// `price` and `hedgeEquity` are the values APPLIED (after the anchor / hedge budgets); compare with the report
    /// to detect a clipped settlement (which processed no deposits and took no fee).
    event Settled(uint256 indexed epoch, uint256 nav, uint256 price, uint256 hedgeEquity, uint256 feeShares, uint256 pps);
    event HedgeMarginSent(uint256 amount, uint256 hedgeEquity);
    event HedgeMarginReturned(uint256 amount, uint256 hedgeEquity);
    event HedgeEquityApproved(uint256 indexed epoch, uint256 value, uint256 until);
    event PriceApproved(uint256 lo, uint256 hi, uint256 until);
    event Paused(bool paused, address indexed by);
    event EmergencyArmed(address indexed by);
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
    error HedgeCap(uint256 after_, uint256 cap);
    error NoHedge();
    error NotRequestOwner();
    error TooEarly();
    error ReserveBreached();
    error TransferFailed();
    error BadParam();
    error PositionsOpen();
    error AddValue(uint256 got, uint256 paid);

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
        if (c.wrappedBase != address(0) && c.wrappedBase.code.length == 0) revert BadParam();
        if (c.keeper == address(0) || c.guardian == address(0) || c.keeper == c.guardian) revert BadParam();
        if (c.feeRecipient == address(0) || c.feeRecipient == address(this)) revert BadParam();
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

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
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
    function previewRedeemLast(uint256 shares) public view returns (uint256) {
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
        return emergency || (epoch != 0 && block.timestamp > lastProgressTime + SETTLE_TIMEOUT);
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
        if (assets < params.minDeposit) revert BelowMinDeposit();
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        if (asset.balanceOf(address(this)) - before != assets) revert TransferFailed();
        id = depositTail++;
        depositRequests[id] = DepositRequest(msg.sender, assets);
        pendingDepositAssets += assets;
        emit DepositRequested(id, msg.sender, assets);
    }

    /// @notice Cancel a queued deposit and get the asset back. Never paused; works in emergency too. If the transfer
    ///         to the owner fails (e.g. a blocked address) the amount becomes `claimable` (see `claimTo`).
    function cancelDeposit(uint256 id) external nonReentrant {
        DepositRequest storage d = depositRequests[id];
        if (d.owner != msg.sender) revert NotRequestOwner();
        uint256 a = d.assets;
        if (a == 0) revert ZeroAmount();
        d.assets = 0;
        pendingDepositAssets -= a;
        _pay(msg.sender, a);
        emit DepositCancelled(id, msg.sender, a);
    }

    // ------------------------------------------------------------------ client: redeems
    /// @notice Lock `shares` for redemption at the next settlement; USDC is pushed to the caller. Never paused.
    function requestRedeem(uint256 shares) external nonReentrant notEmergency returns (uint256 id) {
        if (previewRedeemLast(shares) == 0) revert ZeroAmount(); // dust that would burn for nothing
        super._update(msg.sender, address(this), shares); // the only way shares enter the vault
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

    /// @notice Pull asset owed from a redemption / cancellation whose push transfer failed.
    function claim() external {
        claimTo(msg.sender);
    }

    /// @notice Same as `claim`, paid to `to` (e.g. when the owner's address is blocked by the asset).
    function claimTo(address to) public nonReentrant {
        if (to == address(0) || to == address(this)) revert BadParam();
        uint256 a = claimable[msg.sender];
        if (a == 0) revert ZeroAmount();
        claimable[msg.sender] = 0;
        totalClaimable -= a;
        asset.safeTransfer(to, a);
        emit Claimed(msg.sender, a);
    }

    /// @dev Push `a` asset to `to`; on failure reserve it as `claimable[to]`. Returns false if it was not pushed.
    function _pay(address to, uint256 a) internal returns (bool) {
        if (a == 0 || asset.trySafeTransfer(to, a)) return true;
        claimable[to] += a;
        totalClaimable += a;
        return false;
    }

    // ------------------------------------------------------------------ keeper: settlement
    /// @notice Apply a fresh NAV, take the performance fee, process queued deposits and redeems.
    /// @dev    Allowed while paused so a pause never blocks exits; then the anchor and fees are frozen and only
    ///         redeems are processed. A clipped report never reverts: it processes redeems only.
    function settle(Report calldata r) external nonReentrant onlyKeeper notEmergency {
        if (r.epoch != epoch) revert BadEpoch();
        _checkPoolBand(r.price);
        (uint256 price, bool clipped) =
            RiskBudgets.movePrice(budgets, lastPrice, r.price, paused ? 0 : uint256(params.refDriftBps) * (WAD / BPS));
        bool hClipped;
        (hedgeEquity, hClipped) = _hedgeFor(r.hedgeEquity);

        uint256 nav = grossAssets(price);
        uint256 supply = totalSupply();
        uint256 feeShares;
        if (!(clipped || hClipped || paused)) {
            feeShares = _accrueFee(nav, supply);
            supply += feeShares;
            (nav, supply) = _processDeposits(r.maxDeposits, nav, supply);
        }
        uint256 locked0 = lockedShares;
        (nav, supply) = _processRedeems(r.maxRedeems, nav, supply);
        if (lockedShares < locked0 || redeemHead == redeemTail) lastProgressTime = block.timestamp;

        lastNav = nav;
        lastPrice = price;
        lastSettleTime = block.timestamp;
        emit Settled(epoch, nav, price, hedgeEquity, feeShares, _pps(nav, supply));
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
            if (sh != 0) {
                nav += a;
                supply += sh;
                _mint(d.owner, sh);
            } else {
                // would buy nothing: refund instead of donating it to the holders
                claimable[d.owner] += a;
                totalClaimable += a;
            }
            emit Deposited(head, d.owner, a, sh);
        }
        depositHead = head;
        return (nav, supply);
    }

    /// @dev FIFO. The head request is paid partially with all idle asset if it cannot be paid in full; the rest of
    ///      it stays at the head.
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
            uint256 burnSh = sh;
            if (a > idle) {
                burnSh = Math.mulDiv(sh, idle, a);
                a = Math.mulDiv(burnSh, nav + 1, supply + VIRTUAL_SHARES);
                if (a == 0) break;
            }
            q.shares = sh - burnSh;
            lockedShares -= burnSh;
            _burn(address(this), burnSh);
            supply -= burnSh;
            nav -= a;
            idle -= a;
            emit Redeemed(head, q.owner, burnSh, a, _pay(q.owner, a));
            if (burnSh != sh) break; // partially filled head: wait for more liquidity
        }
        redeemHead = head;
        return (nav, supply);
    }

    function _checkPoolBand(uint256 price) internal view {
        if (price == 0) revert BadPrice();
        uint256 p = _poolPrice();
        if (_absDiff(p, price) * BPS > price * params.poolBandBps) revert PoolPriceOff(p, price);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev Keeper alone may only LOWER the off-chain equity, by at most `hedgeStepBps` of the last NAV (which never
    ///      includes this settlement's deposits) per decaying day; any increase needs the guardian's co-signature.
    ///      Margin moved by `sendHedgeMargin`/`returnHedgeMargin` is applied directly and is not a "move".
    function _hedgeFor(uint256 v) internal returns (uint256, bool) {
        uint256 old = hedgeEquity;
        if (v == old) return (v, false);
        if (hedgeTreasury == address(0)) revert NoHedge();
        return RiskBudgets.moveHedge(budgets, old, v, epoch, Math.mulDiv(lastNav, params.hedgeStepBps, BPS));
    }

    /// @dev Keeper-supplied price for an LP/swap action: within `poolBandBps` of the pool AND of the price anchor.
    function _checkKeeperPrice(uint256 price) internal view {
        _checkPoolBand(price);
        uint256 ref = lastPrice;
        if (ref != 0 && _absDiff(price, ref) * BPS > ref * params.poolBandBps) revert BadPrice();
    }

    /// @dev Value of an LP add at the anchor: what the position is worth must be within `maxSlippageBps` of what the
    ///      vault paid, and the paid value counts against the turnover budget (an add is a swap in effect).
    function _checkAdd(uint256 got, uint256 paid) internal {
        uint256 s = params.maxSlippageBps;
        if (got * BPS < paid * (BPS - s)) revert AddValue(got, paid);
        // turnover counts loss exposure in swap units (band + slippage per unit); an add can lose only `s` per unit
        _useTurnover(Math.mulDiv(paid, s, s + params.poolBandBps, Math.Rounding.Ceil));
    }

    /// @dev Asset-denominated value at `price` of the asset and base the vault holds (raw balances).
    function _heldValue(uint256 price) internal view returns (uint256) {
        uint256 b = baseToken == address(0) ? address(this).balance : IERC20(baseToken).balanceOf(address(this));
        return asset.balanceOf(address(this)) + Math.mulDiv(b, price, WAD);
    }

    /// @dev After any keeper action: queued deposits and unpaid claims stay fully backed.
    function _checkReserve() internal view {
        if (asset.balanceOf(address(this)) < pendingDepositAssets + totalClaimable) revert ReserveBreached();
    }

    /// @dev Decaying-day budget (not per settlement: settling is free for the keeper).
    function _useTurnover(uint256 notional) internal {
        RiskBudgets.useTurnover(budgets, notional, Math.mulDiv(lastNav, params.swapTurnoverBps, BPS));
    }

    // ------------------------------------------------------------------ keeper: hedge margin
    /// @notice Send hedge margin to the fixed `hedgeTreasury`. max(reported equity, net margin outstanding) after the
    ///         send must stay <= hedgeCapBps of last NAV. Allowed while paused (topping up a short is risk-reducing).
    function sendHedgeMargin(uint256 amount) external nonReentrant onlyKeeper notEmergency {
        if (hedgeTreasury == address(0)) revert NoHedge();
        if (amount == 0) revert ZeroAmount();
        uint256 h = hedgeEquity;
        uint256 m = netMargin;
        uint256 after_ = (h > m ? h : m) + amount;
        uint256 cap = hedgeCap();
        if (after_ > cap) revert HedgeCap(after_, cap);
        hedgeEquity = h + amount;
        netMargin = m + amount;
        budgets.hedgeApprovedEpoch = 0; // an approval was judged against the old baseline
        asset.safeTransfer(hedgeTreasury, amount);
        _checkReserve();
        emit HedgeMarginSent(amount, h + amount);
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
        uint256 m = netMargin;
        netMargin = amount >= m ? 0 : m - amount;
        budgets.hedgeApprovedEpoch = 0;
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

    /// @notice Guardian co-signs the exact off-chain hedge equity for the current epoch, valid until `until`.
    ///         Cleared by any margin send/return (it was judged against the old baseline) and when used.
    function approveHedgeEquity(uint256 value, uint256 until) external onlyGuardian {
        budgets.hedgeApproved = value;
        budgets.hedgeApprovedEpoch = epoch + 1;
        budgets.hedgeApprovedUntil = until;
        emit HedgeEquityApproved(epoch, value, until);
    }

    /// @notice Guardian vouches for settlement prices in [lo, hi] until `until`: such a report moves the anchor
    ///         without using the drift budget (also while paused). `until = 0` revokes.
    function approvePrice(uint256 lo, uint256 hi, uint256 until) external onlyGuardian {
        budgets.priceApprovedLo = lo;
        budgets.priceApprovedHi = hi;
        budgets.priceApprovedUntil = until;
        emit PriceApproved(lo, hi, until);
    }

    // ------------------------------------------------------------------ owner
    function setKeeper(address k) external onlyOwner {
        if (k == address(0) || k == guardian) revert BadParam();
        keeper = k;
        emit RoleSet("keeper", k);
    }

    function setGuardian(address g) external onlyOwner {
        if (g == address(0) || g == keeper) revert BadParam();
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

    /// @notice Disabled: without an owner a pause could never be lifted and a hostile keeper never rotated.
    function renounceOwnership() public pure override {
        revert BadParam();
    }

    function _setParams(Params memory p) internal {
        if (
            p.feeBps > MAX_FEE_BPS || p.hedgeCapBps > MAX_HEDGE_CAP_BPS || p.poolBandBps > MAX_POOL_BAND_BPS
                || p.poolBandBps == 0 || p.maxSlippageBps > MAX_SLIPPAGE_BPS || p.hedgeStepBps > MAX_HEDGE_STEP_BPS
                || p.refDriftBps > MAX_REF_DRIFT_BPS || p.swapTurnoverBps > MAX_TURNOVER_BPS || p.minDeposit == 0
                || p.minDeposit > 100 * 10 ** _assetDecimals
        ) revert BadParam();
        if (hedgeTreasury == address(0) && (p.hedgeCapBps != 0 || p.hedgeStepBps != 0)) revert BadParam();
        params = p;
        emit ParamsSet(p);
    }

    /// @dev Shares can enter the vault only through `requestRedeem` (they would otherwise be unrecoverable and
    ///      dilute every pro-rata payout).
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) revert BadParam();
        super._update(from, to, value);
    }

    // ------------------------------------------------------------------ emergency
    /// @notice Permissionless wind-down when the redeem queue made no progress for `SETTLE_TIMEOUT` after the first
    ///         settlement. Two steps: the first call arms it, a call `UNWIND_NOTICE` later executes it unless a
    ///         settlement made progress in between (protects against a sequencer outage being read as keeper
    ///         absence). Removes all LP liquidity into tokens; can be called again to retry failed positions.
    function emergencyUnwind() external nonReentrant {
        if (!emergency) {
            if (!canEmergencyUnwind()) revert TooEarly();
            uint256 armed = unwindArmedAt;
            if (armed <= lastProgressTime) {
                unwindArmedAt = block.timestamp;
                emit EmergencyArmed(msg.sender);
                return;
            }
            if (block.timestamp < armed + UNWIND_NOTICE) revert TooEarly();
            emergency = true;
            emergencySince = block.timestamp;
            emit EmergencyUnwind(msg.sender);
        }
        if (_positionCount() != 0) _unwindAll();
    }

    /// @notice Wind-down exit: burn `shares` for a pro-rata part of every token the vault holds on-chain. Refused
    ///         while LP positions are still open during the first `EMERGENCY_GRACE` (call `emergencyUnwind` again).
    ///         A failed asset transfer is credited to `claimable[to]` so the native/wrapped legs still go out.
    function emergencyRedeem(uint256 shares, address to) external nonReentrant {
        if (!emergency) revert NotEmergency();
        if (shares == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this)) revert BadParam();
        if (_positionCount() != 0 && block.timestamp < emergencySince + EMERGENCY_GRACE) revert PositionsOpen();
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
        _pay(to, aOut);
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
