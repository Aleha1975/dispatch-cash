#!/usr/bin/env python3
"""Parameter sweep of the auto_hedge rule over the pilot (read-only). Uses auto_hedge.decide() and
auto_hedge.sanity() themselves (module constants overridden per run; sanity's clock faked), so the 10-min
confirmation of a liquidity jump (14.11 re-range) is simulated exactly as live.
LP HYPE/USDC(t) rebuilt from on-chain ModifyLiquidity events (ely_live.POSITIONS); fee income is common to all
rules and left out. P&L = LP mark-to-market at fixed liquidity (common) + hedge (short * -dP) - HL taker fees.
Grids: '30m' = HL 30-min opens (ely_live curve), '5m' = Elysium pool 5-min closes (forward-filled).
Margin is assumed available (live account has withdrawable 0 -- see report). Usage: auto_hedge_sweep.py"""
import json, sys, math, itertools, os
sys.path.insert(0, "/root/tools/ely_live"); sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ely_live as E
import auto_hedge as A
from eth_utils import keccak

FEE = 0.00045
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "auto_hedge_sweep_cache.json")
ML_T = "0x" + keccak(text="ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)").hex()


def fetch():
    if os.path.exists(CACHE):
        return json.load(open(CACHE))
    head = int(E.rpc("eth_blockNumber", []), 16); ev = []; frm = E.INIT_BLOCK
    while frm <= head:
        to = min(head, frm + 399999)
        for lg in E.rpc("eth_getLogs", [{"address": E.PM, "fromBlock": hex(frm), "toBlock": hex(to), "topics": [ML_T, "0x" + E.POOLID.hex()]}]):
            d = bytes.fromhex(lg["data"][2:]); tid = int.from_bytes(d[96:128], "big")
            if tid in E.POSITIONS:
                ev.append([int(lg["blockTimestamp"], 16), tid, E.s24(int.from_bytes(d[0:32], "big")),
                           E.s24(int.from_bytes(d[32:64], "big")), E.sint(d[64:96], 256)])
        frm = to + 1
    fills = [dict(t=f["time"] // 1000, b=f["side"] == "B", sz=float(f["sz"]), px=float(f["px"]), fee=float(f["fee"]))
             for f in E.hl({"type": "userFillsByTime", "user": E.HL, "startTime": (E.PILOT_START - 3600) * 1000}) if f["coin"] == "HYPE"]
    st = json.load(open(E.STATE))
    d = dict(ev=sorted(ev), fills=fills, m5={k: v[3] for k, v in st["m5"].items()}, c30={k: v[0] for k, v in st["curve"].items()})
    json.dump(d, open(CACHE, "w")); return d


D = fetch()
EV, FILLS = D["ev"], D["fills"]
T_OPEN = FILLS[0]["t"]; OPEN_SZ = sum(f["sz"] for f in FILLS if f["t"] == T_OPEN and not f["b"]); OPEN_PX = FILLS[0]["px"]
HAND = [f for f in FILLS if f["t"] > T_OPEN]


def liq_at(t):
    L = {}
    for te, tid, lo, hi, dl in EV:
        if te <= t:
            x = L.setdefault(tid, [lo, hi, 0]); x[2] += dl
    return [v for v in L.values() if v[2] > 0]


def lp_amt(pos, P):
    sp = math.sqrt(P / 1e12) * 2**96; h = u = 0.0
    for lo, hi, l in pos:
        a0, a1 = E.amounts(sp, E.sqrt_at(lo), E.sqrt_at(hi), l); h += a0 / 1e18; u += a1 / 1e6
    return h, u


def series(grid):
    if grid == "5m":
        m = {int(k): v for k, v in D["m5"].items()}; ks = sorted(m); out = []; P = None; i = 0
        t0 = T_OPEN - T_OPEN % 300 + 300
        for t in range(t0, max(ks) + 300, 300):
            while i < len(ks) and ks[i] <= t: P = m[ks[i]]; i += 1
            if P: out.append((t, P))
        return out
    return sorted((int(k), v) for k, v in D["c30"].items() if int(k) > T_OPEN)


def simulate(grid, band, cooldown, rebal_to, hand=False, urgent=0.0):
    A.BAND, A.COOLDOWN, A.REBAL_TO, A.URGENT_HYPE = band, cooldown, rebal_to, urgent
    ser = series(grid); clock = [0]
    A.time.time = lambda: clock[0]
    st = {"alerts": {}}; short = OPEN_SZ; raw = OPEN_SZ * OPEN_PX * (1 + 1 / 3); last = -1e18
    n = fees = hedge = lpm = 0.0; devs = []; prev = None; fi = 0; hf = sorted(HAND, key=lambda f: f["t"])
    for t, P in ser:
        clock[0] = t
        pos = liq_at(t)
        if prev:  # step P&L at the previous step's liquidity and short
            pt, pP, ppos, pshort = prev
            lpm += (lambda a, b: (a[0] * P + a[1]) - (b[0] * pP + b[1]))(lp_amt(ppos, P), lp_amt(ppos, pP))
            hedge += pshort * (pP - P)
        if hand:
            while fi < len(hf) and hf[fi]["t"] <= t:
                f = hf[fi]; short += -f["sz"] if f["b"] else f["sz"]; fees += f["fee"]; n += 1; fi += 1
        hy, _ = lp_amt(pos, P)
        if not hand:
            lp = dict(hype=hy, P=P, block_ts=t, L=sum(x[2] for x in pos))
            h = dict(mark=P, szi=-short, short=short, withdrawable=1e9, liq=None, lev=3, raw=raw, margin=0, isolated=True)
            if A.sanity(lp, h, st) is None:
                act, info = A.decide(lp, h, st)
                if act and t - last >= A.gap_for(info):
                    sz = info["size"]
                    if act == "sell": raw += sz * P * (1 + 1 / 3); short = round(short + sz, 2)
                    else: raw *= (short - sz) / short if short else 0; short = round(short - sz, 2)
                    last = t; n += 1; fees += sz * P * FEE
                    st["last_order_buy_all"] = act == "buy" and short == 0
                st["last_seen"] = dict(hype=hy, P=P, short=short, L=lp["L"])
        if hy > 0:
            devs.append((t, abs(short / hy - 1), abs(short - hy), hy))
        prev = (t, P, pos, short)
    days = (ser[-1][0] - ser[0][0]) / 86400
    rr = [e[0] for e in EV if e[4] < 0]  # re-range moments
    # maxX: max |ratio-1| while LP HYPE >= 0.5 and outside the re-range window (near the top edge LP HYPE -> 0
    # and the ratio explodes on a few hundredths of HYPE); maxHYPE: max |short - LP HYPE| in HYPE
    dev_x = [d for t, d, _, hy in devs if hy >= 0.5 and not any(r - 600 <= t <= r + 3600 for r in rr)]
    return dict(orders=int(n), per_day=n / days, fees=fees, hedge=hedge, lp=lpm, total=lpm + hedge - fees,
                mean_dev=sum(d[1] for d in devs) / len(devs), max_dev=max(d[1] for d in devs), max_dev_x=max(dev_x),
                max_abs=max(d[2] for d in devs), days=days)


if __name__ == "__main__":
    rows = []
    for grid in ("30m", "5m"):
        hd = simulate(grid, 0, 0, 0, hand=True)
        print("\n== grid %s, %.2f days, LP mark-to-market (common) $%.2f; unhedged would be $%.2f" % (grid, hd["days"], hd["lp"], hd["lp"]))
        print("%-22s %6s %6s %7s %8s %8s %6s %6s %7s %7s" % ("rule", "orders", "/day", "fees$", "hedge$", "total$", "mean%", "max%", "maxX%", "maxHYPE"))
        print("%-22s %6d %6.1f %7.3f %8.2f %8.2f %6.1f %6.0f %7.0f %7.2f" % ("HAND (actual fills)", hd["orders"], hd["per_day"], hd["fees"], hd["hedge"], hd["total"], hd["mean_dev"] * 100, hd["max_dev"] * 100, hd["max_dev_x"] * 100, hd["max_abs"]))
        combos = [(b, c, r, 0.0) for b, c, r in itertools.product((0.10, 0.15, 0.20, 0.25, 0.30), (900, 3600, 14400), (0.0, 0.5))]
        combos += [(b, c, r, u) for b, c, r, u in itertools.product((0.20, 0.25, 0.30), (3600, 14400), (0.0, 0.5), (0.5, 0.75, 1.0))]
        for band, cd, rt, ur in combos:
            r = simulate(grid, band, cd, rt, urgent=ur); r.update(grid=grid, band=band, cd=cd, rt=rt, urgent=ur); rows.append(r)
            print("%-22s %6d %6.1f %7.3f %8.2f %8.2f %6.1f %6.0f %7.0f %7.2f" % (
                "b%2d%% gap%3dm %s%s" % (band * 100, cd // 60, "X/2" if rt else "->1", (" u%.2f" % ur) if ur else ""), r["orders"], r["per_day"], r["fees"],
                r["hedge"], r["total"], r["mean_dev"] * 100, r["max_dev"] * 100, r["max_dev_x"] * 100, r["max_abs"]))
    json.dump(rows, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "auto_hedge_sweep.json"), "w"), indent=0)
