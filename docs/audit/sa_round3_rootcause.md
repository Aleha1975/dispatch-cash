# SA audit round 3: findings grouped by root cause

Inputs, de-duplicated: `docs/audit/sa_round3_report_1226.md` (0 C, 0 H, 4 M, 22 L, 8 I) and
`docs/audit/sa_round3b_report_1227.md` (0 C, 0 H, 8 M, 27 L, 18 I, keeper K-1..K-13), both at commit `ecb6eda`.
Earlier rounds: `sa_round1_rootcause.md`, `sa_round2_rootcause.md` and the two responses.

Written before the fixes, as in rounds 1 and 2. Priorities for every decision below, in this order:
**client principal safety > liveness > accuracy of our fee**. A residual that can only lower the operator's fee is
accepted and documented (it favours the client); a residual that can move client principal is not.

## 0. First question: is 1227 M-2 a principal-loss path?

1227 M-2: an upgraded account replaces the module's swap with its own swap through the same `SwapExecutor`; the module
books the executor's record as if it were its swap. We traced every direction:

- The substituted swap is paid from and paid to the account itself (`payer = msg.sender = the account`). Its loss is the
  client's own loss, made by the client's own code; nothing leaves the account except into the pool.
- What the module mis-books is the account's own books: a bad trade booked as a trading result lowers profit (our fee
  goes down) and a favourable one booked as such could at most raise the fee base by the gap between the substituted
  and the requested swap. For that to be a fee on principal the client's code would have to pay for it.
- No third-party funds, no other account's books and no operator funds are reachable through the record (it is keyed
  by payer in transient storage, written only by the executor's `unlockCallback` frame).

So M-2 is a fee-base error, not a principal-loss path. It is still fixed structurally (class S below), because the
"computed effect" invariant of round 2 must hold without exceptions.

| Class | Root cause | Findings (1226 / 1227) |
|---|---|---|
| F | `sync` and `value` are not the same function: LP fees are in `value`, not in the flow | 1226 M-1; 1227 M-1 |
| S | The swap record says "a swap happened", not "this swap happened" | 1227 M-2; 1226 L-4 |
| R | The anchor drift budget charges path length, and the guardian range consumes it | 1227 M-7; 1226 M-2 (budget part), L-2; 1227 I-11 |
| T | The booking moment and the anchor at booking are not neutral | 1226 M-4, M-2 (swap part), L-5, L-6; 1227 M-4, M-5, L-3, L-4, L-7; K-1, K-6, K-11 |
| P | The fee price differs from the booking price, and one pool read at the fee is pushable | 1226 M-3, L-1, L-3, I-1, I-2, I-7; 1227 M-3, M-6, L-1, L-2, L-11; K-2, K-4 |
| A | Consent and registration edges | 1226 L-7, L-14; 1227 L-5, L-6, L-14, I-1, I-8, I-14 |
| G | Governance and deployment | 1226 L-11, L-12, L-13, L-17; 1227 L-12, L-13, L-16, I-2, I-3, I-15, I-17 |
| O | Operational residuals of earlier rounds | 1226 L-8, L-9, L-10, L-15, L-16, L-18, I-4, I-5, I-6; 1227 L-8, L-9, L-10, L-15, L-17, I-4..I-7, I-9, I-10, I-12, I-13, I-16 |
| K | Keeper mirrors and policy | 1226 L-19..L-22, I-8; 1227 K-3, K-5, K-7..K-10, K-12, K-13 |

---

## F. LP fees: yield in `value`, flow in `sync`

**What went wrong.** `value()` counts a tracked position's principal plus its uncollected fees. `sync` booked
`live − snapshot` as client flow, where live idle includes fees the client collected itself (POSM decrease(0), burn,
or a collect to an outside address). The fees therefore moved from "uncollected, in value" to "idle, booked as a
deposit": profit fell by the whole fee income (both reports, independently by most agents). Round 2 called it a bounded
residual; the bound was the whole LP income.

**Invariant F.** Fees that PoolManager paid out of a tracked position since the books last looked at it are yield, not
flow: they are added to the snapshot first, and only then is `live − snapshot` booked.

**Structural change.** Each tracked position keeps a fee checkpoint, `snapPos[id] = (liq, feeGrowthInside0Last,
feeGrowthInside1Last)`, written from PoolManager's `getPositionInfo` after every module modify. `SABook.sync` runs,
per position and **independently of the price** (so even an untrusted sync keeps the fee marks right):
`fees = (PM.feeGrowthInsideLast_now − mark) × n`, added to `snapAsset / snapBase`, with
`n = min(live, booked)` liquidity while the account still owns the NFT, `n = booked` if PoolManager shows the position
emptied (burn), `0` if the NFT left the account. Then the liquidity and idle deltas are booked as before.
PoolManager's `feeGrowthInsideLast` only moves when someone modifies the position (that is exactly when fees are paid
out), so the difference is precisely what was paid out, wherever it went.

**Siblings checked.** Client decrease(0) into the account; collect to an outside address (a withdrawal of profit:
contributed falls, profit keeps the fees); client burn; NFT transferred out (fees not counted: client favour); client
partial decrease (fees on the removed part counted as flow: client favour); module actions (marks rewritten after
each modify, so nothing is double counted); positions the client adds to directly (pending liquidity delta as before).

**Residuals (all lower only our fee, except the last, which is bounded and self-inflicted).**
- Fees of an NFT the client transferred out, and the fee share of a client partial decrease, are not counted as yield.
- A client who changes a tracked position's liquidity several times between two syncs (down, then up) can make
  `n` larger than the liquidity that earned part of the interval. The over-count is bounded by fees on the client's own
  added liquidity over that interval (it is the client's own fee income, priced at the pool's fee).

## S. The swap record is bound to the module's call

**What went wrong.** `SwapExecutor` recorded `(count, paid, received)` per payer; the module required "one new record"
and `received >= minOut`. Account code inside the redemption could run its own swap instead (any size, either
direction: 1227 M-2), and the module assigned units from its own flag (1226 L-4).

**Invariant S.** A swap is booked only if the executor ran exactly the module's call.

**Change.** The executor records `keccak256(msg.data)` of the call it executed next to `(n, paid, received)`;
`lastSwap(payer)` returns all four. The module requires `n1 == n0 + 1`, `hash == keccak256(the call it built)` and
`received >= minOut`; otherwise `BelowMinOutOrBadSwap`. Direction, size, min-out and price limit are therefore all
the module's.

## R. The anchor drift budget: net displacement, not path length

**What went wrong.** The 24 h window summed every move. Ordinary volatility (σ ≈ 4-6%/day, hysteresis 25 bps) uses a
10% path budget in hours; the guardian's approved jump was charged to the window and filled it (1227 M-7, 1226 L-2).
Then the anchor froze, and margin sends, swaps and adds stopped for a day: a liveness failure created by honest
behaviour. A single report could also use the whole budget (1226 M-2).

**Invariant R.** The keeper alone can move the anchor at most `refDriftBps` away from **every** value it held during the
trailing 24 h, in either direction; an oscillation that comes back costs nothing. A guardian-approved level starts a new
window.

**Change.** New `SARange` (nine 3 h buckets of (min, max)); `movePrice` clamps the report into
`[hi/(1+cap), lo·(1+cap)]` of the trailing range (both bounds include the current anchor), records the old and the new
value; a guardian range is used only for a report the budget would clip and then resets the range. `priceUsed` is now
`(hi − lo) / lo`.

**Considered and dropped.** A path-length backstop on top (e.g. 3× the net budget): realised path per day is roughly
σ²/hysteresis, so any path budget either never binds or freezes the anchor in a volatile day. Liveness wins; the
stolen-keeper bound below is stated instead.

**Stolen-keeper bound (accepted, documented).** Inside the 10% range a stolen keeper can oscillate the anchor. Every
action that uses the anchor against the client is otherwise bounded: swaps and adds need a trusted anchor (class T) and
the pool within `poolBandBps` of the keeper price; swaps are floored at `maxSlippageBps`; turnover is
`swapTurnoverBps` of NAV per sliding day. Loss bound per day ≈ (band + slippage) × turnover ≈ 3% × 2 = 6% of NAV at the
defaults, plus the pool's own fee; less in practice since each swap must also clear the pool. Pilot recommendation:
`swapTurnoverBps` 5000 (50%/day), a guardian bot that pauses on an anchor/HL gap, and a keeper key on a single host.

## T. The booking moment and the anchor at booking

**What went wrong.** Three independent findings with one cause: a booking is neutral only at its instant, at the anchor.
- The anchor could sit a full `poolBandBps` (1.5%) from the pool when booked; a keeper at the band edge creates
  phantom profit (fee on principal); a client times its flows against the gap (1226 M-4, 1227 M-4).
- The keeper chose the booking moment, and swaps / adds acted on funds whose flow was pending (1227 M-5; 1226 M-2).
- A stale pre-outage anchor was trusted in the first block after the outage (1226 L-5, 1227 L-4).

**Invariant T.** A flow is booked, and the module acts on funds, only at a trusted anchor:
fresh (age ≤ `maxPriceAge`, not clipped, pool within `poolBandBps`), **unchanged for `minPriceStable`, re-confirmed by a
report within the last `minPriceStable`, and the pool within `BOOK_BAND_BPS` (50 bps) of it**. A report after a gap
longer than `minPriceStable` counts as a move.

**Changes.** `_trusted()` adds the recency check and the 50 bps booking band. Swaps, mints and increases require
`_trusted()` (their `_sync` therefore books every pending flow first). New permissionless `sync(a)` books a pending flow
at a trusted anchor: the booking moment is not the keeper's alone. `reportPrice` treats a gap as a move.

**Why not min/max pricing (1226 M-4's smallest fix).** As argued in round 2, any second price turns the difference into
profit or loss and a client can cycle it. The tight booking band attacks the cause (an anchor far from the pool) at
both sides with one price.

**Residuals.**
- Client timing inside the band: deposit while anchor > market, withdraw while anchor < market, gains at most
  2 × 50 bps per round trip of contributed (lowers only our fee; the keeper reports every 120 s with 25 bps
  hysteresis, so the window is short).
- A keeper booking at the band edge: phantom gain ≤ 50 bps × flow, fee ≤ 0.075% of the flow (stolen keeper only; the
  honest keeper reports the pool).
- Anyone who moves the pool > 50 bps off the anchor pauses booking, swaps and adds (1227 L-3, 1226 L-6). Liveness only:
  removals, margin returns and the client exit never need trust; the keeper re-reports and the window passes.

## P. The fee: one price, measured where it cannot be pushed

**What went wrong.** `chargeFee` booked pending flows at the anchor and then measured profit at
`min(V(anchor), V(pool))`: a base deposit parked before the fee was booked at one price and valued at another (1227 M-6,
1226 L-1: the fee goes to zero; the mirror over-charges). And `_trusted()` read the pool at one instant, so a keeper that
walked anchor and pool together inside its budget could charge on up to the drift budget (1226 M-3, 1227 M-3).

**Invariant P.** Profit for the fee is `V(anchor) − contributed` right after a trusted sync at that same anchor (a
parked flow is neutral), and only while the anchor is (a) not above the pool and (b) within `poolBandBps` of its
trailing 24 h low (`SALib.feeGate`). A walked-up anchor must be held a day in public view before it carries a fee.

**Bound (accepted).** A keeper that pushes the pool up 1.5% and holds it for `minPriceStable` against arbitrage can
charge on at most 1.5% × base exposure × `feeBps` once per `feeInterval` (0.225% of exposure per week at the defaults),
at a real cost in the pool. A falling market never blocks the gate; a rally defers the fee by up to a day (our fee only).

**Siblings.** Hedge equity at the fee (1227 L-2, 1226 L-3): a keeper-only decrease that cannot happen (paused, stale
anchor) now changes nothing at all (no flag, no report time); `hedgeClipped` clears on a full return. Equal reports
refreshing `hedgeTime` stay (equity is keeper-attested either way; the guardian approval covers increases). 1227 L-1 /
1226 L-10 (refuse only the fee): keeper stop rule (two refused due dates → stop managing). 1227 L-11 (`feeBps` change
applies to accrued profit): documented, timelocked. 1226 I-7 (profit accrued while revoked): documented.

## A. Consent and registration edges

- Permit fallback (1226 L-7, 1227 L-5): a consumed signature could be reused while an equal standing allowance existed.
  Now `(owner, nonce)` of the signature is marked used in the module's storage.
- `onboard` without liveness (1227 L-6): reverts `NotLive` unless the account is active (incl. DelegationManager not
  paused, now part of `isActive`).
- A signed but unregistered delegation (1226 L-14): the account can `revoke` before registration; the relayer cannot
  register it afterwards, the client can.
- 7702 exclusion order (1227 I-1): treasury / fee recipient rejected before either branch.
- I-8 (ECDSA-only onboard), I-14 (a stale delegation registered first): documented; the client replaces it.

## G. Governance and deployment

- Rotation order (1226 L-11, 1227 L-12): NatSpec corrected (schedule step 2 only after step 1 executed; 2 × delay).
- Per-operation delay above `MAX_DELAY` refused; `isExpired(id)` view (1226 L-12, 1227 I-3).
- Proposer role cannot be renounced (1227 L-13); DeploySA requires a contract owner unless `ALLOW_EOA_OWNER`.
- `transferOwnership(address(0))` cancels a pending owner (1226 L-14, 1227 L-14); acceptance expiry: not added.
- `setPaused` repeats refused (1227 I-2).
- DeploySA (1226 L-13, 1227 L-16): venue runtime code compared with the fixtures, `POSM.poolManager() == PM`, roles
  and wiring read back from the deployed contracts, the probe fed from the module's getters.

## O / K. Operational residuals and the keeper

Unchanged and documented: multicall gas forwarding and selectors (single-account batches), approval resets on 7702
wallets, the enforcer bounding recipients not price, a USDC blacklist of an immutable endpoint, the
`returnHedgeMargin` allowance (operator: approve just-in-time, per return), partial fills reverting, LP-add turnover
weighting, sequencer clock, account gas stipends, ERC-1271 of HybridDeleGator.

Keeper (all in `keeper/elysium_keeper/`): pending mirror includes the fee-out step; `trusted()` mirrors the contract
(pool denominator, recency, booking band); `fee_profit` at the anchor; fee-gate mirror; reports every 120 s (<
`minPriceStable`); anchor held only while a fee is due and the pool is inside the booking band; `sync(a)` when a flow
is pending; swaps / adds only when trusted (re-checked between chunks); `minOut` = simulated output − 30 bps; removal
minima; fee-refusal stop rule; dust floor; a failed report never aborts the tick; `ownerOf` in the reader.
