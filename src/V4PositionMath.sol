// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title V4PositionMath
/// @notice Linked (external) library: valuation of PositionManager positions straight from PoolManager storage, and
///         the PositionManager `modifyLiquidities` calldata the vault sends (recipient always passed by the vault).
///         Kept out of the vault to stay under EIP-170. Pure reads / pure encoding, no state, no token movement.
library V4PositionMath {
    using StateLibrary for IPoolManager;

    // PositionManager action codes (v4-periphery Actions.sol)
    uint8 internal constant A_INCREASE = 0x00;
    uint8 internal constant A_DECREASE = 0x01;
    uint8 internal constant A_MINT = 0x02;
    uint8 internal constant A_BURN = 0x03;
    uint8 internal constant A_SETTLE_PAIR = 0x0d;
    uint8 internal constant A_TAKE_PAIR = 0x11;
    uint8 internal constant A_CLOSE_CURRENCY = 0x12;
    uint8 internal constant A_SWEEP = 0x14;

    struct Position {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice asset raw units per 1e18 base raw units from sqrtPriceX96 (token1/token0 = sqrtP^2 / 2^192).
    function price(IPoolManager pm, PoolId id, bool baseIsCurrency0) external view returns (uint256) {
        (uint160 sp,,,) = pm.getSlot0(id);
        if (baseIsCurrency0) return FullMath.mulDiv(FullMath.mulDiv(sp, sp, 1 << 96), 1e18, 1 << 96);
        return FullMath.mulDiv(FullMath.mulDiv(1 << 96, 1 << 96, sp), 1e18, sp);
    }

    /// @notice Sum of (currency0, currency1) of all positions: principal at the current pool price, rounded down,
    ///         plus uncollected fees.
    function amounts(IPoolManager pm, PoolId id, address posm, Position[] calldata ps)
        external
        view
        returns (uint256 a0, uint256 a1)
    {
        (uint160 sp,,,) = pm.getSlot0(id);
        for (uint256 i; i < ps.length; ++i) {
            (uint256 x0, uint256 x1) = _amountsOf(pm, id, posm, ps[i], sp);
            a0 += x0;
            a1 += x1;
        }
    }

    function _amountsOf(IPoolManager pm, PoolId id, address posm, Position calldata p, uint160 sp)
        private
        view
        returns (uint256 a0, uint256 a1)
    {
        (uint128 liq, uint256 last0, uint256 last1) =
            pm.getPositionInfo(id, posm, p.tickLower, p.tickUpper, bytes32(p.tokenId));
        if (liq == 0) return (0, 0);
        (a0, a1) = _principal(sp, p.tickLower, p.tickUpper, liq);
        (uint256 in0, uint256 in1) = pm.getFeeGrowthInside(id, p.tickLower, p.tickUpper);
        unchecked {
            a0 += FullMath.mulDiv(in0 - last0, liq, 1 << 128);
            a1 += FullMath.mulDiv(in1 - last1, liq, 1 << 128);
        }
    }

    /// @dev Principal of `liq` in [tl, tu) at sqrt price `sp`, rounded down (matches PoolManager burn amounts).
    function _principal(uint160 sp, int24 tl, int24 tu, uint128 liq) private pure returns (uint256 a0, uint256 a1) {
        uint160 sa = TickMath.getSqrtPriceAtTick(tl);
        uint160 sb = TickMath.getSqrtPriceAtTick(tu);
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, liq, false);
        } else if (sp < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, liq, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, liq, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, liq, false);
        }
    }

    /// @notice Asset-denominated value of `liq` in [tl, tu) if the pool sat exactly at `price` (asset raw units per
    ///         1e18 base raw units): principal at sqrt(price), base leg valued at `price`. Used to bound LP adds
    ///         against the vault's price anchor.
    function liquidityValue(int24 tl, int24 tu, uint128 liq, uint256 price, bool baseIsCurrency0)
        external
        pure
        returns (uint256)
    {
        // token1/token0 raw ratio as Q192: base=c0 -> price/1e18 ; base=c1 -> 1e18/price
        uint256 q = baseIsCurrency0 ? FullMath.mulDiv(price, 1 << 192, 1e18) : FullMath.mulDiv(1e18, 1 << 192, price);
        uint256 s = Math.sqrt(q);
        if (s < TickMath.MIN_SQRT_PRICE) s = TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) s = TickMath.MAX_SQRT_PRICE;
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint256 a0, uint256 a1) = _principal(uint160(s), tl, tu, liq);
        (uint256 b, uint256 a) = baseIsCurrency0 ? (a0, a1) : (a1, a0);
        return a + FullMath.mulDiv(b, price, 1e18);
    }

    // ------------------------------------------------------------------ PositionManager calldata
    /// @notice MINT_POSITION + SETTLE_PAIR + SWEEP(currency0 -> me).
    function mintData(PoolKey calldata key, int24 tl, int24 tu, uint256 liq, uint128 m0, uint128 m1, address me)
        external
        pure
        returns (bytes memory)
    {
        bytes[] memory ps = new bytes[](3);
        ps[0] = abi.encode(key, tl, tu, liq, m0, m1, me, bytes(""));
        ps[1] = abi.encode(key.currency0, key.currency1);
        ps[2] = abi.encode(key.currency0, me);
        return abi.encode(abi.encodePacked(A_MINT, A_SETTLE_PAIR, A_SWEEP), ps);
    }

    /// @notice INCREASE_LIQUIDITY + CLOSE_CURRENCY x2 + SWEEP(currency0 -> me).
    function increaseData(uint256 id, uint256 liq, uint128 m0, uint128 m1, address c0, address c1, address me)
        external
        pure
        returns (bytes memory)
    {
        bytes[] memory ps = new bytes[](4);
        ps[0] = abi.encode(id, liq, m0, m1, bytes(""));
        ps[1] = abi.encode(c0);
        ps[2] = abi.encode(c1);
        ps[3] = abi.encode(c0, me);
        return abi.encode(abi.encodePacked(A_INCREASE, A_CLOSE_CURRENCY, A_CLOSE_CURRENCY, A_SWEEP), ps);
    }

    /// @notice DECREASE_LIQUIDITY (liq > 0 or fee collect) or BURN_POSITION (burn = true), then TAKE_PAIR -> me.
    function removeData(bool burn, uint256 id, uint256 liq, uint128 m0, uint128 m1, address c0, address c1, address me)
        external
        pure
        returns (bytes memory)
    {
        bytes[] memory ps = new bytes[](2);
        ps[0] = burn ? abi.encode(id, m0, m1, bytes("")) : abi.encode(id, liq, m0, m1, bytes(""));
        ps[1] = abi.encode(c0, c1, me);
        return abi.encode(abi.encodePacked(burn ? A_BURN : A_DECREASE, A_TAKE_PAIR), ps);
    }
}
