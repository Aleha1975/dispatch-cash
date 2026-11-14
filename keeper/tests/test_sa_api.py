"""Unit tests for the relayer HTTP endpoint (sa_api): schema, signatures, delegation shape, permit, replay, rate limits,
queue format and the HTTP layer. The chain is a fake (FakeChain); the anvil e2e is in test_sa_api_e2e_fork.py."""
from __future__ import annotations

import copy
import json
import os
import sys
import threading
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eth_account import Account  # noqa: E402
from eth_utils import keccak, to_checksum_address  # noqa: E402

from elysium_keeper.sa_api import (  # noqa: E402
    SECP256K1_N, Facts, Policy, Queue, RateLimiter, Reject, SAApi, StatusFile, make_server, parse_json, parse_request)
from elysium_keeper.sa_chain import (  # noqa: E402
    EIP7702_IMPL, Delegation, Relayer, delegation_hash, dm_domain, domain_separator, hybrid_address,
    module_delegation, permit_digest, typed_digest)

MODULE = to_checksum_address("0x" + "a1" * 20)
ENF = to_checksum_address("0x" + "b2" * 20)
TREAS = to_checksum_address("0x" + "c3" * 20)
FEE = to_checksum_address("0x" + "d4" * 20)
USDC = "0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65"
NOW = 1_800_000_000
E6 = 10 ** 6
PK = keccak(text="sa-api-unit-alice")
PK2 = keccak(text="sa-api-unit-mallory")
OWNER = Account.from_key(PK).address


class FakeChain:
    def __init__(self):
        self.facts = Facts(chain_id=99901, module=MODULE, enforcer=ENF, treasury=TREAS, fee_to=FEE, usdc=USDC,
                           usdc_domain=domain_separator("USD Coin", "2", 99901, USDC), min_lifetime=86400)
        self.t = NOW
        self.nonces: dict = {}
        self.balances: dict = {}
        self.codes: dict = {}
        self.registered: dict = {}
        self.disabled_hashes: set = set()

    def now(self):
        return self.t

    def usdc_nonce(self, o):
        return self.nonces.get(o, 0)

    def usdc_balance(self, o):
        return self.balances.get(o, 0)

    def code(self, a):
        return self.codes.get(a, b"")

    def account(self, a):
        r = self.registered.get(a)
        if r is None:
            return {"registered": False, "revoked": False, "active": False, "owner": "0x" + "00" * 20}
        return dict(r, registered=True)

    def disabled(self, h):
        return h in self.disabled_hashes


def sign_request(pk=PK, *, chain: FakeChain, amount=1000 * E6, kind="hybrid", until=None, deadline=None,
                 delegation_pk=None, permit_pk=None, nonce=None, mutate=None, dm_chain=99901, spender=MODULE,
                 salt=1) -> dict:
    owner = Account.from_key(pk).address
    acct = hybrid_address(owner) if kind == "hybrid" else owner
    d = module_delegation(acct, MODULE, ENF, TREAS, FEE, until or NOW + 180 * 86400, salt)
    if mutate:
        mutate(d)
    d.signature = bytes(Account.unsafe_sign_hash(typed_digest(dm_domain(dm_chain), delegation_hash(d)),
                                                 delegation_pk or pk).signature)
    body = {"owner": owner, "kind": kind, "delegation": dict(d.to_json(), salt=str(d.salt)), "permit": None}
    if kind == "hybrid":
        dl = deadline or NOW + 3600
        n = chain.usdc_nonce(owner) if nonce is None else nonce
        sig = Account.unsafe_sign_hash(permit_digest(chain.facts.usdc_domain, owner, spender, amount, n, dl),
                                       permit_pk or pk)
        body["permit"] = {"amount": str(amount), "deadline": str(dl), "v": sig.v,
                          "r": "0x" + sig.r.to_bytes(32, "big").hex(), "s": "0x" + sig.s.to_bytes(32, "big").hex(),
                          "token": USDC, "spender": spender}
    return body


def logs():
    out = []
    return out, (lambda ev, **kw: out.append((ev, kw)))


@pytest.fixture
def env(tmp_path):
    chain = FakeChain()
    chain.balances[OWNER] = 5000 * E6
    rec, log = logs()
    api = SAApi(chain, Queue(str(tmp_path / "q")), StatusFile(str(tmp_path / "status.json")), Policy(), log,
                ip_onboard=RateLimiter(100, 60), owner_onboard=RateLimiter(100, 3600), ip_status=RateLimiter(100, 60),
                wall=lambda: NOW)
    return api, chain, tmp_path, rec


def post(api, body, ip="1.2.3.4"):
    return api.onboard(json.dumps(body).encode(), ip)


def rej(api, body, status=400, code=None, ip="1.2.3.4"):
    with pytest.raises(Reject) as e:
        post(api, body, ip) if not isinstance(body, bytes) else api.onboard(body, ip)
    assert e.value.status == status, e.value
    if code:
        assert e.value.code == code, e.value
    return e.value


# ---------------------------------------------------------------- happy path and the queue format
def test_valid_request_is_queued_in_keeper_format(env):
    api, chain, tmp, rec = env
    body = sign_request(chain=chain)
    st, out = post(api, body)
    assert st == 202 and out["state"] == "queued" and out["account"] == hybrid_address(OWNER)
    path = tmp / "q" / f"{OWNER}.json"
    req = json.loads(path.read_text())
    assert oct(path.stat().st_mode & 0o777) == "0o640"
    assert [n for n in os.listdir(tmp / "q") if n.startswith(".tmp")] == []
    # the keeper's own parser and relayer check accept it
    d = Delegation.from_json(req["delegation"])
    assert d.delegator == hybrid_address(OWNER) and len(d.signature) == 65

    rel = Relayer.__new__(Relayer)
    rel.r = type("R", (), {"m": type("M", (), {"address": MODULE})})
    assert rel.check(req).delegate == MODULE
    assert int(req["permit"]["amount"]) == 1000 * E6 and req["permit"]["v"] in (27, 28)
    # logs: addresses and codes only
    assert rec == [("sa_api_queued", {"owner": OWNER, "account": hybrid_address(OWNER), "kind": "hybrid",
                                      "amount": 1000 * E6})]


def test_idempotent_resubmit_and_conflicting_request(env):
    api, chain, tmp, _ = env
    body = sign_request(chain=chain)
    assert post(api, body)[0] == 202
    st, out = post(api, copy.deepcopy(body))
    assert st == 200 and out["duplicate"]
    rej(api, sign_request(chain=chain, amount=999 * E6), 409, "already_queued")


def test_web_numbers_as_strings_or_ints(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    body["permit"]["amount"] = int(body["permit"]["amount"])
    body["permit"]["deadline"] = int(body["permit"]["deadline"])
    body["delegation"]["salt"] = 1
    assert post(api, body)[0] == 202


# ---------------------------------------------------------------- schema
@pytest.mark.parametrize("mut", [
    lambda b: b.update(extra=1),
    lambda b: b.pop("permit"),
    lambda b: b.update(kind="safe"),
    lambda b: b.update(owner="0x1234"),
    lambda b: b.update(owner=b["owner"][:2] + b["owner"][2:3].swapcase() + b["owner"][3:]
                       if b["owner"][2:3].isalpha() else "0x" + "aB" * 20),
    lambda b: b["delegation"].update(foo="0x"),
    lambda b: b["delegation"].pop("signature"),
    lambda b: b["delegation"].update(signature="0x" + "11" * 64),
    lambda b: b["delegation"].update(signature="0xabc"),
    lambda b: b["delegation"].update(salt=-1),
    lambda b: b["delegation"].update(salt="01"),
    lambda b: b["delegation"].update(salt=str(2 ** 256)),
    lambda b: b["delegation"].update(salt=True),
    lambda b: b["delegation"].update(caveats=b["delegation"]["caveats"] * 2),
    lambda b: b["delegation"].update(caveats=b["delegation"]["caveats"][:1]),
    lambda b: b["delegation"]["caveats"][0].pop("args"),
    lambda b: b["delegation"]["caveats"][1].update(terms="zz"),
    lambda b: b["permit"].update(amount=1.5),
    lambda b: b["permit"].update(amount="1e9"),
    lambda b: b["permit"].update(v=300),
    lambda b: b["permit"].update(r="0x" + "11" * 31),
    lambda b: b["permit"].pop("spender"),
    lambda b: b["permit"].update(nonce=0),
    lambda b: b.update(permit=None),
    lambda b: b.update(permit="yes"),
])
def test_schema_rejects(env, mut):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    mut(body)
    rej(api, body, 400)


@pytest.mark.parametrize("raw", [b"[]", b"not json", b"\xff\xfe", b'{"owner": NaN}', b'{"a":1,"a":2}', b"1e999",
                                 b'"x"', b"[" * 5000 + b"]" * 5000])
def test_raw_body_rejects(env, raw):
    api, _, _, _ = env
    rej(api, raw, 400, "schema")


def test_parse_request_7702_permit_rules():
    chain = FakeChain()
    b = sign_request(chain=chain, kind="eip7702")
    assert parse_request(parse_json(json.dumps(b).encode())).permit is None
    b["permit"] = {"amount": "1"}
    with pytest.raises(Reject) as e:
        parse_request(b)
    assert e.value.code == "permit_unexpected"


# ---------------------------------------------------------------- signatures
def test_delegation_signed_by_someone_else(env):
    api, chain, _, _ = env
    rej(api, sign_request(chain=chain, delegation_pk=PK2), 401, "delegation_signature")


def test_delegation_signed_for_another_chain(env):
    api, chain, _, _ = env
    rej(api, sign_request(chain=chain, dm_chain=1), 401, "delegation_signature")


def test_delegation_high_s_and_bad_v(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    sig = bytes.fromhex(body["delegation"]["signature"][2:])
    r, s, v = sig[:32], int.from_bytes(sig[32:64], "big"), sig[64]
    malleable = r + (SECP256K1_N - s).to_bytes(32, "big") + bytes([55 - v])  # same signer, high s
    body["delegation"]["signature"] = "0x" + malleable.hex()
    rej(api, body, 401, "delegation_signature")
    body["delegation"]["signature"] = "0x" + (sig[:64] + bytes([v - 27])).hex()  # v in {0, 1}
    rej(api, body, 401, "delegation_signature")


def test_permit_signed_by_someone_else(env):
    api, chain, _, _ = env
    rej(api, sign_request(chain=chain, permit_pk=PK2), 401, "permit_signature")


def test_permit_replay_after_nonce_used(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    chain.nonces[OWNER] = 1  # the permit was used (or front-run) on chain: the same signature no longer verifies
    rej(api, body, 401, "permit_signature")


def test_permit_tampered_amount(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    body["permit"]["amount"] = str(int(body["permit"]["amount"]) - 1)
    rej(api, body, 401, "permit_signature")


# ---------------------------------------------------------------- delegation shape
def _cav(i, enforcer=None, terms=None, args=None):
    def m(d: Delegation):
        e, t, a = d.caveats[i]
        d.caveats[i] = (enforcer or e, terms if terms is not None else t, args if args is not None else a)
    return m


@pytest.mark.parametrize("kw,code", [
    (dict(mutate=lambda d: setattr(d, "delegate", ENF)), "delegate"),
    (dict(mutate=lambda d: setattr(d, "delegator", TREAS)), "delegator"),
    (dict(mutate=lambda d: setattr(d, "authority", b"\x01" * 32)), "authority"),
    (dict(mutate=_cav(0, enforcer=FEE)), "delegation_caveats"),
    (dict(mutate=_cav(0, terms=b"\x00" * 96)), "delegation_caveats"),
    (dict(mutate=_cav(0, args=b"\x01")), "delegation_caveats"),
    (dict(mutate=_cav(1, enforcer=ENF)), "delegation_caveats"),
    (dict(mutate=_cav(1, terms=b"\x00" * 31)), "delegation_caveats"),
    (dict(mutate=_cav(1, terms=(5).to_bytes(16, "big") + (NOW + 99 * 86400).to_bytes(16, "big"))),
     "delegation_expiry"),
    (dict(until=NOW + 86400), "delegation_expiry"),  # module minimum, no margin for the queue
    (dict(until=NOW + 500 * 86400), "delegation_expiry"),
    (dict(mutate=lambda d: d.caveats.reverse()), "delegation_caveats"),
])
def test_delegation_shape_rejects(env, kw, code):
    api, chain, _, _ = env
    rej(api, sign_request(chain=chain, **kw), 400, code)


def test_owner_may_not_be_protocol_address(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    body["owner"] = TREAS
    rej(api, body, 400, "owner")


# ---------------------------------------------------------------- permit edge cases
@pytest.mark.parametrize("kw,code", [
    (dict(amount=0), "permit_amount"),
    (dict(amount=5000 * E6 + 1), "permit_amount"),  # more than the wallet holds
    (dict(deadline=NOW + 60), "permit_deadline"),
    (dict(deadline=NOW + 2 * 86400), "permit_deadline"),
    (dict(deadline=NOW - 1), "permit_deadline"),
    (dict(spender=TREAS), "permit_spender"),
])
def test_permit_rejects(env, kw, code):
    api, chain, _, _ = env
    rej(api, sign_request(chain=chain, **kw), 400, code)


def test_permit_token_must_be_module_usdc(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    body["permit"]["token"] = TREAS
    rej(api, body, 400, "permit_token")


def test_whole_balance_is_fine(env):
    api, chain, _, _ = env
    assert post(api, sign_request(chain=chain, amount=5000 * E6))[0] == 202


# ---------------------------------------------------------------- chain state
def test_already_registered(env):
    api, chain, _, _ = env
    chain.registered[hybrid_address(OWNER)] = {"revoked": False, "active": True, "owner": OWNER}
    rej(api, sign_request(chain=chain), 409, "already_registered")


def test_disabled_delegation(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain)
    chain.disabled_hashes.add(delegation_hash(Delegation.from_json(body["delegation"])))
    rej(api, body, 400, "delegation_disabled")


def test_7702_needs_designator(env):
    api, chain, _, _ = env
    body = sign_request(chain=chain, kind="eip7702")
    rej(api, body, 400, "account_code")
    chain.codes[OWNER] = b"\xef\x01\x00" + bytes.fromhex(EIP7702_IMPL[2:])
    st, out = post(api, body)
    assert st == 202 and out["account"] == OWNER and out["kind"] == "eip7702"


# ---------------------------------------------------------------- rate limits
def test_rate_limit_per_ip(env):
    api, chain, _, _ = env
    t = [0.0]
    api.rl_ip = RateLimiter(2, 60, clock=lambda: t[0])
    bad = {"nope": 1}
    rej(api, bad, 400)
    rej(api, bad, 400)
    rej(api, bad, 429, "rate_limited")
    rej(api, bad, 400, ip="5.6.7.8")  # other clients unaffected
    t[0] = 61
    rej(api, bad, 400)


def test_rate_limit_per_owner_counts_only_proven_owners(env):
    api, chain, _, _ = env
    api.rl_owner = RateLimiter(1, 3600)
    forged = sign_request(chain=chain, delegation_pk=PK2)  # someone else's signature: rejected before the owner limit
    for _ in range(3):
        rej(api, forged, 401)
    body = sign_request(chain=chain)
    assert post(api, body, ip="9.9.9.9")[0] == 202
    rej(api, body, 429, "rate_limited", ip="8.8.8.8")


def test_rate_limiter_bounded_memory():
    rl = RateLimiter(1, 60, max_keys=10)
    for i in range(100):
        assert rl.allow(str(i))
    assert len(rl.hits) == 10


# ---------------------------------------------------------------- status / health
def test_status_states(env):
    api, chain, tmp, _ = env
    st, out = api.get_status(f"owner={OWNER}", "1.1.1.1")
    assert out["state"] == "none" and out["account"] == hybrid_address(OWNER) and out["summary"] is None
    post(api, sign_request(chain=chain))
    assert api.get_status(f"owner={OWNER}", "1.1.1.1")[1]["state"] == "queued"
    # keeper failed it
    q = tmp / "q"
    os.makedirs(q / "failed")
    (q / "failed" / f"{OWNER}.json").write_text(json.dumps({"request": None, "result": {
        "error": "aggregate3 reverted: BadDelegation(6) via https://rpc.example/x"}}))
    os.remove(q / f"{OWNER}.json")
    out = api.get_status(f"owner={OWNER}", "1.1.1.1")[1]
    assert out["state"] == "failed" and "BadDelegation(6)" in out["error"] and "https" not in out["error"]
    # registered on chain, keeper has not reported it yet
    a = hybrid_address(OWNER)
    chain.registered[a] = {"revoked": False, "active": True, "owner": OWNER}
    assert api.get_status(f"owner={OWNER}", "1.1.1.1")[1]["state"] == "onchain"
    # keeper status file
    row = {"owner": OWNER, "kind": "hybrid", "active": True, "revoked": False, "until": NOW + 1, "value": 1000.0,
           "usdc": 10.0, "hype": 0.1, "contributed": 1000.0, "profit": 0.0, "hwm": 0.0, "fees_paid": 0.0,
           "hedge_equity": 250.0, "net_margin": 250.0, "positions": [], "stale": False,
           "ledger": {"short": 1.2, "equity": 250.0, "margin_in": 250.0, "margin_out": 0.0, "closed": False, "x": 1}}
    (tmp / "status.json").write_text(json.dumps({"written_at": NOW - 5, "last_tick": NOW, "paused": False,
                                                 "price": {"anchor": 40.1}, "accounts": {a: row}}))
    out = api.get_status(f"owner={OWNER.lower()}", "1.1.1.1")[1]
    assert out["state"] == "active" and out["summary"]["value"] == 1000.0
    assert out["summary"]["hedge"] == {"short": 1.2, "equity": 250.0, "margin_in": 250.0, "margin_out": 0.0,
                                       "closed": False}
    assert out["keeper"] == {"last_tick": NOW, "age_s": 5, "fresh": True, "paused": False, "price": 40.1}
    row["active"] = False
    (tmp / "status.json").write_text(json.dumps({"written_at": NOW, "accounts": {a: row}}))
    assert api.get_status(f"owner={OWNER}", "1.1.1.1")[1]["state"] == "revoked"


@pytest.mark.parametrize("q", ["", "owner=0x12", f"owner={OWNER}&owner={OWNER}", f"owner={OWNER}&x=1", "x=1"])
def test_status_query_rejects(env, q):
    api, _, _, _ = env
    with pytest.raises(Reject) as e:
        api.get_status(q, "1.1.1.1")
    assert e.value.status == 400


# ---------------------------------------------------------------- HTTP layer
@pytest.fixture
def http(env):
    api = env[0]
    srv = make_server(api, "127.0.0.1", 0)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", env
    srv.shutdown()
    srv.server_close()


def call(url, method="GET", body=None, ct="application/json", headers=None):
    req = urllib.request.Request(url, data=body, method=method, headers=dict({"Content-Type": ct}, **(headers or {})))
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r), r.headers
    except urllib.error.HTTPError as e:
        return e.code, json.load(e), e.headers


def test_http_endpoints(http):
    base, (api, chain, tmp, rec) = http
    p = base + "/elysium-api/sa"
    st, out, h = call(p + "/health")
    assert st == 200 and out["ok"] is False or st == 503  # queue dir not created yet
    os.makedirs(tmp / "q")
    st, out, h = call(p + "/health")
    assert st == 200 and out["ok"] and out["pending"] == 0 and h["Cache-Control"] == "no-store"
    body = json.dumps(sign_request(chain=chain)).encode()
    assert call(p + "/onboard", "POST", body, ct="text/plain")[0] == 415
    assert call(p + "/onboard", "POST", b"x" * 20000)[0] == 413
    assert call(p + "/onboard?token=1", "POST", body)[0] == 400
    assert call(p + "/onboard")[0] == 405
    assert call(p + "/nope")[0] == 404
    assert call(base + "/status")[0] == 404
    assert call(p + "/onboard", "PUT", body)[0] == 405
    st, out, _ = call(p + "/onboard", "POST", body)
    assert st == 202 and out["state"] == "queued", out
    st, out, _ = call(p + f"/status?owner={OWNER}")
    assert st == 200 and out["state"] == "queued"
    assert call(p + "/health")[1]["pending"] == 1
    st, out, _ = call(p + "/onboard", "POST", b'{"owner": 1}')
    assert st == 400 and out == {"ok": False, "error": "schema", "detail": out["detail"]}
    # nothing about the client IP in the logs
    assert "127.0.0.1" not in json.dumps(rec)


def test_http_client_ip_from_proxy_header(http):
    base, (api, chain, _, _) = http
    api.rl_ip = RateLimiter(1, 60)
    p = base + "/elysium-api/sa/onboard"
    assert call(p, "POST", b"{}", headers={"X-Real-IP": "10.0.0.1"})[0] == 400
    assert call(p, "POST", b"{}", headers={"X-Real-IP": "10.0.0.1"})[0] == 429
    assert call(p, "POST", b"{}", headers={"X-Real-IP": "10.0.0.2"})[0] == 400


def test_http_internal_error_is_opaque(http):
    base, (api, chain, _, rec) = http

    def boom():
        raise ConnectionError("rpc https://secret.example down")
    chain.now = boom
    st, out, _ = call(base + "/elysium-api/sa/onboard", "POST", json.dumps(sign_request(chain=FakeChain())).encode())
    assert st == 503 and "secret" not in json.dumps(out) and "secret" not in json.dumps(rec)


def test_server_binds_localhost_only(env):
    with pytest.raises(ValueError):
        make_server(env[0], "0.0.0.0", 0)
