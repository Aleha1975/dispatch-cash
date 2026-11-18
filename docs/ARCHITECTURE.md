# Architecture: three client products on per-client smart accounts (Elysium)

Branch `sa-r4-riskoff` (off `sa-product`). Date: 2026-11-17. Companion docs: `SMART_ACCOUNT_DESIGN.md` (contracts, as built,
§6), `PRODUCT_FLOW.md` (wizard, Strategy message, width bounds), `audit_sa_round4.txt` (audit round 4 prompt, now including
the R4 exit window).

## 1. The three products

All three use the same stack: one smart account per client (HybridDeleGator, or the client's own 7702 wallet), one
`LPManagerModule` per pool, and one keeper. A client starts with **one onboarding** (signatures only, no gas) and leaves
with **one transaction** that stops the manager and closes the pool position. The keeper winds down the hedge after that
(§5). The product is not a separate contract. It is the client's signed **Strategy** (`prefs.py`), which the keeper follows:

| # | Product | Strategy | What the keeper does |
|---|---|---|---|
| 1 | **LP with range management** (unhedged) | `hedged = false`, `riskOff = false`, width auto or manual | Keeps a concentrated HYPE/USDC range, re-centres it (out of range / near edge / width change), charges the HWM fee. The client keeps about half its value in HYPE. |
| 2 | **LP + risk-off** | `riskOff = true` (with or without hedge) | Same as 1 while the market is calm. When the risk-off signal fires, it burns the position, sells the HYPE to USDC and holds USDC. It re-enters when the signal clears and the account has been out at least 24 h. *Protection from crashes, not extra yield.* |
| 3 | **LP + hedge** | `hedged = true` | Same as 1, plus a HYPE short on Hyperliquid equal to the account's LP + idle HYPE. Margin goes from the account to the hedge treasury and then to HL. |

`riskOff` combines with `hedged`: a hedged risk-off account also closes its short and takes its margin back into the
account while it is out.

## 2. Components

```
 client wallet (MetaMask)                                     Hyperliquid (one account, all clients' shorts)
   │ signs: delegation, USDC permit, Strategy                        ▲  netted IOC orders (live gate)
   ▼                                                                 │  Relay: treasury ⇄ HL (§6)
 web/account.html + account.js ── POST onboard / strategy ──▶ sa-api (127.0.0.1:8790, no key, validates, queues)
                                  GET status / recommend          │ requests_dir/*.json        ▲ status_path
                                                                  ▼                            │
                                                         keeper `sa-run` (keeper key, HL key, relayer)
                                                                  │ module calls only
 Elysium 99901 ───────────────────────────────────────────────────▼────────────────────────────────────────────
   DelegationManager ── client's delegation (ElysiumCustodyEnforcer + TimestampEnforcer) ──▶ LPManagerModule
   LPManagerModule (+ SALib, SABook): budgets, anchor, books, fee; builds every call; redeems the delegation
   ElysiumCustodyEnforcer: default deny; pool / router / Permit2 / USDC-to-treasury-or-fee-recipient only
   SwapExecutor: v4 unlock router, pays the account; Uniswap v4 PoolManager / PositionManager (HYPE/USDC 0.30%)
   hedgeTreasury (immutable operator address) ── Relay ──▶ HL;  feeRecipient (immutable)
```

| Component | Code | Key / trust |
|---|---|---|
| Contracts | `src/sa/*` (audit rounds 1-3 done; round 4 pending) | Owner = VaultTimelock (≥ 24 h). Keeper hot key, bounded on-chain. Guardian: pause, price ranges, hedge-equity increases. |
| Keeper | `keeper/elysium_keeper/sa_keeper.py`, `sa_chain.py`, `ledger.py`, `riskoff.py`, `recommend.py`, `prefs.py` | Keeper key (module role), relayer (any funded key), HL key (live gate: `hl.adapter = live` + `hl.live_enabled` + env). |
| API | `sa_api.py` | No key. Validates signatures and queues work. Serves the status and the recommendation. |
| Web | `web/account.html`, `web/account.js`, `web/config.js` | Static page. Runs every signature check locally before anything is sent. |
| HL | `hl.py` (`HLInfo` read only, `DryRunAdapter` default, `LiveAdapter` gated) | One HL account. A per-client ledger splits it (§6). |

## 3. Client paths

### Onboarding (all products), one sitting, no gas

1. **Pool**: one whitelisted pool (HYPE/USDC v4 0.30%).
2. **Range**: auto (k·σ, recommended) or a manual half-width (slider bounded by the live turnover floor).
3. **Hedge**: hedged or unhedged. **Crash protection** (risk-off): on or off. The card says "Protection from crashes,
   not extra yield", about 2-3 exits a month, and that each exit and re-entry costs swap fees and earns nothing while out.
4. **Amount**: USDC (or "use this wallet" for a 7702 wallet).
5. **Review**: pool, width, range now, hedge, crash protection, deposit, 15% fee above the HWM and no other fee, leave
   any time.
6. **Sign**: (1) the delegation, (2) the USDC permit (hybrid only), (3) the Strategy (v2: `riskOff` field).
   `POST /onboard` → queue → the relayer deploys the account and calls `module.onboard` in one transaction.

### Product 1: LP with range management

The keeper ticks every 60 s. It reports the anchor (HL mid; the pool must sit within the band), books pending client
flows (`sync`), then picks the width (auto or manual, widened to the turnover floor) and re-ranges: burn → swap to the
range split (chunks of ≤ $1.5k, each probed first) → mint or increase within the turnover room. The fee runs every 7 days,
when the fee gate allows it.
**Exit**: one client transaction (`revoke` + `disableDelegation` + burn every position into the account). A second
client transaction withdraws USDC + HYPE to the wallet. No keeper step is involved.

### Product 2: LP + risk-off

- **Signal** (`riskoff.py`, from free HL `candleSnapshot` data only): d = 1 − BTC 4 h close / EMA(span 180 bars = 30 d,
  pandas `adjust=True` weights). The threshold is the 80th percentile of d over all closed bars before the current month,
  with an 18-bar purge and at least 300 bars; it is refitted monthly and is 4.19% now. The signal is **on** when d is
  above the threshold at a **closed** bar. An optional extra trigger fires when HYPE's 7 d Parkinson vol is above its own
  monthly q80 (`sa.riskoff_use_rv`, default off).
  - Replayed over the research data (2025-09 to now): 2.27 exits/month, 32% of the time out.
  - **On the 2026-11-17 12:00 UTC bar the signal is ON**: BTC is 14.1% below its 30 d EMA, against a 4.19% threshold.
  - The keeper stores the signal state in `state.riskoff`. A failed fetch keeps the last decision, and an alert fires
    after 6 h without a refresh.
- **Exit** (`account_tick_out`, `exit_lp`):
  1. Burn every position. Burns are allowed in every state, even while paused.
  2. Sell the HYPE to USDC. This needs a trusted anchor, and the module charges it to the **exit window**: a sell with no
     position held. The sale is chunked like any swap.
  3. Hedged accounts keep the short on the idle HYPE until it is sold. Then the target goes to 0: the netted order closes
     the client's share, and `returnHedgeMargin` puts the margin back **into the account**. This is the same code as the
     unhedged switch.
  4. The fee is charged as usual.
- **Hold**: USDC idle. Value = USDC. Status shows "Out of the pool, holding USDC since …".
- **Re-entry**: when the signal is off and the account has been out ≥ `sa.riskoff_min_out_s` (24 h), the keeper uses the
  normal deploy path: buy the range split, mint (turnover window), and for hedged accounts send margin first.
- **Exit from the product**: as product 1. If the account is out, the client simply withdraws USDC.

### Product 3: LP + hedge

The tick is the same as product 1, plus three steps:
- Margin first: target 25% of value, enforcer cap 35%/24 h of idle USDC, module cap 35% of value.
- Target short = LP HYPE + idle HYPE. One netted HL order per tick for all clients (10% drift band). Fills are split by the
  ledger.
- On-chain `hedgeEquity` follows the ledger: the keeper may lower it; raising it needs the guardian.

**Exit**: one client transaction. Then the keeper, unattended: next tick it detects `!isActive`, sets the target to 0 and
the netted order closes the short; on the tick after, `returnHedgeMargin` pays (≤ on-chain hedge equity, ≤ treasury
balance) into the account. The client then withdraws with a second transaction. Gaps are in §6.3.

## 4. On-chain vs keeper-enforced

| Enforced by the contracts (audited, client-signed caveat) | Enforced by the keeper only (trust; visible in status) |
|---|---|
| Only the fixed pool. Every recipient is the account. Margin goes only to the immutable treasury (≤ 35% of value; ≤ 35% of idle USDC per 24 h). The fee goes only to the fee recipient (≤ 15% of profit above the HWM, once per 7 days, ≤ 20% of idle). Anchor drift ≤ `refDriftBps` per trailing 24 h. Every swap and add within band of the anchor and the pool, with min-out at fair − slippage. **Turnover** ≤ `swapTurnoverBps` × value per 24 h (swaps + adds). **Exit window** ≤ `exitTurnoverBps` × value per 24 h (sells of HYPE with no position held). Hedge equity: keeper may only lower it. Client stop and exit in one transaction, never blockable. | The Strategy itself: width, hedged or not, **risk-off or not**. The risk-off signal and timing. Margin target and HL short size. The ledger split of the one HL account. Bridging between the treasury and HL. Returning margin above the on-chain hedge equity. |

The contract does not know a client's product. A stolen keeper could ignore the Strategy, but it stays inside the bounds
in the left column. With the exit window, the stolen-keeper oscillation bound is about (band + slippage) × (turnover +
exit) × value per day: 4.5%/day at the pilot Params (it was 1.5%). This is stated in the audit prompt.

## 5. Task A: does risk-off fit the contracts? (verdict: not at pilot Params without a change; fixed by the exit window)

### What a risk-off exit needs from the module

| Step | Module call | Limit that applies | Size |
|---|---|---|---|
| Burn all positions | `burnPosition` | none (no budget, allowed while paused) | — |
| Sell HYPE → USDC | `swap(sellBase)` | turnover window (before R4); trusted anchor; band; executor | 0.45-0.97 of value unhedged, 0.33-0.72 hedged |
| Hold USDC | — | — | — |
| Buy HYPE back | `swap(buy)` | turnover window | ≈ 0.46-0.5 of the LP |
| Re-mint | `mintPosition` | turnover window: charge = 0.5 × LP value (150/150) | 0.5 of the LP |

The HYPE share of a ±16% range (auto now) is 0.46 at the centre, 0.55 / 0.61 / 0.71 / 0.77 / 0.95 after −3 / −5 / −8
/ −10 / −15%, and 1.0 below the range. At ±10% it is already 0.73 at −5%. A risk-off exit happens *during a fall*, so a
typical sale is 0.6-0.75 of the value of an unhedged account. In addition, a near-edge or out-of-range re-range during the
same fall has often already used turnover in the last 24 h: about 0.5-1.0 of value (re-centring swap + 0.5 × LP add
charge).

### Against the pilot Params (swapTurnoverBps 5000 = 0.5 × value per sliding 24 h)

- **Exit**: it does not fit one day in the typical case (0.6-0.97 needed > 0.5), and not at all when a re-range used the
  window shortly before. It would take 2-3 days, which defeats the purpose.
- **Re-entry**: 0.97 × (0.48 + 0.5) ≈ 0.95 of value, i.e. 2 days at 5000. This is acceptable: the market is calm and the
  minimum time out is 24 h anyway.
- At 20000 everything would fit one day, at four times the stolen-keeper bound for every swap, which is why the pilot
  runs 5000. SA-4 L-12: `script/DeploySA.s.sol` now deploys the pilot values (5000 / 10000) and reads `params()` back.
- SA-4 L-6: an exit sale that does not fit the exit window (or with the exit window off) is charged to the turnover
  window instead of reverting. SA-4 M-1: the anchor moves at most one `poolBandBps` step per `minPriceStable`, so in a
  fast fall the exit sale waits until the anchor has caught up (about 5 minutes per 1.5%) or the guardian approves a
  range; the exit sale is never available on an untrusted anchor or while paused (SA-4 M-4 decision).

### The change (implemented, `src/sa`, folded into audit round 4)

`Params.exitTurnoverBps` (≤ 10000, 0 = off). In `swap()`, a **sell of base while the account holds no tracked position**
is charged to its own SAWindow (`Budgets.exit`). Everything else stays on turnover. `windows(a)` returns `exitUsed`.

- With exit 10000 (1× value), any exit, even a fully-HYPE position, fits one 24 h window, regardless of what turnover has
  already been used.
- Safety: the window only converts base into the asset inside the account. Each unit loses at most band + slippage, like
  any keeper swap. It is usable only with everything burned, and selling again needs base re-bought on the turnover
  window.
- Bound: (band + slippage) × (T + E): 4.5%/day of value at the pilot, 1.5% before.
- Cost: +324 bytes. The module is 23,996 B, 580 under EIP-170.
- Tests: `test/sa/SARiskOff.t.sol` (7). Two older turnover tests now hold a tiny position so their sells stay on turnover.

### "For every client at once"

All budgets are per account, so the contracts do not couple clients. What couples them:

1. **Pool depth.** About $700 moves the pool 1.5%. Every swap needs the pool within 50 bps of the anchor (`_trusted`),
   so a chunk can be at most about $230 before the next one must wait for arbitrage to pull the pool back. Selling $S of
   HYPE across all clients takes about S / $230 arbitrage cycles; our own burns also thin the pool.
   - Pilot ($250): trivial.
   - $25k of unhedged risk-off capital: about $15k to sell, about 65 cycles. This fits a day only if Elysium arbitrage
     re-centres the pool within minutes, which is **unmeasured**.
   - Pool depth, not the contract, is the scaling limit of product 2. At size, the alternative is to short HYPE on HL
     instead of selling in the pool, which uses the product 3 path.
2. **Anchor drift** (`refDriftBps` 1000 per trailing 24 h). In a crash of more than 10% within 24 h the anchor is clipped,
   swaps are blocked (burns still work), and the guardian must `approvePrice`. The guardian bot must do this
   automatically, or exits stall exactly when they matter.
3. **Pause**: blocks swaps (not burns).
4. Gas is not a limit: about 0.2M (burn) + about 0.3M per swap chunk, ≈ 0.0005 HYPE per client per exit.

## 6. Task C: scaling product 3 and the margin path

### 6.1 Owner decisions (17.11) and bridge costs

The owner decided:
- No operator-funded float on HL. The client pays bridging.
- There is a minimum deposit (e.g. $100).
- A slice of each deposit goes to HL as margin.

Bridge quotes (17.11, Relay is the only usable bridge for 99901):

| Route | Cost | Time |
|---|---|---|
| Elysium USDC → HL perp (Relay, chain 1337 = HyperCore) | 0.94-0.95% ($100-10k) | ~1 s |
| HL → Elysium (Relay; off-chain authorize signature, no gas) | 0.02-0.04% | ~1 s |
| Arbitrum → Elysium | 0.01-0.03% | — |
| Elysium → Arbitrum | 0.94% | — |
| Arbitrum → HL (native Bridge2) | $0 | — |
| HL → Arbitrum | $1 | — |

LI.FI adds 0.25%. deBridge, Across and Gas.zip do not support 99901. A margin round trip Elysium → HL → Elysium costs
≈ 0.96% **of the margin**, paid once. At a 25-30% margin slice that is ≈ 0.24-0.29% of the deposit.

### 6.2 Recommended margin path (fits the current contracts, no change before the audit)

```
onboard:  client USDC ──Arbitrum→Elysium (Relay, ~0.02%)──▶ account ──sendHedgeMargin──▶ hedgeTreasury (Elysium)
          hedgeTreasury ──Relay deposit to HyperCore (0.94%, batched)──▶ HL account (all clients)
exit:     HL ──Relay withdraw (0.03%)──▶ hedgeTreasury ──returnHedgeMargin──▶ account ──client withdraws──▶ wallet
```

- **Fit with the immutable treasury.** The module only verifies the transfer into `hedgeTreasury`. Moving USDC from the
  treasury to Relay, and from HL back to the treasury, is operator custody, already out of audit scope. The keeper (or a
  separate treasury bot holding the treasury key) initiates the Relay deposits and withdrawals.
  - **No contract change is needed for this path.**
  - The treasury key becomes a hot key. Its exposure is bounded by keeping the Elysium balance near zero: bridge each
    batch promptly, and pay returns from incoming margin first.
- **Who pays.** Each Relay crossing is recorded as a ledger batch. Its actual cost is charged to the equity of the clients
  whose margin crossed, pro rata, through a new `ledger.bridge_cost(batch)`. This replaces today's reconciliation, which
  spreads every difference over all clients by short notional. On-chain `hedgeEquity` follows down through the existing
  keeper-only decrease, so the client's profit, and therefore the fee, already nets the cost.
- **Netting (no float).** Inflows of new clients' margin and returns to exiting clients meet at the treasury on Elysium.
  Returns are paid from the treasury's Elysium balance first; only the net goes over Relay. Elysium → HL runs as a batch
  per tick when the net is above a minimum, or immediately when the HL margin ratio is below target. HL → Elysium runs
  per exit when the treasury is short (it is cheap). The ledger keeps per-client `margin_in` / `margin_out`; `in_transit`
  becomes a list of batches (id, amount, clients, Relay request id, state) reconciled against HL deposits / withdrawals and
  the treasury balance.
- **Margin sizing, so that top-ups (0.94% each) are rare.**
  - Short ≈ 0.5 × LP ≈ 0.36 × value (LP 72%).
  - With 25% margin, HL liquidation of the client's share needs HYPE about +60% (the LP sells HYPE as price rises, so the
    short shrinks). Top-ups are therefore rare at 25%.
  - **Recommend 30% at onboarding** (cap 35%). Top up only when equity_i < 35% of the client's short notional. Return the
    excess (HL → Elysium, 0.03%) when equity_i > 120% of short notional, which happens after HYPE falls.
  - Top-up source: idle USDC (enforcer ≤ 35%/day of idle), freed by a partial LP decrease when needed.
- **Minimum deposit $100**: margin $30, short ≈ $36 notional. That works only netted (the HL minimum order is $10). The
  bridge cost is about $0.28 at 0.94%. The ledger handles sub-lot shares (`release_dust`).

### 6.3 Gaps found (product 3 at scale)

| # | Gap | Fix (off-chain unless noted) |
|---|---|---|
| G1 | Bridging treasury ⇄ HL is a **MANUAL alert** (`margin_bridge`, `exit_margin_*`). A new client's short is opened on other clients' HL margin until someone bridges. | Treasury bot: Relay deposit (Elysium → HyperCore) in the same tick after margin sends and before `hedge()`. Relay withdraw (HL → treasury) when returns exceed the treasury balance. Both behind the live gate. Add to `hl.py` / a new `bridge.py`. |
| G2 | Bridge costs are not attributed: reconciliation spreads them over all clients by short notional. | Ledger batches with per-client cost (§6.2). |
| G3 | On exit the keeper returns at most the **on-chain** hedge equity. Gains above it need the guardian or the treasury itself: manual. | The treasury bot calls `returnHedgeMargin` for the remainder (the treasury may return any amount; it is a payout to the client). Alternatively the guardian bot approves increases automatically within a tolerance of the ledger. |
| G4 | One cross-margined HL account: a client whose equity_i goes negative (large HYPE rally, no top-up) is carried by the others. | Per-client margin floor (top-up at 35% of notional; if the top-up is impossible, cut that client's short and alert); reconcile negative equity to that client only. |
| G5 | Raising on-chain hedge equity needs a guardian transaction **per account**. At N clients that is N approvals. Without them, fees lag (operator-side only). | Guardian bot batches approvals in `multicall`-style transactions within a ledger tolerance. Equity increases are not needed for client safety. |
| G6 | Exit is "one action" for the pool only. Hedge close + margin return is automatic only while the HL adapter is live and the treasury holds enough USDC on Elysium. Otherwise it is a manual alert. Withdraw is a second client transaction. | With G1 + G3: the client's stop transaction leads to the short closed on the same tick (≤ 60 s) and the margin in the account on the next tick (≈ 1-3 min, Relay ~1 s). The page polls and enables "Withdraw" when `hedgeEquity == 0`. Optional later: return the margin straight to the client's Arbitrum wallet (needs a contract change, §6.4). |
| G7 | Tick time grows linearly: one account per transaction, plus a stagger. The anchor must be re-confirmed within `minPriceStable` (300 s) for every swap and add. | Parallel reads; batch `reportHedgeEquity` / `sync` in `multicall`; re-report the anchor inside long ticks (already checked per chunk). |
| G8 | Shared pool depth: all clients re-range at the same moment (same triggers). | Stagger re-ranges across ticks by account; cap total swap notional per tick to pool depth. |

### 6.4 What would need a contract change (flagged, NOT in round 4)

The owner's cheapest-direction ideas are: fund the margin directly on HL from the client's source chain (Arbitrum →
HL is free), and return it from HL straight to the client's wallet. Both bypass the account. The books then break:
- If margin enters HL without passing through `sendHedgeMargin`, `contributed` never includes it.
  - Reporting it as `hedgeEquity` (guardian) turns it into **profit**, so the HWM fee would be charged on principal.
  - Not reporting it leaves hedged clients' LP gains unnetted against hedge losses, so the fee is also charged on
    non-profit.
- Returning margin outside the account has the mirror problem.

The fix would be one profit-neutral module function, `bookExternalMargin(a, amount, in/out)`:
- It moves `hedgeEquity` and `contributed` by the same amount: in requires ≤ hedgeCap of the post-booking value, as
  `sendHedgeMargin`; out requires ≤ hedgeEquity.
- It is profit-neutral by construction. Its only side effect is that a larger value scales the turnover, exit and step
  budgets, which is bounded by the 35% cap as today.
- It also needs attribution of HL deposits to clients (Bridge2 credits the sender's own HL address, so the client would
  have to `usdSend` to our account, which adds a signature and an HL account per client).

The saving is ≈ 0.94% of the margin, ≈ 0.24-0.28% of the deposit, once. **Recommendation: keep the immutable-treasury
path for the pilot and round 4.** Consider `bookExternalMargin` for a later round if volume justifies it. The module has
580 bytes left, which is enough for a small function but leaves little room.

## 7. Go-live list

1. Audit round 4 including the R4 exit window (`docs/audit_sa_round4.txt`), then deploy (module with `exitTurnoverBps`,
   enforcer, executor) and fill `web/config.js`.
2. Pilot Params: `swapTurnoverBps` 5000, `exitTurnoverBps` 10000 (deployed by the script and read back, SA-4 L-12).
   Re-check the page's manual minimum (turnover floor).
3. Guardian bot: pause on an anchor/HL gap, **and automatic `approvePrice` after a > 10%/24 h move** (risk-off exits and
   re-ranges stall without it).
4. Server: API + keeper units, `sa-requests/` (+ `strategy/`), `sa-status/`, the nginx include. The keeper needs outbound
   HL info for 1 h and 4 h candles (BTC, HYPE).
5. HL live adapter (gated) + the treasury/Relay bot (G1). Until then product 3 is dry-run or manual bridging.
6. Ledger: bridge batches with per-client cost (G2), per-client margin floor (G4), treasury remainder returns (G3).
7. A MetaMask test of the v2 Strategy signature on 99901 (the page recovers it locally before sending).
8. A measurement of arbitrage speed on the Elysium pool (how fast the pool returns within 50 bps after a $230 push),
   before risk-off is offered above a few thousand dollars.
9. Owner review of the risk-off wording and the recommendation numbers before they are public.

## 8. Built vs missing (honest)

| Area | Built (tested offline) | Missing |
|---|---|---|
| Contracts | Module / libs / enforcer / executor through audit round 3 fixes. **R4 exit window** (+7 Foundry tests). 228 Foundry tests pass offline (2 fork tests skipped). | Audit round 4 result. Deployment. `bookExternalMargin` (only if direct-to-HL funding is chosen). |
| Product 1 | Keeper re-range / width / turnover floor / fee, wizard, status, API. | Live deployment. Arbitrage-speed measurement. |
| Product 2 | Strategy v2 `riskOff` (v1 still valid), `riskoff.py` signal (validated against pandas and the research data), keeper exit / hold / re-entry, status "out since …", wizard card + review + status rows, 17 pytest tests. | A fork e2e of a full exit at pilot Params on the replica (Foundry covers the contract side). Automatic guardian `approvePrice`. A capacity plan beyond pool depth (HL-short alternative). |
| Product 3 | Margin send / return (on-chain), netted HL orders (dry-run; live gated), ledger, unhedged switch, exit wind-down. | G1-G8: automated Relay bridging, cost attribution, remainder returns, per-client margin floor, batched guardian approvals, tick scaling. |
| Ops | Status file, API, alerts. | Monitoring of signal staleness to the owner bot. Runbooks. |
