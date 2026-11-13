"""Local anvil fork of Elysium + helpers for the end-to-end keeper test. Nothing leaves the local fork:
anvil runs with --auto-impersonate, so no private keys exist anywhere in the test."""
from __future__ import annotations

import bisect
import json
import math
import os
import socket
import subprocess
import time

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

from elysium_keeper.rpc import ERC20_ABI, RPC, Contract

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
USDC = "0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65"
PM = "0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1"
ZERO = "0x0000000000000000000000000000000000000000"
DEPLOYER = "0x7E7E000000000000000000000000000000000D01"


def addr(tag: int) -> str:
    return to_checksum_address("0x7e7e" + "0" * 32 + "%04x" % tag)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Fork:
    def __init__(self, fork_url: str, block: int | None = None, log_path: str | None = None):
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        cmd = ["anvil", "--fork-url", fork_url, "--port", str(self.port), "--auto-impersonate", "--silent",
               "--chain-id", "99901"]
        if block:
            cmd += ["--fork-block-number", str(block)]
        self.proc = subprocess.Popen(cmd, stdout=open(log_path or os.devnull, "w"), stderr=subprocess.STDOUT)
        self.rpc = RPC(self.url, retries=1)
        for _ in range(120):
            try:
                self.rpc.chain_id()
                break
            except Exception:
                time.sleep(0.5)
        else:
            raise RuntimeError("anvil did not start")
        self.usdc = Contract(self.rpc, USDC, ERC20_ABI)
        self._usdc_slot = None
        self.set_balance(DEPLOYER, 10 ** 22)

    def close(self):
        self.proc.terminate()
        self.proc.wait(10)

    # ---------------------------------------------------------- chain control
    def set_balance(self, a: str, wei: int):
        self.rpc.call("anvil_setBalance", [a, hex(wei)])

    def advance(self, seconds: int):
        self.rpc.call("evm_increaseTime", [hex(seconds)])
        self.rpc.call("evm_mine", [])

    def now(self) -> int:
        return self.rpc.block_timestamp()

    def receipt(self, h):
        for _ in range(400):
            rc = self.rpc.call("eth_getTransactionReceipt", [h])
            if rc:
                return rc
            time.sleep(0.05)
        raise TimeoutError(h)

    def send(self, frm: str, c: Contract, fn: str, *args, value: int = 0):
        tx = {"from": frm, "to": c.address, "data": c.encode(fn, *args), "value": hex(value), "gas": hex(3_000_000)}
        rc = self.receipt(self.rpc.call("eth_sendTransaction", [tx]))
        if int(rc["status"], 16) != 1:
            try:
                c.call(fn, *args, sender=frm, value=value)
            except Exception as e:
                raise RuntimeError(f"{fn} reverted: {e}")
            raise RuntimeError(f"{fn} reverted")
        return rc

    def deploy_bytecode(self, frm: str, bytecode: str, ctor_types=(), ctor_args=()) -> str:
        data = bytecode + abi_encode(list(ctor_types), list(ctor_args)).hex()
        rc = self.receipt(self.rpc.call("eth_sendTransaction", [{"from": frm, "data": data, "gas": hex(8_000_000)}]))
        assert int(rc["status"], 16) == 1
        return to_checksum_address(rc["contractAddress"])

    # ---------------------------------------------------------- USDC
    def deal_usdc(self, who: str, amount: int):
        try:  # anvil >= 1.0 has a native deal
            self.rpc.call("anvil_dealERC20", [who, USDC, hex(amount)])
            if self.usdc.call("balanceOf", who) == amount:
                return
        except Exception:
            pass
        cands = [self._usdc_slot] if self._usdc_slot is not None else list(range(0, 20))
        for slot in cands:
            key = "0x" + keccak(abi_encode(["address", "uint256"], [who, slot])).hex()
            old = self.rpc.call("eth_getStorageAt", [USDC, key, "latest"])
            self.rpc.call("anvil_setStorageAt", [USDC, key, "0x" + amount.to_bytes(32, "big").hex()])
            if self.usdc.call("balanceOf", who) == amount:
                self._usdc_slot = slot
                return
            self.rpc.call("anvil_setStorageAt", [USDC, key, old])
        raise RuntimeError("USDC balance slot not found")

    # ---------------------------------------------------------- deploy via the repo script
    def deploy_vault(self, *, hedged: bool, owner, keeper, guardian, fee_to, treasury, name, symbol) -> str:
        env = dict(os.environ, HEDGE_TREASURY=treasury if hedged else ZERO, HEDGE_CAP_BPS="3500" if hedged else "0",
                   OWNER=owner, KEEPER=keeper, GUARDIAN=guardian, FEE_RECIPIENT=fee_to, NAME=name, SYMBOL=symbol)
        cmd = ["forge", "script", "script/Deploy.s.sol:Deploy", "--rpc-url", self.url, "--broadcast",
               "--unlocked", "--sender", DEPLOYER, "--slow"]
        r = subprocess.run(cmd, cwd=REPO, env=env, capture_output=True, text=True, timeout=900)
        if r.returncode != 0:
            raise RuntimeError("forge script failed:\n" + r.stdout[-3000:] + r.stderr[-3000:])
        run = json.load(open(os.path.join(REPO, "broadcast", "Deploy.s.sol", "99901", "run-latest.json")))
        for tx in run["transactions"]:
            if tx.get("contractName") == "UniV4LPVault":
                return to_checksum_address(tx["contractAddress"])
        raise RuntimeError("vault address not found in broadcast")


class Trader:
    """The repo's fork-test Trader contract: third-party swaps that move the pool (volume / arbitrage / crash)."""

    def __init__(self, fork: Fork, vault: Contract):
        art = json.load(open(os.path.join(REPO, "out", "UniV4LPVault.fork.t.sol", "Trader.json")))
        self.fork, self.vault = fork, vault
        key = (ZERO, USDC, 3000, 60, ZERO)
        self.address = fork.deploy_bytecode(DEPLOYER, art["bytecode"]["object"],
                                            ["address", "(address,address,uint24,int24,address)"], [PM, key])
        self.c = Contract(fork.rpc, self.address, art["abi"])
        fork.deal_usdc(self.address, 50_000_000 * 10 ** 6)
        fork.set_balance(self.address, 1_000_000 * 10 ** 18)

    def price(self) -> int:
        return self.vault.call("poolPrice")

    def swap(self, zero_for_one: bool, amount: int):
        self.fork.send(DEPLOYER, self.c, "swap", zero_for_one, amount)

    def move_to(self, target_p: int, tol: float = 0.0005, depth_usd: float = 280_000):
        """Swap until the pool price is within `tol` of target (keeper units). Adaptive step: halve on overshoot,
        grow while the price barely moves (thin liquidity between ticks)."""
        scale, last_d = 1.0, None
        for _ in range(150):
            p = self.price()
            d = (target_p - p) / p
            if abs(d) <= tol:
                return
            if last_d is not None:
                if (d > 0) != (last_d > 0):
                    scale *= 0.4
                elif abs(d) > 0.7 * abs(last_d):
                    scale = min(scale * 1.5, 20)
            last_d = d
            usd = min(80_000, max(20, depth_usd * abs(d) * scale))
            if d > 0:
                self.swap(False, int(usd * 1e6))  # USDC in -> price up
            else:
                self.swap(True, int(usd / (p / 1e6) * 1e18))  # HYPE in -> price down
        raise RuntimeError("pool did not converge")

    def volume(self, usd: float, rounds: int):
        p = self.price()
        for _ in range(rounds):
            self.swap(False, int(usd * 1e6))
            self.swap(True, int(usd / (p / 1e6) * 1e18))


class MockHL:
    """Stands in for HLInfo: a piecewise-constant HYPE price path keyed on chain time, with candles built from it.
    History is seeded hourly with +-0.1% alternation (daily vol ~1%, so the range clips to the 3% minimum)."""

    def __init__(self, t0: int, p0_usd: float, seed_hours: int = 200):
        self.ts: list[int] = []
        self.ps: list[float] = []
        start = (t0 // 3600 - seed_hours) * 3600
        for i in range(seed_hours):
            self._add(start + i * 3600, p0_usd * (1.001 if i % 2 else 0.999))
        self._add(t0, p0_usd)

    def _add(self, t, p):
        i = bisect.bisect_right(self.ts, t)
        self.ts.insert(i, t)
        self.ps.insert(i, p)

    def set(self, t: int, p_usd: float):
        self._add(t, p_usd)

    def at(self, t: float) -> float:
        i = bisect.bisect_right(self.ts, t) - 1
        return self.ps[max(0, i)]

    def mid(self, coin: str = "HYPE") -> float:
        return self.ps[-1]

    def candles(self, coin, interval, start_ms, end_ms):
        iv = {"5m": 300, "15m": 900, "1h": 3600}[interval]
        out = []
        b = max(start_ms // 1000 // iv * iv, self.ts[0] // iv * iv)
        end = end_ms // 1000
        while b <= end:
            o = self.at(b)
            lo_i, hi_i = bisect.bisect_right(self.ts, b), bisect.bisect_left(self.ts, b + iv)
            inside = self.ps[lo_i:hi_i]
            c = inside[-1] if inside else o
            out.append({"t": b * 1000, "T": (b + iv) * 1000 - 1, "o": str(o), "c": str(c),
                        "h": str(max([o] + inside)), "l": str(min([o] + inside)), "s": coin, "i": interval})
            b += iv
        return out


def assert_close(a, b, rel, msg=""):
    assert math.isclose(a, b, rel_tol=rel), f"{msg}: {a} vs {b} (rel {rel})"
