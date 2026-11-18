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
Client preferences (prefs.py, docs/PRODUCT_FLOW.md): each account's signed Strategy picks the range width (auto =
the volatility recommendation, recomputed at every re-range; manual = the client's half-width, re-centred on every
re-range, widened to the live turnover floor if needed) and hedged / unhedged (unhedged: no margin, no short; margin
already sent is returned once the short share is closed). Re-range triggers: out of range, within sa.edge_frac of an
edge, a newer preference whose width differs, or (auto) a vol-based width that moved by more than
sa.auto_rewidth_factor; the in-range triggers wait while the turnover budget cannot pay the re-deploy.
Risk-off (Strategy v2 riskOff, riskoff.py): while the global signal is on, a risk-off account leaves the pool: burn
every position, sell its HYPE into USDC (on-chain: the module's exit window, exitTurnoverBps), and, if hedged, close
its short share once the HYPE is sold and take the margin back into the account; it re-enters through the normal
deploy path once the signal is off and it has been out at least sa.riskoff_min_out_s.
Restart safety: every action is recomputed from a fresh read; the state file holds the ledger, the dry-run HL
simulation, the event-scan cursor, fee records and the accepted preferences (state `prefs`, with the signatures).
"""
from __future__ import annotations

import json
import os
import signal
import threading
import time

from eth_utils import to_checksum_address

from . import prefs as P
from . import recommend as R
from . import riskoff as RO
from . import strategy as S
from . import v4math as M
from .config import Config
from .hl import DryRunAdapter, HLInfo, LiveAdapter
from .infra import Alerts, Log, State, StatusServer
from .ledger import HedgeLedger
from .rpc import RPC, Chain, KeystoreSigner, ReadOnlySigner, TxRevert, UnlockedSigner, is_local
from .sa_chain import BOOK_BAND_BPS, AccountSnap, GlobalSnap, ModuleReader, hybrid_address

BPS = 10_000
E18 = 10 ** 18
SWAP_MIN_OUT_SLACK_BPS = 30  # minOut = the simulated output less this (the module floor still applies)


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


def pos_half_width(tl: int, tu: int) -> float:
    """Half-width of [pl, pu] around its arithmetic centre: (pu - pl) / (pu + pl) (= w for [P(1-w), P(1+w)])."""
    pl, pu = 1.0001 ** tl, 1.0001 ** tu
    return (pu - pl) / (pu + pl)


def rerange_reason(tick: int, positions: list, target_hw: float, mode: str, edge_frac: float, prefs_nonce: int,
                   meta: dict | None, rewidth_tol: float = 0.25, auto_factor: float = 2.0) -> str | None:
    """Why the account's LP should be closed and re-opened centred at `target_hw` now, or None.
    out_of_range (always acted on), near_edge, prefs_changed (a newer signed preference with another width),
    width_mismatch (manual width not what the client asked), vol_changed (auto width off by > auto_factor)."""
    if not positions:
        return None
    live = [p for p in positions if S.in_range(tick, p.tl, p.tu)]
    if not live:
        return "out_of_range"
    p = live[0]
    w = p.tu - p.tl
    if edge_frac > 0 and (tick - p.tl < edge_frac * w or p.tu - tick <= edge_frac * w):
        return "near_edge"
    ratio = pos_half_width(p.tl, p.tu) / target_hw if target_hw > 0 else 1.0
    if int((meta or {}).get("nonce", 0)) < prefs_nonce and abs(ratio - 1) > rewidth_tol:
        return "prefs_changed"
    if mode == "manual" and abs(ratio - 1) > rewidth_tol:
        return "width_mismatch"
    if mode == "auto" and auto_factor > 1 and (ratio > auto_factor or ratio < 1 / auto_factor):
        return "vol_changed"
    return None


def rerange_charge(value_lp: int, tick: int, cur: tuple[int, int], new: tuple[int, int], slip_bps: int,
                   band_bps: int) -> int:
    """Turnover a re-range is expected to use: the re-centring swap (change of the HYPE share) + the LP add charge
    (SA-5 M-2, SABook.lpAdd: the whole principal; `slip_bps` / `band_bps` no longer enter it)."""
    swap = abs(R.base_frac(tick, *cur) - R.base_frac(tick, *new))
    return int(value_lp * (swap + 1.0))


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
        self._hold_until = 0  # a fee is due: keep the anchor value unchanged until then (minPriceStable, SA-2 H-1)
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
        self._floor = None
        self.prefs = self.state.d.setdefault("prefs", {})  # account -> accepted signed Strategy (prefs.Strategy.record)
        self.ranges = self.state.d.setdefault("ranges", {})  # account -> {nonce, hw, tl, tu} of the last mint
        self.riskoff = RO.RiskOff(self.info, self.state.d.setdefault("riskoff", {}), coin_btc=self.sa.riskoff_btc_coin,
                                  coin_base=cfg.hl.coin, use_rv=self.sa.riskoff_use_rv,
                                  refresh_s=self.sa.riskoff_refresh_s, log=self.log)
        self.riskout = self.state.d.setdefault("riskoff_out", {})  # account -> time it left the pool (risk-off)
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
        """Auto (recommended) half-width: k x 72 h realized daily vol, clipped (same as recommend.py)."""
        if self._vol and 0 <= now - self._vol[0] < self.st.vol_refresh_s and abs(mid_usd / self._vol[2] - 1) < 0.01:
            return self._vol[1]
        hrs = self.st.vol_lookback_h + 3
        cs = self.info.candles(self.cfg.hl.coin, "1h", (now - hrs * 3600) * 1000, now * 1000)
        vol = S.realized_daily_vol([float(c["c"]) for c in cs], self.st.vol_lookback_h)
        hw = S.range_half_width(vol, self.st.k_vol, self.st.min_half_width, self.st.max_half_width)
        self._vol = (now, hw, mid_usd, vol)
        self._floor = None
        return hw

    def turnover_floor(self, g: GlobalSnap, hedged: bool) -> float:
        """Smallest half-width whose expected re-ranges fit the module's turnover budget (recommend.turnover_floor),
        for the current vol and the module's Params; cached per vol refresh."""
        if not self._vol:
            return 0.0
        key = (self._vol[0], g.params["swapTurnoverBps"], g.params["maxSlippageBps"], g.params["poolBandBps"])
        if self._floor is None or self._floor[0] != key:
            lp_h, lp_u = R.lp_fracs(self.sa.margin_frac, self.sa.buffer_bps)
            out = {}
            for k, lp in ((True, lp_h), (False, lp_u)):
                m = R.Model(sigma_daily=self._vol[3], price=g.pool_price, tick=M.tick_at_price(g.pool_price),
                            spacing=self.spacing,
                            fee_tier=0.003, fees_per_l_day=0.0, edge_frac=self.sa.edge_frac,
                            turnover_bps=g.params["swapTurnoverBps"], slippage_bps=g.params["maxSlippageBps"],
                            band_bps=g.params["poolBandBps"], lp_frac=lp)
                out[k] = R.turnover_floor(m)
            self._floor = (key, out)
        return self._floor[1][hedged]

    @property
    def spacing(self) -> int:
        return int(self.pool_entry().get("tick_spacing", 60))

    def pool_entry(self) -> dict:
        """This module's entry of the pool whitelist (sa.pools), matched by module, else by the module's pool id."""
        pid = "0x" + bytes(self.r.pool_id).hex() if isinstance(self.r.pool_id, (bytes, bytearray)) else self.r.pool_id
        for p in self.sa.pools:
            if (p.get("module") or "").lower() == self.r.m.address.lower():
                return p
        for p in self.sa.pools:
            if str(p.get("pool_id", "")).lower() == str(pid).lower():
                return p
        return {"id": "module", "name": "pool", "pool_id": pid, "tick_spacing": 60, "module": self.r.m.address}

    # ------------------------------------------------------------ client preferences
    def prefs_of(self, a: str) -> dict:
        return self.prefs.get(a) or P.default_record(self.sa.default_hedged)

    def width_for(self, a: str, g: GlobalSnap, hw_auto: float) -> tuple[float, bool, float]:
        """(half-width to use, clamped to the turnover floor, floor) for account `a` under its preference."""
        pr = self.prefs_of(a)
        floor = self.turnover_floor(g, bool(pr["hedged"]))
        hw, clamped = R.effective_half_width(pr["mode"], pr.get("width_bps"), hw_auto, floor, self.st.max_half_width)
        return hw, clamped, floor

    def apply_strategy(self, raw: dict, owner: str, account: str, now: int) -> dict:
        """Verify a signed Strategy (the keeper's own check, independent of sa-api) and store it for `account`."""
        st = P.parse(raw)
        last = int((self.prefs.get(account) or {}).get("nonce", 0))
        P.verify(st, owner=owner, account=account, module=self.r.m.address, chain_id=self.cfg.chain.chain_id, now=now,
                 b=P.Bounds.from_cfg(self.sa), last_nonce=last)
        rec = st.record(now)
        self.prefs[account] = rec
        self.log("strategy_applied", account=account, mode=rec["mode"], width_bps=rec["width_bps"],
                 hedged=rec["hedged"], nonce=rec["nonce"])
        return rec

    def process_strategy_requests(self, now: int):
        """Strategy updates dropped by sa-api into sa.requests_dir/strategy (`<owner>-<nonce>.json`), lowest nonce
        first; each is verified again and moved to strategy/done or strategy/failed. An update for an account that is
        not registered yet stays queued (its onboarding may still be in the queue) until its deadline."""
        d = os.path.join(self.sa.requests_dir, "strategy") if self.sa.requests_dir else ""
        if not d or not os.path.isdir(d):
            return
        items = []
        for name in os.listdir(d):
            if name.endswith(".json") and "-" in name and not name.startswith("."):
                try:
                    items.append((int(name.rsplit("-", 1)[1][:-5]), name))
                except ValueError:
                    continue
        for _, name in sorted(items):
            path = os.path.join(d, name)
            try:
                with open(path) as fh:
                    req = json.load(fh)
                owner = to_checksum_address(req["owner"])
                account = hybrid_address(owner) if req.get("kind", "hybrid") == "hybrid" else owner
                try:
                    acc = self.r.account(account)
                except ValueError:  # not registered (yet)
                    if now <= int(req["strategy"]["deadline"]):
                        continue
                    raise P.PrefsError("not_registered", "the account was not registered before the deadline")
                if acc.owner != owner:
                    raise P.PrefsError("strategy_owner", "the account's pinned owner is another wallet")
                self.apply_strategy(req["strategy"], owner, account, now)
                out, res = "done", {"account": account}
            except Exception as e:
                out, res, req = "failed", {"error": str(e)}, None
                self.log("strategy_failed", file=name, error=str(e))
            os.makedirs(os.path.join(d, out), exist_ok=True)
            with open(os.path.join(d, out, name), "w") as fh:
                json.dump({"request": req, "result": res}, fh)
            os.remove(path)

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
        stale = now - g.last_price_time >= min(self.sa.report_every_s, g.params["maxPriceAge"] // 2,
                                               g.params["minPriceStable"] * 2 // 5)
        # SA-8 L-3: the pool is held off the market while the market is still at the stored anchor. The module accepts
        # a pure refresh (price == anchor) without the pool check: keep the anchor fresh (margin sends, hedge reports)
        # instead of following the pool or letting the anchor age out; risk-adding actions wait (they need the pool
        # within BOOK_BAND_BPS of the anchor anyway).
        if (pc.status != "ok" and g.last_price
                and abs(hl - g.last_price) * BPS <= g.last_price * BOOK_BAND_BPS):
            if stale:
                self.act("reportPrice", g.last_price)
                g = self.r.global_snap()
            self.alert("warn", "pool_held_off", f"pool {g.pool_price / 1e6:.4f} off HL {hl / 1e6:.4f} "
                                                f"({pc.dev_bps:.0f} bps) at the anchor: anchor refreshed, no risk-adding actions")
            return None, g
        if pc.status == "skip":
            self.alert("warn", "price_skip", f"pool {g.pool_price / 1e6:.4f} vs HL {hl / 1e6:.4f} differ "
                                             f"{pc.dev_bps:.0f} bps; skipping risk-adding actions this tick")
            return None, g
        price = S.sticky_price(pc.price, g.last_price, g.pool_price, g.params["poolBandBps"],
                               self.st.anchor_hysteresis_bps, self.st.band_safety)
        # SA-3 L-21: hold the anchor value (still re-reported for freshness) only while a fee is due and positive, and
        # only while the pool stays inside the booking band of it (a held anchor off the band blocks booking, swaps
        # and adds for every account)
        if (now < self._hold_until and price != g.last_price and g.last_price
                and abs(g.pool_price - g.last_price) * BPS <= g.pool_price * BOOK_BAND_BPS * self.st.band_safety):
            price = g.last_price
        if price != g.last_price or stale or g.clipped:
            before = g
            self.act("reportPrice", price)
            g = self.r.global_snap()
            if g.clipped:
                # SA-4 M-1: the anchor moves one poolBandBps step per minPriceStable; only an anchor that did not move
                # although its last move was stable is held by the 24 h budget (a guardian matter)
                stable = now >= before.last_price_moved + g.params["minPriceStable"]
                if g.last_price == before.last_price and stable:
                    # SA-5 M-2: the anchor is bound to refDriftBps of the guardian-confirmed level as well
                    why = " (refDriftBps from the confirmed level)" if g.at_drift_limit() else ""
                    lo, hi = price * 995 // 1000, price * 1005 // 1000
                    self.alert("warn", "anchor_budget", f"anchor clipped at {g.last_price / 1e6:.4f} (wanted "
                                                        f"{price / 1e6:.4f}){why}; guardian: approvePrice({lo}, "
                                                        f"{hi}, now + 1 h) after checking the market (<= 2 x poolBandBps wide)")
                else:
                    self.log("anchor_stepping", anchor=g.last_price, wanted=price)
        return price, g

    # ------------------------------------------------------------ per account
    # ------------------------------------------------------------ risk-off
    def risk_out(self, a: str, now: int) -> bool:
        """Is account `a` (Strategy riskOff) to be out of the pool now? Tracks when it left (min time out)."""
        pr = self.prefs_of(a)
        if not pr.get("risk_off"):
            if self.riskout.pop(a, None) is not None:
                self.log("riskoff_disabled", account=a)
            return False
        since = self.riskout.get(a)
        out = RO.account_out(bool(self.riskoff.st.get("on")), since, now, self.sa.riskoff_min_out_s)
        if out and since is None:
            self.riskout[a] = now
            self.log("riskoff_exit", account=a, signal=dict(self.riskoff.st))
        elif not out and since is not None:
            self.riskout.pop(a)
            self.log("riskoff_reenter", account=a, out_s=now - since)
        return out

    def exit_lp(self, a: str, g: GlobalSnap, price: int | None) -> AccountSnap:
        """Risk-off: burn every position (allowed in every state), then sell the HYPE into USDC within the module's
        exit window (exitTurnoverBps: a sell with no position held). Swaps need a price and a trusted anchor; until
        then the account waits with idle HYPE (still hedged if it was)."""
        s = self.r.account(a)
        if s.positions:
            sp, _ = self.r.slot0()
            k = BPS - self.st.burn_slippage_bps
            for p in s.positions:
                x, y = M.amounts_for_liquidity(sp, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu), p.liquidity)
                self.act("burnPosition", a, p.token_id, x * k // BPS, y * k // BPS)
                self.log("burned", account=a, token_id=p.token_id, why="risk_off")
            s = self.r.account(a)
        if price is None or s.positions or g.paused:
            return s
        min_amt = int(self.st.min_swap_usd / M.p_to_usd(price) * E18)
        if s.native <= min_amt:
            return s
        if not self.r.global_snap().trusted(self.now()):
            self.log("riskoff_sell_waits_trusted", account=a)
            return s
        # SA-4 L-6: an exit sale beyond the exit window falls back to the turnover window; SA-5 I-2: the module does
        # not split one sale between the windows, so sell into the exit room first and into the turnover room second
        exit_room = max(0, s.nav * int(g.params.get("exitTurnoverBps", 0)) // BPS - int(s.windows.get("exitUsed", 0)))
        turn_room = max(0, s.nav * g.params["swapTurnoverBps"] // BPS - s.windows["turnoverUsed"])
        sold_any = False
        for room in (exit_room, turn_room):
            amt = min(s.native - self.gas_reserve(s), int(room * 98 // 100) * E18 // price)
            if amt <= min_amt:
                continue
            sold = self.swap(a, True, amt, price)
            sold_any = True
            self.log("riskoff_sold", account=a, hype=sold / E18, left=(s.native - sold) / E18)
            s = self.r.account(a)
            if s.native - self.gas_reserve(s) <= min_amt:
                break
        if not sold_any:
            self.log("riskoff_sell_no_room", account=a, room=(exit_room + turn_room) / 1e6, hype=s.native / E18)
        return s

    def gas_reserve(self, s: AccountSnap) -> int:
        """SA-4 L-7 (1241): a 7702 account pays its own gas in native HYPE (revoke, withdrawals): never sell or
        deploy the last `eip7702_gas_reserve_hype` of it."""
        return int(self.sa.eip7702_gas_reserve_hype * E18) if s.kind == "eip7702" else 0

    def account_tick(self, a: str, price: int | None, g: GlobalSnap, now: int, hw: float):
        s = self.r.account(a)
        if not s.active:
            self.wind_down(s, g)
            return s
        led = self.ledger.client(a)
        if s.pending and not s.flow_seen and not g.trusted(self.now()):
            # SA-7 M-1: a flow that cannot be booked now is marked (sync books nothing, sets flowSeen), so the booking
            # resets the fee baseline even if the client brings the same amount back before it
            self.act("sync", a)
        if self.risk_out(a, now) and s.value >= self.sa.min_account_usd * 1e6:
            return self.account_tick_out(a, s, price, g, now)
        if price is None:
            led["target"] = led["short"]  # keep the hedge as is while prices disagree
            return s
        refused = int((self.state.d.get("fee_refusals", {}).get(a) or {}).get("n", 0))
        if refused >= self.sa.fee_refusals_stop:
            # SA-2 L-10 / SA-3 L-1: the account refused the fee on consecutive due dates: stop managing it (no new
            # margin, no LP deploy, hedge closed); removals and the client's exit are unaffected
            led["target"] = 0.0
            self.alert("warn", f"fee_refused_{a}", f"{a} refused the fee {refused}x: not managed any more")
            return s
        if s.value < self.sa.min_account_usd * 1e6:
            self.log("account_below_floor", account=a, value=s.value / 1e6)  # SA-3 L-20: read only
            return s
        hedged = bool(self.prefs_of(a)["hedged"])
        if not g.paused:
            g = self.r.global_snap()
            t = self.now()
            if s.pending and g.trusted(t):
                self.act("sync", a)  # SA-3 M-5: book a pending client flow at the first trusted moment
            if hedged:
                self.margin(s, g, price)
            target_hw, _, _ = self.width_for(a, g, hw)
            self.manage_lp(a, g, price, target_hw, hedged=hedged)
            self.fee(a, g, now)
        s = self.r.account(a)
        if hedged:
            lp_b, _ = s.lp_amounts(self.r.slot0()[0])
            self.ledger.set_target(a, (lp_b + s.native) / E18 * self.st.hedge_ratio)
        else:  # unhedged: no short; margin sent while it was hedged goes back into the account
            self.return_margin(s, self.r.global_snap(), close=False)
            s = self.r.account(a)
        self.report_equity(s)
        return s

    def account_tick_out(self, a: str, s: AccountSnap, price: int | None, g: GlobalSnap, now: int) -> AccountSnap:
        """Risk-off account while out: no margin, no LP; exit to USDC; fee as usual; hedge follows the idle HYPE
        (hedged) and, once it is sold, the short share is closed and the margin goes back INTO the account."""
        if not g.paused and price is not None:
            if s.pending and g.trusted(self.now()):
                self.act("sync", a)
        s = self.exit_lp(a, g, price)
        if not g.paused and price is not None:
            self.fee(a, g, now)
        s = self.r.account(a)
        hedged = bool(self.prefs_of(a)["hedged"])
        dust = int(self.st.min_swap_usd / M.p_to_usd(price) * E18) if price else 0
        if hedged and s.native > dust:
            self.ledger.set_target(a, s.native / E18 * self.st.hedge_ratio)  # still holding HYPE: keep it hedged
        else:
            self.return_margin(s, self.r.global_snap(), close=False)
            s = self.r.account(a)
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
            if not self.r.global_snap().trusted(self.now()):
                self.log("swap_waits_trusted", account=a)  # SA-3: a previous chunk moved the pool off the book band
                break
            chunk = min(amount - done, chunk_max)
            while True:
                try:  # the module's floor applies to the probe; the sent swap pins what the probe got (SA-3 L-22)
                    out = self.r.m.call("swap", a, sell_base, chunk, price, 0, sender=self.chain.signer.address)
                    break
                except TxRevert as e:
                    why = e.reason
                if "BelowMinOut" in why and chunk > 2 * min_amt:
                    chunk //= 2
                    continue
                self.log("swap_probe_revert", account=a, reason=why, chunk=chunk)
                return done
            self.act("swap", a, sell_base, chunk, price, int(out) * (BPS - SWAP_MIN_OUT_SLACK_BPS) // BPS)
            done += chunk
        return done

    def manage_lp(self, a: str, g: GlobalSnap, price: int, hw: float, hedged: bool = True):
        """Re-range (rerange_reason) and deploy idle funds at half-width `hw` (the account's preference)."""
        s = self.r.account(a)
        sp, tick = self.r.slot0()
        pr = self.prefs_of(a)
        why = rerange_reason(tick, s.positions, hw, pr["mode"], self.sa.edge_frac, int(pr.get("nonce", 0)),
                             self.ranges.get(a), self.sa.rewidth_tol, self.sa.auto_rewidth_factor)
        if why and why != "out_of_range":
            # an in-range position keeps earning: close it only if the turnover budget can pay the re-deploy now
            p0 = next(p for p in s.positions if S.in_range(tick, p.tl, p.tu))
            x, y = s.lp_amounts(sp)
            need = rerange_charge(x * price // E18 + y, tick, (p0.tl, p0.tu), S.range_ticks(price, hw, self.spacing),
                                  g.params["maxSlippageBps"], g.params["poolBandBps"])
            room = max(0, s.nav * g.params["swapTurnoverBps"] // BPS - s.windows["turnoverUsed"])
            if need > room * 0.9 or not g.trusted(self.now()):
                self.log("rerange_postponed", account=a, why=why, need=need / 1e6, room=room / 1e6)
                why = None
        if why:
            for p in s.positions:
                x, y = M.amounts_for_liquidity(sp, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu), p.liquidity)
                k = BPS - self.st.burn_slippage_bps
                self.act("burnPosition", a, p.token_id, x * k // BPS, y * k // BPS)
                self.log("burned", account=a, token_id=p.token_id, why=why)
            s = self.r.account(a)
        # swaps and adds must quote within the band of the anchor, and (SA-3) need a trusted anchor
        if abs(price - g.last_price) * BPS > g.last_price * g.params["poolBandBps"] * self.st.band_safety:
            self.log("deploy_skipped_anchor", account=a)
            return
        g = self.r.global_snap()
        if not g.trusted(self.now()):
            self.log("deploy_waits_trusted", account=a)
            return
        pos = s.positions[0] if s.positions else None
        tl, tu = (pos.tl, pos.tu) if pos else S.range_ticks(price, hw, self.spacing)
        buffer = s.value * self.sa.buffer_bps // BPS
        margin_left = max(0, int(s.value * self.sa.margin_frac) - max(s.hedge_equity, s.net_margin)) if hedged else 0
        free = max(0, s.usdc - buffer - margin_left)
        native = max(0, s.native - self.gas_reserve(s))
        hv = native * price // E18
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
        a0, a1 = max(0, s.native - self.gas_reserve(s)), max(0, s.usdc - buffer - margin_left)
        sa_, sb = M.sqrt_price_at_tick(tl), M.sqrt_price_at_tick(tu)
        liq = M.liquidity_for_amounts(sp, sa_, sb, a0 * 995 // 1000, a1 * 995 // 1000)
        u0, u1 = M.amounts_for_liquidity(sp, sa_, sb, liq)
        val = u0 * price // E18 + u1
        if liq <= 0 or val < self.sa.min_deploy_usd * 1e6:
            return
        # sliding 24 h window (SAWindow): capacity returns 24-27 h after use, no decay
        room = max(0, s.nav * g.params["swapTurnoverBps"] // BPS - s.windows["turnoverUsed"])
        charge = val  # SA-5 M-2: SABook.lpAdd charges an add at its whole principal
        if charge > room * 0.98:
            k = room * 0.98 / charge if charge else 0.0
            if val * k < self.sa.min_deploy_usd * 1e6:
                self.log("deploy_postponed_turnover", account=a, room=room / 1e6)
                return
            liq = int(liq * k)
        if not self.r.global_snap().trusted(self.now()):
            self.log("deploy_waits_trusted", account=a)  # the swaps above moved the pool off the book band
            return
        if pos is None:
            self.act("mintPosition", a, tl, tu, liq, a0, a1, price)
            self.ranges[a] = {"nonce": int(pr.get("nonce", 0)), "hw": round(hw, 6), "tl": tl, "tu": tu}
            self.log("minted", account=a, tl=tl, tu=tu, liquidity=liq, value_usd=val / 1e6, half_width=round(hw, 4),
                     mode=pr["mode"])
        else:
            self.act("increasePosition", a, pos.token_id, liq, a0, a1, price)
            self.log("increased", account=a, token_id=pos.token_id, liquidity=liq)

    def fee(self, a: str, g: GlobalSnap, now: int):
        s = self.r.account(a)
        if now < s.last_fee_time + g.params["feeInterval"]:
            return
        if s.pending and g.trusted(now):
            # book the client flow first: a price-dependent one resets the fee baseline (SA-7), so the fee below is
            # estimated on the books as they will be
            self.act("sync", a)
            s = self.r.account(a)
        if not g.trusted(now):
            # SA-2: chargeFee needs a fresh, unclipped anchor within the pool band that has not changed for
            # minPriceStable; hold the anchor value for a while so the window can elapse
            self._hold_until = max(self._hold_until, now + 2 * g.params["minPriceStable"] + self.sa.report_every_s)
            self.log("fee_waits_price", account=a, clipped=g.clipped, stable_in=max(
                0, g.last_price_moved + g.params["minPriceStable"] - now))
            return
        if s.hedge_equity and (s.hedge_clipped or now - s.hedge_time > g.params["maxPriceAge"]):
            self.report_equity(s, refresh=True)  # chargeFee needs a recent, unclipped hedge report (SA-1 L-12)
            s = self.r.account(a)
            if s.hedge_clipped:
                self.log("fee_waits_hedge", account=a)
                return
        fee, new_hwm = hwm_fee(s.fee_profit, s.hwm, g.params["feeBps"])
        if fee <= 0:
            return
        if not g.base_fresh(now):
            # SA-6 L-3: chargeFee needs the guardian's confirmation of the level within the last day
            self.log("fee_waits_confirm", account=a, base=g.price_base, base_time=g.price_base_time)
            lo, hi = g.last_price * 995 // 1000, g.last_price * 1005 // 1000
            self.alert("info", "fee_needs_confirm", f"fee due for {a}; the confirmed level is older than a day; "
                                                    f"guardian: approvePrice({lo}, {hi}, now + 1 h) after checking "
                                                    f"the market")
            return
        if not g.fee_gate():
            # SA-3 M-3: the anchor must not be above the pool nor more than poolBandBps above its trailing 24 h low;
            # SA-5 M-3: nor above the guardian-confirmed level by more than poolBandBps (only the guardian lifts it)
            self._hold_until = max(self._hold_until, now + 2 * g.params["minPriceStable"] + self.sa.report_every_s)
            self.log("fee_waits_gate", account=a, anchor=g.last_price, pool=g.pool_price, low=g.trailing_low,
                     base=g.price_base)
            if not g.base_gate():
                self.alert("info", "fee_needs_confirm", f"fee due for {a} but the anchor {g.last_price / 1e6:.4f} is "
                                                        f"above the confirmed level {g.price_base / 1e6:.4f} by more "
                                                        f"than poolBandBps; guardian: approvePrice around the market")
            return
        need = int(fee * 5 * self.sa.fee_idle_margin) + 1
        if s.usdc < need and s.positions:
            sp, _ = self.r.slot0()
            p = s.positions[0]
            _, y = M.amounts_for_liquidity(sp, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu), p.liquidity)
            if y > 0:
                q = min(1.0, (need - s.usdc) * 1.05 / y)
                liq = int(p.liquidity * q)
                x0, y0 = M.amounts_for_liquidity(sp, M.sqrt_price_at_tick(p.tl), M.sqrt_price_at_tick(p.tu), liq)
                k = BPS - self.st.burn_slippage_bps  # SA-3 L-22: removal minima
                self.act("decreasePosition", a, p.token_id, liq, x0 * k // BPS, y0 * k // BPS)
                s = self.r.account(a)
        if s.usdc * 2000 < fee * BPS:  # charged partially (20% of idle); the mark advances only by that part
            self.log("fee_partial", account=a, fee=fee / 1e6, idle=s.usdc / 1e6)
        refusals = self.state.d.setdefault("fee_refusals", {})
        try:
            self.act("chargeFee", a)
        except TxRevert as e:
            if "TransferMismatch" in (e.reason or "") or "BadExecution" in (e.reason or ""):
                # the account's code refused the transfer: counted once per fee interval (consecutive due dates)
                r = refusals.get(a) or {"n": 0, "t": 0}
                if r["n"] == 0 or now - int(r["t"]) >= g.params["feeInterval"]:
                    refusals[a] = {"n": r["n"] + 1, "t": now}
            raise
        refusals.pop(a, None)
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
        self.return_margin(s, g, close=True)

    def return_margin(self, s: AccountSnap, g: GlobalSnap, close: bool):
        """Close the account's hedge share, then pay its hedge equity back INTO the account. close=True (exited
        account): the ledger entry is closed at the end; close=False (a live account that switched to unhedged): the
        entry stays (it may switch back), on-chain hedge equity follows the ledger through report_equity."""
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
            if not close:
                return
            if s.hedge_equity:  # nothing left off-chain: write the on-chain residue down (a keeper-only decrease)
                self.act("reportHedgeEquity", a, 0)
            self.ledger.close(a)
            self.log("client_closed", account=a)
            return
        avail = min(g.treasury_usdc, g.treasury_allowance)
        # SA-1 H-1 / SA-4 M-3: the keeper may return at most min(on-chain hedge equity, net margin sent); always into
        # the account
        amt = min(eq, avail, s.keeper_return_cap)
        if amt >= 10 ** 6:
            self.act("returnHedgeMargin", a, amt)
            self.ledger.margin_returned(a, amt / 1e6)
            self.log("margin_returned", account=a, to=a, usdc=amt / 1e6)
        if eq - amt >= 10 ** 6:
            why = "on-chain hedge equity / net margin is lower (hedge profit): the treasury itself calls " \
                  "returnHedgeMargin" if s.keeper_return_cap < eq else "withdraw from HL to the treasury first"
            self.alert("warn", f"exit_margin_{a}", f"MANUAL: {(eq - amt) / 1e6:.2f} USDC of "
                                                   f"{'exited' if close else 'unhedged'} client {a} still "
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
                if req.get("strategy"):
                    try:
                        self.apply_strategy(req["strategy"], to_checksum_address(req["owner"]), acct, self.now())
                    except Exception as e:  # the account is live; it runs on the default until a valid re-sign
                        res["strategy_error"] = str(e)
                        self.alert("warn", f"strategy_{name}", f"strategy of {acct} not applied: {e}")
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
        try:
            price, g = self.anchor(now)
        except Exception as e:  # SA-3 L-21: a failed report never aborts the tick (no risk-adding actions)
            errors.append(f"anchor: {e}")
            self.log("anchor_failed", error=str(e))
            price, g = None, self.r.global_snap()
        try:
            self.process_requests()
        except Exception as e:
            errors.append(f"relayer: {e}")
        try:
            self.process_strategy_requests(now)
        except Exception as e:
            errors.append(f"strategy: {e}")
        hw = self.half_width(now, self.info.mid(self.cfg.hl.coin))
        accts = self.accounts()
        if any(self.prefs_of(a).get("risk_off") for a in accts):
            ro = self.riskoff.update(now)
            if ro.get("error") and now - int(ro.get("bar_close", 0)) > self.sa.riskoff_stale_alert_s:
                self.alert("warn", "riskoff_stale", f"risk-off signal not refreshed since bar {ro.get('bar_close')}: "
                                                    f"{ro.get('error')}")
        rows = {}
        for a in accts:
            self._sent = 0
            try:
                s = self.account_tick(a, price, g, now, hw)
                rows[a] = self.status_row(s, g, hw)
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
        try:
            self.write_recommendation(now, g, rows)
        except Exception as e:
            self.log("recommend_failed", error=str(e))
        self.log("tick", ok=not errors, accounts=len(rows), errors=errors)
        return self.get_status()

    def status_row(self, s: AccountSnap, g: GlobalSnap, hw_auto: float) -> dict:
        a = s.address
        tick = self.r.slot0()[1]
        hw, clamped, floor = self.width_for(a, g, hw_auto)
        ps = [vars(p) for p in s.positions]
        rng = None
        if s.positions:
            p = s.positions[0]
            rng = {"lower": round(M.p_to_usd(R.price_at_tick(p.tl)), 4), "upper": round(M.p_to_usd(R.price_at_tick(p.tu)),
                                                                                         4),
                   "in_range": any(S.in_range(tick, q.tl, q.tu) for q in s.positions),
                   "price": round(M.p_to_usd(g.pool_price), 4)}
        strategy = dict(P.public(self.prefs_of(a)), effective_width_bps=int(round(hw * 10_000)), clamped=clamped,
                        turnover_floor_bps=int(round(floor * 10_000)))
        risk = None
        if strategy.get("risk_off"):
            since = self.riskout.get(a)
            risk = {"enabled": True, "out": since is not None, "since": since,
                    "signal_on": bool(self.riskoff.st.get("on")), "signal_since": self.riskoff.st.get("since")}
        ret = round(s.profit / s.contributed * 100, 3) if s.contributed > 0 else None
        return {"owner": s.owner, "kind": s.kind, "active": s.active, "revoked": s.revoked,
                "until": s.until, "value": s.value / 1e6, "usdc": s.usdc / 1e6,
                "hype": s.native / 1e18, "positions": ps,
                "contributed": s.contributed / 1e6, "profit": s.profit / 1e6, "hwm": s.hwm / 1e6,
                "fees_paid": s.fees_paid / 1e6, "hedge_equity": s.hedge_equity / 1e6,
                "net_margin": s.net_margin / 1e6, "ledger": dict(self.ledger.clients().get(a, {})),
                "return_pct": ret, "range": rng, "strategy": strategy, "risk_off": risk}

    def write_recommendation(self, now: int, g: GlobalSnap, rows: dict):
        """GET /recommend (served by sa-api from sa.recommend_path), at most every sa.recommend_every_s."""
        if not self.sa.recommend_path or now - int(self.state.d.get("recommend_at", 0)) < self.sa.recommend_every_s:
            return
        ours = sum(float(r.get("value") or 0) for r in rows.values() if r.get("active"))
        doc = R.compute(self.cfg, hl_info=self.info, rpc=self.rpc, pool=dict(self.pool_entry(), module=self.r.m.address),
                        params=g.params, now=now, our_usd=max(self.sa.recommend_reference_usd, ours))
        R.write(self.sa.recommend_path, doc)
        self.state.d["recommend_at"] = now

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
               "risk_off": {k: self.riskoff.st.get(k) for k in ("on", "since", "off_since", "bar_close",
                                                                  "btc_below_ema_pct", "threshold_pct", "reason")},
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
