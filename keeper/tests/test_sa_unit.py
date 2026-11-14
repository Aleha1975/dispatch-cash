"""Unit tests for the smart-account keeper pieces: fee mirror, hedge ledger, EIP-712 payloads, account addresses."""
from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eth_account import Account  # noqa: E402
from eth_account.messages import encode_typed_data  # noqa: E402
from eth_utils import keccak  # noqa: E402

from elysium_keeper import config as C  # noqa: E402
from elysium_keeper.ledger import HedgeLedger  # noqa: E402
from elysium_keeper.sa_chain import (  # noqa: E402
    ACCOUNT_SALT, DM, ENTRYPOINT, SIMPLE_FACTORY, TIMESTAMP_ENFORCER, Delegation, create2_address, delegation_hash,
    delegation_typed_data, dm_domain, hybrid_address, module_delegation, proxy_initcode, typed_digest, userop_digest)
from elysium_keeper.sa_keeper import enforcer_hedge_room, hedge_room, hwm_fee  # noqa: E402

MODULE = "0x00000000000000000000000000000000000000Aa"
ENF = "0x00000000000000000000000000000000000000Bb"
TREAS = "0x00000000000000000000000000000000000000Cc"
FEE = "0x00000000000000000000000000000000000000Dd"


# ---------------------------------------------------------------- fee mirror (SALib.hwmFee)
@pytest.mark.parametrize("profit,hwm,bps,fee,mark", [
    (0, 0, 1500, 0, 0),
    (-50, 0, 1500, 0, 0),
    (1000, 0, 1500, 150, 850),
    (1000, 850, 1500, 22, 978),  # floor(150 * 0.15) = 22
    (800, 850, 1500, 0, 850),  # drawdown below the mark: nothing
    (10 ** 12, -10 ** 6, 2000, (10 ** 12 + 10 ** 6) * 2000 // 10_000, 10 ** 12 - (10 ** 12 + 10 ** 6) // 5),
])
def test_hwm_fee(profit, hwm, bps, fee, mark):
    assert hwm_fee(profit, hwm, bps) == (fee, mark)


def test_hwm_fee_partial_matches_salib():
    # SA-1 L-11: capped at max_fee, the mark advances only by the gain that was charged for
    fee, mark = hwm_fee(10_000, 0, 1500, max_fee=600)
    assert fee == 600 and mark == 600 * 10_000 // 1500 - 600
    assert hwm_fee(10_000, 0, 1500, max_fee=10 ** 9) == hwm_fee(10_000, 0, 1500)
    f2, _ = hwm_fee(10_000 - fee, mark, 1500, max_fee=10 ** 9)  # the rest is charged later, never twice
    assert fee + f2 <= 1500


def test_hwm_fee_never_charges_twice():
    f1, m1 = hwm_fee(10_000, 0, 1500)
    f2, m2 = hwm_fee(10_000 - f1, m1, 1500)  # profit after paying the fee == the mark
    assert f2 == 0 and m2 == m1


def test_hedge_rooms():
    assert hedge_room(10_000, 3500, 1000, 2000) == 1500
    assert hedge_room(10_000, 3500, 4000, 0) == 0
    assert enforcer_hedge_room(1000) == 350
    assert enforcer_hedge_room(1000, 35 * 10 ** 16) == 0


# ---------------------------------------------------------------- ledger
def test_ledger_mtm_fills_and_crossing():
    L = HedgeLedger({})
    L.margin_sent("A", 1000)
    L.margin_sent("B", 500)
    L.mark_to_market(40.0)
    L.set_target("A", 10)
    L.set_target("B", 5)
    L.allocate_fill(15, 40.0, 0.3)
    assert L.client("A")["short"] == pytest.approx(10)
    assert L.client("B")["short"] == pytest.approx(5)
    assert L.client("A")["fees"] == pytest.approx(0.2)
    # price drops 2 USD: shorts earn
    L.mark_to_market(38.0)
    assert L.equity("A") == pytest.approx(1000 - 0.2 + 20)
    assert L.equity("B") == pytest.approx(500 - 0.1 + 10)
    # A wants +4, B wants -4: crossed internally, no order, no fee
    L.set_target("A", 14)
    L.set_target("B", 1)
    L.allocate_fill(0.0, 38.0, 0.0)
    assert L.client("A")["short"] == pytest.approx(14)
    assert L.client("B")["short"] == pytest.approx(1)
    assert L.total_short() == pytest.approx(15)
    # A wants +6, B wants -1: net +5 rounded to 4.9 on HL
    L.set_target("A", 20)
    L.set_target("B", 0)
    L.allocate_fill(4.9, 38.0, 0.1)
    assert L.client("B")["short"] == pytest.approx(0)
    assert L.client("A")["short"] == pytest.approx(19.9)
    assert L.total_short() == pytest.approx(19.9)
    assert L.client("B")["fees"] == pytest.approx(0.1)  # unchanged: B was crossed, not filled


def test_ledger_reconcile_and_close():
    L = HedgeLedger({})
    L.margin_sent("A", 1000)
    L.margin_sent("B", 1000)
    L.set_target("A", 30)
    L.set_target("B", 10)
    L.allocate_fill(40, 40.0, 0.0)
    d = L.reconcile(2000 - 8)  # funding paid: 8 USD, by short notional
    assert d == pytest.approx(-8)
    assert L.equity("A") == pytest.approx(994)
    assert L.equity("B") == pytest.approx(998)
    L.margin_returned("B", 998)
    L.close("B")
    assert L.client("B")["closed"]
    # closed clients take no further reconciliation
    L.reconcile(994 + 0 + 4)
    assert L.equity("B") == pytest.approx(0)
    assert L.equity("A") == pytest.approx(998)


# ---------------------------------------------------------------- EIP-712 / addresses
def test_delegation_typed_data_matches_struct_hash():
    d = module_delegation("0x1111111111111111111111111111111111111111", MODULE, ENF, TREAS, FEE, 1_800_000_000)
    assert d.caveats[1][0] == TIMESTAMP_ENFORCER
    td = delegation_typed_data(d, 99901)
    msg = encode_typed_data(full_message=td)
    independent = keccak(b"\x19" + msg.version + msg.header + msg.body)
    assert independent == typed_digest(dm_domain(99901), delegation_hash(d))
    # args and signature are not part of the hash
    d2 = Delegation.from_json(d.to_json())
    d2.signature = b"\x01" * 65
    assert delegation_hash(d2) == delegation_hash(d)


def test_signature_recovers():
    acct = Account.from_key(keccak(text="unit-alice"))
    d = module_delegation(hybrid_address(acct.address), MODULE, ENF, TREAS, FEE, 1_800_000_000)
    digest = typed_digest(dm_domain(99901), delegation_hash(d))
    sig = Account.unsafe_sign_hash(digest, acct.key)
    assert Account._recover_hash(digest, signature=sig.signature) == acct.address


def test_hybrid_address_is_create2_of_factory():
    owner = "0x2222222222222222222222222222222222222222"
    code = proxy_initcode(owner)
    assert hybrid_address(owner) == create2_address(SIMPLE_FACTORY, ACCOUNT_SALT, keccak(code))
    assert hybrid_address(owner) != hybrid_address("0x3333333333333333333333333333333333333333")
    assert code[-4 - 0:] != b""  # initcode carries initialize(owner, [], [], [])
    assert bytes.fromhex(owner[2:]) in code


def test_userop_digest_depends_on_account_and_chain():
    op = dict(sender="0x4444444444444444444444444444444444444444", nonce=0, initCode=b"", callData=b"\x12",
              accountGasLimits=b"\0" * 32, preVerificationGas=0, gasFees=b"\0" * 32, paymasterAndData=b"")
    a = userop_digest(op, 99901)
    assert a != userop_digest(op, 1)
    assert a != userop_digest(dict(op, sender="0x5555555555555555555555555555555555555555"), 99901)
    assert ENTRYPOINT and DM


def test_config_sa_section():
    c = C.from_dict({"sa": {"module": MODULE, "accounts": ["0x1"], "stagger_s": 0}})
    assert c.sa.module == MODULE and c.sa.stagger_s == 0
    with pytest.raises(ValueError):
        C.from_dict({"sa": {"modul": MODULE}})


# ---------------------------------------------------------------- SA-3 price-trust mirrors (LPManagerModule._trusted)
def _g(**kw):
    from elysium_keeper.sa_chain import GlobalSnap, PARAM_KEYS
    params = dict(zip(PARAM_KEYS, [1500, 3500, 150, 150, 500, 1000, 20000, 7 * 86400, 3600, 300]))
    base = dict(last_price=40_000_000, last_price_time=1_000, clipped=False, paused=False, pool_price=40_000_000,
                sqrt_price=0, tick=0, params=params, price_budget={}, treasury=TREAS, fee_recipient=FEE,
                last_price_moved=700)
    base.update(kw)
    return GlobalSnap(**base)


def test_trusted_needs_stable_recent_and_book_band():
    assert _g().trusted(1_000)
    assert not _g(last_price_moved=900).trusted(1_000)  # moved less than minPriceStable ago
    assert not _g().trusted(1_301)  # no confirmation within the last minPriceStable
    assert _g(pool_price=40_190_000).trusted(1_000)  # 47 bps off: inside BOOK_BAND_BPS
    assert not _g(pool_price=40_250_000).trusted(1_000)  # 62 bps: fresh (poolBand 150) but not trusted
    assert _g(pool_price=40_250_000).fresh(1_000)


def test_fee_gate_and_trailing_low():
    from elysium_keeper.sa_chain import ModuleReader
    lo = ModuleReader.trailing_low(40_000_000, 2 * 10**16)  # range (hi - lo) / lo = 2%
    assert lo == 39_215_686
    assert not _g(trailing_low=lo).fee_gate()  # anchor 2% above the low > poolBandBps 1.5%
    assert _g(trailing_low=39_500_000).fee_gate()
    assert not _g(pool_price=39_990_000).fee_gate()  # anchor above the pool
