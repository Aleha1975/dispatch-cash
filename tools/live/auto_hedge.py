#!/usr/bin/env python3
"""Elysium LP pilot: automatic delta hedge (HL HYPE perp short against the HYPE inside the v4 LP).

Each run (systemd timer, every 2 min):
  target short = HYPE in the LP positions (principal a0 + unclaimed fee HYPE f0 -- exactly what ely_live
  counts as lp_hype for hedge_ratio), times TARGET_RATIO.
  Rebalance only if |short/target - 1| > BAND (30%) and |diff| >= MIN_DIFF, back to ratio 1 +- BAND/2 (hysteresis);
  size rounded to 0.01. Gap between orders 4 h, 15 min when the hedge is off by > 0.5 HYPE.
Guards: order gap (above); > BIG_ORDER executes but is flagged; RPC/HL failure or inconsistent data
(LP amount jumps > 50% with price still, stale block, pool vs HL price apart, short vanished, long) -> no order,
alert once; a sell that would bring liquidation within LIQ_BUFFER of mark -> no order, alert; never long
(buys are reduce-only and <= short); never short more than MAX_SHORT_X * LP HYPE.
Kill switch: touch /root/tools/ely_lp/auto_hedge.off
Usage: auto_hedge.py [--dry-run]
Reads ely_live (imported, not forked) for the position; places via /opt/mprhedged hedge.place."""
import argparse, fcntl, json, math, os, sys, time, datetime

sys.path.insert(0, "/root/tools/ely_live")
import ely_live as E  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "auto_hedge_state.json")
LOG = os.path.join(HERE, "auto_hedge.log")
LOCK = os.path.join(HERE, ".auto_hedge.lock")
OFF = os.path.join(HERE, "auto_hedge.off")
OWNER = E.HL
VENUE = {"asset_id": 159, "sz_decimals": 2, "coin": "HYPE"}

TARGET_RATIO = 1.00
BAND = 0.30            # |short/target - 1| must exceed this (sweep 17.11, see auto_hedge_sweep.py)
REBAL_TO = 0.5         # 0 = rebalance to target; 0.5 = only back to ratio 1 +- BAND/2 (hysteresis)
MIN_DIFF = 0.05        # HYPE
COOLDOWN = 4 * 3600    # s between orders (attempts count)
URGENT_HYPE = 0.5      # if |short - target| exceeds this (HYPE), the gap is URGENT_GAP instead (0 = off)
URGENT_GAP = 15 * 60
BIG_ORDER = 0.6        # HYPE: bigger is executed but flagged in the message
LIQ_BUFFER = 0.20      # liquidation must stay >= 20% above mark after a sell
MAX_SHORT_X = 1.5      # never short more than 1.5x LP HYPE
MMR = 0.05             # HL HYPE maintenance margin (maxLeverage 10); matches liquidationPx on the live position
MIN_NOTIONAL = 10.0    # HL minimum for non-reduce-only orders
JUMP = 0.50            # LP HYPE change that needs a price move to be believed
STILL = 0.02           # "no price move" = pool price within 2% of the last run
CONFIRM_S = 10 * 60    # such a jump is believed only after the same reading for 10 min (covers a re-range gap)
MAX_DIVERGE = 0.06     # Elysium pool price vs HL mid
MAX_BLOCK_AGE = 600    # s
NO_CHANGE_EPS = 1e-9


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def london(ts=None):
    dt = datetime.datetime.fromtimestamp(ts or time.time(), datetime.timezone.utc)
    return dt.strftime("%d.%m %H:%M")  # London = UTC after 25.10.2026


def log(msg, dry=False):
    line = "%s %s%s" % (now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"), "[dry] " if dry else "", msg)
    print(line)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def load_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {"alerts": {}}


def save_state(st):
    json.dump(st, open(STATE + ".tmp", "w"), indent=1)
    os.replace(STATE + ".tmp", STATE)


# ---------------- Telegram ----------------
def _tg():
    sys.path.insert(0, "/opt/whale-copy")
    import owner_tg
    return owner_tg


def tg_order(text, dry):
    """Executed orders: every one must reach the owner. owner_tg.send() dedupes by text with digits
    stripped (24 h), which would mute the 2nd same-side order -- so send directly, no keyboard
    (same as buttons=[]), and log to /var/log/tg_sent.log like the gate does. Orders are <= 4/h by COOLDOWN."""
    if dry:
        print("TG(order, not sent):\n" + text); return
    try:
        t = _tg()
        t.tg("sendMessage", chat_id=t.CHAT, text=text, disable_web_page_preview="true")
        with open("/var/log/tg_sent.log", "a") as f:
            f.write("%s SENT auto_hedge.py order | %s\n" % (now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"), text[:160].replace("\n", " / ")))
    except Exception as e:
        log("tg order send failed: %s" % e)


def alert(st, kind, text, dry):
    """Once per kind until the condition clears (clear_alert)."""
    if kind in st["alerts"]:
        return
    if dry:
        print("TG(alert %s, not sent):\n%s" % (kind, text)); return
    st["alerts"][kind] = int(time.time())
    try:
        _tg().send(text, buttons=[])
    except Exception as e:
        log("tg alert send failed: %s" % e)


def clear_alert(st, kind):
    st["alerts"].pop(kind, None)


# ---------------- data ----------------
def read_lp():
    """HYPE in the LP at the chain head. Raises on any RPC failure (E.pos_state swallows errors on the
    position-info call, so a position that reads as empty is re-checked with a direct liquidity call)."""
    head = int(E.rpc("eth_blockNumber", []), 16)
    bts = int(E.rpc("eth_getBlockByNumber", [hex(head), False])["timestamp"], 16)
    s0, _liq = E.sload([E.POOL, E.add(E.POOL, 3)], head)
    sp = s0 & ((1 << 160) - 1); tick = E.s24(s0 >> 160); P = E.price(sp)
    if sp == 0:
        raise RuntimeError("pool slot0 is empty")
    hype, usdc, Lsum, parts = 0.0, 0.0, 0, []
    for tid in E.POSITIONS:
        p = E.pos_state(tid, head, sp, tick)
        if p is None:
            raw = E.call(E.POSM, E.sel("getPositionLiquidity(uint256)") + tid.to_bytes(32, "big"), head)
            if int.from_bytes(raw[:32], "big") != 0:
                raise RuntimeError("position %d has liquidity but reading it failed" % tid)
            continue
        hype += p["a0"] + p["f0"]; usdc += p["a1"] + p["f1"]; Lsum += p["L"]
        parts.append(dict(id=tid, lo=p["lo"], hi=p["hi"], a0=round(p["a0"], 4), f0=round(p["f0"], 4),
                          in_range=p["lo"] <= tick < p["hi"]))
    return dict(block=head, block_ts=bts, P=P, tick=tick, hype=hype, usdc=usdc, L=Lsum, parts=parts)


def read_hl():
    chs = E.hl({"type": "clearinghouseState", "user": OWNER})
    mid = float(E.hl({"type": "allMids"})["HYPE"])
    pos = next((p["position"] for p in chs["assetPositions"] if p["position"]["coin"] == "HYPE"), None)
    szi = float(pos["szi"]) if pos else 0.0
    free = float(chs.get("withdrawable") or 0)
    try:  # unified account: perp margin comes from spot USDC; perp 'withdrawable' then reads 0
        sp = E.hl({"type": "spotClearinghouseState", "user": OWNER})
        free = max(free, float(dict(sp.get("tokenToAvailableAfterMaintenance") or []).get(0, 0)))
    except Exception:
        pass
    out = dict(mark=mid, szi=szi, short=-szi if szi < 0 else 0.0, withdrawable=free,
               liq=float(pos["liquidationPx"]) if pos and pos.get("liquidationPx") else None,
               lev=float(pos["leverage"]["value"]) if pos else 3.0,
               raw=float(pos["leverage"].get("rawUsd") or 0) if pos else 0.0,
               margin=float(pos["marginUsed"]) if pos else 0.0,
               isolated=(pos["leverage"]["type"] == "isolated") if pos else True)
    return out


def est_liq_after_sell(h, add):
    """Isolated short: liq = rawUsd / (size * (1 + mmr)). A sell adds add*mark to rawUsd plus the margin HL
    can pull from free balance (at most add*mark/lev, at most withdrawable) -- conservative: only what is free."""
    S = h["short"] + add
    raw = h["raw"] + add * h["mark"] + min(h["withdrawable"], add * h["mark"] / h["lev"])
    if h["short"] < 0.005:  # fresh position: margin = notional/lev
        raw = add * h["mark"] * (1 + 1 / h["lev"])
    return raw / (S * (1 + MMR))


# ---------------- decision ----------------
def gap_for(info):
    """Minimum time since the last order: COOLDOWN normally, URGENT_GAP when the hedge is off by more than
    URGENT_HYPE (a fast move through the narrow range must not wait hours)."""
    if URGENT_HYPE and abs(info["target"] - info["short"]) > URGENT_HYPE:
        return min(COOLDOWN, URGENT_GAP)
    return COOLDOWN


def decide(lp, h, st):
    """Return (action, info). action in {None, 'sell', 'buy'}; info has size/reason/problem."""
    target = max(lp["hype"] * TARGET_RATIO, 0.0)
    short = h["short"]
    ratio = short / target if target > 0 else (math.inf if short > 0 else 1.0)
    info = dict(target=round(target, 4), short=short, ratio=None if math.isinf(ratio) else round(ratio, 4))
    off = (target == 0 and short > 0) or (target > 0 and abs(ratio - 1) > BAND)
    goal = target
    if REBAL_TO > 0 and target > 0:  # hysteresis: stop at ratio 1 +- BAND*REBAL_TO on the side we came from
        goal = target * (1 + math.copysign(BAND * REBAL_TO, ratio - 1))
    diff = goal - short
    if not off or abs(diff) < MIN_DIFF:
        info["reason"] = "в полосе (|ratio-1|<=%.0f%% или |diff|<%.2f)" % (BAND * 100, MIN_DIFF)
        return None, info
    size = round(abs(diff), 2)
    if diff > 0:  # need more short
        size = min(size, round(MAX_SHORT_X * lp["hype"] - short, 2))
        if size * h["mark"] < MIN_NOTIONAL:
            bump = math.ceil(MIN_NOTIONAL * 1.05 / h["mark"] * 100) / 100
            if short + bump <= target * (1 + BAND) and short + bump <= MAX_SHORT_X * lp["hype"]:
                info["note"] = "размер поднят до минимума HL $%.0f: %.2f -> %.2f" % (MIN_NOTIONAL, size, bump)
                size = bump
            else:
                info["reason"] = "продажа %.2f меньше минимума HL $%.0f" % (size, MIN_NOTIONAL)
                return None, info
        if size <= 0:
            info["reason"] = "потолок 1.5x LP"; return None, info
        im = size * h["mark"] / h["lev"]
        if im > h["withdrawable"] + 0.5:
            info["problem"] = "margin"
            info["reason"] = "на HL свободно $%.2f, а для продажи %.2f HYPE нужно ~$%.2f маржи" % (h["withdrawable"], size, im)
            return None, info
        liq2 = est_liq_after_sell(h, size)
        info["liq_after"] = round(liq2, 2)
        if liq2 < h["mark"] * (1 + LIQ_BUFFER):
            info["problem"] = "margin"
            info["reason"] = "после продажи ликвидация %.2f < марк+%d%% (%.2f)" % (liq2, LIQ_BUFFER * 100, h["mark"] * (1 + LIQ_BUFFER))
            return None, info
        act = "sell"
    else:
        size = min(size, round(short, 2))  # reduce-only, never long
        if size <= 0:
            info["reason"] = "нечего откупать"; return None, info
        act = "buy"
    info["size"] = size
    info["new_ratio"] = round((short + (size if act == "sell" else -size)) / target, 4) if target > 0 else None
    return act, info


def sanity(lp, h, st):
    """None if data look consistent, else a short reason (Russian). Also handles 'jump confirm'."""
    if time.time() - lp["block_ts"] > MAX_BLOCK_AGE:
        return "блок Elysium старый (%d c)" % (time.time() - lp["block_ts"])
    if abs(lp["P"] / h["mark"] - 1) > MAX_DIVERGE:
        return "цена пула %.2f и HL %.2f разошлись > %d%%" % (lp["P"], h["mark"], MAX_DIVERGE * 100)
    if h["szi"] > 0:
        return "на HL лонг HYPE %.2f (должен быть шорт)" % h["szi"]
    if h["short"] > 0 and not h["isolated"]:
        return "шорт не изолированный"
    last = st.get("last_seen") or {}
    if last.get("short", 0) >= MIN_DIFF and h["short"] == 0 and not st.get("last_order_buy_all"):
        return "шорт %.2f пропал (ликвидация?) -- сам не открываю" % last["short"]
    prev = last.get("hype")
    if prev and prev > MIN_DIFF and abs(lp["hype"] / prev - 1) > JUMP and abs(lp["P"] / last["P"] - 1) < STILL:
        sus = st.get("suspect")
        if sus and abs(lp["hype"] - sus["hype"]) <= max(0.02 * sus["hype"], 0.005) and lp["L"] == sus["L"]:
            if time.time() - sus["ts"] >= CONFIRM_S:
                st.pop("suspect", None)
                return None  # same reading for CONFIRM_S -> real liquidity change (re-range, add, remove)
            return "HYPE в LP %.3f -> %.3f без движения цены; жду %d мин подтверждения" % (prev, lp["hype"], CONFIRM_S // 60)
        st["suspect"] = dict(hype=lp["hype"], L=lp["L"], ts=int(time.time()))
        return "HYPE в LP %.3f -> %.3f (>%d%%) без движения цены; жду подтверждения" % (prev, lp["hype"], JUMP * 100)
    st.pop("suspect", None)
    return None


# ---------------- execution ----------------
def execute(act, info, lp, h, st, dry):
    sys.path.insert(0, "/opt/mprhedged")
    os.environ.setdefault("MPRH_DATA", "/opt/mprhedged/data")
    import hedge
    size = info["size"]
    st["last_order_ts"] = int(time.time())  # attempts count toward the cooldown
    r = hedge.place(OWNER, act == "buy", size, h["mark"], VENUE, reduce_only=(act == "buy"))
    px = None
    try:
        s0 = r["response"]["response"]["data"]["statuses"][0]
        px = float(s0["filled"]["avgPx"]); filled = float(s0["filled"]["totalSz"])
    except Exception:
        filled = None
    if not r.get("ok") or r.get("skipped"):
        log("ORDER FAIL %s %.2f: %s" % (act, size, r.get("error") or r.get("skipped")))
        alert(st, "order_fail", "Хедж Elysium: ордер %s %.2f HYPE не прошёл: %s. Повтор не раньше чем через 15 мин." %
              ("продажа" if act == "sell" else "откуп", size, str(r.get("error") or r.get("skipped"))[:200]), dry)
        return
    clear_alert(st, "order_fail")
    time.sleep(2)
    try:
        h2 = read_hl()
    except Exception:
        h2 = dict(h, short=h["short"] + (size if act == "sell" else -size), liq=None)
    tgt = info["target"]
    rb = h["short"] / tgt if tgt else None; ra = h2["short"] / tgt if tgt else None
    st["last_order"] = dict(ts=st["last_order_ts"], side=act, size=size, px=px, short_after=h2["short"])
    st["last_order_buy_all"] = act == "buy" and h2["short"] == 0
    log("ORDER %s %.2f filled %s @ %s short %.2f -> %.2f ratio %s -> %s liq %s" %
        (act, size, filled, px, h["short"], h2["short"], rb and round(rb, 3), ra and round(ra, 3), h2["liq"]))
    big = size > BIG_ORDER
    text = ("%sХедж Elysium %s: %s %.2f HYPE по %s\n"
            "Шорт %.2f -> %.2f HYPE (в LP %.3f)\n"
            "Покрытие %s -> %s\n"
            "Ликвидация %s (марк %.2f)%s") % (
        "Крупный ордер (>%.1f). " % BIG_ORDER if big else "", london(), "продал" if act == "sell" else "откупил",
        size, ("%.3f" % px) if px else "?", h["short"], h2["short"], lp["hype"],
        ("%.0f%%" % (rb * 100)) if rb is not None else "-", ("%.0f%%" % (ra * 100)) if ra is not None else "-",
        ("%.2f" % h2["liq"]) if h2.get("liq") else "-", h["mark"],
        "" if px else "\nЦена исполнения не пришла -- проверьте позицию")
    tg_order(text, dry)


def run(dry):
    st = load_state(); st.setdefault("alerts", {})
    if os.path.exists(OFF):
        log("выключено файлом %s" % OFF, dry); return
    try:
        lp = read_lp()
    except Exception as e:
        log("NO ORDER: RPC Elysium: %s" % str(e)[:200], dry)
        alert(st, "data", "Хедж Elysium: не читается позиция LP (RPC): %s. Ордера не ставлю." % str(e)[:150], dry)
        if not dry: save_state(st)
        return
    try:
        h = read_hl()
    except Exception as e:
        log("NO ORDER: HL: %s" % str(e)[:200], dry)
        alert(st, "data", "Хедж Elysium: Hyperliquid не отдаёт данные: %s. Ордера не ставлю." % str(e)[:150], dry)
        if not dry: save_state(st)
        return
    prob = sanity(lp, h, st)
    base = "LP %.4f HYPE (%s) pool %.3f mark %.3f short %.2f liq %s" % (
        lp["hype"], ",".join("%d:%s" % (p["id"], "in" if p["in_range"] else "OUT") for p in lp["parts"]) or "none",
        lp["P"], h["mark"], h["short"], h["liq"])
    if prob:
        log("NO ORDER (data): %s | %s" % (prob, base), dry)
        alert(st, "data", "Хедж Elysium: данные не сходятся -- %s. Ордера не ставлю." % prob, dry)
        if not dry: save_state(st)
        return
    clear_alert(st, "data")
    act, info = decide(lp, h, st)
    msg = "%s | target %.4f ratio %s" % (base, info["target"], info["ratio"])
    if info.get("problem") == "margin":
        log("NO ORDER (margin): %s | %s" % (info["reason"], msg), dry)
        alert(st, "margin", "Хедж Elysium, тревога: нужно допродать HYPE, но %s. Нужна маржа на HL -- решение за вами." % info["reason"], dry)
    elif act is None:
        clear_alert(st, "margin")
        log("hold: %s | %s" % (info["reason"], msg), dry)
    else:
        clear_alert(st, "margin")
        wait = gap_for(info) - (time.time() - st.get("last_order_ts", 0))
        plan = "%s %.2f -> ratio %s%s%s" % (act, info["size"], info.get("new_ratio"),
                                            (" liq~%.2f" % info["liq_after"]) if "liq_after" in info else "",
                                            (" (%s)" % info["note"]) if info.get("note") else "")
        if wait > 0:
            log("WAIT cooldown %ds: would %s | %s" % (wait, plan, msg), dry)
        elif dry:
            log("WOULD %s | %s" % (plan, msg), dry)
        else:
            log("DO %s | %s" % (plan, msg))
            execute(act, info, lp, h, st, dry)
            try:
                h = read_hl()
            except Exception:
                pass
    st["last_seen"] = dict(ts=int(time.time()), block=lp["block"], hype=lp["hype"], L=lp["L"], P=lp["P"],
                           mark=h["mark"], short=h["short"], liq=h["liq"])
    if not dry:
        save_state(st)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="print the decision; no order, no Telegram, state untouched")
    a = ap.parse_args()
    fd = open(LOCK, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("another run holds the lock"); return
    run(a.dry_run)


if __name__ == "__main__":
    main()
