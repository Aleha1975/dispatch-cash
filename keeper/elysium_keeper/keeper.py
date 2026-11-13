"""Keeper: one process per vault. Each tick follows the README sequence:

  read -> choose price -> (settle first if the price drifted near refDrift) -> free liquidity for redeems ->
  settle (interval or queues) -> LP: crash guard exit / re-range / deploy idle -> hedge + margin -> persist.

Idempotency: the chain is the source of truth (epoch, positions, balances); every step recomputes what is still
missing from a fresh snapshot, so a restart after a crash at any point never repeats a completed action. Settle
reports carry `epoch`, so a mined settle can never be replayed. The HL hedge is sized from the adapter's position,
not from remembered orders.
"""
from __future__ import annotations

import signal
import threading
import time

from . import strategy as S
from . import v4math as M
from .config import Config
from .hl import DryRunAdapter, HLInfo, LiveAdapter
from .infra import Alerts, Log, State, StatusServer
from .rpc import RPC, Chain, KeystoreSigner, ReadOnlySigner, TxRevert, UnlockedSigner, is_local
from .vault import ZERO, Snapshot, VaultReader

BPS = 10_000
E18 = 10 ** 18


class Keeper:
    def __init__(self, cfg: Config, *, hl_info=None, adapter=None, signer=None, alert_sink=None, log=None,
                 rpc=None):
        self.cfg = cfg
        self.st = cfg.strategy
        self.log = log or Log(cfg.log_path, cfg.name)
        self.rpc = rpc or RPC(cfg.chain.rpc_url)
        cid = self.rpc.chain_id()
        if cid != cfg.chain.chain_id:
            raise ValueError(f"chain id {cid} != configured {cfg.chain.chain_id}")
        if not is_local(cfg.chain.rpc_url) and cfg.chain.signer != "readonly" and not cfg.chain.allow_live_chain:
            raise PermissionError("non-local RPC: use signer=readonly or set chain.allow_live_chain deliberately")
        self.reader = VaultReader(self.rpc, cfg.chain.vault, cfg.chain.pool_manager, cfg.chain.position_manager,
                                  cfg.chain.usdc, cfg.chain.pool_id)
        self.vault = self.reader.v
        self.usdc = self.reader.usdc
        self.chain = Chain(self.rpc, signer or self._make_signer(), self.log, cfg.chain.tx_timeout_s)
        if self.vault.call("keeper") != self.chain.signer.address:
            raise ValueError(f"signer {self.chain.signer.address} is not the vault keeper")
        self.state = State(cfg.state_path)
        self.alert = Alerts(cfg.alerts, self.log, cfg.name, sink=alert_sink)
        self.info = hl_info or HLInfo(cfg.hl.api_url)
        self.hedged = self.st.mode == "hedged"
        if self.hedged and self.reader.treasury == ZERO:
            raise ValueError("hedged mode but the vault has no hedgeTreasury")
        if not self.hedged and self.reader.treasury != ZERO:
            self.log("warn_growth_mode_on_hedged_vault")
        self.adapter = adapter
        if self.hedged and self.adapter is None:
            if cfg.hl.adapter == "live":
                self.adapter = LiveAdapter(cfg.hl, self.state.d.setdefault("hl_nonce", {}), self.log, self.info)
            else:
                self.adapter = DryRunAdapter(cfg.hl, self.state.d.setdefault("hl_sim", {}), self.log, self.info,
                                             mark_fn=lambda: self.info.mid(cfg.hl.coin))
        if isinstance(self.adapter, DryRunAdapter):
            self.adapter.sim = self.state.d.setdefault("hl_sim", self.adapter.sim)
        self.guard = S.CrashGuard.from_dict(self.state.d.get("crash", {}), self.st.crash_drop, self.st.crash_wait_s)
        self._vol = None  # (fetched_at, half_width, daily_vol)
        self.lock = threading.Lock()
        self.status: dict = {"ok": False, "vault": cfg.chain.vault, "name": cfg.name, "mode": self.st.mode}
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
        rc = self.chain.transact(self.vault, fn, *args, **kw)
        rec = {"ts": self.now(), "fn": fn, "args": [str(a) for a in args],
               "tx": (rc or {}).get("transactionHash")}
        self.actions = (self.actions + [rec])[-40:]
        return rc

    def hl_mid_p(self) -> int:
        return M.usd_to_p(self.info.mid(self.cfg.hl.coin))

    def treasury_capital(self, snap: Snapshot) -> int:
        """Off-chain hedge capital in USDC raw: treasury balance + HL equity + operator-declared in-transit."""
        if not self.hedged:
            return 0
        eq = int(self.adapter.equity() * 1e6)
        transit = int(self.state.d.get("in_transit_usdc", 0))
        return max(0, snap.treasury_usdc + eq + transit)

    def buffer(self, snap: Snapshot, price: int) -> int:
        return snap.nav_at(price) * self.st.idle_buffer_bps // BPS

    def reserved_for_redeems(self, snap: Snapshot, price: int) -> int:
        if not snap.queued_redeem_shares:
            return 0
        he = self.treasury_capital(snap) if self.hedged else 0
        v = max(snap.redeem_value(price, snap.queued_redeem_shares),
                snap.redeem_value(price, snap.queued_redeem_shares, he))
        return int(v * (1 + self.st.redeem_value_margin))

    # ------------------------------------------------------------ signals
    def half_width(self, now: int, mid_usd: float) -> tuple[float, float]:
        """Cached for vol_refresh_s, but refreshed at once if the price moved > 1% since (a re-range right after a
        jump must see the jump in its volatility)."""
        if self._vol and 0 <= now - self._vol[0] < self.st.vol_refresh_s and abs(mid_usd / self._vol[3] - 1) < 0.01:
            return self._vol[1], self._vol[2]
        hrs = self.st.vol_lookback_h + 3
        cs = self.info.candles(self.cfg.hl.coin, "1h", (now - hrs * 3600) * 1000, now * 1000)
        vol = S.realized_daily_vol([float(c["c"]) for c in cs], self.st.vol_lookback_h)
        hw = S.range_half_width(vol, self.st.k_vol, self.st.min_half_width, self.st.max_half_width)
        self._vol = (now, hw, vol, mid_usd)
        return hw, vol

    def crash_signal(self, now: int, mid_usd: float) -> str:
        w = self.st.crash_window_s
        c5 = self.info.candles(self.cfg.hl.coin, "5m", (now - w - 300) * 1000, now * 1000)
        peak = S.peak_in_window(c5, now, w, mid_usd)
        hrs = self.st.rv1h_median_lookback_h + 2
        c1 = self.info.candles(self.cfg.hl.coin, "1h", (now - hrs * 3600) * 1000, now * 1000)
        rv_last, rv_med = S.vol_median_ok([float(c["c"]) for c in c1], self.st.rv1h_median_lookback_h)
        before = self.guard.mode
        a = self.guard.step(now, mid_usd, peak, rv_last, rv_med)
        self.state.d["crash"] = self.guard.to_dict()
        self.status["crash"] = dict(self.guard.to_dict(), peak_4h=peak, rv1h=rv_last, rv1h_median=rv_med,
                                    drop=1 - mid_usd / peak if peak else 0)
        if a == "exit":
            self.alert("warn", "crash_exit", f"crash guard: HYPE {mid_usd:.3f} is {100 * (1 - mid_usd / peak):.1f}% "
                                             f"below the 4h peak {peak:.3f}; pulling all liquidity to USDC")
        elif a == "reenter":
            self.alert("info", "crash_reenter", f"crash guard released after {(now - self.guard.since) / 3600:.1f}h "
                                                f"(rv1h {rv_last:.4f} < median {rv_med:.4f}); re-entering")
        if before != self.guard.mode:
            self.log("crash_guard", action=a, mode=self.guard.mode, price=mid_usd, peak=peak)
        return a

    # ------------------------------------------------------------ settle
    def report_hedge_equity(self, snap: Snapshot, now: int) -> int | None:
        if not self.hedged:
            return 0
        v = self.treasury_capital(snap)
        old = snap.hedge_equity
        diff = abs(v - old)
        used = 0 if now >= snap.hedge_drift_start + 86400 else snap.hedge_drift_used
        budget = snap.last_nav * snap.params["hedgeStepBps"]
        if diff == 0 or (used + diff) * BPS <= budget:
            return v
        if snap.approved_hedge_epoch == snap.epoch + 1 and snap.approved_hedge_equity == v:
            return v
        if snap.last_nav == 0 or diff < 10 ** 6:
            # no NAV yet (budget is 0) or sub-$1 dust: keep the on-chain value rather than block settlement
            self.log("hedge_equity_kept", reported=old, actual=v, reason="no_nav" if snap.last_nav == 0 else "dust")
            return old
        policy = self.st.hedge_equity_over_budget
        queues = snap.pending_deposits or snap.pending_redeems
        if policy == "skip" or (policy == "auto" and queues):
            self.alert("warn", "hedge_eq_budget", f"hedge equity {v / 1e6:.2f} vs on-chain {old / 1e6:.2f} exceeds the "
                                                  f"daily drift budget; guardian must approveHedgeEquity({v}) for "
                                                  f"epoch {snap.epoch}; settlement skipped")
            return None
        room = max(0, budget // BPS - used)
        clamped = old + room if v > old else old - min(room, old)
        self.alert("warn", "hedge_eq_budget", f"hedge equity {v / 1e6:.2f} over drift budget; reporting {clamped / 1e6:.2f}"
                                              f" (guardian approveHedgeEquity({v}) for epoch {snap.epoch} to fix)")
        return clamped

    def settle_due(self, snap: Snapshot, now: int, price: int) -> bool:
        if now - snap.last_settle >= self.st.settle_interval_s:
            return True
        if snap.pending_deposits and not snap.paused:
            return True
        if snap.pending_redeems and snap.first_redeem_shares:
            he = self.treasury_capital(snap) if self.hedged else 0
            return snap.redeem_value(price, snap.first_redeem_shares, he) <= snap.idle_asset + (
                0 if snap.paused else snap.pending_deposit_assets)
        return False

    def settle_all(self, price: int, now: int, reason: str) -> int:
        n = 0
        for _ in range(self.st.settle_calls_per_tick):
            snap = self.reader.snapshot()
            he = self.report_hedge_equity(snap, now)
            if he is None:
                break
            m = self.st.max_settle_items
            self.act("settle", (snap.epoch, price, he, m, m))
            n += 1
            self.state.d["last_settle_epoch"] = snap.epoch
            s2 = self.reader.snapshot()
            self.log("settled", epoch=snap.epoch, reason=reason, price=price, hedge_equity=he, nav=s2.last_nav,
                     deposits_left=s2.pending_deposits, redeems_left=s2.pending_redeems)
            more_dep = s2.pending_deposits and not s2.paused and s2.pending_deposits < snap.pending_deposits
            more_red = s2.pending_redeems and s2.redeem_head > snap.redeem_head
            if not (more_dep or more_red):
                break
        return n

    # ------------------------------------------------------------ swaps
    def swap_budgeted(self, sell_base: bool, amount: int, price: int) -> int:
        """Exact-input swaps in chunks; stop when the pool moves more than max_adverse_dev_bps against `price`
        (wait for arbitrage next tick) or the vault's turnover cap is hit. Returns the amount swapped."""
        p_usd = M.p_to_usd(price)
        chunk_max = int(self.st.swap_chunk_usd / p_usd * E18) if sell_base else int(self.st.swap_chunk_usd * 1e6)
        min_amt = int(self.st.min_swap_usd / p_usd * E18) if sell_base else int(self.st.min_swap_usd * 1e6)
        done = 0
        dev = self.st.max_adverse_dev_bps
        while amount - done > min_amt:
            pool = self.vault.call("poolPrice")
            if (sell_base and pool * BPS < price * (BPS - dev)) or (not sell_base and pool * BPS > price * (BPS + dev)):
                self.log("swap_paused_adverse_dev", pool=pool, price=price, left=amount - done, sell_base=sell_base)
                break
            chunk = min(amount - done, chunk_max)
            while True:
                try:
                    self.vault.call("swap", sell_base, chunk, price, sender=self.chain.signer.address)
                    break
                except TxRevert as e:
                    if "BelowMinOut" in e.reason and chunk > 2 * min_amt:
                        chunk //= 2
                        continue
                    if "Turnover" in e.reason:
                        self.alert("warn", "turnover", "swap turnover cap (rolling day) reached")
                    else:
                        self.log("swap_probe_revert", reason=e.reason, chunk=chunk)
                    return done
            self.act("swap", sell_base, chunk, price)
            done += chunk
        return done

    # ------------------------------------------------------------ liquidity
    def burn_all(self, snap: Snapshot, why: str):
        for p in snap.positions:
            sa, sb = M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu)
            a0, a1 = M.amounts_for_liquidity(snap.sqrt_price, sa, sb, p.liquidity)
            k = BPS - self.st.burn_slippage_bps
            self.act("burnPosition", p.token_id, a0 * k // BPS, a1 * k // BPS)
            self.log("burned", token_id=p.token_id, tl=p.tl, tu=p.tu, why=why)

    def free_for_redeems(self, price: int):
        snap = self.reader.snapshot()
        if not snap.queued_redeem_shares:
            return
        need = self.reserved_for_redeems(snap, price) - snap.idle_asset - (
            0 if snap.paused else snap.pending_deposit_assets)
        if need <= 0:
            return
        self.log("free_liquidity", need_usdc=need / 1e6)
        p_usd = M.p_to_usd(price)
        lp_val = snap.lp_asset + snap.lp_base * price // E18
        idle_base_val = snap.native * price // E18
        from_lp = max(0, need - idle_base_val)
        if from_lp > 0 and lp_val > 0 and snap.positions:
            q = min(1.0, from_lp * 1.05 / lp_val)
            if q > 0.97:
                self.burn_all(snap, "redeem")
            else:
                for p in snap.positions:
                    liq = int(p.liquidity * q)
                    sa, sb = M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu)
                    a0, a1 = M.amounts_for_liquidity(snap.sqrt_price, sa, sb, liq)
                    k = BPS - self.st.burn_slippage_bps
                    self.act("decreasePosition", p.token_id, liq, a0 * k // BPS, a1 * k // BPS)
            snap = self.reader.snapshot()
        need = self.reserved_for_redeems(snap, price) - snap.idle_asset - (
            0 if snap.paused else snap.pending_deposit_assets)
        if need > 0 and snap.native > 0:
            sell = min(snap.native, int(need * 1.03 / p_usd / 1e6 * E18) + 1)
            self.swap_budgeted(True, sell, price)
            snap = self.reader.snapshot()
            need = self.reserved_for_redeems(snap, price) - snap.idle_asset - (
                0 if snap.paused else snap.pending_deposit_assets)
        if need > 0 and self.hedged:
            self.return_margin(snap, need, "redeem")

    def return_margin(self, snap: Snapshot, amount: int, why: str):
        avail = min(snap.treasury_usdc, snap.treasury_allowance)
        amt = min(amount, avail)
        if amt > 0 and self.st.auto_return_margin:
            self.act("returnHedgeMargin", amt)
            self.log("margin_returned", usdc=amt / 1e6, why=why)
        left = amount - amt
        if left > self.st.min_margin_move_usd * 1e6:
            self.alert("warn", f"margin_withdraw_{why}",
                       f"MANUAL: withdraw {left / 1e6:.2f} USDC from the HL hedge account to treasury "
                       f"{snap.treasury} and approve the vault ({why}); the keeper pulls it with returnHedgeMargin")

    def deploy(self, price: int, half_width: float):
        """Mint (no position) or increase (in-range position) with idle funds, keeping the USDC buffer, the value
        reserved for queued redeems and (hedged) the margin for the new HYPE exposure."""
        snap = self.reader.snapshot()
        if snap.paused or snap.last_nav == 0:
            return
        p_usd = M.p_to_usd(price)
        if snap.positions:
            pos = snap.positions[0]
            tl, tu = pos.tl, pos.tu
        else:
            pos = None
            tl, tu = S.range_ticks(price, half_width)
        f = M.base_value_fraction(snap.sqrt_price, tl, tu)
        buffer, reserved = self.buffer(snap, price), self.reserved_for_redeems(snap, price)
        free = max(0, snap.idle_asset - buffer - reserved) / 1e6
        hv = snap.native * price / E18 / 1e6
        cap = self.treasury_capital(snap) / 1e6 if self.hedged else 0.0
        v, margin_x = S.deploy_split(free, hv, snap.lp_base * price / E18 / 1e6, cap, f, self.hedged,
                                     self.st.hedge_leverage)
        if v < self.st.min_deploy_usd:
            return
        target_hv = f * v
        if hv < target_hv - self.st.min_swap_usd:
            self.swap_budgeted(False, int((target_hv - hv) * 1e6), price)
        elif hv > target_hv + self.st.min_swap_usd:
            self.swap_budgeted(True, int((hv - target_hv) / p_usd * E18), price)
        snap = self.reader.snapshot()
        a0 = snap.native
        a1 = max(0, snap.idle_asset - buffer - reserved - int(margin_x * 1e6))
        sa, sb = M.sqrt_price_at_tick(tl), M.sqrt_price_at_tick(tu)
        liq = M.liquidity_for_amounts(snap.sqrt_price, sa, sb, a0 * 995 // 1000, a1 * 995 // 1000)
        u0, u1 = M.amounts_for_liquidity(snap.sqrt_price, sa, sb, liq)
        val = (u0 * price // E18 + u1) / 1e6
        if liq <= 0 or val < self.st.min_deploy_usd:
            self.log("deploy_skipped", value_usd=val, a0=a0, a1=a1)
            return
        if pos is None:
            self.act("mintPosition", tl, tu, liq, a0, a1, price)
            self.log("minted", tl=tl, tu=tu, liquidity=liq, value_usd=val, half_width=half_width)
        else:
            self.act("increasePosition", pos.token_id, liq, a0, a1, price)
            self.log("increased", token_id=pos.token_id, liquidity=liq, value_usd=val)

    def manage_lp(self, price: int, half_width: float):
        snap = self.reader.snapshot()
        if snap.positions and not any(S.in_range(snap.tick, p.tl, p.tu) for p in snap.positions):
            self.log("rerange", tick=snap.tick, ranges=[(p.tl, p.tu) for p in snap.positions])
            self.burn_all(snap, "out_of_range")
            self.state.d["last_rerange"] = self.now()
        self.deploy(price, half_width)

    def exit_all(self, price: int):
        snap = self.reader.snapshot()
        if snap.positions:
            self.burn_all(snap, "crash_guard")
            snap = self.reader.snapshot()
        if snap.native * price // E18 > self.st.min_swap_usd * 1e6:
            self.swap_budgeted(True, snap.native, price)

    # ------------------------------------------------------------ hedge
    def hedge(self, price: int, now: int):
        snap = self.reader.snapshot()
        p_usd = M.p_to_usd(price)
        mid = self.info.mid(self.cfg.hl.coin)
        exposure = (snap.lp_base + snap.native + snap.whype) / E18
        target = exposure * self.st.hedge_ratio
        cur = -self.adapter.position()
        last = int(self.state.d.get("last_hedge_ts", 0))
        d = S.hedge_decision(target, cur, mid, now, last, self.st.rehedge_drift, self.st.rehedge_interval_s,
                             self.cfg.hl.min_order_usd, self.cfg.hl.sz_decimals)
        if d.act:
            res = self.adapter.place(d.is_buy, d.size, mid, d.reduce_only)
            self.state.d["last_hedge_ts"] = now
            self.log("rehedge", reason=d.reason, target=target, before=cur, side="buy" if d.is_buy else "sell",
                     size=d.size, ok=res.get("ok"))
            if not res.get("ok"):
                self.alert("warn", "hedge_order_failed", f"HL order failed: {res.get('error')}")
        elif now - last >= self.st.rehedge_interval_s:
            self.state.d["last_hedge_ts"] = now
        cur = -self.adapter.position()
        self.status["hedge"] = {"target_short": round(target, 4), "short": cur, "adapter": self.adapter.name,
                                "delta_pct": round(100 * (cur - target) / target, 2) if target else None,
                                "last_hedge_ts": self.state.d.get("last_hedge_ts")}
        # margin
        cap = self.treasury_capital(snap)
        mp = S.margin_plan(target * p_usd, cap / 1e6, self.st.hedge_leverage, self.st.margin_tolerance,
                           self.st.min_margin_move_usd)
        self.status["margin"] = {"plan": mp.action, "amount": round(mp.amount_usd, 2), "target": round(mp.target_usd, 2),
                                 "capital": cap / 1e6, "onchain_hedge_equity": snap.hedge_equity / 1e6,
                                 "treasury_usdc": snap.treasury_usdc / 1e6,
                                 "in_transit": self.state.d.get("in_transit_usdc", 0) / 1e6}
        if mp.action == "send":
            room = max(0, snap.last_nav * snap.params["hedgeCapBps"] // BPS - snap.hedge_equity)
            avail = max(0, snap.idle_asset - self.buffer(snap, price) - self.reserved_for_redeems(snap, price))
            amt = min(int(mp.amount_usd * 1e6), room, avail)
            if amt >= self.st.min_margin_move_usd * 1e6 and self.st.auto_send_margin and not snap.paused:
                self.act("sendHedgeMargin", amt)
                self.log("margin_sent", usdc=amt / 1e6, target=mp.target_usd)
            elif amt < mp.amount_usd * 1e6 - self.st.min_margin_move_usd * 1e6:
                self.alert("warn", "margin_short", f"hedge margin {cap / 1e6:.2f} below target {mp.target_usd:.2f} and "
                                                   f"cannot send more (cap room {room / 1e6:.2f}, idle {avail / 1e6:.2f})")
        elif mp.action == "return":
            self.return_margin(snap, int(mp.amount_usd * 1e6), "excess")
        snap = self.reader.snapshot()
        if snap.treasury_usdc >= self.st.min_margin_move_usd * 1e6 and mp.action != "return":
            self.alert("warn", "margin_bridge",
                       f"MANUAL: bridge {snap.treasury_usdc / 1e6:.2f} USDC from treasury {snap.treasury} to the HL "
                       f"hedge account (native bridge 5.5d free / Relay ~1.8%); then run `margin --in-transit` if slow")

    # ------------------------------------------------------------ tick
    def tick(self) -> dict:
        t0 = time.time()
        now = self.now()
        errors = []
        snap = self.reader.snapshot()
        self.status.update({"last_tick_chain_ts": now, "epoch": snap.epoch})
        if snap.emergency:
            self.alert("alarm", "emergency", "vault is in emergency wind-down; keeper idle")
            return self._finish(now, snap, None, ["emergency"], t0)
        if snap.last_settle and now - snap.last_settle > 24 * 3600:
            self.alert("alarm", "settle_stale", f"no settlement for {(now - snap.last_settle) / 3600:.1f}h "
                                                f"(emergencyUnwind opens at 72h)")
        hl = self.hl_mid_p()
        pc = S.choose_price(hl, snap.pool_price, snap.params["poolBandBps"], self.st.band_safety,
                            self.st.max_clamp_dev_bps)
        self.status["price"] = {"hl": hl / 1e6, "pool": snap.pool_price / 1e6, "used": (pc.price or 0) / 1e6,
                                "status": pc.status, "dev_bps": round(pc.dev_bps, 1)}
        if pc.status == "skip":
            self.alert("warn", "price_skip", f"pool {snap.pool_price / 1e6:.4f} vs HL {hl / 1e6:.4f} differ "
                                             f"{pc.dev_bps:.0f} bps (> {self.st.max_clamp_dev_bps}); skipping tick, "
                                             f"waiting for arbitrage")
            return self._finish(now, snap, None, ["price_skip"], t0)
        if pc.status == "clamped":
            self.log("price_clamped", hl=hl, pool=snap.pool_price, used=pc.price)
        price = pc.price
        hw, vol = self.half_width(now, hl / 1e6)
        self.status["range_rule"] = {"half_width": hw, "daily_vol_72h": vol}
        crash = None
        if not self.hedged:
            crash = self.crash_signal(now, hl / 1e6)

        def step(name, fn, *a):
            try:
                fn(*a)
            except Exception as e:  # keep going with the remaining (independent) steps
                errors.append(f"{name}: {e}")
                self.log("step_failed", step=name, error=str(e))
                self.alert("warn", f"step_{name}", f"{name} failed: {e}")

        if snap.whype:
            step("unwrap", self.act, "unwrapBase", snap.whype)
        if snap.last_price and abs(price - snap.last_price) * BPS > snap.last_price * snap.params["refDriftBps"] * 0.9:
            step("settle_ref", self.settle_all, price, now, "ref_drift")
        step("free", self.free_for_redeems, price)
        s = self.reader.snapshot()
        if self.settle_due(s, now, price):
            step("settle", self.settle_all, price, now, "due")
        if not self.hedged and self.guard.mode == "out":
            step("exit", self.exit_all, price)
        else:
            step("lp", self.manage_lp, price, hw)
        if self.hedged:
            step("hedge", self.hedge, price, now)
        snap = self.reader.snapshot()
        return self._finish(now, snap, price, errors, t0, crash)

    def _finish(self, now, snap: Snapshot, price, errors, t0, crash=None) -> dict:
        self.state.d["last_tick"] = now
        self.state.save()
        rng = None
        if snap.positions:
            p = snap.positions[0]
            rng = {"tl": p.tl, "tu": p.tu, "tick": snap.tick, "in_range": S.in_range(snap.tick, p.tl, p.tu),
                   "lo_usd": 1.0001 ** p.tl * 1e12, "hi_usd": 1.0001 ** p.tu * 1e12}
        px = price or snap.pool_price
        with self.lock:
            self.status.update({
                "ok": not errors and (now - snap.last_settle) < 3 * self.st.settle_interval_s,
                "errors": errors, "tick_seconds": round(time.time() - t0, 2), "last_tick_wall": int(time.time()),
                "epoch": snap.epoch, "last_nav_usd": snap.last_nav / 1e6, "nav_now_usd": snap.nav_at(px) / 1e6,
                "last_settle_age_s": now - snap.last_settle, "paused": snap.paused, "emergency": snap.emergency,
                "queues": {"deposits": snap.pending_deposits, "redeems": snap.pending_redeems,
                           "deposit_usdc": snap.pending_deposit_assets / 1e6},
                "holdings": {"idle_usdc": snap.idle_asset / 1e6, "idle_hype": snap.native / 1e18,
                             "lp_hype": snap.lp_base / 1e18, "lp_usdc": snap.lp_asset / 1e6,
                             "hedge_equity_onchain": snap.hedge_equity / 1e6},
                "positions": [vars(p) for p in snap.positions], "range": rng, "crash_action": crash,
                "actions": self.actions[-15:], "alerts": self.alert.recent[-15:],
            })
        self.log("tick", ok=self.status["ok"], epoch=snap.epoch, nav=snap.nav_at(px) / 1e6, errors=errors)
        return self.get_status()

    def get_status(self) -> dict:
        with self.lock:
            st = dict(self.status)
        st["last_tick_age_s"] = int(time.time()) - st.get("last_tick_wall", 0) if st.get("last_tick_wall") else None
        if st["last_tick_age_s"] is not None and st["last_tick_age_s"] > 5 * self.cfg.loop_interval_s:
            st["ok"] = False
        return st

    # ------------------------------------------------------------ loop
    def serve_status(self):
        if self.cfg.status_port and self.server is None:
            self.server = StatusServer(self.cfg.status_host, self.cfg.status_port, self.get_status)
            self.log("status_server", url=f"http://{self.cfg.status_host}:{self.server.port}/status")

    def run(self, once: bool = False):
        self.serve_status()
        signal.signal(signal.SIGTERM, lambda *a: setattr(self, "stop", True))
        while not self.stop:
            try:
                self.tick()
            except Exception as e:
                self.log("tick_failed", error=repr(e))
                self.alert("warn", "tick_failed", f"tick failed: {e}")
                with self.lock:
                    self.status.update({"ok": False, "errors": [repr(e)]})
            if once:
                break
            for _ in range(int(self.cfg.loop_interval_s * 4)):
                if self.stop:
                    break
                time.sleep(0.25)
        self.state.save()
