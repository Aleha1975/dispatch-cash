"""Smart-account (per-client) chain layer: EIP-712 payloads the client signs, counterfactual HybridDeleGator
addresses, the LPManagerModule reader and the onboarding relayer.

Everything here is read-only or goes through rpc.Chain (simulate first, then the configured Signer, which refuses a
non-local RPC unless chain.allow_live_chain is set deliberately).
"""
from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

from .rpc import ERC20_ABI, POOL_MANAGER_ABI, POSM_ABI, RPC, Contract

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_ABI_PATH = os.path.join(HERE, "abi", "LPManagerModule.json")
PROXY_INITCODE_PATH = os.path.join(HERE, "abi", "ERC1967Proxy.initcode.hex")
POOLS_SLOT = 6

# Delegation Framework v1.3.0 (canonical CREATE2 addresses; DM / 7702 / TimestampEnforcer live on Elysium 99901)
DM = "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3"
EIP7702_IMPL = "0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B"
TIMESTAMP_ENFORCER = "0x1046bb45C8d673d4ea75321280DB34899413c069"
HYBRID_IMPL = "0x48dBe696A4D990079e039489bA2053B36E8FFEC4"
SIMPLE_FACTORY = "0x69Aa2f9fe1572F1B640E1bbc512f5c3a734fc77c"
ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
ROOT_AUTHORITY = b"\xff" * 32
ACCOUNT_SALT = b"ELYSIUM-LP-V1".ljust(32, b"\0")
KIND = {1: "hybrid", 2: "eip7702"}

CAVEAT_TYPE = "Caveat(address enforcer,bytes terms)"
DELEGATION_TYPE = "Delegation(address delegate,address delegator,bytes32 authority,Caveat[] caveats,uint256 salt)"
CAVEAT_TYPEHASH = keccak(text=CAVEAT_TYPE)
DELEGATION_TYPEHASH = keccak(text=DELEGATION_TYPE + CAVEAT_TYPE)
PERMIT_TYPEHASH = keccak(text="Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
USEROP_TYPE = ("PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,"
               "uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,address entryPoint)")
USEROP_TYPEHASH = keccak(text=USEROP_TYPE)
DOMAIN_TYPEHASH = keccak(text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

DELEGATION_TUPLE = "(address,address,bytes32,(address,bytes,bytes)[],uint256,bytes)"


def _b(x) -> bytes:
    if isinstance(x, bytes):
        return x
    return bytes.fromhex(x[2:] if x.startswith("0x") else x)


def domain_separator(name: str, version: str, chain_id: int, verifying: str) -> bytes:
    return keccak(abi_encode(["bytes32", "bytes32", "bytes32", "uint256", "address"],
                             [DOMAIN_TYPEHASH, keccak(text=name), keccak(text=version), chain_id, verifying]))


def typed_digest(domain_sep: bytes, struct_hash: bytes) -> bytes:
    return keccak(b"\x19\x01" + domain_sep + struct_hash)


# ---------------------------------------------------------------- delegation
@dataclass
class Delegation:
    delegate: str
    delegator: str
    caveats: list  # [(enforcer, terms bytes, args bytes)]
    salt: int
    authority: bytes = ROOT_AUTHORITY
    signature: bytes = b""

    def as_tuple(self):
        return (self.delegate, self.delegator, self.authority,
                [(e, _b(t), _b(a)) for e, t, a in self.caveats], self.salt, self.signature)

    def to_json(self) -> dict:
        return {"delegate": self.delegate, "delegator": self.delegator, "authority": "0x" + self.authority.hex(),
                "caveats": [{"enforcer": e, "terms": "0x" + _b(t).hex(), "args": "0x" + _b(a).hex()}
                            for e, t, a in self.caveats],
                "salt": str(self.salt), "signature": "0x" + self.signature.hex()}

    @classmethod
    def from_json(cls, d: dict) -> "Delegation":
        return cls(to_checksum_address(d["delegate"]), to_checksum_address(d["delegator"]),
                   [(to_checksum_address(c["enforcer"]), _b(c["terms"]), _b(c.get("args", "0x")))
                    for c in d["caveats"]],
                   int(d["salt"]), _b(d.get("authority", "0x" + ROOT_AUTHORITY.hex())), _b(d.get("signature", "0x")))


def delegation_hash(d: Delegation) -> bytes:
    """DelegationManager.getDelegationHash (EIP-712 struct hash; caveat args and the signature are excluded)."""
    cav = b"".join(keccak(abi_encode(["bytes32", "address", "bytes32"], [CAVEAT_TYPEHASH, e, keccak(_b(t))]))
                   for e, t, _ in d.caveats)
    return keccak(abi_encode(["bytes32", "address", "address", "bytes32", "bytes32", "uint256"],
                             [DELEGATION_TYPEHASH, d.delegate, d.delegator, d.authority, keccak(cav), d.salt]))


def dm_domain(chain_id: int) -> bytes:
    return domain_separator("DelegationManager", "1", chain_id, DM)


def module_delegation(account: str, module: str, enforcer: str, treasury: str, fee_to: str, until: int,
                      salt: int = 1) -> Delegation:
    """The exact shape LPManagerModule.register accepts: custody caveat + timestamp caveat (no 'after', 'before'=until)."""
    terms = abi_encode(["address", "address", "address"], [module, treasury, fee_to])
    ts = (0).to_bytes(16, "big") + until.to_bytes(16, "big")
    return Delegation(to_checksum_address(module), to_checksum_address(account),
                      [(to_checksum_address(enforcer), terms, b""), (TIMESTAMP_ENFORCER, ts, b"")], salt)


def delegation_typed_data(d: Delegation, chain_id: int) -> dict:
    """eth_signTypedData_v4 payload (MetaMask) whose digest equals typed_digest(dm_domain, delegation_hash)."""
    return {
        "types": {
            "EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
                             {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}],
            "Delegation": [{"name": "delegate", "type": "address"}, {"name": "delegator", "type": "address"},
                           {"name": "authority", "type": "bytes32"}, {"name": "caveats", "type": "Caveat[]"},
                           {"name": "salt", "type": "uint256"}],
            "Caveat": [{"name": "enforcer", "type": "address"}, {"name": "terms", "type": "bytes"}],
        },
        "primaryType": "Delegation",
        "domain": {"name": "DelegationManager", "version": "1", "chainId": chain_id, "verifyingContract": DM},
        "message": {"delegate": d.delegate, "delegator": d.delegator, "authority": "0x" + d.authority.hex(),
                    "caveats": [{"enforcer": e, "terms": "0x" + _b(t).hex()} for e, t, _ in d.caveats],
                    "salt": str(d.salt)},
    }


# ---------------------------------------------------------------- USDC permit (EIP-2612)
def permit_digest(usdc_domain_sep: bytes, owner: str, spender: str, value: int, nonce: int, deadline: int) -> bytes:
    sh = keccak(abi_encode(["bytes32", "address", "address", "uint256", "uint256", "uint256"],
                           [PERMIT_TYPEHASH, owner, spender, value, nonce, deadline]))
    return typed_digest(usdc_domain_sep, sh)


# ---------------------------------------------------------------- HybridDeleGator account
def proxy_initcode(owner: str) -> bytes:
    with open(PROXY_INITCODE_PATH) as fh:
        code = _b(fh.read().strip())
    # HybridDeleGator.initialize(owner, string[] keyIds, uint256[] xs, uint256[] ys)
    sel = keccak(text="initialize(address,string[],uint256[],uint256[])")[:4]
    init = sel + abi_encode(["address", "string[]", "uint256[]", "uint256[]"], [owner, [], [], []])
    return code + abi_encode(["address", "bytes"], [HYBRID_IMPL, init])


def create2_address(deployer: str, salt: bytes, initcode_hash: bytes) -> str:
    return to_checksum_address(keccak(b"\xff" + _b(deployer) + salt + initcode_hash)[12:])


def hybrid_address(owner: str) -> str:
    """Counterfactual HybridDeleGator of `owner` (SimpleFactory.computeAddress(keccak(initcode), ACCOUNT_SALT))."""
    return create2_address(SIMPLE_FACTORY, ACCOUNT_SALT, keccak(proxy_initcode(owner)))


def userop_struct_hash(op: dict) -> bytes:
    return keccak(abi_encode(
        ["bytes32", "address", "uint256", "bytes32", "bytes32", "bytes32", "uint256", "bytes32", "bytes32", "address"],
        [USEROP_TYPEHASH, op["sender"], op["nonce"], keccak(op["initCode"]), keccak(op["callData"]),
         op["accountGasLimits"], op["preVerificationGas"], op["gasFees"], keccak(op["paymasterAndData"]), ENTRYPOINT]))


def userop_digest(op: dict, chain_id: int) -> bytes:
    return typed_digest(domain_separator("HybridDeleGator", "1", chain_id, op["sender"]), userop_struct_hash(op))


# ---------------------------------------------------------------- module reader
@dataclass
class APos:
    token_id: int
    tl: int
    tu: int
    liquidity: int


@dataclass
class AccountSnap:
    address: str
    kind: str
    active: bool
    until: int
    contributed: int
    hwm: int
    hedge_equity: int
    net_margin: int
    hedge_epoch: int
    last_fee_time: int
    fees_paid: int
    usdc: int
    native: int
    positions: list
    value: int  # accountValue at the anchor
    budgets: dict  # guardian hedge approval (hedgeApproved / Epoch / Until / Era)
    windows: dict  # used amounts in the sliding 24 h windows (turnoverUsed, hedgeUsed, priceUsed)
    owner: str = ""  # pinned owner (hybrid: the EOA the address derives from; 7702: the account)
    revoked: bool = False
    hedge_clipped: bool = False
    hedge_time: int = 0
    pending: int = 0  # live state - snapshot at the anchor: a client flow not booked yet (SA-2: booked at a trusted sync)
    value_pool: int = 0  # accountValue at the pool price (the fee uses min(value, value_pool), SA-2 H-1)

    @property
    def profit(self) -> int:
        """Profit as the module books it: value minus contributed minus the not yet booked client flow."""
        return self.value - self.contributed - self.pending

    @property
    def fee_profit(self) -> int:
        """The profit chargeFee measures: min(value at the anchor, value at the pool) - contributed - pending."""
        return min(self.value, self.value_pool or self.value) - self.contributed - self.pending

    def lp_amounts(self, sqrt_price: int):
        from . import v4math as M
        b = a = 0
        for p in self.positions:
            x, y = M.amounts_for_liquidity(sqrt_price, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu),
                                           p.liquidity)
            b, a = b + x, a + y
        return b, a


@dataclass
class GlobalSnap:
    last_price: int
    last_price_time: int
    clipped: bool  # view: the anchor is outside the pool band of the keeper's last report (clears itself)
    paused: bool
    pool_price: int
    sqrt_price: int
    tick: int
    params: dict
    price_budget: dict
    treasury: str
    fee_recipient: str
    treasury_usdc: int = 0
    treasury_allowance: int = 0
    extra: dict = field(default_factory=dict)
    last_price_moved: int = 0  # last change of the anchor value (fees and booking need minPriceStable since)
    last_reported: int = 0

    def trusted(self, now: int) -> bool:
        """LPManagerModule._trusted(): fresh, unclipped, pool within band of the anchor, anchor stable long enough."""
        p = self.params
        lp = self.last_price
        return (lp > 0 and not self.clipped and now - self.last_price_time <= p["maxPriceAge"]
                and abs(self.pool_price - lp) * 10_000 <= lp * p["poolBandBps"]
                and now >= self.last_price_moved + p["minPriceStable"])


# LPManagerModule.budgets(a): (turnover window, hedge window, hedgeApproved, hedgeApprovedEpoch, hedgeApprovedUntil,
# hedgeApprovedEra); the windows are read through windows(a)
ZERO_ADDRESS = "0x" + "00" * 20
BUDGET_KEYS = ["hedgeApproved", "hedgeApprovedEpoch", "hedgeApprovedUntil", "hedgeApprovedEra"]
WINDOW_KEYS = ["turnoverUsed", "hedgeUsed", "priceUsed"]
PRICE_BUDGET_KEYS = ["priceApprovedLo", "priceApprovedHi", "priceApprovedUntil"]
# SALib.Account field order (LPManagerModule.account(a))
ACCOUNT_KEYS = ["delegationHash", "owner", "kind", "until", "revoked", "hedgeClipped", "contributed", "hwm",
                "hedgeEquity", "netMargin", "hedgeEpoch", "snapAsset", "snapBase", "lastFeeTime", "feesPaid",
                "hedgeTime"]
PARAM_KEYS = ["feeBps", "hedgeCapBps", "poolBandBps", "maxSlippageBps", "hedgeStepBps", "refDriftBps",
              "swapTurnoverBps", "feeInterval", "maxPriceAge", "minPriceStable"]


class ModuleReader:
    def __init__(self, rpc: RPC, module: str):
        with open(MODULE_ABI_PATH) as fh:
            self.abi = json.load(fh)
        self.rpc = rpc
        self.m = Contract(rpc, module, self.abi)
        self.pm = Contract(rpc, self.m.call("poolManager"), POOL_MANAGER_ABI)
        self.posm = Contract(rpc, self.m.call("positionManager"), POSM_ABI)
        self.usdc = Contract(rpc, self.m.call("asset"), ERC20_ABI)
        self.pool_id = self.m.call("poolId")
        self.slot0_key = keccak(abi_encode(["bytes32", "uint256"], [self.pool_id, POOLS_SLOT]))
        self.treasury = to_checksum_address(self.m.call("hedgeTreasury"))
        self.fee_recipient = to_checksum_address(self.m.call("feeRecipient"))
        self.enforcer = to_checksum_address(self.m.call("enforcer"))
        if not self.m.call("baseIsCurrency0"):
            raise ValueError("keeper assumes native HYPE = currency0")
        self.registered_topic = "0x" + keccak(text="Registered(address,bytes32,uint8,uint256,bool)").hex()

    def slot0(self):
        w = int.from_bytes(self.pm.call("extsload", self.slot0_key), "big")
        sp = w & ((1 << 160) - 1)
        t = (w >> 160) & 0xFFFFFF
        if t >= 1 << 23:
            t -= 1 << 24
        return sp, t

    def global_snap(self) -> GlobalSnap:
        c = self.m.call
        sp, tick = self.slot0()
        g = GlobalSnap(last_price=c("lastPrice"), last_price_time=c("lastPriceTime"), clipped=c("lastPriceClipped"),
                       paused=c("paused"), pool_price=c("poolPrice"), sqrt_price=sp, tick=tick,
                       params=dict(zip(PARAM_KEYS, c("params"))),
                       price_budget=dict(zip(PRICE_BUDGET_KEYS, c("priceBudget")[1:])),
                       treasury=self.treasury, fee_recipient=self.fee_recipient,
                       last_price_moved=c("lastPriceMoved"), last_reported=c("lastReported"))
        g.price_budget["priceUsed"] = c("windows", ZERO_ADDRESS)[2]
        g.treasury_usdc = self.usdc.call("balanceOf", self.treasury)
        g.treasury_allowance = self.usdc.call("allowance", self.treasury, self.m.address)
        return g

    def account(self, a: str, price: int | None = None) -> AccountSnap:
        c = self.m.call
        a = to_checksum_address(a)
        s = dict(zip(ACCOUNT_KEYS, c("account", a)))
        if s["delegationHash"] == b"\0" * 32:
            raise ValueError(f"{a} is not registered")
        price = price or c("lastPrice")
        ps = [APos(int(t[0]), int(t[1]), int(t[2]), int(self.posm.call("getPositionLiquidity", int(t[0]))))
              for t in c("positionsOf", a)]
        active = c("isActive", a)
        snap = AccountSnap(
            address=a, kind=KIND.get(s["kind"], str(s["kind"])), active=active, until=s["until"],
            contributed=s["contributed"], hwm=s["hwm"], hedge_equity=s["hedgeEquity"], net_margin=s["netMargin"],
            hedge_epoch=s["hedgeEpoch"], last_fee_time=s["lastFeeTime"], fees_paid=s["feesPaid"],
            usdc=self.usdc.call("balanceOf", a), native=self.rpc.balance(a), positions=ps,
            value=c("accountValue", a, price), budgets=dict(zip(BUDGET_KEYS, c("budgets", a)[2:])),
            windows=dict(zip(WINDOW_KEYS, c("windows", a))), owner=to_checksum_address(s["owner"]),
            revoked=s["revoked"], hedge_clipped=s["hedgeClipped"], hedge_time=s["hedgeTime"],
            value_pool=c("accountValue", a, c("poolPrice")))
        snap.pending = self.pending(snap, s, price)
        return snap

    def pending(self, snap: "AccountSnap", s: dict, price: int) -> int:
        """Live state - snapshot at `price` (SABook.sync's flow): idle deltas plus the liquidity deltas of the
        tracked positions, each valued with V4PositionMath.liquidityValue's formula. A few wei of rounding apart."""
        from . import v4math as M
        sp = math.isqrt(price * (1 << 192) // 10**18)
        f = snap.usdc - s["snapAsset"]
        db = snap.native - s["snapBase"]
        f += db * price // 10**18 if db >= 0 else -((-db * price + 10**18 - 1) // 10**18)
        for p in snap.positions:
            old = self.m.call("snapLiquidity", p.token_id)
            if p.liquidity != old:
                sa_, sb = M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu)
                for liq, sign in ((p.liquidity, 1), (old, -1)):
                    x, y = M.amounts_for_liquidity(sp, sa_, sb, liq)
                    f += sign * (y + x * price // 10**18)
        return f

    def discover(self, from_block: int, to_block: int | None = None, step: int = 50_000) -> list[str]:
        """Accounts from Registered events (chunked eth_getLogs)."""
        end = to_block if to_block is not None else int(self.rpc.call("eth_blockNumber"), 16)
        out: list[str] = []
        b = from_block
        while b <= end:
            e = min(end, b + step - 1)
            logs = self.rpc.call("eth_getLogs", [{"address": self.m.address, "fromBlock": hex(b), "toBlock": hex(e),
                                                  "topics": [self.registered_topic]}])
            for lg in logs:
                a = to_checksum_address("0x" + lg["topics"][1][-40:])
                if a not in out:
                    out.append(a)
            b = e + 1
        return out


# ---------------------------------------------------------------- relayer (onboarding)
MULTICALL3_ABI = [{"type": "function", "name": "aggregate3", "stateMutability": "payable",
                   "inputs": [{"name": "calls", "type": "tuple[]", "components": [
                       {"name": "target", "type": "address"}, {"name": "allowFailure", "type": "bool"},
                       {"name": "callData", "type": "bytes"}]}],
                   "outputs": [{"name": "r", "type": "tuple[]", "components": [
                       {"name": "success", "type": "bool"}, {"name": "returnData", "type": "bytes"}]}]}]
FACTORY_ABI = [{"type": "function", "name": "deploy", "stateMutability": "nonpayable",
                "inputs": [{"name": "b", "type": "bytes"}, {"name": "s", "type": "bytes32"}],
                "outputs": [{"name": "", "type": "address"}]}]


class Relayer:
    """Submits a client's onboarding (two signatures, no client transaction): deploy the HybridDeleGator if needed
    and call module.onboard(delegation, amount, permit) in ONE Multicall3 transaction. 7702 accounts: register only.
    The request is checked off-chain first (account address, delegation hash, shape) and simulated before sending."""

    def __init__(self, reader: ModuleReader, chain, chain_id: int, log):
        self.r, self.chain, self.chain_id, self.log = reader, chain, chain_id, log
        self.mc = Contract(reader.rpc, MULTICALL3, MULTICALL3_ABI)
        self.factory = Contract(reader.rpc, SIMPLE_FACTORY, FACTORY_ABI)

    def check(self, req: dict) -> Delegation:
        d = Delegation.from_json(req["delegation"])
        if d.delegate != self.r.m.address:
            raise ValueError("delegation is not to this module")
        owner = to_checksum_address(req["owner"])
        if req.get("kind", "hybrid") == "hybrid" and hybrid_address(owner) != d.delegator:
            raise ValueError("delegator is not the owner's HybridDeleGator")
        if req.get("kind") == "eip7702" and d.delegator != owner:
            raise ValueError("7702 delegator must be the owner EOA")
        if len(d.signature) != 65:
            raise ValueError("delegation signature missing")
        return d

    def onboard(self, req: dict):
        d = self.check(req)
        owner = to_checksum_address(req["owner"])
        calls = []
        if req.get("kind", "hybrid") == "hybrid":
            if self.r.rpc.call("eth_getCode", [d.delegator, "latest"]) in ("0x", "0x0"):
                calls.append((SIMPLE_FACTORY, False,
                              _b(self.factory.encode("deploy", proxy_initcode(owner), ACCOUNT_SALT))))
            p = req.get("permit") or {"amount": 0, "deadline": 0, "v": 0, "r": "0x" + "00" * 32, "s": "0x" + "00" * 32}
            calls.append((self.r.m.address, False, _b(self.r.m.encode(
                "onboard", d.as_tuple(), int(p["amount"]), int(p["deadline"]), int(p["v"]), _b(p["r"]), _b(p["s"])))))
        else:
            calls.append((self.r.m.address, False, _b(self.r.m.encode("register", d.as_tuple()))))
        rc = self.chain.transact(self.mc, "aggregate3", calls)
        self.log("onboarded", account=d.delegator, owner=owner, kind=req.get("kind", "hybrid"),
                 amount=(req.get("permit") or {}).get("amount", 0))
        return d.delegator, rc
