# Elysium LP Vault — Security Audit (round 1)

**Job:** leftclaw.services #1222 · **Date:** 2026-11-13 · **Method:** deep-audit v3 (x-ray pre-scan → context map → 8 checklist agents → 12 blind attack agents → reconciliation + coverage gate)

**Repo:** https://github.com/Aleha1975/dispatch-cash · branch `elysium-lp-vault` · **commit `35cc81f22ad1884bb3a60bad8985b648f7ca0e55`** (verified reachable on the remote: `refs/heads/elysium-lp-vault`). Not deployed — no on-chain address to pin. Target chain per the client: Elysium, chain id 99901.

**Scope (as submitted):** `src/LPVaultBase.sol`, `src/UniV4LPVault.sol`, `src/V4PositionMath.sol`, `src/VaultTimelock.sol`, `src/interfaces/IExternal.sol`, `script/Deploy.s.sol` (950 nSLOC). `README.md` and `DESIGN.md` were read as the threat model and list of accepted risks. Nothing was compiled or executed (audit policy: no target-code execution), so every proof below is a hand trace against the source, and gas figures are estimates.

**Severity counts:** 0 Critical · 3 High · 10 Medium · 17 Low · 4 Informational

---

## How to read this report

- The client asked whether the keeper's on-chain bounds are **wrong or bypassable**, and declared keeper behaviour *inside* the bounds out of scope. The three High findings are all of that kind: each needs a compromised keeper key (plus, for two of them, an accomplice with capital), which `DESIGN.md` treats as an in-model adversary whose damage is supposed to be bounded at "a few % of NAV per day". In each case the documented bound does not hold and the loss reaches most of the holders' assets. A reader who treats the keeper as fully trusted should read these as Medium.
- No finding lets an unprivileged third party take funds from a correctly operated vault. The unprivileged findings are liveness and fairness issues (M-7, M-8, L-2, L-3, L-4).
- Accepted risks from `DESIGN.md` are not re-reported as such; where a finding touches one, it says how the real exposure differs.
- Each finding carries **Severity** (cost if real) and **Confidence** (how sure we are it is real) as separate fields, and an origin tag: `[both]` = raised independently by the checklist phase and the blind attack phase.

### Coverage caveat — read this

Phase 2 spawned all 12 attack agents (waves of 3), but **only 5 delivered output** (math-precision, access-control, invariant, numerical-gap, trust-gap). The other 7 (economic-security, execution-trace, periphery, first-principles, asymmetry, boundary, flow-gap) were stopped by an automated model safeguard before returning anything; per the methodology they were not respawned and their lenses were not substituted. Phase 1 (8 agents, 10 checklists) completed in full, and the coverage gate below was closed against the phase-0 inventory, threat catalog and invariant catalog. The depth phase is therefore thinner than a normal run: treat the absence of a finding in the areas those seven lenses specialise in (multi-step execution traces, periphery/native-token plumbing, asymmetric paths) as weaker evidence than usual.

### Reconciliation summary

`Overlap: 15 · Phase-1-only: 19 · Phase-2-only: 0 · Re-examined leads kept: 19, demoted: 0 (severity adjusted on 6) · Coverage holes closed: 1 · Invariants: 29 answered (18 hold, 11 violated, 0 unverified)`

`Completeness: 29 unique (Contract, function) across both phases, 29 covered.` Reporting floor: Low and above as findings; items with confidence < 50 are listed under Leads.

`Coverage: 30 entrypoints in inventory, 30 addressed. 19 threat rows, 19 answered. 29 inferred invariants, 29 answered. Holes closed this pass: 1` (`unwrapBase` — re-read, no issue: keeper-only, value-neutral, cannot touch reserved USDC).

---

## Answers to the client's ten questions

| # | Question | Short answer | Findings |
|---|---|---|---|
| 1 | Band-price extraction; third-party manipulation | Per settlement the skew is band × base-leg share (≈0.75% of NAV at 50% HYPE) **only if the pool is at fair value**. There is no per-day budget and no minimum settle interval, so a keeper + accomplice repeats it without limit (≈1.35% of incumbent NAV per round trip with a large accomplice). Worse, `settle` checks only spot, so a keeper who also moves the thin pool is not bound by the band at all. A third party alone, against an honest keeper, gains nothing material: the band makes `settle` revert, and LP amounts read at a skewed spot but valued at the true price are second-order. | H-2, M-4, M-10 |
| 2 | Hedge-equity budget + guardian override | Not sound. The budget is a % of `lastNav`, which an accomplice deposit inflates (loss to incumbents is unbounded, not 5%/day); the window is fixed, not rolling (2× burst); the guardian approval is an absolute number that the keeper can make wrong with `sendHedgeMargin`/`returnHedgeMargin`; an unhedged vault accepts equity too; the cap limits the reported number, not margin sent; and the budget sums absolute moves, so honest frequent settlement exhausts it. Approval reuse across epochs is not possible. | H-1, M-1, M-2, M-5, M-9, L-1 |
| 3 | Emergency unwind + pro-rata redeem | The trigger cannot be abused to extract value at a manipulated price (removing liquidity at a pushed price hurts the pusher, and the exit is in kind). But: the clock starts at deployment; the 10% band turns "72 h" into 7 days under ordinary volatility; sequencer downtime counts as keeper absence; `emergencyRedeem` pays out while positions are still open (and a caller may be able to induce that); shares at the vault outside the queue strand their slice; the exit is all-or-nothing across three assets. Sequential pro-rata redemption itself is order-independent and leak-free. | M-8, L-2, L-3, L-4, L-6, L-7 |
| 4 | Queue FIFO griefing | One redeem larger than idle USDC at the head blocks every later redeem (no partial fill, no skip, no cancel), while `settle` keeps the emergency timer reset. Cancelled deposits and dust redeems only cost keeper gas (bounded by `max*`). A blocked USDC recipient does not block the queue, but that recipient's money is then stuck because `claim()` pays only `msg.sender`. Zero-share deposits are consumed. | M-7, L-5, L-8 |
| 5 | Fee and HWM | The fee formula is exact: fee shares are worth exactly `feeAssets` after the mint, the HWM takes the post-mint pps, all rounding floors against the fee recipient, and no path charges more than `feeBps` of the gain. Two doc mismatches: the HWM can decrease in the `supply == 0` branch, and sub-unit gains raise it without a fee. Fees are minted on fake or manipulated gains (H-1, H-2, M-1). | I-1 |
| 6 | Native HYPE | No reentrancy or accounting issue found: every value-moving entry is `nonReentrant`, `unlockCallback` is gated, `emergencyRedeem` burns before paying and pays native last, SWEEP and TAKE land in an empty `receive()`. Action codes and encodings match the vendored v4-periphery. One robustness note: native `settle` is not preceded by `sync`. (The periphery/execution-trace attack lenses did not report — see coverage caveat.) | I-2 |
| 7 | Inflation / donation | The 1e6 offset holds. A donor loses the donation to the virtual shares; a victim loses at most one share unit = donation / 1e6 per deposit. `DESIGN.md`'s "victim loses < 1%" is true only for deposits ≥ 100 × donation / 1e6. A deposit that rounds to zero shares is consumed rather than refunded. | L-8 |
| 8 | Reserve segregation | Holds. `_checkReserve` follows every USDC-outflow keeper path; Permit2 sub-allowances are exact, same-block and reset; CLOSE_CURRENCY/SWEEP pay the vault; the callback is unreachable outside `swap`; redeems are bounded by `idleAsset()`. No path spends queued deposits or unpaid claims. | — |
| 9 | Timelock | No path changes a vault parameter without the delay. But the operator can make any vault change immune to the guardian's cancel by adding a no-op self-call to the batch; ready operations never expire; `updateDelay` has no upper bound; `renounceOwnership` is live; the 24 h floor is shorter than the only trustless exit (72 h). The guardian cannot block the operator permanently (the operator can rotate it in an uncancellable batch). | M-3, L-9, L-10, L-11, L-12 |
| 10 | V4PositionMath | Correct for the deployed configuration. `price` is exact to ~1e-18 relative with no overflow across the TickMath range; `amounts` matches core position accounting including fee-growth wraparound; the range branches match v4 at both boundaries; a zero-liquidity position correctly returns (0, 0); NAV equals burn proceeds at equal `sqrtPrice`. | — |

---

# Findings

## High

### H-1 — A queue deposit inflates the base of the hedge-equity drift budget, so "5% of NAV per day" is unbounded for incumbent holders

**Severity:** High · **Confidence:** 90 · **Origin:** [both] (phase 1: erc4626, oracles, general; phase 2: agents 1, 2, 5, 10, 11)
**Location:** `LPVaultBase._checkHedgeEquity` (`src/LPVaultBase.sol:489-490`), `settle` (`:390`), `hedgeCap` (`:292`), `_useTurnover` (`:521`)

```solidity
489        uint256 used = hedgeDriftUsed + diff;
490        if (used * BPS <= lastNav * params.hedgeStepBps) {
...
390        lastNav = nav;          // post-flow NAV: includes deposits processed in this settle
```

**Description.** The budget for unverified hedge equity is a percentage of `lastNav`, and `lastNav` includes any deposit processed in the previous settlement. A keeper's accomplice deposits k × NAV; the keeper may then fake 5% × (1 + k) × NAV of equity. The accomplice holds k/(1+k) of the supply, so it captures almost all of the fake gain when it redeems in the next settle — paid in real USDC, mostly its own idle deposit plus the incumbents' liquid assets. Nothing enforces an interval between settlements, so the accomplice's capital is exposed for two keeper transactions and is never at risk (fake equity is not a real loss). `settle` runs while paused, so the guardian cannot stop the redeem leg. `DESIGN.md` threat 4 and the accepted-risk list quantify this as "5%/day of NAV can be faked"; relative to incumbent capital it is 5% × (1 + k), bounded only by the vault's liquid assets. The same base inflates `hedgeCap()` and the swap turnover budget.

**Proof of concept** (defaults: `hedgeStepBps` 500, `feeBps` 1500).
1. Incumbent NAV N = 1,000,000 USDC at the high-water mark.
2. Accomplice `requestDeposit(9,000,000e6)`. Keeper settles with honest values: `lastNav` = 10,000,000; accomplice owns 90% of supply.
3. Accomplice `requestRedeem(all)` (split into several requests so the FIFO `break` at `:452` does not stop them).
4. Keeper settles with `hedgeEquity + 500,000`: `500,000 × 1e4 ≤ 10,000,000 × 500` passes with no guardian. NAV = 10,500,000; the fee mints 75,000 worth of shares.
5. Accomplice's shares are worth 0.9 × 10,425,000 = 9,382,500. It is paid from its own 9M of idle USDC plus 382,500 of the vault's (the keeper frees more with `decreasePosition`/`burnPosition`, which need no price check and work while paused).
6. Incumbents have lost 382,500 of 1,000,000 (38%) in one window; with a 19M deposit the same steps take ≈ 81%. The fee recipient also holds shares minted on the fake gain.

**Recommendation.** Do not size an off-chain-equity allowance from a base the queues can move. Either (A) track net margin sent (`+=` in `sendHedgeMargin`, `-=` in `returnHedgeMargin`) and bound the reported value against that, or (B) use the lowest `lastNav` seen in the window, fixed when the window opens. Independently, require the guardian path for any *increase* in reported equity not explained by a send, and consider a minimum interval between settlements that process queue items.

---

### H-2 — `settle` bounds the keeper price only against instantaneous pool spot, and rewrites the `lastPrice` anchor that every other price check depends on

**Severity:** High · **Confidence:** 85 · **Origin:** [both] (phase 1: general, oracles, defi-amm; phase 2: agents 2, 5, 11)
**Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:378`, `:391`), `_checkPoolBand` (`:471-476`), `_checkKeeperPrice` (`:502-508`)

```solidity
378        _checkPoolBand(r.price);
...
391        lastPrice = r.price;
...
473        uint256 p = _poolPrice();
474        uint256 diff = p > price ? p - price : price - p;
475        if (diff * BPS > price * params.poolBandBps) revert PoolPriceOff(p, price);
```

**Description.** `settle` compares `r.price` only with the pool's `slot0` in the same transaction. There is no TWAP (a hookless v4 pool has none), no second source, and — unlike `swap`/`mintPosition`, which go through `_checkKeeperPrice` — no drift check against the previous `lastPrice`. The pool is described as a few hundred thousand USD deep, and the vault's own LP is part of that depth, so a keeper who also trades the pool can place spot anywhere for the cost of the 0.3% fee on the round trip (price impact is recovered on the way back). Three consequences:

- **NAV mispricing is not capped at band × base share.** `DESIGN.md` threat 3 accepts "~0.75% of NAV skew per settlement"; that holds only when spot is honest. With spot pushed x%, the base leg is marked x% off, an accomplice in the queue is minted or paid at that NAV, and `_accrueFee` mints on the fictitious gain. The overstate-and-redeem direction works while paused.
- **`refDriftBps` is not an anchor.** A settle with `maxDeposits = maxRedeems = 0` costs nothing and re-bases `lastPrice` to the pushed spot; the 10% drift limit on `swap`, `mintPosition` and `increasePosition` then passes at that price, and can be walked again.
- **The 72 h–7 d emergency band** (`:614-618`) is anchored to the same keeper-written value.

**Proof of concept** (understate-and-deposit). Vault: 500,000 USDC idle and HYPE worth 500,000. An accomplice queues an 850,000 USDC deposit and sells HYPE into the pool until spot is 30% lower. Keeper `settle(price = spot)`: the band passes; NAV = 500,000 + 350,000 = 850,000; the accomplice receives 50% of supply. The accomplice buys the pool back. At the next honest settle NAV is 1,850,000 and the accomplice redeems 925,000 — a gain of 75,000 (7.5% of incumbent NAV) for a few hundred USDC of pool fees; a deeper push or a larger deposit takes more. (Exact numbers depend on how much of the base leg is in-range LP, which converts while spot is pushed; the steps are separate keeper transactions unless the keeper account can batch.)

**Recommendation.** Give `settle` a reference the keeper cannot move in-block: bound `|r.price − lastPrice|` per elapsed time with a guardian co-sign beyond it (the pattern already used for hedge equity), and/or check against an independent feed. Do not let an empty settle refresh the anchor used by LP and swap checks — keep a separate, rate-limited reference.

---

### H-3 — `mintPosition` / `increasePosition` are swaps in effect but skip the swap bounds (no turnover budget, no min-out, free range choice)

**Severity:** High · **Confidence:** 85 · **Origin:** [both] (phase 1: defi-amm, precision-math, oracles; phase 2: agents 1, 2, 5, 11; agent 10 as lead)
**Location:** `UniV4LPVault.mintPosition` (`src/UniV4LPVault.sol:148`), `increasePosition` (`:171`), `swap` (`:269-270`), `decreasePosition` (`:185-198`), `burnPosition` (`:201-211`)

```solidity
148        _checkKeeperPrice(keeperPrice);
149        if (_positions.length >= MAX_POSITIONS) revert TooManyPositions();
...
269        _useTurnover(sellBase ? fair : amountIn);                              // swap only
270        uint256 minOut = Math.mulDiv(fair, BPS - params.maxSlippageBps, BPS);  // swap only
```

**Description.** In `swap`, `keeperPrice` feeds `fair`, `minOut` and the turnover budget. In a mint or increase it is checked and then never used: ticks, liquidity and maxima are free keeper inputs, `_useTurnover` is not called, and nothing compares what the vault pays in with what the position is worth. A single-sided narrow range next to a displaced spot is a resting limit order at an off-market price for an arbitrary share of vault assets. The only effective constraint is "spot within `refDriftBps` + `poolBandBps` of `lastPrice`" (≈ 11.6% at defaults, ≈ 36% at the hard caps) — and with H-2 not even that. The exit side (`burnPosition`/`decreasePosition`) has no price check and keeper-chosen minimums, so the loop repeats in both directions. `DESIGN.md` threat 2 states the residual for "keeper sandwiches its own swaps / mints" as "~(band + slippage) per swap, bounded by turnover: worst case a few % of NAV per day"; for mints neither bound applies.

**Proof of concept** (`lastPrice` = 30.00, vault has 1,000,000 idle USDC, defaults).
1. The keeper's wallet buys HYPE until spot is 33.00.
2. `mintPosition(tickLower ≈ 32.8, tickUpper ≈ 33.0, L, amount0Max = 0, amount1Max = 1,000,000e6, keeperPrice = 33.0e6)`. Band: pool = keeper price. Drift: |33 − 30| = 10% of 30, passes. The range is just below spot, so the position is USDC-only; `_checkReserve` passes.
3. The wallet sells HYPE down through the range: the vault buys ≈ 30,400 HYPE at ≈ 32.9 for its 1,000,000 USDC — worth ≈ 912,000 at 30. Loss ≈ 88,000 (≈ 8.8% of the deployed amount), less ≈ 3,000 of LP fee earned.
4. `burnPosition(id, 0, 0)`; mirror the trade on the downside with the HYPE (spot to 27, HYPE-only range above spot). `swapNotionalUsed` never changes; there is no daily limit. Ten half-cycles leave roughly 40% of NAV.

A stolen-EOA keeper runs these as back-to-back transactions; arbitrage between them is an execution risk for the attacker, not a bound.

**Recommendation.** Treat liquidity adds as swaps: charge the notional not already in the pool-price ratio to `_useTurnover`; require the range to contain the keeper price (or enforce a minimum width); compute the position's token mix at `sqrtPrice(keeperPrice)` and require the amounts actually paid to match within `maxSlippageBps`; use a much tighter band for adds than for settlement. Fix the anchor (H-2), otherwise `keeperPrice` is not a reference at all.

---

## Medium

### M-1 — An unhedged vault (`hedgeTreasury == 0`) still accepts keeper-reported hedge equity

**Severity:** Medium · **Confidence:** 95 · **Origin:** [both] (phase 1: erc4626, oracles, general; phase 2: agents 1, 2, 5, 11)
**Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:379-380`), `_checkHedgeEquity` (`:481-499`); compare `:528` and `:601`; `script/Deploy.s.sol:50`

```solidity
379        _checkHedgeEquity(r.hedgeEquity);
380        hedgeEquity = r.hedgeEquity;
...
528        if (hedgeTreasury == address(0)) revert NoHedge();                       // sendHedgeMargin
601        if (hedgeTreasury == address(0) && p.hedgeCapBps != 0) revert BadParam(); // _setParams
```

**Description.** `sendHedgeMargin` and `_setParams` both special-case the unhedged strategy, but `settle` and `_checkHedgeEquity` never branch on `hedgeTreasury`, and `grossAssets` always adds `hedgeEquity` (`:266`). `Deploy.s.sol:50` sets `hedgeStepBps: 500` for the "Growth (unhedged)" configuration too. On a vault that by construction has no off-chain account, the keeper can report 5% of `lastNav` per window of phantom equity (more with H-1), compounding because `lastNav` then includes it. `returnHedgeMargin` cannot reconcile it (`safeTransferFrom(address(0), …)` reverts). The accepted risk presumes a real Hyperliquid account for the guardian bot to compare against; here the correct value is always 0 and is enforceable on-chain.

**Proof of concept.** Unhedged vault, `lastNav` = 1,000,000. `settle({hedgeEquity: 50,000e6, …})`: `50,000 × 1e4 ≤ 1,000,000 × 500` passes. NAV is overstated 5%; the fee recipient is minted 15% of 50,000; a queued accomplice redeems at +4.25%. Day 2 allows +52,500, and so on.

**Recommendation.**
```diff
         if (r.epoch != epoch) revert BadEpoch();
+        if (hedgeTreasury == address(0) && r.hedgeEquity != 0) revert NoHedge();
```
Also require `hedgeStepBps == 0` in `_setParams` when there is no treasury.

---

### M-2 — The guardian's hedge approval is an absolute value, not bound to the baseline it was judged against, and never expires within the epoch

**Severity:** Medium · **Confidence:** 80 · **Origin:** [both] (phase 1: oracles, general; phase 2: agents 10, 11; agents 2, 5 as leads)
**Location:** `LPVaultBase._checkHedgeEquity` (`src/LPVaultBase.sol:494-497`), `approveHedgeEquity` (`:564-569`), `sendHedgeMargin` (`:527-537`), `returnHedgeMargin` (`:541-550`)

```solidity
494        if (approvedHedgeEpoch == epoch + 1 && approvedHedgeEquity == v) {
495            approvedHedgeEpoch = 0;
496            return;
```

**Description.** The approval binds the new value and the epoch, not the stored `hedgeEquity` it describes. `sendHedgeMargin` and `returnHedgeMargin` change both the real off-chain equity and the stored baseline in the same epoch without clearing the approval or consuming `hedgeDriftUsed`. A keeper holding a pending approval can therefore move real margin and then settle with the now-stale approved number; the mis-statement equals the margin moved, not `hedgeStepBps`. There is also no time expiry: the approval stays usable until the keeper chooses to settle that epoch (up to 72 h). Reuse across epochs is not possible (`epoch++` at `:394` invalidates it).

**Proof of concept** (send variant — no treasury allowance needed). `lastNav` 1,000,000; cap 350,000; stored equity 100,000; real equity 200,000 after a gain. Guardian `approveHedgeEquity(200,000e6)`. Keeper `sendHedgeMargin(250,000e6)` → stored 350,000, real 450,000. Keeper `settle({hedgeEquity: 200,000e6})`: the diff of 150,000 exceeds the budget, the approval matches, it passes. NAV is understated by 250,000 (25%); an accomplice's 1,000,000 deposit is minted against 750,000 and gets 57.1% of the shares instead of 50% (≈ 143,000 extra once equity is corrected). The return variant (needs a standing treasury allowance) overstates NAV by the returned amount for a redeeming accomplice and mints fee on it.

**Recommendation.** Clear the approval in both margin functions (`approvedHedgeEpoch = 0`), or approve the pair `(expectedStored, newValue)` with a `validUntil` timestamp.

---

### M-3 — The operator can make any vault operation immune to the guardian's cancel by adding a no-op self-call to the batch

**Severity:** Medium · **Confidence:** 95 · **Origin:** [both] (phase 1: governance, general, dos; phase 2: agents 2, 5, 11)
**Location:** `VaultTimelock.scheduleBatch` (`src/VaultTimelock.sol:78-83`), `cancel` (`:87`)

```solidity
78        for (uint256 i; i < targets.length; ++i) {
79            if (targets[i] == address(this)) {
80                isSelfOperation[hashOperationBatch(targets, values, payloads, predecessor, salt)] = true;
81                break;
...
87        if (isSelfOperation[id] && !hasRole(PROPOSER_ROLE, msg.sender)) revert ProposerOnlyCancel();
```

**Description.** The flag is set for the whole operation id if *any* target is the timelock, whatever that call does and whatever the other calls are. A holder of the operator key appends `updateDelay(getMinDelay())` (or an empty-calldata call to the inherited `receive()`) to a batch of vault changes and the guardian's veto is gone. Stock OpenZeppelin lets a canceller cancel everything, so this bypass is introduced by the override. `DESIGN.md` threat 13 promises "guardian can cancel" and accepts only that a rogue operator can remove the cancel right "with 48 h notice" — a two-stage path (≈ 96 h) with a veto on the first stage. The actual path is one delay (48 h, 24 h at the floor) with no veto. The guardian's instant pause does not help: the same batch can replace the vault guardian and unpause. Once the owner appoints both keeper and vault guardian, the hedge gate is self-approved and NAV is arbitrary, so "owner can never move funds" (`LPVaultBase.sol:34`) does not hold against a stolen operator key.

**Proof of concept.** `scheduleBatch([vault, vault, vault, timelock], [0,0,0,0], [setKeeper(A), setGuardian(A), setPaused(false), updateDelay(48h)], 0, salt, 48h)`. Guardian `cancel(id)` → `ProposerOnlyCancel`. After 48 h `executeBatch`; A calls `approveHedgeEquity(V)` then `settle({hedgeEquity: V})` for any V and redeems an accomplice against it.

**Recommendation.** Flag an operation only when *every* target is the timelock, or revert batches that mix timelock and other targets. Do the documented guardian rotation as "role change (self-only op), then `setGuardian`".

---

### M-4 — The in-band price skew has no per-day budget and no minimum settle interval; alternating settlements harvest it without limit

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase1: erc4626, oracles] — re-examined against `settle`, confirmed
**Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:376-395`), `_checkPoolBand` (`:471-476`)

**Description.** `DESIGN.md` gave swap turnover and hedge drift per-day budgets because "settling is free", but left the price band per-settlement. `settle` checks only `r.epoch == epoch` and the band, so the keeper can choose the low edge when an accomplice's deposit is processed and the high edge when its redeem is processed, every block, with no pool manipulation. The accepted risk (threat 3) covers one settlement; the real exposure is that figure times an unbounded number of settlements.

**Proof of concept.** Incumbent NAV N = 1,000,000 with 50% in HYPE, band 1.5% → ε ≈ 0.75% of N. The accomplice cycles 9,000,000 USDC, which sits idle and funds its own redemptions. Settle A at `pool / 1.015`: NAV understated ≈ 7,500, accomplice gain ≈ 6,750. Settle B at `pool / 0.985` with the redeem queued: NAV overstated ≈ 7,500, the accomplice (≈ 90% of supply) is overpaid ≈ 6,750 (less the 15% fee on the first overstated mark only — the HWM then ratchets). One round trip moves ≈ 13,500 (1.35% of N); about fifty round trips take ≈ half of incumbent NAV. At the 5% band cap the per-cycle figure is ≈ 4.5%.

**Recommendation.** Bound cumulative skew per rolling day (a budget on Σ|r.price − pool price| × base exposure), or enforce a minimum interval between settles that process queue items, or price deposits at `max(keeper, pool)` and redeems at `min(keeper, pool)` for the base leg.

---

### M-5 — `sendHedgeMargin` caps the keeper-reported equity at send time, not the margin outstanding

**Severity:** Medium · **Confidence:** 85 · **Origin:** [both] (phase 1: oracles, general; phase 2: agents 5, 11; agents 1, 2, 10 as leads)
**Location:** `LPVaultBase.sendHedgeMargin` (`src/LPVaultBase.sol:530-532`), `hedgeCap` (`:291-293`)

```solidity
530        uint256 after_ = hedgeEquity + amount;
531        uint256 cap = hedgeCap();
532        if (after_ > cap) revert HedgeCap(after_, cap);
```

**Description.** The NatSpec (`:526`) says "total outstanding margin <= hedgeCapBps of last NAV" and `DESIGN.md` threat 1 says "up to `hedgeCapBps` (35%) of NAV is under operator custody". The code compares `hedgeEquity` — the keeper's last report — plus the new amount, only at send time; no counter tracks USDC actually sent. Reporting equity down inside the drift budget frees headroom and the next send refills it, so cumulative custody is unbounded. The cap is also not re-checked when redemptions shrink NAV, and its base (`lastNav`) is inflatable as in H-1. The treasury is the operator's account, so this is custody concentration beyond the documented limit rather than theft by a keeper-key thief; the low reports also understate NAV for a depositing accomplice.

**Proof of concept.** NAV 1,000,000, 350,000 sent (stored 350,000). Each day: `settle` with `hedgeEquity − 50,000` (within budget), then `sendHedgeMargin(≈ 32,500–48,000)`. After ten days several hundred thousand more real USDC is at the treasury while reported equity is still ≈ 35%. Second path: with `lastNav` inflated by a 19 N deposit, the cap is 7 N and the keeper can send all of the incumbents' on-chain USDC before the depositor redeems.

**Recommendation.** Track `netMargin` (sent minus returned, floored at 0) and apply the cap to `max(hedgeEquity, netMargin) + amount`. Optionally re-check in `settle` and block further sends while over the cap.

---

### M-6 — A pause does not stop the settlement path: fake equity, band-skewed prices, fee mints and redemptions all still go through, and the guardian has no faster lever

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase1: governance/access-control] — re-examined, confirmed
**Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:376-388`), `setPaused` (`:553-561`), `setKeeper` (`:572`)

**Description.** `settle` is deliberately not `whenNotPaused` so exits are never blocked. But while paused it still accepts a new `hedgeEquity` (`:379-380`), mints performance-fee shares (`:384`) and prices and pays redemptions (`:388`). `DESIGN.md` bounds keeper extraction "until the guardian pauses" (threat 2) and tells the guardian bot to "monitor HL equity" (threat 4), but the guardian's only instant action does not cover the NAV inputs. The only stop is `setKeeper`, which is owner-only and so takes ≥ 48 h (24 h at the floor) and which the guardian cannot schedule. `emergencyUnwind` is unavailable because the hostile keeper keeps settling. The redeem legs of H-1, H-2, M-1 and M-4 therefore survive a pause.

**Proof of concept.** Keeper key stolen; an accomplice holds 50% of shares; NAV 1,000,000. Guardian pauses at t0; the operator schedules `setKeeper` for t0 + 48 h. The keeper settles at t0, t0 + 24 h and just before t0 + 48 h, each with `hedgeEquity += 50,000` (in budget). Reported NAV is 1,150,000; the accomplice's redeems are paid at ≈ ×1.15, an excess of ≈ 75,000 taken from the other holders, and the fee recipient is minted 15% of the fake gain.

**Recommendation.** Give the guardian an instant, non-fund-moving stop on NAV-changing inputs: while paused require `r.hedgeEquity == hedgeEquity` unless guardian-approved and skip `_accrueFee`; or add a guardian "freeze keeper" flag that blocks `settle` and lets the 72 h clock run.

---

### M-7 — One redeem larger than idle USDC at the head of the queue blocks every later redeem, while `settle` keeps resetting the liveness timer

**Severity:** Medium · **Confidence:** 90 · **Origin:** [both] (phase 1: dos, erc4626; phase 2: agent 11 as lead)
**Location:** `LPVaultBase._processRedeems` (`src/LPVaultBase.sol:452`), `requestRedeem` (`:341-348`), `cancelRedeem` (`:351-352`)

```solidity
452            if (a > idle) break; // FIFO: wait for the keeper to free liquidity
```

**Description.** Redeems are strictly FIFO and all-or-nothing per request. Any head request above idle USDC stops the loop, so every smaller, payable request behind it waits. There is no maximum request size, no partial fill, no skip, and no cancel outside emergency (shares in the queue are locked). `settle` succeeds with zero progress and writes `lastSettleTime` (`:392`), so `emergencyUnwind` never arms. The accepted risk says that, while paused, "redemptions larger than idle USDC + USDC freed from LP wait"; the real exposure is that *every* redemption behind such a request waits, and any holder whose position exceeds the idle buffer can create the state deliberately. Outside a pause the keeper must unwind LP / swap / pull hedge margin to clear the head, so a holder can also force repeated unwinds.

**Proof of concept.** NAV 1,000,000; idle USDC 80,000 (the recommended buffer). A 10% holder calls `requestRedeem` (≈ 100,000) and becomes the head. Twenty later requests of 1,000 each sit behind it. At settle `100,000 > 80,000` → `break`; nothing is paid although 20,000 was payable. If the guardian has paused (`swap` blocked) and the LP is out of range on the HYPE side, no USDC can be freed until an unpause (≥ 24–48 h via the timelock).

**Recommendation.** Partially fill the head with available idle and leave the remainder queued, or skip an unfillable head with a bounded look-ahead and retry it first each settle. Consider allowing `cancelRedeem` while paused.

---

### M-8 — `emergencyRedeem` pays out while LP positions are still open, and the caller of `emergencyUnwind` can likely induce that state by under-supplying gas

**Severity:** Medium · **Confidence:** 55 (gas window not measured — nothing was executed) · **Origin:** [phase1: dos, erc4626, general] — re-examined, structure confirmed
**Location:** `UniV4LPVault._unwindAll` (`src/UniV4LPVault.sol:245-250`), `LPVaultBase.emergencyUnwind` (`src/LPVaultBase.sol:619-622`), `emergencyRedeem` (`:626-651`)

```solidity
245            try positionManager.modifyLiquidities(abi.encode(_burnActions(), _burnParams(id, 0, 0)), block.timestamp) {
246                _removeAt(i);
247                emit PositionBurned(id);
248            } catch (bytes memory reason) {
249                emit PositionUnwindFailed(id, reason);
250            }
```

**Description.** `emergencyUnwind` is permissionless, sets `emergency = true` before `_unwindAll`, and `_unwindAll` swallows every burn failure. `emergencyRedeem` has no `_positionCount() == 0` condition and pays pro-rata of idle balances only, so anyone who redeems before the positions are unwound burns shares for a payout that excludes the LP — that value accrues to whoever waits. `DESIGN.md` threat 16 accepts a position that "never unwinds"; it does not cover a failure the caller induces on a position that unwinds fine on the next call. The external call receives 63/64 of the remaining gas, so a caller can choose a gas limit at which the last burn in the loop (index 0) runs out of gas while the retained 1/64 covers the `catch`, one event and function exit. The transaction succeeds with `emergency = true` and a position still open. Whether the retained gas is enough depends on the burn's real cost (plausible for a ~200k+ burn, tight below that); this was not measured.

**Proof of concept.** Vault: one position worth 700k, idle 100k USDC; attacker holds 10% of supply; no settle for > 72 h. The attacker calls `emergencyUnwind()` with gas tuned so the burn fails. Holders with 50% of supply react to the `EmergencyUnwind` event, call `emergencyRedeem`, and receive 50k in total, forfeiting their 350k share of the LP. The attacker re-calls `emergencyUnwind()` with normal gas; its 10% is now 20% of the remaining supply: 150k instead of 80k. Even without the gas trick, the same loss occurs whenever a burn fails for any reason on the first call.

**Recommendation.** In `_unwindAll`, revert (do not catch) when the callee ran out of gas, e.g. `if (gasleft() < g / 32) revert UnwindOutOfGas();` in the catch block with `g` sampled before the `try`. In `emergencyRedeem`, revert while `_positionCount() != 0` unless a grace period has elapsed or the caller passes an explicit `acceptPartial` flag.

---

### M-9 — The hedge-drift budget sums absolute moves, so honest frequent settlement exhausts it; the keeper must then stall or report a known-stale NAV

**Severity:** Medium · **Confidence:** 75 · **Origin:** [phase1: dos, erc4626, oracles] — re-examined, confirmed
**Location:** `LPVaultBase._checkHedgeEquity` (`src/LPVaultBase.sol:483-498`)

```solidity
483        uint256 diff = v > old ? v - old : old - v;
...
489        uint256 used = hedgeDriftUsed + diff;
```

**Description.** The budget is path length, not net move: +3% then −3% in one window exhausts it with zero net change. The README prescribes hourly settlement, and a mark-to-market short worth a large fraction of NAV oscillates. Once the budget is gone, an honest report reverts the whole `settle` — including the redeem pass — unless the guardian approves the exact integer for that epoch. The alternatives are to re-report the stale value (`diff == 0`), which misprices NAV for that settlement's deposits, redeems and fee by a publicly computable amount (Hyperliquid equity, `hedgeDriftUsed` and `lastNav` are all public, and `cancelDeposit` gives depositors a free option until the settle), or to stall — and after 72 h anyone can start the permanent wind-down. The base also shrinks after large redemptions while hedge equity does not, tightening the budget exactly when exits are in progress.

**Proof of concept.** NAV 1,000,000; budget 50,000/day; hedge notional ≈ 500,000; hourly settles. Hourly HYPE moves of ±1% change equity by ≈ ±5,000. After ten settles `hedgeDriftUsed` = 50,000 with net change ≈ 0; the eleventh honest settle reverts `HedgeEquityJump`. A single 12% daily move (60,000) breaches the budget on its own; if the keeper clips the report, a third-party deposit processed in that settle is minted ≈ 5–10% cheap.

**Recommendation.** Bound the *net* move in the window (store the equity at window start, adjust it for sends/returns, require `|v − anchor| ≤ budget`) — that still prevents compounding. Let the guardian approve a range with a deadline. Skip deposit processing whenever the report was clipped, and never let the check block a redeem-only settle.

---

### M-10 — The per-swap loss bound is `refDriftBps + poolBandBps + maxSlippageBps`, not "band + slippage" as documented

**Severity:** Medium · **Confidence:** 85 · **Origin:** [both] (phase 1: defi-amm, oracles; phase 2: agent 1)
**Location:** `UniV4LPVault.swap` (`src/UniV4LPVault.sol:267-270`), `LPVaultBase._checkKeeperPrice` (`src/LPVaultBase.sol:502-508`)

```solidity
504        uint256 ref = lastPrice;
505        if (ref == 0) return; // before the first settlement there is no NAV to protect
506        uint256 diff = price > ref ? price - ref : ref - price;
507        if (diff * BPS > ref * params.refDriftBps) revert BadPrice();
```

**Description.** `minOut` is fair value at `keeperPrice` minus `maxSlippageBps`, and `keeperPrice` only has to be within 1.5% of spot and within 10% of `lastPrice`. With spot 10% away from the last settled price, the swap passes while executing ≈ 10% off fair value. `DESIGN.md` threat 2 states "up to ~(band + slippage) per swap, bounded by turnover: worst case a few % of NAV per day" — 2.5% × 2 × NAV = 5%/day at defaults. The coded bound is ≈ 10–12.5% of notional, i.e. up to ≈ 20–25% of NAV per day at 2× turnover (and doubled at a window edge, L-1); at the hard caps (drift 30%, band 5%, slippage 5%) one swap can lose ≈ 35–40%. This holds without H-2; with H-2 there is no bound per unit of notional.

**Proof of concept.** `lastPrice` = 30e6, spot moved to 33e6. `swap(false, U, 33e6)`: band diff 0; `3e6 × 1e4 = 3e10` is not `> 30e6 × 1000 = 3e10`, passes. `minOut = U / 33 × 0.99`: the vault receives HYPE worth ≈ 90% of U at the old price — a 10% loss per unit of notional, with the keeper's wallet as counterparty.

**Recommendation.** Reduce the default and cap of `refDriftBps` to the order of the band or make it time-scaled; compute `fair` from the price nearer to the reference; correct `DESIGN.md` threat 2; fix H-2 so the reference is trustworthy.

---

## Low

### L-1 — The "rolling-day" windows for hedge drift and swap turnover are fixed windows anchored at first use: twice the budget fits in one second
**Severity:** Low · **Confidence:** 95 · **Origin:** [both] (phase 1: precision-math, general, oracles; phase 2: agents 1, 2, 5, 10, 11)
**Location:** `src/LPVaultBase.sol:485-488` (`_checkHedgeEquity`), `:519-520` (`_useTurnover`)
```solidity
485        if (block.timestamp >= hedgeDriftStart + 1 days) {
486            hedgeDriftStart = block.timestamp;
487            hedgeDriftUsed = 0;
...
519        if (block.timestamp < swapWindowStart + 1 days) used += swapNotionalUsed;
520        else swapWindowStart = block.timestamp;
```
The NatSpec (`:478-479`, `:515-516`) and `DESIGN.md` say "per rolling day". A keeper anchors a window with a 1-wei use at T0, spends the full budget at T0 + 86,399 s and the full budget again at T0 + 86,400 s: 10.25% of NAV of fake equity (the second step is against the already-inflated `lastNav`), or 4× NAV of swap notional, inside two blocks. The long-run average is unchanged, which is why this is Low on its own; it doubles H-1 and M-10. **Fix:** a decaying budget, `used = used × (1 days − elapsed) / 1 days + new`, for both.

### L-2 — The 72 h liveness clock starts at construction and has no price gate before the first settle
**Severity:** Low · **Confidence:** 95 · **Origin:** [both] (phase 1: dos, erc4626, general; phase 2: agent 2; agents 5, 10 as leads)
**Location:** `src/LPVaultBase.sol:208`, `:613-614`
```solidity
208        lastSettleTime = block.timestamp;
...
613            if (block.timestamp <= lastSettleTime + SETTLE_TIMEOUT) revert TooEarly();
614            if (block.timestamp <= lastSettleTime + EMERGENCY_FORCE_DELAY && lastPrice != 0) {
```
If the first `settle` does not land within 72 h of deployment — or in any later quiet 72 h — any address can call `emergencyUnwind()` and set `emergency = true` forever (the band is skipped while `lastPrice == 0`). No funds are lost (`cancelDeposit` works), but the deployment, timelock wiring and published address are dead. **Fix:** `if (epoch == 0 || block.timestamp <= lastSettleTime + SETTLE_TIMEOUT) revert TooEarly();` and document the mandatory ≤ 72 h heartbeat settle.

### L-3 — Between 72 h and 7 d the wind-down is blocked whenever the market moved more than 10% since the last settle
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: dos, oracles, general] — confirmed
**Location:** `src/LPVaultBase.sol:614-618`
The band compares the pool with `lastPrice`, which is ≥ 72 h old by construction; a > 10% move over three days is routine for HYPE and most likely exactly when a keeper fails. The advertised 72 h exit then becomes 7 days with LP and hedge unmanaged. The band also buys little: removing liquidity at a pushed price costs the pusher, and the exit is in kind. A keeper about to go dark can poison the reference with an empty settle at a displaced spot (H-2). `DESIGN.md` threat 7 covers manipulation after 7 d, not this extension. **Fix:** drop the band, or replace it with a short-horizon check on the pool itself (two-step: record the pool price, execute ≥ N minutes later within X% of the recorded price).

### L-4 — The 72 h timer counts sequencer downtime as keeper absence, and the band is vacuous on resume
**Severity:** Low · **Confidence:** 70 (Elysium's force-inclusion settings were not verified) · **Origin:** [phase1: dos/chain-specific, oracles] — confirmed structurally
**Location:** `src/LPVaultBase.sol:613-618`, `:471-476`
`block.timestamp` jumps across an Orbit sequencer outage. After a ≥ 72 h gap the pool has not traded, so it trivially sits within 10% of `lastPrice`, while an honest `settle` needs the true price within 1.5% of that stale pool price and may revert. The first transaction after resume (or a force-included one) can be `emergencyUnwind()` and the healthy vault is wound down permanently. **Fix:** require evidence of chain liveness in the window (e.g. a two-step announce/execute that any successful settle cancels), or a grace period after a timestamp gap.

### L-5 — `claim()` and `cancelDeposit()` pay only `msg.sender`, so a blocked recipient's USDC is stranded
**Severity:** Low · **Confidence:** 95 · **Origin:** [phase1: erc20, dos] — confirmed
**Location:** `src/LPVaultBase.sol:369` (`claim`), `:335` (`cancelDeposit`), `:460-463`
```solidity
369        asset.safeTransfer(msg.sender, a);
```
`claimable` is credited when the settlement push fails; the realistic cause is a USDC blacklist, and for that address `claim()` reverts for the same reason. The shares are already burnt, so the USDC stays reserved indefinitely. README:32 presents `claim()` as the remedy for "a blocked address" and `DESIGN.md` threat 10 lists the residual as "none". In emergency (no `settle`) a blacklisted depositor's queued USDC is equally stuck. No other user is harmed. **Fix:** `claim(address to)` and `cancelDeposit(uint256 id, address to)` with `to != address(0) && to != address(this)`.

### L-6 — `emergencyRedeem` is all-or-nothing across USDC, WHYPE and native
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: erc20, dos] — confirmed
**Location:** `src/LPVaultBase.sol:640-649`
```solidity
640        if (aOut != 0) asset.safeTransfer(to, aOut);
641        if (wOut != 0) IERC20(wrappedBase).safeTransfer(to, wOut);
...
644                (bool ok,) = to.call{value: bOut}("");
645                if (!ok) revert TransferFailed();
```
Settlement tolerates a USDC failure (`trySafeTransfer` → `claimable`); the last-resort exit does not. While bridged USDC is paused or the vault is blacklisted, no holder can withdraw the native HYPE either, though that leg would succeed. Nothing is lost (the burn reverts too). **Fix:** make the asset leg non-blocking by crediting `claimable[to]` on failure, or let the caller choose legs.

### L-7 — Shares held by the vault outside the redeem queue are unrecoverable and strand a pro-rata slice; the constructor omits the setter's `feeRecipient != address(this)` check
**Severity:** Low · **Confidence:** 95 · **Origin:** [both] (phase 1: erc20, erc4626, general; phase 2: agents 2, 5 as leads)
**Location:** `src/LPVaultBase.sol:631-632`, `:196`, `:585`
```solidity
631        uint256 supply = totalSupply();
632        uint256 aOut = Math.mulDiv(idleAsset(), shares, supply);
```
The share token accepts `transfer(address(vault), x)`; such shares are not in `lockedShares` (which is written but never read), belong to no request, and can never be burned, yet they count in every denominator (`:450`, `:631`). In wind-down their slice of USDC, HYPE and WHYPE stays in the vault forever. Ways in: user error, or a deployment with `feeRecipient == address(this)` — the constructor (`:196`) checks only the zero address while `setFeeRecipient` (`:585`) also rejects the vault. **Fix:** reject non-queue share transfers to the vault in `_update`, or use `totalSupply() − (balanceOf(address(this)) − lockedShares)` as the denominator; mirror the setter check in the constructor.

### L-8 — A deposit that converts to zero shares is still consumed; dust redeems burn shares for nothing
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] (phase 1: precision-math, erc4626; phase 2: agent 1 as lead)
**Location:** `src/LPVaultBase.sol:427-434`, `:450-460`, `:599`
```solidity
427            uint256 sh = Math.mulDiv(a, supply + VIRTUAL_SHARES, nav + 1);
428            d.assets = 0;
429            pendingDepositAssets -= a;
430            nav += a;
431            if (sh != 0) {
```
When `a × (supply + 1e6) < nav + 1` the depositor's USDC moves into NAV with no mint; more generally the loss is up to one share unit, `(nav+1)/(supply+1e6)`, with no floor relative to `a`. This needs ≈ 1,000,000 USDC sitting at zero supply per 1 USDC deposited (a late hedge return after a full exit, or a donation), so it is a latent/griefing issue, not a profitable attack — but `DESIGN.md`'s "at most one share unit" does not say one unit can exceed the whole deposit (with a 1M leftover, a 1.99 USDC deposit loses ≈ 50%). `minDeposit` has no lower bound. **Fix:** when `sh == 0`, credit `claimable[d.owner] += a` instead of adding to `nav`; require `shares ≥ 1e6` in `requestRedeem`; enforce `minDeposit > 0`.

### L-9 — The timelock delay (48 h default, 24 h floor) is shorter than the only trustless exit (72 h without a settle)
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: governance, dos/chain-specific] — confirmed
**Location:** `src/VaultTimelock.sol:21`, `:52`; `src/LPVaultBase.sol:62`, `:613`
The delay exists so holders can leave before a change lands, but shares are burnt only in keeper-only `settle`, and `emergencyRedeem` needs 72 h without one; a keeper that settles with `maxRedeems = 0` keeps the gate shut. When operator and keeper are compromised together, the notice period guarantees no exit. On an Orbit chain a 24 h floor also equals a typical force-inclusion delay, so a censored guardian's `cancel` races the `execute`. **Fix:** raise `MIN_DELAY_FLOOR` to ≥ `SETTLE_TIMEOUT`, or make the liveness clock measure redemption progress.

### L-10 — Scheduled operations never expire, so ready operations can be stockpiled as instant levers
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: governance] — confirmed against OpenZeppelin 5.4 `TimelockController` (no grace period)
**Location:** `src/VaultTimelock.sol:57-84`
A Ready operation stays executable forever. An operator-key holder can pre-schedule `setPaused(false)` (ten salts), `setKeeper(X)` or cap-level `setParams` and fire them at will later — with M-3, uncancellable. This weakens the claim that "an owner-key thief cannot lift a guardian pause instantly". **Fix:** revert in `execute`/`executeBatch` when `block.timestamp > readyAt + GRACE` (e.g. 7 days).

### L-11 — `updateDelay` has no upper bound; an oversized delay bricks the timelock and vault ownership permanently
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: governance] — confirmed
**Location:** `src/VaultTimelock.sol:50-55`
```solidity
52        if (newDelay < MIN_DELAY_FLOOR) revert DelayBelowFloor();
```
Only the floor is checked and there is no external admin. A unit mistake (`172_800_000`, milliseconds for seconds) makes every later operation — including the correcting `updateDelay` — wait ≈ 5.5 years; a huge value makes every `schedule` overflow. The guardian cannot cancel it (self-operation). **Fix:** `if (newDelay > 30 days) revert DelayAboveCap();`, in the constructor too.

### L-12 — `renounceOwnership` is not disabled, and a pending owner never expires
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: governance] — confirmed (`LPVaultBase` inherits `Ownable2Step` with no override)
After a timelocked `renounceOwnership()`, `setPaused(false)`, `setKeeper`, `setGuardian` and `setParams` are dead: a paused vault stays paused and a hostile keeper can no longer be rotated. `transferOwnership(X)` leaves a pending owner with no deadline; if X is not a timelock, every owner action becomes instant on acceptance. **Fix:** override `renounceOwnership` to revert; consider requiring the new owner to expose `getMinDelay() >= 24 hours`.

### L-13 — The vault guardian and the timelock canceller are independent slots; `Deploy.s.sol` does not validate a reused timelock, role distinctness or the chain id
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] (phase 1: governance, general, dos; phase 2: agent 2 as lead)
**Location:** `src/LPVaultBase.sol:578-582`; `src/VaultTimelock.sol:37`; `script/Deploy.s.sol:27-33`, `:39-41`, `:20-24`
`vault.guardian` (pause, hedge co-sign) and the timelock `CANCELLER_ROLE` are set separately; `setGuardian` does not touch the role, so a rotation that forgets the role change leaves the old guardian with the veto and the new one without. With `TIMELOCK` set, the script uses the address as owner unchecked (it may be an EOA, a zero-delay timelock, or another vault's timelock whose canceller is a different guardian), reads `OWNER` and ignores it, and never checks `hasRole(CANCELLER_ROLE, guardian)`. The constructors accept `keeper == guardian` (hedge co-sign self-approved, one key controls NAV) and `operator == guardian`. The script's five hard-coded addresses are used with no `block.chainid == 99901` check. **Fix:** on reuse, require code, `getMinDelay() >= 24 h`, `hasRole(PROPOSER_ROLE, owner)` and `hasRole(CANCELLER_ROLE, guardian)`; require pairwise-distinct operator/guardian/keeper; add the chain-id check.

### L-14 — `uint16(vm.envUint("HEDGE_CAP_BPS"))` truncates silently
**Severity:** Low · **Confidence:** 95 · **Origin:** [both] (phase 1: governance, precision-math, general; phase 2: agents 1, 2, 10 as leads)
**Location:** `script/Deploy.s.sol:47`
```solidity
47                hedgeCapBps: uint16(vm.envUint("HEDGE_CAP_BPS")),
```
The cast wraps mod 65,536 before `_setParams` validates `≤ 5000`. `HEDGE_CAP_BPS=70000` deploys a 44.64% cap with no error; `65536` deploys a hedged vault with cap 0. **Fix:** read into `uint256`, `require(cap <= 5000)`, then cast.

### L-15 — `swap` has no caller-supplied `minOut` or deadline
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase1: defi-amm] — confirmed
**Location:** `src/UniV4LPVault.sol:258-278` (`minOut` at `:270`, price limit at `:294`), deadline `block.timestamp` at `:235`
`minOut` derives only from the global `maxSlippageBps` (1% default, 5% cap). An honest keeper cannot ask for tighter execution except by skewing `keeperPrice` (which distorts the turnover notional); a party ordering around the keeper's transaction can take the gap; and a delayed keeper transaction executes whenever the band happens to hold. Conversely the fixed 1% includes the 0.3% fee, so a redemption-funding sell with > ≈ 0.7% impact reverts and must be split by hand. **Fix:** add `minOut` and `deadline` parameters (`out >= max(minOut, policyMinOut)`), and a deadline on mint/increase.

### L-16 — A guardian pause freezes hedge top-ups and all swaps for at least the timelock delay; `DESIGN.md` says it "stops new deposits only"
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: governance/access-control] — confirmed
**Location:** `src/LPVaultBase.sol:527` (`sendHedgeMargin … whenNotPaused`), `:553-558`; `src/UniV4LPVault.sol:262`
Pausing is instant for the guardian; unpausing needs the timelock (≥ 48 h). During that time the keeper cannot add margin to the off-chain short (liquidation risk in a fast market), swap, mint or increase. A rogue guardian that also holds CANCELLER can cancel a plain unpause repeatedly; recovery needs one batch with `setGuardian`, `setPaused(false)` and the role change. **Fix:** allow `sendHedgeMargin` within the cap while paused (or a guardian-approved top-up); correct threat 12.

### L-17 — `wrappedBase` is not validated at construction
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: dos/chain-specific, general, erc20] — confirmed
**Location:** `src/LPVaultBase.sol:195-200`, `:252`
The constructor checks code for `asset`, PoolManager, PositionManager and Permit2 but not `wrappedBase`. If WHYPE has no code at the configured address, `IERC20(wrappedBase).balanceOf` reverts in `idleBase()` and `emergencyRedeem`, so `settle` and the emergency exit revert forever (only `cancelDeposit` works). A wrong but live token is silently counted 1:1 as base; a token that mirrored the native balance would double-count the base leg. **Fix:** `if (c.wrappedBase != address(0) && c.wrappedBase.code.length == 0) revert BadParam();` and assert `decimals() == 18` and a 1:1 deposit/withdraw round trip in the deploy script or a fork test.

---

## Informational

### I-1 — Documentation mismatches on the high-water mark and the hedge-step wording
**Severity:** Informational · **Confidence:** 95 · **Origin:** [both] (phase 1: precision-math, general; phase 2: agent 1 as lead)
**Location:** `src/LPVaultBase.sol:404-407`, `:415-416`, `:28-29`, `:32`
```solidity
404        if (supply == 0) {
405            highWaterMark = pps; // nobody to charge; restart the mark
406            return 0;
```
The `supply == 0` branch assigns the HWM without a max, so "The HWM never decreases" (`:32`, README) is true only while supply > 0; no holder is harmed (nobody is left who paid toward the old mark). When `feeAssets` floors to 0, `:416` still raises the HWM, so that sub-unit gain is never charged (≤ 1 raw unit per settlement). The header at `:28-29` says hedge equity may move `hedgeStepBps` "per settlement"; the code uses a per-window budget.

### I-2 — Native `settle` in `unlockCallback` is not preceded by `sync(address(0))`
**Severity:** Informational · **Confidence:** 80 · **Origin:** [phase1: defi-amm] — confirmed against vendored v4-core `PoolManager._settle`
**Location:** `src/UniV4LPVault.sol:305-306`
```solidity
305        if (cIn == address(0)) {
306            poolManager.settle{value: pay}();
```
`PoolManager._settle` treats the payment as native only if the transient synced currency is zero and otherwise reverts `NonzeroNativeValue`; `sync` is callable by anyone and the slot persists for the transaction. If the keeper call is ever bundled after something that leaves an ERC-20 synced, every sell-base swap reverts. No fund risk. The periphery's own `DeltaResolver` always syncs first. **Fix:** `poolManager.sync(Currency.wrap(address(0)));` before the native settle.

### I-3 — Token properties assumed by the code and script are not asserted; floating pragma
**Severity:** Informational · **Confidence:** 80 · **Origin:** [phase1: erc20, general]
**Location:** `script/Deploy.s.sol:20-21`, `:53`; `src/LPVaultBase.sol:202`, `:250-253`
`minDeposit: 1e6` and the documented 12-decimal shares assume 6-decimal USDC (the vault itself reads `decimals()`); `requestDepositWithPermit` assumes EIP-2612 (a missing permit is swallowed safely); `idleBase()` assumes WHYPE is a WETH9-style 18-decimal wrapper with its own ledger. The deployed bytecode at the hard-coded addresses could not be inspected. Sources use `pragma ^0.8.26` while `foundry.toml` pins 0.8.26. **Fix:** assert these in the deploy script or a fork test.

### I-4 — EIP-170 headroom is ≈ 0.5 KB
**Severity:** Informational · **Confidence:** 70 (not measured — building was disabled) · **Origin:** [phase1: dos/chain-specific]
**Location:** README.md:150
The README states the vault is "~24.0 KB (EIP-170 limit 24.576 KB, optimizer runs = 1, via-IR)". Several fixes recommended here add code and will not fit without moving logic into the linked library. Orbit's `MaxCodeSize` is chain-configurable; confirm it for Elysium and add a CI size check.

---

## Leads (not confirmed as findings)

- **Late hedge-margin return timing in wind-down** — `LPVaultBase.emergencyRedeem` / `returnHedgeMargin`. The operator chooses when margin returns, and it accrues to shares still outstanding — which include the fee recipient's. `DESIGN.md` accepts that early redeemers forgo unreturned margin; no path beyond that accepted risk was proven. [phase2: agent 11]
- **Turnover budget scales with a transient deposit** — `LPVaultBase._useTurnover` (`:521`). Same base problem as H-1; the accomplice shares the real swap loss pro-rata, so no amplification was shown beyond M-10. [phase2: agent 11]
- **Code-executing keeper inside `PoolManager.unlock`** — if the keeper address can execute code (a contract keeper, or an EIP-7702-delegated EOA where supported), the spot displacement in H-2 can be done with zero capital in one transaction wrapping `vault.settle`. Not verified for Elysium. [phase1: oracles]

---

## Access-Control Inventory

30 declared state-changing entry points (LPVaultBase 18, UniV4LPVault 7, VaultTimelock 4, Deploy 1), reconciled against the grep-verified x-ray list. `NR` = transient `nonReentrant`.

| Function | Guard | Caller | Moves value | Coverage |
|---|---|---|---|---|
| `receive` | none | anyone | native in | examined, no issue (donation accrues to holders) |
| `requestDeposit` / `requestDepositWithPermit` | NR; not paused, not emergency; permit in try/catch | anyone | USDC in | examined, no issue; L-8 (zero-share outcome) |
| `cancelDeposit` | NR; request owner | request owner | USDC out | L-5 |
| `requestRedeem` | NR; not emergency | holder | shares → vault | M-7, L-8 |
| `cancelRedeem` | NR; emergency only; request owner | request owner | shares back | M-7 (no cancel outside emergency) |
| `claim` | NR | creditor | USDC out | L-5 |
| `settle` | NR; keeper; not emergency; epoch, band, hedge checks | keeper | USDC → redeemers; mint/burn | H-1, H-2, M-1, M-2, M-4, M-6, M-7, M-9 |
| `sendHedgeMargin` | NR; keeper; not paused; not emergency; cap; reserve | keeper | USDC → treasury | M-5, M-2, L-16 |
| `returnHedgeMargin` | NR; keeper or treasury | keeper / treasury | USDC in | M-2 |
| `setPaused` | guardian or owner (pause); owner (unpause) | guardian / owner | — | M-6, L-16 |
| `approveHedgeEquity` | guardian | guardian | — | M-2 |
| `setKeeper` / `setGuardian` / `setFeeRecipient` / `setParams` | owner (timelock); hard caps | owner | — | M-3, L-13; caps examined, no issue |
| `emergencyUnwind` | NR; time gate; band until day 7 | anyone | LP → vault | M-8, L-2, L-3, L-4 |
| `emergencyRedeem` | NR; emergency only; `to` ≠ 0, ≠ vault | holder | USDC, WHYPE, native out | M-8, L-6, L-7 |
| `mintPosition` / `increasePosition` | NR; keeper; not paused; not emergency; keeper price; reserve | keeper | vault → pool | H-3 |
| `decreasePosition` / `burnPosition` | NR; keeper; not emergency | keeper | pool → vault | examined, no issue alone (removal at a pushed price costs the pusher); enables the H-3 loop |
| `swap` | NR; keeper; not paused; not emergency; price, turnover, min-out, reserve | keeper | vault ↔ pool | M-10, L-1, L-15 |
| `unwrapBase` | NR; keeper | keeper | WHYPE → native | examined in reconciliation, no issue |
| `unlockCallback` | PoolManager and `_swapping` | PoolManager | vault ↔ PoolManager | I-2; gating examined, no issue |
| `VaultTimelock.schedule` / `scheduleBatch` | PROPOSER | operator | — | M-3, L-10 |
| `VaultTimelock.cancel` | CANCELLER; PROPOSER for self-ops | operator, guardian | — | M-3 |
| `VaultTimelock.updateDelay` | self-call; ≥ 24 h | timelock | — | L-9, L-11 |
| `Deploy.run` | script broadcaster | deployer | deploys | L-13, L-14, I-3 |
| inherited: ERC20 transfer/approve/transferFrom; Ownable2Step; TimelockController execute/executeBatch/grantRole/revokeRole/renounceRole | per OpenZeppelin 5.4 | — | shares / forwards value | L-7 (share transfers to the vault), L-12 (renounce / pending owner) |

**Roles.** Owner = `VaultTimelock` (two-step transfer, one-step renounce; every call delayed ≥ `getMinDelay()`). Keeper: hot key, all functions instant; `settle`, `decreasePosition`, `burnPosition`, `returnHedgeMargin`, `unwrapBase` are not pausable. Guardian: instant pause, one hedge value per epoch; independent of the timelock CANCELLER slot. Operator: PROPOSER + EXECUTOR + CANCELLER; no external admin. `hedgeTreasury`: immutable, may be 0.

---

## Threat Model

| # | Actor → reach | Invariant that must hold | Verdict |
|---|---|---|---|
| T1 | Keeper + accomplice → settle price inside band | skew ≤ band × base share; no amplification | **violated** — M-4 (unbounded repetition), H-2 (spot not bounded) |
| T2 | Keeper + accomplice → settle hedgeEquity | drift ≤ `hedgeStepBps`/day, not compoundable | **violated** — H-1, M-1, M-2, L-1 |
| T3 | Keeper → send/return margin | outstanding margin ≤ cap over time | **violated** — M-5 |
| T4 | Keeper → swap | loss/day ≤ turnover × (band + slippage) | **violated** — M-10, L-1, H-2 |
| T5 | Keeper → mint/increase/decrease/burn | LP actions cannot exceed the swap bounds | **violated** — H-3 |
| T6 | Keeper → any path | queued deposits / unpaid claims never spent | invariant holds — `_checkReserve` after every USDC-outflow keeper path; Permit2 sub-allowance exact and reset; redeems bounded by `idleAsset()` |
| T7 | Keeper → settle maxima, timing | liveness | accepted risk (hostile keeper settling with `maxRedeems = 0`); widened by M-6, M-7 |
| T8 | Third-party pool trader | band checks bound spot influence | invariant holds against an honest keeper (settle reverts off-band; LP valuation effect is second-order); liveness side: L-3, L-4 |
| T9 | Client / third party → queues | queue progress and fair pricing for others | **violated** — M-7; L-5, L-8; spam is bounded by `max*` (accepted) |
| T10 | Donor / first depositor | virtual offset makes inflation unprofitable | invariant holds — donor loses the donation to virtual shares, victim ≤ donation / 1e6; L-8 for the zero-share edge |
| T11 | Fee recipient / owner | fee ≤ `feeBps` of real gain; HWM never lowers while supply > 0 | invariant holds for exactness; fee is minted on fake/manipulated gains (H-1, H-2, M-1); I-1 |
| T12 | Emergency participants | exact pro-rata | sequential redemption is order-independent; **violated** at the edges — M-8, L-6, L-7 |
| T13 | Anyone → emergencyUnwind timing | 72 h gate measures real keeper absence | **violated** — L-2, L-4 |
| T14 | Native recipient / token code | NR + CEI on every native path | invariant holds — all value-moving entries NR, burn before pay, native last; I-2 |
| T15 | Operator (stolen key) | every vault change waits and stays guardian-cancellable | **violated** — M-3; L-10, L-11 |
| T16 | Guardian (stolen key) | cannot block the operator permanently | invariant holds (operator can rotate it in a self-op batch); L-16 for the ≥ 48 h freeze |
| T17 | Owner | caps hold; no instant path | caps hold; L-12 (renounce / non-timelock pending owner) |
| T18 | Deployer / config | wiring matches the trust model | **violated** — L-13, L-14, L-17 |
| T19 | Math consumer → V4PositionMath | NAV = what burn returns | invariant holds — verified against vendored StateLibrary / PositionManager |

---

## Invariant Verification

Inferred invariants from the mechanical pre-scan (`x-ray/invariants.md`), each answered.

| ID | Property | On-chain | Verdict |
|---|---|---|---|
| I-1 | `pendingDepositAssets == Σ depositRequests.assets` | Yes | holds — paired writes at `:323`, `:334`, `:429` |
| I-2 | `totalClaimable == Σ claimable` | Yes | holds — `:462-463`, `:367-368` |
| I-3 | `lockedShares == Σ redeemRequests.shares` | Yes | holds — `:344-346`, `:357-358`, `:453-454` |
| I-4 | `balanceOf(vault) == lockedShares` | No | violated → L-7 |
| I-5 | USDC balance ≥ `pendingDepositAssets + totalClaimable` after every keeper action | Yes | holds — see T6 |
| I-6 | every `params` field within its hard cap | Yes | holds — single writer `:602` behind `:595-601` |
| I-7 | `hedgeEquity ≤ lastNav × hedgeCapBps` | No | violated → M-5 |
| I-8 | summed hedge drift per rolling day ≤ `hedgeStepBps` of NAV | No | violated → H-1, L-1, M-2 |
| I-9 | swap notional per rolling day ≤ `swapTurnoverBps` of NAV | No | violated → L-1 (and H-3 for the economic intent) |
| I-10 | `highWaterMark` never decreases | No | violated at `supply == 0` only → I-1 (no impact) |
| I-11 | `emergency` is one-way | Yes | holds — single write `:619` |
| I-12 | wind-down only after 72 h without settle | Yes | holds as coded; the clock start is L-2, downtime is L-4 |
| I-13 | 72 h–7 d trigger needs pool within 10% of `lastPrice` | Yes | holds as coded; its usefulness is L-3 |
| I-14 | mint/redeem ratios on one post-fee `(nav, supply)`, floor | Yes | holds |
| I-15 | fee-share formula; fee ≤ `feeBps` of gain | Yes | holds |
| I-16 | `_positions.length ≤ 8` | Yes | holds |
| I-17 | every PositionManager/PoolManager action pays the vault | Yes | holds — recipients hard-coded |
| I-18 | `epoch` +1 per settle; report valid for one epoch | Yes | holds |
| I-19 | guardian approval usable once, in its epoch | Yes | holds (but the value is not bound to the baseline → M-2) |
| I-20 | unhedged vault carries `hedgeEquity == 0` | No | violated → M-1 |
| I-21 | timelock delay ≥ 24 h | Yes | holds (no upper bound → L-11) |
| X-1 | an operation is guardian-uncancellable only when it changes the timelock itself | No | violated → M-3 |
| X-2 | `_positions[i]` identifies a PoolManager position owned by PositionManager with salt `tokenId` | Yes | holds |
| X-3 | the reference price for keeper actions is itself bounded | No | violated → H-2 |
| X-4 | all keeper changes of the base/asset mix count against turnover | No | violated → H-3 |
| E-1 | queued deposits and unpaid claims are never in NAV nor spendable | Yes | holds |
| E-2 | keeper-induced NAV misstatement per day is bounded | No | violated → H-1, H-2, M-1, M-4 |
| E-3 | flows inside one settlement do not move pps except by floor rounding | Yes | holds |
| E-4 | keeper execution loss per day ≤ turnover × (band + slippage) | No | violated → H-3, M-10, L-1 |

---

## Suggested fix order

1. **H-2** (bound `settle` price against time-scaled drift from `lastPrice` / an independent reference) — it underlies H-3, M-10 and L-3.
2. **H-1 + M-1 + M-5 + M-2** together: introduce a `netMargin` counter, base the drift budget and cap on it, reject equity on unhedged vaults, clear approvals on margin moves.
3. **H-3**: charge adds to turnover and bind ranges/amounts to the keeper price.
4. **M-3**: one-line change to the self-operation flag.
5. **M-4, M-6, M-9**: a minimum settle interval for queue-processing settles, a guardian stop on NAV inputs, a net (not gross) drift budget.
6. **M-7, M-8**, then the Low items; several are one-line checks. Mind the EIP-170 margin (I-4).

*Prepared by an automated multi-agent pipeline. AI analysis cannot verify the complete absence of vulnerabilities; nothing here was executed against the code. A human review, a fork-based test of the High findings, and on-chain monitoring are recommended before launch.*
