"""Hyperliquid: read-only info client + pluggable hedge adapters.

- HLInfo: POST /info (allMids, clearinghouseState, spotClearinghouseState, spotMeta, candleSnapshot). Read only.
- DryRunAdapter (default): builds the exact order action the live adapter would sign, LOGS it, and tracks a
  simulated position. Equity is either mocked (margin credited by the operator/test + simulated PnL) or read
  from a real account (read only).
- LiveAdapter: signs IOC limit orders at mark*(1 +- slip) like /opt/mprhedged/hedge.py place(). Disabled unless
  hl.live_enabled=true in the config AND env ELYSIUM_KEEPER_HL_LIVE=I_UNDERSTAND. Not exercised by the tests.

Unified accounts: spot USDC `total` already includes perp unrealized PnL, so equity = spot USDC total + other spot
tokens at mid. Never add uPnL again.
"""
from __future__ import annotations

import json
import os
import time
import urllib.request

from .rpc import UA


class HLInfo:
    def __init__(self, url: str = "https://api.hyperliquid.xyz/info", timeout: float = 15.0):
        self.url, self.timeout = url, timeout

    def _post(self, body: dict):
        req = urllib.request.Request(self.url, json.dumps(body).encode(),
                                     {"Content-Type": "application/json", "User-Agent": UA})
        last = None
        for i in range(3):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as fh:
                    return json.load(fh)
            except Exception as e:  # transport errors: retry
                last = e
                time.sleep(0.5 * (2 ** i))
        raise ConnectionError(f"HL info {body.get('type')} failed: {last}")

    def mid(self, coin: str) -> float:
        return float(self._post({"type": "allMids"})[coin])

    def candles(self, coin: str, interval: str, start_ms: int, end_ms: int) -> list[dict]:
        return self._post({"type": "candleSnapshot",
                           "req": {"coin": coin, "interval": interval, "startTime": start_ms, "endTime": end_ms}})

    def perp_position(self, user: str, coin: str) -> float:
        st = self._post({"type": "clearinghouseState", "user": user})
        for ap in st.get("assetPositions", []):
            p = ap.get("position", {})
            if p.get("coin") == coin:
                return float(p.get("szi", 0))
        return 0.0

    def account_equity(self, user: str) -> float:
        """Unified account equity: spot USDC total (already includes perp uPnL) + other spot tokens at mid."""
        st = self._post({"type": "spotClearinghouseState", "user": user})
        bal = st.get("balances", [])
        eq = sum(float(b["total"]) for b in bal if b["coin"] == "USDC")
        others = [b for b in bal if b["coin"] != "USDC" and float(b["total"]) != 0]
        if others:
            meta = self._post({"type": "spotMeta"})
            mids = self._post({"type": "allMids"})
            pair_of = {}
            for u in meta.get("universe", []):
                base, quote = u["tokens"]
                if quote == 0:
                    pair_of[base] = u["name"]
            for b in others:
                m = mids.get(pair_of.get(b["token"], ""), None)
                if m is not None:
                    eq += float(b["total"]) * float(m)
        return eq


# ---------------------------------------------------------------- order formatting (signature-sensitive)
def num_str(x: float, decimals: int) -> str:
    """Fixed decimals then strip trailing zeros: the action hash is computed over the normalized string."""
    t = ("%." + str(int(decimals)) + "f") % float(x)
    if "." in t:
        t = t.rstrip("0").rstrip(".")
    return t or "0"


def px_str(p: float) -> str:
    """<= 5 significant figures and <= 6 decimals (perp)."""
    s = "%.6f" % float("%.5g" % p)
    return s.rstrip("0").rstrip(".") if "." in s else s


def build_order_action(asset_id: int, is_buy: bool, size: float, mark: float, slip: float, sz_decimals: int,
                       reduce_only: bool) -> dict:
    """IOC limit just through the market. Key order inside the dicts is part of the signature: do not rebuild."""
    limit = mark * (1 + slip) if is_buy else mark * (1 - slip)
    order = {"a": asset_id, "b": bool(is_buy), "p": px_str(limit), "s": num_str(size, sz_decimals),
             "r": bool(reduce_only), "t": {"limit": {"tif": "Ioc"}}}
    return {"type": "order", "orders": [order], "grouping": "na"}


class HedgeAdapter:
    name = "base"

    def position(self) -> float:
        """Signed HYPE perp size (negative = short)."""
        raise NotImplementedError

    def equity(self) -> float:
        raise NotImplementedError

    def place(self, is_buy: bool, size: float, mark: float, reduce_only: bool) -> dict:
        raise NotImplementedError


class DryRunAdapter(HedgeAdapter):
    """Logs intended orders and simulates fills at the limit-free mark with a taker fee.

    sim (persisted in the keeper state file, so a restart sees the same simulated position):
      pos (signed), entry (avg entry px), realized (USD), margin (USD credited as if bridged to HL), fees (USD)
    equity_source: "mock" -> margin + realized - fees + uPnL(sim) ; "account" -> HLInfo.account_equity(account)
    """

    name = "dry_run"

    def __init__(self, cfg, sim: dict, log, info: HLInfo | None = None, mark_fn=None):
        self.cfg, self.sim, self.log, self.info = cfg, sim, log, info
        self.mark_fn = mark_fn
        for k, v in (("pos", 0.0), ("entry", 0.0), ("realized", 0.0), ("margin", 0.0), ("fees", 0.0)):
            self.sim.setdefault(k, v)

    def position(self) -> float:
        return float(self.sim["pos"])

    def equity(self) -> float:
        if self.cfg.equity_source == "account":
            return self.info.account_equity(self.cfg.account)
        mark = self.mark_fn() if self.mark_fn else self.sim["entry"]
        upnl = self.sim["pos"] * (mark - self.sim["entry"])
        return self.sim["margin"] + self.sim["realized"] - self.sim["fees"] + upnl

    def credit_margin(self, usd: float):
        """Operator/test: margin arrived on HL (manual bridge) or left it (negative)."""
        self.sim["margin"] += usd

    def place(self, is_buy: bool, size: float, mark: float, reduce_only: bool) -> dict:
        action = build_order_action(self.cfg.asset_id, is_buy, size, mark, self.cfg.slippage,
                                    self.cfg.sz_decimals, reduce_only)
        self.log("hl_intended_order", adapter=self.name, side="buy" if is_buy else "sell", size=size,
                 mark=mark, action=action)
        # simulated fill at mark
        pos, entry = self.sim["pos"], self.sim["entry"]
        d = size if is_buy else -size
        new = pos + d
        if pos == 0 or (pos > 0) == (d > 0):  # open / add
            self.sim["entry"] = (abs(pos) * entry + size * mark) / abs(new) if new else 0.0
        else:  # reduce / flip
            closed = min(abs(d), abs(pos))
            self.sim["realized"] += closed * (mark - entry) * (1 if pos > 0 else -1)
            if abs(d) > abs(pos):
                self.sim["entry"] = mark
            elif new == 0:
                self.sim["entry"] = 0.0
        self.sim["pos"] = round(new, 8)
        self.sim["fees"] += size * mark * self.cfg.taker_fee
        return {"ok": True, "dry": True, "action": action}


class LiveAdapter(HedgeAdapter):
    """Real orders. Double-gated; requires the `hyperliquid-python-sdk` for sign_l1_action."""

    name = "live"

    def __init__(self, cfg, nonce_state: dict, log, info: HLInfo):
        if not cfg.live_enabled or os.environ.get("ELYSIUM_KEEPER_HL_LIVE") != "I_UNDERSTAND":
            raise PermissionError("live HL adapter disabled: needs hl.live_enabled=true and "
                                  "ELYSIUM_KEEPER_HL_LIVE=I_UNDERSTAND")
        if not cfg.agent_keystore or not cfg.account:
            raise ValueError("live HL adapter needs hl.account and hl.agent_keystore")
        self.cfg, self.nonce_state, self.log, self.info = cfg, nonce_state, log, info
        self._agent = None

    def _account(self):
        if self._agent is None:
            from eth_account import Account

            with open(self.cfg.agent_keystore) as fh:
                ks = json.load(fh)
            pw = os.environ.get(self.cfg.agent_password_env)
            if pw is None:
                raise RuntimeError(f"{self.cfg.agent_password_env} not set")
            self._agent = Account.from_key(Account.decrypt(ks, pw))
        return self._agent

    def position(self) -> float:
        return self.info.perp_position(self.cfg.account, self.cfg.coin)

    def equity(self) -> float:
        return self.info.account_equity(self.cfg.account)

    def place(self, is_buy: bool, size: float, mark: float, reduce_only: bool) -> dict:
        from hyperliquid.utils.signing import sign_l1_action  # optional dependency, live only

        action = build_order_action(self.cfg.asset_id, is_buy, size, mark, self.cfg.slippage,
                                    self.cfg.sz_decimals, reduce_only)
        nonce = max(int(time.time() * 1000), int(self.nonce_state.get("nonce", 0)) + 1)
        self.nonce_state["nonce"] = nonce
        vault = self.cfg.vault_address or None
        sig = sign_l1_action(self._account(), action, vault, nonce, None, True)
        env = {"action": action, "nonce": nonce, "signature": sig, "vaultAddress": vault}
        url = self.cfg.api_url.rsplit("/", 1)[0] + "/exchange"
        req = urllib.request.Request(url, json.dumps(env).encode(),
                                     {"Content-Type": "application/json", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=25) as fh:
            res = json.load(fh)
        statuses = (((res.get("response") or {}).get("data") or {}).get("statuses") or []) \
            if res.get("status") == "ok" else []
        err = None
        if res.get("status") != "ok":
            err = json.dumps(res)[:240]
        elif statuses and isinstance(statuses[0], dict) and statuses[0].get("error"):
            err = str(statuses[0]["error"])
        self.log("hl_order", side="buy" if is_buy else "sell", size=size, px=action["orders"][0]["p"],
                 error=err)
        return {"ok": not err, "error": err, "response": res}
