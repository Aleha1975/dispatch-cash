"""Elysium HYPE/USDC v4 pool + pilot position -> public JSON for app.deepyield.ai/elysium. Read-only, no keys."""
import json, time, math, os, sys, calendar, urllib.request
from eth_abi import encode, decode
from eth_utils import keccak

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BASE, "live.json")
STATE = os.path.join(BASE, "state.json")
RPCS = ["https://rpc.elysium.kinetiq.xyz", "https://rpc.volta.family"]
PM = "0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1"
POSM = "0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518"
USDC = "0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65"
POOLID = bytes.fromhex("b3032695ffb0a66e6342876dd2386835471466cb2bb70f341947d98a69e265cc")
INIT_BLOCK = 2213865
W = "0xf38a7Ad45d6E7f3B524256D59916c7E3bdF328b2"
HL = "0x080da174fafd6a9da64e798515ec08d6f9268cce"
POSITIONS = [11805, 47526]
CLOSED_FEES = {11805: 5.87}          # collected on exit 14.11
PILOT_START = calendar.timegm((2026, 11, 11, 16, 5, 0))
SWAP_T = "0x" + keccak(text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)").hex()
Q128 = 1 << 128

def rpc(m, p):
    err = None
    for i in range(8):
        url = RPCS[i % 2 if i >= 4 else 0]
        try:
            r = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(),
                                       {"content-type": "application/json", "User-Agent": "Mozilla/5.0 deepyield-ely-live"})
            d = json.load(urllib.request.urlopen(r, timeout=30))
            if "result" in d: return d["result"]
            err = RuntimeError(str(d)[:300])
        except Exception as e:
            err = e
        time.sleep(1.2 * (i + 1))
    raise err

def hl(body):
    r = urllib.request.Request("https://api.hyperliquid.xyz/info", json.dumps(body).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=30))

def sel(s): return keccak(text=s)[:4]
def call(to, data, blk): return bytes.fromhex(rpc("eth_call", [{"to": to, "data": "0x" + data.hex()}, hex(blk)])[2:])
def add(b, n): return (int.from_bytes(b, "big") + n).to_bytes(32, "big")
POOL = keccak(POOLID + (6).to_bytes(32, "big"))
def sload(slots, blk):
    out = call(PM, sel("extsload(bytes32[])") + encode(["bytes32[]"], [slots]), blk)
    return [int.from_bytes(x, "big") for x in decode(["bytes32[]"], out)[0]]
def s24(x): x &= 0xFFFFFF; return x - (1 << 24) if x >> 23 else x
def sqrt_at(t): return math.sqrt(1.0001 ** t) * 2**96
def price(sp): return (sp / 2**96) ** 2 * 1e12
def tick_price(t): return 1.0001 ** t * 1e12
def amounts(sp, sa, sb, L):
    if sp <= sa: return L * (sb - sa) / (sa * sb) * 2**96, 0
    if sp >= sb: return 0, L * (sb - sa) / 2**96
    return L * (sb - sp) / (sp * sb) * 2**96, L * (sp - sa) / 2**96
def sint(b, bits):
    v = int.from_bytes(b, "big"); return v - (1 << 256) if v >> 255 else v

_ANCH = []
def _bts(b):
    return int(rpc("eth_getBlockByNumber", [hex(b), False])["timestamp"], 16)
def block_at(ts):
    """first block with timestamp >= ts (interpolation search)"""
    if not _ANCH:
        h = int(rpc("eth_blockNumber", []), 16); _ANCH.extend([(INIT_BLOCK, _bts(INIT_BLOCK)), (h, _bts(h))])
    lo = max((a for a in _ANCH if a[1] < ts), default=_ANCH[0])
    hi = min((a for a in _ANCH if a[1] >= ts), default=None)
    if hi is None:
        h = int(rpc("eth_blockNumber", []), 16); hi = (h, _bts(h)); _ANCH.append(hi)
        if hi[1] < ts: return h
    (lb, lt), (hb, ht) = lo, hi
    while hb - lb > 1:
        g = lb + int((ts - lt) * (hb - lb) / max(ht - lt, 1))
        g = min(max(g, lb + 1), hb - 1)
        if hb - lb > 64:  # keep interpolation from crawling
            g = min(max(g, lb + (hb - lb) // 64), hb - (hb - lb) // 64)
        gt = _bts(g); _ANCH.append((g, gt))
        if gt < ts: lb, lt = g, gt
        else: hb, ht = g, gt
    return hb

def pos_state(tid, blk, sp, tick):
    try:
        info = decode(["(address,address,uint24,int24,address)", "uint256"],
                      call(POSM, sel("getPoolAndPositionInfo(uint256)") + encode(["uint256"], [tid]), blk))[1]
    except Exception:
        return None
    lo, hi = s24(info >> 8), s24(info >> 32)
    if lo == 0 and hi == 0: return None
    pkey = keccak(bytes.fromhex(POSM[2:]) + lo.to_bytes(3, "big", signed=True) + hi.to_bytes(3, "big", signed=True) + tid.to_bytes(32, "big"))
    ps = keccak(pkey + add(POOL, 6))
    tl = keccak(lo.to_bytes(32, "big", signed=True) + add(POOL, 4)); th = keccak(hi.to_bytes(32, "big", signed=True) + add(POOL, 4))
    g0, g1, lo0, lo1, hi0, hi1, L, l0, l1 = sload([add(POOL, 1), add(POOL, 2), add(tl, 1), add(tl, 2), add(th, 1), add(th, 2), ps, add(ps, 1), add(ps, 2)], blk)
    L &= (1 << 128) - 1
    if L == 0: return None
    def inside(g, a, b):
        below = a if tick >= lo else (g - a) % 2**256
        above = b if tick < hi else (g - b) % 2**256
        return (g - below - above) % 2**256
    f0 = ((inside(g0, lo0, hi0) - l0) % 2**256) * L // Q128
    f1 = ((inside(g1, lo1, hi1) - l1) % 2**256) * L // Q128
    a0, a1 = amounts(sp, sqrt_at(lo), sqrt_at(hi), L)
    return dict(id=tid, lo=lo, hi=hi, L=L, a0=a0 / 1e18, a1=a1 / 1e6, f0=f0 / 1e18, f1=f1 / 1e6)

def snapshot(ts=None, blk=None):
    if blk is None: blk = block_at(ts)
    if ts is None: ts = int(rpc("eth_getBlockByNumber", [hex(blk), False])["timestamp"], 16)
    s0, liq = sload([POOL, add(POOL, 3)], blk)
    sp = s0 & ((1 << 160) - 1); tick = s24(s0 >> 160); P = price(sp)
    nat = int(rpc("eth_getBalance", [W, hex(blk)]), 16) / 1e18
    usdc = decode(["uint256"], call(USDC, sel("balanceOf(address)") + encode(["address"], [W]), blk))[0] / 1e6
    hype, usd, fees, pos = nat, usdc, 0.0, None
    for t in POSITIONS:
        p = pos_state(t, blk, sp, tick)
        if p:
            hype += p["a0"] + p["f0"]; usd += p["a1"] + p["f1"]; fees += p["f0"] * P + p["f1"]; pos = p
    return dict(ts=ts, blk=blk, P=P, sp=sp, tick=tick, liq=liq & ((1 << 128) - 1), hype=hype, usdc=usd, fees=fees, pos=pos)

def hl_mid_at(ts):
    for iv, w in (("1m", 120), ("15m", 1800), ("1h", 7200)):
        c = hl({"type": "candleSnapshot", "req": {"coin": "HYPE", "interval": iv, "startTime": (ts - w) * 1000, "endTime": (ts + 60) * 1000}})
        if c: return float(c[-1]["c"])
    return None

def hedge_pnl(fills, fund, t0, t1, p0, p1):
    sz = sum((-f["sz"] if f["side"] == "A" else f["sz"]) for f in fills if f["t"] < t0)
    out, p = 0.0, p0
    for f in fills:
        if t0 <= f["t"] < t1:
            out += sz * (f["px"] - p) - f["fee"]; p = f["px"]
            sz += -f["sz"] if f["side"] == "A" else f["sz"]
    out += sz * (p1 - p)
    return out + sum(x["usdc"] for x in fund if t0 <= x["t"] < t1)

def load_state():
    try: return json.load(open(STATE))
    except Exception: return {"last_block": INIT_BLOCK - 1, "m5": {}, "day_snaps": {}}

def pilot_pct(cur, hpos, hlmid, p, lp_hype, short, total, days, fees_total, days_live):
    """Public view: percentages only, no dollar amounts or sizes."""
    margin = float(hpos["marginUsed"]) if hpos else 0
    cap = cur["hype"] * hlmid + cur["usdc"] + margin
    pc = lambda v: round(v / cap * 100, 3)
    lp_usdc = (p["a1"] + p["f1"]) if p else 0
    lp_val = lp_hype * hlmid + lp_usdc
    tot = pc(total["total"])
    return dict(start=PILOT_START, days=round(days_live, 2),
                range=[tick_price(p["lo"]), tick_price(p["hi"])] if p else None, in_range=bool(p and p["lo"] <= cur["tick"] < p["hi"]),
                hype_share=round(lp_hype * hlmid / lp_val * 100, 1) if lp_val else None,
                hedge_ratio=round(short / lp_hype, 3) if lp_hype else None,
                margin_share=round(margin / cap * 100, 1),
                liq_px=float(hpos["liquidationPx"]) if hpos and hpos.get("liquidationPx") else None,
                total_pct=tot, lp_pct=pc(total["lp"]), hedge_pct=pc(total["hedge"]),
                apr=round(tot / max(days_live, 0.01) * 365, 1),
                fees_pct=pc(fees_total), unclaimed_pct=pc(cur["fees"]),
                fee_yield_day=round(fees_total / max(days_live, 0.01) / cap * 100, 3),
                days_pnl=[dict(t0=d["t0"], lp=pc(d["lp"]), hedge=pc(d["hedge"]), total=pc(d["total"])) for d in days])

def main():
    st = load_state()
    head = int(rpc("eth_blockNumber", []), 16)
    # 1) swaps -> 5m candles
    frm = st["last_block"] + 1
    m5 = st["m5"]
    while frm <= head:
        to = min(head, frm + 399999)
        logs = rpc("eth_getLogs", [{"address": PM, "fromBlock": hex(frm), "toBlock": hex(to), "topics": [SWAP_T, "0x" + POOLID.hex()]}])
        for lg in logs:
            d = bytes.fromhex(lg["data"][2:])
            a1 = sint(d[32:64], 128); sp = int.from_bytes(d[64:96], "big"); fee = int.from_bytes(d[160:192], "big")
            ts = int(lg["blockTimestamp"], 16); k = str(ts - ts % 300); p = price(sp); vol = abs(a1) / 1e6
            c = m5.get(k)
            if c is None: m5[k] = [p, p, p, p, vol, vol * fee / 1e6, 1]
            else:
                c[1] = max(c[1], p); c[2] = min(c[2], p); c[3] = p; c[4] += vol; c[5] += vol * fee / 1e6; c[6] += 1
        st["last_block"] = to; frm = to + 1
    now = int(rpc("eth_getBlockByNumber", [hex(head), False])["timestamp"], 16)
    # 2) live snapshot + day boundary snapshots (cached, immutable once past)
    cur = snapshot(blk=head)
    day0 = now - now % 86400
    bounds = [PILOT_START] + list(range(PILOT_START - PILOT_START % 86400 + 86400, day0 + 1, 86400))
    ds = st["day_snaps"]
    for b in bounds:
        if str(b) not in ds:
            s = snapshot(ts=b); s.pop("pos"); s["hl"] = hl_mid_at(b); ds[str(b)] = s
    # 3) hedge
    fills = [dict(t=f["time"] // 1000, side=f["side"], sz=float(f["sz"]), px=float(f["px"]), fee=float(f["fee"]))
             for f in hl({"type": "userFillsByTime", "user": HL, "startTime": (PILOT_START - 3600) * 1000}) if f["coin"] == "HYPE"]
    fund = [dict(t=f["time"] // 1000, usdc=float(f["delta"]["usdc"]))
            for f in hl({"type": "userFunding", "user": HL, "startTime": (PILOT_START - 3600) * 1000}) if f["delta"].get("coin") == "HYPE"]
    chs = hl({"type": "clearinghouseState", "user": HL})
    hpos = next((p["position"] for p in chs["assetPositions"] if p["position"]["coin"] == "HYPE"), None)
    mids = hl({"type": "allMids"}); hlmid = float(mids["HYPE"])
    def window(a, b, pa, pb):
        va = a["hype"] * pa + a["usdc"]; vb = b["hype"] * pb + b["usdc"]
        h = hedge_pnl(fills, fund, a["ts"], b["ts"], pa, pb)
        return dict(t0=a["ts"], t1=b["ts"], lp=round(vb - va, 2), hedge=round(h, 2), total=round(vb - va + h, 2))
    cur_w = dict(cur); cur_w["hl"] = hlmid
    seq = [ds[str(b)] for b in bounds] + [cur_w]
    days = [window(seq[i], seq[i + 1], seq[i]["hl"], seq[i + 1]["hl"]) for i in range(len(seq) - 1)]
    total = window(seq[0], cur_w, seq[0]["hl"], hlmid)
    fees_total = sum(CLOSED_FEES.values()) + cur["fees"]
    days_live = (now - PILOT_START) / 86400
    p = cur["pos"]
    lp_hype = (p["a0"] + p["f0"]) if p else 0
    short = -float(hpos["szi"]) if hpos else 0
    # depth: USDC to move price +1% within the active range
    depth = cur["liq"] * (cur["sp"] / 2**96) * (math.sqrt(1.01) - 1) / 1e6
    keys = sorted(m5, key=int)
    cut = now - 86400
    v24 = sum(m5[k][4] for k in keys if int(k) >= cut); f24 = sum(m5[k][5] for k in keys if int(k) >= cut)
    n24 = sum(m5[k][6] for k in keys if int(k) >= cut)
    daily = {}
    for k in keys:
        dd = int(k) - int(k) % 86400; e = daily.setdefault(dd, [0, 0, 0]); e[0] += m5[k][4]; e[1] += m5[k][5]; e[2] += m5[k][6]
    # equity curve: pilot total return vs HYPE, 30-min steps (usd kept server-side only)
    cv = st.setdefault("curve", {})
    STEP = 1800
    c30 = hl({"type": "candleSnapshot", "req": {"coin": "HYPE", "interval": "30m", "startTime": PILOT_START * 1000 - STEP * 1000, "endTime": now * 1000}})
    opens = {int(c["t"]) // 1000: float(c["o"]) for c in c30}
    s0 = seq[0]; p0 = s0["hl"]; v0 = s0["hype"] * p0 + s0["usdc"]
    t = PILOT_START - PILOT_START % STEP + STEP
    while t <= now - 60:
        if str(t) not in cv and t in opens:
            sn = snapshot(ts=t); pt = opens[t]
            pnl_t = sn["hype"] * pt + sn["usdc"] - v0 + hedge_pnl(fills, fund, PILOT_START, t, p0, pt)
            cv[str(t)] = [pt, round(pnl_t, 4)]
        t += STEP
    cap_now = cur["hype"] * hlmid + cur["usdc"] + (float(hpos["marginUsed"]) if hpos else 0)
    curve_pts = [[PILOT_START, 0.0, 0.0]] + [[int(k), round((v[0] / p0 - 1) * 100, 3), round(v[1] / cap_now * 100, 3)] for k, v in sorted(cv.items(), key=lambda x: int(x[0]))]
    curve_pts.append([now, round((hlmid / p0 - 1) * 100, 3), round(total["total"] / cap_now * 100, 3)])
    out = dict(
        curve=curve_pts,
        updated=now, block=head,
        pool=dict(price=cur["P"], tick=cur["tick"], fee_bps=30, depth_1pct=round(depth, 0), vol24=round(v24, 0), fees24=round(f24, 2), swaps24=n24,
                  daily=[[d, round(v[0]), round(v[1], 2), v[2]] for d, v in sorted(daily.items())]),
        candles=[[int(k)] + [round(x, 4) for x in m5[k][:4]] + [round(m5[k][4], 2)] for k in keys],
        hl_mid=hlmid,
        pilot=pilot_pct(cur, hpos, hlmid, p, lp_hype, short, total, days, fees_total, days_live))
    tmp = OUT + ".tmp"; json.dump(out, open(tmp, "w"), separators=(",", ":")); os.replace(tmp, OUT)
    json.dump(st, open(STATE + ".tmp", "w"), separators=(",", ":")); os.replace(STATE + ".tmp", STATE)
    print(f"ok block {head} price {cur['P']:.3f} candles {len(keys)}")

if __name__ == "__main__":
    main()
