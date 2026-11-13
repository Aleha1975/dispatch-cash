# Elysium LP vault keeper

One process per vault (`hedged` or `growth`), driving `UniV4LPVault` on Elysium (chain 99901) and, for the hedged
vault, a HYPE perp short on Hyperliquid through a pluggable adapter. Nothing in here has touched a real chain or HL
account. The tests run on a local anvil fork, with HL in dry-run.

## Why Python (eth_account + eth_abi + raw JSON-RPC, no web3.py)

- Same stack as the existing HL tooling (`/opt/mprhedged/hedge.py`). The live HL adapter reuses its proven
  `sign_l1_action` path and its order formatting (`num_str`/`px_str`, the action key order).
- Three small deps (`eth-account`, `eth-abi`, `eth-utils`), all already on the servers. Python 3.9 compatible.
  The JSON-RPC client is about 60 lines of urllib. It always sends a User-Agent (Kinetiq RPC returns 403 without
  one) and refuses Alchemy URLs.

## Layout

| Path | Role |
|---|---|
| `elysium_keeper/strategy.py` | Pure math: 72h realized vol -> range half-width, ticks, price clamp, hedge decision, margin plan, crash guard state machine, deploy split |
| `elysium_keeper/v4math.py` | v4 tick/sqrtPrice/liquidity math |
| `elysium_keeper/keeper.py` | Per-tick sequence, swaps, LP, settlement, hedge, status |
| `elysium_keeper/vault.py` | Snapshot of the vault, pool slot0 (`extsload`), positions, redeem queue, treasury |
| `elysium_keeper/hl.py` | HL info reader (read only); `DryRunAdapter` (default); `LiveAdapter` (double-gated) |
| `elysium_keeper/rpc.py` | JSON-RPC, ABI, signers (`unlocked` = anvil only, `keystore`, `readonly` plan mode) |
| `elysium_keeper/infra.py` | JSON-lines log, alerts (log / telegram via env / any `module:function`), atomic JSON state, localhost `/status` |
| `abi/UniV4LPVault.json` | Vault ABI extracted from `forge build` |
| `config/*.json` | Fork configs and a live template |
| `deploy/elysium-keeper@.service` | systemd template unit |
| `tests/` | Unit tests (`test_strategy.py`) and fork end-to-end tests (`test_e2e_fork.py`, `forkutil.py`) |

## Per-tick sequence (default every 60 s; one settlement at least every `settle_interval_s` = 1 h)

1. Snapshot the chain. Alarm if the last settlement is older than 24h (emergencyUnwind opens at 72h). If the vault
   is in emergency, do nothing.
2. Price: `P` = HL mid. If it is within 0.8 x band of the pool, use it. If it is up to 3% off, clamp it into the band.
   Beyond that, skip the tick and alert. The keeper never forces a price.
3. Anchor: if `P` is within 25 bps of the vault's anchor `lastPrice`, report the anchor (no budget used). If `P` is
   more than half the pool band from the anchor, settle first (swaps and adds must quote within the band of the
   anchor). A move beyond the anchor's daily budget is clipped on-chain; the keeper alerts the guardian
   (`approvePrice`).
4. Free liquidity for queued redeems: sell idle HYPE, then decrease (or burn) LP pro rata, then sell the freed
   HYPE. Hedged vault: pull margin from the treasury (`returnHedgeMargin`, needs the treasury's approval), else
   send a MANUAL alert asking for an HL withdraw.
5. Settle when due (interval, queued deposits, or the first queued redeem is payable). Loop over long queues. The
   reported hedge equity is treasury USDC + HL equity + operator-declared in-transit. The real value is always
   reported. The keeper alone can only lower it (5% of NAV per decaying day); an increase, or a larger drop, is
   clipped on-chain (redeems only, no deposits, no fee). The keeper alerts the guardian (`approveHedgeEquity`) and,
   with redeems queued, waits up to `guardian_wait_s` (2 h) before settling clipped. LP adds are sized to the
   remaining turnover budget.
6. LP. Growth vault in crash mode: burn everything and sell HYPE to USDC. Otherwise, if the price is out of range,
   burn and re-mint at `P +- k x vol` (k = 2.5, 72h vol from HL 1h candles, clipped to 3-40%). Idle funds are
   deployed by minting a position, or adding to it with `increasePosition`. The keeper keeps 5% of NAV as a USDC
   buffer, the value of queued redeems, and (hedged) the margin for the new HYPE leg.
7. Hedge (hedged vault). Target short = LP HYPE + idle HYPE. The keeper re-hedges when the drift is above 10% or
   every 4h, with the $10 minimum (reduce-only orders are exempt) and size rounded to 2 decimals. Margin target =
   short notional / 3. Below target, the keeper calls `sendHedgeMargin` and posts "MANUAL: bridge X USDC treasury ->
   HL". Above target, it asks for a manual HL withdraw, then pulls the money with `returnHedgeMargin`.

All swaps are split into chunks of $1.5k or less, with an `eth_call` probe before each one (min-out is halved if
needed). Swapping stops when the pool moves more than 0.5% against `P`, and the rest waits for arbitrage on a later
tick. The Elysium pool has about $560k of virtual depth per side, so a 1% move is about $2.8k.

Restart safety: every step recomputes its work from a fresh snapshot (epoch, positions, balances, HL position). A
settle carries `epoch`, so it cannot be replayed. The state file holds only the crash guard, the last hedge time, the
dry-run sim/nonce and the in-transit amount, and it is written atomically. The e2e test checks that a freshly started
keeper does nothing on its first tick.

Crash guard (growth): when the HL mid is at least 8% below the 4h high (5m candles), exit to USDC. Re-enter once 24h
have passed and the last 1h |log return| is below its 168h median.

## Run on a fork

```
anvil --fork-url https://rpc.elysium.kinetiq.xyz --auto-impersonate --chain-id 99901
# deploy from the repo script (no key needed with --unlocked):
HEDGE_TREASURY=<addr> HEDGE_CAP_BPS=3500 OWNER=.. KEEPER=.. GUARDIAN=.. FEE_RECIPIENT=.. NAME=.. SYMBOL=.. \
  forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <addr>
cd keeper && edit config/hedged.fork.json (vault, keeper)
python3 -m elysium_keeper run --config config/hedged.fork.json            # loop, /status on 127.0.0.1:8781
python3 -m elysium_keeper status --config config/hedged.fork.json         # read only
python3 -m elysium_keeper margin --config ... --credit 500                # dry-run: mock HL margin arrived
python3 -m elysium_keeper margin --config ... --in-transit 500            # operator: USDC on the bridge
```

Tests: `python3 -m pytest -q tests/test_strategy.py` (unit), `ELYSIUM_FORK=1 python3 -m pytest -s tests/`
(adds the e2e test, about 90 s; it needs anvil and forge, and optionally `ELYSIUM_FORK_BLOCK`).

## Going live (staged)

1. `signer: "readonly"` on the real RPC (plan mode). The keeper reads the vault, logs `would_send_tx`, and sends
   nothing. HL `equity_source: "account"` reads the real hedge account (read only).
2. `signer: "keystore"` + `allow_live_chain: true`. The keeper key is an encrypted keystore, and its password comes
   from the env file. HL stays in `dry_run`.
3. HL live: `hl.adapter: "live"`, `hl.live_enabled: true` **and** env `ELYSIUM_KEEPER_HL_LIVE=I_UNDERSTAND`. This
   needs `hyperliquid-python-sdk` and an agent keystore. Without all three, the adapter refuses to start.

Secrets are never in code or config: `ELYSIUM_KEEPER_KEYSTORE_PASSWORD`, `ELYSIUM_KEEPER_HL_AGENT_PASSWORD`,
`ELYSIUM_KEEPER_TG_TOKEN`, `ELYSIUM_KEEPER_TG_CHAT` go in `/etc/elysium-keeper/<name>.env`.

`/status` (and `/healthz`, which returns 503 when unhealthy) shows: ok, epoch, NAV, price (hl/pool/used/status),
range, half-width/vol, hedge (target/short/delta%), margin (plan/capital/treasury/in-transit), crash guard, queues,
holdings, the last actions and the last alerts. `ok` turns false on step errors, when the last settlement is older
than 3h, or when the last tick is older than 5 loop intervals.
