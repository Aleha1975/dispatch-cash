"""Smart-account keeper end to end on a local anvil fork of Elysium (chain 99901). Nothing leaves the fork: anvil runs
with --auto-impersonate; the client keys are throwaway keys derived in the test. HL is the dry-run adapter.

  ELYSIUM_FORK=1 python3 -m pytest -s tests/test_sa_e2e_fork.py

Scenario: deploy with script/DeploySA.s.sol (canonical HybridDeleGatorImpl + SimpleFactory via CREATE2, module,
enforcer, executor) -> keeper anchors the price -> two clients onboard through the relayer (2 typed-data signatures
each: delegation + USDC permit; the client sends no transaction) -> keeper ticks: hedge margin, swap, mint, netted
dry-run short split by the ledger -> third-party volume, one week -> HWM fee -> client 1 exits with ONE EntryPoint
transaction (revoke + burn to its account) -> keeper closes its hedge share and pays its margin to the owner EOA ->
a restarted keeper does nothing new.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from eth_abi import encode as abi_encode  # noqa: E402
from eth_account import Account  # noqa: E402
from eth_utils import keccak, to_checksum_address  # noqa: E402

from elysium_keeper import config as C  # noqa: E402
from elysium_keeper.hl import DryRunAdapter  # noqa: E402
from elysium_keeper.infra import Log  # noqa: E402
from elysium_keeper.rpc import ERC20_ABI, Contract  # noqa: E402
from elysium_keeper.sa_chain import _b  # noqa: E402
from elysium_keeper.sa_chain import (  # noqa: E402
    DM, ENTRYPOINT, HYBRID_IMPL, SIMPLE_FACTORY, Relayer, delegation_hash, dm_domain, hybrid_address,
    module_delegation, permit_digest, typed_digest, userop_digest)
from elysium_keeper.sa_keeper import SAKeeper  # noqa: E402
from forkutil import DEPLOYER, REPO, USDC, Fork, MockHL, Trader, addr  # noqa: E402

pytestmark = pytest.mark.skipif(not os.environ.get("ELYSIUM_FORK"), reason="set ELYSIUM_FORK=1 (needs anvil+forge)")

OWNER, KEEPER, GUARDIAN, FEE_TO, TREASURY = addr(1), addr(2), addr(3), addr(4), addr(5)
E6 = 10 ** 6
DM_ABI = [
    {"type": "function", "name": "getDelegationHash", "stateMutability": "view",
     "inputs": [{"name": "d", "type": "tuple", "components": [
         {"name": "delegate", "type": "address"}, {"name": "delegator", "type": "address"},
         {"name": "authority", "type": "bytes32"},
         {"name": "caveats", "type": "tuple[]", "components": [
             {"name": "enforcer", "type": "address"}, {"name": "terms", "type": "bytes"}, {"name": "args", "type": "bytes"}]},
         {"name": "salt", "type": "uint256"}, {"name": "signature", "type": "bytes"}]}],
     "outputs": [{"name": "", "type": "bytes32"}]},
    {"type": "function", "name": "getDomainHash", "stateMutability": "view", "inputs": [],
     "outputs": [{"name": "", "type": "bytes32"}]},
    {"type": "function", "name": "disabledDelegations", "stateMutability": "view",
     "inputs": [{"name": "h", "type": "bytes32"}], "outputs": [{"name": "", "type": "bool"}]},
]
PERMIT_ABI = [
    {"type": "function", "name": "DOMAIN_SEPARATOR", "stateMutability": "view", "inputs": [],
     "outputs": [{"name": "", "type": "bytes32"}]},
    {"type": "function", "name": "nonces", "stateMutability": "view", "inputs": [{"name": "o", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
]
FACTORY_VIEW_ABI = [{"type": "function", "name": "computeAddress", "stateMutability": "view",
                     "inputs": [{"name": "h", "type": "bytes32"}, {"name": "s", "type": "bytes32"}],
                     "outputs": [{"name": "", "type": "address"}]}]
OP = "(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)"
ACCOUNT_ABI = [
    {"type": "function", "name": "getPackedUserOperationTypedDataHash", "stateMutability": "view",
     "inputs": [{"name": "op", "type": "tuple", "components": [
         {"name": "sender", "type": "address"}, {"name": "nonce", "type": "uint256"}, {"name": "initCode", "type": "bytes"},
         {"name": "callData", "type": "bytes"}, {"name": "accountGasLimits", "type": "bytes32"},
         {"name": "preVerificationGas", "type": "uint256"}, {"name": "gasFees", "type": "bytes32"},
         {"name": "paymasterAndData", "type": "bytes"}, {"name": "signature", "type": "bytes"}]}],
     "outputs": [{"name": "", "type": "bytes32"}]},
]
EP_ABI = [
    {"type": "function", "name": "handleOps", "stateMutability": "nonpayable",
     "inputs": [{"name": "ops", "type": "tuple[]", "components": ACCOUNT_ABI[0]["inputs"][0]["components"]},
                {"name": "b", "type": "address"}], "outputs": []},
    {"type": "function", "name": "getNonce", "stateMutability": "view",
     "inputs": [{"name": "s", "type": "address"}, {"name": "k", "type": "uint192"}],
     "outputs": [{"name": "", "type": "uint256"}]},
]


@pytest.fixture(scope="module")
def env():
    tmp = tempfile.mkdtemp(prefix="sa-e2e-")
    fork = Fork(os.environ.get("ELYSIUM_RPC", "https://rpc.elysium.kinetiq.xyz"),
                int(os.environ["ELYSIUM_FORK_BLOCK"]) if os.environ.get("ELYSIUM_FORK_BLOCK") else None,
                os.path.join(tmp, "anvil.log"))
    for a in (KEEPER, TREASURY, OWNER, GUARDIAN):
        fork.set_balance(a, 10 ** 21)
    yield fork, tmp
    fork.close()


def deploy_sa(fork) -> str:
    import subprocess

    env = dict(os.environ, OWNER=OWNER, KEEPER=KEEPER, GUARDIAN=GUARDIAN, HEDGE_TREASURY=TREASURY,
               FEE_RECIPIENT=FEE_TO)
    cmd = ["forge", "script", "script/DeploySA.s.sol:DeploySA", "--rpc-url", fork.url, "--broadcast", "--unlocked",
           "--sender", DEPLOYER, "--slow"]
    r = subprocess.run(cmd, cwd=REPO, env=env, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise RuntimeError("forge script failed:\n" + r.stdout[-3000:] + r.stderr[-3000:])
    run = json.load(open(os.path.join(REPO, "broadcast", "DeploySA.s.sol", "99901", "run-latest.json")))
    for tx in run["transactions"]:
        if tx.get("contractName") == "LPManagerModule":
            return to_checksum_address(tx["contractAddress"])
    raise RuntimeError("module address not found")


def make_keeper(fork, tmp, module, hl, alerts, name="sa"):
    cfg = C.from_dict({
        "name": name,
        "chain": {"rpc_url": fork.url, "keeper": KEEPER, "signer": "unlocked"},
        "hl": {"adapter": "dry_run", "equity_source": "mock"},
        "sa": {"module": module, "discover_from_block": int(fork.rpc.call("eth_blockNumber"), 16) - 50,
               "stagger_s": 0, "ledger_path": os.path.join(tmp, "ledger.json"),
               "requests_dir": os.path.join(tmp, "requests")},
        "state_path": os.path.join(tmp, "sa.state.json"),
        "log_path": os.path.join(tmp, "sa.log"),
    })
    log = Log(cfg.log_path, name, echo=False)
    st_sim = {}
    adapter = DryRunAdapter(cfg.hl, st_sim, log, mark_fn=hl.mid)
    return SAKeeper(cfg, hl_info=hl, adapter=adapter, log=log, alert_sink=lambda lvl, t: alerts.append((lvl, t)))


def onboard(fork, k, module_addr, pk: bytes, usd: int, via_dir: str | None = None):
    acct = Account.from_key(pk)
    owner = acct.address
    fork.deal_usdc(owner, usd * E6)
    a = hybrid_address(owner)
    fac = Contract(fork.rpc, SIMPLE_FACTORY, FACTORY_VIEW_ABI)
    from elysium_keeper.sa_chain import ACCOUNT_SALT, proxy_initcode
    assert to_checksum_address(fac.call("computeAddress", keccak(proxy_initcode(owner)), ACCOUNT_SALT)) == a
    until = fork.now() + 180 * 86400
    d = module_delegation(a, module_addr, k.r.enforcer, TREASURY, FEE_TO, until)
    dm = Contract(fork.rpc, DM, DM_ABI)
    assert dm.call("getDelegationHash", d.as_tuple()) == delegation_hash(d)
    assert dm.call("getDomainHash") == dm_domain(99901)
    d.signature = bytes(Account.unsafe_sign_hash(typed_digest(dm_domain(99901), delegation_hash(d)), pk).signature)
    usdc = Contract(fork.rpc, USDC, PERMIT_ABI)
    deadline = fork.now() + 3600
    digest = permit_digest(usdc.call("DOMAIN_SEPARATOR"), owner, module_addr, usd * E6, usdc.call("nonces", owner),
                           deadline)
    sig = Account.unsafe_sign_hash(digest, pk)
    req = {"owner": owner, "kind": "hybrid", "delegation": d.to_json(),
           "permit": {"amount": usd * E6, "deadline": deadline, "v": sig.v, "r": hex(sig.r), "s": hex(sig.s)}}
    req["permit"]["r"] = "0x" + sig.r.to_bytes(32, "big").hex()
    req["permit"]["s"] = "0x" + sig.s.to_bytes(32, "big").hex()
    if via_dir:  # the web backend drops the request; the keeper's relayer picks it up on its next tick
        os.makedirs(via_dir, exist_ok=True)
        with open(os.path.join(via_dir, f"{owner}.json"), "w") as fh:
            json.dump(req, fh)
        return a, d
    acct_addr, _ = Relayer(k.r, k.chain, 99901, k.log).onboard(json.loads(json.dumps(req)))
    assert acct_addr == a
    assert int(fork.rpc.call("eth_getTransactionCount", [owner, "latest"]), 16) == 0, "client sent nothing"
    return a, d


def exit_hybrid(fork, k, pk: bytes, a: str, d):
    """ONE transaction from the owner EOA: EntryPoint.handleOps with a zero-fee userOp signed (EIP-712) by the owner;
    the account revokes at the module, disables the delegation and burns its positions into itself, in ERC-7579 TRY
    mode (SA-1 M-8: a failing burn cannot undo the revocation; the outcome is checked by state, not tx status)."""
    owner = Account.from_key(pk).address
    fork.set_balance(owner, 10 ** 18)
    xs = [(k.r.m.address, 0, _b(k.r.m.encode("revoke", a)))]
    xs += [(DM, 0, keccak(text="disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))")[:4]
           + abi_encode(["(address,address,bytes32,(address,bytes,bytes)[],uint256,bytes)"], [d.as_tuple()]))]
    for p in k.r.m.call("positionsOf", a):
        # V4PositionMath.removeData(burn) equivalent: actions BURN_POSITION, TAKE_PAIR(c0, c1, account)
        actions = bytes([0x03, 0x11])
        params = [abi_encode(["uint256", "uint128", "uint128", "bytes"], [int(p[0]), 0, 0, b""]),
                  abi_encode(["address", "address", "address"], ["0x" + "00" * 20, USDC, a])]
        unlock = abi_encode(["bytes", "bytes[]"], [actions, params])
        call = keccak(text="modifyLiquidities(bytes,uint256)")[:4] + abi_encode(["bytes", "uint256"],
                                                                              [unlock, fork.now() + 3600])
        xs.append((k.r.posm.address, 0, call))
    batch = abi_encode(["(address,uint256,bytes)[]"], [xs])
    mode = ((1 << 248) | (1 << 240)).to_bytes(32, "big")  # batch, TRY exec type
    call_data = keccak(text="execute(bytes32,bytes)")[:4] + abi_encode(["bytes32", "bytes"], [mode, batch])
    ep = Contract(fork.rpc, ENTRYPOINT, EP_ABI)
    op = dict(sender=a, nonce=ep.call("getNonce", a, 0), initCode=b"", callData=call_data,
              accountGasLimits=((300_000 << 128) | 2_000_000).to_bytes(32, "big"), preVerificationGas=0,
              gasFees=b"\0" * 32, paymasterAndData=b"")
    onchain = Contract(fork.rpc, a, ACCOUNT_ABI).call("getPackedUserOperationTypedDataHash", (
        op["sender"], op["nonce"], op["initCode"], op["callData"], op["accountGasLimits"], op["preVerificationGas"],
        op["gasFees"], op["paymasterAndData"], b""))
    assert onchain == userop_digest(op, 99901)
    sig = bytes(Account.unsafe_sign_hash(onchain, pk).signature)
    tup = (op["sender"], op["nonce"], op["initCode"], op["callData"], op["accountGasLimits"], op["preVerificationGas"],
           op["gasFees"], op["paymasterAndData"], sig)
    rc = fork.send(owner, ep, "handleOps", [tup], owner)
    return int(rc["gasUsed"], 16)


def test_sa_end_to_end(env):
    fork, tmp = env
    alerts: list = []
    module = deploy_sa(fork)
    assert int(fork.rpc.call("eth_getCode", [HYBRID_IMPL, "latest"]), 16) > 0
    usdc = Contract(fork.rpc, USDC, ERC20_ABI)
    fork.send(TREASURY, usdc, "approve", module, 2 ** 256 - 1)
    m = Contract(fork.rpc, module, json.load(open(os.path.join(REPO, "keeper", "abi", "LPManagerModule.json"))))
    trader = Trader(fork, m)
    p0 = trader.price()
    hl = MockHL(fork.now(), p0 / 1e6)
    k = make_keeper(fork, tmp, module, hl, alerts)
    st = k.tick()  # anchors the price (register needs it)
    assert not st["errors"], st["errors"]
    assert m.call("lastPrice") > 0

    pk1, pk2 = keccak(text="sa-e2e-alice"), keccak(text="sa-e2e-bob")
    a1, d1 = onboard(fork, k, module, pk1, 3000)
    a2, d2 = onboard(fork, k, module, pk2, 1500, via_dir=k.sa.requests_dir)
    assert usdc.call("balanceOf", a1) == 3000 * E6

    # first tick: relayer onboards client 2 from the request queue; margin, swap, mint for both; one netted short
    st = k.tick()
    assert not st["errors"], st["errors"]
    assert os.listdir(os.path.join(k.sa.requests_dir, "done")) and usdc.call("balanceOf", a2) < 1500 * E6
    for a, usd in ((a1, 3000), (a2, 1500)):
        row = st["accounts"][a]
        assert len(row["positions"]) == 1, row
        assert row["net_margin"] == pytest.approx(usd * 0.25, rel=0.02)
        assert abs(row["value"] - usd) < usd * 0.01
    short = -k.adapter.position()
    led = k.ledger.clients()
    assert short == pytest.approx(led[a1]["short"] + led[a2]["short"], abs=0.02)
    sp = k.r.slot0()[0]
    for a in (a1, a2):  # each client's share = its own HYPE exposure
        s = k.r.account(a)
        expo = (s.lp_amounts(sp)[0] + s.native) / 1e18
        assert led[a]["short"] == pytest.approx(expo, rel=0.10), (a, led[a], expo)  # rehedge drift band
    # leftovers (rounding, the pool moved by the other client's swaps) are deployed within a few ticks; after that
    # a tick is a no-op on chain
    for i in range(4):
        n_actions = len(k.actions)
        trader.move_to(int(hl.mid() * 1e6))
        st = k.tick()
        assert not st["errors"], st["errors"]
        done = [x["fn"] for x in k.actions[n_actions:]]
        print("tick", i, done)
        if done in ([], ["reportPrice"]):
            break
    else:
        raise AssertionError(f"keeper does not converge: {done}")

    # volume -> fees; a week later the HWM fee is charged
    trader.volume(3000, 6)
    trader.move_to(p0)
    fork.advance(7 * 86400 + 60)
    hl.set(fork.now(), p0 / 1e6)
    st = k.tick()
    assert not st["errors"], st["errors"]
    fees = k.state.d.get("fees_by_account", {})
    for a in (a1, a2):
        fees_paid = k.r.account(a).fees_paid
        if fees_paid:
            assert fees.get(a) == fees_paid
    print("fees", {a: v / 1e6 for a, v in fees.items()}, "profit", {a: st["accounts"][a]["profit"] for a in (a1, a2)})

    # client 1 exits with one transaction; the keeper winds its hedge down and pays the margin back INTO the account
    gas = exit_hybrid(fork, k, pk1, a1, d1)
    print("exit gas", gas)
    assert Contract(fork.rpc, DM, DM_ABI).call("disabledDelegations", delegation_hash(d1))
    assert k.r.account(a1).revoked
    assert not m.call("isActive", a1)
    contributed0 = k.r.account(a1).contributed
    before = usdc.call("balanceOf", a1)
    for _ in range(3):
        st = k.tick()
        assert not st["errors"], st["errors"]
    led = k.ledger.clients()[a1]
    assert led["closed"] and led["short"] == pytest.approx(0, abs=1e-9)
    paid = usdc.call("balanceOf", a1) - before
    assert paid == pytest.approx(led["margin_out"] * E6, rel=1e-6)
    assert paid > 3000 * 0.25 * 0.95 * E6
    # net margin is a flow counter: what is left is the client's realised hedge cost (fees), not owed money
    assert k.r.account(a1).net_margin == pytest.approx((led["margin_in"] - led["margin_out"]) * E6, abs=2)
    assert k.r.account(a1).hedge_equity == 0
    # the margin coming back is not a client deposit (SA-1 M-2); what moves `contributed` here is the client's own
    # burn collecting a week of LP fees into idle (booked as a client flow: acknowledged, in the client's favour)
    assert abs(k.r.account(a1).contributed - contributed0) < 0.05 * paid
    assert led["equity"] == pytest.approx(0, abs=1e-6)
    # client 2 untouched and still managed
    assert m.call("isActive", a2) and k.ledger.clients()[a2]["short"] > 0

    # restarted keeper (same state files) picks up the same accounts and does nothing new
    k2 = make_keeper(fork, tmp, module, hl, alerts, name="sa")
    st = k2.tick()
    assert not st["errors"], st["errors"]
    assert [x["fn"] for x in k2.actions] in ([], ["reportPrice"]), k2.actions
