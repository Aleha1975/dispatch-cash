"""Elysium pool monitor: 24h activity of all Uniswap v4 pools + Aerodrome/Ramses USDC/WHYPE. Read-only."""
import json, os, sys, time, math
from collections import defaultdict
import ely_live as E

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BASE, "pools.json")
CACHE = os.path.join(BASE, "pools_cache.json")
V4SWAP = "0x" + E.keccak(text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)").hex()
V3SWAP = "0x" + E.keccak(text="Swap(address,address,int256,int256,uint160,uint128,int24)").hex()
INIT = "0x" + E.keccak(text="Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)").hex()
NATIVE = "0x0000000000000000000000000000000000000000"
USDC = E.USDC.lower()
WHYPE = "0xba876237b0f021a6c6d852d6c26e107997cc5e81"
V3 = {"0x97796d80b6a1db78632f7451196b04f307329eb6": "Aerodrome Slipstream",
      "0xd329b88ba62483918c3f6c9421178345cf9eebc2": "Ramses"}
OURS = "0x" + E.POOLID.hex()
TOP = 12

def logs(addr, topics, frm, to):
    out, step = [], 40000
    while frm <= to:
        hi = min(to, frm + step - 1)
        try:
            out += E.rpc("eth_getLogs", [{"address": addr, "fromBlock": hex(frm), "toBlock": hex(hi), "topics": topics}])
            frm = hi + 1
        except Exception as e:
            if "limit" in str(e) and step > 500: step //= 2
            else: raise
    return out

def token_meta(cache, a, blk):
    a = a.lower()
    if a in cache["tok"]: return cache["tok"][a]
    if a == NATIVE: m = ["HYPE", 18]
    else:
        try:
            raw = E.call(a, E.sel("symbol()"), blk)
            try: sym = E.decode(["string"], raw)[0]
            except Exception: sym = raw.rstrip(b"\0").decode(errors="ignore")
            dec = E.decode(["uint8"], E.call(a, E.sel("decimals()"), blk))[0]
            m = [sym[:12] or a[:8], dec]
        except Exception:
            m = [a[:8], 18]
    cache["tok"][a] = m
    return m

def main():
    try: cache = json.load(open(CACHE))
    except Exception: cache = {"keys": {}, "tok": {}}
    head = int(E.rpc("eth_blockNumber", []), 16)
    now = int(E.rpc("eth_getBlockByNumber", [hex(head), False])["timestamp"], 16)
    start = E.block_at(now - 86400)
    hl = float(E.hl({"type": "allMids"})["HYPE"])
    agg = defaultdict(lambda: {"n": 0, "a0": 0, "a1": 0, "fee": 0.0})
    for l in logs(E.PM, [V4SWAP], start, head):
        d = bytes.fromhex(l["data"][2:]); g = agg[l["topics"][1]]
        a0, a1 = abs(E.sint(d[0:32], 128)), abs(E.sint(d[32:64], 128))
        g["n"] += 1; g["a0"] += a0; g["a1"] += a1; g["fee"] += int.from_bytes(d[160:192], "big") * a0
    v3agg = defaultdict(lambda: {"n": 0, "a0": 0, "a1": 0})
    for l in logs(list(V3), [V3SWAP], start, head):
        d = bytes.fromhex(l["data"][2:]); g = v3agg[l["address"].lower()]
        g["n"] += 1; g["a0"] += abs(E.sint(d[0:32], 256)); g["a1"] += abs(E.sint(d[32:64], 256))
    # resolve pool keys for the busiest v4 pools
    busy = [k for k, _ in sorted(agg.items(), key=lambda x: -x[1]["n"])[:40]]
    if OURS not in busy: busy.append(OURS)
    missing = [k for k in busy if k not in cache["keys"]]
    if missing:
        for l in logs(E.PM, [INIT, missing], 0, head):
            d = bytes.fromhex(l["data"][2:])
            cache["keys"][l["topics"][1]] = dict(c0="0x" + l["topics"][2][-40:], c1="0x" + l["topics"][3][-40:],
                                               fee=int.from_bytes(d[0:32], "big"), ts=E.sint(d[32:64], 24),
                                               hooks="0x" + d[64:96].hex()[-40:])
    rows = []
    def usd(c, amt, dec):
        c = c.lower()
        if c in (NATIVE, WHYPE): return amt / 10**dec * hl
        if c == USDC: return amt / 1e6
        return None
    for k in busy:
        key = cache["keys"].get(k)
        if not key: continue
        g = agg.get(k, {"n": 0, "a0": 0, "a1": 0, "fee": 0})
        s0, s1 = token_meta(cache, key["c0"], head), token_meta(cache, key["c1"], head)
        vol = usd(key["c0"], g["a0"], s0[1])
        if vol is None: vol = usd(key["c1"], g["a1"], s1[1])
        avg_fee = (g["fee"] / g["a0"]) if g["a0"] else (key["fee"] if key["fee"] < 0x800000 else 0)
        pslot = E.keccak(bytes.fromhex(k[2:]) + (6).to_bytes(32, "big"))
        sl0, liq = E.sload([pslot, E.add(pslot, 3)], head)
        sp = sl0 & ((1 << 160) - 1); liq &= (1 << 128) - 1
        p_raw = (sp / 2**96) ** 2
        price = p_raw * 10 ** (s0[1] - s1[1]) if sp else None
        d1 = liq * (sp / 2**96) * (math.sqrt(1.01) - 1)          # token1 raw to move +1%
        depth = usd(key["c1"], d1, s1[1])
        if depth is None and price: depth = usd(key["c0"], d1 / p_raw, s0[1])
        pair = f"{s0[0]}/{s1[0]}"
        if key["c0"].lower() == USDC and price:
            price, pair = 1 / price, f"{s1[0]}/{s0[0]}"
        rows.append(dict(id=k, venue="Uniswap v4", pair=pair, fee_bps=round(avg_fee / 100, 2) if avg_fee else None,
                         hooks=key["hooks"] != NATIVE, price=price, swaps=g["n"], vol24=round(vol) if vol is not None else None,
                         fees24=round(vol * avg_fee / 1e6, 2) if vol is not None and avg_fee else None,
                         depth_1pct=round(depth) if depth else None, ours=(k == OURS)))
    for a, name in V3.items():
        g = v3agg.get(a, {"n": 0, "a0": 0, "a1": 0})
        fee = E.decode(["uint24"], E.call(a, E.sel("fee()"), head))[0]
        sl = E.call(a, E.sel("slot0()"), head); sp = int.from_bytes(sl[0:32], "big")
        liq = E.decode(["uint128"], E.call(a, E.sel("liquidity()"), head))[0]
        price = 1 / ((sp / 2**96) ** 2 * 1e-12) if sp else None   # USDC per WHYPE
        b0 = E.decode(["uint256"], E.call(USDC, E.sel("balanceOf(address)") + E.encode(["address"], [a]), head))[0] / 1e6
        b1 = E.decode(["uint256"], E.call(WHYPE, E.sel("balanceOf(address)") + E.encode(["address"], [a]), head))[0] / 1e18
        vol = g["a0"] / 1e6
        depth = liq * 2**96 / sp * (1 - 1 / math.sqrt(1.01)) / 1e6 if sp else 0   # USDC in to move HYPE +1%
        rows.append(dict(id=a, venue=name, pair="WHYPE/USDC", fee_bps=round(fee / 100, 2), hooks=False, price=price,
                         swaps=g["n"], vol24=round(vol), fees24=round(vol * fee / 1e6, 2), depth_1pct=round(depth),
                         tvl=round(b0 + b1 * hl), ours=False))
    rows.sort(key=lambda r: -(r["vol24"] or 0))
    keep = [r for r in rows if r["ours"] or r["venue"] != "Uniswap v4"] + [r for r in rows if r["venue"] == "Uniswap v4" and not r["ours"]][:TOP]
    keep.sort(key=lambda r: -(r["vol24"] or 0))
    out = dict(updated=now, block=head, hype=hl, pools=keep, v4_swaps24=sum(g["n"] for g in agg.values()), v4_active=len(agg))
    json.dump(out, open(OUT + ".tmp", "w"), separators=(",", ":")); os.replace(OUT + ".tmp", OUT)
    json.dump(cache, open(CACHE + ".tmp", "w")); os.replace(CACHE + ".tmp", CACHE)
    print("ok", len(keep), "pools", out["v4_active"], "active v4")

if __name__ == "__main__":
    main()
