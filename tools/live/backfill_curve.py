import json, time, sys
from concurrent.futures import ThreadPoolExecutor
import ely_live as E
st = json.load(open(E.STATE))
ds = st["day_snaps"]; s0 = ds[str(E.PILOT_START)]
p0 = s0["hl"]; v0 = s0["hype"] * p0 + s0["usdc"]
now = int(time.time()); STEP = 1800
fills = [dict(t=f["time"] // 1000, side=f["side"], sz=float(f["sz"]), px=float(f["px"]), fee=float(f["fee"]))
         for f in E.hl({"type": "userFillsByTime", "user": E.HL, "startTime": (E.PILOT_START - 3600) * 1000}) if f["coin"] == "HYPE"]
fund = [dict(t=f["time"] // 1000, usdc=float(f["delta"]["usdc"]))
        for f in E.hl({"type": "userFunding", "user": E.HL, "startTime": (E.PILOT_START - 3600) * 1000}) if f["delta"].get("coin") == "HYPE"]
c30 = E.hl({"type": "candleSnapshot", "req": {"coin": "HYPE", "interval": "30m", "startTime": E.PILOT_START * 1000 - STEP * 1000, "endTime": now * 1000}})
opens = {int(c["t"]) // 1000: float(c["o"]) for c in c30}
cv = st.setdefault("curve", {})
ts = [t for t in range(E.PILOT_START - E.PILOT_START % STEP + STEP, now - 60, STEP) if str(t) not in cv and t in opens]
E.block_at(ts[0])  # warm anchors
def job(t):
    sn = E.snapshot(ts=t); pt = opens[t]
    return t, [pt, round(sn["hype"] * pt + sn["usdc"] - v0 + E.hedge_pnl(fills, fund, E.PILOT_START, t, p0, pt), 4)]
done = 0
with ThreadPoolExecutor(6) as ex:
    for t, v in ex.map(job, ts):
        cv[str(t)] = v; done += 1
        if done % 25 == 0: print(done, len(ts), flush=True)
json.dump(st, open(E.STATE, "w"), separators=(",", ":"))
print("saved", len(cv))
