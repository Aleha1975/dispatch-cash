"""Uniswap v4 price / tick / liquidity math (integer X96, Decimal for tick -> sqrt price).

Pool: currency0 = native HYPE (18 dec), currency1 = USDC (6 dec). Raw price token1/token0 = USDC raw per wei.
Keeper price P = USDC raw per 1e18 wei = USD price * 1e6.
"""
from __future__ import annotations

import math
from decimal import Decimal, localcontext

Q96 = 1 << 96
MIN_TICK, MAX_TICK = -887272, 887272
LOG_BASE = math.log(1.0001)


def sqrt_price_at_tick(tick: int) -> int:
    with localcontext() as ctx:
        ctx.prec = 80
        return int(Decimal("1.0001") ** (Decimal(tick) / 2) * Q96)


def price_from_sqrt(sp: int) -> int:
    """Keeper-price units (USDC raw per 1e18 wei), same rounding as V4PositionMath.price."""
    return (sp * sp // Q96) * 10 ** 18 // Q96


def p_to_usd(p: int) -> float:
    return p / 1e6


def usd_to_p(usd: float) -> int:
    return int(round(usd * 1e6))


def tick_at_price(p: float) -> float:
    """Unrounded tick for keeper price p (USDC raw per 1e18 wei)."""
    return math.log(p / 1e18) / LOG_BASE


def floor_tick(t: float, spacing: int) -> int:
    return int(math.floor(t / spacing)) * spacing


def ceil_tick(t: float, spacing: int) -> int:
    return int(math.ceil(t / spacing)) * spacing


def liquidity_for_amounts(sp: int, sa: int, sb: int, a0: int, a1: int) -> int:
    if sa > sb:
        sa, sb = sb, sa
    if sp <= sa:
        return a0 * sa * sb // Q96 // (sb - sa)
    if sp < sb:
        l0 = a0 * sp * sb // Q96 // (sb - sp)
        l1 = a1 * Q96 // (sp - sa)
        return min(l0, l1)
    return a1 * Q96 // (sb - sa)


def amounts_for_liquidity(sp: int, sa: int, sb: int, liq: int) -> tuple[int, int]:
    if sa > sb:
        sa, sb = sb, sa
    if sp <= sa:
        return liq * Q96 * (sb - sa) // sb // sa, 0
    if sp < sb:
        return liq * Q96 * (sb - sp) // sb // sp, liq * (sp - sa) // Q96
    return 0, liq * (sb - sa) // Q96


def base_value_fraction(sp: int, tl: int, tu: int) -> float:
    """Share of position value held in the base token (HYPE) at sqrt price sp."""
    sa, sb = sqrt_price_at_tick(tl), sqrt_price_at_tick(tu)
    a0, a1 = amounts_for_liquidity(sp, sa, sb, 10 ** 24)
    v0 = a0 * price_from_sqrt(sp) / 1e18
    tot = v0 + a1
    return v0 / tot if tot else 0.0
