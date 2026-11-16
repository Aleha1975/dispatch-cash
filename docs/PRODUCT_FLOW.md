# Product flow: per-client hedged / unhedged LP on Elysium

Branch `sa-product` (built on `sa-r3-fixes`). Off-chain only: **no contract under `src/` changed** (the contracts are
in audit round 4 at `f70cee1`). Date: 2026-11-16.

## 1. What the client does

| Step | Page (`web/account.html`) | What happens |
|---|---|---|
| Pool | One whitelisted pool: a confirmation card (HYPE / USDC, Uniswap v4, 0.30%; price, volume, volatility). A list appears only once more pools are whitelisted. | Picks the module (one `LPManagerModule` per pool). |
| Range | **Auto** (recommended) or **Manual** slider (half-width, bounds from `GET /recommend`, the recommendation marked). Live preview of the range on a price axis; est. fee APR, re-centres / week, est. net APR. | Nothing is sent. |
| Hedge | **Hedged**: earn fees, minimal HYPE exposure (short on Hyperliquid, 10% re-adjust band, ~25% of the deposit as margin). **Unhedged**: full HYPE exposure + fees (shows the loss vs holding at the range edge). | Nothing is sent. |
| Amount | USDC amount (or "use this wallet" for a MetaMask 7702 account). | |
| Review | Pool, width, range now, hedge, deposit, **15% performance fee above the high-water mark, no other fee**, leave any time. | |
| Sign | 1. delegation (EIP-712, DelegationManager), 2. USDC permit (EIP-2612; not for 7702), 3. **Strategy** (EIP-712, below). No transaction, no gas. | `POST /elysium-api/sa/onboard` → queue → the keeper's relayer deploys the HybridDeleGator and calls `module.onboard` (one tx), then stores the Strategy. |
| Status | Return % since deposit (before the fee), range with in / out of range, strategy (+ a pending change), hedge (margin % of account, HYPE short), value, fees paid as % of deposits. **Change strategy** = one more Strategy signature (`POST /strategy`). Exit and withdraw unchanged. | |

`?mock=1` (or `?mock=<state>&step=<step>`) walks through every state without a wallet; `web/mock/recommend.json` is a
real snapshot of the recommendation.

## 2. The Strategy message (prefs schema)

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
  name = "Elysium LP Strategy", version = "1", chainId = 99901, verifyingContract = the module (= the pool)
Strategy(address owner,address account,address module,uint8 widthMode,uint32 widthBps,bool hedged,uint64 nonce,uint64 deadline)
```

| Field | Meaning |
|---|---|
| `owner` | The signing EOA (HybridDeleGator owner; for 7702 the account itself). Must recover from the signature (low s, v ∈ {27, 28}). |
| `account` | The managed account: CREATE2 HybridDeleGator of `owner`, or the 7702 EOA. |
| `module` | The pool's `LPManagerModule`. A Strategy for another pool is refused. |
| `widthMode` | 0 = auto, 1 = manual. |
| `widthBps` | Manual only (auto: must be 0). **Half-width** in bps of the price at (re)centring: the range is `[P·(1−w), P·(1+w)]`, widened outward to tick spacing 60. Bounds `[sa.width_min_bps, sa.width_max_bps]` = [200, 4000]. |
| `hedged` | true = margin + HL short; false = neither. |
| `nonce` | Strictly above the stored one (the web uses `Date.now()` ms): an old signature can never undo a newer choice. |
| `deadline` | Submission window only: the keeper must receive it before then (API: ≥ now + 5 min, ≤ now + 2 days). An accepted Strategy stays until a newer one. |

Wire format (onboarding body field `strategy`, and `POST /strategy {owner, kind, strategy}`): the message fields plus
`signature` (65-byte hex); uints as numbers or decimal strings. `strategy` is optional at onboarding: an account
without one is managed as **auto, hedged** (`sa.default_hedged`), exactly as before this branch.

Code: `keeper/elysium_keeper/prefs.py` (typed data, parsing, `verify`), `web/account.js` (`signStrategy`: builds the
same typed data and recovers the signer locally before sending).

## 3. Where each piece lives: on-chain vs off-chain

| On-chain (audited contracts, unchanged) | Off-chain (this branch) |
|---|---|
| Delegation (client-signed), custody enforcer, module: pool fixed by the immutable PoolKey, recipients = the account, hedge margin only to the immutable treasury (≤ 35% cap), fee only to the fee recipient, **15% HWM fee at most once per 7 days**, anchor / band / turnover / hedge-equity limits, client exit in one tx. | Strategy signature and its storage (keeper state `prefs`, with the signature), width choice (auto / manual), re-range triggers, hedged / unhedged, the recommendation, the web wizard. |

API (`sa_api.py`, stdlib, 127.0.0.1:8790, holds no key):
- `POST /elysium-api/sa/onboard` — unchanged checks plus the optional `strategy` (binding to owner / account / module,
  bounds, deadline, signature) before anything is queued.
- `POST /elysium-api/sa/strategy` — same checks; nonce must beat the active (keeper status), queued and onboarding
  ones; the account must be registered and live, or its onboarding queued. Queued as
  `requests_dir/strategy/<owner>-<nonce>.json` (atomic, never overwrites; an identical resubmission is a 200).
- `GET /elysium-api/sa/recommend` — the keeper's recommendation file with `age_s` / `stale`.
- `GET /elysium-api/sa/status` — adds `strategy`, `strategy_pending`, and in `summary`: `return_pct`, `range`
  (`lower`, `upper`, `in_range`, `price`), `strategy` (incl. `effective_width_bps`, `clamped`, `turnover_floor_bps`).

Keeper (`sa_keeper.py`): re-verifies every Strategy itself (it does not trust the API's queue), applies updates in
nonce order (`strategy/done`, `strategy/failed`), keeps an update for a not-yet-registered account until its deadline.

## 4. Keeper behaviour per preference

- **Width.** Auto = `k × σ` (k = 2.5, σ = 72 h realized daily vol from HL 1 h candles, clipped 3–40%) — the same
  function the page shows as "recommended"; recomputed at every re-range. Manual = the client's half-width,
  re-centred on every re-range. If a manual width is below the **live turnover floor** (§5) the keeper uses the floor
  and reports `clamped` (the page says "widened").
- **Re-range triggers** (`rerange_reason`): out of range (always, as before); price within `sa.edge_frac` = 10% of the
  range width from an edge; a newer Strategy whose width differs by > 25%; manual width off by > 25%; auto width
  off by > 2× (vol regime change). The in-range triggers run only when the account's turnover room covers the
  re-deploy (swap + add charge) and the anchor is trusted; otherwise they wait (`rerange_postponed`) — an in-range
  position keeps earning.
- **Hedged**: unchanged path — margin first (target 25% of value), LP, fee, target short = LP HYPE + idle HYPE, one
  netted HL order with the 10% drift band, ledger split, equity reports. HL live orders stay behind the existing
  double gate (`hl.adapter = live` + `hl.live_enabled` + env); default dry-run.
- **Unhedged**: no margin send, no margin reserved in the LP split, ledger target 0. An account that switches from
  hedged: the netted order closes its short share, then its hedge equity is returned **into the account**
  (`returnHedgeMargin`, ≤ on-chain hedge equity, same code as the exit wind-down, ledger entry kept open), on-chain
  equity follows the ledger down.
- **Fee**: unchanged (≤ once per 7 days, 15% above the HWM, trusted anchor, fee gate).
- Idempotent: every decision is recomputed from a fresh chain read; prefs, the last mint's (nonce, width) and the
  event cursor are in the state file; a restarted keeper does nothing new (fork e2e).

## 5. Width bounds and the contract

Nothing in `LPManagerModule` / `SALib` / `SABook` / the enforcer constrains the tick range: the keeper is free to
choose any ticks in the fixed pool (multiples of tickSpacing 60, ≤ 4 positions). What bounds the width is indirect:

1. **Tick spacing 60** (one spacing ≈ 0.6%): `range_ticks` widens outward to spacing, so below ±2% the rounding
   (up to +0.6% per side) dominates the chosen width → `width_min_bps = 200`.
2. **Turnover budget** (`swapTurnoverBps` × account value per sliding 24 h, SAWindow): every re-range spends the
   re-centring swap (change of the HYPE share, up to ~50% of the LP) **plus** the LP add, charged
   `paid × maxSlippageBps / (maxSlippageBps + poolBandBps)` (`SABook.lpAdd`; 0.5 × LP with the deploy defaults
   150 / 150). Expected re-ranges per day for a Brownian log price from the centre to the triggers at distances a, b:
   `σ² / (a·b)`. The **turnover floor** is the narrowest half-width whose expected re-ranges fit 80% of the budget
   (`recommend.turnover_floor`). Examples (HYPE price $65.9):

   | σ daily | swapTurnoverBps | floor hedged / unhedged | auto (2.5σ) |
   |---|---|---|---|
   | 4.0% | 20000 (deploy default) | ±2.7% / ±3.3% | ±10% |
   | 4.0% | 5000 (pilot) | ±6.2% / ±7.1% | ±10% |
   | 6.5% | 20000 | ±5.0% / ±5.8% | ±16% |
   | 6.5% | 5000 | ±10.3% / ±11.7% | ±16% |

   The floor moves with volatility and Params, so it is not a static bound of the signed message: the API accepts
   [200, 4000]; the page's slider starts at `bounds.manual_min_bps` (floor rounded up to 50 bps); the keeper widens a
   manual width below the live floor.
3. **`AddValue` check** (`got ≥ paid × (1 − maxSlippageBps)`, pool within 50 bps of the anchor): the LP-curve vs
   holdings gap is ≈ δ²/(4h) for a pool-anchor gap δ — for δ ≤ 0.5% and slippage 150 bps it binds only below about ±0.04%, so not a bound here.
4. **Upper bound 4000** (±40%) = the keeper's `max_half_width`; nothing on-chain forbids wider, it just earns little.

**No contract change is required** for this flow.

## 6. Recommendation (`recommend.py`, `GET /recommend`)

Written by the keeper every `sa.recommend_every_s` (900 s) to `sa.recommend_path`; also `python -m elysium_keeper
sa-recommend --config cfg.json [--out f.json]` (read only). Inputs: HL `candleSnapshot` 1 h (72 h and 7 d vol),
PoolManager `extsload` of slot0 / feeGrowthGlobal0/1 / liquidity at the head and at blocks 24 h and 7 d earlier
(the Elysium RPC serves history; ~0.25 s blocks; User-Agent sent; free RPC only), the module's Params (deploy
defaults before deployment). Per width (grid 2–40% plus the recommendation), for hedged (LP share 72%) and unhedged
(97%):

- `fee_apr_in_range` = fees per unit of in-range liquidity per day / position value per unit of liquidity × 365,
  diluted by our own liquidity (all clients' capital, at least `sa.recommend_reference_usd` = $25k) at the same volume;
- `rebalances_per_week`, `in_range_frac` (turnover-bounded), `turnover_per_rebalance`;
- `est_rerange_loss_apr` (LP vs holding the entry mix at the trigger × re-ranges: the convexity loss the hedge does
  not remove), `est_swap_cost_apr` (pool fee + 5 bps impact on the re-centring swap), `est_net_apr`;
- unhedged: `il_at_edge` (loss vs holding at the range edge), HYPE share at the centre.

Snapshot (2026-11-16, σ72h 6.5%, pool ~$91k volume/day, $273 fees/day): recommended ±16.2%, est. fee APR (hedged,
diluted by $25k) ≈ 216%, ~1.7 re-centres / week, est. net ≈ 29% hedged / −7% unhedged (before HYPE moves). The
narrow widths are net negative under this model; hedged turns positive from about ±15%, unhedged from about ±20%. These are model estimates (the page
says so); the pool is shallow, so our own size dominates the realised APR.

## 7. Trust note

The Strategy is **enforced by our keeper, not by the contract**. The module does not know the client's width or
hedge choice: a compromised or buggy keeper could ignore them (e.g. trade at another width, send hedge margin for an
unhedged client). What it can **not** do is unchanged by this branch: every keeper action still goes through the
module and the client-signed custody enforcer — the fixed pool only, recipients = the account, hedge margin only to
the immutable treasury within the 35% cap (and 35% of idle USDC per 24 h), the fee only to the fee recipient, 15%
above the HWM at most once per 7 days, turnover / anchor / band limits — and the client can stop everything with one
transaction. The signed Strategy is kept with its signature in the keeper state, so what the client asked for is
provable; the status endpoint shows the effective width and hedge so a deviation is visible.

## 8. Adding a pool

A pool = one hook-free Uniswap v4 pool with the asset (USDC) on one side. Deploy another `LPManagerModule` (+ its
custody enforcer and SwapExecutor, which pin the same PoolKey) with `script/DeploySA.s.sol`, run one more keeper
(`sa.module` = it) and one more API instance (own `requests_dir`, `status_path`, `recommend_path`, port and nginx
prefix), and add an entry to `sa.pools` (keeper) and `smartAccount.pools` (`web/config.js`, with its `module` and
`api`). With more than one entry the page shows a picker instead of the confirmation card. The keeper assumes native
HYPE = currency0 (`ModuleReader`); another base token needs that generalised (off-chain only). Uniswap-v3-style NFT
managers (Aerodrome Slipstream, Ramses) would need new audited contracts and are out of scope.

## 9. Before go-live

1. Audit round 4 result for `src/sa` (unchanged here), then deploy (module, enforcer, executor; HybridDeleGatorImpl +
   SimpleFactory at the canonical addresses) and fill `web/config.js` (`pools[0].module`, `enforcer`,
   `hedgeTreasury`, `feeRecipient`).
2. Server: API + keeper units, `sa-requests/` (+ `strategy/`), `sa-status/` with `status_path` and `recommend_path`,
   the nginx include (now with `/strategy` and `/recommend`).
3. Pilot Params (`swapTurnoverBps` 5000 per the pilot plan) raise the turnover floor (§5 table): check the page's
   manual minimum and the auto width against it on day one.
4. HL: live adapter, treasury ↔ HL bridging and the guardian bot stay manual / gated as before; unhedged accounts
   reduce the HL capital needed.
5. A wallet test on 99901 of the three signatures in MetaMask (the Strategy recovery check runs in the page).
6. Owner review of the recommendation model's numbers (esp. the dilution assumption and the re-range loss) before
   showing APRs publicly.
