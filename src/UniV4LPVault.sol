// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LPVaultBase} from "./LPVaultBase.sol";
import {V4PositionMath} from "./V4PositionMath.sol";
import {IPositionManagerMin, IPermit2Min, IWrappedNative} from "./interfaces/IExternal.sol";

/// @title UniV4LPVault
/// @notice LPVaultBase on one fixed Uniswap v4 pool (no hooks). LP positions are PositionManager NFTs owned by the
///         vault; swaps go straight through PoolManager.unlock on the same pool. Every keeper action is allowlisted:
///         the pool key, the recipient (always this vault) and the PoolManager/PositionManager targets are immutable,
///         so the keeper can never move tokens anywhere except into the vault's own positions, the configured pool
///         (swap, min-out enforced) or `hedgeTreasury` (relative cap).
contract UniV4LPVault is LPVaultBase, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // PositionManager action codes (v4-periphery Actions.sol)
    uint8 internal constant A_INCREASE = 0x00;
    uint8 internal constant A_DECREASE = 0x01;
    uint8 internal constant A_MINT = 0x02;
    uint8 internal constant A_BURN = 0x03;
    uint8 internal constant A_SETTLE_PAIR = 0x0d;
    uint8 internal constant A_TAKE_PAIR = 0x11;
    uint8 internal constant A_CLOSE_CURRENCY = 0x12;
    uint8 internal constant A_SWEEP = 0x14;

    uint256 public constant MAX_POSITIONS = 8;

    IPoolManager public immutable poolManager;
    IPositionManagerMin public immutable positionManager;
    IPermit2Min public immutable permit2;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    bool public immutable baseIsCurrency0;
    PoolId public immutable poolId;

    V4PositionMath.Position[] internal _positions;
    bool private _swapping;

    event PositionMinted(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionIncreased(uint256 indexed tokenId, uint128 liquidity);
    event PositionDecreased(uint256 indexed tokenId, uint128 liquidity);
    event PositionBurned(uint256 indexed tokenId);
    event PositionUnwindFailed(uint256 indexed tokenId, bytes reason);
    event Swapped(bool sellBase, uint256 amountIn, uint256 amountOut, uint256 keeperPrice);

    error BadPool();
    error UnknownPosition();
    error TooManyPositions();
    error BelowMinOut(uint256 out, uint256 minOut);
    error NotPoolManager();
    error MintFailed();

    struct V4Config {
        IPoolManager poolManager;
        IPositionManagerMin positionManager;
        IPermit2Min permit2;
        PoolKey key;
    }

    constructor(BaseConfig memory c, V4Config memory v) LPVaultBase(c) {
        address c0 = Currency.unwrap(v.key.currency0);
        address c1 = Currency.unwrap(v.key.currency1);
        if (address(v.key.hooks) != address(0)) revert BadPool();
        if (c1 == address(c.asset) && c0 == c.baseToken) baseIsCurrency0 = true;
        else if (!(c0 == address(c.asset) && c1 == c.baseToken)) revert BadPool();
        if (
            address(v.poolManager).code.length == 0 || address(v.positionManager).code.length == 0
                || address(v.permit2).code.length == 0
        ) revert BadPool();
        poolManager = v.poolManager;
        positionManager = v.positionManager;
        permit2 = v.permit2;
        currency0 = c0;
        currency1 = c1;
        fee = v.key.fee;
        tickSpacing = v.key.tickSpacing;
        poolId = v.key.toId();
        (uint160 sp,,,) = v.poolManager.getSlot0(v.key.toId());
        if (sp == 0) revert BadPool();
        // the vault only ever approves Permit2; Permit2 sub-allowances to PositionManager are exact and short-lived
        if (c0 != address(0)) IERC20(c0).forceApprove(address(v.permit2), type(uint256).max);
        IERC20(c1).forceApprove(address(v.permit2), type(uint256).max);
    }

    // ------------------------------------------------------------------ views
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee, tickSpacing, IHooks(address(0)));
    }

    function positions() external view returns (V4PositionMath.Position[] memory) {
        return _positions;
    }

    function _positionCount() internal view override returns (uint256) {
        return _positions.length;
    }

    function _poolPrice() internal view override returns (uint256) {
        return V4PositionMath.price(poolManager, poolId, baseIsCurrency0);
    }

    function _positionAmounts() internal view override returns (uint256 baseAmt, uint256 assetAmt) {
        if (_positions.length == 0) return (0, 0);
        (uint256 a0, uint256 a1) = V4PositionMath.amounts(poolManager, poolId, address(positionManager), _positions);
        (baseAmt, assetAmt) = baseIsCurrency0 ? (a0, a1) : (a1, a0);
    }

    function _indexOf(uint256 tokenId) internal view returns (uint256) {
        uint256 n = _positions.length;
        for (uint256 i; i < n; ++i) {
            if (_positions[i].tokenId == tokenId) return i;
        }
        revert UnknownPosition();
    }

    // ------------------------------------------------------------------ keeper: liquidity
    /// @notice Mint a new position in the configured pool, owned by the vault. Leftover native is swept back.
    function mintPosition(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 keeperPrice
    ) external nonReentrant onlyKeeper whenNotPaused notEmergency returns (uint256 tokenId) {
        _checkKeeperPrice(keeperPrice);
        if (_positions.length >= MAX_POSITIONS) revert TooManyPositions();
        tokenId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(A_MINT, A_SETTLE_PAIR, A_SWEEP);
        bytes[] memory ps = new bytes[](3);
        ps[0] = abi.encode(poolKey(), tickLower, tickUpper, uint256(liquidity), amount0Max, amount1Max, address(this), bytes(""));
        ps[1] = abi.encode(currency0, currency1);
        ps[2] = abi.encode(currency0, address(this));
        _modify(actions, ps, amount0Max, amount1Max);
        if (positionManager.ownerOf(tokenId) != address(this)) revert MintFailed();
        _positions.push(V4PositionMath.Position(tokenId, tickLower, tickUpper));
        _checkReserve();
        emit PositionMinted(tokenId, tickLower, tickUpper, liquidity);
    }

    /// @notice Add liquidity to an existing vault position (accrued fees net against the payment).
    function increasePosition(uint256 tokenId, uint128 liquidity, uint128 amount0Max, uint128 amount1Max, uint256 keeperPrice)
        external
        nonReentrant
        onlyKeeper
        whenNotPaused
        notEmergency
    {
        _checkKeeperPrice(keeperPrice);
        _indexOf(tokenId);
        bytes memory actions = abi.encodePacked(A_INCREASE, A_CLOSE_CURRENCY, A_CLOSE_CURRENCY, A_SWEEP);
        bytes[] memory ps = new bytes[](4);
        ps[0] = abi.encode(tokenId, uint256(liquidity), amount0Max, amount1Max, bytes(""));
        ps[1] = abi.encode(currency0);
        ps[2] = abi.encode(currency1);
        ps[3] = abi.encode(currency0, address(this));
        _modify(actions, ps, amount0Max, amount1Max);
        _checkReserve();
        emit PositionIncreased(tokenId, liquidity);
    }

    /// @notice Remove liquidity (0 = collect fees only) into the vault. Risk-reducing: allowed while paused.
    function decreasePosition(uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min)
        external
        nonReentrant
        onlyKeeper
        notEmergency
    {
        _indexOf(tokenId);
        bytes memory actions = abi.encodePacked(A_DECREASE, A_TAKE_PAIR);
        bytes[] memory ps = new bytes[](2);
        ps[0] = abi.encode(tokenId, uint256(liquidity), amount0Min, amount1Min, bytes(""));
        ps[1] = abi.encode(currency0, currency1, address(this));
        _modify(actions, ps, 0, 0);
        emit PositionDecreased(tokenId, liquidity);
    }

    /// @notice Remove all liquidity + fees and burn the NFT. Risk-reducing: allowed while paused.
    function burnPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min)
        external
        nonReentrant
        onlyKeeper
        notEmergency
    {
        uint256 i = _indexOf(tokenId);
        _modify(_burnActions(), _burnParams(tokenId, amount0Min, amount1Min), 0, 0);
        _removeAt(i);
        emit PositionBurned(tokenId);
    }

    function _burnActions() internal pure returns (bytes memory) {
        return abi.encodePacked(A_BURN, A_TAKE_PAIR);
    }

    function _burnParams(uint256 tokenId, uint128 min0, uint128 min1) internal view returns (bytes[] memory ps) {
        ps = new bytes[](2);
        ps[0] = abi.encode(tokenId, min0, min1, bytes(""));
        ps[1] = abi.encode(currency0, currency1, address(this));
    }

    function _removeAt(uint256 i) internal {
        uint256 last = _positions.length - 1;
        if (i != last) _positions[i] = _positions[last];
        _positions.pop();
    }

    /// @dev Calls PositionManager with exact, same-tx Permit2 allowances for ERC-20 legs and msg.value for native.
    function _modify(bytes memory actions, bytes[] memory ps, uint128 max0, uint128 max1) internal {
        uint256 value;
        if (currency0 == address(0)) value = max0;
        else if (max0 != 0) permit2.approve(currency0, address(positionManager), max0, uint48(block.timestamp));
        if (max1 != 0) permit2.approve(currency1, address(positionManager), max1, uint48(block.timestamp));
        positionManager.modifyLiquidities{value: value}(abi.encode(actions, ps), block.timestamp);
        if (currency0 != address(0) && max0 != 0) permit2.approve(currency0, address(positionManager), 0, 0);
        if (max1 != 0) permit2.approve(currency1, address(positionManager), 0, 0);
    }

    function _unwindAll() internal override {
        uint256 i = _positions.length;
        while (i != 0) {
            --i;
            uint256 id = _positions[i].tokenId;
            try positionManager.modifyLiquidities(abi.encode(_burnActions(), _burnParams(id, 0, 0)), block.timestamp) {
                _removeAt(i);
                emit PositionBurned(id);
            } catch (bytes memory reason) {
                emit PositionUnwindFailed(id, reason);
            }
        }
    }

    // ------------------------------------------------------------------ keeper: swaps
    /// @notice Exact-input swap through the configured pool only. minOut = fair value at `keeperPrice` minus
    ///         `maxSlippageBps`; `keeperPrice` must be within `poolBandBps` of the pool and `refDriftBps` of the last
    ///         settled price; cumulative swap notional per epoch <= `swapTurnoverBps` of the last NAV.
    function swap(bool sellBase, uint256 amountIn, uint256 keeperPrice)
        external
        nonReentrant
        onlyKeeper
        whenNotPaused
        notEmergency
        returns (uint256 out)
    {
        if (amountIn == 0) revert ZeroAmount();
        _checkKeeperPrice(keeperPrice);
        uint256 fair = sellBase ? Math.mulDiv(amountIn, keeperPrice, WAD) : Math.mulDiv(amountIn, WAD, keeperPrice);
        _useTurnover(sellBase ? fair : amountIn);
        uint256 minOut = Math.mulDiv(fair, BPS - params.maxSlippageBps, BPS);
        bool zeroForOne = sellBase == baseIsCurrency0;
        _swapping = true;
        out = abi.decode(poolManager.unlock(abi.encode(zeroForOne, amountIn)), (uint256));
        _swapping = false;
        if (out < minOut) revert BelowMinOut(out, minOut);
        _checkReserve();
        emit Swapped(sellBase, amountIn, out, keeperPrice);
    }

    /// @notice Unwrap wrapped base (e.g. WHYPE) into native base. Value-neutral.
    function unwrapBase(uint256 amount) external nonReentrant onlyKeeper {
        if (wrappedBase == address(0) || baseToken != address(0)) revert BadParam();
        IWrappedNative(wrappedBase).withdraw(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_swapping) revert NotPoolManager();
        (bool zeroForOne, uint256 amountIn) = abi.decode(data, (bool, uint256));
        BalanceDelta d = poolManager.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        (address cIn, address cOut) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        // exact input: dIn <= 0 (owed by the vault), dOut >= 0 (owed to the vault); negation is checked
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 pay = uint256(uint128(-dIn));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 got = uint256(uint128(dOut));
        if (cIn == address(0)) {
            poolManager.settle{value: pay}();
        } else {
            poolManager.sync(Currency.wrap(cIn));
            IERC20(cIn).safeTransfer(address(poolManager), pay);
            poolManager.settle();
        }
        poolManager.take(Currency.wrap(cOut), address(this), got);
        return abi.encode(got);
    }
}
