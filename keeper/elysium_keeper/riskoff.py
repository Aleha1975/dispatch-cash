"""Risk-off signal for the "LP + risk-off" product (docs/ARCHITECTURE.md): leave the pool for USDC when the market is
dangerous, re-enter when it is calm. Protection from crashes, not extra yield.

Rule (research 2026-11, scratchpad riskoff/: walk-forward, out of sample from 2025-09, HL candles only):
  d_t   = 1 - BTC_close_t / EMA_t        BTC 4 h closes from Hyperliquid, EMA span 180 bars (= 30 days), pandas
                                          ewm(adjust=True) weights
  thr   = 80th percentile of d over all history before the current month (minus an 18-bar purge), refit at the
          start of every month (needs >= 300 bars); ~4.3% in 2026-11
  on    = d_t > thr                      (optional: OR HYPE 7 d Parkinson vol > its own monthly q80)
  exit  when on at a closed 4 h bar; re-enter when off at a closed bar AND at least `min_out_s` (24 h) since the exit
About 2.5 exits per month in the backtest. Inputs are public chain-adjacent data only (HL info candleSnapshot, free).
The keeper evaluates only CLOSED bars, so the decision cannot flip inside a bar.
"""
from __future__ import annotations

import calendar
import math
import time
from dataclasses import dataclass

BAR_S = 4 * 3600
EMA_SPAN = 180
PURGE_BARS = 18
MIN_TRAIN = 300
RV_BARS = 42  # 7 days of 4 h bars
HISTORY_BARS = 5000  # HL candleSnapshot returns at most 5000 candles


@dataclass
class Signal:
    on: bool
    bar_close: int  # close time (s) of the last closed bar evaluated
    btc_below_ema: float  # d_t
    threshold: float  # thr of the current month (nan if not enough history)
    rv7d: float = float("nan")
    rv_threshold: float = float("nan")
    reason: str = ""

    def public(self) -> dict:
        def r(x):
            return None if x is None or (isinstance(x, float) and math.isnan(x)) else round(x * 100, 3)
        return {"on": self.on, "bar_close": self.bar_close, "btc_below_ema_pct": r(self.btc_below_ema),
                "threshold_pct": r(self.threshold), "rv7d_pct": r(self.rv7d), "rv_threshold_pct": r(self.rv_threshold),
                "reason": self.reason}


def ema_adjusted(xs: list[float], span: int = EMA_SPAN) -> list[float]:
    """pandas Series.ewm(span).mean() with adjust=True: sum (1-a)^i x_{t-i} / sum (1-a)^i."""
    a = 2.0 / (span + 1)
    num = den = 0.0
    out = []
    for x in xs:
        num = x + (1 - a) * num
        den = 1 + (1 - a) * den
        out.append(num / den)
    return out


def parkinson(h: list[float], lo: list[float], n: int = RV_BARS, bars_per_day: int = 6) -> list[float]:
    """Annualized Parkinson vol over the last n bars (nan before n bars)."""
    sq = [math.log(a / b) ** 2 / (4 * math.log(2)) if a > 0 and b > 0 else 0.0 for a, b in zip(h, lo)]
    out, s = [], 0.0
    for i, x in enumerate(sq):
        s += x
        if i >= n:
            s -= sq[i - n]
        out.append(math.sqrt(s / n * bars_per_day * 365) if i >= n - 1 else float("nan"))
    return out


def quantile_before(times: list[int], vals: list[float], cutoff: int, q: float = 0.8) -> float:
    """q-quantile (empirical, 'fraction <= x' convention of the research's percentile rank) of vals at bar close
    times < cutoff - PURGE_BARS bars; nan with fewer than MIN_TRAIN values."""
    lim = cutoff - PURGE_BARS * BAR_S
    xs = sorted(v for t, v in zip(times, vals) if t < lim and not math.isnan(v))
    if len(xs) < MIN_TRAIN:
        return float("nan")
    # rank(x) = #(train <= x) / n > q  <=>  x >= xs[ceil(q n)] (0-based index floor(q n))
    return xs[min(len(xs) - 1, int(math.floor(q * len(xs))))]


def month_start(ts: int) -> int:
    """UTC start of the month of `ts` (the threshold is refit monthly)."""
    t = time.gmtime(ts)
    return calendar.timegm((t.tm_year, t.tm_mon, 1, 0, 0, 0))


def closed_bars(candles: list[dict], now: int) -> tuple[list[int], list[float], list[float], list[float]]:
    """(close times s, closes, highs, lows) of the candles whose bar has closed by `now` (HL: t = open ms)."""
    rows = sorted(((int(c["t"]) // 1000 + BAR_S, float(c["c"]), float(c["h"]), float(c["l"])) for c in candles))
    rows = [r for r in rows if r[0] <= now]
    return [r[0] for r in rows], [r[1] for r in rows], [r[2] for r in rows], [r[3] for r in rows]


def evaluate(btc: list[dict], now: int, hype: list[dict] | None = None, use_rv: bool = False) -> Signal:
    """The signal at the last closed 4 h bar."""
    t, c, _, _ = closed_bars(btc, now)
    if len(t) < EMA_SPAN:
        return Signal(False, t[-1] if t else 0, float("nan"), float("nan"), reason="not_enough_history")
    ema = ema_adjusted(c)
    d = [1 - x / e for x, e in zip(c, ema)]
    # the EMA needs a warm-up: only bars after one span count as history
    th = quantile_before(t[EMA_SPAN:], d[EMA_SPAN:], month_start(t[-1]))
    on = not math.isnan(th) and d[-1] > th
    sig = Signal(on, t[-1], d[-1], th, reason="btc_below_ema" if on else "")
    if use_rv and hype:
        ht, _, hh, hl = closed_bars(hype, now)
        if len(ht) > RV_BARS:
            rv = parkinson(hh, hl)
            rth = quantile_before(ht, rv, month_start(ht[-1]))
            sig.rv7d, sig.rv_threshold = rv[-1], rth
            if not math.isnan(rth) and rv[-1] > rth:
                sig.on = True
                sig.reason = (sig.reason + "+" if sig.reason else "") + "hype_vol"
    return sig


class RiskOff:
    """Fetches HL 4 h candles (free endpoint) and keeps the global signal state in the keeper state:
    state["riskoff"] = {on, since, bar_close, ...}. Accounts follow it per account (min time out, sa_keeper)."""

    def __init__(self, info, state: dict, *, coin_btc: str = "BTC", coin_base: str = "HYPE", use_rv: bool = False,
                 refresh_s: int = 900, log=None):
        self.info, self.st, self.use_rv, self.refresh_s = info, state, use_rv, refresh_s
        self.coin_btc, self.coin_base = coin_btc, coin_base
        self.log = log or (lambda *a, **k: None)

    def update(self, now: int) -> dict:
        """Re-evaluate at most every refresh_s and only when a new 4 h bar may have closed. Never raises: a failed
        fetch keeps the last state (a stale signal does not flip anything) and is reported in `error`."""
        st = self.st
        last = int(st.get("checked_at", 0))
        if now - last < self.refresh_s and now < int(st.get("bar_close", 0)) + BAR_S:
            return st
        try:
            start = (now - HISTORY_BARS * BAR_S) * 1000
            btc = self.info.candles(self.coin_btc, "4h", start, now * 1000)
            hype = self.info.candles(self.coin_base, "4h", start, now * 1000) if self.use_rv else None
            sig = evaluate(btc, now, hype, self.use_rv)
        except Exception as e:  # keep the last decision
            st["error"] = str(e)[:200]
            st["checked_at"] = now
            self.log("riskoff_fetch_failed", error=str(e))
            return st
        was = bool(st.get("on", False))
        st.update(sig.public())
        st["checked_at"] = now
        st.pop("error", None)
        if sig.on and not was:
            st["since"] = sig.bar_close
            self.log("riskoff_on", **sig.public())
        elif not sig.on and was:
            st["off_since"] = sig.bar_close
            self.log("riskoff_off", **sig.public())
        return st


def account_out(signal_on: bool, out_since: int | None, now: int, min_out_s: int) -> bool:
    """Should a risk-off account be out of the pool? Out as soon as the signal is on; back in only when it is off and
    the account has been out at least min_out_s."""
    if signal_on:
        return True
    if out_since is None:
        return False
    return now - out_since < min_out_s
