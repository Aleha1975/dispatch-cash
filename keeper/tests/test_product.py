"""Product flow (offline): signed Strategy preferences (prefs.py), their API endpoints (sa_api), the recommendation
math (recommend.py) and the keeper's width / hedge branching (sa_keeper). Chain and keeper reads are fakes."""
from __future__ import annotations

import json
import math
import os
import sys
import types

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eth_account import Account  # noqa: E402
from eth_account.messages import encode_typed_data  # noqa: E402

from test_sa_api import (  # noqa: E402
    E6, MODULE, NOW, OWNER, PK, PK2, FakeChain, call, http, post, rej, sign_request)
from elysium_keeper import config as C  # noqa: E402
from elysium_keeper import prefs as P  # noqa: E402
from elysium_keeper import recommend as R  # noqa: E402
from elysium_keeper import strategy as S  # noqa: E402
from elysium_keeper.ledger import HedgeLedger  # noqa: E402
from elysium_keeper.sa_api import Policy, Queue, RateLimiter, Reject, SAApi, StatusFile  # noqa: E402
from elysium_keeper.sa_chain import APos, hybrid_address  # noqa: E402
from elysium_keeper.sa_keeper import SAKeeper, pos_half_width, rerange_charge, rerange_reason  # noqa: E402

ACCOUNT = hybrid_address(OWNER)
_ = http  # fixture re-export


def make_strategy(pk=PK, *, mode=0, width=0, hedged=True, nonce=1, deadline=None, module=MODULE, account=None,
                  owner=None, chain_id=99901) -> P.Strategy:
    o = owner or Account.from_key(pk).address
    s = P.Strategy(o, account or hybrid_address(o), module, mode, width, hedged, nonce, deadline or NOW + 3600)
    sig = Account.unsafe_sign_hash(P.digest(s, chain_id), pk).signature
    return P.Strategy(**{**s.__dict__, "signature": bytes(sig)})


def wire(st: P.Strategy) -> dict:
    return st.to_json()


# ================================================================ prefs
def test_strategy_digest_matches_independent_encoder():
    st = make_strategy(mode=1, width=1500, hedged=False, nonce=1_763_000_000_123)
    td = P.typed_data(st, 99901)
    msg = dict(td["message"], nonce=int(td["message"]["nonce"]), deadline=int(td["message"]["deadline"]))
    sm = encode_typed_data(full_message=dict(td, message=msg))
    assert Account.recover_message(sm, signature=st.signature) == OWNER
    assert P.digest(st, 99901) != P.digest(st, 1)  # chain bound
    assert P.digest(st, 99901) != P.digest(P.Strategy(**{**st.__dict__, "module": "0x" + "ee" * 20}), 99901)


def test_strategy_roundtrip_and_record():
    st = make_strategy(mode=1, width=800)
    assert P.parse(st.to_json()) == st
    rec = st.record(NOW)
    assert rec["mode"] == "manual" and rec["width_bps"] == 800 and rec["hedged"] and rec["source"] == "signed"
    assert P.public(rec) == {"mode": "manual", "width_bps": 800, "hedged": True, "nonce": 1, "accepted_at": NOW,
                             "source": "signed", "risk_off": False}
    assert make_strategy().record(NOW)["width_bps"] is None


@pytest.mark.parametrize("mut", [
    lambda d: d.update(extra=1), lambda d: d.pop("hedged"), lambda d: d.update(hedged="yes"),
    lambda d: d.update(widthMode=True), lambda d: d.update(widthBps=-1), lambda d: d.update(widthBps=2 ** 32),
    lambda d: d.update(nonce="01"), lambda d: d.update(nonce=1.5), lambda d: d.update(signature="0x12"),
    lambda d: d.update(signature="0x" + "zz" * 65), lambda d: d.update(owner="0x1234"), lambda d: d.update(module=1),
])
def test_strategy_schema_rejects(mut):
    d = wire(make_strategy())
    mut(d)
    with pytest.raises(P.PrefsError) as e:
        P.parse(d)
    assert e.value.code == "strategy_schema"


def _verify(st, **kw):
    a = dict(owner=OWNER, account=ACCOUNT, module=MODULE, chain_id=99901, now=NOW, b=P.Bounds(), last_nonce=0)
    a.update(kw)
    P.verify(st, **a)


@pytest.mark.parametrize("st,code,kw", [
    (lambda: make_strategy(mode=0, width=500), "strategy_width", {}),
    (lambda: make_strategy(mode=1, width=199), "strategy_width", {}),
    (lambda: make_strategy(mode=1, width=4001), "strategy_width", {}),
    (lambda: make_strategy(mode=2), "strategy_mode", {}),
    (lambda: make_strategy(nonce=0), "strategy_nonce", {}),
    (lambda: make_strategy(nonce=5), "strategy_nonce", {"last_nonce": 5}),
    (lambda: make_strategy(module="0x" + "ee" * 20), "strategy_module", {}),
    (lambda: make_strategy(account=OWNER), "strategy_account", {}),
    (lambda: make_strategy(PK2), "strategy_owner", {}),
    (lambda: make_strategy(owner=OWNER, account=ACCOUNT, pk=PK2), "strategy_signature", {}),
    (lambda: make_strategy(chain_id=1), "strategy_signature", {}),
    (lambda: make_strategy(deadline=NOW - 1), "strategy_deadline", {}),
    (lambda: make_strategy(deadline=NOW + 3 * 86400), "strategy_deadline", {}),
    (lambda: make_strategy(deadline=NOW + 100), "strategy_deadline", {"b": P.Bounds(deadline_min_s=300)}),
])
def test_strategy_verify_rejects(st, code, kw):
    with pytest.raises(P.PrefsError) as e:
        _verify(st(), **kw)
    assert e.value.code == code


def test_strategy_verify_accepts_bounds_and_rejects_high_s():
    for w in (200, 4000):
        _verify(make_strategy(mode=1, width=w))
    _verify(make_strategy(nonce=6), last_nonce=5)
    st = make_strategy()
    from elysium_keeper.sa_api import SECP256K1_N
    s_ = int.from_bytes(st.signature[32:64], "big")
    hi = st.signature[:32] + (SECP256K1_N - s_).to_bytes(32, "big") + bytes([55 - st.signature[64]])
    with pytest.raises(P.PrefsError) as e:
        _verify(P.Strategy(**{**st.__dict__, "signature": hi}))
    assert e.value.code == "strategy_signature"


def test_config_width_bounds_and_pools():
    c = C.from_dict({})
    assert (c.sa.width_min_bps, c.sa.width_max_bps) == (P.WIDTH_MIN_BPS, P.WIDTH_MAX_BPS)
    assert c.sa.pools[0]["pool_id"].startswith("0xb3032695") and c.sa.pools[0]["tick_spacing"] == 60
    with pytest.raises(ValueError):
        C.from_dict({"sa": {"width_min_bps": 500, "width_max_bps": 400}})
    with pytest.raises(ValueError):
        C.from_dict({"sa": {"pools": [{"pool_id": "0x12"}]}})


# ================================================================ API
@pytest.fixture
def env(tmp_path):
    chain = FakeChain()
    chain.balances[OWNER] = 5000 * E6
    rec: list = []
    api = SAApi(chain, Queue(str(tmp_path / "q")), StatusFile(str(tmp_path / "status.json")), Policy(),
                lambda ev, **kw: rec.append((ev, kw)), ip_onboard=RateLimiter(100, 60),
                owner_onboard=RateLimiter(100, 3600), ip_status=RateLimiter(100, 60), wall=lambda: NOW,
                recommend=StatusFile(str(tmp_path / "rec.json")), owner_strategy=RateLimiter(100, 3600))
    return api, chain, tmp_path, rec


def strat_post(api, st, kind="hybrid", owner=OWNER):
    return api.strategy(json.dumps({"owner": owner, "kind": kind, "strategy": wire(st)}).encode(), "1.2.3.4")


def test_onboard_with_strategy_is_queued_for_the_keeper(env):
    api, chain, tmp, _ = env
    body = sign_request(chain=chain)
    body["strategy"] = wire(make_strategy(mode=1, width=1200, hedged=False, nonce=7))
    assert post(api, body)[0] == 202
    req = json.loads((tmp / "q" / f"{OWNER}.json").read_text())
    st = P.parse(req["strategy"])
    assert (st.mode, st.width_bps, st.hedged, st.nonce) == ("manual", 1200, False, 7)
    _, out = api.get_status(f"owner={OWNER}", "1.1.1.1")
    assert out["state"] == "queued" and out["strategy"] == {"mode": "manual", "width_bps": 1200, "hedged": False,
                                                            "nonce": 7, "source": "queued", "risk_off": False}


def test_onboard_without_strategy_still_accepted(env):
    api, chain, tmp, _ = env
    assert post(api, sign_request(chain=chain))[0] == 202
    assert "strategy" not in json.loads((tmp / "q" / f"{OWNER}.json").read_text())


@pytest.mark.parametrize("kw,code", [
    ({"mode": 1, "width": 50}, "strategy_width"),
    ({"pk": PK2, "owner": OWNER}, "strategy_signature"),
    ({"module": "0x" + "ee" * 20}, "strategy_module"),
    ({"deadline": NOW + 60}, "strategy_deadline"),  # shorter than the queue window
])
def test_onboard_with_bad_strategy_queues_nothing(env, kw, code):
    api, chain, tmp, _ = env
    body = sign_request(chain=chain)
    body["strategy"] = wire(make_strategy(**{"account": ACCOUNT, **kw}))
    rej(api, body, 401 if code == "strategy_signature" else 400, code)
    assert not (tmp / "q" / f"{OWNER}.json").exists()


def rej_any(fn, status, code):
    with pytest.raises(Reject) as e:
        fn()
    assert (e.value.status, e.value.code) == (status, code), e.value
    return e.value


def test_strategy_update_flow(env):
    api, chain, tmp, rec = env
    st = make_strategy(mode=1, width=900, nonce=10)
    rej_any(lambda: strat_post(api, st), 409, "not_registered")
    chain.registered[ACCOUNT] = {"revoked": False, "active": True, "owner": OWNER}
    code, out = strat_post(api, st)
    assert code == 202 and out["nonce"] == 10 and out["account"] == ACCOUNT
    assert (tmp / "q" / "strategy" / f"{OWNER}-10.json").exists()
    assert strat_post(api, st)[1]["duplicate"]  # identical resubmission
    rej_any(lambda: strat_post(api, make_strategy(nonce=10, hedged=False)), 409, "strategy_nonce")
    rej_any(lambda: strat_post(api, make_strategy(nonce=9)), 409, "strategy_nonce")  # older than queued
    assert strat_post(api, make_strategy(nonce=11, hedged=False))[0] == 202
    # status: the keeper's active row (nonce 3) plus the newest queued update
    (tmp / "status.json").write_text(json.dumps({"written_at": NOW, "accounts": {ACCOUNT: {
        "owner": OWNER, "kind": "hybrid", "active": True,
        "strategy": {"mode": "auto", "width_bps": None, "hedged": True, "nonce": 3}}}}))
    _, out = api.get_status(f"owner={OWNER}", "1.1.1.1")
    assert out["strategy"]["nonce"] == 3 and out["summary"]["strategy"]["mode"] == "auto"
    assert out["strategy_pending"] == {"mode": "auto", "width_bps": None, "hedged": False, "nonce": 11,
                                       "source": "queued", "risk_off": False}
    assert ("sa_api_strategy_queued", {"owner": OWNER, "account": ACCOUNT, "mode": "manual", "width_bps": 900,
                                       "hedged": True, "nonce": 10}) in rec


def test_strategy_update_refused_for_stopped_account_and_bad_body(env):
    api, chain, _, _ = env
    chain.registered[ACCOUNT] = {"revoked": True, "active": False, "owner": OWNER}
    rej_any(lambda: strat_post(api, make_strategy()), 409, "not_active")
    rej_any(lambda: api.strategy(b'{"owner": 1}', "1.1.1.1"), 400, "schema")
    rej_any(lambda: strat_post(api, make_strategy(), kind="eip7702"), 400, "strategy_account")
    rej_any(lambda: api.strategy(json.dumps({"owner": OWNER, "kind": "hybrid", "strategy": wire(make_strategy()),
                                             "x": 1}).encode(), "1.1.1.1"), 400, "schema")


def test_strategy_nonce_must_beat_active_row(env):
    api, chain, tmp, _ = env
    chain.registered[ACCOUNT] = {"revoked": False, "active": True, "owner": OWNER}
    (tmp / "status.json").write_text(json.dumps({"written_at": NOW, "accounts": {ACCOUNT: {
        "owner": OWNER, "active": True, "strategy": {"nonce": 50}}}}))
    rej_any(lambda: strat_post(api, make_strategy(nonce=50)), 409, "strategy_nonce")
    assert strat_post(api, make_strategy(nonce=51))[0] == 202


def test_recommend_endpoint(env):
    api, _, tmp, _ = env
    rej_any(lambda: api.get_recommend("1.1.1.1"), 503, "no_recommendation")
    (tmp / "rec.json").write_text(json.dumps({"version": 1, "generated_at": NOW - 100, "grid": []}))
    code, out = api.get_recommend("1.1.1.1")
    assert code == 200 and out["age_s"] == 100 and out["stale"] is False and out["ok"]
    api.wall = lambda: NOW + 10_000
    assert api.get_recommend("1.1.1.1")[1]["stale"] is True


def test_http_strategy_and_recommend_routes(http):
    base, (api, chain, tmp, _) = http
    p = base + "/elysium-api/sa"
    assert call(p + "/recommend")[0] == 503
    (tmp / "rec.json").write_text(json.dumps({"version": 1, "generated_at": NOW}))
    api.recommend = StatusFile(str(tmp / "rec.json"))
    st, out, _ = call(p + "/recommend")
    assert st == 200 and out["version"] == 1
    assert call(p + "/recommend?x=1")[0] == 400
    assert call(p + "/recommend", "POST", b"{}")[0] == 405
    assert call(p + "/strategy")[0] == 405
    chain.registered[ACCOUNT] = {"revoked": False, "active": True, "owner": OWNER}
    body = json.dumps({"owner": OWNER, "kind": "hybrid", "strategy": wire(make_strategy(nonce=3))}).encode()
    st, out, _ = call(p + "/strategy", "POST", body)
    assert st == 202 and out["nonce"] == 3, out


# ================================================================ recommendation math
def test_position_math_basics():
    tl, tu = -1000, 1000
    assert R.base_frac(0, tl, tu) == pytest.approx(0.5, abs=1e-9)
    assert R.base_frac(-2000, tl, tu) == 1.0 and R.base_frac(2000, tl, tu) == 0.0
    h = 0.02
    tl2, tu2 = math.floor(math.log(1 - h) / R.LN_TICK), math.ceil(math.log(1 + h) / R.LN_TICK)
    assert R.value_per_l(0, tl2, tu2) == pytest.approx(h, rel=0.02)  # V / (L sqrt P) ~ h for a narrow range
    assert R.il_at(0, 0, tl, tu) == 0
    assert 0 < R.il_at(0, -300, tl, tu) < R.il_at(0, -900, tl, tu)  # loss grows with the move
    assert R.il_at(0, -5000, tl, tu) > R.il_at(0, -1000, tl, tu)  # beyond the range: all HYPE, keeps losing
    assert R.edge_loss(0.05) < R.edge_loss(0.10) < R.edge_loss(0.20)


def test_rebalances_scale_with_vol_over_width():
    r1 = R.rebalances_per_day(0.05, 0, -1000, 1000, 0.1)
    assert R.rebalances_per_day(0.05, 0, -2000, 2000, 0.1) == pytest.approx(r1 / 4, rel=1e-6)
    assert R.rebalances_per_day(0.10, 0, -1000, 1000, 0.1) == pytest.approx(r1 * 4, rel=1e-6)
    assert R.rebalances_per_day(0.05, 0, -1000, 1000, 0.0) < r1  # no edge trigger: fewer re-ranges
    a = 1000 * 0.8 * R.LN_TICK
    assert r1 == pytest.approx(0.05 ** 2 / (a * a), rel=1e-6)


def _model(**kw):
    m = dict(sigma_daily=0.05, price=40_000_000, tick=float(math.log(40e6 / 1e18) / R.LN_TICK), spacing=60,
             fee_tier=0.003, fees_per_l_day=1e-8, turnover_bps=20000, slippage_bps=150, band_bps=150, lp_frac=0.72)
    m.update(kw)
    return R.Model(**m)


def test_turnover_floor_follows_the_module_budget():
    f_big, f_small = R.turnover_floor(_model(turnover_bps=20000)), R.turnover_floor(_model(turnover_bps=5000))
    assert f_small > f_big  # a smaller daily turnover budget needs a wider range
    assert _model().metrics(f_big * 1.05)["in_range_frac"] == 1.0
    assert _model().metrics(f_big * 0.7)["in_range_frac"] < 1.0
    assert R.turnover_floor(_model(sigma_daily=0.10)) > f_big


def test_metrics_and_dilution():
    m = _model()
    a, b = m.metrics(0.05), m.metrics(0.20)
    assert a["fee_apr_in_range"] > b["fee_apr_in_range"] > 0  # narrower earns more per $ while in range
    assert a["rebalances_per_week"] > b["rebalances_per_week"]
    assert a["lower"] < 40 < a["upper"] and a["tick_lower"] % 60 == 0 and a["tick_upper"] % 60 == 0
    d = _model(active_liquidity=10 ** 15, our_usd=50_000).metrics(0.05)
    assert d["fee_apr_in_range"] < a["fee_apr_in_range"]
    assert a["est_net_apr"] == pytest.approx(a["est_fee_apr"] - a["est_rerange_loss_apr"] - a["est_swap_cost_apr"],
                                             abs=2e-4)


def test_effective_half_width():
    assert R.effective_half_width("auto", None, 0.12, 0.05, 0.4) == (0.12, False)
    assert R.effective_half_width("manual", 800, 0.12, 0.05, 0.4) == (0.08, False)
    assert R.effective_half_width("manual", 300, 0.12, 0.05, 0.4) == (0.05, True)  # widened to the floor
    assert R.effective_half_width("manual", 4000, 0.12, 0.05, 0.3) == (0.3, False)


def test_build_output_shape():
    cfg = C.from_dict({})
    price = 40_000_000
    tick = int(math.log(price / 1e18) / R.LN_TICK)
    doc = R.build(sig72=0.05, sig7d=0.045, price=price, tick=tick, liquidity=10 ** 16, fee_tier=0.003, fpl=1e-8,
                  fpl24=5e-9, days=7.0, params=R.DEFAULT_PARAMS, cfg=cfg, pool=cfg.sa.pools[0], now=NOW, lp_h=0.72,
                  lp_u=0.97)
    assert doc["recommended"]["width_bps"] == round(S.range_half_width(0.05) * 10_000)  # same as the keeper's auto
    assert doc["bounds"]["min_bps"] == 200 and doc["bounds"]["max_bps"] == 4000
    assert doc["bounds"]["manual_min_bps"] >= max(200, doc["bounds"]["turnover_floor_bps"])
    assert doc["bounds"]["manual_min_bps"] % 50 == 0
    widths = [g["width_bps"] for g in doc["grid"]]
    assert widths == sorted(widths) and widths[0] == 200 and widths[-1] == 4000
    for g in doc["grid"]:
        assert set(g["hedged"]) >= {"rebalances_per_week", "est_fee_apr", "est_net_apr", "in_range_frac"}
        assert "il_at_edge" in g["unhedged"] and "il_at_edge" not in g["hedged"]
        assert g["unhedged"]["est_fee_apr"] >= g["hedged"]["est_fee_apr"]  # more of the account in the LP (equal
        # where the turnover budget binds: the budget then caps the re-ranges per $ of account either way)
    assert doc["pool"]["fee_tier"] == 0.003 and doc["vol"]["daily_72h"] == 0.05
    json.dumps(doc)


def test_fees_per_l_day_wraps():
    then = {"fg0": 2 ** 256 - 2 ** 128, "fg1": 0}
    now = {"fg0": 2 ** 128, "fg1": 3 * 2 ** 128}
    assert R.fees_per_l_day(now, then, 2.0, 1e-11) == pytest.approx((2 * 1e-11 + 3) / 2)


# ================================================================ keeper branching
def P_(tl, tu, tid=1, liq=10 ** 12):
    return APos(tid, tl, tu, liq)


def test_rerange_reason():
    ps = [P_(-600, 600)]
    hw = pos_half_width(-600, 600)
    assert rerange_reason(0, [], hw, "auto", 0.1, 0, None) is None
    assert rerange_reason(700, ps, hw, "auto", 0.1, 0, None) == "out_of_range"
    assert rerange_reason(-600, ps, hw, "auto", 0.1, 0, None) == "near_edge"  # at the lower edge: in range
    assert rerange_reason(500, ps, hw, "auto", 0.1, 0, None) == "near_edge"
    assert rerange_reason(0, ps, hw, "auto", 0.1, 0, None) is None
    assert rerange_reason(0, ps, hw * 3, "auto", 0.1, 0, None) == "vol_changed"
    assert rerange_reason(0, ps, hw * 1.5, "auto", 0.1, 0, None) is None  # auto: within the factor
    assert rerange_reason(0, ps, hw * 1.5, "auto", 0.1, 2, {"nonce": 1}) == "prefs_changed"
    assert rerange_reason(0, ps, hw * 1.1, "auto", 0.1, 2, {"nonce": 1}) is None  # same width: no churn
    assert rerange_reason(0, ps, hw * 1.5, "manual", 0.1, 2, {"nonce": 2}) == "width_mismatch"
    assert rerange_reason(500, ps, hw, "auto", 0.0, 0, None) is None  # edge trigger off


def test_pos_half_width_and_charge():
    tl, tu = S.range_ticks(40_000_000, 0.10)
    assert pos_half_width(tl, tu) == pytest.approx(0.10, abs=0.006)  # widened outward to 60 ticks
    v = 1000 * E6
    centre = rerange_charge(v, 0, (-600, 600), (-600, 600), 150, 150)
    edge = rerange_charge(v, -540, (-600, 600), (-1140, 60), 150, 150)
    assert centre == pytest.approx(v * 1.0, rel=1e-6)  # no swap, only the add charge (SA-5 M-2: whole principal)
    assert edge > centre


class FakeReader:
    """Just enough of ModuleReader for account_tick / manage_lp / process_strategy_requests."""

    def __init__(self, accounts, tick=0, sp=None):
        self.accts, self.tick = accounts, tick
        self.sp = sp or int(1.0001 ** (tick / 2) * 2 ** 96)
        self.m = types.SimpleNamespace(address=MODULE, call=lambda *a, **k: 0)
        self.pool_id = bytes.fromhex(C.from_dict({}).sa.pools[0]["pool_id"][2:])

    def account(self, a, price=None):
        if a not in self.accts:
            raise ValueError(f"{a} is not registered")
        return self.accts[a]

    def slot0(self):
        return self.sp, self.tick

    def global_snap(self):
        from test_sa_unit import _g
        return _g(last_price_time=NOW, last_price_moved=NOW - 400, tick=self.tick)


def snap(**kw):
    from elysium_keeper.sa_chain import AccountSnap
    d = dict(address=ACCOUNT, kind="hybrid", active=True, until=NOW + 10 ** 6, contributed=1000 * E6, hwm=0,
             hedge_equity=0, net_margin=0, hedge_epoch=0, last_fee_time=NOW, fees_paid=0, usdc=1000 * E6, native=0,
             positions=[], value=1000 * E6, budgets={}, windows={"turnoverUsed": 0}, owner=OWNER)
    d.update(kw)
    return AccountSnap(**d)


def bare_keeper(tmp_path, reader, prefs=None):
    k = SAKeeper.__new__(SAKeeper)
    k.cfg = C.from_dict({"sa": {"requests_dir": str(tmp_path / "q")}})
    k.st, k.sa, k.r = k.cfg.strategy, k.cfg.sa, reader
    k.state = types.SimpleNamespace(d={"prefs": prefs or {}, "ranges": {}})
    k.prefs, k.ranges = k.state.d["prefs"], k.state.d["ranges"]
    k.riskoff = types.SimpleNamespace(st={})
    k.riskout = k.state.d.setdefault("riskoff_out", {})
    k.ledger = HedgeLedger({})
    k.logs, k.calls = [], []
    k.log = lambda ev, **kw: k.logs.append((ev, kw))
    k.alert = lambda *a, **kw: None
    k.now = lambda: NOW
    k.act = lambda fn, *a, **kw: k.calls.append((fn, a))
    k._vol, k._floor = (NOW, 0.12, 40.0, 0.048), None
    return k


def test_account_tick_hedged_vs_unhedged(tmp_path):
    for hedged in (True, False):
        st = make_strategy(hedged=hedged, nonce=4)
        k = bare_keeper(tmp_path, FakeReader({ACCOUNT: snap()}), {ACCOUNT: st.record(NOW)})
        seen = []
        k.margin = lambda s, g, p: seen.append("margin")
        k.manage_lp = lambda a, g, p, hw, hedged=True: seen.append(("lp", round(hw, 4), hedged))
        k.fee = lambda a, g, n: seen.append("fee")
        k.return_margin = lambda s, g, close: seen.append(("return", close))
        k.report_equity = lambda s, refresh=False: seen.append("report")
        k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
        if hedged:
            assert seen == ["margin", ("lp", 0.12, True), "fee", "report"]
        else:
            assert seen == [("lp", 0.12, False), "fee", ("return", False), "report"]
            assert k.ledger.client(ACCOUNT)["target"] == 0.0


def test_width_for_manual_and_floor(tmp_path):
    k = bare_keeper(tmp_path, FakeReader({}))
    g = k.r.global_snap()
    assert k.width_for(ACCOUNT, g, 0.12)[0] == 0.12  # no signed preference: auto
    k.prefs[ACCOUNT] = make_strategy(mode=1, width=2500).record(NOW)
    assert k.width_for(ACCOUNT, g, 0.12)[:2] == (0.25, False)
    k.prefs[ACCOUNT] = make_strategy(mode=1, width=200).record(NOW)
    hw, clamped, floor = k.width_for(ACCOUNT, g, 0.12)
    assert clamped and hw == floor > 0.02


def test_manage_lp_near_edge_waits_for_turnover_then_reranges(tmp_path):
    tick = int(math.log(40e6 / 1e18) / R.LN_TICK)
    tl, tu = S.range_ticks(40_000_000, 0.10)
    tick = tl + 30  # inside, within 10% of the lower edge
    pos = P_(tl, tu, tid=9, liq=10 ** 15)
    acct = snap(positions=[pos], usdc=10 * E6, windows={"turnoverUsed": 1990 * E6})
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}, tick=tick))
    k.manage_lp(ACCOUNT, k.r.global_snap(), 40_000_000, 0.10)
    assert k.calls == [] and k.logs[0][0] == "rerange_postponed" and k.logs[0][1]["why"] == "near_edge"
    acct.windows = {"turnoverUsed": 0}
    k.logs.clear()
    k.manage_lp(ACCOUNT, k.r.global_snap(), 40_000_000, 0.10)
    assert k.calls[0][0] == "burnPosition" and k.calls[0][1][1] == 9
    assert ("burned", {"account": ACCOUNT, "token_id": 9, "why": "near_edge"}) in k.logs


def test_manage_lp_out_of_range_burns_regardless_of_turnover(tmp_path):
    tl, tu = -240000, -239000
    acct = snap(positions=[P_(tl, tu, tid=5)], windows={"turnoverUsed": 10 ** 12})
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}, tick=tu + 600))
    k.manage_lp(ACCOUNT, k.r.global_snap(), 40_000_000, 0.10)
    assert k.calls and k.calls[0][0] == "burnPosition"


def _drop(tmp_path, st: P.Strategy, kind="hybrid"):
    d = tmp_path / "q" / "strategy"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{st.owner}-{st.nonce}.json").write_text(json.dumps({"owner": st.owner, "kind": kind,
                                                               "account": st.account, "strategy": wire(st)}))


def test_keeper_applies_strategy_updates_in_nonce_order(tmp_path):
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: snap()}))
    _drop(tmp_path, make_strategy(mode=1, width=600, nonce=12))
    _drop(tmp_path, make_strategy(hedged=False, nonce=11))
    _drop(tmp_path, make_strategy(nonce=12, hedged=False))  # same file name: the later write wins on disk
    k.process_strategy_requests(NOW)
    rec = k.prefs[ACCOUNT]
    assert rec["nonce"] == 12 and rec["signature"].startswith("0x")
    done = sorted(os.listdir(tmp_path / "q" / "strategy" / "done"))
    assert done == [f"{OWNER}-11.json", f"{OWNER}-12.json"]
    # a replay of an old nonce is refused by the keeper's own check
    _drop(tmp_path, make_strategy(mode=1, width=3000, nonce=11))
    k.process_strategy_requests(NOW)
    assert k.prefs[ACCOUNT]["nonce"] == 12
    failed = json.loads((tmp_path / "q" / "strategy" / "failed" / f"{OWNER}-11.json").read_text())
    assert "strategy_nonce" in failed["result"]["error"]


def test_keeper_strategy_waits_for_registration_until_deadline(tmp_path):
    k = bare_keeper(tmp_path, FakeReader({}))
    _drop(tmp_path, make_strategy(nonce=3, deadline=NOW + 600))
    k.process_strategy_requests(NOW)
    assert os.path.exists(tmp_path / "q" / "strategy" / f"{OWNER}-3.json")  # still queued
    k.process_strategy_requests(NOW + 601)
    assert os.path.exists(tmp_path / "q" / "strategy" / "failed" / f"{OWNER}-3.json") and ACCOUNT not in k.prefs


def test_keeper_refuses_strategy_from_another_owner(tmp_path):
    other = Account.from_key(PK2).address
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: snap(owner=other)}))
    _drop(tmp_path, make_strategy(nonce=3))
    k.process_strategy_requests(NOW)
    assert ACCOUNT not in k.prefs


def test_status_row_has_strategy_range_and_return(tmp_path):
    tl, tu = S.range_ticks(40_000_000, 0.10)
    acct = snap(positions=[P_(tl, tu)], value=1050 * E6)
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}, tick=(tl + tu) // 2))
    k.prefs[ACCOUNT] = make_strategy(mode=1, width=1000, hedged=False, nonce=2).record(NOW)
    row = k.status_row(acct, k.r.global_snap(), 0.12)
    assert row["return_pct"] == pytest.approx(5.0)
    assert row["range"]["in_range"] and row["range"]["lower"] < 40 < row["range"]["upper"]
    assert row["strategy"]["mode"] == "manual" and row["strategy"]["effective_width_bps"] == 1000
    assert row["strategy"]["hedged"] is False and "signature" not in row["strategy"]


# ---------------------------------------------------------------- SA-4 (round-4 audit) keeper mirrors
def test_sa4_fee_waits_a_day_after_priced_flow(tmp_path):
    """SA-4 M-2: chargeFee waits a day after a booked price-dependent client flow; the keeper books a pending flow
    with sync(a) first and then waits (no reverting chargeFee)."""
    acct = snap(last_fee_time=NOW - 8 * 86400, pending=5 * E6, priced_flow_time=NOW - 3600, value=1200 * E6)
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}))
    g = k.r.global_snap()
    k.fee(ACCOUNT, g, NOW)
    assert [fn for fn, _ in k.calls] == ["sync"]
    assert any(ev == "fee_waits_flow" for ev, _ in k.logs)
    acct.pending, acct.priced_flow_time = 0, NOW - 86400 - 1
    k.calls.clear()
    k.fee(ACCOUNT, g, NOW)
    assert "chargeFee" in [fn for fn, _ in k.calls]


def test_sa4_return_and_fee_profit_use_net_margin():
    """SA-4 M-3: the keeper returns at most min(hedge equity, net margin); equity above the net margin is no profit."""
    s = snap(hedge_equity=900 * E6, net_margin=300 * E6, value=2000 * E6, contributed=1000 * E6)
    assert s.keeper_return_cap == 300 * E6
    assert s.nav == 1400 * E6 and s.fee_profit == 400 * E6
    s2 = snap(hedge_equity=200 * E6, net_margin=300 * E6)
    assert s2.keeper_return_cap == 200 * E6 and s2.nav == s2.value


# ---------------------------------------------------------------- SA-6 (round-6 audit) keeper mirrors
def test_sa6_fee_waits_for_recent_confirmation(tmp_path):
    """SA-6 L-3: chargeFee needs the guardian's confirmation of the level within a day; the keeper waits and asks."""
    from test_sa_unit import _g
    acct = snap(last_fee_time=NOW - 8 * 86400, value=1200 * E6)
    k = bare_keeper(tmp_path, FakeReader({ACCOUNT: acct}))
    pb = {"priceBase": 40_000_000, "priceBaseTime": NOW - 86400 - 1}
    g = _g(last_price_time=NOW, last_price_moved=NOW - 400, price_budget=pb)
    assert not g.base_fresh(NOW) and g.base_fresh(NOW - 1)
    k.fee(ACCOUNT, g, NOW)
    assert "chargeFee" not in [fn for fn, _ in k.calls]
    assert any(ev == "fee_waits_confirm" for ev, _ in k.logs)
    pb["priceBaseTime"] = NOW - 3600
    k.fee(ACCOUNT, g, NOW)
    assert "chargeFee" in [fn for fn, _ in k.calls]


def test_sa6_account_tick_refreshes_booking(tmp_path):
    """SA-6 M-1: a zero-flow sync re-books an account whose last priced sync is older than BOOK_REFRESH_S, so a later
    client flow is raised by the prices reported since (not by its whole value beyond the module's 24 h ring)."""
    from elysium_keeper.sa_keeper import BOOK_REFRESH_S
    for age, want in ((BOOK_REFRESH_S, True), (60, False)):
        k = bare_keeper(tmp_path, FakeReader({ACCOUNT: snap(book_time=NOW - age)}),
                        {ACCOUNT: make_strategy(hedged=False, nonce=5).record(NOW)})
        k.manage_lp = lambda *a, **kw: None
        k.fee = lambda *a: None
        k.return_margin = lambda *a, **kw: None
        k.report_equity = lambda *a, **kw: None
        k.account_tick(ACCOUNT, 40_000_000, k.r.global_snap(), NOW, 0.12)
        assert ("sync" in [fn for fn, _ in k.calls]) is want
