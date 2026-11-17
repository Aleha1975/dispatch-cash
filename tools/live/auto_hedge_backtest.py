#!/usr/bin/env python3
"""Backtest the auto_hedge rule over the pilot vs the hand hedge (read-only).
LP HYPE(t) rebuilt from on-chain ModifyLiquidity events (tokenIds in ely_live.POSITIONS) and the pool price
from ely_live state.json 5-min candles (close, forward-filled). Unclaimed-fee HYPE is ignored (small).
The rule runs every 5 min (the timer is 2 min, the pool price only changes on swaps), 15-min cooldown, fill at
the pool price, fee 0.045% taker. Hand = actual HL HYPE fills after the initial open."""
import json, sys, math
sys.path.insert(0, "/root/tools/ely_live"); sys.path.insert(0, "/root/tools/ely_lp")
import ely_live as E
import auto_hedge as A
from eth_utils import keccak

FEE = 0.00045
ML_T = "0x" + keccak(text="ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)").hex()
st = json.load(open(E.STATE))
m5 = {int(k): v for k, v in st["m5"].items()}
head = int(E.rpc("eth_blockNumber", []), 16)
ev = []
frm = E.INIT_BLOCK
while frm <= head:
    to = min(head, frm + 399999)
    for lg in E.rpc("eth_getLogs", [{"address": E.PM, "fromBlock": hex(frm), "toBlock": hex(to), "topics": [ML_T, "0x" + E.POOLID.hex()]}]):
        d = bytes.fromhex(lg["data"][2:])
        tid = int.from_bytes(d[96:128], "big")
        if tid in E.POSITIONS:
            ev.append((int(lg["blockTimestamp"], 16), tid, E.s24(int.from_bytes(d[0:32], "big")),
                       E.s24(int.from_bytes(d[32:64], "big")), E.sint(d[64:96], 256)))
    frm = to + 1
ev.sort()
print("liquidity events:", [(e[0], e[1], e[4]) for e in ev])

fills = [dict(t=f["time"] // 1000, b=f["side"] == "B", sz=float(f["sz"]), px=float(f["px"]), fee=float(f["fee"]))
         for f in E.hl({"type": "userFillsByTime", "user": E.HL, "startTime": (E.PILOT_START - 3600) * 1000}) if f["coin"] == "HYPE"]
t_open = fills[0]["t"]
open_sz = sum(f["sz"] for f in fills if f["t"] == t_open and not f["b"])
hand = [f for f in fills if f["t"] > t_open]

def lp_hype(t, P):
    L = {}
    for (te, tid, lo, hi, dl) in ev:
        if te <= t:
            x = L.setdefault(tid, [lo, hi, 0]); x[2] += dl
    sp = math.sqrt(P / 1e12) * 2**96
    return sum(E.amounts(sp, E.sqrt_at(lo), E.sqrt_at(hi), l)[0] / 1e18 for lo, hi, l in L.values() if l > 0)

t0 = max(t_open, ev[0][0]) + 300; t0 -= t0 % 300
end = max(m5); P = None; ks = sorted(m5)
short_auto, last_ord, orders, fees_auto = open_sz, -1e18, [], 0.0
short_hand = open_sz
raw_auto = open_sz * fills[0]["px"] * (1 + 1 / 3)  # isolated 3x at the initial open
skipped_margin = 0
resid_auto = resid_hand = 0.0; dev_auto = dev_hand = 0.0; n = 0; maxdev_a = maxdev_h = 0.0
prevP = None; prev_la = None
i = 0
for t in range(t0, end + 300, 300):
    while i < len(ks) and ks[i] <= t:
        P = m5[ks[i]][3]; i += 1
    if P is None: continue
    for f in hand:
        if t - 300 < f["t"] <= t: short_hand += -f["sz"] if f["b"] else f["sz"]
    lh = lp_hype(t, P)
    if prevP is not None:  # residual delta P&L over the step: (LP HYPE - short) * dP
        resid_auto += (prev_la[0] - prev_la[1]) * (P - prevP); resid_hand += (prev_la[0] - prev_la[2]) * (P - prevP)
    if lh > 0:
        da, dh = abs(short_auto / lh - 1), abs(short_hand / lh - 1)
        dev_auto += da; dev_hand += dh; n += 1; maxdev_a = max(maxdev_a, da); maxdev_h = max(maxdev_h, dh)
    h = dict(mark=P, szi=-short_auto, short=short_auto, withdrawable=1e9, liq=None, lev=3, raw=raw_auto,
             margin=0, isolated=True)  # free margin assumed available (live account: withdrawable 0!)
    act, info = A.decide(dict(hype=lh, P=P), h, {})
    if info.get("problem") == "margin": skipped_margin += 1
    if act and t - last_ord >= A.COOLDOWN:
        sz = info["size"]
        if act == "sell": raw_auto += sz * P * (1 + 1 / 3); short_auto = round(short_auto + sz, 2)
        else: raw_auto *= (short_auto - sz) / short_auto; short_auto = round(short_auto - sz, 2)
        last_ord = t
        fees_auto += sz * P * FEE; orders.append((t, act, sz, round(P, 3), round(lh, 3)))
    prevP, prev_la = P, (lh, short_auto, short_hand)

fees_hand = sum(f["fee"] for f in hand)
print("window %s .. %s UTC, %d steps" % (A.london(t0), A.london(end), n))
print("AUTO: %d orders, volume %.2f HYPE, fees $%.3f, mean |ratio-1| %.1f%%, max %.0f%%, residual delta P&L $%.2f" %
      (len(orders), sum(o[2] for o in orders), fees_auto, dev_auto / n * 100, maxdev_a * 100, resid_auto))
print("HAND: %d orders, volume %.2f HYPE, fees $%.3f, mean |ratio-1| %.1f%%, max %.0f%%, residual delta P&L $%.2f" %
      (len(hand), sum(f["sz"] for f in hand), fees_hand, dev_hand / n * 100, maxdev_h * 100, resid_hand))
print("AUTO steps blocked by the margin guard: %d (x5 min)" % skipped_margin)
for o in orders: print("  ", A.london(o[0]), *o[1:])
