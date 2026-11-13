"""Pure strategy math (no I/O): volatility, range, price clamp, hedge decision, crash guard, margin plan.

All functions are deterministic and unit-tested in tests/test_strategy.py.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from statistics import median

from . import v4math

BPS = 10_000


# ---------------------------------------------------------------- volatility
def log_returns(closes: list[float]) -> list[float]:
    return [math.log(b / a) for a, b in zip(closes, closes[1:]) if a > 0 and b > 0]


def realized_daily_vol(hourly_closes: list[float], lookback_h: int = 72) -> float:
    """Daily realized vol from the last `lookback_h` hourly log returns: sample stdev * sqrt(24)."""
    r = log_returns(hourly_closes[-(lookback_h + 1):])
    if len(r) < 2:
        raise ValueError("not enough candles for realized vol")
    m = sum(r) / len(r)
    var = sum((x - m) ** 2 for x in r) / (len(r) - 1)
    return math.sqrt(var) * math.sqrt(24)


def range_half_width(daily_vol: float, k: float = 2.5, lo: float = 0.03, hi: float = 0.40) -> float:
    return min(hi, max(lo, k * daily_vol))


def range_ticks(price: int, half_width: float, spacing: int = 60) -> tuple[int, int]:
    """Ticks for [P*(1-w), P*(1+w)] widened outward to the tick spacing. price in keeper units."""
    tl = v4math.floor_tick(v4math.tick_at_price(price * (1 - half_width)), spacing)
    tu = v4math.ceil_tick(v4math.tick_at_price(price * (1 + half_width)), spacing)
    lo_lim = v4math.ceil_tick(v4math.MIN_TICK, spacing)
    hi_lim = v4math.floor_tick(v4math.MAX_TICK, spacing)
    tl, tu = max(tl, lo_lim), min(tu, hi_lim)
    if tu <= tl:
        tu = tl + spacing
    return tl, tu


def in_range(tick: int, tl: int, tu: int) -> bool:
    return tl <= tick < tu


# ---------------------------------------------------------------- price choice
@dataclass
class PriceChoice:
    price: int | None  # keeper units, None = skip
    status: str  # ok | clamped | skip
    dev_bps: float  # |hl - pool| / pool


def choose_price(hl: int, pool: int, band_bps: int, safety: float = 0.8, max_dev_bps: int = 300) -> PriceChoice:
    """Contract check: |pool - P| * BPS <= P * band. Use the HL mid if it is inside `safety * band`; clamp it
    into that inner band if it is within `max_dev_bps` of the pool; otherwise skip (alert, wait for arbitrage)."""
    if hl <= 0 or pool <= 0:
        return PriceChoice(None, "skip", float("inf"))
    dev = abs(hl - pool) * BPS / pool
    b = band_bps * safety
    lo = math.ceil(pool * BPS / (BPS + b))
    hi = math.floor(pool * BPS / (BPS - b))
    if lo <= hl <= hi:
        return PriceChoice(hl, "ok", dev)
    if dev > max_dev_bps:
        return PriceChoice(None, "skip", dev)
    return PriceChoice(min(hi, max(lo, hl)), "clamped", dev)


# ---------------------------------------------------------------- vault rules (mirror of LPVaultBase / RiskBudgets)
WAD = 10 ** 18
DAY = 86400


def decayed(used: int, t: int, now: int) -> int:
    """RiskBudgets._decay: `used` spent at `t` is restored linearly over the next 24 h."""
    dt = now - t
    return 0 if dt >= DAY else used * (DAY - dt) // DAY


def turnover_room(nav: int, turnover_bps: int, used: int, t: int, now: int) -> int:
    """Remaining swap/LP-add turnover budget (asset units): swapTurnoverBps x lastNav minus the decayed use."""
    return max(0, nav * turnover_bps // 10_000 - decayed(used, t, now))


def add_charge(value: int, band_bps: int, slippage_bps: int) -> int:
    """Turnover charged by an LP add of `value` (LPVaultBase._checkAdd: weighted slippage / (band + slippage))."""
    return -(-value * slippage_bps // (slippage_bps + band_bps))


def anchor_move(p: int, ref: int, ref_drift_bps: int, used: int, t: int, now: int, paused: bool,
                approved: tuple = (0, 0, 0)) -> tuple[int, bool]:
    """Price the vault will APPLY for a settle report `p` (RiskBudgets.movePrice): free in a guardian-approved
    [lo, hi] until `until`; otherwise limited by the decaying refDriftBps budget (0 while paused). (price, clipped)"""
    lo, hi, until = approved
    if ref == 0 or (now <= until and lo <= p <= hi):
        return p, False
    cap = 0 if paused else ref_drift_bps * (WAD // BPS)
    u = decayed(used, t, now)
    room = max(0, cap - u)
    move = -(-abs(p - ref) * WAD // ref)  # ceil
    if move <= room:
        return p, False
    d = ref * room // WAD
    return (ref + d if p > ref else ref - d), True


def sticky_price(p: int, ref: int, pool: int, band_bps: int, hyst_bps: int, safety: float = 0.8) -> int:
    """Report the anchor itself while the fresh price is within `hyst_bps` of it and the anchor is still inside the
    pool band: chop then costs no anchor budget (the NAV error stays below hyst_bps of the base leg)."""
    if ref and abs(p - ref) * BPS <= ref * hyst_bps and abs(pool - ref) * BPS <= ref * band_bps * safety:
        return ref
    return p


def hedge_move(v: int, old: int, last_nav: int, step_bps: int, used: int, t: int, now: int, epoch: int,
               approved: tuple = (0, 0, 0)) -> tuple[int, bool]:
    """Hedge equity the vault will APPLY for a report `v` (LPVaultBase._hedgeFor / RiskBudgets.moveHedge):
    guardian's exact value for this epoch before its deadline -> as is; any other increase -> refused (old kept);
    a decrease -> limited by the decaying hedgeStepBps-of-lastNav budget. (value, clipped)"""
    if v == old:
        return v, False
    value, ep, until = approved
    if ep == epoch + 1 and value == v and now <= until:
        return v, False
    if v > old:
        return old, True
    room = max(0, last_nav * step_bps // BPS - decayed(used, t, now))
    d = old - v
    return (old - min(d, room)), d > room


# ---------------------------------------------------------------- hedge
@dataclass
class HedgeDecision:
    act: bool
    is_buy: bool = False
    size: float = 0.0
    reduce_only: bool = False
    reason: str = ""


def round_down(x: float, decimals: int) -> float:
    q = 10 ** decimals
    return math.floor(x * q + 1e-9) / q


def hedge_decision(target_short: float, current_short: float, price_usd: float, now: int, last_hedge_ts: int,
                   drift: float = 0.10, interval_s: int = 4 * 3600, min_order_usd: float = 10.0,
                   sz_decimals: int = 2) -> HedgeDecision:
    """Sizes in HYPE (shorts positive). Re-hedge when |diff| > drift * target, or every `interval_s`.
    Orders below the exchange minimum notional are skipped unless they only reduce the short."""
    diff = target_short - current_short
    if target_short > 0:
        drift_due = abs(diff) > drift * target_short
    else:
        drift_due = current_short > 0
    time_due = now - last_hedge_ts >= interval_s and abs(diff) > 0
    if not (drift_due or time_due):
        return HedgeDecision(False, reason="within tolerance")
    size = round_down(abs(diff), sz_decimals)
    if size <= 0:
        return HedgeDecision(False, reason="zero after rounding")
    is_buy = diff < 0  # buying back reduces the short
    reduce_only = is_buy and size <= current_short + 1e-12
    if size * price_usd < min_order_usd and not reduce_only:
        return HedgeDecision(False, reason=f"below min order ${min_order_usd}")
    return HedgeDecision(True, is_buy, size, reduce_only, "drift" if drift_due else "interval")


@dataclass
class MarginPlan:
    action: str  # none | send | return
    amount_usd: float = 0.0
    target_usd: float = 0.0


def margin_plan(short_notional_usd: float, capital_usd: float, leverage: float = 3.0, tol: float = 0.25,
                min_move_usd: float = 25.0) -> MarginPlan:
    """capital = treasury USDC + HL equity + in transit. Keep it within target*(1 +- tol)."""
    target = short_notional_usd / leverage if leverage > 0 else 0.0
    if capital_usd < target * (1 - tol) and target - capital_usd >= min_move_usd:
        return MarginPlan("send", target - capital_usd, target)
    if capital_usd > target * (1 + tol) and capital_usd - target >= min_move_usd:
        return MarginPlan("return", capital_usd - target, target)
    return MarginPlan("none", 0.0, target)


# ---------------------------------------------------------------- crash guard (growth vault)
def peak_in_window(candles: list[dict], now_s: int, window_s: int, current: float) -> float:
    """Max of candle highs overlapping [now - window, now] and the current price. candles: {t (ms open), T, h}."""
    lo_ms = (now_s - window_s) * 1000
    hs = [float(c["h"]) for c in candles if int(c["T"]) >= lo_ms and int(c["t"]) <= now_s * 1000]
    return max(hs + [current])


def rv1h_series(hourly_closes: list[float]) -> list[float]:
    """1h realized vol per hour = |log return| of the hourly close."""
    return [abs(x) for x in log_returns(hourly_closes)]


@dataclass
class CrashGuard:
    drop: float = 0.08
    wait_s: int = 24 * 3600
    mode: str = "normal"  # normal | out
    since: int = 0
    trigger_price: float = 0.0
    peak: float = 0.0

    def step(self, now: int, price: float, peak: float, rv_latest: float, rv_median: float) -> str:
        """Returns: none (normal, keep LP), exit (just triggered), hold (stay out), reenter (just released)."""
        if self.mode == "normal":
            if peak > 0 and price <= peak * (1 - self.drop):
                self.mode, self.since, self.trigger_price, self.peak = "out", now, price, peak
                return "exit"
            return "none"
        if now - self.since >= self.wait_s and rv_latest < rv_median:
            self.mode = "normal"
            return "reenter"
        return "hold"

    def to_dict(self) -> dict:
        return {"mode": self.mode, "since": self.since, "trigger_price": self.trigger_price, "peak": self.peak}

    @classmethod
    def from_dict(cls, d: dict, drop: float, wait_s: int) -> "CrashGuard":
        g = cls(drop=drop, wait_s=wait_s)
        for k in ("mode", "since", "trigger_price", "peak"):
            if k in d:
                setattr(g, k, d[k])
        return g


def vol_median_ok(hourly_closes: list[float], lookback_h: int) -> tuple[float, float]:
    rv = rv1h_series(hourly_closes[-(lookback_h + 1):])
    if not rv:
        return 0.0, 0.0
    return rv[-1], median(rv)


# ---------------------------------------------------------------- allocation
def deploy_split(free_usd: float, idle_base_usd: float, lp_base_usd: float, capital_usd: float, base_frac: float,
                 hedged: bool, leverage: float) -> tuple[float, float]:
    """Split deployable USDC `free` (+ idle HYPE value) into new LP value V and margin x to keep idle for the hedge
    so that capital + x = (HYPE value in LP after deploy) / leverage. Returns (V, x)."""
    if not hedged or leverage <= 0:
        return free_usd + idle_base_usd, 0.0
    x = ((lp_base_usd + (free_usd + idle_base_usd) * base_frac) / leverage - capital_usd) / (1 + base_frac / leverage)
    x = min(max(0.0, x), free_usd)
    return free_usd - x + idle_base_usd, x
