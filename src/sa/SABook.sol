// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {SALib} from "./SALib.sol";

/// @title SABook
/// @notice Linked (external) library of the LPManagerModule: the per-account books (audit SA-2 root-cause class B',
///         docs/audit/sa_round2_rootcause.md).
///
///         ONE RULE: the snapshot (idle asset, idle base, the liquidity of every tracked position) is the state the
///         books already account for. It is never read back from the account after a module action; the module
///         ADDS its own effect to it, computed from state the account's code cannot write (PoolManager slot0 and
///         position info before the action, the liquidity the module asked PositionManager to add or remove, the
///         SwapExecutor's per-payer record, the verified recipient delta of a transfer). Therefore
///             live state - snapshot == everything the client did, inside or outside a module bracket,
///         and `sync` books exactly that, valued with the SAME function and the SAME price as `value` (the anchor),
///         and only while the anchor is trusted (the caller passes price 0 otherwise: the flow stays pending, exact,
///         in the difference). A client flow therefore moves `value` and `contributed` by the same amount at the
///         moment it is booked and cannot change `profit`, whatever the pool spot or the anchor lag is.
library SABook {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    event Flow(address indexed account, int256 value);

    /// @notice Book live state - snapshot as a client flow at `price` and move the snapshot to the live state.
    ///         `price` = 0 (anchor not trusted): nothing is booked or moved; the flow stays pending. Positions the
    ///         account no longer owns are dropped (their snapshot liquidity is an outflow).
    function sync(
        SALib.Account storage s,
        V4PositionMath.Position[] storage ps,
        mapping(uint256 => uint128) storage snapLiq,
        address a,
        SALib.Venue storage v,
        uint256 price
    ) external {
        if (price == 0) return;
        int256 x = int256(IERC20(v.asset).balanceOf(a));
        int256 b = int256(_bal(v.base, a));
        int256 f = x - s.snapAsset + _mul(b - s.snapBase, price);
        uint256 i = ps.length;
        while (i != 0) {
            --i;
            V4PositionMath.Position memory p = ps[i];
            (uint128 liq, bool owned) = _liquidityOf(v.posm, a, p.tokenId);
            uint128 old = snapLiq[p.tokenId];
            if (liq != old) {
                // forge-lint: disable-next-line(unsafe-typecast)
                f += int256(V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, price, v.baseIsCurrency0))
                    // forge-lint: disable-next-line(unsafe-typecast)
                    - int256(V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, old, price, v.baseIsCurrency0));
            }
            if (owned) {
                snapLiq[p.tokenId] = liq;
            } else {
                delete snapLiq[p.tokenId];
                uint256 last = ps.length - 1;
                if (i != last) ps[i] = ps[last];
                ps.pop();
            }
        }
        s.snapAsset = x;
        s.snapBase = b;
        if (f != 0) {
            s.contributed += f;
            emit Flow(a, f);
        }
    }

    /// @notice Account value at `price`: idle + positions the account still owns (principal at sqrt(price) plus
    ///         uncollected fees, base valued at `price`; no pool-spot term) + attributed hedge equity.
    function value(
        SALib.Venue storage v,
        SALib.Account storage s,
        V4PositionMath.Position[] storage ps,
        address a,
        uint256 price
    ) external view returns (uint256 val) {
        val = IERC20(v.asset).balanceOf(a) + Math.mulDiv(_bal(v.base, a), price, WAD) + s.hedgeEquity;
        for (uint256 i; i < ps.length; ++i) {
            V4PositionMath.Position memory p = ps[i];
            (, bool owned) = _liquidityOf(v.posm, a, p.tokenId);
            if (owned) {
                (uint128 liq, uint256 f0, uint256 f1) = _fees(v, p);
                if (liq == 0) continue;
                (uint256 fb, uint256 fa) = v.baseIsCurrency0 ? (f0, f1) : (f1, f0);
                val += V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, price, v.baseIsCurrency0) + fa
                    + Math.mulDiv(fb, price, WAD);
            }
        }
    }

    /// @notice The module's own effect of adding `liq` to `p` (a new position or a tracked one), computed from
    ///         PoolManager state before the action: idle falls by the principal PoolManager charges at the current
    ///         sqrt price (rounded up, as PoolManager does) and rises by the uncollected fees the modify pays out.
    ///         H-3 add check at the anchor `ref` (the principal is worth at most got / (1 - slippage)); returns the
    ///         turnover charge principal x slippage / (band + slippage).
    function lpAdd(SALib.Venue storage v, V4PositionMath.Position memory p, uint128 liq, uint256 ref, uint256 slip, uint256 band)
        external
        view
        returns (int256 dAsset, int256 dBase, uint256 charge)
    {
        (uint256 pa, uint256 pb) = _principal(v, p, liq, true);
        uint256 paid = pa + Math.mulDiv(pb, ref, WAD, Math.Rounding.Ceil);
        uint256 got = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, ref, v.baseIsCurrency0);
        if (got * BPS < paid * (BPS - slip)) revert SALib.AddValue(got, paid);
        charge = Math.mulDiv(paid, slip, slip + band, Math.Rounding.Ceil);
        (, uint256 fa, uint256 fb) = _feesAB(v, p);
        // forge-lint: disable-next-line(unsafe-typecast)
        dAsset = int256(fa) - int256(pa);
        // forge-lint: disable-next-line(unsafe-typecast)
        dBase = int256(fb) - int256(pb);
    }

    /// @notice The module's own effect of removing liquidity from tracked position `p` whose snapshot liquidity is
    ///         `snap`: the module removes `liq` (burn: everything), of which only m = min(liq, snap) (burn: snap) is
    ///         liquidity the books account for; idle rises by the principal of m at the current sqrt price (rounded
    ///         down, as PoolManager pays) plus the uncollected fees. Liquidity the client added or removed directly
    ///         stays a pending flow on both sides (position and idle), so it is booked exactly once.
    function lpRemove(SALib.Venue storage v, V4PositionMath.Position memory p, uint128 liq, bool burn, uint128 snap)
        external
        view
        returns (int256 dAsset, int256 dBase, uint128 m)
    {
        m = burn || liq > snap ? snap : liq;
        (uint256 pa, uint256 pb) = _principal(v, p, m, false);
        (, uint256 fa, uint256 fb) = _feesAB(v, p);
        // forge-lint: disable-next-line(unsafe-typecast)
        dAsset = int256(pa + fa);
        // forge-lint: disable-next-line(unsafe-typecast)
        dBase = int256(pb + fb);
    }

    // ------------------------------------------------------------------ internals
    function _principal(SALib.Venue storage v, V4PositionMath.Position memory p, uint128 liq, bool up)
        private
        view
        returns (uint256 pa, uint256 pb)
    {
        (uint160 sp,,,) = v.pm.getSlot0(v.id);
        uint160 sa = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(p.tickUpper);
        uint256 a0;
        uint256 a1;
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, liq, up);
        } else if (sp < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, liq, up);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, liq, up);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, liq, up);
        }
        (pb, pa) = v.baseIsCurrency0 ? (a0, a1) : (a1, a0);
    }

    function _fees(SALib.Venue storage v, V4PositionMath.Position memory p)
        private
        view
        returns (uint128 liq, uint256 f0, uint256 f1)
    {
        uint256 last0;
        uint256 last1;
        (liq, last0, last1) = v.pm.getPositionInfo(v.id, address(v.posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
        if (liq == 0) return (0, 0, 0);
        (uint256 in0, uint256 in1) = v.pm.getFeeGrowthInside(v.id, p.tickLower, p.tickUpper);
        unchecked {
            f0 = FullMath.mulDiv(in0 - last0, liq, 1 << 128);
            f1 = FullMath.mulDiv(in1 - last1, liq, 1 << 128);
        }
    }

    function _feesAB(SALib.Venue storage v, V4PositionMath.Position memory p)
        private
        view
        returns (uint128 liq, uint256 fa, uint256 fb)
    {
        uint256 f0;
        uint256 f1;
        (liq, f0, f1) = _fees(v, p);
        (fb, fa) = v.baseIsCurrency0 ? (f0, f1) : (f1, f0);
    }

    /// @dev x * price / 1e18, signed, rounded toward minus infinity.
    function _mul(int256 x, uint256 price) private pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (x >= 0) return int256(Math.mulDiv(uint256(x), price, WAD));
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int256(Math.mulDiv(uint256(-x), price, WAD, Math.Rounding.Ceil));
    }

    function _bal(address token, address a) private view returns (uint256) {
        return token == address(0) ? a.balance : IERC20(token).balanceOf(a);
    }

    function _liquidityOf(IPositionManagerMin posm, address a, uint256 tokenId) private view returns (uint128, bool) {
        try posm.ownerOf(tokenId) returns (address o) {
            if (o != a) return (0, false);
        } catch {
            return (0, false);
        }
        return (posm.getPositionLiquidity(tokenId), true);
    }
}
