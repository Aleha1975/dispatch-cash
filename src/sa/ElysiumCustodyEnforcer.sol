// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ICaveatEnforcer, ModeCode} from "./vendor/DelegationFramework.sol";
import {SAWindow} from "./SAWindow.sol";

interface IPositionManagerView {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
}

/// @title ElysiumCustodyEnforcer
/// @notice Caveat enforcer (MetaMask Delegation Framework v1.3.0) that a client signs into its delegation to the
///         LPManagerModule. It is the client-visible custody guarantee and does not trust the module: every single
///         execution redeemed under the delegation must be one of the shapes below, everything else reverts
///         (default deny, including any native value transfer).
///
///         | target            | call                               | checks                                              |
///         |-------------------|------------------------------------|-----------------------------------------------------|
///         | PositionManager   | modifyLiquidities(unlockData, dl)  | canonical ABI encoding; actions only MINT, INCREASE, |
///         |                   |                                    | DECREASE, BURN, SETTLE_PAIR, TAKE_PAIR, CLOSE_CURRENCY|
///         |                   |                                    | SWEEP; pool key == the fixed pool; MINT owner,      |
///         |                   |                                    | TAKE_PAIR and SWEEP recipients == delegator; empty  |
///         |                   |                                    | hookData; tokenIds owned by the delegator and in the|
///         |                   |                                    | fixed pool; native value only with a final SWEEP of |
///         |                   |                                    | native back to the delegator                        |
///         | SwapExecutor      | swap(zeroForOne, amountIn, minOut, | canonical; amountIn, minOut > 0; value == amountIn  |
///         |                   |      sqrtPriceLimitX96)            | for native input, else 0 (executor pays msg.sender) |
///         | Permit2           | approve(token, spender, amt, exp)  | token = a pool ERC-20; spender = PositionManager or |
///         |                   |                                    | SwapExecutor; amt <= delegator balance; expiring in |
///         |                   |                                    | this block (exp 0 or now); amt 0 always allowed     |
///         | pool ERC-20       | approve(Permit2, amt)              | amt <= delegator balance                            |
///         | asset (USDC)      | transfer(hedgeTreasury, amt)       | <= HEDGE_DAY_BPS (35%) of the delegator's USDC per  |
///         |                   |                                    | sliding 24 h window (fraction of the balance at each|
///         |                   |                                    | send; a rate on idle USDC, not a cap on the total)  |
///         | asset (USDC)      | transfer(feeRecipient, amt)        | <= FEE_MAX_BPS (20%) of the USDC balance, at most   |
///         |                   |                                    | once per FEE_INTERVAL (7 days)                      |
///
///         Execution mode must be single call, revert-on-failure, no selector/payload (ModeCode 0). The redeemer
///         must be the module named in the signed terms. Terms (signed by the client, 96 bytes):
///         abi.encode(address module, address hedgeTreasury, address feeRecipient).
///         Stateful hooks run only for the DelegationManager; state is per (delegator, keccak256(terms)), so a
///         second delegation the client signs with other terms cannot consume this one's limits (audit SA-1 M-6), and
///         a renewal with the same terms keeps its history.
contract ElysiumCustodyEnforcer is ICaveatEnforcer {
    // v4-periphery Actions codes
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint8 internal constant CLOSE_CURRENCY = 0x12;
    uint8 internal constant SWEEP = 0x14;

    uint256 public constant MAX_ACTIONS = 16;
    uint256 public constant HEDGE_DAY_BPS = 3_500;
    uint256 public constant FEE_MAX_BPS = 2_000;
    uint256 public constant FEE_INTERVAL = 7 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    bytes4 internal constant MODIFY_LIQUIDITIES = bytes4(keccak256("modifyLiquidities(bytes,uint256)"));
    bytes4 internal constant EXECUTOR_SWAP = bytes4(keccak256("swap(bool,uint256,uint256,uint160)"));
    bytes4 internal constant PERMIT2_APPROVE = bytes4(keccak256("approve(address,address,uint160,uint48)"));
    bytes4 internal constant ERC20_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 internal constant ERC20_TRANSFER = bytes4(keccak256("transfer(address,uint256)"));

    address public immutable delegationManager;
    address public immutable positionManager;
    address public immutable permit2;
    address public immutable swapExecutor;
    address public immutable asset;
    address public immutable currency0;
    address public immutable currency1;
    bytes32 public immutable poolKeyHash;

    struct Spend {
        SAWindow.W hedge; // fractions (WAD) of the USDC balance sent to hedgeTreasury, sliding 24 h window
        uint64 lastFeeTime;
    }

    mapping(address delegator => mapping(bytes32 termsHash => Spend)) internal _spend;

    event HedgeTransfer(address indexed delegator, address indexed to, uint256 amount, uint256 usedWad);
    event FeeTransfer(address indexed delegator, address indexed to, uint256 amount);

    error NotDelegationManager();
    error BadMode();
    error BadTerms();
    error BadRedeemer();
    error BadExecution();
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(address target, bytes4 selector);
    error NonCanonical();
    error ActionNotAllowed(uint8 action);
    error BadPool();
    error BadRecipient(address to);
    error NotOwnedByDelegator(uint256 tokenId);
    error HookDataNotEmpty();
    error BadValue();
    error BadAmount();
    error BadSpender(address spender);
    error BadToken(address token);
    error BadExpiration();
    error HedgeBudget(uint256 usedWad, uint256 capWad);
    error FeeTooLarge(uint256 amount, uint256 max);
    error FeeTooSoon(uint256 next);

    constructor(
        address delegationManager_,
        address positionManager_,
        address permit2_,
        address swapExecutor_,
        address asset_,
        PoolKey memory key
    ) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            delegationManager_.code.length == 0 || positionManager_.code.length == 0 || permit2_.code.length == 0
                || swapExecutor_.code.length == 0 || asset_.code.length == 0 || address(key.hooks) != address(0)
                || (c0 != asset_ && c1 != asset_)
        ) revert BadPool();
        delegationManager = delegationManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        swapExecutor = swapExecutor_;
        asset = asset_;
        currency0 = c0;
        currency1 = c1;
        poolKeyHash = keccak256(abi.encode(key));
    }

    // ------------------------------------------------------------------ hooks
    function beforeAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address)
        external
        pure
    {}

    function afterHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address)
        external
        pure
    {}

    function afterAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address)
        external
        pure
    {}

    function beforeHook(
        bytes calldata terms,
        bytes calldata,
        ModeCode mode,
        bytes calldata executionCalldata,
        bytes32,
        address delegator,
        address redeemer
    ) external {
        if (msg.sender != delegationManager) revert NotDelegationManager();
        if (ModeCode.unwrap(mode) != bytes32(0)) revert BadMode();
        (address module, address hedgeTreasury, address feeRecipient) = decodeTerms(terms);
        if (redeemer != module) revert BadRedeemer();
        if (executionCalldata.length < 52) revert BadExecution();
        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata cd = executionCalldata[52:];
        if (cd.length < 4) revert BadExecution(); // no plain value transfers, no fallback calls
        bytes4 sel = bytes4(cd[0:4]);

        if (target == positionManager) {
            if (sel != MODIFY_LIQUIDITIES) revert SelectorNotAllowed(target, sel);
            _checkModify(cd[4:], value, delegator);
        } else if (target == swapExecutor) {
            if (sel != EXECUTOR_SWAP) revert SelectorNotAllowed(target, sel);
            _checkSwap(cd[4:], value);
        } else if (target == permit2) {
            if (sel != PERMIT2_APPROVE) revert SelectorNotAllowed(target, sel);
            _noValue(value);
            _checkPermit2Approve(cd[4:], delegator);
        } else if (target != address(0) && (target == currency0 || target == currency1)) {
            _noValue(value);
            if (sel == ERC20_APPROVE) {
                (address spender, uint256 amount) = _addrUint(cd[4:]);
                if (spender != permit2) revert BadSpender(spender);
                if (amount > IERC20(target).balanceOf(delegator)) revert BadAmount();
            } else if (sel == ERC20_TRANSFER && target == asset) {
                (address to, uint256 amount) = _addrUint(cd[4:]);
                _checkTransfer(_spend[delegator][keccak256(terms)], delegator, to, amount, hedgeTreasury, feeRecipient);
            } else {
                revert SelectorNotAllowed(target, sel);
            }
        } else {
            revert TargetNotAllowed(target);
        }
    }

    /// @notice terms = abi.encode(module, hedgeTreasury, feeRecipient); all non-zero and distinct.
    function decodeTerms(bytes calldata terms) public pure returns (address module, address hedgeTreasury, address feeRecipient) {
        if (terms.length != 96) revert BadTerms();
        (module, hedgeTreasury, feeRecipient) = abi.decode(terms, (address, address, address));
        if (
            module == address(0) || hedgeTreasury == address(0) || feeRecipient == address(0) || hedgeTreasury == feeRecipient
                || module == hedgeTreasury || module == feeRecipient
        ) revert BadTerms();
    }

    // ------------------------------------------------------------------ PositionManager
    function _checkModify(bytes calldata args, uint256 value, address delegator) internal view {
        (bytes memory unlockData, uint256 deadline) = abi.decode(args, (bytes, uint256));
        if (keccak256(args) != keccak256(abi.encode(unlockData, deadline))) revert NonCanonical();
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (keccak256(unlockData) != keccak256(abi.encode(actions, params))) revert NonCanonical();
        uint256 n = actions.length;
        if (n == 0 || n > MAX_ACTIONS || params.length != n) revert BadExecution();
        bool nativeSweptLast;
        for (uint256 i; i < n; ++i) {
            uint8 a = uint8(actions[i]);
            bytes memory p = params[i];
            if (a == INCREASE_LIQUIDITY || a == DECREASE_LIQUIDITY) {
                (uint256 id, uint256 liq, uint128 x0, uint128 x1, bytes memory hook) =
                    abi.decode(p, (uint256, uint256, uint128, uint128, bytes));
                _canonical(p, abi.encode(id, liq, x0, x1, hook));
                _noHook(hook);
                _checkToken(id, delegator);
            } else if (a == MINT_POSITION) {
                _checkMint(p, delegator);
            } else if (a == BURN_POSITION) {
                (uint256 id, uint128 x0, uint128 x1, bytes memory hook) = abi.decode(p, (uint256, uint128, uint128, bytes));
                _canonical(p, abi.encode(id, x0, x1, hook));
                _noHook(hook);
                _checkToken(id, delegator);
            } else if (a == SETTLE_PAIR) {
                (address c0, address c1) = abi.decode(p, (address, address));
                _canonical(p, abi.encode(c0, c1));
                if (c0 != currency0 || c1 != currency1) revert BadPool();
            } else if (a == TAKE_PAIR) {
                (address c0, address c1, address to) = abi.decode(p, (address, address, address));
                _canonical(p, abi.encode(c0, c1, to));
                if (c0 != currency0 || c1 != currency1) revert BadPool();
                if (to != delegator) revert BadRecipient(to);
            } else if (a == CLOSE_CURRENCY) {
                address c = abi.decode(p, (address));
                _canonical(p, abi.encode(c));
                _poolCurrency(c);
            } else if (a == SWEEP) {
                (address c, address to) = abi.decode(p, (address, address));
                _canonical(p, abi.encode(c, to));
                _poolCurrency(c);
                if (to != delegator) revert BadRecipient(to);
                if (i == n - 1 && c == address(0)) nativeSweptLast = true;
            } else {
                revert ActionNotAllowed(a);
            }
        }
        // native sent to PositionManager that a settle leaves over could be swept by anyone: require the sweep back
        if (value != 0 && !nativeSweptLast) revert BadValue();
    }

    function _checkMint(bytes memory p, address delegator) internal view {
        (PoolKey memory key, int24 tl, int24 tu, uint256 liq, uint128 x0, uint128 x1, address owner, bytes memory hook) =
            abi.decode(p, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        _canonical(p, abi.encode(key, tl, tu, liq, x0, x1, owner, hook));
        if (keccak256(abi.encode(key)) != poolKeyHash) revert BadPool();
        if (owner != delegator) revert BadRecipient(owner);
        _noHook(hook);
    }

    function _checkToken(uint256 id, address delegator) internal view {
        if (IPositionManagerView(positionManager).ownerOf(id) != delegator) revert NotOwnedByDelegator(id);
        (PoolKey memory key,) = IPositionManagerView(positionManager).getPoolAndPositionInfo(id);
        if (keccak256(abi.encode(key)) != poolKeyHash) revert BadPool();
    }

    function _poolCurrency(address c) internal view {
        if (c != currency0 && c != currency1) revert BadPool();
    }

    function _canonical(bytes memory got, bytes memory want) internal pure {
        if (keccak256(got) != keccak256(want)) revert NonCanonical();
    }

    function _noHook(bytes memory hook) internal pure {
        if (hook.length != 0) revert HookDataNotEmpty();
    }

    // ------------------------------------------------------------------ SwapExecutor
    function _checkSwap(bytes calldata args, uint256 value) internal view {
        if (args.length != 128) revert NonCanonical();
        (bool zeroForOne, uint256 amountIn, uint256 minOut, uint160 limit) =
            abi.decode(args, (bool, uint256, uint256, uint160));
        limit; // any limit: the executor pays msg.sender only
        if (amountIn == 0 || minOut == 0) revert BadAmount();
        address cIn = zeroForOne ? currency0 : currency1;
        if (value != (cIn == address(0) ? amountIn : 0)) revert BadValue();
    }

    // ------------------------------------------------------------------ approvals and transfers
    function _checkPermit2Approve(bytes calldata args, address delegator) internal view {
        if (args.length != 128) revert NonCanonical();
        (address token, address spender, uint160 amount, uint48 expiration) =
            abi.decode(args, (address, address, uint160, uint48));
        if (token == address(0) || (token != currency0 && token != currency1)) revert BadToken(token);
        if (spender != positionManager && spender != swapExecutor) revert BadSpender(spender);
        if (amount == 0) return; // revoking is always fine
        if (expiration != 0 && expiration != block.timestamp) revert BadExpiration(); // Permit2: 0 = this block
        if (amount > IERC20(token).balanceOf(delegator)) revert BadAmount();
    }

    /// @notice Hedge fraction used in the current 24 h window and the last fee time, for (delegator, terms).
    function spend(address delegator, bytes32 termsHash) external view returns (uint256 hedgeUsedWad, uint64 lastFeeTime) {
        Spend storage s = _spend[delegator][termsHash];
        return (SAWindow.used(s.hedge), s.lastFeeTime);
    }

    function _checkTransfer(
        Spend storage s,
        address delegator,
        address to,
        uint256 amount,
        address hedgeTreasury,
        address feeRecipient
    ) internal {
        uint256 bal = IERC20(asset).balanceOf(delegator);
        if (amount == 0 || amount > bal) revert BadAmount();
        if (to == hedgeTreasury) {
            uint256 frac = Math.mulDiv(amount, WAD, bal, Math.Rounding.Ceil);
            uint256 cap = HEDGE_DAY_BPS * (WAD / BPS);
            uint256 used = SAWindow.used(s.hedge) + frac;
            if (used > cap) revert HedgeBudget(used, cap);
            SAWindow.add(s.hedge, frac);
            emit HedgeTransfer(delegator, to, amount, used);
        } else if (to == feeRecipient) {
            uint256 max = bal * FEE_MAX_BPS / BPS;
            if (amount > max) revert FeeTooLarge(amount, max);
            if (s.lastFeeTime != 0 && block.timestamp < s.lastFeeTime + FEE_INTERVAL) {
                revert FeeTooSoon(s.lastFeeTime + FEE_INTERVAL);
            }
            s.lastFeeTime = uint64(block.timestamp);
            emit FeeTransfer(delegator, to, amount);
        } else {
            revert BadRecipient(to);
        }
    }

    function _noValue(uint256 value) internal pure {
        if (value != 0) revert BadValue();
    }

    function _addrUint(bytes calldata args) internal pure returns (address a, uint256 v) {
        if (args.length != 64) revert NonCanonical();
        (a, v) = abi.decode(args, (address, uint256));
    }
}
