// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {SALib} from "./SALib.sol";
import {SARange} from "./SARange.sol";

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

    /// @notice Per tracked position: the liquidity the books account for, (SA-5 M-1) PoolManager's liquidity of the
    ///         position at the books' last look, (SA-3 M-1) PoolManager's feeGrowthInside{0,1}LastX128 of the position
    ///         and (SA-4 H-1) the pool's feeGrowthGlobal{0,1}X128 as of the moment that fee mark was taken (SA-5 L-2:
    ///         the global mark moves only when the position's mark moves, so both span the same interval).
    struct Pos {
        uint128 liq;
        uint128 seen;
        uint256 g0;
        uint256 g1;
        uint256 G0;
        uint256 G1;
    }

    /// @notice Book live state - snapshot as a client flow at `price` and move the snapshot to the live state.
    ///         First, at every sync (also while the anchor is not trusted; it needs no price): LP fees that left a
    ///         tracked position outside a module action (the client's own collect) are added to the snapshot, exactly
    ///         as the module books its own collects, so they stay yield and never become a contribution (SA-3 M-1).
    ///         SA-4 H-1 / SA-5 M-1: only for a position nobody changed since the mark (still owned, PoolManager and
    ///         the books on the same liquidity now AND at the last look), only up to the pool's global fee growth over
    ///         the same interval (a larger or wrapped difference means PoolManager re-based the position), only while
    ///         idle holds no less than the snapshot in EITHER token (a dip and restore at another price changes the
    ///         mix: one token up, the other down; that is not yield) and never more than idle holds above the
    ///         snapshot in each token. Every guard can only LOWER the yield counted (a client modify's fees then
    ///         become a contribution: our fee lower). SA-6 L-1: nothing at all in a sync where ANY tracked position
    ///         is pending (not owned, or PoolManager's liquidity differs from the books'): its pending principal sits
    ///         in idle too and must not serve as room for another position's credit.
    ///         Then, `price` = 0 (anchor not trusted): nothing else is booked or moved; the flow stays pending.
    ///         Positions the account no longer owns are dropped (their snapshot liquidity is an outflow).
    ///         SA-4 M-2 / SA-5 L-1: a booked flow whose price-dependent part (idle base, position liquidity) is at least
    ///         1% of the net contributions stamps `pricedFlowTime`; the fee waits a day after it (dust sent by a third
    ///         party does not). SA-6 M-1 (replaces SA-5 M-4): a pending flow happened at some market price between the
    ///         account's last priced sync (bookTime, at the anchor bookPrice) and now, not necessarily at either
    ///         anchor. Every priced booking raises the high-water mark by priced x d / lo, where [lo, hi] spans
    ///         bookPrice, this anchor and every keeper report recorded since bookTime's 3 h bucket (PriceBudget.seen,
    ///         each report within poolBandBps of the pool) and d is the larger distance of this anchor from lo or hi.
    ///         A base or liquidity value V(P) is concave with V(0) >= 0, so |V(P') - V(P)| <= V(P) x |P' - P| / P
    ///         <= priced x d / lo for any P' in [lo, hi]: the raise covers the flow at any recorded price, in both
    ///         directions. If bookTime is older than the 24 h ring, the raise is the whole priced value (it covers
    ///         any outflow, whose value at the flow cannot be below 0). Only the high-water mark rises: a late
    ///         booking can only lower the fee (the keeper refreshes bookTime with a sync while nothing is pending).
    function sync(
        SALib.Account storage s,
        V4PositionMath.Position[] storage ps,
        mapping(uint256 => Pos) storage pos,
        address a,
        SALib.Venue storage v,
        uint256 price,
        SALib.PriceBudget storage pb
    ) external {
        int256 f;
        uint256 priced;
        uint256 i = ps.length;
        bool dirty = _dirty(ps, pos, v, a); // SA-6 L-1
        while (i != 0) {
            --i;
            V4PositionMath.Position memory p = ps[i];
            Pos storage q = pos[p.tokenId];
            (uint128 liq, bool owned) = _liquidityOf(v.posm, a, p.tokenId);
            uint128 old = q.liq;
            _feesOut(s, q, v, a, p, !dirty && owned && liq == old ? old : 0);
            if (price == 0) continue;
            if (liq != old) {
                uint256 lv = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, price, v.baseIsCurrency0);
                uint256 ov = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, old, price, v.baseIsCurrency0);
                priced += lv > ov ? lv - ov : ov - lv;
                // forge-lint: disable-next-line(unsafe-typecast)
                f += int256(lv) - int256(ov);
            }
            if (owned) {
                q.liq = liq;
            } else {
                delete pos[p.tokenId];
                uint256 last = ps.length - 1;
                if (i != last) ps[i] = ps[last];
                ps.pop();
            }
        }
        if (price != 0) _bookIdle(s, v, a, price, f, priced, pb);
    }

    /// @dev `sync` at a trusted anchor, after the positions: book idle - snapshot and the positions' flow `f`
    ///      (`priced` = its price-dependent part so far), stamp pricedFlowTime, raise the high-water mark (SA-6 M-1).
    function _bookIdle(
        SALib.Account storage s,
        SALib.Venue storage v,
        address a,
        uint256 price,
        int256 f,
        uint256 priced,
        SALib.PriceBudget storage pb
    ) private {
        int256 x = int256(IERC20(v.asset).balanceOf(a));
        int256 b = int256(_bal(v.base, a));
        int256 fb = _mul(b - s.snapBase, price);
        // forge-lint: disable-next-line(unsafe-typecast)
        priced += uint256(fb < 0 ? -fb : fb);
        f += x - s.snapAsset + fb;
        int256 c = s.contributed;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (priced != 0 && priced * 100 >= uint256(c < 0 ? -c : c)) s.pricedFlowTime = block.timestamp; // SA-5 L-1
        if (priced != 0) s.hwm += SafeCast.toInt256(_late(s, pb, priced, price)); // SA-6 M-1, I-9
        s.bookPrice = price;
        s.bookTime = block.timestamp;
        s.snapAsset = x;
        s.snapBase = b;
        if (f != 0) {
            s.contributed = c + f;
            emit Flow(a, f);
        }
    }

    /// @dev SA-6 L-1: some tracked position is pending (not owned, or PoolManager's liquidity differs from the books').
    function _dirty(
        V4PositionMath.Position[] storage ps,
        mapping(uint256 => Pos) storage pos,
        SALib.Venue storage v,
        address a
    ) private view returns (bool) {
        for (uint256 j; j < ps.length; ++j) {
            uint256 id = ps[j].tokenId;
            (uint128 l, bool o) = _liquidityOf(v.posm, a, id);
            if (!o || l != pos[id].liq) return true;
        }
        return false;
    }

    /// @dev SA-6 M-1: the high-water-mark raise of a priced booking of `priced` at `price` (see `sync`).
    function _late(SALib.Account storage s, SALib.PriceBudget storage pb, uint256 priced, uint256 price)
        private
        view
        returns (uint256)
    {
        (uint256 lo, uint256 hi, bool ok) = SARange.since(pb.seen, price, s.bookTime);
        if (!ok) return priced;
        uint256 p0 = s.bookPrice;
        if (p0 != 0 && p0 < lo) lo = p0;
        if (p0 > hi) hi = p0;
        return Math.mulDiv(priced, Math.max(hi - price, price - lo), lo, Math.Rounding.Ceil);
    }

    /// @dev SA-3 M-1: fees paid out of position `p` since the books' last look, for liquidity `n` (the snapshot when
    ///      the position is owned and unchanged, else 0), added to the snapshot as yield. SA-4 H-1: the difference of
    ///      the position's fee mark is credited only while it does not exceed the pool's global growth since the mark
    ///      (inside growth on one basis never does), and the credit never exceeds the idle surplus above the snapshot.
    ///      SA-5 M-1: nothing if PoolManager's liquidity at the last look differed (a dip seen by any sync), or if idle
    ///      is below the snapshot in either token (Option A of the report). SA-5 L-2: the global mark moves only with
    ///      the position's mark.
    function _feesOut(SALib.Account storage s, Pos storage q, SALib.Venue storage v, address a, V4PositionMath.Position memory p, uint128 n)
        private
    {
        (uint128 pl, uint256 l0, uint256 l1) =
            v.pm.getPositionInfo(v.id, address(v.posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
        (uint256 G0, uint256 G1) = v.pm.getFeeGrowthGlobals(v.id);
        if (q.seen != n) n = 0; // SA-5 M-1: PoolManager's liquidity differed at the last look
        uint256 c0;
        uint256 c1;
        unchecked {
            uint256 d0 = l0 - q.g0;
            uint256 d1 = l1 - q.g1;
            if (d0 > G0 - q.G0 || d1 > G1 - q.G1) n = 0; // re-based by PoolManager (cleared tick): count nothing
            c0 = FullMath.mulDiv(d0, n, 1 << 128);
            c1 = FullMath.mulDiv(d1, n, 1 << 128);
        }
        if (v.baseIsCurrency0) _credit(s, v, a, c1, c0);
        else _credit(s, v, a, c0, c1);
        _mark(q, pl, l0, l1, G0, G1);
    }

    /// @dev Add the credit (ca asset, cb base) to the snapshot: nothing if idle is below the snapshot in either token
    ///      (SA-5 M-1, a mix change is not yield), and never more than idle holds above it in each token.
    function _credit(SALib.Account storage s, SALib.Venue storage v, address a, uint256 ca, uint256 cb) private {
        int256 ra = int256(IERC20(v.asset).balanceOf(a)) - s.snapAsset;
        int256 rb = int256(_bal(v.base, a)) - s.snapBase;
        if (ra < 0 || rb < 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.snapAsset += int256(_cap(ca, ra));
        // forge-lint: disable-next-line(unsafe-typecast)
        s.snapBase += int256(_cap(cb, rb));
    }

    function _cap(uint256 c, int256 room) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return room <= 0 ? 0 : (c > uint256(room) ? uint256(room) : c);
    }

    /// @dev SA-5 L-2: the global mark moves only when the position's fee mark moves (both span one interval).
    function _mark(Pos storage q, uint128 pl, uint256 l0, uint256 l1, uint256 G0, uint256 G1) private {
        if (l0 != q.g0 || l1 != q.g1) {
            q.G0 = G0;
            q.G1 = G1;
        }
        q.g0 = l0;
        q.g1 = l1;
        q.seen = pl;
    }

    /// @notice The module's own effect after a PositionManager call it made on `p` (SA-3: the writes live here):
    ///         idle moves by (dAsset, dBase), the books' liquidity by dLiq, and the fee mark is PoolManager's
    ///         feeGrowthInsideLast after the call (the fees that call paid are already in dAsset / dBase).
    function book(
        SALib.Account storage s,
        mapping(uint256 => Pos) storage pos,
        SALib.Venue storage v,
        V4PositionMath.Position memory p,
        int256 dAsset,
        int256 dBase,
        int256 dLiq
    ) external {
        s.snapAsset += dAsset;
        s.snapBase += dBase;
        Pos storage q = pos[p.tokenId];
        q.liq = SafeCast.toUint128(SafeCast.toUint256(int256(uint256(q.liq)) + dLiq)); // SA-4 I-5
        (uint128 pl, uint256 l0, uint256 l1) =
            v.pm.getPositionInfo(v.id, address(v.posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
        (uint256 G0, uint256 G1) = v.pm.getFeeGrowthGlobals(v.id);
        q.G0 = G0; // the module touched the position: both marks are taken now
        q.G1 = G1;
        q.g0 = l0;
        q.g1 = l1;
        q.seen = pl;
    }

    /// @notice Account value at `price`: idle + positions the account still owns (principal at sqrt(price) plus
    ///         uncollected fees, base valued at `price`; no pool-spot term) + attributed hedge equity.
    function value(
        SALib.Venue storage v,
        SALib.Account storage s,
        V4PositionMath.Position[] storage ps,
        address a,
        uint256 price
    ) external view returns (uint256) {
        return _value(v, s, ps, a, price);
    }

    /// @notice SA-4 M-3 (1241): the value every keeper budget and the fee are measured on: `value` without hedge
    ///         equity above the net margin the account really sent (a guardian-approved gain widens no window and
    ///         carries no fee until the treasury returns it into the account).
    function nav(
        SALib.Venue storage v,
        SALib.Account storage s,
        V4PositionMath.Position[] storage ps,
        address a,
        uint256 price
    ) external view returns (uint256 val) {
        val = _value(v, s, ps, a, price);
        uint256 h = s.hedgeEquity;
        uint256 m = s.netMargin;
        if (h > m) val -= h - m;
    }

    function _value(
        SALib.Venue storage v,
        SALib.Account storage s,
        V4PositionMath.Position[] storage ps,
        address a,
        uint256 price
    ) private view returns (uint256 val) {
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
    ///         turnover charge: SA-5 M-2, the whole principal (an add next to a pushed pool is a limit order at that
    ///         price: it costs the window what a swap of the same principal costs).
    function lpAdd(SALib.Venue storage v, V4PositionMath.Position memory p, uint128 liq, uint256 ref, uint256 slip)
        external
        view
        returns (int256 dAsset, int256 dBase, uint256 charge)
    {
        (uint256 pa, uint256 pb) = _principal(v, p, liq, true);
        uint256 paid = pa + Math.mulDiv(pb, ref, WAD, Math.Rounding.Ceil);
        uint256 got = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, ref, v.baseIsCurrency0);
        if (got * BPS < paid * (BPS - slip)) revert SALib.AddValue(got, paid);
        charge = paid;
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
    ///         stays a pending flow on both sides (position and idle), so it is booked exactly once. SA-4 L-3: m is also
    ///         at most the live PoolManager liquidity (a burn after a direct client decrease books only what it
    ///         removes; the rest of the snapshot stays tracked until the next priced sync books it as an outflow).
    function lpRemove(SALib.Venue storage v, V4PositionMath.Position memory p, uint128 liq, bool burn, uint128 snap)
        external
        view
        returns (int256 dAsset, int256 dBase, uint128 m)
    {
        (uint128 live, uint256 fa, uint256 fb) = _feesAB(v, p);
        m = burn || liq > snap ? snap : liq;
        if (m > live) m = live;
        (uint256 pa, uint256 pb) = _principal(v, p, m, false);
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
