// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {RiskBudgets} from "../RiskBudgets.sol";
import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {SALib} from "./SALib.sol";
import {ElysiumCustodyEnforcer} from "./ElysiumCustodyEnforcer.sol";
import {SwapExecutor} from "./SwapExecutor.sol";
import {
    Delegation,
    ModeCode,
    IDelegationManager,
    IHybridDeleGator,
    DelegationFramework
} from "./vendor/DelegationFramework.sol";

/// @title LPManagerModule
/// @notice The keeper's only delegate for per-client smart accounts (HybridDeleGator owned by the client EOA, or an
///         EOA upgraded with EIP-7702 to EIP7702StatelessDeleGator). Each client signs ONE root delegation
///         `account -> this module` with two caveats: ElysiumCustodyEnforcer (custody backstop) and the framework's
///         TimestampEnforcer (expiry). The keeper never submits executions: it calls this module, which BUILDS every
///         call itself with owner / recipient = the client account and redeems it through the DelegationManager.
///
///         Tokens and position NFTs never leave the client's account except: into the client's own v4 positions in
///         the fixed pool, into the fixed pool through SwapExecutor (which pays the account back), to the immutable
///         `hedgeTreasury` (hedge margin, <= hedgeCapBps of the account value) and to the immutable `feeRecipient`
///         (performance fee). The client can always act on its account directly and revoke the delegation
///         (`DelegationManager.disableDelegation`) with one transaction; nothing here can block that.
///
///         BUDGETS (audit round 1 constraints, now per account):
///         - one global price anchor `lastPrice`, moved only by `reportPrice` within `refDriftBps` per decaying
///           day (frozen while paused unless the guardian approves a range) (H-2, M-4, M-6, M-10);
///         - swaps and LP adds need a keeper price within `poolBandBps` of the pool AND the anchor; swaps carry
///           min-out and a sqrtPrice limit at the anchor band edge (L-15); an LP add is valued at the anchor and
///           must be worth >= paid x (1 - maxSlippageBps) (H-3); swap + add notional per account per decaying
///           day <= swapTurnoverBps x account value;
///         - hedge equity per account: the keeper alone can only lower it (hedgeStepBps of the account value per
///           decaying day); increases need the guardian's exact, expiring, account- and epoch-bound value, cleared
///           by margin moves (H-1, M-2, M-9); hedge sends need max(hedgeEquity, netMargin) + amount <=
///           hedgeCapBps x account value (M-5);
///         - fee: feeBps (15%, cap 20%) of the account's profit above its own high-water mark, at most once per
///           `feeInterval` (>= 7 days), only with a fresh unclipped anchor and not while paused.
///
///         CONTRIBUTIONS are measured on-chain: between two module actions on an account, any change of its idle
///         USDC / HYPE or of its tracked positions' liquidity can only come from the client (or a donor), so it is
///         booked as a contribution (+) or withdrawal (-) at the anchor. Module actions are bracketed by
///         `_sync` / `_snap`, so fees, swaps, LP moves and hedge margin moves are never mistaken for flows.
///
///         ROLES: owner = VaultTimelock (keeper/guardian rotation, bounded params; can never move client funds);
///         keeper (hot key, all actions above, multicall over many accounts); guardian (pause, price-range and
///         hedge-equity co-signatures; cannot unpause or move funds). keeper != guardian (L-13).
///         Pause stops mints, increases, swaps, fees and anchor movement; never decreases, burns, hedge margin
///         sends/returns, and never anything the client does directly (M-6, L-16).
contract LPManagerModule is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant MAX_HEDGE_CAP_BPS = 3_500;
    uint256 internal constant MAX_POOL_BAND_BPS = 500;
    uint256 internal constant MAX_SLIPPAGE_BPS = 500;
    uint256 internal constant MAX_HEDGE_STEP_BPS = 2_000;
    uint256 internal constant MAX_REF_DRIFT_BPS = 2_000;
    uint256 internal constant MAX_TURNOVER_BPS = 50_000;
    uint256 public constant MIN_FEE_INTERVAL = 7 days; // == ElysiumCustodyEnforcer.FEE_INTERVAL
    uint256 internal constant FEE_MAX_BPS = 2_000; // == ElysiumCustodyEnforcer.FEE_MAX_BPS (fee <= 20% of idle USDC)
    uint256 public constant MAX_POSITIONS = 4;
    uint256 public constant MIN_DELEGATION_LIFETIME = 1 days;

    // ------------------------------------------------------------------ immutables
    IDelegationManager public immutable delegationManager;
    address public immutable enforcer;
    address public immutable timestampEnforcer;
    address public immutable hybridImpl;
    address public immutable eip7702Impl;
    IPoolManager public immutable poolManager;
    IPositionManagerMin public immutable positionManager;
    address public immutable permit2;
    address public immutable swapExecutor;
    IERC20 public immutable asset;
    address public immutable hedgeTreasury;
    address public immutable feeRecipient;
    address internal immutable currency0;
    address internal immutable currency1;
    uint24 internal immutable fee;
    int24 internal immutable tickSpacing;
    bool public immutable baseIsCurrency0;
    PoolId public immutable poolId;
    bytes32 public immutable enforcerTermsHash;

    // ------------------------------------------------------------------ config
    struct Params {
        uint16 feeBps;
        uint16 hedgeCapBps;
        uint16 poolBandBps;
        uint16 maxSlippageBps;
        uint16 hedgeStepBps;
        uint16 refDriftBps;
        uint32 swapTurnoverBps;
        uint32 feeInterval;
        uint32 maxPriceAge; // the anchor must have been reported this recently for a fee
    }

    Params public params;
    address public keeper;
    address public guardian;
    bool public paused;

    // ------------------------------------------------------------------ global price anchor
    uint256 public lastPrice; // asset raw units per 1e18 base raw units
    uint256 public lastPriceTime;
    bool public lastPriceClipped;
    RiskBudgets.Budgets public priceBudget; // price fields + guardian price approval only

    // ------------------------------------------------------------------ accounts
    struct Account {
        bytes32 delegationHash; // 0 = never registered
        uint8 kind; // SALib.KIND_HYBRID | KIND_EIP7702
        uint64 until; // delegation expiry (TimestampEnforcer)
        int256 contributed; // net client contributions at the anchor
        int256 hwm; // profit level already charged
        uint256 hedgeEquity; // off-chain hedge equity attributed to this account
        uint256 netMargin; // margin sent - margin returned (floored at 0)
        uint256 hedgeEpoch; // increments with every hedge report (guardian approvals bind to it)
        uint256 snapAsset; // idle asset after the last module action
        uint256 snapBase; // idle base after the last module action
        uint256 lastFeeTime;
        uint256 feesPaid;
    }

    mapping(address => Account) public accounts;
    mapping(address => bytes) public permissionContext; // abi.encode(Delegation[1])
    mapping(address => RiskBudgets.Budgets) public budgets; // hedge + turnover + guardian hedge approval
    mapping(address => V4PositionMath.Position[]) internal _positions;
    mapping(uint256 => uint128) public snapLiquidity;

    // ------------------------------------------------------------------ events
    event Registered(address indexed account, bytes32 delegationHash, uint8 kind, uint256 until, bool first);
    event Flow(address indexed account, int256 value);
    event PriceReported(uint256 reported, uint256 applied, bool clipped);
    event PriceApproved(uint256 lo, uint256 hi, uint256 until);
    event PositionMinted(address indexed account, uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionIncreased(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event PositionDecreased(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event PositionBurned(address indexed account, uint256 indexed tokenId);
    event Swapped(address indexed account, bool sellBase, uint256 amountIn, uint256 amountOut, uint256 keeperPrice);
    event HedgeMarginSent(address indexed account, uint256 amount, uint256 hedgeEquity, uint256 netMargin);
    event HedgeMarginReturned(address indexed account, address to, uint256 amount, uint256 hedgeEquity, uint256 netMargin);
    event HedgeEquityReported(address indexed account, uint256 reported, uint256 applied, bool clipped);
    event HedgeEquityApproved(address indexed account, uint256 epoch, uint256 value, uint256 until);
    event FeeCharged(address indexed account, uint256 fee, int256 profit, int256 hwm);
    event Paused(bool paused, address indexed by);
    event ParamsSet(Params p);
    event RoleSet(bytes32 indexed role, address account);
    event CallFailed(uint256 indexed index, bytes reason);

    // ------------------------------------------------------------------ errors
    error NotKeeper();
    error NotGuardian();
    error IsPaused();
    error BadParam();
    error BadWiring();
    error NotRegistered();
    error NoAnchor();
    error BadPrice();
    error PoolPriceOff(uint256 poolPrice, uint256 keeperPrice);
    error UnknownPosition();
    error TooManyPositions();
    error MintFailed();
    error BelowMinOut(uint256 out, uint256 minOut);
    error HedgeCap(uint256 after_, uint256 cap);
    error TransferMismatch();
    error StalePrice();
    error FeeTooEarly(uint256 next);
    error FeeNeedsIdle(uint256 fee, uint256 idle);
    error NotOwnAccount();
    error ZeroAmount();

    struct Config {
        IDelegationManager delegationManager;
        address enforcer;
        address timestampEnforcer;
        address hybridImpl;
        address eip7702Impl;
        IPoolManager poolManager;
        IPositionManagerMin positionManager;
        address permit2;
        address swapExecutor;
        PoolKey key;
        IERC20 asset;
        address hedgeTreasury;
        address feeRecipient;
        address owner;
        address keeper;
        address guardian;
        Params params;
    }

    constructor(Config memory c) Ownable(c.owner) {
        address c0 = Currency.unwrap(c.key.currency0);
        address c1 = Currency.unwrap(c.key.currency1);
        if (address(c.key.hooks) != address(0)) revert BadWiring();
        if (c0 == address(c.asset)) baseIsCurrency0 = false;
        else if (c1 == address(c.asset)) baseIsCurrency0 = true;
        else revert BadWiring();
        if (
            c.keeper == address(0) || c.guardian == address(0) || c.keeper == c.guardian || c.hedgeTreasury == address(0)
                || c.feeRecipient == address(0) || c.hedgeTreasury == c.feeRecipient || c.hedgeTreasury == address(this)
                || c.feeRecipient == address(this) || c.timestampEnforcer.code.length == 0 || c.hybridImpl.code.length == 0
                || c.eip7702Impl.code.length == 0
        ) revert BadParam();
        // the custody enforcer and the swap executor must be wired to exactly this venue (L-13 style wiring check)
        ElysiumCustodyEnforcer e = ElysiumCustodyEnforcer(c.enforcer);
        SwapExecutor x = SwapExecutor(c.swapExecutor);
        if (
            e.delegationManager() != address(c.delegationManager) || e.positionManager() != address(c.positionManager)
                || e.permit2() != c.permit2 || e.swapExecutor() != c.swapExecutor || e.asset() != address(c.asset)
                || e.poolKeyHash() != keccak256(abi.encode(c.key)) || address(x.poolManager()) != address(c.poolManager)
                || address(x.permit2()) != c.permit2 || keccak256(abi.encode(x.poolKey())) != keccak256(abi.encode(c.key))
        ) revert BadWiring();
        delegationManager = c.delegationManager;
        enforcer = c.enforcer;
        timestampEnforcer = c.timestampEnforcer;
        hybridImpl = c.hybridImpl;
        eip7702Impl = c.eip7702Impl;
        poolManager = c.poolManager;
        positionManager = c.positionManager;
        permit2 = c.permit2;
        swapExecutor = c.swapExecutor;
        asset = c.asset;
        hedgeTreasury = c.hedgeTreasury;
        feeRecipient = c.feeRecipient;
        currency0 = c0;
        currency1 = c1;
        fee = c.key.fee;
        tickSpacing = c.key.tickSpacing;
        poolId = c.key.toId();
        enforcerTermsHash = keccak256(abi.encode(address(this), c.hedgeTreasury, c.feeRecipient));
        keeper = c.keeper;
        guardian = c.guardian;
        _setParams(c.params);
    }

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

    // ------------------------------------------------------------------ views
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee, tickSpacing, IHooks(address(0)));
    }

    function positionsOf(address a) external view returns (V4PositionMath.Position[] memory) {
        return _positions[a];
    }

    function poolPrice() public view returns (uint256) {
        return V4PositionMath.price(poolManager, poolId, baseIsCurrency0);
    }

    function isActive(address a) public view returns (bool) {
        Account storage s = accounts[a];
        return s.delegationHash != 0 && block.timestamp < s.until && !delegationManager.disabledDelegations(s.delegationHash);
    }

    /// @notice Account value at `price`: idle asset + idle base + tracked LP positions (amounts at the pool price,
    ///         uncollected fees included, base valued at `price`) + attributed hedge equity.
    function accountValue(address a, uint256 price) public view returns (uint256) {
        (uint256 b, uint256 x) = _lpAmounts(a);
        return _held(a, price) + x + Math.mulDiv(b, price, WAD) + accounts[a].hedgeEquity;
    }

    /// @notice Where hedge margin goes back: the account while the delegation is live, otherwise its owner EOA.
    function payoutAddress(address a) public view returns (address) {
        if (isActive(a) || accounts[a].kind != SALib.KIND_HYBRID) return a;
        try IHybridDeleGator(a).owner() returns (address o) {
            if (o != address(0)) return o;
        } catch {}
        return a;
    }

    // ------------------------------------------------------------------ onboarding (permissionless; relayer)
    /// @notice Register a client-signed delegation (see SALib.checkDelegation for the exact shape). The first
    ///         registration books everything already in the account as the client's contribution.
    function register(Delegation calldata d) public nonReentrant {
        _register(d);
    }

    /// @notice Relayer path: register (if needed) and move `amount` USDC from the HybridDeleGator's owner EOA into
    ///         the account with an EIP-2612 permit (spender = this module). Funds can only go into the owner's own
    ///         account. A front-run permit is tolerated (try/catch).
    function onboard(Delegation calldata d, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        address a = d.delegator;
        if (accounts[a].delegationHash != delegationManager.getDelegationHash(d)) _register(d);
        if (amount == 0) return;
        if (accounts[a].kind != SALib.KIND_HYBRID) revert NotOwnAccount(); // a 7702 account already holds its funds
        address owner_ = IHybridDeleGator(a).owner();
        try IERC20Permit(address(asset)).permit(owner_, address(this), amount, deadline, v, r, s) {} catch {}
        asset.safeTransferFrom(owner_, a, amount); // booked as a contribution at the next sync
    }

    /// @notice Anyone may fund a registered account; booked as a contribution at the next module action.
    function deposit(address a, uint256 amount) external nonReentrant {
        if (accounts[a].delegationHash == 0) revert NotRegistered();
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, a, amount);
    }

    function _register(Delegation calldata d) internal {
        if (lastPrice == 0) revert NoAnchor();
        (bytes32 h, uint8 kind, uint256 until) = SALib.checkDelegation(
            d,
            SALib.Expect(
                delegationManager,
                address(this),
                enforcer,
                enforcerTermsHash,
                timestampEnforcer,
                MIN_DELEGATION_LIFETIME,
                hybridImpl,
                eip7702Impl
            )
        );
        address a = d.delegator;
        Account storage s = accounts[a];
        bool first = s.delegationHash == 0;
        if (!first) _sync(a); // re-registration keeps the books; recognise what the client did meanwhile
        s.delegationHash = h;
        s.kind = kind;
        s.until = uint64(until);
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        permissionContext[a] = abi.encode(ds);
        _snap(a);
        if (first) {
            // forge-lint: disable-next-line(unsafe-typecast)
            s.contributed = int256(accountValue(a, lastPrice));
            s.lastFeeTime = block.timestamp;
        }
        emit Registered(a, h, kind, until, first);
    }

    // ------------------------------------------------------------------ keeper: price anchor
    /// @notice Move the global anchor toward `price` (within `poolBandBps` of the pool) inside the decaying daily
    ///         budget; frozen while paused unless the guardian approved a range. Never reverts on the budget: the
    ///         clipped value is applied and flagged (fees wait for an unclipped report).
    function reportPrice(uint256 price) external nonReentrant onlyKeeper {
        _checkPoolBand(price);
        (uint256 p, bool clipped) =
            RiskBudgets.movePrice(priceBudget, lastPrice, price, paused ? 0 : uint256(params.refDriftBps) * (WAD / BPS));
        lastPrice = p;
        lastPriceTime = block.timestamp;
        lastPriceClipped = clipped;
        emit PriceReported(price, p, clipped);
    }

    // ------------------------------------------------------------------ keeper: liquidity
    function mintPosition(
        address a,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 keeperPrice
    ) external nonReentrant onlyKeeper whenNotPaused returns (uint256 tokenId) {
        _checkKeeperPrice(keeperPrice);
        if (_positions[a].length >= MAX_POSITIONS) revert TooManyPositions();
        _sync(a);
        uint256 ref = lastPrice;
        uint256 v0 = _held(a, ref);
        uint256 nav = accountValue(a, ref);
        tokenId = positionManager.nextTokenId();
        _modify(
            a, V4PositionMath.mintData(poolKey(), tickLower, tickUpper, liquidity, amount0Max, amount1Max, a), amount0Max, amount1Max
        );
        if (positionManager.ownerOf(tokenId) != a) revert MintFailed();
        _positions[a].push(V4PositionMath.Position(tokenId, tickLower, tickUpper));
        _checkAdd(a, v0, ref, nav, tickLower, tickUpper, liquidity);
        _snap(a);
        emit PositionMinted(a, tokenId, tickLower, tickUpper, liquidity);
    }

    function increasePosition(
        address a,
        uint256 tokenId,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 keeperPrice
    ) external nonReentrant onlyKeeper whenNotPaused {
        _checkKeeperPrice(keeperPrice);
        _sync(a);
        V4PositionMath.Position memory p = _positions[a][_indexOf(a, tokenId)];
        uint256 ref = lastPrice;
        uint256 v0 = _held(a, ref);
        uint256 nav = accountValue(a, ref);
        _modify(
            a, V4PositionMath.increaseData(tokenId, liquidity, amount0Max, amount1Max, currency0, currency1, a), amount0Max, amount1Max
        );
        _checkAdd(a, v0, ref, nav, p.tickLower, p.tickUpper, liquidity);
        _snap(a);
        emit PositionIncreased(a, tokenId, liquidity);
    }

    /// @notice Remove liquidity (0 = collect fees) into the account. Risk-reducing: allowed while paused.
    function decreasePosition(address a, uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min)
        external
        nonReentrant
        onlyKeeper
    {
        _sync(a);
        _indexOf(a, tokenId);
        _modify(a, V4PositionMath.removeData(false, tokenId, liquidity, amount0Min, amount1Min, currency0, currency1, a), 0, 0);
        _snap(a);
        emit PositionDecreased(a, tokenId, liquidity);
    }

    /// @notice Remove everything into the account and burn the NFT. Allowed while paused.
    function burnPosition(address a, uint256 tokenId, uint128 amount0Min, uint128 amount1Min)
        external
        nonReentrant
        onlyKeeper
    {
        _sync(a);
        uint256 i = _indexOf(a, tokenId);
        _modify(a, V4PositionMath.removeData(true, tokenId, 0, amount0Min, amount1Min, currency0, currency1, a), 0, 0);
        _removeAt(a, i);
        _snap(a);
        emit PositionBurned(a, tokenId);
    }

    // ------------------------------------------------------------------ keeper: swaps
    /// @notice Exact-input swap of the account's own tokens through SwapExecutor (pays the account). min-out =
    ///         fair value at `keeperPrice` minus maxSlippageBps; the pool may not be pushed beyond the anchor band
    ///         (sqrtPrice limit), so a stale or sandwiched swap loses at most band + slippage against the anchor.
    function swap(address a, bool sellBase, uint256 amountIn, uint256 keeperPrice)
        external
        nonReentrant
        onlyKeeper
        whenNotPaused
        returns (uint256 out)
    {
        if (amountIn == 0) revert ZeroAmount();
        _checkKeeperPrice(keeperPrice);
        _sync(a);
        uint256 ref = lastPrice;
        uint256 fair = sellBase ? Math.mulDiv(amountIn, keeperPrice, WAD) : Math.mulDiv(amountIn, WAD, keeperPrice);
        _useTurnover(a, sellBase ? fair : amountIn, accountValue(a, ref));
        uint256 minOut = Math.mulDiv(fair, BPS - params.maxSlippageBps, BPS);
        if (minOut == 0) revert ZeroAmount();
        uint256 band = params.poolBandBps;
        uint160 limit = SALib.sqrtPriceAt(Math.mulDiv(ref, sellBase ? BPS - band : BPS + band, BPS), baseIsCurrency0);
        bool zeroForOne = sellBase == baseIsCurrency0;
        (address cIn, address cOut) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        uint256 before = _balanceOf(cOut, a);
        bytes memory call = abi.encodeCall(SwapExecutor.swap, (zeroForOne, amountIn, minOut, limit));
        _redeem(a, SALib.swapExecs(cIn, permit2, swapExecutor, amountIn, call));
        out = _balanceOf(cOut, a) - before;
        if (out < minOut) revert BelowMinOut(out, minOut);
        _snap(a);
        emit Swapped(a, sellBase, amountIn, out, keeperPrice);
    }

    // ------------------------------------------------------------------ keeper: hedge
    /// @notice Send hedge margin from the account to the immutable `hedgeTreasury`. Allowed while paused.
    function sendHedgeMargin(address a, uint256 amount) external nonReentrant onlyKeeper {
        if (amount == 0) revert ZeroAmount();
        if (lastPrice == 0) revert NoAnchor();
        _sync(a);
        Account storage s = accounts[a];
        uint256 h = s.hedgeEquity;
        uint256 m = s.netMargin;
        uint256 after_ = (h > m ? h : m) + amount;
        uint256 cap = Math.mulDiv(accountValue(a, lastPrice), params.hedgeCapBps, BPS);
        if (after_ > cap) revert HedgeCap(after_, cap);
        s.hedgeEquity = h + amount;
        s.netMargin = m + amount;
        budgets[a].hedgeApprovedEpoch = 0; // M-2: an approval was judged against the old baseline
        uint256 before = asset.balanceOf(a);
        _exec1(a, address(asset), 0, abi.encodeCall(IERC20.transfer, (hedgeTreasury, amount)));
        if (before - asset.balanceOf(a) != amount) revert TransferMismatch();
        _snap(a);
        emit HedgeMarginSent(a, amount, s.hedgeEquity, s.netMargin);
    }

    /// @notice Pull margin back from `hedgeTreasury` (which approves this module) into the account, or to its
    ///         owner EOA once the delegation is revoked or expired. Keeper or treasury. Never paused.
    function returnHedgeMargin(address a, uint256 amount) external nonReentrant {
        if (msg.sender != keeper && msg.sender != hedgeTreasury) revert NotKeeper();
        if (amount == 0) revert ZeroAmount();
        Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        bool live = isActive(a);
        if (live) _sync(a);
        address to = payoutAddress(a);
        uint256 before = asset.balanceOf(to);
        asset.safeTransferFrom(hedgeTreasury, to, amount);
        if (asset.balanceOf(to) - before != amount) revert TransferMismatch();
        uint256 h = s.hedgeEquity;
        uint256 m = s.netMargin;
        s.hedgeEquity = amount >= h ? 0 : h - amount;
        s.netMargin = amount >= m ? 0 : m - amount;
        budgets[a].hedgeApprovedEpoch = 0;
        if (live) _snap(a);
        emit HedgeMarginReturned(a, to, amount, s.hedgeEquity, s.netMargin);
    }

    /// @notice Report the account's off-chain hedge equity. The keeper alone can only lower it, within
    ///         hedgeStepBps of the account value per decaying day; an increase needs the guardian's exact value for
    ///         this account and epoch. A clipped report never reverts.
    function reportHedgeEquity(address a, uint256 value) external nonReentrant onlyKeeper {
        Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        uint256 old = s.hedgeEquity;
        if (value == old) return;
        uint256 cap = Math.mulDiv(accountValue(a, lastPrice), params.hedgeStepBps, BPS);
        (uint256 applied, bool clipped) = RiskBudgets.moveHedge(budgets[a], old, value, s.hedgeEpoch, cap);
        s.hedgeEquity = applied;
        s.hedgeEpoch++;
        emit HedgeEquityReported(a, value, applied, clipped);
    }

    // ------------------------------------------------------------------ keeper: fee
    /// @notice Charge feeBps of the account's profit above its high-water mark, in USDC from the account to
    ///         `feeRecipient`. Needs an unclipped anchor reported within maxPriceAge, `feeInterval` since the last
    ///         fee, not paused, and enough idle USDC (the enforcer caps a fee at 20% of it).
    function chargeFee(address a) external nonReentrant onlyKeeper whenNotPaused returns (uint256 f) {
        if (lastPriceClipped || block.timestamp > lastPriceTime + params.maxPriceAge) revert StalePrice();
        _sync(a);
        Account storage s = accounts[a];
        uint256 next = s.lastFeeTime + params.feeInterval;
        if (block.timestamp < next) revert FeeTooEarly(next);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 profit = int256(accountValue(a, lastPrice)) - s.contributed;
        int256 newHwm;
        (f, newHwm) = SALib.hwmFee(profit, s.hwm, params.feeBps);
        if (f == 0) return 0;
        uint256 idle = asset.balanceOf(a);
        if (f * BPS > idle * FEE_MAX_BPS) revert FeeNeedsIdle(f, idle);
        _exec1(a, address(asset), 0, abi.encodeCall(IERC20.transfer, (feeRecipient, f)));
        if (idle - asset.balanceOf(a) != f) revert TransferMismatch();
        s.hwm = newHwm;
        s.lastFeeTime = block.timestamp;
        s.feesPaid += f;
        _snap(a);
        emit FeeCharged(a, f, profit, newHwm);
    }

    // ------------------------------------------------------------------ keeper: batching
    /// @notice Run several keeper calls (typically over many accounts) in one transaction. With `allowFailure`
    ///         a failing call is reported (CallFailed) and the rest continue.
    function multicall(bytes[] calldata data, bool allowFailure) external onlyKeeper returns (bytes[] memory res) {
        res = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory r) = address(this).delegatecall(data[i]);
            if (!ok) {
                if (!allowFailure) {
                    assembly {
                        revert(add(r, 32), mload(r))
                    }
                }
                emit CallFailed(i, r);
            }
            res[i] = r;
        }
    }

    // ------------------------------------------------------------------ guardian
    function approvePrice(uint256 lo, uint256 hi, uint256 until) external onlyGuardian {
        priceBudget.priceApprovedLo = lo;
        priceBudget.priceApprovedHi = hi;
        priceBudget.priceApprovedUntil = until;
        emit PriceApproved(lo, hi, until);
    }

    /// @notice Exact hedge equity for account `a` at its current hedge epoch, valid until `until`; one-shot,
    ///         cleared by any margin move.
    function approveHedgeEquity(address a, uint256 value, uint256 until) external onlyGuardian {
        RiskBudgets.Budgets storage b = budgets[a];
        uint256 ep = accounts[a].hedgeEpoch;
        b.hedgeApproved = value;
        b.hedgeApprovedEpoch = ep + 1;
        b.hedgeApprovedUntil = until;
        emit HedgeEquityApproved(a, ep, value, until);
    }

    function setPaused(bool p) external {
        if (p) {
            if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        } else {
            _checkOwner();
        }
        paused = p;
        emit Paused(p, msg.sender);
    }

    // ------------------------------------------------------------------ owner (VaultTimelock)
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

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function renounceOwnership() public pure override {
        revert BadParam();
    }

    function _setParams(Params memory p) internal {
        if (
            p.feeBps > MAX_FEE_BPS || p.hedgeCapBps > MAX_HEDGE_CAP_BPS || p.poolBandBps == 0
                || p.poolBandBps > MAX_POOL_BAND_BPS || p.maxSlippageBps > MAX_SLIPPAGE_BPS
                || p.hedgeStepBps > MAX_HEDGE_STEP_BPS || p.refDriftBps > MAX_REF_DRIFT_BPS
                || p.swapTurnoverBps > MAX_TURNOVER_BPS || p.feeInterval < MIN_FEE_INTERVAL || p.feeInterval > 365 days
                || p.maxPriceAge < 60 || p.maxPriceAge > 1 days
        ) revert BadParam();
        params = p;
        emit ParamsSet(p);
    }

    // ------------------------------------------------------------------ internals: execution
    /// @dev Redeem the account's stored delegation for single-call executions (one DelegationManager call).
    function _redeem(address a, bytes[] memory execs) internal {
        bytes memory ctx = permissionContext[a];
        if (ctx.length == 0) revert NotRegistered();
        uint256 n = execs.length;
        bytes[] memory ctxs = new bytes[](n);
        ModeCode[] memory modes = new ModeCode[](n);
        for (uint256 i; i < n; ++i) {
            ctxs[i] = ctx;
            modes[i] = DelegationFramework.SINGLE_DEFAULT;
        }
        delegationManager.redeemDelegations(ctxs, modes, execs);
    }

    function _exec1(address a, address target, uint256 value, bytes memory data) internal {
        bytes[] memory xs = new bytes[](1);
        xs[0] = DelegationFramework.single(target, value, data);
        _redeem(a, xs);
    }

    function _modify(address a, bytes memory unlockData, uint128 max0, uint128 max1) internal {
        _redeem(a, SALib.modifyExecs(currency0, currency1, permit2, address(positionManager), unlockData, max0, max1));
    }

    // ------------------------------------------------------------------ internals: accounting
    function _balanceOf(address token, address a) internal view returns (uint256) {
        return token == address(0) ? a.balance : IERC20(token).balanceOf(a);
    }

    function _baseToken() internal view returns (address) {
        return baseIsCurrency0 ? currency0 : currency1;
    }

    function _held(address a, uint256 price) internal view returns (uint256) {
        return asset.balanceOf(a) + Math.mulDiv(_balanceOf(_baseToken(), a), price, WAD);
    }

    function _lpAmounts(address a) internal view returns (uint256 baseAmt, uint256 assetAmt) {
        if (_positions[a].length == 0) return (0, 0);
        (uint256 a0, uint256 a1) =
            V4PositionMath.amounts(poolManager, poolId, address(positionManager), _positions[a]);
        (baseAmt, assetAmt) = baseIsCurrency0 ? (a0, a1) : (a1, a0);
    }

    /// @dev Book what changed since the last module action (client deposits / withdrawals, direct LP changes) as a
    ///      contribution flow at the anchor; drop positions the account no longer owns.
    function _sync(address a) internal {
        Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        uint256 ref = lastPrice;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 idle = int256(asset.balanceOf(a)) - int256(s.snapAsset) + SALib.signedDelta(_balanceOf(_baseToken(), a), s.snapBase, ref);
        int256 f = SALib.flow(_positions[a], snapLiquidity, positionManager, a, ref, baseIsCurrency0, idle);
        if (f != 0) {
            s.contributed += f;
            emit Flow(a, f);
        }
    }

    function _snap(address a) internal {
        Account storage s = accounts[a];
        s.snapAsset = asset.balanceOf(a);
        s.snapBase = _balanceOf(_baseToken(), a);
        SALib.snapLiquidity(_positions[a], snapLiquidity, positionManager);
    }

    function _indexOf(address a, uint256 tokenId) internal view returns (uint256) {
        V4PositionMath.Position[] storage ps = _positions[a];
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].tokenId == tokenId) return i;
        }
        revert UnknownPosition();
    }

    function _removeAt(address a, uint256 i) internal {
        V4PositionMath.Position[] storage ps = _positions[a];
        uint256 last = ps.length - 1;
        delete snapLiquidity[ps[i].tokenId];
        if (i != last) ps[i] = ps[last];
        ps.pop();
    }

    // ------------------------------------------------------------------ internals: price and budgets
    function _checkPoolBand(uint256 price) internal view {
        if (price == 0) revert BadPrice();
        uint256 p = poolPrice();
        uint256 d = p > price ? p - price : price - p;
        if (d * BPS > price * params.poolBandBps) revert PoolPriceOff(p, price);
    }

    /// @dev Keeper price for a swap / LP add: within poolBandBps of the pool AND of the anchor (anchor required).
    function _checkKeeperPrice(uint256 price) internal view {
        _checkPoolBand(price);
        uint256 ref = lastPrice;
        if (ref == 0) revert NoAnchor();
        uint256 d = price > ref ? price - ref : ref - price;
        if (d * BPS > ref * params.poolBandBps) revert BadPrice();
    }

    /// @dev H-3: an add is a swap in effect. paid = drop of the account's held value at the anchor; got = the new
    ///      liquidity valued at the anchor; turnover charged with the add's loss weight slippage / (band + slippage).
    function _checkAdd(address a, uint256 v0, uint256 ref, uint256 nav, int24 tl, int24 tu, uint128 liquidity) internal {
        uint256 v1 = _held(a, ref);
        uint256 paid = v0 > v1 ? v0 - v1 : 0;
        uint256 charge = SALib.addCharge(tl, tu, liquidity, ref, baseIsCurrency0, paid, params.maxSlippageBps, params.poolBandBps);
        _useTurnover(a, charge, nav);
    }

    function _useTurnover(address a, uint256 notional, uint256 nav) internal {
        RiskBudgets.useTurnover(budgets[a], notional, Math.mulDiv(nav, params.swapTurnoverBps, BPS));
    }
}
