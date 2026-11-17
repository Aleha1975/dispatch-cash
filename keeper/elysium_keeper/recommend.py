"""Range-width recommendation per whitelisted pool (served at GET /elysium-api/sa/recommend, consumed by the web).

Recommended half-width = clamp(k x sigma_daily), k = strategy.k_vol (2.5), sigma = realized daily volatility of HYPE
from Hyperliquid 1h candles over strategy.vol_lookback_h (72 h) - exactly what the keeper uses in auto mode
(strategy.range_half_width), so the page and the keeper agree. Our backtest: hedge + vol-scaled width k~2.5 + 10%
hedge re-adjust performed best.

Per width the model estimates (all as fractions per year of the ACCOUNT value; it is a model, not a promise):
  fee_apr_in_range   pool fees per unit of in-range liquidity over the fee horizon (feeGrowthGlobal delta read from
                     PoolManager at two blocks) / position value per unit of liquidity at that width, annualised,
                     diluted by our own liquidity (all clients' capital in the pool: max(sa.recommend_reference_usd,
                     the keeper's current total)) at the same volume;
  rebalances / day   sigma^2 / (a x b): expected exit time of a Brownian log-price from the centre between the two
                     re-range triggers at distances a and b (the keeper re-ranges when the price is within
                     sa.edge_frac of the range from an edge, or out of range);
  turnover           each re-range is charged to the module's sliding 24 h turnover budget (swapTurnoverBps x account
                     value): the re-centring swap + the LP add (charged paid x slip / (slip + band), SABook.lpAdd);
                     beyond the budget the position waits out of range, so in_range_frac = min(1, budget / need);
  re-range loss      LP value vs holding the entry mix at the trigger (the convexity loss a re-range realises; the
                     hedge removes the HYPE delta, not this) x rebalances;
  swap cost          pool fee + impact on the re-centring swap x rebalances.
"""
from __future__ import annotations

import json
import math
import os
import time
from dataclasses import dataclass

from eth_abi import encode as abi_encode
from eth_utils import keccak

from . import strategy as S
from . import v4math as M

LN_TICK = math.log(1.0001)
Q128 = 1 << 128
POOLS_SLOT = 6
# script/DeploySA.s.sol defaults (used when no module is configured yet, e.g. the page before deployment)
DEFAULT_PARAMS = {"feeBps": 1500, "hedgeCapBps": 3500, "poolBandBps": 150, "maxSlippageBps": 150, "hedgeStepBps": 500,
                  "refDriftBps": 1000, "swapTurnoverBps": 20000, "feeInterval": 7 * 86400, "maxPriceAge": 3600,
                  "minPriceStable": 300, "exitTurnoverBps": 10000}
GRID_BPS = (200, 300, 400, 500, 600, 800, 1000, 1200, 1500, 2000, 2500, 3000, 4000)


# ------------------------------------------------------------------------------------------------ pure math
def ticks_for(price: int, h: float, spacing: int) -> tuple[int, int]:
    return S.range_ticks(price, h, spacing)


def _sp(t: float) -> float:
    return math.exp(t * LN_TICK / 2)


def amounts_per_l(tick: float, tl: int, tu: int) -> tuple[float, float]:
    """(HYPE, USDC) of one unit of liquidity at tick `tick`, in units where the price is 1.0001^tick."""
    c = min(max(tick, tl), tu)
    return 1 / _sp(c) - 1 / _sp(tu), _sp(c) - _sp(tl)


def value_per_l(tick: float, tl: int, tu: int) -> float:
    """Position value per unit of liquidity / sqrt(p) at tick `tick` (in range: 2 - sqrt(pa/p) - sqrt(p/pb))."""
    x, y = amounts_per_l(tick, tl, tu)
    return (x * _sp(tick) ** 2 + y) / _sp(tick)


def base_frac(tick: float, tl: int, tu: int) -> float:
    """Share of the position's value in HYPE at tick `tick`."""
    x, y = amounts_per_l(tick, tl, tu)
    v0 = x * _sp(tick) ** 2
    return v0 / (v0 + y) if v0 + y > 0 else 0.0


def il_at(t0: float, t1: float, tl: int, tu: int) -> float:
    """Loss of the LP vs holding its entry mix, from tick t0 to t1 (fraction of the hold value, >= 0)."""
    p1 = _sp(t1) ** 2
    x0, y0 = amounts_per_l(t0, tl, tu)
    x1, y1 = amounts_per_l(t1, tl, tu)
    hold = x0 * p1 + y0
    return max(0.0, 1 - (x1 * p1 + y1) / hold) if hold > 0 else 0.0


def triggers(tick: float, tl: int, tu: int, edge_frac: float) -> tuple[float, float]:
    w = tu - tl
    return tl + edge_frac * w, tu - edge_frac * w


def rebalances_per_day(sigma_daily: float, tick: float, tl: int, tu: int, edge_frac: float) -> float:
    lo, hi = triggers(tick, tl, tu, edge_frac)
    a, b = max(1e-9, (tick - lo) * LN_TICK), max(1e-9, (hi - tick) * LN_TICK)
    return sigma_daily ** 2 / (a * b)


def lp_fracs(margin_frac: float, buffer_bps: int) -> tuple[float, float]:
    """Share of the account in the LP: (hedged, unhedged). Hedged keeps the hedge margin outside the LP."""
    buf = buffer_bps / 10_000
    return max(0.0, 1 - margin_frac - buf), max(0.0, 1 - buf)


@dataclass
class Model:
    sigma_daily: float
    price: int  # keeper units (USDC raw per 1e18 wei)
    tick: float
    spacing: int
    fee_tier: float  # 0.003
    fees_per_l_day: float  # USDC raw per unit of liquidity per day (in range)
    edge_frac: float = 0.10
    turnover_bps: int = 20000
    slippage_bps: int = 150
    band_bps: int = 150
    lp_frac: float = 0.72
    impact_bps: float = 5.0
    budget_safety: float = 0.8
    active_liquidity: int = 0  # other LPs' in-range liquidity now (0 = no dilution modelled)
    our_usd: float = 0.0  # all clients' capital in this pool (our liquidity dilutes the fee share)
    pool_lp_frac: float | None = None  # share of `our_usd` in the LP (default lp_frac)

    @property
    def sqrt_p_raw(self) -> float:
        return math.sqrt(self.price / 1e18)

    def metrics(self, h: float) -> dict:
        tl, tu = ticks_for(self.price, h, self.spacing)
        t = self.tick
        v = value_per_l(t, tl, tu) * self.sqrt_p_raw  # USDC raw per unit of liquidity
        apr_in = self.fees_per_l_day / v * 365 if v > 0 else 0.0
        if self.active_liquidity and self.our_usd > 0 and v > 0:
            ours = self.our_usd * 1e6 * (self.pool_lp_frac or self.lp_frac) / v
            apr_in *= self.active_liquidity / (self.active_liquidity + ours)
        r = rebalances_per_day(self.sigma_daily, t, tl, tu, self.edge_frac)
        lo, hi = triggers(t, tl, tu, self.edge_frac)
        fc = base_frac(t, tl, tu)
        swap_frac = max(abs(base_frac(lo, tl, tu) - fc), abs(base_frac(hi, tl, tu) - fc))
        il = (il_at(t, lo, tl, tu) + il_at(t, hi, tl, tu)) / 2
        add_share = self.slippage_bps / (self.slippage_bps + self.band_bps)
        charge = self.lp_frac * (swap_frac + add_share)  # turnover per re-range, fraction of the account
        r_max = (self.turnover_bps / 10_000) / charge if charge > 0 else float("inf")
        in_range = min(1.0, self.budget_safety * r_max / r) if r > 0 else 1.0
        r_eff = min(r, self.budget_safety * r_max)
        fee_apr = apr_in * in_range * self.lp_frac
        loss_apr = r_eff * 365 * il * self.lp_frac
        swap_apr = r_eff * 365 * swap_frac * self.lp_frac * (self.fee_tier + self.impact_bps / 10_000)
        lower, upper = M.p_to_usd(price_at_tick(tl)), M.p_to_usd(price_at_tick(tu))
        return {"width_bps": int(round(h * 10_000)), "tick_lower": tl, "tick_upper": tu,
                "lower": round(lower, 4), "upper": round(upper, 4),
                "fee_apr_in_range": round(apr_in, 4), "rebalances_per_week": round(r_eff * 7, 2),
                "rebalances_per_week_unbounded": round(r * 7, 2), "in_range_frac": round(in_range, 3),
                "turnover_per_rebalance": round(charge, 4), "il_at_trigger": round(il, 5),
                "est_fee_apr": round(fee_apr, 4), "est_rerange_loss_apr": round(loss_apr, 4),
                "est_swap_cost_apr": round(swap_apr, 4), "est_net_apr": round(fee_apr - loss_apr - swap_apr, 4)}


def price_at_tick(t: int) -> int:
    """Keeper price units at tick t."""
    return int(math.exp(t * LN_TICK) * 1e18)


def edge_loss(h: float) -> float:
    """Unhedged note: loss vs holding the entry 50/50-ish mix when the price reaches the edge of a +-h range (the
    position is then all HYPE below / all USDC above). Average of the two edges, fraction."""
    t0 = 0.0
    tl, tu = math.floor(math.log(1 - h) / LN_TICK), math.ceil(math.log(1 + h) / LN_TICK)
    return (il_at(t0, tl, tl, tu) + il_at(t0, tu, tl, tu)) / 2


def turnover_floor(m: Model, lo: float = 0.002, hi: float = 0.6) -> float:
    """Smallest half-width whose expected re-ranges fit the module's turnover budget (x budget_safety)."""
    def fits(h):
        x = m.metrics(h)
        return x["in_range_frac"] >= 0.999
    if fits(lo):
        return lo
    if not fits(hi):
        return hi
    for _ in range(40):
        mid = (lo + hi) / 2
        if fits(mid):
            hi = mid
        else:
            lo = mid
    return hi


def effective_half_width(mode: str, width_bps: int | None, auto_hw: float, floor_hw: float, max_hw: float
                         ) -> tuple[float, bool]:
    """The half-width the keeper uses: auto -> the recommendation; manual -> the client's width, widened to the
    live turnover floor when it is below it (a narrower range would sit out of range waiting for budget).
    Returns (half_width, clamped)."""
    if mode != "manual" or not width_bps:
        return auto_hw, False
    w = width_bps / 10_000
    if w < floor_hw:
        return min(max_hw, floor_hw), True
    return min(w, max_hw), False


# ------------------------------------------------------------------------------------------------ chain data
class PoolReader:
    """Read-only v4 pool state through PoolManager.extsload, at any block (the Elysium RPC serves history)."""

    def __init__(self, rpc, pool_manager: str, pool_id: str):
        self.rpc, self.pm = rpc, pool_manager
        self.base = int.from_bytes(keccak(abi_encode(["bytes32", "uint256"], [bytes.fromhex(pool_id[2:]),
                                                                               POOLS_SLOT])), "big")

    def _slot(self, i: int, block: str) -> int:
        data = "0x1e2eaeaf" + (self.base + i).to_bytes(32, "big").hex()
        return int(self.rpc.call("eth_call", [{"to": self.pm, "data": data}, block]), 16)

    def state(self, block: str = "latest") -> dict:
        w = self._slot(0, block)
        sp = w & ((1 << 160) - 1)
        t = (w >> 160) & 0xFFFFFF
        if t >= 1 << 23:
            t -= 1 << 24
        return {"sqrt_price": sp, "tick": t, "lp_fee": (w >> 208) & 0xFFFFFF, "fg0": self._slot(1, block),
                "fg1": self._slot(2, block), "liquidity": self._slot(3, block) & ((1 << 128) - 1)}

    def block_at(self, ts: int, head: int, head_ts: int) -> tuple[int, int]:
        """Block at (about) timestamp ts: secant steps on (number, timestamp)."""
        b0, t0 = head, head_ts
        probe = max(1, head - 100_000)
        t1 = self._ts(probe)
        b1 = probe
        for _ in range(6):
            if t0 == t1:
                break
            b = int(b1 + (ts - t1) * (b0 - b1) / (t0 - t1))
            b = min(max(1, b), head)
            tb = self._ts(b)
            if abs(tb - ts) < 120:
                return b, tb
            b0, t0, b1, t1 = b1, t1, b, tb
        return b1, t1

    def _ts(self, b: int) -> int:
        return int(self.rpc.call("eth_getBlockByNumber", [hex(b), False])["timestamp"], 16)


def fees_per_l_day(now: dict, then: dict, days: float, price_raw: float) -> float:
    """USDC raw earned per unit of in-range liquidity per day: feeGrowthGlobal deltas (Q128) valued at the price."""
    d0 = ((now["fg0"] - then["fg0"]) % (1 << 256)) / Q128
    d1 = ((now["fg1"] - then["fg1"]) % (1 << 256)) / Q128
    return (d0 * price_raw + d1) / days if days > 0 else 0.0


# ------------------------------------------------------------------------------------------------ engine
def compute(cfg, *, hl_info, rpc, pool: dict, params: dict | None = None, now: int | None = None,
            our_usd: float | None = None) -> dict:
    """Recommendation JSON for one whitelisted pool (`pool`: an entry of sa.pools)."""
    st, sa = cfg.strategy, cfg.sa
    params = dict(DEFAULT_PARAMS, **(params or {}))
    now = now or int(time.time())
    hrs = max(st.vol_lookback_h, 168) + 3
    cs = hl_info.candles(cfg.hl.coin, "1h", (now - hrs * 3600) * 1000, now * 1000)
    closes = [float(c["c"]) for c in cs]
    sig72 = S.realized_daily_vol(closes, st.vol_lookback_h)
    sig7d = S.realized_daily_vol(closes, 168) if len(closes) > 100 else sig72
    pr = PoolReader(rpc, pool.get("pool_manager") or cfg.chain.pool_manager, pool["pool_id"])
    head = int(rpc.call("eth_blockNumber"), 16)
    head_ts = int(rpc.call("eth_getBlockByNumber", [hex(head), False])["timestamp"], 16)
    cur = pr.state(hex(head))
    price = M.price_from_sqrt(cur["sqrt_price"])
    horizon = sa.recommend_fee_horizon_h * 3600
    b0, t0 = pr.block_at(head_ts - horizon, head, head_ts)
    old = pr.state(hex(b0))
    days = (head_ts - t0) / 86400
    fpl = fees_per_l_day(cur, old, days, price / 1e18)
    b1, t1 = pr.block_at(head_ts - 86400, head, head_ts)
    fpl24 = fees_per_l_day(cur, pr.state(hex(b1)), (head_ts - t1) / 86400, price / 1e18)
    fee_tier = cur["lp_fee"] / 1e6
    lp_h, lp_u = lp_fracs(sa.margin_frac, sa.buffer_bps)
    return build(sig72=sig72, sig7d=sig7d, price=price, tick=cur["tick"], liquidity=cur["liquidity"],
                 fee_tier=fee_tier, fpl=fpl, fpl24=fpl24, days=days, params=params, cfg=cfg, pool=pool, now=now,
                 lp_h=lp_h, lp_u=lp_u, our_usd=our_usd)


def build(*, sig72, sig7d, price, tick, liquidity, fee_tier, fpl, fpl24, days, params, cfg, pool, now, lp_h, lp_u,
          our_usd: float | None = None) -> dict:
    """Pure part of `compute` (tested offline)."""
    st, sa = cfg.strategy, cfg.sa
    our_usd = sa.recommend_reference_usd if our_usd is None else our_usd
    spacing = int(pool.get("tick_spacing", 60))

    def model(lp, s=sig72):
        return Model(sigma_daily=s, price=price, tick=float(tick), spacing=spacing, fee_tier=fee_tier,
                     fees_per_l_day=fpl, edge_frac=sa.edge_frac, turnover_bps=params["swapTurnoverBps"],
                     slippage_bps=params["maxSlippageBps"], band_bps=params["poolBandBps"], lp_frac=lp,
                     active_liquidity=liquidity, our_usd=our_usd, pool_lp_frac=lp_h)

    mh, mu = model(lp_h), model(lp_u)
    rec_h = S.range_half_width(sig72, st.k_vol, st.min_half_width, st.max_half_width)
    floor = max(turnover_floor(mh), turnover_floor(mu))
    lo_bps, hi_bps = sa.width_min_bps, sa.width_max_bps
    manual_min = min(hi_bps, max(lo_bps, int(math.ceil(floor * 10_000 / 50.0)) * 50))

    def row(h):
        a, b = mh.metrics(h), mu.metrics(h)
        keep = ("width_bps", "tick_lower", "tick_upper", "lower", "upper", "fee_apr_in_range")
        out = {k: a[k] for k in keep}
        out["hedged"] = {k: v for k, v in a.items() if k not in keep}
        out["unhedged"] = dict({k: v for k, v in b.items() if k not in keep}, il_at_edge=round(edge_loss(h), 5),
                               hype_share_at_centre=round(base_frac(float(tick), a["tick_lower"], a["tick_upper"]), 3))
        return out

    grid = [row(b / 10_000) for b in GRID_BPS if lo_bps <= b <= hi_bps]
    fees_usd_day = fpl * liquidity / 1e6
    return {
        "version": 1, "generated_at": now,
        "pool": {"id": pool.get("id"), "name": pool.get("name"), "dex": pool.get("dex", "uniswap-v4"),
                 "pool_id": pool["pool_id"], "module": pool.get("module") or None, "fee_tier": fee_tier,
                 "tick_spacing": spacing, "price": round(M.p_to_usd(price), 4), "tick": tick,
                 "active_liquidity": str(liquidity)},
        "vol": {"daily_72h": round(sig72, 5), "daily_7d": round(sig7d, 5), "lookback_h": st.vol_lookback_h},
        "fees": {"horizon_days": round(days, 2), "fees_per_l_day": fpl, "fees_per_l_day_24h": fpl24,
                 "pool_fees_usd_day_est": round(fees_usd_day, 2),
                 "pool_volume_usd_day_est": round(fees_usd_day / fee_tier, 0) if fee_tier else None},
        "model": {"k": st.k_vol, "edge_frac": sa.edge_frac, "swap_turnover_bps": params["swapTurnoverBps"],
                  "max_slippage_bps": params["maxSlippageBps"], "pool_band_bps": params["poolBandBps"],
                  "fee_bps": params["feeBps"], "lp_frac_hedged": round(lp_h, 3), "lp_frac_unhedged": round(lp_u, 3),
                  "hedge_rebalance_band": st.rehedge_drift, "our_capital_usd": round(our_usd, 0)},
        "bounds": {"min_bps": lo_bps, "max_bps": hi_bps, "turnover_floor_bps": int(round(floor * 10_000)),
                   "manual_min_bps": manual_min},
        "recommended": row(rec_h),
        "grid": grid,
        "note": "Model estimates from recent pool fees and HYPE volatility; not a promise. Returns before the 15% "
                "performance fee above the high-water mark. Hedged: HYPE exposure is offset on Hyperliquid "
                "(funding not included). Unhedged: value also moves with about half of the HYPE price.",
    }


def write(path: str, doc: dict):
    if os.path.dirname(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(fd, "w") as fh:
        json.dump(doc, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
