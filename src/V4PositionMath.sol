// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title V4PositionMath
/// @notice Linked (external) library: valuation of PositionManager positions straight from PoolManager storage.
///         Kept out of the vault to stay under EIP-170. Pure reads, no state, no token movement.
library V4PositionMath {
    using StateLibrary for IPoolManager;

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
        uint160 sa = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(p.tickUpper);
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, liq, false);
        } else if (sp < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, liq, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, liq, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, liq, false);
        }
        (uint256 in0, uint256 in1) = pm.getFeeGrowthInside(id, p.tickLower, p.tickUpper);
        unchecked {
            a0 += FullMath.mulDiv(in0 - last0, liq, 1 << 128);
            a1 += FullMath.mulDiv(in1 - last1, liq, 1 << 128);
        }
    }
}
