"""Relayer API end to end on a local anvil fork of Elysium (chain 99901; the fork reads https://rpc.elysium.kinetiq.xyz
with a User-Agent, nothing is sent to it). Throwaway client keys; anvil --auto-impersonate for the keeper.

  ELYSIUM_FORK=1 python3 -m pytest -s tests/test_sa_api_e2e_fork.py

web-shaped request (the exact body account.js posts: strings for uint256, checksummed addresses, MetaMask-style
65-byte delegation signature, permit v/r/s + token/spender) -> sa-api over HTTP (verified against the fork) -> queue
file -> keeper: client 1 through the sa-run tick's queue, client 2 through `sa-onboard --request <queued file>` ->
accounts live on the fork -> /status reports them; replays and bad permits are refused before anything is queued.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from eth_account import Account  # noqa: E402
from eth_utils import keccak  # noqa: E402

from elysium_keeper import config as C  # noqa: E402
from elysium_keeper.__main__ import main as cli  # noqa: E402
from elysium_keeper.hl import DryRunAdapter  # noqa: E402
from elysium_keeper.infra import Log  # noqa: E402
from elysium_keeper.rpc import ERC20_ABI, Contract  # noqa: E402
from elysium_keeper.sa_api import SAApi, make_server  # noqa: E402
from elysium_keeper.sa_chain import (  # noqa: E402
    delegation_hash, dm_domain, hybrid_address, module_delegation, permit_digest, typed_digest)
from elysium_keeper.sa_keeper import SAKeeper  # noqa: E402
from forkutil import USDC, Fork, MockHL, Trader  # noqa: E402
from test_sa_e2e_fork import FEE_TO, GUARDIAN, KEEPER, OWNER, PERMIT_ABI, TREASURY, deploy_sa  # noqa: E402

pytestmark = pytest.mark.skipif(not os.environ.get("ELYSIUM_FORK"), reason="set ELYSIUM_FORK=1 (needs anvil+forge)")
E6 = 10 ** 6


@pytest.fixture(scope="module")
def env():
    tmp = tempfile.mkdtemp(prefix="sa-api-e2e-")
    fork = Fork(os.environ.get("ELYSIUM_RPC", "https://rpc.elysium.kinetiq.xyz"),
                int(os.environ["ELYSIUM_FORK_BLOCK"]) if os.environ.get("ELYSIUM_FORK_BLOCK") else None,
                os.path.join(tmp, "anvil.log"))
    for a in (KEEPER, TREASURY, OWNER, GUARDIAN):
        fork.set_balance(a, 10 ** 21)
    yield fork, tmp
    fork.close()


def web_body(fork, module, enforcer, pk: bytes, usd: int) -> dict:
    """What web/account.js start() posts (signTyped -> 0x-hex 65-byte signature; signPermit -> strings + v/r/s)."""
    owner = Account.from_key(pk).address
    a = hybrid_address(owner)
    d = module_delegation(a, module, enforcer, TREASURY, FEE_TO, fork.now() + 180 * 86400, 1)
    sig = Account.unsafe_sign_hash(typed_digest(dm_domain(99901), delegation_hash(d)), pk).signature
    usdc = Contract(fork.rpc, USDC, PERMIT_ABI)
    deadline = fork.now() + 3600
    ps = Account.unsafe_sign_hash(permit_digest(usdc.call("DOMAIN_SEPARATOR"), owner, module, usd * E6,
                                                usdc.call("nonces", owner), deadline), pk)
    return {
        "owner": owner, "kind": "hybrid",
        "delegation": {"delegate": d.delegate, "delegator": d.delegator, "authority": "0x" + "f" * 64,
                       "caveats": [{"enforcer": e, "terms": "0x" + t.hex(), "args": "0x"} for e, t, _ in d.caveats],
                       "salt": "1", "signature": "0x" + bytes(sig).hex()},
        "permit": {"amount": str(usd * E6), "deadline": str(deadline), "v": ps.v,
                   "r": "0x" + ps.r.to_bytes(32, "big").hex(), "s": "0x" + ps.s.to_bytes(32, "big").hex(),
                   "token": USDC, "spender": module},
    }


def call(url, body=None):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 method="GET" if body is None else "POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def test_api_queue_keeper_e2e(env):
    fork, tmp = env
    module = deploy_sa(fork)
    usdc = Contract(fork.rpc, USDC, ERC20_ABI)
    fork.send(TREASURY, usdc, "approve", module, 2 ** 256 - 1)
    m = Contract(fork.rpc, module, json.load(open(os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "abi", "LPManagerModule.json"))))
    hl = MockHL(fork.now(), Trader(fork, m).price() / 1e6)
    cfg_d = {
        "name": "sa-api-e2e",
        "chain": {"rpc_url": fork.url, "keeper": KEEPER, "signer": "unlocked"},
        "hl": {"adapter": "dry_run", "equity_source": "mock"},
        "sa": {"module": module, "discover_from_block": int(fork.rpc.call("eth_blockNumber"), 16) - 50,
               "stagger_s": 0, "ledger_path": os.path.join(tmp, "ledger.json"),
               "requests_dir": os.path.join(tmp, "requests"), "status_path": os.path.join(tmp, "status", "sa.json")},
        "state_path": os.path.join(tmp, "sa.state.json"),
        "log_path": os.path.join(tmp, "sa.log"),
    }
    cfg_path = os.path.join(tmp, "cfg.json")
    with open(cfg_path, "w") as fh:
        json.dump(cfg_d, fh)
    cfg = C.from_dict(cfg_d)
    log = Log(cfg.log_path, cfg.name, echo=False)
    k = SAKeeper(cfg, hl_info=hl, adapter=DryRunAdapter(cfg.hl, {}, log, mark_fn=hl.mid), log=log,
                 alert_sink=lambda *a: None)
    assert not k.tick()["errors"]  # anchor
    os.makedirs(cfg.sa.requests_dir)

    api_log = Log(os.path.join(tmp, "api.log"), "api", echo=False)
    api = SAApi.from_config(cfg, api_log)  # real RPC chain view against the fork
    srv = make_server(api, "127.0.0.1", 0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}/elysium-api/sa"
    try:
        st, h = call(base + "/health")
        assert st == 200 and h["ok"] and h["module"] == module

        pk1, pk2 = keccak(text="sa-api-e2e-carol"), keccak(text="sa-api-e2e-dave")
        o1, o2 = Account.from_key(pk1).address, Account.from_key(pk2).address
        fork.deal_usdc(o1, 2000 * E6)
        fork.deal_usdc(o2, 800 * E6)
        b1 = web_body(fork, module, k.r.enforcer, pk1, 2000)
        too_much = web_body(fork, module, k.r.enforcer, pk2, 801)
        st, out = call(base + "/onboard", too_much)
        assert st == 400 and out["error"] == "permit_amount", out
        b2 = web_body(fork, module, k.r.enforcer, pk2, 800)

        st, out = call(base + "/onboard", b1)
        assert st == 202 and out["account"] == hybrid_address(o1), out
        st, out = call(base + "/onboard", b2)
        assert st == 202, out
        assert sorted(n for n in os.listdir(cfg.sa.requests_dir) if n.endswith(".json")) == sorted(
            [f"{o1}.json", f"{o2}.json"])
        assert call(base + f"/status?owner={o1}")[1]["state"] == "queued"

        # client 2 through the CLI relayer (`sa-onboard --request`), the queued file as is
        q2 = os.path.join(cfg.sa.requests_dir, f"{o2}.json")
        cli(["sa-onboard", "--config", cfg_path, "--request", q2])
        os.remove(q2)
        assert m.call("isActive", hybrid_address(o2))
        # client 1 through the keeper's queue (sa-run tick), which then manages both accounts
        st = k.tick()
        assert not st["errors"], st["errors"]
        assert os.listdir(os.path.join(cfg.sa.requests_dir, "done")) == [f"{o1}.json"]
        for o, usd in ((o1, 2000), (o2, 800)):
            a = hybrid_address(o)
            assert m.call("isActive", a)
            assert int(fork.rpc.call("eth_getTransactionCount", [o, "latest"]), 16) == 0, "client sent nothing"
            assert usdc.call("balanceOf", o) == 0
            st, out = call(base + f"/status?owner={o}")
            assert st == 200 and out["state"] == "active" and out["account"] == a, out
            assert abs(out["summary"]["value"] - usd) < usd * 0.01, out
            assert out["summary"]["hedge"]["margin_in"] == pytest.approx(usd * 0.25, rel=0.02)
            assert out["keeper"]["fresh"]

        # replays: the same bodies again are refused (registered; the permit nonce is used)
        for b in (b1, b2):
            st, out = call(base + "/onboard", b)
            assert st == 409 and out["error"] == "already_registered", out
        assert not [n for n in os.listdir(cfg.sa.requests_dir) if n.endswith(".json")]
        # client exits -> revoked
        fork.rpc.call("anvil_setBalance", [o2, hex(10 ** 18)])
        fork.send(o2, m, "revoke", hybrid_address(o2))
        assert not k.tick()["errors"]
        assert call(base + f"/status?owner={o2}")[1]["state"] == "revoked"
        log_text = open(os.path.join(tmp, "api.log")).read()
        assert "127.0.0.1" not in log_text and "sa_api_queued" in log_text
    finally:
        srv.shutdown()
        srv.server_close()
