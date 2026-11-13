"""Minimal JSON-RPC + ABI layer (urllib + eth_abi + eth_account). No web3.py.

Safety: transactions are only sent through a Signer. Every signer refuses a non-local RPC unless the config
explicitly sets `allow_live_chain` (the default is local anvil only).
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

UA = "elysium-lp-keeper/0.1 (+python urllib)"
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


class RPCError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(f"rpc error {code}: {message}")
        self.code, self.message, self.data = code, message, data


class TxRevert(Exception):
    def __init__(self, fn, reason, tx_hash=None):
        super().__init__(f"{fn} reverted: {reason}" + (f" (tx {tx_hash})" if tx_hash else ""))
        self.fn, self.reason, self.tx_hash = fn, reason, tx_hash


class LiveChainDisabled(Exception):
    pass


def is_local(url: str) -> bool:
    return (urllib.parse.urlparse(url).hostname or "") in LOCAL_HOSTS


class RPC:
    def __init__(self, url: str, timeout: float = 20.0, retries: int = 3):
        if "alchemy" in url.lower():
            raise ValueError("Alchemy RPC is not allowed (free RPC only)")
        self.url, self.timeout, self.retries = url, timeout, retries
        self._id = 0

    def call(self, method: str, params: list | None = None) -> Any:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or []}).encode()
        last = None
        for i in range(self.retries):
            req = urllib.request.Request(
                self.url, body, {"Content-Type": "application/json", "User-Agent": UA}
            )
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as fh:
                    res = json.load(fh)
                if "error" in res:
                    e = res["error"]
                    raise RPCError(e.get("code"), e.get("message"), e.get("data"))
                return res["result"]
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:  # transport: retry
                last = e
                time.sleep(0.5 * (2 ** i))
        raise ConnectionError(f"rpc {method} failed after {self.retries} tries: {last}")

    # convenience
    def block_timestamp(self) -> int:
        return int(self.call("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)

    def chain_id(self) -> int:
        return int(self.call("eth_chainId"), 16)

    def balance(self, addr: str) -> int:
        return int(self.call("eth_getBalance", [addr, "latest"]), 16)


# ---------------------------------------------------------------- ABI helpers
def _type_str(p: dict) -> str:
    t = p["type"]
    if t.startswith("tuple"):
        return "(" + ",".join(_type_str(c) for c in p["components"]) + ")" + t[5:]
    return t


def _hex(b: bytes) -> str:
    return "0x" + b.hex()


def _unhex(s: str) -> bytes:
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


ERC20_ABI = [
    {"type": "function", "name": "balanceOf", "stateMutability": "view",
     "inputs": [{"name": "a", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"type": "function", "name": "allowance", "stateMutability": "view",
     "inputs": [{"name": "o", "type": "address"}, {"name": "s", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"type": "function", "name": "approve", "stateMutability": "nonpayable",
     "inputs": [{"name": "s", "type": "address"}, {"name": "v", "type": "uint256"}],
     "outputs": [{"name": "", "type": "bool"}]},
    {"type": "function", "name": "transfer", "stateMutability": "nonpayable",
     "inputs": [{"name": "t", "type": "address"}, {"name": "v", "type": "uint256"}],
     "outputs": [{"name": "", "type": "bool"}]},
]
POOL_MANAGER_ABI = [
    {"type": "function", "name": "extsload", "stateMutability": "view",
     "inputs": [{"name": "slot", "type": "bytes32"}], "outputs": [{"name": "", "type": "bytes32"}]},
]
POSM_ABI = [
    {"type": "function", "name": "getPositionLiquidity", "stateMutability": "view",
     "inputs": [{"name": "id", "type": "uint256"}], "outputs": [{"name": "", "type": "uint128"}]},
]


class Contract:
    def __init__(self, rpc: RPC, address: str, abi: list):
        self.rpc, self.address = rpc, to_checksum_address(address)
        self.fns: dict[str, tuple[bytes, list[str], list[str]]] = {}
        self.errors: dict[bytes, tuple[str, list[str]]] = {
            _unhex("0x08c379a0"): ("Error", ["string"]),
            _unhex("0x4e487b71"): ("Panic", ["uint256"]),
        }
        for item in abi:
            if item["type"] == "function":
                ins = [_type_str(p) for p in item["inputs"]]
                outs = [_type_str(p) for p in item.get("outputs", [])]
                sel = keccak(text=f"{item['name']}({','.join(ins)})")[:4]
                self.fns[item["name"]] = (sel, ins, outs)
            elif item["type"] == "error":
                ins = [_type_str(p) for p in item["inputs"]]
                sel = keccak(text=f"{item['name']}({','.join(ins)})")[:4]
                self.errors[sel] = (item["name"], ins)

    def encode(self, fn: str, *args) -> str:
        sel, ins, _ = self.fns[fn]
        return _hex(sel + abi_encode(ins, list(args)))

    def call(self, fn: str, *args, sender: str | None = None, value: int = 0, block="latest"):
        _, _, outs = self.fns[fn]
        tx = {"to": self.address, "data": self.encode(fn, *args)}
        if sender:
            tx["from"] = sender
        if value:
            tx["value"] = hex(value)
        try:
            raw = self.rpc.call("eth_call", [tx, block])
        except RPCError as e:
            raise TxRevert(fn, self.decode_error(e.data) or e.message) from None
        out = abi_decode(outs, _unhex(raw))
        return out[0] if len(out) == 1 else out

    def decode_error(self, data) -> str | None:
        if isinstance(data, dict):
            data = data.get("data")
        if not isinstance(data, str) or len(data) < 10:
            return None
        b = _unhex(data)
        name, ins = self.errors.get(b[:4], (None, None))
        if name is None:
            return data[:74]
        try:
            vals = abi_decode(ins, b[4:])
        except Exception:
            vals = ()
        return f"{name}({', '.join(str(v) for v in vals)})"


# ---------------------------------------------------------------- signers
class Signer:
    address: str

    def send(self, rpc: RPC, tx: dict) -> str:
        raise NotImplementedError


class UnlockedSigner(Signer):
    """eth_sendTransaction from an address the node has unlocked (anvil --auto-impersonate). Local RPC only."""

    def __init__(self, address: str):
        self.address = to_checksum_address(address)

    def send(self, rpc: RPC, tx: dict) -> str:
        if not is_local(rpc.url):
            raise LiveChainDisabled("UnlockedSigner is for a local anvil fork only")
        tx = dict(tx, **{"from": self.address})
        return rpc.call("eth_sendTransaction", [tx])


class KeystoreSigner(Signer):
    """Signs locally with an encrypted keystore (path + password from an env var). The key never leaves memory,
    is never logged. Refuses a non-local RPC unless allow_live_chain is set in the config."""

    def __init__(self, keystore_path: str, password_env: str, chain_id: int, allow_live_chain: bool):
        from eth_account import Account

        with open(keystore_path) as fh:
            ks = json.load(fh)
        pw = os.environ.get(password_env)
        if pw is None:
            raise RuntimeError(f"keystore password env {password_env} not set")
        self._acct = Account.from_key(Account.decrypt(ks, pw))
        self.address = self._acct.address
        self.chain_id, self.allow_live_chain = chain_id, allow_live_chain

    def send(self, rpc: RPC, tx: dict) -> str:
        if not is_local(rpc.url) and not self.allow_live_chain:
            raise LiveChainDisabled("live chain sending disabled (set chain.allow_live_chain=true deliberately)")
        nonce = int(rpc.call("eth_getTransactionCount", [self.address, "pending"]), 16)
        gas_price = int(rpc.call("eth_gasPrice"), 16)
        full = {
            "to": tx["to"], "data": tx["data"], "value": int(tx.get("value", "0x0"), 16),
            "gas": int(tx["gas"], 16), "nonce": nonce, "chainId": self.chain_id,
            "maxFeePerGas": gas_price * 2, "maxPriorityFeePerGas": min(gas_price, 10 ** 9),
        }
        signed = self._acct.sign_transaction(full)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        return rpc.call("eth_sendRawTransaction", [_hex(raw)])


class ReadOnlySigner(Signer):
    """Plan mode: logs the transaction it would send and sends nothing."""

    def __init__(self, address: str, log):
        self.address = to_checksum_address(address)
        self.log = log

    def send(self, rpc: RPC, tx: dict) -> str:
        self.log("would_send_tx", to=tx["to"], data=tx["data"][:138], value=tx.get("value"))
        return ""


class Chain:
    def __init__(self, rpc: RPC, signer: Signer, log, tx_timeout: float = 120.0):
        self.rpc, self.signer, self.log, self.tx_timeout = rpc, signer, log, tx_timeout

    def transact(self, c: Contract, fn: str, *args, value: int = 0) -> dict | None:
        """Simulate (eth_call) first so a revert is reported with its decoded reason without spending gas,
        then send and wait for the receipt."""
        c.call(fn, *args, sender=self.signer.address, value=value)  # raises TxRevert
        tx = {"to": c.address, "data": c.encode(fn, *args), "value": hex(value)}
        try:
            gas = int(self.rpc.call("eth_estimateGas", [dict(tx, **{"from": self.signer.address})]), 16)
        except RPCError as e:
            raise TxRevert(fn, c.decode_error(e.data) or e.message) from None
        tx["gas"] = hex(int(gas * 1.3) + 50_000)
        h = self.signer.send(self.rpc, tx)
        if not h:  # read-only plan mode
            return None
        t0 = time.time()
        while True:
            rc = self.rpc.call("eth_getTransactionReceipt", [h])
            if rc:
                break
            if time.time() - t0 > self.tx_timeout:
                raise TimeoutError(f"{fn} tx {h} not mined in {self.tx_timeout}s")
            time.sleep(0.25)
        if int(rc["status"], 16) != 1:
            raise TxRevert(fn, "status 0", h)
        self.log("tx", fn=fn, hash=h, gas=int(rc["gasUsed"], 16))
        return rc
