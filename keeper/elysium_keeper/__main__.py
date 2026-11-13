"""CLI.

  python -m elysium_keeper run    --config cfg.json [--once]   # loop (or a single tick)
  python -m elysium_keeper status --config cfg.json            # snapshot + plan inputs, sends nothing
  python -m elysium_keeper margin --config cfg.json --in-transit 1234.5   # operator: USDC bridging treasury->HL
  python -m elysium_keeper margin --config cfg.json --credit 1234.5       # dry-run only: mock HL equity credit
"""
from __future__ import annotations

import argparse
import json
import sys

from . import config as C
from .infra import State


def main(argv=None):
    ap = argparse.ArgumentParser(prog="elysium_keeper")
    ap.add_argument("cmd", choices=["run", "status", "margin"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--in-transit", type=float, default=None, help="USDC currently in transit treasury<->HL")
    ap.add_argument("--credit", type=float, default=None, help="dry-run: credit mock HL margin (USD)")
    a = ap.parse_args(argv)
    cfg = C.load(a.config)

    if a.cmd == "margin":
        st = State(cfg.state_path)
        if a.in_transit is not None:
            st.d["in_transit_usdc"] = int(a.in_transit * 1e6)
        if a.credit is not None:
            if cfg.hl.adapter != "dry_run":
                sys.exit("--credit is only for the dry-run adapter")
            sim = st.d.setdefault("hl_sim", {})
            sim["margin"] = sim.get("margin", 0.0) + a.credit
        st.save()
        print(json.dumps({"in_transit_usdc": st.d.get("in_transit_usdc", 0) / 1e6,
                          "hl_sim": st.d.get("hl_sim")}))
        return

    from .keeper import Keeper

    if a.cmd == "status":
        cfg.chain.signer = "readonly"
        k = Keeper(cfg)
        snap = k.reader.snapshot()
        out = {k2: v for k2, v in vars(snap).items() if k2 != "positions"}
        out["positions"] = [vars(p) for p in snap.positions]
        out["hl_mid"] = k.info.mid(cfg.hl.coin)
        print(json.dumps(out, default=str, indent=1))
        return
    Keeper(cfg).run(once=a.once)


if __name__ == "__main__":
    main()
