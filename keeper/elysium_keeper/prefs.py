"""Client strategy preferences: the EIP-712 "Strategy" message a client signs at onboarding (free, no transaction) and
may re-sign later to change it.

    Strategy(address owner,address account,address module,uint8 widthMode,uint32 widthBps,bool hedged,uint64 nonce,
             uint64 deadline)
    domain: {name: "Elysium LP Strategy", version: "1", chainId: 99901, verifyingContract: module}

  v2 (risk-off, docs/ARCHITECTURE.md): domain version "2" and one more field after `hedged`:
    Strategy(address owner,address account,address module,uint8 widthMode,uint32 widthBps,bool hedged,bool riskOff,
             uint64 nonce,uint64 deadline)
  v1 signatures stay valid (read as riskOff = false); the wire format tells them apart by the `riskOff` key.

- owner: the client EOA that signs (for a HybridDeleGator: its owner; for 7702: the account itself).
- account: the managed account (HybridDeleGator CREATE2 address, or the 7702 EOA).
- module: the LPManagerModule = the pool (one module per whitelisted hook-free Uniswap v4 pool).
- widthMode: 0 = auto (recommended width, recomputed from volatility at every re-range), 1 = manual.
- widthBps: manual only (auto: must be 0). HALF-width of the range in bps of the price at (re)centring: the range is
  [P x (1 - w), P x (1 + w)], widened outward to the pool's tick spacing. Bounds: [WIDTH_MIN_BPS, WIDTH_MAX_BPS]
  (config sa.width_min_bps / sa.width_max_bps; docs/PRODUCT_FLOW.md explains how they follow from the module's Params
  and tickSpacing 60).
- hedged: true = margin to the hedge treasury and a HYPE short on Hyperliquid (10% delta band); false = no margin, no
  short (full HYPE exposure + fees).
- riskOff (v2): true = the keeper leaves the pool for USDC while the risk-off signal is on (riskoff.py: BTC 4 h
  close far below its 30 d EMA) and re-enters when it clears (at least 24 h out). Protection from crashes, not extra
  yield. A hedged account also closes its short share while out (margin back into the account, as when unhedging).
- nonce: strictly increasing per account (the web uses the time in milliseconds); a message with a nonce not above
  the stored one is refused, so an old signature can never be replayed to undo a change.
- deadline: the signature must reach the keeper before it (a short submission window, not a validity period: an
  accepted preference stays until the client signs a newer one).

Nothing here is checked by a contract: the keeper enforces the preference; the module's Params still bound whatever
the keeper does (docs/PRODUCT_FLOW.md, trust note).
"""
from __future__ import annotations

from dataclasses import dataclass

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

from .sa_chain import domain_separator, typed_digest

MODE_AUTO, MODE_MANUAL = 0, 1
MODES = {MODE_AUTO: "auto", MODE_MANUAL: "manual"}
WIDTH_MIN_BPS = 200  # +-2%: below this the 60-tick spacing rounding (+-0.6% per side) dominates the width
WIDTH_MAX_BPS = 4000  # +-40%: the keeper's max_half_width; wider earns little (fees scale ~1/width)
U64_MAX = 2 ** 64 - 1

DOMAIN_NAME, DOMAIN_VERSION = "Elysium LP Strategy", "1"
STRATEGY_TYPE = ("Strategy(address owner,address account,address module,uint8 widthMode,uint32 widthBps,bool hedged,"
                 "uint64 nonce,uint64 deadline)")
STRATEGY_TYPEHASH = keccak(text=STRATEGY_TYPE)
STRATEGY_FIELDS = [("owner", "address"), ("account", "address"), ("module", "address"), ("widthMode", "uint8"),
                   ("widthBps", "uint32"), ("hedged", "bool"), ("nonce", "uint64"), ("deadline", "uint64")]
# v2: + riskOff (after hedged), domain version "2"
DOMAIN_VERSION_V2 = "2"
STRATEGY_TYPE_V2 = ("Strategy(address owner,address account,address module,uint8 widthMode,uint32 widthBps,bool hedged,"
                    "bool riskOff,uint64 nonce,uint64 deadline)")
STRATEGY_TYPEHASH_V2 = keccak(text=STRATEGY_TYPE_V2)
STRATEGY_FIELDS_V2 = STRATEGY_FIELDS[:6] + [("riskOff", "bool")] + STRATEGY_FIELDS[6:]


class PrefsError(ValueError):
    def __init__(self, code: str, detail: str = "", status: int = 400):
        super().__init__(f"{code}: {detail}")
        self.code, self.detail, self.status = code, detail, status


@dataclass(frozen=True)
class Strategy:
    owner: str
    account: str
    module: str
    width_mode: int
    width_bps: int
    hedged: bool
    nonce: int
    deadline: int
    signature: bytes = b""
    risk_off: bool = False
    version: int = 1  # 1: no riskOff field (risk_off is False); 2: riskOff signed

    @property
    def mode(self) -> str:
        return MODES[self.width_mode]

    @property
    def fields(self) -> list:
        return STRATEGY_FIELDS_V2 if self.version == 2 else STRATEGY_FIELDS

    def message(self) -> dict:
        m = {"owner": self.owner, "account": self.account, "module": self.module, "widthMode": self.width_mode,
             "widthBps": self.width_bps, "hedged": self.hedged, "nonce": str(self.nonce),
             "deadline": str(self.deadline)}
        if self.version == 2:
            m["riskOff"] = self.risk_off
        return m

    def to_json(self) -> dict:
        """Wire format (web -> API -> queue -> keeper): the message plus the 65-byte signature."""
        return dict(self.message(), signature="0x" + self.signature.hex())

    def record(self, accepted_at: int) -> dict:
        """What the keeper persists per account (state `prefs`) and publishes in the status file."""
        return {"owner": self.owner, "account": self.account, "module": self.module, "mode": self.mode,
                "width_bps": self.width_bps if self.width_mode == MODE_MANUAL else None, "hedged": self.hedged,
                "risk_off": self.risk_off, "version": self.version, "nonce": self.nonce, "deadline": self.deadline, "signature": "0x" + self.signature.hex(),
                "accepted_at": accepted_at, "source": "signed"}


def struct_hash(s: Strategy) -> bytes:
    if s.version == 2:
        return keccak(abi_encode(["bytes32"] + [t for _, t in STRATEGY_FIELDS_V2],
                                 [STRATEGY_TYPEHASH_V2, s.owner, s.account, s.module, s.width_mode, s.width_bps,
                                  s.hedged, s.risk_off, s.nonce, s.deadline]))
    return keccak(abi_encode(["bytes32"] + [t for _, t in STRATEGY_FIELDS],
                             [STRATEGY_TYPEHASH, s.owner, s.account, s.module, s.width_mode, s.width_bps, s.hedged,
                              s.nonce, s.deadline]))


def strategy_domain(chain_id: int, module: str, version: int = 1) -> bytes:
    return domain_separator(DOMAIN_NAME, DOMAIN_VERSION_V2 if version == 2 else DOMAIN_VERSION, chain_id, module)


def digest(s: Strategy, chain_id: int) -> bytes:
    return typed_digest(strategy_domain(chain_id, s.module, s.version), struct_hash(s))


def typed_data(s: Strategy, chain_id: int) -> dict:
    """eth_signTypedData_v4 payload (the web page builds the same object)."""
    return {
        "types": {
            "EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
                             {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}],
            "Strategy": [{"name": n, "type": t} for n, t in s.fields],
        },
        "primaryType": "Strategy",
        "domain": {"name": DOMAIN_NAME, "version": DOMAIN_VERSION_V2 if s.version == 2 else DOMAIN_VERSION,
                   "chainId": chain_id, "verifyingContract": s.module},
        "message": s.message(),
    }


# ------------------------------------------------------------------------------------------------ parsing
def _uint(v, field: str, bits: int) -> int:
    if isinstance(v, bool):
        raise PrefsError("strategy_schema", f"{field} must be an unsigned integer")
    if isinstance(v, int):
        x = v
    elif isinstance(v, str) and v.isdigit() and (v == "0" or not v.startswith("0")) and len(v) <= 78:
        x = int(v)
    else:
        raise PrefsError("strategy_schema", f"{field} must be an unsigned integer (number or decimal string)")
    if not 0 <= x < 2 ** bits:
        raise PrefsError("strategy_schema", f"{field} out of range")
    return x


def _addr(v, field: str) -> str:
    if not isinstance(v, str) or len(v) != 42 or not v.startswith("0x"):
        raise PrefsError("strategy_schema", f"{field} must be a 0x address")
    try:
        int(v[2:], 16)
    except ValueError:
        raise PrefsError("strategy_schema", f"{field} must be a 0x address")
    c = to_checksum_address(v)
    h = v[2:]
    if h != h.lower() and h != h.upper() and v != c:
        raise PrefsError("strategy_schema", f"{field}: bad address checksum")
    return c


def parse(obj) -> Strategy:
    """Strict: exactly the message keys plus `signature` (65 bytes hex). With a `riskOff` key it is a v2 message."""
    if not isinstance(obj, dict):
        raise PrefsError("strategy_schema", "strategy must be an object")
    version = 2 if "riskOff" in obj else 1
    keys = {n for n, _ in (STRATEGY_FIELDS_V2 if version == 2 else STRATEGY_FIELDS)} | {"signature"}
    missing, extra = keys - set(obj), set(obj) - keys
    if missing:
        raise PrefsError("strategy_schema", f"strategy: missing {sorted(missing)}")
    if extra:
        raise PrefsError("strategy_schema", f"strategy: unknown {sorted(extra)}")
    if not isinstance(obj["hedged"], bool):
        raise PrefsError("strategy_schema", "hedged must be true or false")
    if version == 2 and not isinstance(obj["riskOff"], bool):
        raise PrefsError("strategy_schema", "riskOff must be true or false")
    if version == 2 and obj["riskOff"] and obj["hedged"]:
        raise PrefsError("strategy_bounds", "smart exit (riskOff) is for unhedged positions only")
    sig = obj["signature"]
    if not isinstance(sig, str) or not sig.startswith("0x") or len(sig) != 132:
        raise PrefsError("strategy_schema", "signature must be 65 bytes of 0x hex")
    try:
        sigb = bytes.fromhex(sig[2:])
    except ValueError:
        raise PrefsError("strategy_schema", "signature must be 65 bytes of 0x hex")
    return Strategy(_addr(obj["owner"], "owner"), _addr(obj["account"], "account"), _addr(obj["module"], "module"),
                    _uint(obj["widthMode"], "widthMode", 8), _uint(obj["widthBps"], "widthBps", 32), obj["hedged"],
                    _uint(obj["nonce"], "nonce", 64), _uint(obj["deadline"], "deadline", 64), sigb,
                    risk_off=bool(obj["riskOff"]) if version == 2 else False, version=version)


# ------------------------------------------------------------------------------------------------ validation
@dataclass
class Bounds:
    width_min_bps: int = WIDTH_MIN_BPS
    width_max_bps: int = WIDTH_MAX_BPS
    deadline_min_s: int = 0  # API: the signature must stay valid this long after submission (queue latency)
    deadline_max_s: int = 2 * 86400

    @classmethod
    def from_cfg(cls, sa, deadline_min_s: int = 0) -> "Bounds":
        return cls(sa.width_min_bps, sa.width_max_bps, deadline_min_s, sa.strategy_deadline_max_s)


def check_values(s: Strategy, b: Bounds):
    if s.width_mode not in MODES:
        raise PrefsError("strategy_mode", "widthMode must be 0 (auto) or 1 (manual)")
    if s.width_mode == MODE_AUTO and s.width_bps != 0:
        raise PrefsError("strategy_width", "auto mode: widthBps must be 0")
    if s.width_mode == MODE_MANUAL and not b.width_min_bps <= s.width_bps <= b.width_max_bps:
        raise PrefsError("strategy_width", f"manual half-width must be within [{b.width_min_bps}, "
                                           f"{b.width_max_bps}] bps")
    if s.nonce == 0:
        raise PrefsError("strategy_nonce", "nonce must be > 0")


def verify(s: Strategy, *, owner: str, account: str, module: str, chain_id: int, now: int, b: Bounds,
           last_nonce: int = 0):
    """Everything about a Strategy message that does not need the chain: binding (owner, account, module), values,
    deadline window, nonce above the stored one, and the owner's signature (low s, v in {27, 28})."""
    from .sa_api import recover  # same ECDSA rules as the delegation / permit checks

    if s.owner != owner:
        raise PrefsError("strategy_owner", "strategy owner differs from the request owner")
    if s.account != account:
        raise PrefsError("strategy_account", "strategy account is not the owner's managed account")
    if s.module != module:
        raise PrefsError("strategy_module", "strategy is for another pool (module)")
    check_values(s, b)
    if not now + b.deadline_min_s <= s.deadline <= now + b.deadline_max_s:
        raise PrefsError("strategy_deadline", f"deadline must be within [now + {b.deadline_min_s} s, "
                                              f"now + {b.deadline_max_s} s]")
    if s.nonce <= last_nonce:
        raise PrefsError("strategy_nonce", f"nonce must be above the current one ({last_nonce})", status=409)
    sig = s.signature
    if len(sig) != 65 or recover(digest(s, chain_id), sig[64], sig[:32], sig[32:64]) != owner:
        raise PrefsError("strategy_signature", "the strategy is not signed by the owner", status=401)


def default_record(hedged: bool = True) -> dict:
    """Preference of an account that never signed one (onboarded before this flow): auto width, hedged."""
    return {"mode": "auto", "width_bps": None, "hedged": hedged, "risk_off": False, "nonce": 0, "source": "default"}


def public(rec: dict) -> dict:
    """The part of a stored preference served to the web (no signature)."""
    out = {k: rec.get(k) for k in ("mode", "width_bps", "hedged", "nonce", "accepted_at", "source")}
    out["risk_off"] = bool(rec.get("risk_off", False))
    return out
