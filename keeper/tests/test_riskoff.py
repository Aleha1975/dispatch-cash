"""Risk-off product (offline): the signal (riskoff.py), Strategy v2 (prefs.py, riskOff field, v1 still valid) and the
keeper's exit / hold / re-entry path (sa_keeper). Chain and HL reads are fakes."""
from __future__ import annotations

import calendar
import math
import os
import random
import sys
import types

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eth_account import Account  # noqa: E402
from eth_account.messages import encode_typed_data  # noqa: E402

from test_product import ACCOUNT, P_, FakeReader, bare_keeper, make_strategy, snap  # noqa: E402
from test_sa_api import E6, MODULE, NOW, OWNER, PK  # noqa: E402
from elysium_keeper import prefs as P  # noqa: E402
from elysium_keeper import riskoff as RO  # noqa: E402
from elysium_keeper.sa_chain import hybrid_address  # noqa: E402

E18 = 10 ** 18


# ================================================================ signal
def candles(closes, t0=calendar.timegm((2025, 1, 1, 0, 0, 0)), spread=0.004):
    return [{"t": (t0 + i * RO.BAR_S) * 1000, "o": c, "h": c * (1 + spread), "l": c * (1 - spread), "c": c}
            for i, c in enumerate(closes)]


def walk(n, seed=3, vol=0.01, start=60_000.0):
    rnd = random.Random(seed)
    out, x = [], start
    for _ in range(n):
        x *= math.exp(rnd.gauss(0, vol))
        out.append(x)
    return out


def test_ema_matches_pandas_adjust_true():
    pd = pytest.importorskip("pandas")
    xs = walk(400)
    ref = pd.Series(xs).ewm(span=180).mean().tolist()
    got = RO.ema_adjusted(xs)
    assert max(abs(a - b) / b for a, b in zip(got, ref)) < 1e-12


def test_parkinson_matches_research_formula():
    pd = pytest.importorskip("pandas")
    np = pytest.importorskip("numpy")
    h = [1 + 0.01 * (i % 7) for i in range(100)]
    lo = [1 - 0.005 * (i % 5) for i in range(100)]
    H, L = pd.Series(h), pd.Series(lo)
    ref = np.sqrt(((np.log(H / L)) ** 2 / (4 * np.log(2))).rolling(42).mean() * 6 * 365)
    got = RO.parkinson(h, lo)
    assert math.isnan(got[40]) and abs(got[-1] - ref.iloc[-1]) < 1e-12


def test_threshold_is_monthly_q80_of_past_and_crash_turns_it_on():
    xs = walk(1500)
    cs = candles(xs)
    end = cs[-1]["t"] // 1000 + RO.BAR_S
    sig = RO.evaluate(cs, end)
    assert not math.isnan(sig.threshold) and sig.threshold > 0
    # the threshold only uses bars before the current month (minus the purge): appending bars does not move it
    # within the month
    same_month = [c for c in cs if c["t"] // 1000 + RO.BAR_S < RO.month_start(end)]
    assert len(same_month) < len(cs)
    # a 15% crash in the last bars pushes BTC far below its 30 d EMA: on
    crash = xs + [xs[-1] * (1 - 0.03 * k) for k in range(1, 6)]
    s2 = RO.evaluate(candles(crash), cs[0]["t"] // 1000 + (len(crash)) * RO.BAR_S)
    assert s2.on and s2.btc_below_ema > s2.threshold and s2.reason == "btc_below_ema"


def test_open_bar_is_ignored_and_short_history_is_off():
    xs = walk(1500)
    cs = candles(xs)
    last_close = cs[-1]["t"] // 1000 + RO.BAR_S
    a = RO.evaluate(cs, last_close)
    b = RO.evaluate(cs, last_close - 1)  # the last bar is still open: evaluated at the bar before
    assert b.bar_close == a.bar_close - RO.BAR_S
    assert RO.evaluate(candles(walk(100)), 10 ** 10).reason == "not_enough_history"


def test_rv_option_adds_a_trigger():
    xs = walk(1500)
    calm = candles(xs)
    wild = candles(xs, spread=0.004)
    for c in wild[-42:]:
        c["h"], c["l"] = c["c"] * 1.08, c["c"] * 0.92
    end = calm[-1]["t"] // 1000 + RO.BAR_S
    base = RO.evaluate(calm, end)
    assert not base.on
    s = RO.evaluate(calm, end, hype=wild, use_rv=True)
    assert s.on and "hype_vol" in s.reason and s.rv7d > s.rv_threshold


def test_account_out_min_time():
    assert RO.account_out(True, None, 100, 86400)
    assert RO.account_out(False, 0, 86399, 86400)  # signal off but out less than 24 h: stay out
    assert not RO.account_out(False, 0, 86400, 86400)
    assert not RO.account_out(False, None, 5, 86400)


class FakeInfo:
    def __init__(self, cs):
        self.cs, self.calls, self.fail = cs, 0, False

    def candles(self, coin, interval, start, end):
        self.calls += 1
        if self.fail:
            raise ConnectionError("down")
        return [c for c in self.cs if c["t"] <= end]


def test_riskoff_update_tracks_since_throttles_and_keeps_state_on_failure():
    xs = walk(1500)
    crash = xs + [xs[-1] * (1 - 0.03 * k) for k in range(1, 6)]
    cs = candles(crash)
    info = FakeInfo(cs)
    st: dict = {}
    logs = []
    ro = RO.RiskOff(info, st, log=lambda ev, **kw: logs.append(ev))
    t_calm = cs[0]["t"] // 1000 + len(xs) * RO.BAR_S
    ro.update(t_calm)
    assert st["on"] is False and info.calls == 1
    ro.update(t_calm + 60)  # same bar, within refresh: no fetch
    assert info.calls == 1
    t_crash = cs[0]["t"] // 1000 + len(crash) * RO.BAR_S
    ro.update(t_crash)
    assert st["on"] is True and st["since"] == t_crash and "riskoff_on" in logs
    info.fail = True
    ro.update(t_crash + RO.BAR_S + 1)
    assert st["on"] is True and "error" in st  # a failed fetch keeps the decision


# ================================================================ Strategy v2
def make_v2(pk=PK, *, risk_off=True, hedged=False, nonce=5, chain_id=99901, **kw):
    o = Account.from_key(pk).address
    s = P.Strategy(o, hybrid_address(o), MODULE, kw.get("mode", 0), kw.get("width", 0), hedged, nonce, NOW + 3600,
                   risk_off=risk_off, version=2)
    sig = Account.unsafe_sign_hash(P.digest(s, chain_id), pk).signature
    return P.Strategy(**{**s.__dict__, "signature": bytes(sig)})


def test_v2_digest_matches_independent_encoder_and_differs_from_v1():
    st = make_v2()
    td = P.typed_data(st, 99901)
    assert td["domain"]["version"] == "2" and {"name": "riskOff", "type": "bool"} in td["types"]["Strategy"]
    msg = dict(td["message"], nonce=int(td["message"]["nonce"]), deadline=int(td["message"]["deadline"]))
    assert Account.recover_message(encode_typed_data(full_message=dict(td, message=msg)), signature=st.signature) \
        == OWNER
    v1 = P.Strategy(**{**st.__dict__, "risk_off": False, "version": 1})
    v2_off = P.Strategy(**{**st.__dict__, "risk_off": False})
    assert len({P.digest(st, 99901), P.digest(v1, 99901), P.digest(v2_off, 99901)}) == 3


def test_v2_roundtrip_verify_and_v1_still_valid():
    st = make_v2()
    j = st.to_json()
    assert j["riskOff"] is True and P.parse(j) == st
    P.verify(st, owner=OWNER, account=ACCOUNT, module=MODULE, chain_id=99901, now=NOW, b=P.Bounds())
    rec = st.record(NOW)
    assert rec["risk_off"] is True and rec["version"] == 2 and P.public(rec)["risk_off"] is True
    v1 = make_strategy(nonce=6)
    assert "riskOff" not in v1.to_json() and P.parse(v1.to_json()).version == 1
    P.verify(P.parse(v1.to_json()), owner=OWNER, account=ACCOUNT, module=MODULE, chain_id=99901, now=NOW,
             b=P.Bounds())
    assert v1.record(NOW)["risk_off"] is False


def test_v2_signature_does_not_verify_as_v1_and_schema():
    st = make_v2()
    j = st.to_json()
    j1 = {k: v for k, v in j.items() if k != "riskOff"}  # strip the field: now a v1 message with a v2 signature
    with pytest.raises(P.PrefsError) as e:
        P.verify(P.parse(j1), owner=OWNER, account=ACCOUNT, module=MODULE, chain_id=99901, now=NOW, b=P.Bounds())
    assert e.value.code == "strategy_signature"
    with pytest.raises(P.PrefsError):
        P.parse(dict(j, riskOff=1))
    with pytest.raises(P.PrefsError):
        P.parse(dict(j, riskoff=True))


def test_api_accepts_v2_strategy_and_shows_it(tmp_path):
    from test_product import strat_post
    api, chain, tmp, _ = _env(tmp_path)
    chain.registered[ACCOUNT] = {"revoked": False, "active": True, "owner": OWNER}
    code, out = strat_post(api, make_v2(nonce=21))
    assert code == 202
    _, st = api.get_status(f"owner={OWNER}", "1.1.1.1")
    assert st["strategy_pending"]["risk_off"] is True and st["strategy_pending"]["nonce"] == 21
    # v1 messages are still accepted
    assert strat_post(api, make_strategy(nonce=22))[0] == 202


def _env(tmp_path):
    from test_sa_api import FakeChain
    from elysium_keeper.sa_api import Policy, Queue, RateLimiter, SAApi, StatusFile
    chain = FakeChain()
    chain.balances[OWNER] = 5000 * E6
    api = SAApi(chain, Queue(str(tmp_path / "q")), StatusFile(str(tmp_path / "status.json")), Policy(),
                lambda ev, **kw: None, ip_onboard=RateLimiter(100, 60), owner_onboard=RateLimiter(100, 3600),
                ip_status=RateLimiter(100, 60), wall=lambda: NOW, recommend=StatusFile(str(tmp_path / "rec.json")),
                owner_strategy=RateLimiter(100, 3600))
    return api, chain, tmp_path, []


# ================================================================ keeper
def ro_keeper(tmp_path, acct, *, hedged=False, signal_on=True):
    st = make_v2(hedged=hedged, nonce=9)
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}, tick=acct.positions[0].tl + 10 if acct.positions else 0),
                    {ACCOUNT: st.record(NOW)})
    k.riskoff = types.SimpleNamespace(st={"on": signal_on, "since": NOW - 100})
    k.sold = []
    k.fee = lambda a, g, n: None
    k.report_equity = lambda s, refresh=False: None
    k.returned = []
    k.return_margin = lambda s, g, close: k.returned.append(close)

    def swap(a, sell, amt, price):
        k.sold.append((sell, amt))
        acct.native -= amt
        return amt
    k.swap = swap
    return k


def test_keeper_exit_burns_then_sells_within_exit_window(tmp_path):
    from elysium_keeper import strategy as S
    tl, tu = S.range_ticks(40_000_000, 0.10)
    acct = snap(positions=[P_(tl, tu, tid=7)], native=10 * E18, usdc=600 * E6, value=1000 * E6,
                windows={"turnoverUsed": 10 ** 12, "exitUsed": 0})
    k = ro_keeper(tmp_path, acct)

    def act(fn, *a, **kw):
        k.calls.append((fn, a))
        if fn == "burnPosition":
            acct.positions = []
    k.act = act
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
    assert k.calls[0][0] == "burnPosition"
    assert k.sold and k.sold[0][0] is True and k.sold[0][1] == 10 * E18  # all HYPE, turnover window irrelevant
    assert k.riskout[ACCOUNT] == NOW and ("riskoff_exit" in [e for e, _ in k.logs])
    assert k.returned == [False]  # unhedged: nothing on HL, return_margin is a no-op there
    assert not any(fn in ("mintPosition", "increasePosition", "sendHedgeMargin") for fn, _ in k.calls)


def test_keeper_exit_limited_by_exit_room(tmp_path):
    acct = snap(positions=[], native=20 * E18, usdc=200 * E6, value=1000 * E6,
                windows={"turnoverUsed": 0, "exitUsed": 900 * E6})  # 100 USDC of the 1x exit window left
    k = ro_keeper(tmp_path, acct)
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
    assert k.sold[0][1] == 98 * E6 * E18 // 40_000_000  # 98% of the room, in HYPE


def test_keeper_hedged_keeps_hedge_until_hype_sold(tmp_path):
    acct = snap(positions=[], native=10 * E18, usdc=600 * E6, value=1000 * E6,
                windows={"turnoverUsed": 0, "exitUsed": 0})
    k = ro_keeper(tmp_path, acct, hedged=True)
    k.swap = lambda a, sell, amt, price: 0  # the sell could not run (e.g. anchor not trusted)
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
    assert k.ledger.client(ACCOUNT)["target"] == pytest.approx(10.0) and k.returned == []
    acct.native = 0  # sold on a later tick: the short share closes and the margin comes back
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW + 60, 0.12)
    assert k.returned == [False]


def test_keeper_reenters_after_min_out(tmp_path):
    acct = snap(positions=[], native=0, usdc=1000 * E6, value=1000 * E6, windows={"turnoverUsed": 0, "exitUsed": 0})
    k = ro_keeper(tmp_path, acct)
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
    assert k.riskout[ACCOUNT] == NOW
    k.riskoff.st["on"] = False
    seen = []
    k.manage_lp = lambda a, g, p, hw, hedged=True: seen.append("lp")
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW + 3600, 0.12)
    assert seen == [] and ACCOUNT in k.riskout  # off, but out < 24 h
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW + 86400, 0.12)
    assert seen == ["lp"] and ACCOUNT not in k.riskout
    assert "riskoff_reenter" in [e for e, _ in k.logs]


def test_keeper_ignores_signal_for_accounts_without_riskoff(tmp_path):
    acct = snap()
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}), {ACCOUNT: make_strategy(hedged=False, nonce=4).record(NOW)})
    k.riskoff = types.SimpleNamespace(st={"on": True})
    assert not k.risk_out(ACCOUNT, NOW)


def test_status_row_shows_risk_off_since(tmp_path):
    acct = snap(positions=[], native=0, usdc=1000 * E6, value=1000 * E6, windows={"turnoverUsed": 0, "exitUsed": 0})
    k = ro_keeper(tmp_path, acct)
    k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
    row = k.status_row(acct, k.r.global_snap(), 0.12)
    assert row["strategy"]["risk_off"] is True
    assert row["risk_off"] == {"enabled": True, "out": True, "since": NOW, "signal_on": True,
                               "signal_since": NOW - 100}
