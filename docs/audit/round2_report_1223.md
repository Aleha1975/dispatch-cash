# Elysium LP Vault — Security Audit (round 2)

**Job:** leftclaw.services #1223 · **Date:** 2026-11-13 · **Method:** deep-audit v3 (x-ray pre-scan → context map → checklist agents → blind attack agents → reconciliation + coverage gate)

**Repo:** https://github.com/Aleha1975/dispatch-cash · branch `elysium-lp-vault` · **commit `77bd53d3241d98c4d711e8cc82e90fa2f380b3ce`** (verified reachable on the remote as `refs/heads/elysium-lp-vault`). Not deployed — no on-chain address to pin. Target chain per the client: Elysium, chain id 99901.

**Scope (as submitted):** `src/RiskBudgets.sol`, `src/LPVaultBase.sol`, `src/UniV4LPVault.sol`, `src/V4PositionMath.sol`, `src/VaultTimelock.sol`, `script/Deploy.s.sol` (plus `src/interfaces/IExternal.sol` for context); 1,175 nSLOC. `README.md` and `DESIGN.md` were read as the specification. Dependencies (OpenZeppelin 5.4.0, v4-periphery `c6e4754`, v4-core `59d3ecf`, permit2 `cc56ad0`) were fetched at the pinned submodule commits and read where the in-scope code relies on them. Nothing was compiled or executed (audit policy: no target-code execution), so every proof is a hand trace against the source.

A round-1 audit of this code base exists (job #1222, `docs/audit/round1_report_1222.md`). This report is an independent run on the round-2 code; every finding below comes from this job's own agents.

**Severity counts:** 0 Critical · 2 High · 7 Medium · 15 Low · 8 Informational

---

## How to read this report

- The client's model treats the keeper as a semi-trusted hot key whose damage, if compromised, must stay inside the per-channel bounds in `DESIGN.md`. Both High findings and most Mediums are of that kind: they need a compromised keeper (usually with accomplice capital), and they show a documented bound that does not hold. A reader who treats the keeper as fully trusted should read them one level lower.
- No finding lets an unprivileged third party take funds from a correctly operated vault.
- Each finding carries **Severity** (cost if real) and **Confidence** (how sure we are it is real) as separate fields, plus an origin tag: `[both]` = raised independently by the checklist phase and by the blind attack phase.
- Accepted risks from `DESIGN.md` are not re-reported; where a finding touches one, it says how the exposure differs from what is stated.

### Coverage caveat — read this

The pipeline spawned every agent it is meant to spawn (3 context, 8 checklist, 12 attack), but **5 of the 20 hunting agents returned nothing** because an automated model safeguard stopped them. Per the methodology they were not respawned and their lenses were not substituted by the orchestrator.

| Phase | Lens | Status |
|---|---|---|
| 1 | general · precision-math · erc4626 · oracles · erc20+signatures · governance+access-control · dos+chain-specific | returned |
| 1 | **defi-amm + flashloans** | **did not run** |
| 2 | math-precision · access-control · periphery · first-principles · boundary · numerical-gap · trust-gap · flow-gap | returned |
| 2 | **economic-security · execution-trace · invariant · asymmetry** | **did not run** |

Mapping to the seven lenses the client asked for: **periphery (3), first principles (4), boundary (6) and flow gaps (7) ran**. **Economic security (1), execution trace (2) and asymmetry (5) did not run as dedicated lenses.** Parts of their ground were reached by the agents that did return (the 1/3/7-day budget arithmetic, the one-transaction settle sequences, up-versus-down price steps), and those results are in the findings. But there was no dedicated end-to-end "all channels at once" extraction model, no systematic multi-call trace sweep, and no systematic direction/role asymmetry sweep. Treat the absence of a finding in those areas as weaker evidence than usual, and consider re-running those three lenses.

### Reconciliation summary

`Overlap: 15 · Phase-1-only: 16 · Phase-2-only: 1 · Re-examined leads kept: 9, demoted: 0 (severity adjusted on 9) · Coverage holes closed: 0 · Invariants: 26 answered (13 hold, 13 violated, 0 unverified)`

`Completeness: 21 unique (Contract, function) in phase-2 raw, 21 covered.` Reporting floor: Informational and above.

`Coverage: 37 entrypoints, 37 addressed. 15 threat rows, 15 answered. 26 inferred invariants, 26 answered. Holes closed this pass: 0.`

---

## Answers to the client's questions

| # | Question | Short answer | Findings |
|---|---|---|---|
| 1 | Are H-1..H-3 and M-1..M-10 fixed at the root? | Six are fixed at the root (H-1 in the PoC direction, H-3, M-1, M-3, M-6, M-10). Seven are fixed for the round-1 PoC only and a variant still works (H-2, M-2, M-4, M-5, M-7, M-9; M-8 has a Low residual). See the fix table. | H-1, H-2, M-1, M-3, M-5, L-2, L-13 |
| 2 | Can a clipped-settlement state be abused? | Yes. A clipped or paused settle prices redemptions from LP amounts read at pool spot but valued at an anchor that nothing compares with spot. The keeper can also force a "clipped" settle for free, which skips the fee for redeemers. | H-1, L-5, I-1 |
| 3 | Is the liveness clock sound? | No. A partial fill of 1–2 raw USDC units (0.000002 USDC) counts as progress, resets the 72 h clock and disarms an armed unwind. | M-1 |
| 4 | Can a withdrawal be blocked or griefed with partial fill, `claimTo`, zero-share refund or `PositionsOpen`? | Not by another client. The queue cannot be blocked by a reverting or blocked recipient, and reserve accounting holds. Withdrawals can be delayed by the keeper (M-1), by a pause that stops base sales (M-4), by the anchor band (L-8), and a failed USDC push in `emergencyRedeem` is credited to `to` (L-15). `PositionsOpen` can be induced for one call but anyone can retry (L-13). | M-1, M-4, L-8, L-13, L-15 |
| 5 | Timelock: MixedBatch, expiry, guardian rotation? | MixedBatch counting and expiry are correct for `execute` and `executeBatch`; no id collision, no nested bypass. The MixedBatch fix has a side effect: removing a hostile guardian now needs two sequential delays. `schedule` accepts any delay, and `renounceRole` can brick ownership. | M-7, L-9, L-10 |
| 6 | Deploy.s.sol: unsafe default or unchecked input? | Defaults are sane. Gaps: a reused `TIMELOCK` is not checked for type, admin or executor; treasury overlap with roles is not checked; the delay is compared with 72 h, not 78 h. | L-11, L-12 |

---

## Round-1 fix verification

| Round-1 ID | Verdict | Evidence / residual |
|---|---|---|
| H-1 | Fixed at root (fake-increase direction) | Unapproved increase returns `(old, true)` (`RiskBudgets.sol:72`). Residuals in other directions: M-3, M-6. |
| H-2 | **Fixed for the PoC only** | Anchor no longer rebased, clipped settle mints nothing. The redeem direction survives: H-1. |
| H-3 | Fixed at root | Mint at a displaced spot reverts `AddValue`; a 1% displacement loses 1% and is charged 0.4 turnover units (2.5% per unit, as documented). Residual: fee netting, L-3. (Verified by the phase-2 agents; the phase-1 AMM lens did not run.) |
| M-1 | Fixed at root | `NoHedge` revert (`LPVaultBase.sol:540`), `_setParams` forces step and cap to 0. |
| M-2 | **Fixed for the PoC only** | Approval then send is cleared; send or return *before* the approval lands is not detected: M-3. |
| M-3 | Fixed at root, with a side effect | `MixedBatch` (`VaultTimelock.sol:99`). Side effect: M-7. |
| M-4 | **Fixed for the PoC only** | Unclipped skew now charges the budget. It is free again inside a live guardian range (H-2) and in clipped settles (H-1). |
| M-5 | **Fixed for the PoC only** | `max(h, m)` closes path 1. The cap base `lastNav` is still inflatable by a transient deposit: M-5. |
| M-6 | Fixed | Paused: anchor cap 0, no fee, no deposits. Residuals: hedge decreases still run (L-4); mispricing at the frozen anchor (H-1). |
| M-7 | **Fixed for the PoC only** | Head is partially filled, but dust progress resets the clock: M-1. |
| M-8 | Fixed at root (Low residual) | `PositionsOpen` gate and 1M gas pre-check. A caller can still induce caught failures for one call: L-13. |
| M-9 | **Fixed for the PoC only** | No revert, increases not charged. Gross decreases still accumulate: L-2. |
| M-10 | Fixed at root | Anchor band uses `poolBandBps` (`LPVaultBase.sol:548`). |
| L-1 | Fixed for the PoC only | 2x in two blocks is gone; 2x in 24 h remains: M-2. |
| L-2 | Fixed (residual L-14) | `epoch != 0`. Empty-queue vault still needs a heartbeat settle. |
| L-3, L-5, L-6, L-7, L-11, L-12, L-14, L-16, L-17 | Fixed at root | L-6 residual: L-15. L-12 variant: L-10. |
| L-4, L-15 | Acknowledged, unchanged | As stated by the client. |
| L-8 | Fixed for the PoC only | Zero-share deposits refunded. A dust redeem can still burn for 0 at settle time: I-3. |
| L-9 | Partly fixed | Default 96 h; floor still 24 h; script compares with 72 h: L-11. |
| L-10 | Fixed for the PoC only | Expiry works; staggered delays still give a standing lever: L-9. |
| L-13 | Fixed for the PoC, residual | Reused timelock checks are incomplete: L-12. |
| I-1 | Partly fixed | `README.md:68` still says "the HWM never decreases": I-6. |
| I-2, I-3 | Fixed | `sync(address(0))` before native settle; pragma pinned. |
| I-4 | Not verifiable here | No build was run. The three documents give three different runtime sizes: I-6. |

---

# Findings

## High

### H-1 — A clipped or paused settle prices redemptions from LP amounts read at pool spot, valued at an anchor that is never compared with spot

**Severity:** High · **Confidence:** 90 · **Origin:** [both] (phase 1: oracles, erc4626; phase 2: math-precision, periphery, first-principles, numerical-gap, flow-gap)
**Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:419-434`), `LPVaultBase.grossAssets` (`src/LPVaultBase.sol:290-293`), `V4PositionMath.amounts` (`src/V4PositionMath.sol:50`)

```solidity
// src/LPVaultBase.sol:290-293
function grossAssets(uint256 price) public view returns (uint256) {
    (uint256 b, uint256 a) = _positionAmounts();
    return idleAsset() + a + Math.mulDiv(idleBase() + b, price, WAD) + hedgeEquity;
}
// src/LPVaultBase.sol:419-421, 425
_checkPoolBand(r.price);
(uint256 price, bool clipped) =
    RiskBudgets.movePrice(budgets, lastPrice, r.price, paused ? 0 : uint256(params.refDriftBps) * (WAD / BPS));
...
uint256 nav = grossAssets(price);
// src/V4PositionMath.sol:50
(uint160 sp,,,) = pm.getSlot0(id);
```

**What is wrong.** `settle` uses three prices. The band check ties the keeper report `r.price` to pool spot. The applied anchor `price` is `r.price` only when the move fits the budget; when the move is clipped, or the vault is paused (cap 0), the applied anchor stays at or near the old anchor. LP token amounts are read at the pool's current `sqrtPrice`. Nothing compares pool spot with the *applied* anchor. For one position with liquidity `L`, spot `S` and anchor `A`, the marked value exceeds the position's value at the anchor by `L·(√S − √A)² / √S`, which is never negative: any displacement of spot, up or down, raises NAV. A clipped or paused settle processes redemptions (and only redemptions) at that NAV, and a clipped settle with no room left charges no budget.

**Impact.** Redeemers in that settle are paid above fair value from idle USDC; the remaining holders bear the difference when spot returns. The overstatement as a share of the position's value:

| Position | spot = 2 × anchor | spot = 4 × anchor |
|---|---|---|
| Full range | +6.1% | +25% |
| Range `[A/4, 4A]` pushed to the edge | — | +50% |
| ±20% range pushed out of range | +4–6% | same |
| ±10% range pushed out of range | +2–3% | same |

Worked case (phase 2, range `[A/4, 4A]`): NAV 1,000,000 = 500,000 idle + 500,000 LP; half the shares are queued for redemption; spot at `4A` during the settle. NAV reads 1,250,000, the redemption is paid 500,000 (all idle) and keeps a residual stake; honest holders end at 416,667 instead of 500,000 (−16.7%) in one settlement. `DESIGN.md:87` bounds this channel by "base exposure x anchor movement … ~5-8% of NAV … not at all once the guardian pauses". Here the anchor does not need to move, the pause does not stop it, and it can repeat: a settle that reports the anchor itself is unclipped (deposits mint at fair NAV), and the next clipped settle redeems high, with no price budget used in either.

**Conditions.** A compromised keeper, a share holder that redeems in the settle, and pool spot far from the anchor during the settle. The keeper chooses the position ranges, so it controls the size. A keeper that executes code (a contract keeper, or an EOA using EIP-7702) can move spot and settle in one transaction. Against the honest keeper bot a third party cannot use this, because the bot skips a tick when the pool is more than 3% from its reference (`keeper/README.md:35-36`, out of scope); the README instruction "report `clamp(P_hl, pool * (1 +- band))`" would expose an honest keeper that clamps instead of waiting.

**This is the round-1 H-2 root cause in the redemption direction.** The round-1 fix stopped the anchor from being rebased and stopped deposits in clipped settles, but NAV still mixes spot amounts with the anchor price.

**Fix.** Make NAV a function of the applied price only. `V4PositionMath.liquidityValue` already computes a position's principal at `sqrt(price)`; use the same principal for NAV and read only the uncollected fees from the pool.

```diff
 function grossAssets(uint256 price) public view returns (uint256) {
-    (uint256 b, uint256 a) = _positionAmounts();
+    // principal of every position at sqrt(price), as V4PositionMath.liquidityValue does;
+    // only the uncollected fees come from pool state
+    (uint256 b, uint256 a) = _positionAmountsAt(price);
     return idleAsset() + a + Math.mulDiv(idleBase() + b, price, WAD) + hedgeEquity;
 }
```

Since the spot-based value is never below the anchor-based value, this is also the conservative choice. It does not remove the accepted lag risk (I-1). Mind the EIP-170 margin (~250 B): the per-position loop belongs in the linked library.

---

### H-2 — A guardian price range is a reusable, uncharged pass: the anchor can swing between `lo` and `hi` in every settle until it expires

**Severity:** High · **Confidence:** 85 · **Origin:** [both] (phase 1: erc20+signatures, oracles, governance; phase 2: first-principles, trust-gap, flow-gap)
**Location:** `RiskBudgets.movePrice` (`src/RiskBudgets.sol:44-46`), `LPVaultBase.approvePrice` (`src/LPVaultBase.sol:633-638`)

```solidity
// src/RiskBudgets.sol:44-46
if (ref == 0 || (block.timestamp <= b.priceApprovedUntil && p >= b.priceApprovedLo && p <= b.priceApprovedHi)) {
    return (p, false);
}
```

**What is wrong.** The hedge approval is exact, epoch-bound and consumed on use (`src/RiskBudgets.sol:68-70`). The price approval is none of these. Every report inside `[lo, hi]` before `until` returns `(p, false)`: no budget is read or charged, the approval is not cleared, and the settle is unclipped, so deposits and the fee are processed. `DESIGN.md:26` says a co-signature bypasses a budget "for one specific value"; the code bypasses it for every value in the range, any number of times.

**Impact.** While one honest approval is live, the keeper can settle at `lo`, then at `hi`, then at `lo` again. If the range is no wider than twice `poolBandBps`, both ends pass the pool band against an unmoved pool. Worked case: NAV 1,000,000 with 50% base exposure, range ±1% around the pool price, a 1,000,000 deposit minted in the settle at `lo` and redeemed in the settle at `hi`: about 5,000 (0.5% of honest NAV) per pair of settles, with `priceUsed` unchanged. The number of pairs inside one approval window is not bounded by the contract, and a code-executing keeper can run many in one transaction. Without the approval each pair costs 2% of a 10% budget, which is the bound `DESIGN.md` relies on. This reopens round-1 M-4 for as long as a range is live. `DESIGN.md:139-140` describes range approvals with short deadlines as the guardian's routine in fast markets, so the precondition is ordinary operation, not guardian collusion.

**Fix.** Make the price approval one-shot, like the hedge approval, or charge every move after the first to the budget.

```diff
-if (ref == 0 || (block.timestamp <= b.priceApprovedUntil && p >= b.priceApprovedLo && p <= b.priceApprovedHi)) {
-    return (p, false);
-}
+if (ref == 0) return (p, false);
+if (block.timestamp <= b.priceApprovedUntil && p >= b.priceApprovedLo && p <= b.priceApprovedHi) {
+    b.priceApprovedUntil = 0; // consumed by the settle that uses it
+    return (p, false);
+}
```

See also L-6 (no validation of `lo <= hi`, range width or `until`; approvals survive a guardian change).

---

## Medium

### M-1 — A partial fill of 1–2 raw USDC units resets the liveness clock and disarms the emergency exit

**Severity:** Medium · **Confidence:** 90 · **Origin:** [both] (phase 1: general, precision-math, erc4626, dos; phase 2: seven agents)
**Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:433-435`), `LPVaultBase._processRedeems` (`src/LPVaultBase.sol:506-510`), `LPVaultBase.emergencyUnwind` (`src/LPVaultBase.sol:696`)

```solidity
// src/LPVaultBase.sol:435
if (lockedShares < locked0 || redeemHead == redeemTail) lastProgressTime = block.timestamp;
// src/LPVaultBase.sol:506-510
if (a > idle) {
    burnSh = Math.mulDiv(sh, idle, a);
    a = Math.mulDiv(burnSh, nav + 1, supply + VIRTUAL_SHARES);
    if (a == 0) break;
}
```

"Progress" is any decrease of `lockedShares`. The keeper controls idle USDC (LP adds, swaps, hedge sends, `maxDeposits = 0`). With NAV 1e12 raw, supply 1e18 and a head request of 5e17 shares, `idle = 2` gives `burnSh = 2e6` and `a = 2`: the head receives 0.000002 USDC, `lockedShares` falls, and the clock restarts. One such settle every 72 h keeps `canEmergencyUnwind()` false; one inside the 6 h notice makes `armed <= lastProgressTime` and forces a re-arm. Two other routes have the same root: dust requests queued ahead of real ones and processed one per period with `maxRedeems = 1`, and a request that computes `a == 0` on the full path (burned for nothing, still counted).

**Impact.** No direct theft. The only keeper-independent exit is disabled for as long as the keeper wants; `cancelRedeem` exists only in emergency. Holders stay exposed to every other keeper channel until the owner rotates the keeper through the timelock (≥ 96 h), and indefinitely if the operator is the stalling party. `DESIGN.md` threat 6 and the Deploy comment ("holders can always leave before a change lands") both rely on this clock. This is the round-1 M-7 variant.

**Fix.** Tie liveness to the age of the oldest unpaid request, or count only material progress.

```diff
-if (lockedShares < locked0 || redeemHead == redeemTail) lastProgressTime = block.timestamp;
+// progress = queue empty, or the head request was paid in full
+if (redeemHead == redeemTail || redeemHead > head0) lastProgressTime = block.timestamp;
```

A per-request `requestedAt` checked in `canEmergencyUnwind` is the stronger version. Note the interaction with M-4: once dust no longer counts, a paused vault that cannot sell base reaches the wind-down deterministically, so fix both together.

---

### M-2 — Each decaying budget admits 2x in 24 hours, not "~1.6x"; the anchor compounds to about +22% / −19%

**Severity:** Medium · **Confidence:** 95 · **Origin:** [both] (phase 1: precision-math, general, erc4626; phase 2: five agents)
**Location:** `RiskBudgets._decay` (`src/RiskBudgets.sol:35-38`), `RiskBudgets.movePrice` (`src/RiskBudgets.sol:49`, `:56-57`); spec claim at `src/RiskBudgets.sol:9-10` and `DESIGN.md:18`, `:87-89`

```solidity
// src/RiskBudgets.sol:35-38
function _decay(uint256 used, uint256 t) private view returns (uint256) {
    uint256 dt = block.timestamp - t;
    return dt >= 1 days ? 0 : used * (1 days - dt) / 1 days;
}
```

Decay is linear to zero over one day from the last write. A window that starts with an unused budget (the normal state when a key is stolen) therefore admits `cap × (1 + T / 1 day)`: a full spend at `t0` and another at `t0 + 86,399 s`, or one full spend followed by spending the restored room. "~1.6x" would be right for exponential decay. The price budget also compounds because each step is relative to the current anchor, and up and down are not symmetric.

| Channel (defaults) | Documented, per 24 h | Actual, first 24 h | 3 days | 7 days |
|---|---|---|---|---|
| Budget multiple | ~1.6x | 2x | 4x | 8x |
| Anchor movement (10% cap) | ≤ ~16% | +22.1% / −19% | +49% / −34% | +123% / −57% |
| NAV price error at 50% base | ~5–8% | ~10–11% | — | — |
| Hedge understatement (5% cap) | 5% | 10% | 20% | 40% |
| Execution loss (2x NAV turnover × 2.5%) | 5% | 10% | 20% | 40% |

At the hard cap `MAX_REF_DRIFT_BPS = 2000` the 24 h figures are +49% and −36%. The long-run rate stays 1x per day; the excess is one extra budget in the first day after a quiet period. `round1_response.md` already says "~e^0.2 per 24 h" for the price, which contradicts the `DESIGN.md` table.

**Fix.** Either correct the documents and size the three defaults for 2x and `e^(2x)`, or enforce the intended figure, for example by restoring over two days (any 24 h window then admits 1.5x) or by adding a separate 24 h accumulator. For the price budget, charge the step against the lower of the two prices so up and down steps cost the same:

```diff
-uint256 move = Math.mulDiv(p > ref ? p - ref : ref - p, WAD, ref, Math.Rounding.Ceil);
+uint256 move = Math.mulDiv(p > ref ? p - ref : ref - p, WAD, p > ref ? ref : p, Math.Rounding.Ceil);
```

---

### M-3 — A hedge approval is not bound to the stored equity the guardian judged; a margin move that lands first is not detected

**Severity:** Medium · **Confidence:** 80 · **Origin:** [both] (phase 1: erc4626, erc20+signatures; phase 2: access-control, boundary)
**Location:** `LPVaultBase.approveHedgeEquity` (`src/LPVaultBase.sol:624-629`), `RiskBudgets.moveHedge` (`src/RiskBudgets.sol:68-71`); clears at `src/LPVaultBase.sol:589`, `:607`

```solidity
// src/LPVaultBase.sol:624-628
function approveHedgeEquity(uint256 value, uint256 until) external onlyGuardian {
    budgets.hedgeApproved = value;
    budgets.hedgeApprovedEpoch = epoch + 1;
    budgets.hedgeApprovedUntil = until;
```

`sendHedgeMargin` and `returnHedgeMargin` clear an approval because it "was judged against the old baseline". That only works when the margin move comes after the approval. `approveHedgeEquity` takes no expected `hedgeEquity`, `netMargin` or epoch, so a send or return that lands between the guardian's read and the guardian's transaction leaves a fresh, valid approval for a baseline the guardian never saw. The approved path charges no budget in either direction and is not "clipped", so deposits and the fee run.

- **Send first:** `lastNav` 1,000,000, stored equity 100,000, real HL equity 110,000. A send of 240,000 lands, then the approval of 110,000, then `settle(110,000)`: stored equity drops 230,000 (23% of NAV) with no budget charge, against a documented 5%. A deposit minted in that settle gains roughly 13% of honest NAV when the margin is later recognised.
- **Return first** (needs a treasury allowance): the returned cash is counted in idle and again inside the approved value — an overstatement, which `DESIGN.md:88` calls impossible without the guardian.

For a send no race is needed in practice: margin in transit to Hyperliquid is not in HL equity, so a guardian that signs "HL equity" signs a true number against a baseline that already contains the in-flight amount. Round-1 M-2 with the order reversed.

**Fix.**

```diff
-function approveHedgeEquity(uint256 value, uint256 until) external onlyGuardian {
+function approveHedgeEquity(uint256 value, uint256 until, uint256 forEpoch, uint256 baseline) external onlyGuardian {
+    if (forEpoch != epoch || baseline != hedgeEquity) revert BadEpoch();
```

Also specify whether the guardian's value includes margin in transit.

---

### M-4 — A pause blocks the only base-to-USDC path for longer than the no-progress timeout, so pause plus redeem demand ends in permanent wind-down

**Severity:** Medium · **Confidence:** 85 · **Origin:** [both] (phase 1: governance, dos; phase 2: access-control, first-principles, flow-gap)
**Location:** `UniV4LPVault.swap` (`src/UniV4LPVault.sol:265-270`), `LPVaultBase.setPaused` (`src/LPVaultBase.sol:612-617`), `script/Deploy.s.sol:61`

```solidity
// src/UniV4LPVault.sol:265-270
function swap(bool sellBase, uint256 amountIn, uint256 keeperPrice)
    external
    nonReentrant
    onlyKeeper
    whenNotPaused
    notEmergency
```

`swap` is `whenNotPaused` in both directions. Only the owner can unpause, and the Deploy script requires the timelock delay to exceed 72 h, so a pause lasts at least 96 h by default. While paused, redemptions are payable only from idle USDC, the USDC leg of LP removals and hedge returns; the base half cannot be sold. Once that is spent there is no progress, and at 72 h + 6 h = 78 h anyone can make the wind-down permanent — before an unpause scheduled at the moment of the pause can execute. Example: NAV 1,000,000 with a 50/50 LP, redemptions of 600,000 queued after a pause; 500,000 is paid, 100,000 remains, `swap(true, …)` reverts `IsPaused`.

**Impact.** One guardian key (or one false-positive pause by the guardian bot) plus ordinary redeem demand above the USDC share of NAV ends the vault irreversibly. README ("Pause never blocks…") and `DESIGN.md` threat 12 ("redemptions continue at the frozen price until unpaused") do not state this. Today an honest keeper can only avoid it with the dust payments of M-1.

**Fix.** Allow the risk-reducing direction while paused, with all existing checks.

```diff
-    whenNotPaused
     notEmergency
     returns (uint256 out)
 {
+    if (paused && !sellBase) revert IsPaused();
```

Alternatively let the guardian lift its own pause, or exclude paused time from `SETTLE_TIMEOUT`. A frozen anchor more than about 3% from the pool still blocks the sale until a range is approved (L-8).

---

### M-5 — The hedge cap is sized on `lastNav`, which a transient deposit inflates: up to 100% of the remaining NAV can sit at the treasury

**Severity:** Medium · **Confidence:** 80 · **Origin:** [both] (phase 1: erc4626, general; phase 2: numerical-gap, plus four leads)
**Location:** `LPVaultBase.sendHedgeMargin` (`src/LPVaultBase.sol:584-586`), `LPVaultBase.hedgeCap` (`src/LPVaultBase.sol:317-319`)

```solidity
// src/LPVaultBase.sol:584-586
uint256 after_ = (h > m ? h : m) + amount;
uint256 cap = hedgeCap();
if (after_ > cap) revert HedgeCap(after_, cap);
```

`hedgeCap()` is `lastNav × hedgeCapBps`, and `lastNav` is the post-flow NAV of the last settle, including a deposit processed in it. The cap is checked once, at send time, and never again when NAV shrinks. With honest NAV `N`, a deposit of `10N` gives `lastNav = 11N` and a cap of `3.85N`; after the send the depositor redeems the remaining idle USDC. All of the honest `N` is then off-chain at the treasury, against a documented custody bound of 35% (`DESIGN.md:90`). A deposit of about `1.86N` is enough. `sendHedgeMargin` works while paused, so the guardian cannot stop it. The same drift happens without an accomplice when honest holders redeem after a send.

**Impact.** No theft while the treasury operator is honest: this is a custody bound broken by about 3x, and withdrawals (including the in-kind emergency exit, which excludes hedge margin) then depend entirely on an off-chain return. It is the second path of round-1 M-5.

**Fix.** Size the cap on a base the queue cannot move, for example NAV net of queued redemptions and of deposits minted in the last settle.

```diff
-uint256 cap = hedgeCap();
+uint256 cap = Math.mulDiv(lastNav - previewRedeemLast(lockedShares), params.hedgeCapBps, BPS);
```

---

### M-6 — An unchanged hedge report is never "clipped", so a withheld hedge gain understates NAV beyond `hedgeStepBps` while deposits are processed

**Severity:** Medium · **Confidence:** 70 · **Origin:** [both] (phase 1: erc4626; phase 2: trust-gap, first-principles lead)
**Location:** `LPVaultBase._hedgeFor` (`src/LPVaultBase.sol:538-539`), `LPVaultBase.settle` (`src/LPVaultBase.sol:428-432`)

```solidity
// src/LPVaultBase.sol:538-539
uint256 old = hedgeEquity;
if (v == old) return (v, false);
```

The hedge budget bounds active decreases. An increase needs the guardian, but nothing obliges the keeper to report one: `v == old` returns "not clipped", so the settle is eligible and deposits mint at a NAV that omits the unreported gain. A short hedge gains when HYPE falls, exactly when the anchor (moved by the keeper) marks the LP loss. Example: NAV 1,000,000, HYPE −20%, hedge +100,000 unreported; a large deposit at the understated NAV holds about 9/10 of supply and gains about 9% of honest NAV when the equity is later recognised (by an honest approval, or by `returnHedgeMargin`, whose surplus over `hedgeEquity` lands in idle with no approval at `src/LPVaultBase.sol:604`). `DESIGN.md` states "Understatement <= 5%/day" and names only stale reporting of a *loss* as a residual.

**Conditions.** A real market move, a compromised keeper and accomplice capital; a guardian that pauses stops the deposit side (but paused settles then redeem honest holders at the understated NAV). Confidence is lower because the guardian bot's HL comparison is meant to catch a stale report.

**Fix.** Hold deposits unless the equity was refreshed within a maximum age (a `hedgeEquityTime`, required when `hedgeTreasury != 0`), or restate the bound.

---

### M-7 — Removing a hostile guardian now takes two sequential delays, during which it keeps the pause, the co-signatures and a veto on the unpause

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase 1: governance] (phase 2 access-control and first-principles reached the same state inside M-4)
**Location:** `VaultTimelock.scheduleBatch` (`src/VaultTimelock.sol:98-101`), `VaultTimelock.cancel` (`src/VaultTimelock.sol:131`)

```solidity
// src/VaultTimelock.sol:98-101
if (self != 0) {
    if (self != targets.length) revert MixedBatch();
    isSelfOperation[hashOperationBatch(targets, values, payloads, predecessor, salt)] = true;
}
```

The round-1 M-3 fix makes every batch that mixes timelock and vault targets revert. The guardian can cancel every vault-targeted operation (`setPaused(false)`, `setGuardian`) until a self-only operation has removed its `CANCELLER_ROLE`, so a vault operation that survives can only be scheduled once that self-operation is executable: recovery is at least 2 × delay (192 h at the default). For that whole time the guardian keeps `vault.guardian`: the pause, the frozen anchor, and with M-4 the path to wind-down. The NatSpec rotation order ("(1) a timelock-only batch… (2) `vault.setGuardian`", `src/VaultTimelock.sol:20-21`) and the round-1 response ("vault, then timelock roles") contradict each other. A self-only `updateDelay(24 h)` shortens the wait but cuts everyone's notice to 24 h.

**Fix.** Give guardian removal a one-delay path that covers the vault seat: treat an operation as proposer-only-cancellable when every call is a timelock self-call or `vault.setGuardian(address)`, and treat other mixed batches as ordinary guardian-cancellable operations instead of reverting. State one rotation order in NatSpec, README and `DESIGN.md`, and add the 2 × delay figure to threat 12.

---

## Low

### L-1 — Every budget write re-bases the decay, including zero-size writes, so honest capacity restores exponentially, not linearly
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] · **Location:** `RiskBudgets.movePrice` (`src/RiskBudgets.sol:56-57`), `useTurnover` (`:85-88`), `moveHedge` (`:78-79`)

`b.priceUsed = used + move; b.priceTime = block.timestamp;` runs when `move` is 0 (a settle that reports the anchor, every paused settle, `useTurnover(0)`). After a full spend, 24 hourly settles leave (23/24)^24 = 36% of the budget still used, where the documents say 0%. This never helps an attacker; it means more clipped settlements (no deposits, no fee, redemptions at the anchor edge) for an honest keeper. **Fix:** return before the write when the charge is 0, or store a refill model that does not depend on write frequency.

### L-2 — The hedge budget still sums gross decreases; approved increases give nothing back (round-1 M-9 variant)
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: precision-math] · **Location:** `RiskBudgets.moveHedge` (`src/RiskBudgets.sol:72-80`)

The revert is gone and increases are not charged, but the budget is path length on the downward half. With the round-1 numbers (NAV 1,000,000, cap 50,000, hourly ±5,000 with each increase approved) the budget's fixed point is 60,000 > 50,000, so honest down-reports are clipped from about hour 41. Every real increase, including funding income, is "clipped" unless the guardian signs the exact integer for that epoch. **Fix:** bound the net move against a reference equity, or credit `hedgeUsed` when equity moves back up.

### L-3 — `increasePosition` nets collected fees against `paid`, so an increase can lose up to the uncollected fees beyond the slippage bound and is under-charged for turnover
**Severity:** Low · **Confidence:** 80 · **Origin:** [both] (two phase-1 agents, seven phase-2 leads) · **Location:** `UniV4LPVault._checkAddAt` (`src/UniV4LPVault.sol:215-218`)

```solidity
uint256 v1 = _heldValue(ref);
_checkAdd(V4PositionMath.liquidityValue(tl, tu, liquidity, ref, baseIsCurrency0), v0 > v1 ? v0 - v1 : 0);
```

PositionManager nets the position's accrued fees `F` into the currency delta, so `paid = cost − F` while `got` values only the new liquidity; `F` was already in NAV. The check allows a loss of `F + s·(cost − F)`, and with `F >= cost`, `paid = 0` skips both the value check and the turnover charge. Bounded by the fees left uncollected in one position; no agent found a cheap way to make `F` large. **Fix:** collect fees before taking `v0`, or add the fee value at `ref` to `paid`.

### L-4 — A pause does not freeze keeper-only hedge decreases
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase 1: erc4626, governance] · **Location:** `LPVaultBase.settle` (`src/LPVaultBase.sol:421-423`), `_hedgeFor` (`:541`)

While paused `movePrice` gets cap 0, but `moveHedge` still gets `lastNav × hedgeStepBps`. A compromised keeper can keep lowering equity at the budget rate for the whole keeper-rotation delay (≥ 96 h, roughly 25% of NAV at defaults), and queued redeemers, who cannot cancel, are paid at the understated NAV. Each day is inside the per-day bound; the gap is that the pause, which `DESIGN.md:96` calls the backstop, does not apply to this channel. **Fix:** pass `paused ? 0 : cap` to `moveHedge`.

### L-5 — The keeper can force a "clipped" settle for free; redemptions in clipped or paused settles escape the performance fee
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] · **Location:** `RiskBudgets.moveHedge` (`src/RiskBudgets.sol:72`), `LPVaultBase.settle` (`src/LPVaultBase.sol:428-432`)

`if (v > old) return (old, true);` changes no state and uses no budget, yet sets `hClipped`. A report of `hedgeEquity + 1` therefore skips the fee and deposits while redemptions run at the pre-fee price per share. With pps 20% above the HWM and half the supply redeeming, the fee recipient forgoes about 1.5% of NAV; remaining holders are not hurt. The same holds for every redemption during a pause. **Fix:** in clipped or paused settles, price redemptions at the post-fee pps (withhold `feeBps` of the gain above the HWM), or document it.

### L-6 — `approvePrice` accepts any range and expiry, and guardian approvals survive a guardian change and a pause
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] · **Location:** `LPVaultBase.approvePrice` (`src/LPVaultBase.sol:633-638`), `LPVaultBase.setGuardian` (`src/LPVaultBase.sol:647-651`)

No `lo <= hi`, no width cap, no cap on `until`; `setGuardian` and `setPaused(true)` clear nothing. A guardian that is being rotated out (public for the whole delay) can leave `approvePrice(0, type(uint256).max, type(uint256).max)` behind, after which the price budget is off for any later keeper, also while paused, until the new guardian revokes it. A pause does not freeze the anchor if an earlier range is still live. **Fix:** require `lo <= hi` and `until <= block.timestamp + MAX_APPROVAL_TTL`; clear `priceApprovedUntil` and `hedgeApprovedEpoch` in `setGuardian` (and preferably in `setPaused(true)`).

### L-7 — Swaps and LP adds accept an anchor of any age
**Severity:** Low · **Confidence:** 60 · **Origin:** [phase 2: first-principles] · **Location:** `LPVaultBase._checkKeeperPrice` (`src/LPVaultBase.sol:545-549`); `lastSettleTime` is written at `:439` and read by no check

Execution loss is bounded "against the anchor", but only the keeper moves the anchor and nothing reads its age. If the keeper stops settling (or the anchor is clipped behind a fast market) and the market moves by a gap `g`, a swap that passes both band checks at the old anchor can lose about `g + band + slippage` per unit against the market, not `band + slippage`. It needs an exogenous market move and pool spot back at the old anchor for the transaction; pool depth for that was not verified. **Fix:** make `_checkKeeperPrice` revert when `block.timestamp - lastSettleTime` exceeds a short limit or when the last settle was clipped.

### L-8 — The anchor band, and a shrunken turnover cap, can block the base sale that funds redemptions
**Severity:** Low · **Confidence:** 80 · **Origin:** [both] · **Location:** `LPVaultBase._checkKeeperPrice` (`src/LPVaultBase.sol:548`), `LPVaultBase._useTurnover` (`src/LPVaultBase.sol:572-574`)

`swap` needs a price within 1.5% of the pool and of the anchor. When the market outruns the anchor (which follows at 10% per decaying day and is frozen while paused), the two bands do not intersect: after a 15% drop in an hour (70 → 59.5, anchor clipped to 63) no price passes, and base cannot be sold for redemptions for roughly 6 h, or until the guardian approves a range. Separately, the turnover cap is `lastNav × swapTurnoverBps`: after a large redemption cuts `lastNav`, an earlier spend can block every swap for up to about 22 h. Both are limits that delay withdrawals, which the design rule says must not happen. **Fix:** make the anchor check one-sided for `sellBase`, or document that redemption funding depends on the guardian in fast markets.

### L-9 — `schedule` accepts any delay, so staggered operations keep a ready lever available; a pending `Ownable2Step` owner never expires
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: governance] · **Location:** `VaultTimelock.schedule` / `scheduleBatch` (`src/VaultTimelock.sol:73-102`), `_checkNotExpired` (`:125-128`)

Expiry is measured from each operation's own ready time and the caller-chosen `delay` has only a lower bound. Operations scheduled with delays of 96 h + k × 7 d give a ready copy at every moment for k weeks; self-operations among them (for example `revokeRole(CANCELLER, guardian)`, `updateDelay(24 h)`) cannot be cancelled by the guardian. Separately, an executed `vault.transferOwnership(X)` leaves `X` able to accept at any later time; if `X` is not a timelock, every owner function becomes instant. (A `delay` near `type(uint256).max` makes `ts + GRACE_PERIOD` overflow in `execute`; harmless, the id can be cancelled.) Round-1 L-10 variant. **Fix:** revert when `delay > getMinDelay() + GRACE_PERIOD`; in the vault, require the new owner to be a timelock with an adequate delay, or let pending ownership lapse.

### L-10 — `renounceRole` on the timelock produces the state `renounceOwnership` was disabled to prevent
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase 1: governance] · **Location:** `VaultTimelock` constructor (`src/VaultTimelock.sol:42-49`); inherited `AccessControl.renounceRole` (`lib/openzeppelin-contracts/contracts/access/AccessControl.sol:155-161`)

The operator is the only holder of `PROPOSER_ROLE` and `EXECUTOR_ROLE`, and the only admin is the timelock itself. `renounceRole(PROPOSER_ROLE, operator)` is instant and irreversible: nobody can schedule, so nobody can grant the role back, and `setPaused(false)`, `setKeeper`, `setGuardian`, `setParams` are dead. A lost operator key has the same effect. **Fix:** override `renounceRole` to revert for `PROPOSER_ROLE` and `EXECUTOR_ROLE` (or for the last holder); consider a second, cold proposer.

### L-11 — The 96 h delay does not guarantee an exit before a change lands; the script compares with 72 h, not 78 h
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] · **Location:** `script/Deploy.s.sol:56`, `:61`; `src/VaultTimelock.sol:27`, `:66-71`

```solidity
require(delay > SETTLE_TIMEOUT, "TIMELOCK_DELAY <= 72h");
```

The trustless exit takes `SETTLE_TIMEOUT + UNWIND_NOTICE` = 78 h (and up to 7 d more with an open position), but a delay of 72 h + 1 s passes. The 72 h clock starts at the last redeem progress, not when the operation is scheduled (and M-1 lets the keeper postpone it). A self-only `updateDelay(24 h)` cannot be cancelled by the guardian, and the contract floor is still 24 h. The statements in `script/Deploy.s.sol:19-20` and `README.md:59` are therefore not established. **Fix:** compare with `SETTLE_TIMEOUT + UNWIND_NOTICE` plus a margin; raise `MIN_DELAY_FLOOR` accordingly; reword the claim.

### L-12 — `Deploy.s.sol`: a reused timelock is checked for only four properties, and role overlaps with the treasury are not checked
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] · **Location:** `script/Deploy.s.sol:54-59`, `:37-47`, `:73-75`

For `TIMELOCK=<addr>` the script checks code, `getMinDelay() > 72 h`, PROPOSER for `OWNER` and CANCELLER for `GUARDIAN`. It does not check `EXECUTOR_ROLE` for `OWNER` (with no executor a pause is permanent), that `DEFAULT_ADMIN_ROLE` is held only by the timelock (a stock OZ timelock with an EOA admin can revoke the guardian's role instantly), or that the contract is a `VaultTimelock` at all (no floor, cap, expiry or self-operation rule). `HEDGE_TREASURY` is not compared with `KEEPER`, `GUARDIAN` or `OWNER`: treasury == keeper would put up to `hedgeCapBps` of NAV under the hot key. `HEDGE_CAP_BPS` is accepted up to 5000 while `DESIGN.md` states 35%; `TIMELOCK_DELAY` is validated even when unused; `FEE_RECIPIENT`, `NAME`, `SYMBOL` are unvalidated. **Fix:** compare the timelock codehash with `type(VaultTimelock).runtimeCode`, require the executor role and no extra admin, and reject treasury overlaps.

### L-13 — A caller can still induce caught burn failures in `_unwindAll`, leaving `emergency = true` with every position open
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: dos] · **Location:** `UniV4LPVault._unwindAll` (`src/UniV4LPVault.sol:250-256`; comment at `:39-41`)

```solidity
if (gasleft() < UNWIND_MIN_GAS) revert UnwindOutOfGas();
try positionManager.modifyLiquidities(_removeData(true, id, 0, 0, 0), block.timestamp) {
```

The 1M gas pre-check removes gas-induced failures, but `PoolManager.unlock` reverts `AlreadyUnlocked` when already unlocked (`lib/v4-periphery/lib/v4-core/src/PoolManager.sol:105`). If the executing `emergencyUnwind()` call is made from inside the caller's own `unlock` callback, every burn reverts cheaply and is caught, and the transaction succeeds with `emergency` set and all positions open. The `PositionsOpen` gate holds for 7 days and anyone can call `emergencyUnwind()` again normally, so the impact is a delay; if nobody retries for 7 days, redeemers forfeit the LP share. The comment "a caught failure … is a real failure, never one induced by a caller" is wrong. **Fix:** revert instead of catching when the reason is `AlreadyUnlocked` / `ContractLocked`, or revert when no position was removed in the call that first sets `emergency`.

### L-14 — A healthy vault with an empty redeem queue is wound down if no `settle` lands for 78 h
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase 1: dos] · **Location:** `LPVaultBase.canEmergencyUnwind` (`src/LPVaultBase.sol:321-323`); NatSpec at `:49-51`

```solidity
return emergency || (epoch != 0 && block.timestamp > lastProgressTime + SETTLE_TIMEOUT);
```

With an empty queue the stamp is written only by a `settle`, so the clock measures "time since the last settle" even when nobody is waiting. The NatSpec says "nothing paid while requests are pending". README documents the heartbeat ("at least every 72 h"), but a keeper that settles only when queues are non-empty, or a sequencer outage of that length, lets anyone arm and execute a permanent wind-down with zero pending redemptions. **Fix:** stamp `lastProgressTime` in `requestRedeem` on the empty-to-non-empty transition, or fix the NatSpec and make the heartbeat a hard keeper requirement.

### L-15 — A failed USDC leg in `emergencyRedeem` is credited to `to`, not to the caller; zero-share refunds are never pushed
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase 1: erc20, general, dos] · **Location:** `LPVaultBase.emergencyRedeem` (`src/LPVaultBase.sol:727`), `_processDeposits` (`src/LPVaultBase.sol:483-484`)

`_pay(to, aOut);` credits `claimable[to]` when the push fails (USDC paused, vault or `to` blocked). If `to` cannot call `claimTo` (an exchange deposit address, a plain contract), that USDC is stranded while the native and WHYPE legs are delivered and the shares are burned. `msg.sender` is the only party proven able to call the vault. The zero-share deposit refund only credits and never attempts a push. **Fix:** credit `claimable[msg.sender]` on failure in `emergencyRedeem`; use `_pay` for the refund.

---

## Informational

### I-1 — Clipped and paused settles redeem at an anchor that may lag the market: magnitude of the accepted risk
**Severity:** Informational · **Origin:** [phase 1: erc4626] · `LPVaultBase.settle` (`src/LPVaultBase.sol:420-434`)

`DESIGN.md` accepts that a redemption in a clipped settle "can be above or below fair" without a figure. The error is `base(spot) × (anchor − market)` with no parameter bound: after a 25% drop in hours (anchor clipped to −10%) a vault with 60,000 HYPE and 300,000 USDC marks 840,000 against a fair 750,000, and redemptions of 30% of supply cost the rest 5%. Anyone can benefit by requesting a redemption during a crash; a keeper that withholds settles while the market trends can make it systematic. The H-1 fix does not remove this. Consider a per-request `minAssets`, cancel while the last settle was clipped, or pricing at the lower of the anchored and the reported NAV.

### I-2 — `maxSlippageBps == 0` is accepted but bricks swaps and adds
**Severity:** Informational · `LPVaultBase._setParams` (`src/LPVaultBase.sol:670-672`). With `s = 0` the add check becomes `got >= paid` (never true after rounding) and `minOut = fair` cannot survive the 0.3% pool fee. Require a floor above the pool fee.

### I-3 — Dead cap, zero-asset burns and dust requests
**Severity:** Informational · `LPVaultBase._processRedeems` (`src/LPVaultBase.sol:503-517`), `requestRedeem` (`:368`). `if (a > nav) a = nav;` (`:504`) can never fire. The `a == 0` break exists only in the partial branch, so a request worth 1 raw unit at request time can burn for 0 after a NAV drop (and counts as progress, M-1). Redeem requests have no floor beyond 1 raw unit; queue spam costs the attacker roughly twice the keeper's gas (accepted, threat 11). A sell-base swap below about 1.4e10 wei has `fair = 0` and charges no turnover (dust). Consider a relative minimum redeem size and skipping zero-asset entries.

### I-4 — A hedge return after the last share is burned in wind-down has no exit
**Severity:** Informational · `LPVaultBase.returnHedgeMargin` (`src/LPVaultBase.sol:597-609`). In emergency there is no `settle` and `emergencyRedeem` needs shares; with `totalSupply() == 0` returned USDC is locked. Revert in that state or document an off-chain distribution.

### I-5 — Treasury and wrapper assumptions
**Severity:** Informational · `returnHedgeMargin` (`src/LPVaultBase.sol:601-606`), `idleBase` (`:276-279`), constructor (`:215`). The keeper chooses the returned `amount`, bounded only by the treasury allowance; a surplus over `hedgeEquity` becomes NAV, and one treasury address shared by two vaults would mix their margin — document "one treasury per vault, exact allowances". NAV and the emergency payout add native and WHYPE balances, which is correct only for a WETH9-style wrapper; Deploy checks only `decimals() == 18`. The constructor does not reject `wrappedBase == baseToken` (relevant to the planned ERC-20-base subclass, which would double count).

### I-6 — Documentation mismatches
**Severity:** Informational. `README.md:68` "the HWM never decreases" (it restarts at supply 0, `src/LPVaultBase.sol:451-453`). `src/VaultTimelock.sol:9` "48 h by default" (Deploy and README: 96 h). Runtime size is given as "~24.0 KB" (README), "24,276 B" (`DESIGN.md`) and "24,326 B" (response). `src/LPVaultBase.sol:566` "After any keeper action" (`_checkReserve` is not called by `settle`, `decreasePosition`, `burnPosition`, `returnHedgeMargin`, `unwrapBase` — harmless, see coverage). `DESIGN.md:23` "`lastNav`… never contains the settling epoch's deposits" (it contains the previous settle's). `DESIGN.md` threat 13 residual omits that the owner can replace the guardian. `src/UniV4LPVault.sol:39-41` (see L-13).

### I-7 — Timelock minor observations
**Severity:** Informational · `src/VaultTimelock.sol`. An empty batch can be scheduled and executed. An expired id still reports ready/pending and blocks re-scheduling the same call and salt until cancelled; an operation whose predecessor expired cannot run until the predecessor is cancelled, rescheduled and executed. The constructor does not reject `operator == guardian` (only Deploy does). On a shared timelock each vault's guardian can veto the other vaults' operations. `setParams` overwrites the whole struct, so two pending operations built from different bases lose one update.

### I-8 — Chain notes (Arbitrum Orbit, native HYPE)
**Severity:** Informational. The sequencer sets `block.timestamp` and several blocks can share one; `_decay` with `dt = 0` and the Permit2 same-timestamp expiry are safe. Sequencer downtime still counts toward the 72 h + 6 h clock, and force inclusion through the parent chain can arm and execute during an outage — document the delayed-inbox path as a keeper requirement. The EIP-170 margin is about 250–300 B, so every fix above must be measured, and Elysium's `MaxCodeSize` is still unconfirmed (`DESIGN.md` open item). EIP-7702 makes a keeper EOA a code-executing keeper; no check depends on `tx.origin` or code size.

---

## Access-Control Inventory

37 state-changing entry points in first-party code (LPVaultBase 20, UniV4LPVault 7, VaultTimelock 6, RiskBudgets 3 linked-library externals, Deploy 1), reconciled against the grep-verified pre-scan list.

| Caller | Functions | Notes |
|---|---|---|
| Anyone | `requestDeposit[WithPermit]`, `cancelDeposit`, `requestRedeem`, `cancelRedeem` (emergency only), `claim`/`claimTo`, `emergencyUnwind`, `emergencyRedeem`, `receive`, ERC-20 transfers | deposits blocked by pause and emergency; `requestRedeem` blocked by emergency only |
| Keeper | `settle`, `swap`, `mintPosition`, `increasePosition`, `decreasePosition`, `burnPosition`, `unwrapBase`, `sendHedgeMargin`, `returnHedgeMargin` (also treasury) | `swap`/mint/increase blocked by pause; all but `returnHedgeMargin` and `unwrapBase` blocked by emergency |
| Guardian | `setPaused(true)`, `approveHedgeEquity`, `approvePrice`; timelock `cancel` (non-self operations) | instant; not gated by pause or emergency |
| Owner (timelock) | `setPaused(false)`, `setKeeper`, `setGuardian`, `setFeeRecipient`, `setParams`, `transferOwnership` | every call waits ≥ delay, expires ready + 7 d; `renounceOwnership` reverts |
| Operator | timelock `schedule[Batch]`, `execute[Batch]`, `cancel` | sole PROPOSER and EXECUTOR; admin is the timelock itself |
| PoolManager | `unlockCallback` | only while `_swapping` |

Examined, no issue: `unwrapBase` (value-neutral, never touches the asset); `unlockCallback` gating and native `sync`/`settle`/`take`; Permit2 sub-allowance (exact, same-timestamp, reset); PositionManager action codes and encodings against the vendored periphery; `_pay` / `claimTo` / zero-share refund accounting; `_update` versus `requestRedeem`; removals at a displaced spot (the vault does not lose); the reserve on every keeper path that does not call `_checkReserve`; timelock id hashing, `MixedBatch`, expiry on both execute paths, `getMinDelay` override; first settle and supply-0 restart; fee and rounding directions.

## Threat Model — catalog answers

| # | Threat row | Answer |
|---|---|---|
| T1 | Keeper + accomplice + pool: settle price path | Violated → H-1, H-2 |
| T2 | Keeper: hedge report, send/return | Violated → M-3, M-5, M-6; L-2, L-4 |
| T3 | Keeper + pool: swap / LP add loss | Holds within band + slippage per unit, except fee netting → L-3, and anchor age → L-7 |
| T4 | Keeper: budget timing | Violated → M-2; L-1 |
| T5 | Keeper: keep redemptions unpaid without triggering the exit | Violated → M-1 |
| T6 | Keeper: removals at a displaced spot | Invariant holds — a removal realises the pusher's loss, not the vault's |
| T7 | Keeper: fee path | Fee math holds; fee skipped for redeemers in clipped/paused settles → L-5 |
| T8 | Client: queue spam, dust, blocked recipient, partial fill, `claimTo` | Invariants hold; residuals I-3, L-15 |
| T9 | Anyone: emergency arm/execute, gas, payout | Arm/execute logic holds; L-13, L-14, I-4 |
| T10 | Anyone: pool moved before a keeper transaction | No sustained settle DoS; honest-keeper exposure depends on the bot skipping (H-1 note) |
| T11 | Guardian alone | Violated → M-4, M-7; L-6 |
| T12 | Operator / owner key | Delay and veto hold; L-9, L-10, L-11 |
| T13 | Reentry from external contracts | Invariant holds — guard coverage and ordering examined |
| T14 | Deployer inputs | L-11, L-12 |
| T15 | Depositor / donor / first depositor | Invariant holds — virtual shares, floor rounding, zero-share refund |

## Invariant Verification

| ID | Property | On-chain | Verdict |
|---|---|---|---|
| I-1 | `lockedShares == balanceOf(vault)` | Yes | holds |
| I-2 | `pendingDepositAssets == Σ queued deposits` | Yes | holds |
| I-3 | `totalClaimable == Σ claimable` | Yes | holds |
| I-4 | asset balance ≥ pending + claimable after every keeper action | No | holds — the unchecked paths only receive the asset or pay from `idleAsset()` |
| I-5 | anchor moves per settle within the remaining budget unless a free path applies | Yes | holds as stated; the free path itself is H-2 |
| I-6 | anchor movement in 24 h ≤ ~1.6 × `refDriftBps` | No | violated → M-2 |
| I-7 | keeper alone never raises equity via `settle`; decreases within budget | Yes / No | violated → M-3 (stale approval), M-6 (withheld gain) |
| I-8 | `max(hedgeEquity, netMargin) ≤ hedgeCapBps × lastNav` | No | violated → M-5 |
| I-9 | swap + add notional within the turnover budget | Yes | holds at charge sites; under-charge → L-3 |
| I-10 | clipped or paused settle mints no shares | Yes | holds |
| I-11 | `lastProgressTime` advances only on real redeem progress | Yes | violated → M-1 |
| I-12 | `emergency` one-way; execute needs a live arm and 6 h | Yes | holds |
| I-13 | fee formula and HWM | Yes | holds |
| I-14 | deposit / redeem conversions and partial fill | Yes | holds |
| I-15 | hedge approval one-shot, epoch-bound, exact, cleared by send/return | Yes | holds as stated; not bound to the baseline → M-3 |
| I-16 | at most 8 positions | Yes | holds |
| X-1 | guardian can always cancel a pending vault operation | No | holds conditionally (documented residual); recovery cost → M-7 |
| X-2 | LP amounts at pool spot are consistent with the applied anchor | No | violated → H-1 |
| X-3 | spent budget "restored linearly over the following 24 h" | No | violated → M-2, L-1 |
| X-4 | drop in `_heldValue` equals the cost of the add | No | violated → L-3 |
| X-5 | `unlockCallback` settles exactly the vault's own swap | Yes | holds |
| E-1 | price-channel damage ≤ base exposure × anchor movement | No | violated → H-1, H-2, M-2 |
| E-2 | execution loss ≤ (band + slippage) × turnover per day | No | violated → M-2 (2x), L-3, L-7 |
| E-3 | no limit ever blocks a withdrawal | Yes | violated in part → M-4, L-8 |
| E-4 | unpaid redemptions lead to the in-kind exit after 72 h + 6 h | No | violated → M-1 |
| E-5 | fee charged on all gains above the HWM | No | violated → L-5 |

Could not verify: none of the rows above. Not modelled in this run: a combined multi-channel, multi-day extraction total (the economic-security lens did not run).

---

*This review was performed by an AI pipeline. AI analysis cannot verify the complete absence of vulnerabilities and no guarantee of security is given. Nothing was compiled or executed; a fuzz or fork test of each High and Medium fix is recommended before deployment.*
