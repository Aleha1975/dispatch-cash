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

import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {SALib} from "./SALib.sol";
import {SABook} from "./SABook.sol";
import {ElysiumCustodyEnforcer} from "./ElysiumCustodyEnforcer.sol";
import {SwapExecutor} from "./SwapExecutor.sol";
import {Delegation, IDelegationManager} from "./vendor/DelegationFramework.sol";

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
///         (performance fee). The client can always act on its account directly, and stop the module with one
///         plain transaction (`revoke`, or `DelegationManager.disableDelegation` from the account); nothing here can
///         block either.
///
///         ROOT-CAUSE RULES (docs/audit/sa_round1_rootcause.md):
///         A. Nothing the account's code says is trusted for identity or transfers: a hybrid account is accepted only
///            at the CREATE2 address of the canonical proxy for its owner, which is pinned; funds are pulled only
///            from that owner into that account; hedge and fee transfers are verified at the recipient; mints are
///            read back from PositionManager; subscribed positions are refused; a 7702 code change or a hybrid
///            owner change suspends the module while it lasts (nothing is stored: restoring the code / owner resumes
///            it; only `revoke` or `disableDelegation` stop it for good, SA-4 I-1); a hybrid's implementation is the
///            client's: its code is treated as hostile, never trusted; approvals are reset after use.
///         B. The snapshot is what the books account for. A module action never reads it back from the account: it
///            ADDS its own effect, computed from state the account cannot write (PoolManager before the action, the
///            liquidity asked of PositionManager, the SwapExecutor record, the verified recipient delta). So
///            live - snapshot is exactly the client's flow, wherever it happened; `_sync` books it at the anchor
///            (the price `value` uses) only while the anchor is trusted, otherwise it stays pending (SA-2, SABook).
///         C. One delegation per account; only the client replaces it (`register` from the account / its owner)
///            or stops it (`revoke`).
///         D. Fee and custody decisions value positions at the anchor. Booking, fees, swaps and adds need a trusted
///            anchor (fresh, unclipped, unchanged for minPriceStable, reported within the last minPriceStable, pool
///            within BOOK_BAND_BPS); the fee is measured at the anchor (the booking price) only while the anchor is not
///            above the pool nor above its trailing 24 h low or (SA-5 M-3) the guardian-confirmed level by more than
///            the band, a day after the last booking of a material price-dependent client flow (SA-4 M-2, SA-5 L-1),
///            and needs a recent, not clipped-down hedge report (SA-3). SA-5 M-4: a priced flow booked at another
///            anchor than the account's previous priced booking raises the high-water mark by its largest possible
///            gain between the two (a late booking can only lower the fee).
///         E. Budgets are sliding 24 h windows (SAWindow): <= 1x per any 24 h, measured on the value without hedge
///            equity above the net margin sent (SA-4 M-3); an LP add is charged at its whole principal (SA-5 M-2). The
///            anchor's budget is its trailing 24 h range (SARange, net displacement; no path budget, SA-4 I-9), SA-4
///            M-1 one step of at most poolBandBps per minPriceStable, and SA-5 M-2 refDriftBps around the
///            guardian-confirmed level (an absolute bound: the keeper alone never walks it further, however long).
///         F. Guardian approvals bind (account, epoch, stored value, guardian era), are one-shot, expire within
///            1 day and are voided by a guardian change or a pause.
///         G. Keeper margin returns <= min(hedge equity, net margin sent) of the account (SA-4 M-3); pause stops
///            margin sends and keeper-only equity decreases; roles pairwise distinct.
///         H. `revoke` is the exit step that cannot fail silently.
///
///         ROLES: owner = VaultTimelock (keeper/guardian rotation, bounded params, SA-5 L-4 incl. their product; can
///         never move client funds);
///         keeper (hot key, all actions above, multicall over many accounts); guardian (pause, price-range and
///         hedge-equity co-signatures; cannot unpause or move funds).
contract LPManagerModule is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// Parameter bounds: enforced by SALib.checkParams (SA-5: moved there for EIP-170), listed here for reference:
    /// poolBandBps, maxSlippageBps 1..500; hedgeStepBps, refDriftBps <= 2000; swapTurnoverBps <= 50000;
    /// exitTurnoverBps <= 10000 (R4: at most 1x the account value per 24 h); feeInterval 7..365 days; maxPriceAge
    /// 60 s..1 day; minPriceStable 300 s..1 day; (refDrift + band + slippage) x (turnover + exit) <= 40% (SA-5 L-4).
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant MAX_HEDGE_CAP_BPS = 3_500;
    uint256 internal constant MAX_POOL_BAND_BPS = 500;
    uint256 public constant MIN_FEE_INTERVAL = 7 days; // == ElysiumCustodyEnforcer.FEE_INTERVAL
    uint256 internal constant FEE_MAX_BPS = 2_000; // == ElysiumCustodyEnforcer.FEE_MAX_BPS (fee <= 20% of idle USDC)
    uint256 public constant MAX_POSITIONS = 4;
    uint256 public constant MIN_DELEGATION_LIFETIME = 1 days;
    uint256 public constant MAX_APPROVAL_TTL = 1 days;
    /// SA-3 M-4: booking, fees, swaps and LP adds need the pool within this band of the anchor (much tighter than the
    /// keeper-report band): a flow is booked at most this far from the pool.
    uint256 public constant BOOK_BAND_BPS = 50;

    // ------------------------------------------------------------------ immutables
    IDelegationManager public immutable delegationManager;
    address public immutable enforcer;
    address public immutable timestampEnforcer;
    address public immutable hybridImpl;
    address public immutable eip7702Impl;
    address public immutable factory;
    bytes32 public immutable accountSalt;
    bytes32 internal immutable designatorHash;
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
        uint32 maxPriceAge; // the anchor (and the hedge report) must be this recent for a fee or a margin send
        uint32 minPriceStable; // booking and fees need the anchor unchanged for this long (SA-2 L-16 / H-1)
        uint16 exitTurnoverBps; // R4: own 24 h budget for selling base with no position held (0 = off: turnover window)
    }

    Params public params;
    address public keeper;
    address public guardian;
    bool public paused;
    uint64 public guardianEra; // incremented by setGuardian and setPaused(true): voids every open approval

    // ------------------------------------------------------------------ global price anchor
    uint256 public lastPrice; // asset raw units per 1e18 base raw units
    uint256 public lastPriceTime; // last report (freshness)
    uint256 public lastPriceMoved; // last change of the anchor value (stable window)
    uint256 public lastReported; // the keeper's last reported price
    SALib.PriceBudget public priceBudget; // getter: (lo, hi, until) of the guardian range, base (SA-5 M-2), range

    // ------------------------------------------------------------------ accounts
    mapping(address => SALib.Account) internal accounts;
    mapping(address => bytes) public permissionContext; // abi.encode(Delegation[1])
    mapping(address => SALib.Budgets) public budgets; // getter: hedge approval (value, epoch + 1, until, era)
    mapping(address => V4PositionMath.Position[]) internal _positions;
    mapping(uint256 => SABook.Pos) public snapPos; // getter: (liq, seen, g0, g1, G0, G1) (SA-3 M-1, SA-4 H-1, SA-5 M-1)
    SALib.Venue internal venue;

    // ------------------------------------------------------------------ events
    event Registered(address indexed account, bytes32 delegationHash, uint8 kind, uint256 until, bool first);
    event Revoked(address indexed account, address by);
    event Flow(address indexed account, int256 value);
    event PriceReported(uint256 reported, uint256 applied, bool clipped);
    event PriceApproved(uint256 lo, uint256 hi, uint256 until);
    event PositionMinted(address indexed account, uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionIncreased(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event PositionDecreased(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event PositionBurned(address indexed account, uint256 indexed tokenId);
    event Swapped(address indexed account, bool sellBase, uint256 amountIn, uint256 amountOut, uint256 keeperPrice);
    event HedgeMarginSent(address indexed account, uint256 amount, uint256 hedgeEquity, uint256 netMargin);
    event HedgeMarginReturned(address indexed account, uint256 amount, uint256 hedgeEquity, uint256 netMargin);
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
    error NotLive();
    error NoAnchor();
    error BadPrice();
    error PoolPriceOff(uint256 poolPrice, uint256 keeperPrice);
    error UnknownPosition();
    error TooManyPositions();
    error HedgeCap(uint256 after_, uint256 cap);
    error StalePrice();
    error StaleHedge();
    error FeeTooEarly(uint256 next);
    error NotOwnAccount();
    error ZeroAmount();
    error BelowMinOutOrBadSwap(uint256 out, uint256 minOut);

    struct Config {
        IDelegationManager delegationManager;
        address enforcer;
        address timestampEnforcer;
        address hybridImpl;
        address eip7702Impl;
        address factory;
        bytes32 accountSalt;
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
        // L-8: every role and operator address distinct and non-zero
        address[6] memory r = [c.owner, c.keeper, c.guardian, c.hedgeTreasury, c.feeRecipient, address(this)];
        for (uint256 i; i < 6; ++i) {
            if (r[i] == address(0)) revert BadParam();
            for (uint256 j = i + 1; j < 6; ++j) {
                if (r[i] == r[j]) revert BadParam();
            }
        }
        if (
            c.timestampEnforcer.code.length == 0 || c.hybridImpl.code.length == 0 || c.eip7702Impl.code.length == 0
                || c.factory.code.length == 0
        ) revert BadParam();
        // the custody enforcer and the swap executor must be wired to exactly this venue
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
        factory = c.factory;
        accountSalt = c.accountSalt;
        designatorHash = keccak256(abi.encodePacked(hex"ef0100", c.eip7702Impl));
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
        venue = SALib.Venue(c.poolManager, poolId, c.positionManager, address(c.asset), baseIsCurrency0 ? c0 : c1, baseIsCurrency0);
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

    /// @notice The module manages `a`: registered, not revoked, not expired, delegation not disabled, account code /
    ///         owner unchanged since registration.
    function isActive(address a) public view returns (bool) {
        SALib.Account storage s = accounts[a];
        return SALib.live(s, a, designatorHash) && !delegationManager.disabledDelegations(s.delegationHash)
            && !delegationManager.paused(); // SA-3 L-17: a paused DelegationManager halts every keeper action
    }

    /// @notice Account value at `price`: idle asset + idle base + positions still owned (principal at sqrt(price)
    ///         plus uncollected fees, base at `price`; no pool-spot term) + attributed hedge equity.
    function accountValue(address a, uint256 price) public view returns (uint256) {
        return SABook.value(venue, accounts[a], _positions[a], a, price);
    }

    /// @notice SA-2 M-4: the anchor counts as clipped only while it is outside `poolBandBps` of the keeper's last
    ///         report (per cause, auto-clearing as soon as it is back in band), not after any unapplied unit.
    function lastPriceClipped() public view returns (bool) {
        return _off(lastPrice, lastReported);
    }

    function account(address a) external view returns (SALib.Account memory) {
        return accounts[a];
    }

    /// @notice (turnover used, hedge-decrease used) of `a` in their 24 h windows, the anchor's trailing 24 h range
    ///         (max / min - 1, WAD; SA-3) and (R4) the exit window used.
    function windows(address a)
        external
        view
        returns (uint256 turnoverUsed, uint256 hedgeUsed, uint256 priceUsed, uint256 exitUsed)
    {
        (turnoverUsed, hedgeUsed, exitUsed) = SALib.used(budgets[a]);
        priceUsed = SALib.priceUsed(priceBudget, lastPrice);
    }

    // ------------------------------------------------------------------ onboarding and client control
    /// @notice Register a client-signed delegation (SALib.checkDelegation). The first registration is permissionless
    ///         (relayer); it books nothing: what the account holds is booked by the first keeper sync at a trusted
    ///         anchor (SA-2 H-1). Registering the stored delegation again is a no-op; replacing it, or registering
    ///         after a revoke, needs the client: the account itself or its pinned owner (M-1).
    function register(Delegation calldata d) external nonReentrant {
        _register(d);
    }

    /// @notice Relayer path: register (first time) and move `amount` USDC from the account's pinned owner into the
    ///         account on a fresh EIP-2612 permit for exactly `amount` (SA-2 M-3; a front-run of this very permit is
    ///         tolerated, see SALib.pull for the one case a same-amount standing allowance is used, SA-4 L-9). Booked
    ///         as a contribution at face value at once.
    function onboard(Delegation calldata d, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s_)
        external
        nonReentrant
    {
        address a = d.delegator;
        _register(d); // a no-op for the stored delegation
        if (amount == 0) return;
        SALib.Account storage s = accounts[a];
        if (s.kind != SALib.KIND_HYBRID) revert NotOwnAccount(); // a 7702 account already holds its funds
        if (!isActive(a)) revert NotLive(); // SA-3 L-6: no pull into an account that is not live
        SALib.pull(address(asset), s.owner, a, amount, deadline, v, r, s_);
        _book(s, a, amount);
    }

    /// @notice Anyone may fund a registered account from its own balance; booked as a contribution at face value.
    function deposit(address a, uint256 amount) external nonReentrant {
        SALib.Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, a, amount);
        _book(s, a, amount);
    }

    /// @notice Stop the module for account `a` (M-8, M-1): the account or its pinned owner EOA, one plain call with
    ///         no external calls to anyone else, not pausable. Only the client can resume (register again). SA-3
    ///         L-14: an account that is not registered yet can revoke in advance (a signed delegation it no longer
    ///         wants used); SA-4 I-2: so can the owner EOA of a hybrid account (derived, pure), deployed or not.
    function revoke(address a) external {
        SALib.Account storage s = accounts[a];
        if (msg.sender != a && msg.sender != s.owner && SALib.hybridAddress(_expect(), msg.sender) != a) {
            revert NotOwnAccount();
        }
        s.revoked = true;
        emit Revoked(a, msg.sender);
    }

    function _register(Delegation calldata d) internal {
        if (lastPrice == 0) revert NoAnchor();
        SALib.register(accounts, permissionContext, d, _expect());
    }

    // ------------------------------------------------------------------ keeper: price anchor
    /// @notice Move the global anchor toward `price` (within `poolBandBps` of the pool) inside the trailing 24 h
    ///         range budget (SALib.movePrice: net displacement); frozen while paused unless the guardian approved a
    ///         range (one-shot). Never reverts on the budget: the clipped value is applied; the anchor counts as
    ///         clipped while it is outside the band of this report (`lastPriceClipped`). Reporting the stored anchor
    ///         refreshes it without moving it; SA-3 L-5: a report after a gap longer than minPriceStable counts as a
    ///         move (an anchor that nobody confirmed during an outage is not "stable"). SA-4 M-1: one report moves
    ///         the anchor at most poolBandBps, and only once the last move has been stable for minPriceStable.
    function reportPrice(uint256 price) external nonReentrant onlyKeeper {
        _checkPoolBand(price);
        uint256 old = lastPrice;
        (uint256 p, bool clipped) = SALib.movePrice(
            priceBudget,
            old,
            price,
            paused ? 0 : uint256(params.refDriftBps) * (WAD / BPS),
            params.poolBandBps,
            block.timestamp >= lastPriceMoved + params.minPriceStable
        );
        if (p != old || block.timestamp > lastPriceTime + params.minPriceStable) lastPriceMoved = block.timestamp;
        if (p != old) {
            lastPrice = p;
        }
        lastReported = price;
        lastPriceTime = block.timestamp;
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
        _live(a);
        _sync(a); // L-10: drop positions the client removed before counting (at a trusted anchor)
        if (_positions[a].length >= MAX_POSITIONS) revert TooManyPositions();
        tokenId = positionManager.nextTokenId();
        V4PositionMath.Position memory p = V4PositionMath.Position(tokenId, tickLower, tickUpper);
        _add(a, p, liquidity, amount0Max, amount1Max, V4PositionMath.mintData(poolKey(), tickLower, tickUpper, liquidity, amount0Max, amount1Max, a));
        SALib.checkMinted(venue, tokenId, a, tickLower, tickUpper, liquidity);
        _positions[a].push(p);
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
        _live(a);
        _sync(a);
        V4PositionMath.Position memory p = _positions[a][_indexOf(a, tokenId)];
        SALib.notSubscribed(positionManager, tokenId);
        _add(a, p, liquidity, amount0Max, amount1Max, V4PositionMath.increaseData(tokenId, liquidity, amount0Max, amount1Max, currency0, currency1, a));
        emit PositionIncreased(a, tokenId, liquidity);
    }

    /// @notice Remove liquidity (0 = collect fees) into the account. Risk-reducing: allowed while paused.
    function decreasePosition(address a, uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min)
        external
        nonReentrant
        onlyKeeper
    {
        _remove(a, tokenId, liquidity, false, amount0Min, amount1Min);
        emit PositionDecreased(a, tokenId, liquidity);
    }

    /// @notice Remove everything into the account and burn the NFT. Allowed while paused.
    function burnPosition(address a, uint256 tokenId, uint128 amount0Min, uint128 amount1Min)
        external
        nonReentrant
        onlyKeeper
    {
        _remove(a, tokenId, 0, true, amount0Min, amount1Min);
        emit PositionBurned(a, tokenId);
    }

    // ------------------------------------------------------------------ keeper: swaps
    /// @notice Exact-input swap of the account's own tokens through SwapExecutor (pays the account). min-out =
    ///         max(`minOut`, fair value at `keeperPrice` minus maxSlippageBps) (SA-2 L-15); the pool may not be pushed
    ///         beyond the anchor band (sqrtPrice limit). The effect on the account is booked from the executor's
    ///         record of this swap (SA-2 L-14), never from the account's balances; SA-3 M-2: the record must be of
    ///         exactly the call the module built (calldata hash), so account code cannot substitute its own swap.
    ///         R4 (risk-off): a sell of base while the account holds no tracked position (everything burned first) is
    ///         charged to the separate exit window (exitTurnoverBps x value per 24 h) instead of the turnover window
    ///         (SA-4 L-6: the turnover window when the exit window is off or has no room); every other swap, and every
    ///         LP add, stays on the turnover window. SA-4 I-6: a sell is charged at the higher of its value at the
    ///         keeper price and at the anchor. SA-4 M-4 (1241): the exit sale has the same gates as every swap (not
    ///         paused, trusted anchor); a looser gate would be reachable at a keeper-walked anchor.
    function swap(address a, bool sellBase, uint256 amountIn, uint256 keeperPrice, uint256 minOut)
        external
        nonReentrant
        onlyKeeper
        whenNotPaused
        returns (uint256 out)
    {
        if (amountIn == 0) revert ZeroAmount();
        _checkKeeperPrice(keeperPrice);
        _live(a);
        _sync(a);
        uint256 ref = lastPrice;
        uint256 charge;
        uint160 limit;
        (charge, minOut, limit) = SALib.swapBounds(
            sellBase, amountIn, keeperPrice, ref, minOut, params.maxSlippageBps, params.poolBandBps, baseIsCurrency0
        );
        _useTurnover(a, charge, _nav(a, ref), sellBase && _positions[a].length == 0);
        bool zeroForOne = sellBase == baseIsCurrency0;
        SwapExecutor x = SwapExecutor(swapExecutor);
        (uint256 n0,,,) = x.lastSwap(a);
        bytes memory call = abi.encodeCall(SwapExecutor.swap, (zeroForOne, amountIn, minOut, limit));
        SALib.swapVia(delegationManager, permissionContext[a], zeroForOne ? currency0 : currency1, permit2, swapExecutor, amountIn, call);
        (uint256 n1, uint256 paid, uint256 got, bytes32 h) = x.lastSwap(a);
        if (n1 != n0 + 1 || h != keccak256(call) || got < minOut) revert BelowMinOutOrBadSwap(got, minOut);
        out = got;
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 pi, int256 go) = (-int256(paid), int256(got));
        if (sellBase) _apply(a, go, pi);
        else _apply(a, pi, go);
        emit Swapped(a, sellBase, paid, out, keeperPrice);
    }

    // ------------------------------------------------------------------ keeper: hedge
    /// @notice Send hedge margin from the account to the immutable `hedgeTreasury`. Needs an anchor reported within
    ///         maxPriceAge; stopped by the pause (G). SA-3 M-7: a clipped (lagging) anchor does not block it, the cap
    ///         is measured on the lower of the account value at the anchor and at the pool. Verified at the treasury;
    ///         the ledgers are written after the verified transfer (H-2).
    function sendHedgeMargin(address a, uint256 amount) external nonReentrant onlyKeeper whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 ref = lastPrice;
        if (ref == 0 || block.timestamp > lastPriceTime + params.maxPriceAge) revert StalePrice();
        _live(a);
        _sync(a);
        SALib.Account storage s = accounts[a];
        uint256 h = s.hedgeEquity;
        uint256 m = s.netMargin;
        uint256 after_ = (h > m ? h : m) + amount;
        uint256 v = accountValue(a, ref);
        uint256 vp = accountValue(a, poolPrice());
        uint256 cap = Math.mulDiv(vp < v ? vp : v, params.hedgeCapBps, BPS);
        if (after_ > cap) revert HedgeCap(after_, cap);
        _transferOut(a, hedgeTreasury, amount);
        s.hedgeEquity = h + amount;
        s.netMargin = m + amount;
        s.hedgeEpoch++; // M-3: any approval was judged against the old state
        emit HedgeMarginSent(a, amount, s.hedgeEquity, s.netMargin);
    }

    /// @notice Pull margin back from `hedgeTreasury` (which approves this module) into the account itself, live or
    ///         not (B: always bracketed; no owner() payout). The keeper may return at most the account's own hedge
    ///         equity (H-1) and (SA-4 M-3, 1241) at most the net margin the account really sent: a guardian-approved
    ///         equity gain cannot pull treasury USDC on the keeper key alone; the treasury itself may return more (its
    ///         own decision, e.g. realised hedge profit). Never paused.
    function returnHedgeMargin(address a, uint256 amount) external nonReentrant {
        bool byTreasury = msg.sender == hedgeTreasury;
        if (!byTreasury && msg.sender != keeper) revert NotKeeper();
        if (amount == 0) revert ZeroAmount();
        SALib.Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        _sync(a);
        SALib.returnMargin(s, address(asset), hedgeTreasury, a, amount, byTreasury);
    }

    /// @notice Report the account's off-chain hedge equity (SALib.moveHedge). The keeper alone can only lower it,
    ///         within hedgeStepBps of the account value per 24 h window (nothing while paused); an increase needs the
    ///         guardian's approval for this exact state. Every report refreshes the report time. Never reverts on the
    ///         budget.
    function reportHedgeEquity(address a, uint256 value) external nonReentrant onlyKeeper {
        SALib.Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        _sync(a);
        // L-16 / SA-2 L-2: no keeper-only move while paused or on an anchor that is not fresh (age, clipped, band)
        uint256 cap = paused || !_freshOk()
            ? 0
            : Math.mulDiv(_nav(a, lastPrice), params.hedgeStepBps, BPS);
        (uint256 applied, bool clipped) = SALib.moveHedge(s, budgets[a], value, cap, guardianEra);
        emit HedgeEquityReported(a, value, applied, clipped);
    }

    // ------------------------------------------------------------------ keeper: fee
    /// @notice Charge feeBps of the account's profit above its high-water mark (at most 20% of idle USDC; the mark
    ///         advances by what was charged), in USDC from the account to `feeRecipient`. Needs a trusted anchor
    ///         (`_trusted`), so the sync before it books every pending flow at the same anchor the profit is measured
    ///         at (SA-3 M-6: a parked deposit is neutral); a recent hedge report that was not clipped down;
    ///         `feeInterval` since the last fee; not paused. SA-3 M-3: profit = value at the anchor - contributed,
    ///         and only while the anchor is not above the pool nor more than poolBandBps above its trailing 24 h low
    ///         (SALib.feeGate), so a walked anchor must be held for a day in public view before it carries a fee.
    ///         SA-4 M-2: not within a day of the last booking of a price-dependent client flow (the keeper books every
    ///         flow with sync(a) at once, so the fee never rides on a flow booked at a moved anchor in the same day).
    ///         SA-4 M-3: profit is measured without hedge equity above the net margin sent. SA-5 M-3: nor more than
    ///         poolBandBps above the guardian-confirmed level (SALib.feeGate).
    function chargeFee(address a) external nonReentrant onlyKeeper whenNotPaused returns (uint256 f) {
        if (!_trusted()) revert StalePrice();
        _live(a);
        _sync(a);
        SALib.Account storage s = accounts[a];
        uint256 next = Math.max(s.lastFeeTime + params.feeInterval, s.pricedFlowTime + 1 days);
        if (block.timestamp < next) revert FeeTooEarly(next);
        if (s.hedgeEquity != 0 && (s.hedgeClipped || block.timestamp > s.hedgeTime + params.maxPriceAge)) {
            revert StaleHedge();
        }
        uint256 ref = lastPrice;
        SALib.feeGate(priceBudget, ref, poolPrice(), params.poolBandBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 profit = int256(_nav(a, ref)) - s.contributed;
        int256 newHwm;
        (f, newHwm) = SALib.hwmFee(profit, s.hwm, params.feeBps, asset.balanceOf(a) * FEE_MAX_BPS / BPS);
        if (f == 0) return 0;
        _transferOut(a, feeRecipient, f);
        s.hwm = newHwm;
        s.lastFeeTime = block.timestamp;
        s.feesPaid += f;
        emit FeeCharged(a, f, profit, newHwm);
    }

    // ------------------------------------------------------------------ keeper: batching
    /// @notice Run several keeper calls (typically over many accounts) in one transaction. With `allowFailure`
    ///         a failing call is reported (CallFailed, reason truncated to 256 bytes) and the rest continue. SA-2 L-4:
    ///         at most 256 bytes of a failing call's return data are copied into this frame's memory (inner frames
    ///         bubble theirs). No per-item gas bound: the keeper batches one account per transaction.
    function multicall(bytes[] calldata data, bool allowFailure) external onlyKeeper returns (bytes[] memory res) {
        res = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            bytes calldata c = data[i];
            bool ok;
            bytes memory r;
            assembly ("memory-safe") {
                r := mload(0x40)
                calldatacopy(r, c.offset, c.length)
                ok := delegatecall(gas(), address(), r, c.length, 0, 0)
                let n := returndatasize()
                if iszero(ok) {
                    if iszero(allowFailure) {
                        returndatacopy(r, 0, n)
                        revert(r, n)
                    }
                    if gt(n, 256) { n := 256 }
                }
                mstore(r, n)
                returndatacopy(add(r, 32), 0, n)
                mstore(0x40, add(add(r, 32), and(add(n, 31), not(31))))
            }
            if (!ok) emit CallFailed(i, r);
            res[i] = r;
        }
    }

    // ------------------------------------------------------------------ guardian
    /// @notice One-shot price range: the next report inside [lo, hi] before `until` (<= 1 day) consumes it and becomes
    ///         the guardian-confirmed level the anchor is bound to (SA-5 M-2); if it does not fit the keeper's budget it
    ///         is applied unclipped and starts a new 24 h window (SA-3). Cleared by a pause and a guardian change. SA-5
    ///         I-1: at most 10% wide.
    function approvePrice(uint256 lo, uint256 hi, uint256 until) external onlyGuardian {
        SALib.approvePrice(priceBudget, lo, hi, until, MAX_APPROVAL_TTL, 2 * MAX_POOL_BAND_BPS); // SA-5 I-1: <= 10% wide
        emit PriceApproved(lo, hi, until);
    }

    /// @notice Exact hedge equity `value` for account `a`, valid only while the account is still at `expectedEpoch`
    ///         with stored equity `expectedStored` (what the guardian judged, M-3), until `until` (<= 1 day), for the
    ///         current guardian; one-shot. Any margin move or equity change bumps the epoch and voids it.
    function approveHedgeEquity(address a, uint256 expectedEpoch, uint256 expectedStored, uint256 value, uint256 until)
        external
        onlyGuardian
    {
        SALib.Account storage s = accounts[a];
        if (
            s.delegationHash == 0 || s.hedgeEpoch != expectedEpoch || s.hedgeEquity != expectedStored
                || until > block.timestamp + MAX_APPROVAL_TTL
        ) revert BadParam();
        SALib.Budgets storage b = budgets[a];
        b.hedgeApproved = value;
        // forge-lint: disable-next-line(unsafe-typecast)
        b.hedgeApprovedEpoch = uint64(expectedEpoch + 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        b.hedgeApprovedUntil = uint64(until);
        b.hedgeApprovedEra = guardianEra;
        emit HedgeEquityApproved(a, expectedEpoch, value, until);
    }

    function setPaused(bool p) external {
        if (p == paused) revert BadParam(); // SA-3 I-2: a stale repeat does not void the guardian's approvals
        if (p) {
            if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
            priceBudget.until = 0; // a range judged before the pause does not move a frozen anchor
            guardianEra++; // SA-2 L-7: nor does a hedge approval judged before it
        } else {
            _checkOwner();
        }
        paused = p;
        emit Paused(p, msg.sender);
    }

    // ------------------------------------------------------------------ owner (VaultTimelock)
    function setKeeper(address k) external onlyOwner {
        _distinct(k);
        keeper = k;
        emit RoleSet("keeper", k);
    }

    function setGuardian(address g) external onlyOwner {
        _distinct(g);
        guardian = g;
        guardianEra++;
        priceBudget.until = 0;
        emit RoleSet("guardian", g);
    }

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function renounceOwnership() public pure override {
        revert BadParam();
    }

    /// @dev SA-2 L-6: the ownership path keeps the roles distinct too. SA-3 L-14: address(0) cancels a pending
    ///      transfer.
    function transferOwnership(address n) public override {
        if (n != address(0)) _distinct(n);
        super.transferOwnership(n);
    }

    function _distinct(address x) internal view {
        if (
            x == address(0) || x == keeper || x == guardian || x == hedgeTreasury || x == feeRecipient || x == owner()
                || x == pendingOwner() || x == address(this)
        ) revert BadParam();
    }

    function _setParams(Params memory p) internal {
        SALib.checkParams(abi.encode(p)); // bounds per parameter and (SA-5 L-4) of their product
        params = p;
        emit ParamsSet(p);
    }

    // ------------------------------------------------------------------ internals: execution
    function _modify(address a, bytes memory unlockData, uint128 max0, uint128 max1) internal {
        SALib.modify(
            delegationManager, permissionContext[a], currency0, currency1, permit2, address(positionManager), unlockData, max0, max1
        );
    }

    function _transferOut(address a, address to, uint256 amount) internal {
        SALib.transferOut(delegationManager, permissionContext[a], accounts[a], address(asset), to, amount);
    }

    // ------------------------------------------------------------------ internals: accounting
    function _expect() internal view returns (SALib.Expect memory) {
        return SALib.Expect(
            delegationManager,
            address(this),
            enforcer,
            enforcerTermsHash,
            timestampEnforcer,
            MIN_DELEGATION_LIFETIME,
            hybridImpl,
            eip7702Impl,
            factory,
            accountSalt,
            hedgeTreasury,
            feeRecipient
        );
    }

    function _live(address a) internal view {
        if (!SALib.live(accounts[a], a, designatorHash)) revert NotLive();
    }

    /// @dev Book live - snapshot as a client flow at the anchor, only while the anchor is trusted (SABook.sync);
    ///      LP fees paid out of tracked positions are booked as yield at every sync (SA-3 M-1).
    function _sync(address a) internal {
        SABook.sync(accounts[a], _positions[a], snapPos, a, venue, _trusted() ? lastPrice : 0);
    }

    /// @dev The module's own effect on idle: added to the snapshot, never read back (SABook).
    function _apply(address a, int256 dAsset, int256 dBase) internal {
        SALib.Account storage s = accounts[a];
        s.snapAsset += dAsset;
        s.snapBase += dBase;
    }

    /// @dev USDC contribution at face value (no price involved), booked at once.
    function _book(SALib.Account storage s, address a, uint256 amount) internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 x = int256(amount);
        s.snapAsset += x;
        s.contributed += x;
        emit Flow(a, x);
    }

    /// @dev LP add: H-3 check and turnover on the computed principal (SABook.lpAdd), then the PositionManager call,
    ///      then the computed effect (idle and the position's snapshot liquidity).
    function _add(address a, V4PositionMath.Position memory p, uint128 liq, uint128 m0, uint128 m1, bytes memory data)
        internal
    {
        uint256 ref = lastPrice;
        uint256 nav = _nav(a, ref);
        (int256 dA, int256 dB, uint256 charge) =
            SABook.lpAdd(venue, p, liq, ref, params.maxSlippageBps);
        _useTurnover(a, charge, nav, false);
        _modify(a, data, m0, m1);
        SABook.book(accounts[a], snapPos, venue, p, dA, dB, int256(uint256(liq)));
    }

    /// @dev LP removal: computed effect of removing min(liquidity, snapshot, live) (burn: min(snapshot, live)) plus
    ///      fees. SA-4 L-3: a burned position whose snapshot liquidity was not all removed stays tracked (not owned:
    ///      worth 0 in `value`) until the next priced sync books the rest as the client's outflow and drops it.
    function _remove(address a, uint256 tokenId, uint128 liquidity, bool burn, uint128 m0, uint128 m1) internal {
        _live(a);
        _sync(a);
        uint256 i = _indexOf(a, tokenId);
        V4PositionMath.Position memory p = _positions[a][i];
        SALib.notSubscribed(positionManager, tokenId);
        (int256 dA, int256 dB, uint128 m) = SABook.lpRemove(venue, p, liquidity, burn, snapPos[tokenId].liq);
        _modify(a, V4PositionMath.removeData(burn, tokenId, liquidity, m0, m1, currency0, currency1, a), 0, 0);
        SABook.book(accounts[a], snapPos, venue, p, dA, dB, -int256(uint256(m)));
        if (burn && snapPos[tokenId].liq == 0) _removeAt(a, i);
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
        delete snapPos[ps[i].tokenId];
        if (i != last) ps[i] = ps[last];
        ps.pop();
    }

    // ------------------------------------------------------------------ internals: price and budgets
    /// @dev `x` is outside poolBandBps of `ref` (measured against `ref`, SA-2 L-5).
    function _off(uint256 x, uint256 ref) internal view returns (bool) {
        uint256 d = x > ref ? x - ref : ref - x;
        return d * BPS > ref * params.poolBandBps;
    }

    function _checkPoolBand(uint256 price) internal view {
        if (price == 0) revert BadPrice();
        uint256 p = poolPrice();
        if (_off(price, p)) revert PoolPriceOff(p, price);
    }

    /// @dev D: the anchor exists, was reported within maxPriceAge, is within the band of the last report (not
    ///      clipped) and of the pool right now.
    function _freshOk() internal view returns (bool) {
        uint256 ref = lastPrice;
        return ref != 0 && block.timestamp <= lastPriceTime + params.maxPriceAge && !_off(ref, lastReported)
            && !_off(ref, poolPrice());
    }

    /// @dev Booking, fees, swaps and LP adds: fresh; unchanged for minPriceStable and reported within the last
    ///      minPriceStable (SA-2 L-16, SA-3 L-5: no anchor move and use in one transaction, no anchor taken over
    ///      unconfirmed after an outage; SA-4 L-14: at exactly moved + minPriceStable the moving report satisfies
    ///      both, so this is not a second-report requirement); the pool within BOOK_BAND_BPS of the anchor (SA-3
    ///      M-4). The pool is read at this instant only: what bounds a keeper that also pushes the pool is the drift
    ///      budget with its per-report step (SA-4 M-1), the stable window and (fees) the trailing-low gate.
    function _trusted() internal view returns (bool) {
        uint256 st = params.minPriceStable;
        uint256 ref = lastPrice;
        uint256 pool = poolPrice();
        uint256 d = ref > pool ? ref - pool : pool - ref;
        return _freshOk() && block.timestamp >= lastPriceMoved + st && block.timestamp <= lastPriceTime + st
            && d * BPS <= pool * BOOK_BAND_BPS;
    }

    /// @notice Book account `a`'s pending client flow now (SA-3 M-5): the keeper, the account or its pinned owner, so
    ///         the booking moment is not the keeper's choice alone (SA-5 L-3: no third party picks it with a pool push),
    ///         only at a trusted anchor; SA-4 M-3: only for a registered account.
    function sync(address a) external nonReentrant {
        SALib.Account storage s = accounts[a];
        if (s.delegationHash == 0) revert NotRegistered();
        if (msg.sender != keeper && msg.sender != a && msg.sender != s.owner) revert NotOwnAccount();
        if (!_trusted()) revert StalePrice();
        _sync(a);
    }

    /// @dev Keeper price for a swap / LP add: within poolBandBps of the pool AND of the anchor (anchor required), and
    ///      SA-3 (M-2 of 1226, M-5 of 1227) only at a trusted anchor, so the `_sync` before the action books every
    ///      pending flow and a moved anchor is usable only after minPriceStable.
    function _checkKeeperPrice(uint256 price) internal view {
        if (!_trusted()) revert StalePrice();
        _checkPoolBand(price);
        uint256 ref = lastPrice;
        if (ref == 0) revert NoAnchor();
        if (_off(price, ref)) revert BadPrice();
    }

    function _useTurnover(address a, uint256 notional, uint256 nav, bool exit) internal {
        SALib.useTurnover(budgets[a], notional, nav, params.swapTurnoverBps, params.exitTurnoverBps, exit);
    }

    /// @dev SA-4 M-3: the value keeper budgets and the fee are measured on (SABook.nav).
    function _nav(address a, uint256 price) internal view returns (uint256) {
        return SABook.nav(venue, accounts[a], _positions[a], a, price);
    }
}
