// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IPermit2Transfer {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @title SwapExecutor
/// @notice Stateless exact-input router for ONE fixed Uniswap v4 pool (no hooks). Whoever calls `swap` is the only
///         payer and the only recipient: the input is pulled from `msg.sender` (ERC-20 through the caller's own,
///         same-block Permit2 allowance; native as `msg.value`), the output is taken by PoolManager straight to
///         `msg.sender`, and unspent native input (a swap stopped by its price limit) is refunded to `msg.sender`.
///         There is no other recipient parameter, no owner, no state and no token custody between calls, so a
///         client account may let a delegate call it without any recipient checks.
///         The caller bounds the trade with `minOut` (reverts below it) and `sqrtPriceLimitX96` (the pool price the
///         swap may not cross; the LPManagerModule sets it to the edge of its price anchor band).
contract SwapExecutor is IUnlockCallback, ReentrancyGuardTransient {
    using SafeCast for uint256;

    IPoolManager public immutable poolManager;
    IPermit2Transfer public immutable permit2;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    event Swapped(address indexed payer, bool zeroForOne, uint256 paid, uint256 received);

    error BadPool();
    error BadAmount();
    error BadValue();
    error BelowMinOut(uint256 out, uint256 minOut);
    error NotPoolManager();
    error RefundFailed();

    constructor(IPoolManager pm, address permit2_, PoolKey memory key) {
        if (address(key.hooks) != address(0) || address(pm).code.length == 0 || permit2_.code.length == 0) {
            revert BadPool();
        }
        poolManager = pm;
        permit2 = IPermit2Transfer(permit2_);
        currency0 = Currency.unwrap(key.currency0);
        currency1 = Currency.unwrap(key.currency1);
        fee = key.fee;
        tickSpacing = key.tickSpacing;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee, tickSpacing, IHooks(address(0)));
    }

    /// @notice Exact-input swap paid by and paid to `msg.sender`.
    /// @param sqrtPriceLimitX96 0 = no limit; otherwise the swap stops there (the unspent input stays with / is
    ///        refunded to the caller).
    function swap(bool zeroForOne, uint256 amountIn, uint256 minOut, uint160 sqrtPriceLimitX96)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        if (amountIn == 0 || minOut == 0 || amountIn > uint256(uint128(type(int128).max))) revert BadAmount();
        address cIn = zeroForOne ? currency0 : currency1;
        if (msg.value != (cIn == address(0) ? amountIn : 0)) revert BadValue();
        if (sqrtPriceLimitX96 == 0) sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 paid;
        (paid, out) = abi.decode(
            poolManager.unlock(abi.encode(msg.sender, zeroForOne, amountIn, sqrtPriceLimitX96)), (uint256, uint256)
        );
        if (out < minOut) revert BelowMinOut(out, minOut);
        if (cIn == address(0) && paid < amountIn) {
            (bool ok,) = msg.sender.call{value: amountIn - paid}("");
            if (!ok) revert RefundFailed();
        }
        emit Swapped(msg.sender, zeroForOne, paid, out);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // only reachable from our own `swap` (PoolManager calls back the locker, which is this contract)
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) revert NotPoolManager();
        (address payer, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (address, bool, uint256, uint160));
        BalanceDelta d = poolManager.swap(
            poolKey(), SwapParams({zeroForOne: zeroForOne, amountSpecified: -amountIn.toInt256(), sqrtPriceLimitX96: limit}), ""
        );
        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        (address cIn, address cOut) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        // exact input: dIn <= 0 (owed by us), dOut >= 0 (owed to us)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 pay = uint256(uint128(-dIn));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 got = uint256(uint128(dOut));
        if (pay != 0) {
            if (cIn == address(0)) {
                poolManager.sync(Currency.wrap(address(0))); // I-2: native settle requires the synced currency to be native
                poolManager.settle{value: pay}();
            } else {
                poolManager.sync(Currency.wrap(cIn));
                permit2.transferFrom(payer, address(poolManager), pay.toUint160(), cIn);
                poolManager.settle();
            }
        }
        if (got != 0) poolManager.take(Currency.wrap(cOut), payer, got);
        return abi.encode(pay, got);
    }
}
