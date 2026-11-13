import math
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from elysium_keeper import strategy as S  # noqa: E402
from elysium_keeper import v4math as M  # noqa: E402
from elysium_keeper.hl import DryRunAdapter, LiveAdapter, build_order_action, num_str, px_str  # noqa: E402
from elysium_keeper.config import HLCfg, from_dict  # noqa: E402


# ---------------------------------------------------------------- volatility / range
def test_realized_vol_constant_returns_zero():
    assert S.realized_daily_vol([100.0] * 80) == 0.0


def test_realized_vol_alternating():
    closes = [100 * (1.001 if i % 2 else 0.999) for i in range(80)]
    r = math.log(1.001 / 0.999)
    v = S.realized_daily_vol(closes, 72)
    # alternating +-r: sample stdev ~ r * sqrt(n/(n-1))
    assert v == pytest.approx(r * math.sqrt(72 / 71) * math.sqrt(24), rel=1e-6)


def test_realized_vol_uses_only_lookback():
    calm = [100.0] * 50
    wild = [100 * (1.05 if i % 2 else 0.95) for i in range(30)]
    assert S.realized_daily_vol(wild + calm, 20) == 0.0
    assert S.realized_daily_vol(calm + wild, 20) > 0.5


def test_realized_vol_needs_data():
    with pytest.raises(ValueError):
        S.realized_daily_vol([100.0, 101.0])


@pytest.mark.parametrize("vol,expected", [(0.0, 0.03), (0.01, 0.03), (0.04, 0.10), (0.1, 0.25), (0.5, 0.40)])
def test_half_width_clip(vol, expected):
    assert S.range_half_width(vol, 2.5, 0.03, 0.40) == pytest.approx(expected)


def test_range_ticks_cover_band_and_spacing():
    p = 71_150_000  # $71.15
    for w in (0.03, 0.1, 0.4):
        tl, tu = S.range_ticks(p, w, 60)
        assert tl % 60 == 0 and tu % 60 == 0 and tl < tu
        lo, hi = 1.0001 ** tl * 1e12, 1.0001 ** tu * 1e12
        assert lo <= 71.15 * (1 - w) + 1e-9 and hi >= 71.15 * (1 + w) - 1e-9
        assert lo > 71.15 * (1 - w) * 0.993 and hi < 71.15 * (1 + w) * 1.007  # at most one spacing wider
        t = M.tick_at_price(p)
        assert S.in_range(int(math.floor(t)), tl, tu)


# ---------------------------------------------------------------- v4 math
def test_sqrt_price_matches_known_ticks():
    assert M.sqrt_price_at_tick(0) == 1 << 96
    # TickMath.getSqrtPriceAtTick(-234000) reference (python Decimal vs on-chain differ < 1e-15 relative)
    sp = M.sqrt_price_at_tick(-234000)
    assert abs(sp / 2 ** 96 - 1.0001 ** (-117000)) / 1.0001 ** (-117000) < 1e-10


def test_liquidity_roundtrip():
    tl, tu = -240000, -228000
    sp = M.sqrt_price_at_tick(-234030)
    sa, sb = M.sqrt_price_at_tick(tl), M.sqrt_price_at_tick(tu)
    a0, a1 = 10 * 10 ** 18, 700 * 10 ** 6
    L = M.liquidity_for_amounts(sp, sa, sb, a0, a1)
    u0, u1 = M.amounts_for_liquidity(sp, sa, sb, L)
    assert u0 <= a0 and u1 <= a1
    assert u0 >= a0 * 0.999 or u1 >= a1 * 0.999  # one side binds


def test_base_fraction_centered_and_edges():
    p = 71_150_000
    tl, tu = S.range_ticks(p, 0.1)
    sp = M.sqrt_price_at_tick(int(M.tick_at_price(p)))
    assert 0.4 < M.base_value_fraction(sp, tl, tu) < 0.6
    assert M.base_value_fraction(M.sqrt_price_at_tick(tl - 600), tl, tu) == pytest.approx(1.0)
    assert M.base_value_fraction(M.sqrt_price_at_tick(tu + 600), tl, tu) == 0.0


def test_price_from_sqrt():
    sp = 0x8d8a559d18bcd05cb570  # Elysium pool sample, ~$71.17
    assert M.p_to_usd(M.price_from_sqrt(sp)) == pytest.approx(71.17, abs=0.01)


# ---------------------------------------------------------------- price choice
def test_choose_price_ok_clamp_skip():
    pool = 71_000_000
    ok = S.choose_price(71_500_000, pool, 150, 0.8, 300)
    assert ok.status == "ok" and ok.price == 71_500_000
    cl = S.choose_price(72_500_000, pool, 150, 0.8, 300)  # +2.1%
    assert cl.status == "clamped"
    # clamped value satisfies the contract check |pool-P|*BPS <= P*band
    assert abs(pool - cl.price) * 10_000 <= cl.price * 150
    cl2 = S.choose_price(69_800_000, pool, 150, 0.8, 300)
    assert cl2.status == "clamped" and abs(pool - cl2.price) * 10_000 <= cl2.price * 150
    sk = S.choose_price(74_000_000, pool, 150, 0.8, 300)  # +4.2%
    assert sk.status == "skip" and sk.price is None
    assert S.choose_price(0, pool, 150).status == "skip"


# ---------------------------------------------------------------- hedge
def test_hedge_within_tolerance_no_trade():
    d = S.hedge_decision(100, 95, 70, now=1000, last_hedge_ts=900)
    assert not d.act


def test_hedge_drift_triggers_sell():
    d = S.hedge_decision(100, 85, 70, now=1000, last_hedge_ts=900)
    assert d.act and not d.is_buy and d.size == 15 and not d.reduce_only


def test_hedge_drift_triggers_reduce():
    d = S.hedge_decision(50, 60, 70, now=1000, last_hedge_ts=900)
    assert d.act and d.is_buy and d.size == 10 and d.reduce_only


def test_hedge_interval_triggers_small_diff():
    d = S.hedge_decision(100, 97, 70, now=4 * 3600 + 1, last_hedge_ts=0)
    assert d.act and d.reason == "interval" and d.size == 3


def test_hedge_min_order():
    d = S.hedge_decision(1.0, 0.8, 30, now=10, last_hedge_ts=0, interval_s=10 ** 9)  # 0.2 HYPE * $30 = $6
    assert not d.act and "min order" in d.reason
    d2 = S.hedge_decision(0.8, 1.0, 30, now=10, last_hedge_ts=0, interval_s=10 ** 9)  # reduce-only allowed
    assert d2.act and d2.reduce_only


def test_hedge_close_when_target_zero_and_rounding():
    d = S.hedge_decision(0, 12.345, 70, now=1, last_hedge_ts=0)
    assert d.act and d.is_buy and d.size == 12.34
    assert not S.hedge_decision(10.004, 10.0, 70, now=10 ** 6, last_hedge_ts=0).act  # rounds to 0


def test_margin_plan():
    assert S.margin_plan(3000, 1000, 3.0).action == "none"
    p = S.margin_plan(3000, 500, 3.0)
    assert p.action == "send" and p.amount_usd == pytest.approx(500)
    r = S.margin_plan(3000, 1600, 3.0)
    assert r.action == "return" and r.amount_usd == pytest.approx(600)
    assert S.margin_plan(0, 10, 3.0).action == "none"  # below min move


def test_deploy_split():
    v, x = S.deploy_split(950, 0, 0, 0, 0.5, True, 3.0)
    assert v + x == pytest.approx(950)
    assert x == pytest.approx(v * 0.5 / 3.0)  # margin covers the new HYPE leg at 3x
    v, x = S.deploy_split(950, 50, 1000, 400, 0.5, True, 3.0)  # existing LP HYPE $1000 already has $400 capital
    assert x == pytest.approx(((1000 + 1000 * 0.5) / 3 - 400) / (1 + 0.5 / 3))
    assert S.deploy_split(950, 50, 0, 10_000, 0.5, True, 3.0) == (1000, 0.0)  # plenty of margin
    assert S.deploy_split(850, 20, 0, 0, 0.5, False, 3.0) == (870, 0.0)


# ---------------------------------------------------------------- crash guard
def candles(points, start_ms=0, step_ms=300_000):
    return [{"t": start_ms + i * step_ms, "T": start_ms + (i + 1) * step_ms - 1, "h": h} for i, h in enumerate(points)]


def test_peak_window():
    cs = candles([100, 110, 105, 90], start_ms=0, step_ms=3600_000)
    now = 4 * 3600
    assert S.peak_in_window(cs, now, 2 * 3600, 95) == 105  # only candles overlapping the last 2h
    assert S.peak_in_window(cs, now, 4 * 3600, 95) == 110


def test_crash_guard_state_machine():
    g = S.CrashGuard(drop=0.08, wait_s=24 * 3600)
    assert g.step(0, 100, 100, 0.01, 0.01) == "none"
    assert g.step(100, 93, 100, 0.01, 0.01) == "none"  # -7%
    assert g.step(200, 92, 100, 0.05, 0.01) == "exit"  # -8%
    assert g.mode == "out" and g.since == 200
    assert g.step(300, 95, 100, 0.001, 0.01) == "hold"  # calm but < 24h
    assert g.step(200 + 24 * 3600, 95, 95, 0.02, 0.01) == "hold"  # 24h but vol above median
    assert g.step(200 + 25 * 3600, 95, 95, 0.005, 0.01) == "reenter"
    assert g.mode == "normal"
    # persistence round trip
    g.step(10 ** 6, 80, 95, 0.1, 0.01)
    g2 = S.CrashGuard.from_dict(g.to_dict(), 0.08, 24 * 3600)
    assert g2.mode == "out" and g2.since == 10 ** 6


def test_rv1h_median():
    closes = [100, 101, 100, 101, 100, 90, 90]
    last, med = S.vol_median_ok(closes, 168)
    assert last == 0.0 and med == pytest.approx(math.log(1.01), rel=1e-6)


# ---------------------------------------------------------------- HL adapter / config
def test_order_action_format_matches_reference():
    a = build_order_action(159, False, 12.3, 71.8125, 0.01, 2, False)
    assert list(a) == ["type", "orders", "grouping"]
    o = a["orders"][0]
    assert list(o) == ["a", "b", "p", "s", "r", "t"]
    assert o == {"a": 159, "b": False, "p": "71.094", "s": "12.3", "r": False, "t": {"limit": {"tif": "Ioc"}}}
    assert num_str(1.50, 2) == "1.5" and num_str(2.0, 2) == "2" and px_str(123456.7) == "123460"


def test_dry_run_adapter_pnl_and_equity():
    cfg = HLCfg(taker_fee=0.0)
    logs = []
    mark = {"v": 100.0}
    a = DryRunAdapter(cfg, {}, lambda *x, **k: logs.append((x, k)), mark_fn=lambda: mark["v"])
    a.credit_margin(500)
    a.place(False, 10, 100.0, False)  # short 10 @100
    assert a.position() == -10
    mark["v"] = 90.0
    assert a.equity() == pytest.approx(600)  # +100 uPnL
    a.place(True, 4, 90.0, True)
    assert a.position() == -6 and a.sim["realized"] == pytest.approx(40)
    assert a.equity() == pytest.approx(600)
    assert logs and logs[0][0][0] == "hl_intended_order"


def test_live_adapter_is_gated(monkeypatch):
    monkeypatch.delenv("ELYSIUM_KEEPER_HL_LIVE", raising=False)
    with pytest.raises(PermissionError):
        LiveAdapter(HLCfg(live_enabled=True), {}, print, None)
    monkeypatch.setenv("ELYSIUM_KEEPER_HL_LIVE", "I_UNDERSTAND")
    with pytest.raises(PermissionError):
        LiveAdapter(HLCfg(live_enabled=False), {}, print, None)


def test_config_rejects_unknown_and_alchemy():
    with pytest.raises(ValueError):
        from_dict({"strategy": {"k_vol": 2.5, "typo": 1}})
    from elysium_keeper.rpc import RPC
    with pytest.raises(ValueError):
        RPC("https://elysium.g.alchemy.com/v2/x")
