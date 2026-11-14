"""Relayer HTTP endpoint for smart-account onboarding (`python -m elysium_keeper sa-api --config cfg.json`).

It only VALIDATES and ENQUEUES. It holds no key and never signs or sends a transaction: the keeper (`sa-run`, its
relayer queue in `sa.requests_dir`) deploys the account and calls `module.onboard` after its own checks and an
eth_call simulation.

  POST /elysium-api/sa/onboard   {owner, kind, delegation, permit}  -> 202 {ok, state: "queued", owner, account, kind}
  GET  /elysium-api/sa/status?owner=0x..                         -> {owner, account, kind, state, summary, keeper}
  GET  /elysium-api/sa/health                                    -> {ok, pending, keeper}

Onboarding checks (everything the module's `checkDelegation` / `onboard` would check, before anything is queued):
  - strict JSON schema (exact keys, types, hex shapes), body <= sa.api_max_body;
  - delegation == module_delegation(account, module, enforcer, treasury, feeRecipient, until, salt) field by field:
    delegate = module, authority = ROOT, exactly [custody caveat with our terms, TimestampEnforcer(0 ‖ until)], empty
    caveat args, 65-byte signature; until within [now + MIN_DELEGATION_LIFETIME + margin, now + max days], <= uint64;
  - the account: hybrid = CREATE2 HybridDeleGator of the owner (owner not the treasury / fee recipient); 7702 = the
    owner EOA whose code is the designator of the canonical EIP7702StatelessDeleGator;
  - both EIP-712 signatures recover to the owner (low s, v in {27, 28}); the delegation is not disabled at the DM;
  - permit (hybrid only, 7702 has none): token = module.asset(), spender = module, 0 < value <= the owner's USDC
    balance, deadline within [now + min window, now + max window], signed over the owner's CURRENT permit nonce
    (a used permit no longer verifies: replay protection);
  - the account is not registered yet; one pending request per owner (an identical resubmission is idempotent);
  - rate limits per client IP (before any work) and per owner (after the delegation signature proved the owner).
Logs carry addresses and outcome codes only (no IPs, no bodies).
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import secrets
import threading
import time
import urllib.parse
from collections import OrderedDict, deque
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_utils import keccak, to_checksum_address

from .sa_chain import (ACCOUNT_SALT, DM, EIP7702_IMPL, HYBRID_IMPL, MODULE_ABI_PATH, ROOT_AUTHORITY, SIMPLE_FACTORY,
                       TIMESTAMP_ENFORCER, Delegation, delegation_hash, dm_domain, hybrid_address, module_delegation,
                       permit_digest, typed_digest)

PREFIX = "/elysium-api/sa"
SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
U64_MAX = 2 ** 64 - 1
U256_MAX = 2 ** 256 - 1
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
HEX_RE = re.compile(r"^0x(?:[0-9a-fA-F]{2})*$")
UINT_RE = re.compile(r"^(?:0|[1-9][0-9]{0,77})$")
OWNER_FILE_RE = re.compile(r"^0x[0-9a-fA-F]{40}\.json$")

PERMIT_ABI = [
    {"type": "function", "name": "DOMAIN_SEPARATOR", "stateMutability": "view", "inputs": [],
     "outputs": [{"name": "", "type": "bytes32"}]},
    {"type": "function", "name": "nonces", "stateMutability": "view", "inputs": [{"name": "o", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"type": "function", "name": "balanceOf", "stateMutability": "view", "inputs": [{"name": "o", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
]
DM_VIEW_ABI = [{"type": "function", "name": "disabledDelegations", "stateMutability": "view",
                "inputs": [{"name": "h", "type": "bytes32"}], "outputs": [{"name": "", "type": "bool"}]}]


class Reject(Exception):
    def __init__(self, status: int, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}")
        self.status, self.code, self.detail = status, code, detail


def _bad(code: str, detail: str = "") -> Reject:
    return Reject(400, code, detail)


# ------------------------------------------------------------------------------------------------ strict JSON
def _no_dupes(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise _bad("schema", f"duplicate key {k!r}")
        d[k] = v
    return d


def _no_constants(x):
    raise _bad("schema", f"non-finite number {x}")


def parse_json(body: bytes) -> dict:
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        raise _bad("schema", "body is not UTF-8")
    try:
        obj = json.loads(text, object_pairs_hook=_no_dupes, parse_constant=_no_constants,
                         parse_float=lambda s: _no_constants(s))
    except Reject:
        raise
    except (ValueError, RecursionError):
        raise _bad("schema", "body is not valid JSON")
    if not isinstance(obj, dict):
        raise _bad("schema", "body must be a JSON object")
    return obj


def _keys(d, field: str, required: set, optional: set = frozenset()):
    if not isinstance(d, dict):
        raise _bad("schema", f"{field} must be an object")
    missing, extra = required - set(d), set(d) - required - set(optional)
    if missing:
        raise _bad("schema", f"{field}: missing {sorted(missing)}")
    if extra:
        raise _bad("schema", f"{field}: unknown {sorted(extra)}")


def _addr(v, field: str) -> str:
    if not isinstance(v, str) or not ADDR_RE.match(v):
        raise _bad("schema", f"{field} must be a 0x address")
    c = to_checksum_address(v)
    h = v[2:]
    if h != h.lower() and h != h.upper() and v != c:  # mixed case = EIP-55 checksum, must be right
        raise _bad("schema", f"{field}: bad address checksum")
    return c


def _hex(v, field: str, n: int | None = None, max_len: int = 4096) -> bytes:
    if not isinstance(v, str) or len(v) > 2 + 2 * max_len or not HEX_RE.match(v):
        raise _bad("schema", f"{field} must be 0x hex bytes")
    b = bytes.fromhex(v[2:])
    if n is not None and len(b) != n:
        raise _bad("schema", f"{field} must be {n} bytes")
    return b


def _uint(v, field: str, bits: int = 256) -> int:
    if isinstance(v, bool):
        raise _bad("schema", f"{field} must be an unsigned integer")
    if isinstance(v, int):
        x = v
    elif isinstance(v, str) and UINT_RE.match(v):
        x = int(v)
    else:
        raise _bad("schema", f"{field} must be an unsigned integer (number or decimal string)")
    if x < 0 or x >= 2 ** bits:
        raise _bad("schema", f"{field} out of range")
    return x


@dataclass
class OnboardRequest:
    owner: str
    kind: str  # hybrid | eip7702
    delegation: Delegation
    permit: dict | None  # {amount, deadline, v, r, s, token, spender} (ints / bytes / addresses)

    def keeper_json(self) -> dict:
        """The exact request format Relayer.onboard (sa_chain) consumes."""
        p = None
        if self.permit is not None:
            p = {"amount": str(self.permit["amount"]), "deadline": str(self.permit["deadline"]), "v": self.permit["v"],
                 "r": "0x" + self.permit["r"].hex(), "s": "0x" + self.permit["s"].hex(),
                 "token": self.permit["token"], "spender": self.permit["spender"]}
        return {"owner": self.owner, "kind": self.kind, "delegation": self.delegation.to_json(), "permit": p}


def parse_request(obj: dict) -> OnboardRequest:
    _keys(obj, "request", {"owner", "kind", "delegation", "permit"})
    owner = _addr(obj["owner"], "owner")
    kind = obj["kind"]
    if kind not in ("hybrid", "eip7702"):
        raise _bad("schema", "kind must be hybrid or eip7702")
    d = obj["delegation"]
    _keys(d, "delegation", {"delegate", "delegator", "authority", "caveats", "salt", "signature"})
    cavs = d["caveats"]
    if not isinstance(cavs, list) or len(cavs) != 2:
        raise _bad("delegation_caveats", "exactly two caveats")
    caveats = []
    for i, c in enumerate(cavs):
        _keys(c, f"caveats[{i}]", {"enforcer", "terms", "args"})
        caveats.append((_addr(c["enforcer"], f"caveats[{i}].enforcer"), _hex(c["terms"], f"caveats[{i}].terms"),
                        _hex(c["args"], f"caveats[{i}].args")))
    dg = Delegation(_addr(d["delegate"], "delegate"), _addr(d["delegator"], "delegator"), caveats,
                    _uint(d["salt"], "salt"), _hex(d["authority"], "authority", 32),
                    _hex(d["signature"], "delegation.signature", 65))
    p = obj["permit"]
    permit = None
    if kind == "hybrid":
        if p is None:
            raise _bad("permit_missing", "a hybrid account needs the USDC permit")
        _keys(p, "permit", {"amount", "deadline", "v", "r", "s", "token", "spender"})
        permit = {"amount": _uint(p["amount"], "permit.amount"), "deadline": _uint(p["deadline"], "permit.deadline"),
                  "v": _uint(p["v"], "permit.v", 8), "r": _hex(p["r"], "permit.r", 32),
                  "s": _hex(p["s"], "permit.s", 32), "token": _addr(p["token"], "permit.token"),
                  "spender": _addr(p["spender"], "permit.spender")}
    elif p is not None:
        raise _bad("permit_unexpected", "a 7702 account holds its funds already: permit must be null")
    return OnboardRequest(owner, kind, dg, permit)


def recover(digest: bytes, v: int, r: bytes, s: bytes) -> str | None:
    """ECDSA as OpenZeppelin's ECDSA.recover accepts it: v in {27, 28}, 0 < r, 0 < s <= n/2."""
    ri, si = int.from_bytes(r, "big"), int.from_bytes(s, "big")
    if v not in (27, 28) or not 0 < ri < SECP256K1_N or not 0 < si <= SECP256K1_N // 2:
        return None
    try:
        return to_checksum_address(Account._recover_hash(digest, vrs=(v, ri, si)))
    except Exception:
        return None


# ------------------------------------------------------------------------------------------------ chain view
@dataclass
class Facts:
    """Immutable deployment facts, read from the module once at start and cross-checked with sa_chain constants."""
    chain_id: int
    module: str
    enforcer: str
    treasury: str
    fee_to: str
    usdc: str
    usdc_domain: bytes
    min_lifetime: int
    dm: str = DM
    timestamp_enforcer: str = TIMESTAMP_ENFORCER

    @property
    def terms(self) -> bytes:
        return abi_encode(["address", "address", "address"], [self.module, self.treasury, self.fee_to])


class RPCChainView:
    """Read-only chain access for the API (eth_call / getCode only; there is no signer)."""

    def __init__(self, rpc, module: str, chain_id: int):
        from .rpc import Contract

        with open(MODULE_ABI_PATH) as fh:
            self.m = Contract(rpc, module, json.load(fh))
        self.rpc = rpc
        cid = rpc.chain_id()
        if cid != chain_id:
            raise ValueError(f"chain id {cid} != configured {chain_id}")
        c = self.m.call
        checks = {"delegationManager": DM, "timestampEnforcer": TIMESTAMP_ENFORCER, "factory": SIMPLE_FACTORY,
                  "hybridImpl": HYBRID_IMPL, "eip7702Impl": EIP7702_IMPL}
        for fn, want in checks.items():
            if to_checksum_address(c(fn)) != want:
                raise ValueError(f"module.{fn} != {want}")
        if c("accountSalt") != ACCOUNT_SALT:
            raise ValueError("module.accountSalt differs from sa_chain.ACCOUNT_SALT")
        usdc = to_checksum_address(c("asset"))
        self.usdc = Contract(rpc, usdc, PERMIT_ABI)
        self.dm = Contract(rpc, DM, DM_VIEW_ABI)
        self.facts = Facts(chain_id=cid, module=self.m.address, enforcer=to_checksum_address(c("enforcer")),
                           treasury=to_checksum_address(c("hedgeTreasury")),
                           fee_to=to_checksum_address(c("feeRecipient")), usdc=usdc,
                           usdc_domain=self.usdc.call("DOMAIN_SEPARATOR"), min_lifetime=c("MIN_DELEGATION_LIFETIME"))
        if c("enforcerTermsHash") != keccak(self.facts.terms):
            raise ValueError("module.enforcerTermsHash != keccak(abi.encode(module, treasury, feeRecipient))")

    def now(self) -> int:
        return self.rpc.block_timestamp()

    def usdc_nonce(self, owner: str) -> int:
        return self.usdc.call("nonces", owner)

    def usdc_balance(self, owner: str) -> int:
        return self.usdc.call("balanceOf", owner)

    def code(self, a: str) -> bytes:
        r = self.rpc.call("eth_getCode", [a, "latest"])
        return bytes.fromhex(r[2:]) if r and r != "0x" else b""

    def account(self, a: str) -> dict:
        """(registered, revoked, active) of `a` at the module."""
        acc = self.m.call("account", a)
        reg = acc[0] != b"\0" * 32
        return {"registered": reg, "revoked": bool(acc[4]) if reg else False,
                "active": bool(self.m.call("isActive", a)) if reg else False, "owner": to_checksum_address(acc[1])}

    def disabled(self, h: bytes) -> bool:
        return bool(self.dm.call("disabledDelegations", h))


@dataclass
class Policy:
    permit_min_window_s: int = 600
    permit_max_window_s: int = 86400
    delegation_margin_s: int = 3600
    delegation_max_days: int = 400

    @classmethod
    def from_cfg(cls, sa) -> "Policy":
        return cls(sa.api_permit_min_window_s, sa.api_permit_max_window_s, sa.api_delegation_margin_s,
                   sa.api_delegation_max_days)


def account_of(req: OnboardRequest) -> str:
    return hybrid_address(req.owner) if req.kind == "hybrid" else req.owner


def verify_offchain(req: OnboardRequest, f: Facts, now: int, pol: Policy) -> str:
    """Shape, account identity and the delegation signature. Needs only the facts and the chain time. Returns the
    account address; after it returns, the owner is proven (it signed this delegation)."""
    d = req.delegation
    if f.chain_id != 99901:
        raise Reject(503, "chain", "API is not on Elysium (99901)")
    if req.owner in (f.treasury, f.fee_to, f.module):
        raise _bad("owner", "owner may not be a protocol address")
    account = account_of(req)
    if d.delegator != account:
        raise _bad("delegator", "delegator must be the owner's HybridDeleGator (CREATE2)" if req.kind == "hybrid"
                   else "a 7702 delegator must be the owner EOA itself")
    if d.delegate != f.module:
        raise _bad("delegate", "delegate must be the module")
    if d.authority != ROOT_AUTHORITY:
        raise _bad("authority", "authority must be ROOT")
    (e0, t0, a0), (e1, t1, a1) = d.caveats
    if a0 or a1:
        raise _bad("delegation_caveats", "caveat args must be empty")
    if e0 != f.enforcer or t0 != f.terms:
        raise _bad("delegation_caveats", "first caveat must be the custody enforcer with the module's terms")
    if e1 != f.timestamp_enforcer or len(t1) != 32:
        raise _bad("delegation_caveats", "second caveat must be the TimestampEnforcer (32-byte terms)")
    after, until = int.from_bytes(t1[:16], "big"), int.from_bytes(t1[16:], "big")
    if after != 0:
        raise _bad("delegation_expiry", "'after' must be 0")
    lo, hi = now + f.min_lifetime + pol.delegation_margin_s, min(U64_MAX, now + pol.delegation_max_days * 86400)
    if not lo <= until <= hi:
        raise _bad("delegation_expiry", f"expiry must be within [{lo}, {hi}]")
    want = module_delegation(account, f.module, f.enforcer, f.treasury, f.fee_to, until, d.salt)
    if want.as_tuple()[:5] != d.as_tuple()[:5]:  # belt and braces: field by field equal to the module's shape
        raise _bad("delegation_shape", "delegation differs from the module's shape")
    sig = d.signature
    signer = recover(typed_digest(dm_domain(f.chain_id), delegation_hash(d)), sig[64], sig[:32], sig[32:64])
    if signer != req.owner:
        raise Reject(401, "delegation_signature", "the delegation is not signed by the owner")
    if req.permit is not None:
        p = req.permit
        if p["token"] != f.usdc:
            raise _bad("permit_token", "permit token must be the module's USDC")
        if p["spender"] != f.module:
            raise _bad("permit_spender", "permit spender must be the module")
        if p["amount"] <= 0:
            raise _bad("permit_amount", "amount must be > 0")
        if not now + pol.permit_min_window_s <= p["deadline"] <= now + pol.permit_max_window_s:
            raise _bad("permit_deadline", f"deadline must be within [now + {pol.permit_min_window_s} s, "
                                          f"now + {pol.permit_max_window_s} s]")
    return account


def verify_onchain(req: OnboardRequest, account: str, chain, f: Facts):
    """State the module checks at registration: account kind, not registered, not disabled; permit nonce/balance."""
    # hybrid: the CREATE2 address can only hold our proxy; deployed-but-unregistered is fine (the relayer skips the
    # deploy). 7702: the EOA must carry the canonical designator (SALib.accountKind).
    if req.kind == "eip7702" and chain.code(req.owner) != b"\xef\x01\x00" + bytes.fromhex(EIP7702_IMPL[2:]):
        raise _bad("account_code", "the wallet is not a MetaMask EIP-7702 smart account")
    st = chain.account(account)
    if st["registered"]:
        raise Reject(409, "already_registered", "this account is already registered with the module")
    if chain.disabled(delegation_hash(req.delegation)):
        raise _bad("delegation_disabled", "this delegation is disabled at the DelegationManager")
    if req.permit is not None:
        p = req.permit
        bal = chain.usdc_balance(req.owner)
        if p["amount"] > bal:
            raise _bad("permit_amount", "amount exceeds the wallet's USDC balance")
        nonce = chain.usdc_nonce(req.owner)
        digest = permit_digest(f.usdc_domain, req.owner, f.module, p["amount"], nonce, p["deadline"])
        if recover(digest, p["v"], p["r"], p["s"]) != req.owner:
            raise Reject(401, "permit_signature", "the permit is not signed by the owner for the current nonce")


# ------------------------------------------------------------------------------------------------ rate limit
class RateLimiter:
    """Sliding-window counter per key; bounded memory (oldest keys evicted)."""

    def __init__(self, limit: int, window_s: float, max_keys: int = 50_000, clock=time.monotonic):
        self.limit, self.window, self.max_keys, self.clock = limit, window_s, max_keys, clock
        self.hits: OrderedDict[str, deque] = OrderedDict()
        self.lock = threading.Lock()

    def allow(self, key: str) -> bool:
        if self.limit <= 0:
            return True
        now = self.clock()
        with self.lock:
            q = self.hits.get(key)
            if q is None:
                q = self.hits[key] = deque()
                while len(self.hits) > self.max_keys:
                    self.hits.popitem(last=False)
            else:
                self.hits.move_to_end(key)
            while q and q[0] <= now - self.window:
                q.popleft()
            if len(q) >= self.limit:
                return False
            q.append(now)
            return True


# ------------------------------------------------------------------------------------------------ queue
class Queue:
    """The keeper's relayer directory: pending `<owner>.json`; the keeper moves each to done/ or failed/."""

    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()

    def _p(self, *parts) -> str:
        return os.path.join(self.path, *parts)

    @staticmethod
    def _read(path: str):
        try:
            with open(path) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    def pending(self, owner: str):
        return self._read(self._p(f"{owner}.json"))

    def outcome(self, owner: str):
        """('done' | 'failed', mtime, record) of the latest processed request, or None."""
        best = None
        for out in ("done", "failed"):
            p = self._p(out, f"{owner}.json")
            try:
                mt = os.stat(p).st_mtime
            except OSError:
                continue
            if best is None or mt > best[1]:
                best = (out, mt, self._read(p))
        return best

    def count(self) -> int:
        try:
            return sum(1 for n in os.listdir(self.path) if OWNER_FILE_RE.match(n))
        except OSError:
            return -1

    def writable(self) -> bool:
        return os.path.isdir(self.path) and os.access(self.path, os.W_OK | os.X_OK)

    def enqueue(self, owner: str, payload: dict) -> bool:
        """Atomically create `<owner>.json` (never overwrites). Returns False if one is already pending."""
        os.makedirs(self.path, exist_ok=True)
        final = self._p(f"{owner}.json")
        tmp = self._p(f".tmp-{owner}-{secrets.token_hex(6)}")
        data = json.dumps(payload, sort_keys=True).encode()
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
                fh.flush()
                os.fsync(fh.fileno())
            with self.lock:
                try:
                    os.link(tmp, final)  # atomic, fails if a request for this owner is already pending
                except FileExistsError:
                    return False
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        try:
            dfd = os.open(self.path, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
        return True


# ------------------------------------------------------------------------------------------------ status file
class StatusFile:
    """The keeper's per-tick summary (SAKeeper.write_status_file); cached by mtime."""

    def __init__(self, path: str):
        self.path = path
        self._cache = (None, {})
        self.lock = threading.Lock()

    def load(self) -> dict:
        if not self.path:
            return {}
        try:
            mt = os.stat(self.path).st_mtime_ns
        except OSError:
            return {}
        with self.lock:
            if self._cache[0] == mt:
                return self._cache[1]
            try:
                with open(self.path) as fh:
                    d = json.load(fh)
            except (OSError, ValueError):
                return self._cache[1]
            self._cache = (mt, d if isinstance(d, dict) else {})
            return self._cache[1]


SUMMARY_KEYS = ("value", "usdc", "hype", "contributed", "profit", "hwm", "fees_paid", "hedge_equity", "net_margin",
                "until", "positions", "stale")
LEDGER_KEYS = ("short", "equity", "margin_in", "margin_out", "closed")
URL_RE = re.compile(r"https?://\S+")


def _public_error(e) -> str:
    return URL_RE.sub("<url>", str(e or ""))[:240]


# ------------------------------------------------------------------------------------------------ the API
class SAApi:
    def __init__(self, chain, queue: Queue, status: StatusFile, pol: Policy, log, *, ip_onboard: RateLimiter,
                 owner_onboard: RateLimiter, ip_status: RateLimiter, stale_s: int = 600, max_body: int = 16384,
                 wall=time.time):
        self.chain, self.q, self.status, self.pol, self.log = chain, queue, status, pol, log
        self.f: Facts = chain.facts
        self.rl_ip, self.rl_owner, self.rl_status = ip_onboard, owner_onboard, ip_status
        self.stale_s, self.max_body, self.wall = stale_s, max_body, wall

    @classmethod
    def from_config(cls, cfg, log, chain=None):
        from .rpc import RPC

        sa = cfg.sa
        if not sa.module:
            raise ValueError("sa.module not configured")
        if not sa.requests_dir:
            raise ValueError("sa.requests_dir not configured")
        chain = chain or RPCChainView(RPC(cfg.chain.rpc_url, timeout=10, retries=2), sa.module, cfg.chain.chain_id)
        return cls(chain, Queue(sa.requests_dir), StatusFile(sa.status_path), Policy.from_cfg(sa), log,
                   ip_onboard=RateLimiter(sa.api_ip_onboard_per_min, 60),
                   owner_onboard=RateLimiter(sa.api_owner_onboard_per_hour, 3600),
                   ip_status=RateLimiter(sa.api_ip_status_per_min, 60),
                   stale_s=sa.api_status_stale_s, max_body=sa.api_max_body)

    # ---------------------------------------------------------------- POST /onboard
    def onboard(self, body: bytes, ip: str) -> tuple[int, dict]:
        if not self.rl_ip.allow("ip:" + ip):
            raise Reject(429, "rate_limited", "too many requests from this address; try again in a minute")
        req = parse_request(parse_json(body))
        now = self.chain.now()
        account = verify_offchain(req, self.f, now, self.pol)
        if not self.rl_owner.allow("owner:" + req.owner):
            raise Reject(429, "rate_limited", "too many onboarding attempts for this wallet; try again later")
        payload = req.keeper_json()
        pend = self.q.pending(req.owner)
        if pend is not None:
            if {k: pend.get(k) for k in payload} == payload:
                return 200, self._queued(req, account, duplicate=True)
            raise Reject(409, "already_queued", "a different request for this wallet is already queued")
        verify_onchain(req, account, self.chain, self.f)
        if not self.q.enqueue(req.owner, dict(payload, received_at=int(self.wall()))):
            pend = self.q.pending(req.owner) or {}
            if {k: pend.get(k) for k in payload} == payload:
                return 200, self._queued(req, account, duplicate=True)
            raise Reject(409, "already_queued", "a different request for this wallet is already queued")
        self.log("sa_api_queued", owner=req.owner, account=account, kind=req.kind,
                 amount=(req.permit or {}).get("amount", 0))
        return 202, self._queued(req, account)

    @staticmethod
    def _queued(req, account, duplicate=False) -> dict:
        return {"ok": True, "state": "queued", "owner": req.owner, "account": account, "kind": req.kind,
                "duplicate": duplicate}

    # ---------------------------------------------------------------- GET /status
    def get_status(self, query: str, ip: str) -> tuple[int, dict]:
        if not self.rl_status.allow("ip:" + ip):
            raise Reject(429, "rate_limited", "too many requests; try again in a minute")
        try:
            q = urllib.parse.parse_qs(query, keep_blank_values=True, strict_parsing=True, max_num_fields=2)
        except ValueError:
            raise _bad("query", "expected ?owner=0x...")
        if set(q) != {"owner"} or len(q["owner"]) != 1:
            raise _bad("query", "expected exactly ?owner=0x...")
        owner = _addr(q["owner"][0], "owner")
        st = self.status.load()
        rows = st.get("accounts") or {}
        account, row = None, None
        for a, r in rows.items():
            if isinstance(r, dict) and r.get("owner") == owner:
                if row is None or r.get("active"):
                    account, row = a, r
        kind = (row or {}).get("kind")
        error = None
        if row is not None:
            state = "active" if row.get("active") else "revoked"
        else:
            pend = self.q.pending(owner)
            out = self.q.outcome(owner)
            if pend is not None:
                state, kind = "queued", pend.get("kind")
                account = hybrid_address(owner) if kind == "hybrid" else owner
            else:
                state = "none"
                for a, k in ((hybrid_address(owner), "hybrid"), (owner, "eip7702")):
                    try:
                        acc = self.chain.account(a)
                    except Exception:
                        acc = None
                    if acc and acc["registered"] and acc["owner"] == owner:
                        account, kind = a, k
                        state = "revoked" if (acc["revoked"] or not acc["active"]) else "onchain"
                        break
                if state == "none" and out is not None and out[0] == "failed":
                    state, error = "failed", _public_error(((out[2] or {}).get("result") or {}).get("error"))
            if account is None:
                account, kind = hybrid_address(owner), kind or "hybrid"
        summary = None
        if row is not None:
            summary = {k: row.get(k) for k in SUMMARY_KEYS}
            led = row.get("ledger") or {}
            summary["hedge"] = {k: led.get(k) for k in LEDGER_KEYS}
        return 200, {"ok": True, "owner": owner, "account": account, "kind": kind, "state": state, "error": error,
                     "summary": summary, "keeper": self._keeper(st)}

    def _keeper(self, st: dict) -> dict:
        w = st.get("written_at")
        age = int(self.wall() - w) if isinstance(w, (int, float)) else None
        return {"last_tick": st.get("last_tick"), "age_s": age, "fresh": age is not None and age <= self.stale_s,
                "paused": st.get("paused"), "price": (st.get("price") or {}).get("anchor")}

    # ---------------------------------------------------------------- GET /health
    def health(self) -> tuple[int, dict]:
        ok = self.q.writable()
        return (200 if ok else 503), {"ok": ok, "pending": self.q.count(), "chain_id": self.f.chain_id,
                                      "module": self.f.module, "keeper": self._keeper(self.status.load())}


# ------------------------------------------------------------------------------------------------ HTTP
def make_handler(api: SAApi, trust_proxy: bool = True):
    class H(BaseHTTPRequestHandler):
        server_version = "elysium-sa-api"
        sys_version = ""
        timeout = 15  # slow clients are dropped (nginx sits in front as well)

        def log_message(self, *a):  # the default access log prints client IPs: off
            pass

        def _ip(self) -> str:
            peer = self.client_address[0]
            if trust_proxy and peer in ("127.0.0.1", "::1"):
                xr = (self.headers.get("X-Real-IP") or "").strip()
                try:
                    return str(ipaddress.ip_address(xr))
                except ValueError:
                    pass
            return peer

        def _send(self, status: int, obj: dict):
            body = json.dumps(obj, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if status == 429:
                self.send_header("Retry-After", "60")
            self.end_headers()
            self.wfile.write(body)

        def _err(self, e: Reject):
            self._send(e.status, {"ok": False, "error": e.code, "detail": e.detail})

        def _route(self):
            u = urllib.parse.urlsplit(self.path)
            if not u.path.startswith(PREFIX + "/"):
                return None, u
            return u.path[len(PREFIX):], u

        def do_GET(self):  # noqa: N802
            r, u = self._route()
            try:
                if r == "/health":
                    self._send(*api.health())
                elif r == "/status":
                    self._send(*api.get_status(u.query, self._ip()))
                elif r == "/onboard":
                    raise Reject(405, "method", "POST only")
                else:
                    raise Reject(404, "not_found")
            except Reject as e:
                self._err(e)
            except Exception as e:
                api.log("sa_api_error", path=r, error=type(e).__name__)
                self._send(503, {"ok": False, "error": "unavailable", "detail": "try again shortly"})

        def do_POST(self):  # noqa: N802
            r, u = self._route()
            try:
                if r != "/onboard":
                    raise Reject(404 if r not in ("/status", "/health") else 405, "not_found")
                if u.query:
                    raise _bad("query", "no query string")
                ct = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
                if ct != "application/json":
                    raise Reject(415, "content_type", "application/json only")
                if self.headers.get("Transfer-Encoding"):
                    raise Reject(411, "length", "Content-Length required")
                cl = self.headers.get("Content-Length")
                if cl is None or not cl.isdigit():
                    raise Reject(411, "length", "Content-Length required")
                n = int(cl)
                if n > api.max_body:
                    self.close_connection = True
                    raise Reject(413, "too_large", f"body > {api.max_body} bytes")
                body = self.rfile.read(n)
                if len(body) != n:
                    raise _bad("schema", "truncated body")
                status, out = api.onboard(body, self._ip())
                self._send(status, out)
            except Reject as e:
                if e.status not in (404, 405, 411, 413, 415, 429):
                    api.log("sa_api_reject", code=e.code, status=e.status)
                self._err(e)
            except Exception as e:  # RPC down, disk full...: no details out
                api.log("sa_api_error", path=r, error=type(e).__name__)
                self._send(503, {"ok": False, "error": "unavailable", "detail": "try again shortly"})

        def do_PUT(self):  # noqa: N802
            self._err(Reject(405, "method"))

        do_DELETE = do_PATCH = do_PUT

    return H


def make_server(api: SAApi, host: str, port: int, trust_proxy: bool = True) -> ThreadingHTTPServer:
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("sa-api binds to localhost only (nginx proxies /elysium-api/sa/)")
    srv = ThreadingHTTPServer((host, port), make_handler(api, trust_proxy))
    srv.daemon_threads = True
    return srv


def serve(cfg, log):
    import signal

    api = SAApi.from_config(cfg, log)
    srv = make_server(api, cfg.sa.api_host, cfg.sa.api_port, cfg.sa.api_trust_proxy)
    signal.signal(signal.SIGTERM, lambda *a: threading.Thread(target=srv.shutdown, daemon=True).start())
    log("sa_api_start", host=cfg.sa.api_host, port=srv.server_address[1], module=api.f.module,
        queue=cfg.sa.requests_dir)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
