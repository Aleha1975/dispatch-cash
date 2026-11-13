"""End-to-end keeper run on a local anvil fork of Elysium (chain 99901). HL is the dry-run adapter with mocked
equity and a mocked price feed. Run with:  ELYSIUM_FORK=1 python3 -m pytest -s tests/test_e2e_fork.py

Scenario (hedged vault, then growth vault):
  deposits -> settle -> chunked HYPE buy + mint (+-3% range from 72h vol) -> margin to treasury -> dry-run short
  -> third-party volume (fees) -> settle charges perf fee -> +5% move out of range -> re-range + re-hedge
  -> 2/3 redeem: decrease LP, sell HYPE, push USDC -> excess margin returned from treasury -> restart is a no-op
  -> /status endpoint -> growth: crash -10% in 4h -> burn + sell to USDC -> hold 2h -> re-enter after 24h + calm vol
  -> HL/pool divergence: clamp (2%) and skip (5%).
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import urllib.request

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from elysium_keeper import config as C  # noqa: E402
from elysium_keeper.hl import DryRunAdapter  # noqa: E402
from elysium_keeper.infra import Log  # noqa: E402
from elysium_keeper.keeper import Keeper  # noqa: E402
from elysium_keeper.rpc import ERC20_ABI, Contract  # noqa: E402
from elysium_keeper.vault import ABI_PATH  # noqa: E402
from forkutil import USDC, Fork, MockHL, Trader, addr, assert_close  # noqa: E402

pytestmark = pytest.mark.skipif(not os.environ.get("ELYSIUM_FORK"), reason="set ELYSIUM_FORK=1 (needs anvil+forge)")

OWNER, KEEPER, GUARDIAN, FEE_TO, TREASURY = addr(1), addr(2), addr(3), addr(4), addr(5)
ALICE, BOB, CAROL, SINK = addr(0xA1), addr(0xB0), addr(0xC0), addr(0x5C)
E6 = 10 ** 6


@pytest.fixture(scope="module")
def env():
    tmp = tempfile.mkdtemp(prefix="keeper-e2e-")
    fork = Fork(os.environ.get("ELYSIUM_RPC", "https://rpc.elysium.kinetiq.xyz"),
                int(os.environ["ELYSIUM_FORK_BLOCK"]) if os.environ.get("ELYSIUM_FORK_BLOCK") else None,
                os.path.join(tmp, "anvil.log"))
    for a in (KEEPER, TREASURY, ALICE, BOB, CAROL, OWNER, GUARDIAN, SINK):
        fork.set_balance(a, 10 ** 21)
    yield fork, tmp
    fork.close()


def make_keeper(fork, tmp, vault, mode, hl, name, sink_log):
    cfg = C.from_dict({
        "name": name,
        "chain": {"rpc_url": fork.url, "vault": vault, "keeper": KEEPER, "signer": "unlocked"},
        "strategy": {"mode": mode},
        "hl": {"adapter": "dry_run", "equity_source": "mock"},
        "state_path": os.path.join(tmp, f"{name}.state.json"),
        "log_path": os.path.join(tmp, f"{name}.log"),
    })
    log = Log(cfg.log_path, name, echo=False)
    adapter = DryRunAdapter(cfg.hl, {}, log, mark_fn=hl.mid) if mode == "hedged" else None
    return Keeper(cfg, hl_info=hl, adapter=adapter, log=log, alert_sink=lambda lvl, txt: sink_log.append((lvl, txt)))


def vault_contract(fork, address):
    return Contract(fork.rpc, address, json.load(open(ABI_PATH)))


def deposit(fork, v, who, usd):
    usdc = Contract(fork.rpc, USDC, ERC20_ABI)
    fork.deal_usdc(who, usd * E6)
    fork.send(who, usdc, "approve", v.address, 2 ** 256 - 1)
    fork.send(who, v, "requestDeposit", usd * E6)


def run_until(k, fork, trader, hl, cond, max_ticks=10, step_s=120):
    """Tick with arbitrage in between (an arbitrageur pulls the pool back to the HL price after our swaps)."""
    for _ in range(max_ticks):
        trader.move_to(int(hl.mid() * 1e6))
        st = k.tick()
        assert not st["errors"], st["errors"]
        if cond():
            return st
        fork.advance(step_s)
    raise AssertionError("condition not reached")


def test_end_to_end(env):
    fork, tmp = env
    alerts: list = []
    report: dict = {}

    # ------------------------------------------------------------- hedged vault, deployed with the repo script
    hv_addr = fork.deploy_vault(hedged=True, owner=OWNER, keeper=KEEPER, guardian=GUARDIAN, fee_to=FEE_TO,
                                treasury=TREASURY, name="Hedged HYPE/USDC v4", symbol="hvHYPE")
    hv = vault_contract(fork, hv_addr)
    trader = Trader(fork, hv)
    p0 = trader.price()
    hl = MockHL(fork.now(), p0 / 1e6)
    kh = make_keeper(fork, tmp, hv_addr, "hedged", hl, "hedged", alerts)
    usdc = Contract(fork.rpc, USDC, ERC20_ABI)

    deposit(fork, hv, ALICE, 4000)
    deposit(fork, hv, BOB, 2000)
    st = kh.tick()
    assert hv.call("pendingDeposits") == 0 and hv.call("lastNav") == 6000 * E6
    assert len(hv.call("positions")) == 1, "first tick mints"
    assert st["range_rule"]["half_width"] == pytest.approx(0.03)
    # operator bridges the margin the keeper sent to the treasury (simulated: treasury -> sink, mock HL credit)
    sent = usdc.call("balanceOf", TREASURY)
    assert sent > 0 and hv.call("hedgeEquity") == sent
    assert any("MANUAL: bridge" in t for _, t in alerts)
    fork.send(TREASURY, usdc, "transfer", SINK, sent)
    kh.adapter.credit_margin(sent / 1e6)

    def deployed():
        s = kh.reader.snapshot()
        return s.idle_asset < s.last_nav * 0.25 and s.native * s.pool_price // 10 ** 18 < 60 * E6
    st = run_until(kh, fork, trader, hl, deployed)
    if usdc.call("balanceOf", TREASURY):  # any top-up sent while converging
        extra = usdc.call("balanceOf", TREASURY)
        fork.send(TREASURY, usdc, "transfer", SINK, extra)
        kh.adapter.credit_margin(extra / 1e6)
    s = kh.reader.snapshot()
    nav = s.nav_at(int(hl.mid() * 1e6))
    assert_close(nav, 6000 * E6, 0.01, "NAV after deployment")
    expo = (s.lp_base + s.native) / 1e18
    short = -kh.adapter.position()
    assert abs(short - expo) <= 0.10 * expo, (short, expo)
    p = s.positions[0]
    lo, hi = 1.0001 ** p.tl * 1e12, 1.0001 ** p.tu * 1e12
    assert lo < hl.mid() < hi and hi / lo < 1.08
    report["deploy"] = dict(nav=nav / 1e6, lp_hype=s.lp_base / 1e18, lp_usdc=s.lp_asset / 1e6, short=short,
                            range=(round(lo, 3), round(hi, 3)), margin=s.hedge_equity / 1e6)

    # ------------------------------------------------------------- fee accrual + performance fee at settlement
    px = int(hl.mid() * 1e6)
    lp_val0 = s.lp_asset + s.lp_base * px // 10 ** 18
    trader.volume(4000, 20)
    trader.move_to(px)
    s2 = kh.reader.snapshot()
    lp_val1 = s2.lp_asset + s2.lp_base * px // 10 ** 18
    assert lp_val1 > lp_val0, "LP fees accrue"
    nav_before = hv.call("lastNav")
    ep = hv.call("epoch")
    fork.advance(3600)
    kh.tick()
    assert hv.call("epoch") > ep, "hourly settle"
    assert hv.call("lastNav") > nav_before
    fee_shares = hv.call("balanceOf", FEE_TO)
    assert fee_shares > 0, "performance fee minted above HWM"
    report["fees"] = dict(lp_fee_usd=(lp_val1 - lp_val0) / 1e6, nav=hv.call("lastNav") / 1e6, fee_shares=fee_shares)

    # ------------------------------------------------------------- +5% move: out of range -> re-range + re-hedge
    old_id = s2.positions[0].token_id
    trader.move_to(int(px * 1.05))
    hl.set(fork.now(), trader.price() / 1e6)
    st = run_until(kh, fork, trader, hl, lambda: (lambda s: bool(s.positions) and s.positions[0].token_id != old_id
                                                  and s.native * s.pool_price // 10 ** 18 < 60 * E6
                                                  and s.idle_asset < s.last_nav * 0.25)(kh.reader.snapshot()))
    s3 = kh.reader.snapshot()
    p3 = s3.positions[0]
    assert p3.tl <= s3.tick < p3.tu
    assert st["range_rule"]["half_width"] > 0.05, "the +5% jump widens the 72h-vol range"
    assert len(s3.positions) == 1
    run_until(kh, fork, trader, hl, lambda: True)
    s3 = kh.reader.snapshot()
    expo = (s3.lp_base + s3.native) / 1e18
    assert abs(-kh.adapter.position() - expo) <= 0.10 * expo
    report["rerange"] = dict(new_range=(round(1.0001 ** p3.tl * 1e12, 3), round(1.0001 ** p3.tu * 1e12, 3)),
                             half_width=st["range_rule"]["half_width"], short=-kh.adapter.position(), expo=expo)

    # ------------------------------------------------------------- redeem 2/3: free liquidity, push USDC
    sh = hv.call("balanceOf", ALICE)
    value = s3.redeem_value(int(hl.mid() * 1e6), sh, kh.treasury_capital(s3))  # fresh HL equity, not on-chain
    a0 = usdc.call("balanceOf", ALICE)
    fork.send(ALICE, hv, "requestRedeem", sh)
    run_until(kh, fork, trader, hl, lambda: hv.call("pendingRedeems") == 0, max_ticks=12)
    got = usdc.call("balanceOf", ALICE) - a0
    assert_close(got, value, 0.02, "alice redeem pushed")
    assert hv.call("balanceOf", ALICE) == 0
    report["redeem"] = dict(expected=value / 1e6, got=got / 1e6)

    # excess margin: keeper asks for a manual HL withdraw; operator does it (mock) and approves; keeper pulls it
    run_until(kh, fork, trader, hl, lambda: True)
    assert any("MANUAL: withdraw" in t for _, t in alerts)
    m = kh.status["margin"]
    assert m["plan"] == "return"
    back = int(m["amount"] * E6)
    kh.adapter.credit_margin(-back / 1e6)
    fork.send(SINK, usdc, "transfer", TREASURY, back)
    fork.send(TREASURY, usdc, "approve", hv_addr, back)
    he0 = hv.call("hedgeEquity")
    run_until(kh, fork, trader, hl, lambda: True)
    assert any(a["fn"] == "returnHedgeMargin" for a in kh.actions)
    assert abs(hv.call("hedgeEquity") - (he0 - back)) < 1 * E6
    report["margin_return"] = dict(returned=back / 1e6, hedge_equity=hv.call("hedgeEquity") / 1e6)

    # ------------------------------------------------------------- restart safety: a fresh process is a no-op
    run_until(kh, fork, trader, hl, lambda: True)
    ep, pos, sim = hv.call("epoch"), hv.call("positions"), dict(kh.adapter.sim)
    kh2 = make_keeper(fork, tmp, hv_addr, "hedged", hl, "hedged", alerts)
    kh2.adapter.sim = kh2.state.d["hl_sim"]
    st = kh2.tick()
    assert not st["errors"] and hv.call("epoch") == ep and hv.call("positions") == pos
    assert kh2.adapter.sim["pos"] == sim["pos"] and kh2.actions == []

    # ------------------------------------------------------------- /status endpoint (localhost)
    kh2.cfg.status_port = 0
    from elysium_keeper.infra import StatusServer
    srv = StatusServer("127.0.0.1", 0, kh2.get_status)
    js = json.load(urllib.request.urlopen(f"http://127.0.0.1:{srv.port}/status", timeout=5))
    srv.close()
    for key in ("ok", "epoch", "price", "range", "hedge", "margin", "queues", "holdings", "last_nav_usd"):
        assert key in js, key
    assert js["ok"] is True

    # ------------------------------------------------------------- growth vault: crash guard
    gv_addr = fork.deploy_vault(hedged=False, owner=OWNER, keeper=KEEPER, guardian=GUARDIAN, fee_to=FEE_TO,
                                treasury=TREASURY, name="Growth HYPE/USDC v4", symbol="gvHYPE")
    gv = vault_contract(fork, gv_addr)
    tg = Trader(fork, gv)
    kg = make_keeper(fork, tmp, gv_addr, "growth", hl, "growth", alerts)
    deposit(fork, gv, CAROL, 3000)
    run_until(kg, fork, tg, hl, lambda: (lambda s: bool(s.positions) and s.idle_asset < 400 * E6)(kg.reader.snapshot()))
    assert kg.guard.mode == "normal"
    pc = tg.price()
    tg.move_to(int(pc * 0.90))
    t_crash = fork.now()
    hl.set(t_crash, tg.price() / 1e6)
    st = kg.tick()
    assert st["crash_action"] == "exit" and kg.guard.mode == "out"
    assert len(gv.call("positions")) == 0
    run_until(kg, fork, tg, hl, lambda: rpc_balance(fork, gv_addr) * tg.price() // 10 ** 18 < 6 * E6)
    s = kg.reader.snapshot()
    assert s.lp_base == 0 and s.lp_asset == 0
    report["crash"] = dict(drop=st["crash"]["drop"], usdc=s.idle_asset / 1e6, nav=s.nav_at(tg.price()) / 1e6)
    fork.advance(2 * 3600)
    hl.set(fork.now(), hl.mid())
    st = run_until(kg, fork, tg, hl, lambda: True)
    assert st["crash_action"] == "hold" and len(gv.call("positions")) == 0
    fork.advance(23 * 3600)
    hl.set(fork.now(), hl.mid())
    st = run_until(kg, fork, tg, hl, lambda: True)
    assert st["crash_action"] == "reenter" and kg.guard.mode == "normal"
    assert len(gv.call("positions")) == 1, "re-entered"
    report["reenter_after_h"] = (fork.now() - t_crash) / 3600

    # ------------------------------------------------------------- HL vs pool divergence: clamp, then skip
    pool = tg.price()
    hl.set(fork.now(), pool * 1.02 / 1e6)
    st = kg.tick()
    assert st["price"]["status"] == "clamped" and not st["errors"]
    hl.set(fork.now(), pool * 1.05 / 1e6)
    ep = gv.call("epoch")
    fork.advance(3700)
    st = kg.tick()
    assert st["price"]["status"] == "skip" and gv.call("epoch") == ep
    assert any("skipping tick" in t for _, t in alerts)
    hl.set(fork.now(), pool / 1e6)

    print("\nE2E REPORT", json.dumps(report, indent=1, default=str))
    print("alerts sent:", len(alerts), "| logs in", tmp)


def rpc_balance(fork, a):
    return fork.rpc.balance(a)


def test_cli_run_once_with_real_hl_info(env):
    """The CLI entry point on the fork with the REAL HL info API (read only) and the dry-run adapter."""
    import subprocess
    fork, tmp = env
    v = fork.deploy_vault(hedged=True, owner=OWNER, keeper=KEEPER, guardian=GUARDIAN, fee_to=FEE_TO,
                          treasury=TREASURY, name="CLI smoke", symbol="cli")
    deposit(fork, vault_contract(fork, v), BOB, 500)
    cfg = {"name": "cli", "chain": {"rpc_url": fork.url, "vault": v, "keeper": KEEPER},
           "strategy": {"mode": "hedged", "max_clamp_dev_bps": 500},
           "state_path": os.path.join(tmp, "cli", "state.json"), "log_path": os.path.join(tmp, "cli", "log.jsonl")}
    path = os.path.join(tmp, "cli.json")
    json.dump(cfg, open(path, "w"))
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    r = subprocess.run([sys.executable, "-m", "elysium_keeper", "run", "--config", path, "--once"], cwd=root,
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stderr[-2000:]
    events = [json.loads(line) for line in open(cfg["log_path"])]
    tick = [e for e in events if e["event"] == "tick"][-1]
    print("\nCLI tick:", tick, "| price events:", [e for e in events if e["event"] in ("price_clamped", "alert")][:3])
    assert not tick["errors"] and tick["epoch"] >= 1, "deposit settled"
    st = json.load(open(cfg["state_path"]))
    assert st["last_tick"] > 0
