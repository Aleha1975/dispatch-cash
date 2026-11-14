"""Keeper for per-client smart accounts (LPManagerModule). One process, one keeper key, many accounts.

Tick:
  1. global: HL mid -> price choice (same rules as the vault keeper) -> report the anchor when it lags or is old;
     mark the hedge ledger to market.
  2. accounts: discover (static list + Registered events), then for EACH account, re-read its state from the chain
     (never from memory) and run, staggered by `sa.stagger_s` after any account that sent a transaction:
       exited (revoked / disabled / expired / code or owner changed): close its hedge share, pay its hedge equity
         back INTO THE ACCOUNT (the keeper may return at most the on-chain hedge equity; the rest is the treasury's);
       live: hedge margin first (the enforcer caps margin at 35%/day of IDLE USDC, so it goes out before the LP add)
             -> LP: burn out-of-range positions, deploy idle funds (swap to the range's split, mint / increase)
             -> fee when due (HWM, frees idle USDC first: the enforcer caps a fee at 20% of idle)
             -> hedge target for this client -> on-chain hedge equity from the ledger (lower only; increases need
                the guardian's per-account approval, the keeper alerts).
  3. one netted HL order for all clients, fills split by the ledger; reconcile the ledger with the real off-chain
     capital (treasury + HL equity + in transit).
Restart safety: every action is recomputed from a fresh read; the state file holds the ledger, the dry-run HL
simulation, the event-scan cursor and fee records.
"""
from __future__ import annotations

import json
import os
import signal
import threading
import time

from eth_utils import to_checksum_address

from . import strategy as S
from . import v4math as M
from .config import Config
from .hl import DryRunAdapter, HLInfo, LiveAdapter
from .infra import Alerts, Log, State, StatusServer
from .ledger import HedgeLedger
from .rpc import RPC, Chain, KeystoreSigner, ReadOnlySigner, TxRevert, UnlockedSigner, is_local
from .sa_chain import AccountSnap, GlobalSnap, ModuleReader

BPS = 10_000
E18 = 10 ** 18


def hwm_fee(profit: int, hwm: int, fee_bps: int, max_fee: int | None = None) -> tuple[int, int]:
    """Mirror of SALib.hwmFee: (fee, new mark). A fee above `max_fee` (20% of idle USDC) is charged partially and
    the mark advances only by the gain it charged for."""
    if profit <= hwm or fee_bps == 0:
        return 0, hwm
    fee = (profit - hwm) * fee_bps // BPS
    if max_fee is None or fee <= max_fee:
        return fee, profit - fee
    return max_fee, hwm + max_fee * BPS // fee_bps - max_fee


def hedge_room(value: int, cap_bps: int, hedge_equity: int, net_margin: int) -> int:
    """sendHedgeMargin: max(hedgeEquity, netMargin) + amount <= cap x accountValue."""
    return max(0, value * cap_bps // BPS - max(hedge_equity, net_margin))


def enforcer_hedge_room(idle_usdc: int, used_wad: int = 0) -> int:
    """ElysiumCustodyEnforcer: transfers to the treasury <= 35% of the account's idle USDC per sliding 24 h window
    (SAWindow: capacity returns 24-27 h after a send)."""
    return max(0, idle_usdc * (35 * 10 ** 16 - used_wad) // E18)


class SAKeeper:
    def __init__(self, cfg: Config, *, hl_info=None, adapter=None, signer=None, alert_sink=None, log=None, rpc=None,
                 sleep=time.sleep):
        self.cfg, self.st, self.sa = cfg, cfg.strategy, cfg.sa
        self.log = log or Log(cfg.log_path, cfg.name)
        self.rpc = rpc or RPC(cfg.chain.rpc_url)
        cid = self.rpc.chain_id()
        if cid != cfg.chain.chain_id:
            raise ValueError(f"chain id {cid} != configured {cfg.chain.chain_id}")
        if not is_local(cfg.chain.rpc_url) and cfg.chain.signer != "readonly" and not cfg.chain.allow_live_chain:
            raise PermissionError("non-local RPC: use signer=readonly or set chain.allow_live_chain deliberately")
        if not self.sa.module:
            raise ValueError("sa.module not configured")
        self.r = ModuleReader(self.rpc, self.sa.module)
        self.chain = Chain(self.rpc, signer or self._make_signer(), self.log, cfg.chain.tx_timeout_s)
        if to_checksum_address(self.r.m.call("keeper")) != self.chain.signer.address:
            raise ValueError(f"signer {self.chain.signer.address} is not the module keeper")
        self.state = State(cfg.state_path)
        self._ledger_state = None
        if self.sa.ledger_path and self.sa.ledger_path != cfg.state_path:
            self._ledger_state = State(self.sa.ledger_path)
            self.ledger = HedgeLedger(self._ledger_state.d)
        else:
            self.ledger = HedgeLedger(self.state.d.setdefault("ledger", {}))
        self._sent = 0
        self.alert = Alerts(cfg.alerts, self.log, cfg.name, sink=alert_sink)
        self.info = hl_info or HLInfo(cfg.hl.api_url)
        self.adapter = adapter
        if self.adapter is None:
            if cfg.hl.adapter == "live":
                self.adapter = LiveAdapter(cfg.hl, self.state.d.setdefault("hl_nonce", {}), self.log, self.info)
            else:
                self.adapter = DryRunAdapter(cfg.hl, self.state.d.setdefault("hl_sim", {}), self.log, self.info,
                                             mark_fn=lambda: self.info.mid(cfg.hl.coin))
        if isinstance(self.adapter, DryRunAdapter):
            self.adapter.sim = self.state.d.setdefault("hl_sim", self.adapter.sim)
        self.sleep = sleep
        self._vol = None
        self.lock = threading.Lock()
        self.status: dict = {"ok": False, "module": self.r.m.address, "name": cfg.name, "accounts": {}}
        self.actions: list[dict] = []
        self.stop = False
        self.server = None

    def _make_signer(self):
        c = self.cfg.chain
        if c.signer == "unlocked":
            return UnlockedSigner(c.keeper)
        if c.signer == "keystore":
            return KeystoreSigner(c.keystore_path, c.keystore_password_env, c.chain_id, c.allow_live_chain)
        if c.signer == "readonly":
            return ReadOnlySigner(c.keeper, self.log)
        raise ValueError(f"unknown signer {c.signer}")

    # ------------------------------------------------------------ helpers
    def now(self) -> int:
        return self.rpc.block_timestamp()

    def act(self, fn: str, *args, **kw):
        rc = self.chain.transact(self.r.m, fn, *args, **kw)
        self._sent += 1
        rec = {"ts": self.now(), "fn": fn, "args": [str(a) for a in args], "tx": (rc or {}).get("transactionHash")}
        self.actions = (self.actions + [rec])[-60:]
        return rc

    def probe(self, fn: str, *args) -> str | None:
        """eth_call as the keeper; returns the decoded revert reason or None."""
        try:
            self.r.m.call(fn, *args, sender=self.chain.signer.address)
            return None
        except TxRevert as e:
            return e.reason

    def half_width(self, now: int, mid_usd: float) -> float:
        if self._vol and 0 <= now - self._vol[0] < self.st.vol_refresh_s and abs(mid_usd / self._vol[2] - 1) < 0.01:
            return self._vol[1]
        hrs = self.st.vol_lookback_h + 3
        cs = self.info.candles(self.cfg.hl.coin, "1h", (now - hrs * 3600) * 1000, now * 1000)
        vol = S.realized_daily_vol([float(c["c"]) for c in cs], self.st.vol_lookback_h)
        hw = S.range_half_width(vol, self.st.k_vol, self.st.min_half_width, self.st.max_half_width)
        self._vol = (now, hw, mid_usd)
        return hw

    def offchain_capital(self, g: GlobalSnap) -> float:
        """USD: treasury USDC + HL equity + operator-declared in transit (the whole hedge book of all clients)."""
        return (g.treasury_usdc + int(self.state.d.get("in_transit_usdc", 0))) / 1e6 + self.adapter.equity()

    def accounts(self) -> list[str]:
        out = [to_checksum_address(a) for a in self.sa.accounts]
        if self.sa.discover_from_block:
            cur = int(self.state.d.get("scan_from", self.sa.discover_from_block))
            head = int(self.rpc.call("eth_blockNumber"), 16)
            if cur <= head:
                found = self.r.discover(cur, head)
                known = self.state.d.setdefault("known_accounts", [])
                for a in found:
                    if a not in known:
                        known.append(a)
                        self.log("account_discovered", account=a)
                self.state.d["scan_from"] = head + 1
            out += [a for a in self.state.d.get("known_accounts", []) if a not in out]
        return out

    # ------------------------------------------------------------ global price
    def anchor(self, now: int) -> tuple[int | None, GlobalSnap]:
        g = self.r.global_snap()
        hl = M.usd_to_p(self.info.mid(self.cfg.hl.coin))
        pc = S.choose_price(hl, g.pool_price, g.params["poolBandBps"], self.st.band_safety, self.st.max_clamp_dev_bps)
        self.status["price"] = {"hl": hl / 1e6, "pool": g.pool_price / 1e6, "status": pc.status,
                                "dev_bps": round(pc.dev_bps, 1), "anchor": g.last_price / 1e6}
        if pc.status == "skip":
            self.alert("warn", "price_skip", f"pool {g.pool_price / 1e6:.4f} vs HL {hl / 1e6:.4f} differ "
                                             f"{pc.dev_bps:.0f} bps; skipping risk-adding actions this tick")
            return None, g
        price = S.sticky_price(pc.price, g.last_price, g.pool_price, g.params["poolBandBps"],
                               self.st.anchor_hysteresis_bps, self.st.band_safety)
        stale = now - g.last_price_time >= min(self.sa.report_every_s, g.params["maxPriceAge"] // 2)
        if price != g.last_price or stale or g.clipped:
            self.act("reportPrice", price)
            g = self.r.global_snap()
            if g.clipped:
                self.alert("warn", "anchor_budget", f"anchor clipped at {g.last_price / 1e6:.4f} (wanted "
                                                    f"{price / 1e6:.4f}); guardian: approvePrice(lo, hi, deadline)")
        return price, g

    # ------------------------------------------------------------ per account
    def account_tick(self, a: str, price: int | None, g: GlobalSnap, now: int, hw: float):
        s = self.r.account(a)
        if not s.active:
            self.wind_down(s, g)
            return s
        led = self.ledger.client(a)
        if price is None:
            led["target"] = led["short"]  # keep the hedge as is while prices disagree
            return s
        if not g.paused:
            self.margin(s, g, price)
            self.manage_lp(a, g, price, hw)
            self.fee(a, g, now)
        s = self.r.account(a)
        lp_b, _ = s.lp_amounts(self.r.slot0()[0])
        self.ledger.set_target(a, (lp_b + s.native) / E18 * self.st.hedge_ratio)
        self.report_equity(s)
        return s

    def margin(self, s: AccountSnap, g: GlobalSnap, price: int):
        target = int(s.value * self.sa.margin_frac)
        have = max(s.hedge_equity, s.net_margin)
        want = target - have
        if want < self.st.min_margin_move_usd * 1e6:
            return
        room = min(hedge_room(s.value, g.params["hedgeCapBps"], s.hedge_equity, s.net_margin),
                   enforcer_hedge_room(s.usdc) * 95 // 100)
        amt = min(want, room)
        if amt < self.st.min_margin_move_usd * 1e6:
            self.log("margin_short", account=s.address, want=want / 1e6, room=room / 1e6)
            return
        why = self.probe("sendHedgeMargin", s.address, amt)
        if why is not None:
            self.log("margin_probe_revert", account=s.address, reason=why, usdc=amt / 1e6)
            return
        self.act("sendHedgeMargin", s.address, amt)
        self.ledger.margin_sent(s.address, amt / 1e6)
        self.log("margin_sent", account=s.address, usdc=amt / 1e6)
        self.alert("info", "margin_bridge", "MANUAL: bridge treasury USDC to the HL hedge account when it exceeds "
                                            "the HL margin target (all clients share one HL account)")

    def swap(self, a: str, sell_base: bool, amount: int, price: int) -> int:
        p_usd = M.p_to_usd(price)
        chunk_max = int(self.st.swap_chunk_usd / p_usd * E18) if sell_base else int(self.st.swap_chunk_usd * 1e6)
        min_amt = int(self.st.min_swap_usd / p_usd * E18) if sell_base else int(self.st.min_swap_usd * 1e6)
        done, dev = 0, self.st.max_adverse_dev_bps
        while amount - done > min_amt:
            pool = self.r.m.call("poolPrice")
            if (sell_base and pool * BPS < price * (BPS - dev)) or (not sell_base and pool * BPS > price * (BPS + dev)):
                self.log("swap_paused_adverse_dev", account=a, pool=pool, price=price)
                break
            chunk = min(amount - done, chunk_max)
            while True:
                why = self.probe("swap", a, sell_base, chunk, price)
                if why is None:
                    break
                if "BelowMinOut" in why and chunk > 2 * min_amt:
                    chunk //= 2
                    continue
                self.log("swap_probe_revert", account=a, reason=why, chunk=chunk)
                return done
            self.act("swap", a, sell_base, chunk, price)
            done += chunk
        return done

    def manage_lp(self, a: str, g: GlobalSnap, price: int, hw: float):
        s = self.r.account(a)
        sp, tick = self.r.slot0()
        if s.positions and not any(S.in_range(tick, p.tl, p.tu) for p in s.positions):
            for p in s.positions:
                x, y = M.amounts_for_liquidity(sp, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu), p.liquidity)
                k = BPS - self.st.burn_slippage_bps
                self.act("burnPosition", a, p.token_id, x * k // BPS, y * k // BPS)
                self.log("burned", account=a, token_id=p.token_id, why="out_of_range")
            s = self.r.account(a)
        # swaps and adds must quote within the band of the anchor
        if abs(price - g.last_price) * BPS > g.last_price * g.params["poolBandBps"] * self.st.band_safety:
            self.log("deploy_skipped_anchor", account=a)
            return
        pos = s.positions[0] if s.positions else None
        tl, tu = (pos.tl, pos.tu) if pos else S.range_ticks(price, hw)
        buffer = s.value * self.sa.buffer_bps // BPS
        margin_left = max(0, int(s.value * self.sa.margin_frac) - max(s.hedge_equity, s.net_margin))
        free = max(0, s.usdc - buffer - margin_left)
        hv = s.native * price // E18
        v = free + hv
        if v < self.sa.min_deploy_usd * 1e6:
            return
        f = M.base_value_fraction(sp, tl, tu)
        target_hv = int(f * v)
        if hv < target_hv - self.st.min_swap_usd * 1e6:
            self.swap(a, False, target_hv - hv, price)
        elif hv > target_hv + self.st.min_swap_usd * 1e6:
            self.swap(a, True, (hv - target_hv) * E18 // price, price)
        s = self.r.account(a)
        sp, _ = self.r.slot0()
        a0, a1 = s.native, max(0, s.usdc - buffer - margin_left)
        sa_, sb = M.sqrt_price_at_tick(tl), M.sqrt_price_at_tick(tu)
        liq = M.liquidity_for_amounts(sp, sa_, sb, a0 * 995 // 1000, a1 * 995 // 1000)
        u0, u1 = M.amounts_for_liquidity(sp, sa_, sb, liq)
        val = u0 * price // E18 + u1
        if liq <= 0 or val < self.sa.min_deploy_usd * 1e6:
            return
        # sliding 24 h window (SAWindow): capacity returns 24-27 h after use, no decay
        room = max(0, s.value * g.params["swapTurnoverBps"] // BPS - s.windows["turnoverUsed"])
        charge = S.add_charge(val, g.params["poolBandBps"], g.params["maxSlippageBps"])
        if charge > room * 0.98:
            k = room * 0.98 / charge if charge else 0.0
            if val * k < self.sa.min_deploy_usd * 1e6:
                self.log("deploy_postponed_turnover", account=a, room=room / 1e6)
                return
            liq = int(liq * k)
        if pos is None:
            self.act("mintPosition", a, tl, tu, liq, a0, a1, price)
            self.log("minted", account=a, tl=tl, tu=tu, liquidity=liq, value_usd=val / 1e6)
        else:
            self.act("increasePosition", a, pos.token_id, liq, a0, a1, price)
            self.log("increased", account=a, token_id=pos.token_id, liquidity=liq)

    def fee(self, a: str, g: GlobalSnap, now: int):
        s = self.r.account(a)
        if now < s.last_fee_time + g.params["feeInterval"]:
            return
        if g.clipped or now - g.last_price_time > g.params["maxPriceAge"]:
            self.log("fee_waits_price", account=a)
            return
        if s.hedge_equity and (s.hedge_clipped or now - s.hedge_time > g.params["maxPriceAge"]):
            self.report_equity(s, refresh=True)  # chargeFee needs a recent, unclipped hedge report (SA-1 L-12)
            s = self.r.account(a)
            if s.hedge_clipped:
                self.log("fee_waits_hedge", account=a)
                return
        fee, new_hwm = hwm_fee(s.profit, s.hwm, g.params["feeBps"])
        if fee <= 0:
            return
        need = int(fee * 5 * self.sa.fee_idle_margin) + 1
        if s.usdc < need and s.positions:
            sp, _ = self.r.slot0()
            p = s.positions[0]
            _, y = M.amounts_for_liquidity(sp, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu), p.liquidity)
            if y > 0:
                q = min(1.0, (need - s.usdc) * 1.05 / y)
                self.act("decreasePosition", a, p.token_id, int(p.liquidity * q), 0, 0)
                s = self.r.account(a)
        if s.usdc * 2000 < fee * BPS:  # charged partially (20% of idle); the mark advances only by that part
            self.log("fee_partial", account=a, fee=fee / 1e6, idle=s.usdc / 1e6)
        self.act("chargeFee", a)
        s2 = self.r.account(a)
        charged = s2.fees_paid - s.fees_paid
        rec = {"ts": now, "account": a, "fee": charged, "profit": s.profit, "hwm_before": s.hwm, "hwm": s2.hwm}
        self.state.d["fees"] = (self.state.d.get("fees", []) + [rec])[-1000:]
        tot = self.state.d.setdefault("fees_by_account", {})
        tot[a] = tot.get(a, 0) + charged
        self.log("fee_charged", **rec)

    def report_equity(self, s: AccountSnap, refresh: bool = False):
        """On-chain hedgeEquity follows the ledger: lowered by the keeper (sliding 24 h budget, nothing while paused or
        on a stale anchor), raised only with the guardian's one-shot approval for this account's exact epoch and
        stored value. `refresh`: report even when unchanged (refreshes the report time the fee needs)."""
        v = max(0, int(self.ledger.equity(s.address) * 1e6))
        old = s.hedge_equity
        if abs(v - old) < max(10 ** 6, old // 200):
            if refresh:
                self.act("reportHedgeEquity", s.address, old)
            return
        b = s.budgets
        if v > old:
            ap, ep, until = b["hedgeApproved"], b["hedgeApprovedEpoch"], b["hedgeApprovedUntil"]
            if ep == s.hedge_epoch + 1 and self.now() <= until and ap <= v:
                self.act("reportHedgeEquity", s.address, ap)
                return
            self.alert("warn", f"hedge_eq_{s.address}",
                       f"hedge equity of {s.address}: ledger {v / 1e6:.2f} > on-chain {old / 1e6:.2f}; guardian: "
                       f"approveHedgeEquity({s.address}, {s.hedge_epoch}, {old}, {v}, <until <= 1 day>)")
            if refresh:
                self.act("reportHedgeEquity", s.address, old)
            return
        self.act("reportHedgeEquity", s.address, v)

    def wind_down(self, s: AccountSnap, g: GlobalSnap):
        a = s.address
        led = self.ledger.clients().get(a)
        if led is None or led["closed"]:
            return
        led["target"] = 0.0
        self.ledger.release_dust(a, 10 ** -self.cfg.hl.sz_decimals)
        if led["short"] > 1e-9:
            return  # the netted order this tick closes it; margin goes back on a later tick
        eq = int(max(0.0, led["equity"]) * 1e6)
        if eq < 10 ** 6:
            if s.hedge_equity:  # nothing left off-chain: write the on-chain residue down (a keeper-only decrease)
                self.act("reportHedgeEquity", a, 0)
            self.ledger.close(a)
            self.log("client_closed", account=a)
            return
        avail = min(g.treasury_usdc, g.treasury_allowance)
        # SA-1 H-1: the keeper may return at most the account's on-chain hedge equity; always into the account
        amt = min(eq, avail, s.hedge_equity)
        if amt >= 10 ** 6:
            self.act("returnHedgeMargin", a, amt)
            self.ledger.margin_returned(a, amt / 1e6)
            self.log("margin_returned", account=a, to=a, usdc=amt / 1e6)
        if eq - amt >= 10 ** 6:
            why = "on-chain hedge equity is lower: the treasury itself calls returnHedgeMargin" \
                if s.hedge_equity < eq else "withdraw from HL to the treasury first"
            self.alert("warn", f"exit_margin_{a}", f"MANUAL: {(eq - amt) / 1e6:.2f} USDC of exited client {a} still "
                                                   f"to return into the account ({why})")

    # ------------------------------------------------------------ hedge (netted)
    def hedge(self, now: int):
        mid = self.info.mid(self.cfg.hl.coin)
        target = self.ledger.total_target()
        cur = -self.adapter.position()
        last = int(self.state.d.get("last_hedge_ts", 0))
        d = S.hedge_decision(target, cur, mid, now, last, self.st.rehedge_drift, self.st.rehedge_interval_s,
                             self.cfg.hl.min_order_usd, self.cfg.hl.sz_decimals)
        filled = 0.0
        if d.act:
            fees0 = float(self.adapter.sim.get("fees", 0.0)) if isinstance(self.adapter, DryRunAdapter) else None
            res = self.adapter.place(d.is_buy, d.size, mid, d.reduce_only)
            self.state.d["last_hedge_ts"] = now
            if res.get("ok"):
                filled = -self.adapter.position() - cur
                fee = (float(self.adapter.sim["fees"]) - fees0) if fees0 is not None else abs(filled) * mid * \
                    self.cfg.hl.taker_fee
                self.ledger.allocate_fill(filled, mid, fee)
            else:
                self.alert("warn", "hedge_order_failed", f"HL order failed: {res.get('error')}")
            self.log("rehedge", reason=d.reason, target=target, before=cur, filled=filled, ok=res.get("ok"))
        else:
            self.ledger.allocate_fill(0.0, mid, 0.0)  # internal crossing only
        self.status["hedge"] = {"target_short": round(target, 4), "short": -self.adapter.position(),
                                "ledger_short": round(self.ledger.total_short(), 4), "adapter": self.adapter.name}

    # ------------------------------------------------------------ relayer queue
    def process_requests(self):
        """Onboarding requests dropped by the web backend into sa.requests_dir (*.json): each is checked, simulated
        and sent (Relayer), then moved to done/ or failed/ with the outcome. Needs an anchor (first tick reports)."""
        d = self.sa.requests_dir
        if not d or not os.path.isdir(d):
            return
        from .sa_chain import Relayer

        rel = Relayer(self.r, self.chain, self.cfg.chain.chain_id, self.log)
        for name in sorted(os.listdir(d)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(d, name)
            try:
                with open(path) as fh:
                    req = json.load(fh)
                acct, _ = rel.onboard(req)
                out, res = "done", {"account": acct}
            except Exception as e:  # bad signature, expired permit, already registered...
                out, res = "failed", {"error": str(e)}
                self.alert("warn", f"onboard_{name}", f"onboarding request {name} failed: {e}")
            os.makedirs(os.path.join(d, out), exist_ok=True)
            with open(os.path.join(d, out, name), "w") as fh:
                json.dump({"request": req if out == "done" else None, "result": res}, fh)
            os.remove(path)

    # ------------------------------------------------------------ tick
    def tick(self) -> dict:
        t0 = time.time()
        now = self.now()
        errors: list[str] = []
        self.ledger.mark_to_market(self.info.mid(self.cfg.hl.coin))
        price, g = self.anchor(now)
        try:
            self.process_requests()
        except Exception as e:
            errors.append(f"relayer: {e}")
        hw = self.half_width(now, self.info.mid(self.cfg.hl.coin))
        rows = {}
        for a in self.accounts():
            self._sent = 0
            try:
                s = self.account_tick(a, price, g, now, hw)
                rows[a] = {"owner": s.owner, "kind": s.kind, "active": s.active, "revoked": s.revoked,
                           "until": s.until, "value": s.value / 1e6, "usdc": s.usdc / 1e6,
                           "hype": s.native / 1e18, "positions": [vars(p) for p in s.positions],
                           "contributed": s.contributed / 1e6, "profit": s.profit / 1e6, "hwm": s.hwm / 1e6,
                           "fees_paid": s.fees_paid / 1e6, "hedge_equity": s.hedge_equity / 1e6,
                           "net_margin": s.net_margin / 1e6, "ledger": dict(self.ledger.clients().get(a, {}))}
            except Exception as e:  # one account never blocks the others
                errors.append(f"{a}: {e}")
                self.log("account_failed", account=a, error=str(e))
                self.alert("warn", f"account_{a}", f"{a}: {e}")
            g = self.r.global_snap()
            if self._sent and self.sa.stagger_s:
                self.sleep(self.sa.stagger_s)
        try:
            self.hedge(now)
            g = self.r.global_snap()
            diff = self.ledger.reconcile(self.offchain_capital(g))
            if abs(diff) > 1:
                self.log("ledger_reconciled", diff=diff)
        except Exception as e:
            errors.append(f"hedge: {e}")
            self.log("hedge_failed", error=str(e))
        self.state.d["last_tick"] = now
        self.state.save()
        if self._ledger_state is not None:
            self._ledger_state.save()
        with self.lock:
            self.status.update({"ok": not errors, "errors": errors, "accounts": rows, "paused": g.paused,
                                "tick_seconds": round(time.time() - t0, 2), "last_tick_wall": int(time.time()),
                                "actions": self.actions[-20:], "alerts": self.alert.recent[-15:]})
        try:
            self.write_status_file(rows, g, now)
        except Exception as e:
            self.log("status_file_failed", error=str(e))
        self.log("tick", ok=not errors, accounts=len(rows), errors=errors)
        return self.get_status()

    def write_status_file(self, rows: dict, g: GlobalSnap, now: int):
        """Per-account summary for the relayer API (sa-api serves it at /elysium-api/sa/status). Atomic replace;
        group-readable. An account whose tick failed keeps its previous row, flagged `stale`. No alerts, errors or
        actions: the file is served to clients."""
        path = self.sa.status_path
        if not path:
            return
        prev = getattr(self, "_status_rows", None)
        if prev is None:  # after a restart: carry the last written rows over
            try:
                with open(path) as fh:
                    prev = json.load(fh).get("accounts") or {}
            except (OSError, ValueError, AttributeError):
                prev = {}
        out_rows = {a: dict(r, stale=False) for a, r in rows.items()}
        for a, r in prev.items():
            if a not in out_rows:
                out_rows[a] = dict(r, stale=True)
        self._status_rows = out_rows
        price = self.status.get("price") or {}
        doc = {"version": 1, "module": self.r.m.address, "written_at": int(time.time()), "last_tick": now,
               "paused": g.paused, "price": {"anchor": g.last_price / 1e6, "pool": price.get("pool"),
                                             "status": price.get("status")},
               "accounts": out_rows}
        if os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.tmp{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
        with os.fdopen(fd, "w") as fh:
            json.dump(doc, fh, default=str)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)

    def get_status(self) -> dict:
        with self.lock:
            return dict(self.status)

    def run(self, once: bool = False):
        if self.cfg.status_port and self.server is None:
            self.server = StatusServer(self.cfg.status_host, self.cfg.status_port, self.get_status)
        signal.signal(signal.SIGTERM, lambda *a: setattr(self, "stop", True))
        while not self.stop:
            try:
                self.tick()
            except Exception as e:
                self.log("tick_failed", error=repr(e))
                self.alert("warn", "tick_failed", f"tick failed: {e}")
            if once:
                break
            for _ in range(int(self.cfg.loop_interval_s * 4)):
                if self.stop:
                    break
                time.sleep(0.25)
        self.state.save()
