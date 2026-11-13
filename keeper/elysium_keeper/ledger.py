"""Per-client hedge ledger over ONE Hyperliquid account.

Every client's hedge (HYPE short) lives in the same HL account; the ledger says which part belongs to whom:

  equity_i = margin sent from the client's account  - margin returned to it
           + short_i x (mark_then - mark_now)      (mark-to-market, every tick)
           - taker fees of the client's own fills  + share of reconciliation (funding, slippage)

Rules:
- Orders are netted across clients (one HL order per tick); a fill is split in proportion to each client's signed
  change, so one client's rebalance never trades on another's account.
- Reconciliation: the difference between the real off-chain capital (treasury + HL equity + in transit) and the sum of
  client equities is spread over clients by short notional (funding, slippage), or by equity if nobody is short.
- The client's on-chain `hedgeEquity` is reported from equity_i (the module lets the keeper lower it within a daily
  budget; an increase needs the guardian).
- A client who exits: target short 0, then its whole equity is paid back with returnHedgeMargin (to the owner EOA
  once the delegation is revoked) and the entry is closed.
The ledger is JSON (atomic write through infra.State) and only ever moved forward by the keeper.
"""
from __future__ import annotations


class HedgeLedger:
    def __init__(self, d: dict):
        self.d = d
        d.setdefault("mark", 0.0)
        d.setdefault("clients", {})
        d.setdefault("history", [])

    # ------------------------------------------------------------ entries
    def client(self, a: str) -> dict:
        c = self.d["clients"].setdefault(a, {})
        for k, v in (("short", 0.0), ("equity", 0.0), ("margin_in", 0.0), ("margin_out", 0.0), ("fees", 0.0),
                     ("pnl", 0.0), ("recon", 0.0), ("target", 0.0), ("closed", False)):
            c.setdefault(k, v)
        return c

    def clients(self) -> dict:
        return self.d["clients"]

    def _hist(self, kind: str, a: str, **kw):
        self.d["history"] = (self.d["history"] + [dict(kind=kind, account=a, **kw)])[-500:]

    # ------------------------------------------------------------ flows
    def margin_sent(self, a: str, usd: float):
        c = self.client(a)
        c["margin_in"] += usd
        c["equity"] += usd
        c["closed"] = False
        self._hist("margin_sent", a, usd=usd)

    def margin_returned(self, a: str, usd: float):
        c = self.client(a)
        c["margin_out"] += usd
        c["equity"] -= usd
        self._hist("margin_returned", a, usd=usd)

    def mark_to_market(self, mid: float):
        m0 = self.d["mark"]
        if m0 and mid:
            for c in self.d["clients"].values():
                pnl = c["short"] * (m0 - mid)
                c["pnl"] += pnl
                c["equity"] += pnl
        self.d["mark"] = mid

    def set_target(self, a: str, short: float):
        self.client(a)["target"] = max(0.0, short)

    def total_short(self) -> float:
        return sum(c["short"] for c in self.d["clients"].values())

    def total_target(self) -> float:
        return sum(c["target"] for c in self.d["clients"].values())

    def allocate_fill(self, filled_short_delta: float, price: float, fee_usd: float):
        """Split a netted fill (positive = more short) over clients by their wanted change (target - short) in the
        same direction; clients moving the other way are netted internally at `price` (no fee)."""
        wants = {a: c["target"] - c["short"] for a, c in self.d["clients"].items()}
        dirn = filled_short_delta or sum(wants.values())
        if dirn == 0:  # wants cancel out exactly: cross everything internally
            for a, w in wants.items():
                self.d["clients"][a]["short"] += w
            return
        same = {a: w for a, w in wants.items() if w * dirn > 0}
        opp = {a: w for a, w in wants.items() if w * dirn < 0}
        # internal crossing: opposite wants are satisfied fully against the same-direction ones
        for a, w in opp.items():
            self.d["clients"][a]["short"] += w
        crossed = -sum(opp.values())  # amount the same-direction side receives from the crossing
        tot_same = sum(same.values())
        if tot_same == 0:
            return
        got = crossed + filled_short_delta
        notional = sum(abs(w) for w in same.values())
        for a, w in same.items():
            c = self.d["clients"][a]
            share = w / tot_same
            c["short"] += got * share
            f = fee_usd * abs(w) / notional if notional else 0.0
            c["fees"] += f
            c["equity"] -= f
        self._hist("fill", "*", delta=filled_short_delta, price=price, fee=fee_usd)

    def reconcile(self, actual_total: float, min_diff: float = 1.0) -> float:
        """Spread (actual - sum of client equities) over open clients. Returns the difference applied."""
        cs = [c for c in self.d["clients"].values() if not c["closed"]]
        if not cs:
            return 0.0
        diff = actual_total - sum(c["equity"] for c in self.d["clients"].values())
        if abs(diff) < min_diff:
            return 0.0
        w = [c["short"] for c in cs]
        if sum(w) <= 0:
            w = [max(c["equity"], 0.0) for c in cs]
        if sum(w) <= 0:
            w = [1.0] * len(cs)
        tw = sum(w)
        for c, wi in zip(cs, w):
            x = diff * wi / tw
            c["recon"] += x
            c["equity"] += x
        self._hist("reconcile", "*", diff=diff)
        return diff

    def release_dust(self, a: str, lot: float) -> float:
        """A residual short below the exchange lot (order rounding) cannot be traded away: hand it to the other open
        clients pro rata to their shorts (at the current mark, so no value moves). Returns the amount released."""
        c = self.client(a)
        x = c["short"]
        if x == 0 or abs(x) >= lot:
            return 0.0
        others = [o for k, o in self.d["clients"].items() if k != a and not o["closed"] and o["short"] > 0]
        tot = sum(o["short"] for o in others)
        if tot <= 0:
            return 0.0
        for o in others:
            o["short"] += x * o["short"] / tot
        c["short"] = 0.0
        self._hist("dust", a, short=x)
        return x

    def equity(self, a: str) -> float:
        return self.client(a)["equity"]

    def close(self, a: str):
        c = self.client(a)
        c["closed"] = True
        self._hist("closed", a, equity=c["equity"], short=c["short"])
