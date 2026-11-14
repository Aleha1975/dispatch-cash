# Elysium LP Smart Accounts — Security Audit, round 2 (verification of the round-1 root-cause fixes)

**Job:** leftclaw #1225 · **Date:** 2026-11-14
**Repo:** https://github.com/Aleha1975/dispatch-cash — commit `ace88c9380fa57b2d328981d81bd1f19f6a3bd2a` (reachable on the remote as `refs/heads/elysium-lp-sa`; verified with `git ls-remote`). Every citation below was checked against the files at this commit.
**Chain context:** Elysium mainnet, chain id 99901 (Arbitrum Orbit / Nitro). The contracts are not deployed.
**Scope (as submitted):** `src/sa/LPManagerModule.sol`, `src/sa/SALib.sol`, `src/sa/SAWindow.sol`, `src/sa/ElysiumCustodyEnforcer.sol`, `src/sa/SwapExecutor.sol`, `src/sa/vendor/DelegationFramework.sol`, `script/DeploySA.s.sol`, and the reused `src/V4PositionMath.sol`, `src/VaultTimelock.sol` (9 files, 1,967 nSLOC). The pooled vault is out of scope.

**Severity counts:** 0 Critical · 1 High · 4 Medium · 16 Low · 11 Informational

---

## How to read this report

- Each finding has its own **Severity** (what it costs if real) and **Confidence** (how sure we are it is real). They are separate.
- **Origin** says which independent pass raised it: `[phase1: <checklist>]`, `[phase2: agent N <lens>]`, or `[both]`.
- Findings with confidence below 50 are in a separate **Leads** section.
- This engagement ran fresh, end to end. The round-1 report in the repo (job 1224) was read as client-supplied input only; no finding was copied from it.

### What ran

| Phase | What | Result |
|---|---|---|
| 0a | x-ray pre-scan (enumeration, grep-verified entry points, invariant synthesis, git analysis) | 33 state-changing entry points; 40 inferred invariants (12 not enforced on-chain) |
| 0 | Context: access-control inventory, protocol map, external surface (3 agents) | map + 22 threat rows + 10 fragility clusters |
| 1 | Breadth: 8 checklist agents over 13 local checklists (general, erc20, precision-math, defi-amm, flashloans, erc4337, proxies, signatures, assembly, oracles, access-control, governance, dos, chain-specific) | 5 Medium, 18 Low, 9 Info after dedup |
| 2 | Depth: 12 attack agents, blind to phase 1, one pass, waves of 3 | **12 of 12 returned**; 5 findings, 12 leads after dedup and gates |
| 3 | Reconciliation, targeted re-reads, coverage gate | this report |

**Lenses the client asked for in Task 4 — all ran in phase 2:** math-precision (agent 1), access-control (2), execution-trace (4), periphery (6), boundary (9), numerical-gap (10), trust-gap (11), flow-gap (12). Also ran: economic-security (3), invariant (5), first-principles (7), asymmetry (8).

### Coverage caveats — read these

- **No code was executed.** Building or testing the target is disabled by audit policy (it runs the target's own code in an environment that holds job credentials). Every trace below is a hand trace through the source with concrete numbers. No Foundry test is attached; each finding gives the sequence a test would follow, and `test/sa/SAHostile.sol` already has the hostile-account shape the Medium findings need.
- **Delegation Framework v1.3.0 internals are from memory**, cross-checked against `test/sa/SATestBase.sol`, `test/sa/SAHostile.sol` and the fixtures (the framework is present only as init-code hex). `SALib.PROXY_CREATION` was compared byte for byte with the ERC1967Proxy fixture and matches. Uniswap v4 PositionManager / Notifier / Permit2 behaviour was read from `lib/` at the repo's pinned submodule commits.
- **Pool-manipulation costs are order-of-magnitude estimates**, not computed from live pool state.
- **Less depth:** `SwapExecutor.sol` and `VaultTimelock.sol` (unchanged since round 1; no new issue found), `DeploySA.s.sol` (read, not simulated), the keeper (`keeper/`) and web code (out of scope, skimmed only where a finding depends on what the operator does off-chain).

### Reconciliation summary

`Overlap: 11 · Phase-1-only: 22 · Phase-2-only: 2 · Re-examined leads kept: 21, demoted: 3 · Coverage holes closed: 0 · Invariants: 40 answered (27 hold, 13 violated or partly violated, 0 unverified)` · Reporting floor: Low and above as findings; confidence < 50 listed under Leads.

`Completeness: 47 unique (Contract, function) across both phases, 47 covered.`
`Coverage: 33 entrypoints in inventory, 33 addressed. 22 threat rows, 22 answered. 40 inferred invariants, 40 answered. Holes closed this pass: 0.`

---

## Answers to the client's tasks (short form)

### Task 1 — are the root-cause invariants enforced on every path?

| Class | Stated invariant | Verdict | Why |
|---|---|---|---|
| **A** identity, transfers, client code in a bracket | "Whatever client code does inside a module action can only make the books more conservative" | **Not enforced** | Identity, payer and recipient-side verification hold. But an upgraded account can inflate `contributed` without limit inside `increasePosition` (M-1) and inside any removal when two tracked positions exist (M-2). The fee base is the victim, not custody. |
| **B** `sync` owns the snapshot | "After every module call the snapshots equal the live state; every change is booked once" | **Enforced for the write, not for the price** | No path writes a snapshot without booking, and no path books without re-snapshotting. But the closing `_snap` covers only the touched position (M-2), and the booking price is unbounded (H-1). |
| **C** one pinned delegation | "Only the client can replace it or stop it" | **Enforced for replace / resume**; first registration is still any delegation, any caller (L-3) | |
| **D** value at a fresh, banded anchor | "Every value that gates a fee is taken at a recent, unclipped anchor within the band" | **Not enforced** | `contributed` is one side of `profit` and is written at `min/max(anchor, raw pool spot)` on five paths with no band, age or clipped gate (H-1). The hedge step cap is age-gated only (L-2). `hedgeClipped` is cleared by an equal report (L-1). |
| **E** sliding window | "Any 24 h window admits at most 1x the cap" | **Holds** for `charge`. The guardian range adds past the cap by design. The drift bound is `e^cap`, not `cap` (I-1). |
| **F** guardian approvals | "Bound to the judged state, one-shot, voided by a guardian change and a pause" | **Holds** for epoch, stored value, era, TTL, one-shot. **Hedge approvals are not voided by a pause** although the documents say so (L-7). Charging the approved price move to the window creates a new liveness problem (M-4). |
| **G** shared treasury, pause | "Keeper return ≤ the account's own equity; pause stops custody growth" | **Holds.** No path found where the keeper moves value between accounts. |
| **H** exit | "`revoke` cannot fail for the account itself" | **Holds** for both account kinds, with the module paused, the DM paused, a subscriber, any number of positions. One funding caveat for 7702 accounts (I-5). |

### The specific claims the client asked us to break

| Claim | Result |
|---|---|
| "The CREATE2 address commits to the implementation, the owner and the absence of P256 keys at creation, so `owner()` is checked, not believed" | **Holds.** Init-code variants, another salt, another factory and extra keys all give another address. An `owner()` that reverts, burns gas or returns short data gives `BadAccount` / not live. A 32-byte answer with dirty upper bits makes `abi.decode` revert instead of returning false (I-4, self-harm only). An account upgraded after creation keeps passing `live()` — that is the stated residual, and it is the precondition of M-1, M-2 and L-10. |
| "Whatever client code does inside a module action can only make the books more conservative" | **Broken**: M-1 (increase), M-2 (decrease / burn with a second tracked position). Bounded leak on swaps (L-14). Mint is safe (`checkMinted` reads back). Native receive and keeper fee collects are safe. |
| "sync owns the snapshot" | **Holds as stated.** Write sites of `snapAsset` / `snapBase`: `SALib.sol:301-302`, `LPManagerModule.sol:749-750`; of `snapLiquidity`: `SALib.sol:293, 295`, `LPManagerModule.sol:751, 781`. None books without a snapshot or the reverse. The defect is what the *partial* closing snapshot hides (M-2). |
| "Any 24 h window admits at most 1x the cap" (SAWindow) | **Holds.** Bucket edges (exactly 24 h is still counted, 27 h is dropped), ring overwrite (a slot is only reused by an index ≥ 9 older), `credit` (no underflow, same nine buckets), amounts above 2^96 (saturate; unreachable for USDC units and WAD fractions) and timestamp jumps were all traced. |
| "A guardian approval applies only to the state the guardian judged" | **Holds** for epoch / era / stored value, refused reports, multicall ordering and same-block margin moves. Exception: a pause does not void a hedge approval (L-7). |
| "`revoke()` cannot fail for the account itself" | **Holds.** No external call, no guard, no pause check, no loop (`LPManagerModule.sol:343-349`). |

### Task 2 — sibling paths still open (and which class they belong to)

| Sibling | Class | Shape | Finding |
|---|---|---|---|
| Flow booking at unbanded spot / stale anchor | D (via the L-2 fix in B) | **The fix moved the problem**: from "anchor of the moment, exploitable by the client" to "raw spot of the moment, exploitable against the client" | H-1 |
| `increasePosition` records what the keeper asked for, not what PositionManager holds | A (L-13 sibling) | keeper-side check the client's code bypasses | M-1 |
| Proceeds moved into another tracked position inside a removal bracket | A / B (M-5 sibling, root-cause doc A item 8) | the documented "booked at the next sync" is itself the hole | M-2 |
| `onboard` allowance fallback | A (C-1 residual) | consent for an amount is not checked | M-3 |
| Window charge of a guardian range + global clipped flag | E / F | fix introduced a liveness cost | M-4 |
| `hedgeClipped` cleared by an equal report | D (L-12) | client-protecting flag a keeper sequence bypasses | L-1 |
| Hedge step cap gated by age only | D (L-16) | a clipped report refreshes the age | L-2 |
| First registration with any signed delegation | C (M-1) | | L-3 |
| `revoke` + `register` as an on-demand sync | B (L-2) | client-side timing still open | L-9 |
| Fee transfer refused by an upgraded account | A (Rebuttal 4) | | L-10 |
| Swap bracket: output above `minOut` leaves unbooked | A (doc sibling 4) | not listed among the residuals | L-14 |

### Task 3 — rebuttals and acknowledged residuals

| Item | Holds? | Note |
|---|---|---|
| Rebuttal 1 — H-1 bound = hedge equity, not net margin | **Holds** | Equity rises only by a verified send or a guardian approval. |
| Rebuttal 2 — C-1 allowance fallback kept | **Holds on destination, not on consent** | Any caller chooses the amount and the moment; the keeper can do it in a `multicall` and enlarge the base its own bounds scale with (M-3). |
| Rebuttal 3 — enforcer state keyed by terms hash | **Holds** | |
| Rebuttal 4 — no codehash pin; "an upgrade can only harm the upgrading client" | **Does not hold** | Custody is safe, but the operator's fee revenue (M-1, M-2, L-10) and the other entries of a keeper batch (L-4) are affected. |
| Residual — client-collected LP fees | **Holds as stated**; the bound "uncollected fees" is all LP fee income accrued since the keeper last touched each position (I-2). |
| Residual — anchor drift "10% per 24 h plus the band" | **Holds in kind; the numbers are larger** | `e^0.10` = +10.52% / −9.52%; the band is measured against the argument (+1.523% / −1.478%) (L-5, I-1). |
| Residual — "adds: drain bounded by the H-3 add check (slippage)" | **True for mint, false for increase** (M-1). |
| Residual — "removals are now exact (value conservation)" | **False with two or more tracked positions** (M-2). |

---

# Findings

## High

### H-1 — `_sync` books client flows at a pool price with no band, so a displaced spot or a lagging anchor becomes a fee on client principal

**Severity:** High · **Confidence:** 90 · **Origin:** [both] (phase 1: precision-math, general, oracles, dos, access-control, defi-amm, signatures, erc4337 — 8 of 8 agents; phase 2: agents 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 — 11 of 12)
**Location:** `SALib._sync` (`src/sa/SALib.sol:273-290`); callers with no price gate: `LPManagerModule._register` (`src/sa/LPManagerModule.sol:351-354`), `decreasePosition` (`:432`), `burnPosition` (`:451`), `returnHedgeMargin` (`:531`), `reportHedgeEquity` (`:550`); price source `:742`
**Root-cause class:** D, introduced by the L-2 fix (class B). Round-1 L-2 / L-16: **regressed**.

**Description.** The L-2 fix books inflows at the lower of anchor and pool spot and outflows at the higher:

```solidity
// src/sa/SALib.sol:273
(uint256 lo, uint256 hi) = ref < poolP ? (ref, poolP) : (poolP, ref);
// :277
int256 f = int256(x) - int256(s.snapAsset) + signedDelta(b, s.snapBase, b >= s.snapBase ? lo : hi);
// :285
uint256 px = liq > old ? lo : hi;
```

`poolP` is slot0 read in the same call, and nothing bounds it:

```solidity
// src/sa/LPManagerModule.sol:742
SALib.sync(accounts[a], _positions[a], snapLiquidity, a, venue, lastPrice, poolPrice());
// :353
SALib.register(accounts, permissionContext, _positions, snapLiquidity, venue, d, _expect(), lastPrice, poolPrice());
```

Mint, increase and swap check the band first (`_checkKeeperPrice`); fee and send use `_fresh`. Decrease, burn, `returnHedgeMargin`, `reportHedgeEquity` and registration check nothing — and all of them run while the module is paused. `contributed` is written only here (`SALib.sol:304`) and is one side of the fee base:

```solidity
// src/sa/LPManagerModule.sol:575
int256 profit = int256(accountValue(a, lastPrice)) - s.contributed;
```

The client can never gain from the rule (an inflow is booked at ≤ anchor, an outflow at ≥ anchor). Every gap is booked against the client, permanently, and is charged at `feeBps` once the anchor is fresh again. The root-cause document calls the rule "conservative for the operator" and assumes the gap is about one band; on these paths it is unbounded. Invariant D ("every value that gates a fee … within the band") is not enforced for `contributed`.

**Exploit path 1 — keeper, one transaction (exceeds the keeper's stated bound).** Anchor 30 USDC/HYPE, `feeBps` 1500. The account holds 100,000 USDC and 1,000 HYPE; `contributed` = 130,000; `hwm` = 0.
1. The client withdraws 10 HYPE directly (a true outflow of 300 USDC). For a 7702 account, ordinary gas spending is the same kind of outflow.
2. The keeper key (as a contract, or an EOA with EIP-7702 code, so `msg.sender == keeper`) calls `PoolManager.unlock`. Inside it: swap spot to 30,000 USDC/HYPE → `reportHedgeEquity(a, <stored equity>)` → swap back → settle. `reportHedgeEquity` only requires registration (`:549`); with an equal value it changes no hedge state and is purely a sync. Flash accounting means the cost is the pool fee on the round trip.
3. `_sync`: `hi = 30e9`, `f = −ceil(10e18 · 30e9 / 1e18) = −300,000e6`. `contributed` = −170,000.
4. A week later, honest anchor, pool in band, `_fresh` passes: `profit = 129,700 − (−170,000) = 299,700`. Fee = min(15% × 299,700, 20% of idle = 20,000) = **20,000 USDC on zero real profit**. `hwm` advances only by the gain charged (113,333), so the 20% slice repeats every `feeInterval`.
5. One push re-books every account with a pending base or liquidity flow in the same `multicall`.

The inflow mirror: push spot down before a sync that sees a HYPE deposit — the deposit is booked near zero and its whole value becomes "profit".

**Exploit path 2 — whoever submits the first registration.** `register` / `onboard` are permissionless on first registration and need only `lastPrice != 0`. A 7702 EOA holds 1,000 HYPE and 10,000 USDC; anchor 30. The submitter (the relayer always holds the signed delegation) wraps `register(d)` in a swap that pushes spot to 15: `contributed = 10,000 + 1,000 × 15 = 25,000` against a value of 40,000. After 7 days: profit 15,000 → fee 2,000 (cap), then 250 the week after. Cost: two 0.3% swaps.

**Path 3 — no attacker at all.** The anchor lags by design (10.5% per 24 h) and is frozen during a pause (minimum 24 h, because only the timelock unpauses). HYPE moves 30 → 39; the anchor is at 33.16 (clipped) or 30 (paused). A client deposits 1,000 HYPE (39,000 USDC of value); the keeper's routine `reportHedgeEquity` books it at 33,160 (or 30,000). When the anchor reaches 39 the books show 5,840 (or 9,000) of profit that was never earned: **876 to 1,350 USDC of fee with an honest keeper.** A client that burns its own LP directly and keeps the tokens is booked `−(base part) × gap` for an operation that changes no value.

**Why High and not Critical or Medium.** A client loses real USDC, up to the enforcer's own backstop (20% of idle USDC per 7 days, repeating), on principal — the module's fee bound "feeBps of profit above the mark" is defeated and only the enforcer's limit remains. The keeper hot key alone triggers it; no guardian or owner is needed; and the honest-path variant needs nobody. It is not Critical because the proceeds go to the immutable `feeRecipient` (an operator address), so a thief holding only the keeper key gains nothing directly, and the operator can refund.

**Recommendation (smallest change).** Clamp the pool term into the anchor band before the min/max. No path reverts, so removals, returns and registration stay live:

```diff
-        (uint256 lo, uint256 hi) = ref < poolP ? (ref, poolP) : (poolP, ref);
+        // `band` = params.poolBandBps, passed in by every caller (LPManagerModule._sync and _register)
+        uint256 bl = Math.mulDiv(ref, BPS - band, BPS);
+        uint256 bh = Math.mulDiv(ref, BPS + band, BPS);
+        poolP = poolP < bl ? bl : (poolP > bh ? bh : poolP);
+        (uint256 lo, uint256 hi) = ref < poolP ? (ref, poolP) : (poolP, ref);
```

This caps the misbooking at one band per flow and closes paths 1 and 2. **It does not close path 3**: with a stale, clipped or frozen anchor the clamp books at about the anchor while the market is elsewhere. To close that, do not price base or liquidity deltas while the anchor is clipped, older than `maxPriceAge` or out of band: carry them as pending quantities, price them at the first sync with a fresh in-band anchor, and make `chargeFee` revert while anything is pending. Add a regression test that syncs at a displaced spot on each of the five paths — none exists today (`test_M4_Sibling_BandAndAgeOnEveryValuePath` covers only send and fee).

---

## Medium

### M-1 — `increasePosition` values the liquidity the keeper asked for and never reads it back: an upgraded account takes the whole add amount out unbooked

**Severity:** Medium · **Confidence:** 90 · **Origin:** [both] (phase 1: erc4337+proxies; phase 2: agent 5 invariant)
**Location:** `LPManagerModule.increasePosition` (`src/sa/LPManagerModule.sol:399-423`), `_checkAdd` (`:811-816`), `SALib.addCharge` (`src/sa/SALib.sol:522-530`)
**Root-cause class:** A (sibling of L-13 and M-5). The residual "adds are bounded by the H-3 add check (slippage)" is false for this function.

**Description.** After a mint, `SALib.checkMinted` requires `getPositionLiquidity(tokenId) == liquidity`. After an increase there is no read-back, and the add check values the *requested* liquidity:

```solidity
// src/sa/LPManagerModule.sol:420-421
_checkAdd(a, v0, ref, nav, p.tickLower, p.tickUpper, liquidity);
_snap(a, tokenId);
// src/sa/SALib.sol:527-528
uint256 got = V4PositionMath.liquidityValue(tl, tu, liquidity, ref, baseIsCurrency0);
if (got * BPS < paid * (BPS - slip)) revert AddValue(got, paid);
```

For a canonical account PositionManager adds exactly `liquidity` or reverts. For an upgraded HybridDeleGator, `executeFromExecutor` is client code (`test/sa/SAHostile.sol` shows the shape) and `live()` still passes because `owner()` still returns the pinned owner.

**Proof of concept.** Idle 100,000 USDC + 1,000 HYPE, anchor 40; the keeper calls `increasePosition(a, id, L, 250e18, 10_000e6, p)` where L is worth 20,000.
1. The hostile implementation skips the `modifyLiquidities` execution and sends 10,000 USDC and 250 HYPE to the owner.
2. `_postAdd` passes (the falls equal the maxima). `paid = v0 − v1 = 20,000`; `got = liquidityValue(L) = 20,000`; `_checkAdd` passes. Turnover is charged 10,000.
3. `_snap(a, id)` writes the reduced idle balances and the unchanged liquidity. No `_sync` ever sees the 20,000 as an outflow.
4. `contributed` is unchanged, value is down 20,000, so `profit` is down 20,000. The client deposits the 20,000 back: `contributed` +20,000, value restored. Net: `contributed` inflated by 20,000 with no capital added.
5. Repeats on every keeper increase. `chargeFee` returns 0 for as long as the client wants; the client can restore the canonical implementation afterwards and nothing records the upgrade.

The loss is the operator's fee on that account (at 15%, 3,000 USDC per 20,000 cycle). No third-party funds move.

**Recommendation.**

```diff
+        uint128 l0 = positionManager.getPositionLiquidity(tokenId);
         _modify(
             a, V4PositionMath.increaseData(tokenId, liquidity, amount0Max, amount1Max, currency0, currency1, a), amount0Max, amount1Max
         );
+        if (positionManager.getPositionLiquidity(tokenId) - l0 != liquidity) revert SALib.BadMint();
         _postAdd(a, amount0Max, amount1Max);
```

Combine with the M-2 check, otherwise the same code can put the add amount into another tracked position instead of sending it away.

### M-2 — A removal's closing snapshot covers only the touched position: proceeds moved into another tracked position are booked as a new contribution

**Severity:** Medium · **Confidence:** 85 · **Origin:** [both] (phase 1: general, erc4337+proxies; phase 2: agent 4 execution-trace, agent 10 numerical-gap)
**Location:** `LPManagerModule.decreasePosition` (`src/sa/LPManagerModule.sol:437-440`), `burnPosition` (`:456-460`), `_snap` (`:747-752`), `_conserved` (`:761-763`); `SALib._sync` (`src/sa/SALib.sol:284-290`), `_post` (`:316-320`)
**Root-cause class:** A / B (open sibling of M-5 and of root-cause doc A item 8). The residual "removals are now exact" is false with two or more tracked positions.

**Description.** The root-cause document says: "The closing snapshot covers only the position the action touched, so a change to any other tracked position inside the bracket is still booked as a flow at the next sync." That deferred booking is the hole when the change is funded by the module's own proceeds:

```solidity
// src/sa/LPManagerModule.sol:747-752
s.snapAsset = asset.balanceOf(a);
s.snapBase = _balanceOf(_baseToken(), a);
if (tokenId != 0) snapLiquidity[tokenId] = positionManager.getPositionLiquidity(tokenId);
```

Inside the redemption, after the PositionManager call returns (PositionManager is no longer locked — `modifyLiquidities` is `isNotLocked`, `lib/v4-periphery/src/PositionManager.sol:172-177`), an upgraded account calls `modifyLiquidities` itself and increases tracked position B with the proceeds.
- `_post(a, 0, 0)` passes: idle is not below the pre-action snapshot.
- `_conserved` passes: `accountValue(a, pp)` reads B's live liquidity.
- `_snap` records idle (no rise) and leaves `snapLiquidity[B]` stale.
- The next `_sync` sees `liq > old` for B and adds `liquidityValue(ΔB, lo)` to `contributed`. The matching idle outflow was absorbed by `_snap` and is never booked.

Done outside a bracket the same move nets to about zero (idle outflow against liquidity inflow). Inside the bracket only the inflow half is booked.

**Proof of concept.** Positions A and B, 50,000 each; idle 0; `contributed` = 100,000.
1. Keeper: `burnPosition(a, A, 0, 0)`. Proceeds of 50,000 arrive; the account's code adds them to B.
2. `_post`: idle 0 ≥ snapshot 0. `_conserved`: B is now worth 100,000 ≈ `v0`. `_snap(a, 0)`.
3. Next keeper touch: `_sync` books +50,000. `contributed` = 150,000, value 100,000, profit −50,000. At `feeBps` 1500 the operator loses 7,500 of fee per cycle, and the inflation compounds on every keeper removal (including a zero-liquidity fee collect).

Preconditions: hybrid account with an upgraded implementation, at least two module-minted positions (`MAX_POSITIONS` is 4), a keeper removal. 7702 accounts cannot run code in a bracket. On mint and swap the same move is limited to the slippage slack.

**Recommendation.** At the end of every redeeming bracket, require every tracked position other than the touched one to still have the owner and the liquidity recorded in `snapLiquidity` (at most three reads; put the loop in `SALib` to stay under EIP-170):

```diff
         _post(a, 0, 0);
         _conserved(a, pp, v0);
+        // new SALib helper: revert when the owner or the liquidity of any tracked position other than `tokenId` differs from snapLiquidity
+        SALib.othersUnchanged(_positions[a], snapLiquidity, positionManager, a, tokenId);
         _snap(a, tokenId);
```

(`burnPosition`: same line with `0` for the token id, after `_removeAt`.) Apply it in `mintPosition`, `increasePosition`, `swap`, `sendHedgeMargin` and `chargeFee` too; it costs nothing for honest accounts.

### M-3 — `onboard` lets any caller spend the pinned owner's standing USDC allowance, for any amount, at any time (Rebuttal 2)

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase1: signatures (Medium), general+erc20 (Low), access-control (Low), erc4337+proxies (Low)]
**Location:** `LPManagerModule.onboard` (`src/sa/LPManagerModule.sol:320-332`), `deposit` (`:335-339`); no-op path `SALib.sol:231`
**Root-cause class:** A (C-1 residual). C-1: **partly fixed**.

**Description.**

```solidity
// src/sa/LPManagerModule.sol:330-331
try IERC20Permit(address(asset)).permit(o, address(this), amount, deadline, v, r, s_) {} catch {}
asset.safeTransferFrom(o, a, amount); // booked as a contribution at the next sync
```

The permit is the only thing that ties the owner's consent to an amount, and its failure is ignored. The stored delegation is public (`permissionContext(a)`), and passing it makes `_register` a no-op (`if (old == h && !s.revoked) return;`). So anyone can call `onboard(storedDelegation, X, 0, 0, 0, 0)` and move up to `allowance(owner, module)` from the owner's wallet into the managed account. `onboard` has no pause gate.

Who has a standing allowance: any owner who used `deposit` — the module's own function, which needs one — with an approval larger than the deposit (commonly unlimited), and the remainder of a permit that was submitted to USDC directly.

Rebuttal 2 ("the worst case is moving the owner's USDC into the owner's own account") is right about the destination. It is not a custody statement: the hedge cap (35% of account value), the 20%-of-idle fee cap and the turnover budget all scale with the account balance, so the *caller* decides how much client capital those bounds apply to. The keeper can do it in one transaction, because `multicall` reaches `onboard` with the keeper as an ordinary caller.

**Proof of concept.** Owner O onboarded 10,000 USDC, later approved the module for `type(uint256).max` and called `deposit(A, 1_000e6)`; O's wallet still holds 100,000.
1. Keeper: `multicall([onboard(d, 100_000e6, 0, 0, 0, 0), sendHedgeMargin(A, x)])`. The permit reverts and is swallowed; `transferFrom(O, A, 100_000e6)` succeeds.
2. The hedge cap is now 35% of about 111,000 instead of 35% of about 11,000: about 38,800 USDC can go to the shared treasury instead of about 3,850 (subject to a fresh anchor and the enforcer's 35%-of-idle window).

The pull is blocked after `revoke`, after `disableDelegation`, in the delegation's last day, and for 7702 accounts. The web flow tops up by plain transfer and exact-amount permit, so exposure today is limited to manual approvals — hence Medium, not High.

**Recommendation.** Take the allowance fallback only when the caller is the client, or when the allowance is exactly what a front-run permit would have produced:

```diff
-        try IERC20Permit(address(asset)).permit(o, address(this), amount, deadline, v, r, s_) {} catch {}
+        try IERC20Permit(address(asset)).permit(o, address(this), amount, deadline, v, r, s_) {} catch {
+            if (msg.sender != o && msg.sender != a && asset.allowance(o, address(this)) != amount) revert NotOwnAccount();
+        }
```

### M-4 — A one-unit unapplied anchor move sets the global clipped flag, and a guardian-approved move saturates the window: fees and margin sends stay blocked for 24–27 h

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase1: dos (Medium), oracles (Low)]
**Location:** `SALib.movePrice` (`src/sa/SALib.sol:431-448`), `LPManagerModule.reportPrice` (`src/sa/LPManagerModule.sol:360-368`), `_fresh` (`:795-798`), `_checkKeeperPrice` (`:801-807`)
**Root-cause class:** E / F — a new liveness problem introduced by the fix that charges the guardian range to the window (the client's Task 1 question 3).

**Description.** The guardian-range path adds the whole approved move to the window with no cap:

```solidity
// src/sa/SALib.sol:434-440
if (block.timestamp <= b.until && p >= b.lo && p <= b.hi) {
    b.until = 0;
    SAWindow.add(b.window, move);
    return (p, false);
}
uint256 room = SAWindow.room(b.window, capWad);
bool clipped = move > room;
```

Once `used >= cap`, `room == 0` for the next 24–27 h. Any later report with `price != lastPrice` — even by one raw unit — returns `clipped = true` with the anchor unchanged; `reportPrice` stores the flag (`:366`) and `_fresh` reverts `StalePrice` on it (`:796`), which stops `sendHedgeMargin` and `chargeFee`. The same happens with no guardian once ordinary reports have used the 10% (charges are gross both ways, so oscillation consumes it). The flag does not measure distance from the market: a fresh, in-band anchor one unit off the reported price is treated like one that is 10% off.

The only way to clear the flag without the guardian is to report exactly `lastPrice`, which works only while the pool is within `poolBandBps` of the stored anchor. Beyond that, `_fresh` fails on both the flag and the band, and beyond about two bands no `keeperPrice` satisfies both halves of `_checkKeeperPrice`, so `swap`, `mintPosition` and `increasePosition` revert too. Each further guardian approval adds to the window and extends the saturation.

**Proof of concept (defaults: drift 1000 bps, band 150).** HYPE moves +25% in a few hours.
- Without the guardian the anchor needs ln(1.25)/0.10 = 2.23 windows: 48–54 h at the earliest. For every account at once: no swap, mint, increase, margin send or fee. Only decrease, burn and return work.
- With one guardian range: unblocked once; then a further 2% move inside the next 24–27 h re-clips and blocks sends until another signature.
- The short hedge is losing about 25% of notional in the same period and cannot be topped up from the account — liquidation risk at the venue, which lands in the client's `hedgeEquity`.

A pool manipulator can also trip the band half of `_fresh` by holding spot more than 1.5% from the anchor (griefing, with a running arbitrage cost).

**Recommendation.** Drop `lastPriceClipped` from `_fresh` (the band check already expresses "the anchor is near the pool"), or set the flag only when the applied price ends outside the band of the reported price. Charge a guardian-approved move at `min(move, room)` so one approval does not zero the keeper's room for a day, and consume the range only when `move > room` (see I-7).

---

## Low

### L-1 — `hedgeClipped` is cleared by re-reporting the stored value (L-12 partly fixed)
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] (phase 1: general, oracles; phase 2: agents 3, 4, 5, 11, 12 as leads)
**Location:** `SALib.moveHedge` (`src/sa/SALib.sol:478-481`); gate `LPManagerModule.sol:571` · **Class:** D
```solidity
if (v >= old) {
    s.hedgeClipped = false;
    return (old, v != old);
}
```
After a clipped decrease (stored 25,000, real 20,000, flag true, `chargeFee` reverts `StaleHedge`), a report of 25,000 takes this branch: flag cleared, `hedgeTime` refreshed, and the fee is charged with 5,000 of equity that does not exist (750 USDC at 15%). A keeper bot that sends an "unchanged" refresh before a fee clears it by accident. A keeper that never reports the loss gets the same result, so the flag only protects against an honest keeper's mistake — weaker than the stated rule "not clipped downward". **Fix:** do not clear the flag in the `v >= old` branch; clear it only by an unclipped decrease or a guardian approval.

### L-2 — The keeper-only hedge step cap is gated by anchor age only, and a clipped report refreshes the age (L-16 partly fixed)
**Severity:** Low · **Confidence:** 75 · **Origin:** [phase1: oracles]
**Location:** `LPManagerModule.reportHedgeEquity` (`src/sa/LPManagerModule.sol:552-554`), `reportPrice` (`:365`) · **Class:** D
`cap = paused || block.timestamp > lastPriceTime + params.maxPriceAge ? 0 : accountValue(a, lastPrice) × hedgeStepBps`. `lastPriceTime` is written on every report, including a fully clipped one whose stored value did not move. After a 40% fall (anchor clipped 50.8% above spot) an account with 60,000 of real HYPE exposure and 40,000 USDC is valued at 130,500 instead of 100,000: step cap 6,525 instead of 5,000 per 24 h, 30% above the stated bound on erasing a client's recorded claim. **Fix:** use the `_fresh` conditions (clipped, age, band) for this cap.

### L-3 — First registration accepts any delegation the client ever signed, and the client cannot cancel one before it is registered (M-1 partly fixed)
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: signatures, dos, access-control]
**Location:** `SALib.register` (`src/sa/SALib.sol:231-232`), `LPManagerModule.revoke` (`src/sa/LPManagerModule.sol:343-346`) · **Class:** C
The client-only rule applies when `old != 0`. For a never-registered account, any holder of any still-enabled signed delegation (any salt, any expiry) starts management and the fee clock, and chooses which delegation is stored; the relayer's later `onboard(d2, …)` then reverts `NotOwnAccount` until the owner sends a transaction. `revoke` reverts `NotRegistered` before registration, so the only cancel is `DelegationManager.disableDelegation` (for an undeployed hybrid: deploy first). For a 7702 client this puts the whole wallet balance under management at a moment the holder picks, and at the H-1 booking price. **Fix:** let the derived owner call `revoke` before registration (a tombstone), or restrict first registration to the account, the derived owner or a relayer role.

### L-4 — `multicall` copies the full revert data before truncating it and has no per-entry gas bound (L-3 partly fixed; Rebuttal 4)
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: signatures+assembly, general, dos, access-control, erc4337+proxies]
**Location:** `LPManagerModule.multicall` (`src/sa/LPManagerModule.sol:590-607`) · **Class:** H / A
```solidity
(bool ok, bytes memory r) = address(this).delegatecall(data[i]);
...
if gt(mload(r), 256) { mstore(r, 256) }
```
The whole returndata is already in memory when the length is cut, so the response's "copied ≤ 256 bytes" is not what the code does. Each redemption reaches client code (`isValidSignature`, `executeFromExecutor`) with 63/64 of the gas. An upgraded account that burns gas or returns megabytes leaves 1/64 for the remaining entries, so the whole batch runs out of gas despite `allowFailure = true` — and it can behave well under `eth_call` and badly on chain, so "re-send without that entry" works only after a paid failure. Risk-reducing burns for other clients in the batch are delayed. **Fix:** `delegatecall{gas: cap}` with a `gasleft()` floor, and `returndatacopy(ptr, 0, min(returndatasize(), 256))` in assembly.

### L-5 — `_checkPoolBand` measures the band against the argument, not the pool
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: precision-math, oracles]
**Location:** `LPManagerModule._checkPoolBand` (`src/sa/LPManagerModule.sol:787-792`) · **Class:** D
`if (d * BPS > price * params.poolBandBps) revert` accepts `pool/(1+band) ≤ price ≤ pool/(1−band)`: +1.523% / −1.478% at 150 bps, +5.263% / −4.762% at the 500 bps hard cap. A USDC→HYPE swap's min-out can therefore sit 5.26% + slippage below spot value at the cap. **Fix:** `d * BPS > p * params.poolBandBps`.

### L-6 — Role distinctness is not enforced on the ownership-transfer path (L-8 partly fixed)
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] (phase 1: access-control, general; phase 2: agent 2 lead)
**Location:** `LPManagerModule._distinct` (`src/sa/LPManagerModule.sol:676-681`); inherited `transferOwnership` / `acceptOwnership` · **Class:** G
`_distinct` runs only in `setKeeper` / `setGuardian` and checks `owner()` but not `pendingOwner()`. `transferOwnership(keeper)` + `acceptOwnership()` makes the hot key the owner (instant `setParams`, `setGuardian`, unpause); `transferOwnership(P)`, `setKeeper(P)`, `P.acceptOwnership()` reaches the same state through the setters. It needs a timelocked operation. **Fix:** override `transferOwnership` to call `_distinct(newOwner)` and add `x == pendingOwner()` to `_distinct`.

### L-7 — Hedge-equity approvals survive a pause, although invariant F and the design document say a pause voids them
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: access-control]
**Location:** `LPManagerModule.setPaused` (`src/sa/LPManagerModule.sol:642-651`), `reportHedgeEquity` (`:547-557`); `SALib.moveHedge` (`src/sa/SALib.sol:462-477`) · **Class:** F
`setPaused(true)` clears only `priceBudget.until` (`:645`). `reportHedgeEquity` is not paused and evaluates the approval branch before the paused cap. A guardian that approved values for several accounts and then pauses because the keeper key is compromised leaves those approvals usable for up to 24 h; there is no revoke function, and the keeper can block an overwrite by bumping the epoch with a 1-unit return. The values are ones the guardian chose, hence Low. **Fix:** `guardianEra++` in `setPaused(true)` (one SSTORE), or correct the two documents.

### L-8 — `DeploySA` leaves preconditions unchecked (L-8 partly fixed)
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase1: access-control, general, erc4337+proxies]
**Location:** `script/DeploySA.s.sol:47-51`, `:60-79`, `:88` · **Class:** G
Not checked: the pool is initialised and has liquidity before the first `reportPrice` (the first report is free and bounded only by the band around a spot anyone can move); code hashes of the pre-existing DelegationManager, 7702 implementation, TimestampEnforcer, hybrid implementation and factory (`_create2` returns when `expected.code.length != 0`); `DelegationManager.paused()`; `SALib.hybridAddress` against `SimpleFactory.computeAddress` (a mismatch makes every hybrid registration revert); the treasury allowance; `TIMELOCK_DELAY <= 30 days` (caught only by the constructor, after the gator deployments are broadcast). The script's role checks apply to the operator EOA while the constructor's apply to the timelock address. **Fix:** add the `require`s and a one-owner derivation self-check.

### L-9 — `revoke` + `register` is still an on-demand sync for the client, and a same-transaction spot push collapses `max` to a lagging anchor (L-2 partly fixed)
**Severity:** Low · **Confidence:** 65 · **Origin:** [phase1: oracles]
**Location:** `SALib.register` (`src/sa/SALib.sol:231-233`), `LPManagerModule.revoke` (`src/sa/LPManagerModule.sol:343-349`) · **Class:** B / D
The no-op rule applies only while not revoked, so the account can batch: withdraw HYPE → push spot down to the lagging anchor → `revoke` → `register(sameDelegation)` → push back. The outflow is booked at the anchor (33.16) instead of spot (34.65); when the anchor has caught up the client redeposits and is booked at 34.65. On 10,000 HYPE that is +14,900 of `contributed` with no capital change (2,235 USDC of fee shielded) for about 100 USDC of swap fees. Operator fee loss only; needs an anchor lag. **Fix:** with the H-1 "pending while not fresh" rule this closes; otherwise skip `_sync` on a client re-register after `revoke` and let the next keeper sync book it.

### L-10 — An upgraded account can refuse only the fee transfer and stay managed (Rebuttal 4)
**Severity:** Low · **Confidence:** 70 · **Origin:** [both] (phase 1: dos, erc4337+proxies; phase 2: agent 9 boundary)
**Location:** `SALib.live` (`src/sa/SALib.sol:207-211`), `transferOut` (`:645`); `LPManagerModule.chargeFee` (`src/sa/LPManagerModule.sol:579`) · **Class:** A
An implementation that executes every PositionManager and SwapExecutor call faithfully but reverts on `USDC.transfer(feeRecipient, …)` makes every `chargeFee` revert while `live()` stays true and the keeper keeps rebalancing and hedging the account. Nothing on-chain makes an overdue fee stop service. Economically it resembles "revoke just before the fee is due", but without leaving management. **Fix:** keeper policy (stop managing an account whose fee reverts; the implementation slot is readable off-chain), or a per-account overdue rule that blocks adds and swaps.

### L-11 — The no-op re-registration path still runs every delegation check, so `onboard` top-ups revert in the delegation's last day
**Severity:** Low · **Confidence:** 90 · **Origin:** [phase1: signatures, dos, erc4337+proxies]
**Location:** `SALib.checkDelegation` (`src/sa/SALib.sol:149-152`), `register` (`:227-231`) · **Class:** C
`checkDelegation` runs before `if (old == h && !s.revoked) return;`, so for the stored delegation `until < block.timestamp + e.minLifetime` reverts `BadDelegation(6)` with less than a day left. Keeper actions still work until `until`; `deposit` is unaffected. **Fix:** return early for the stored, non-revoked hash before the lifetime check.

### L-12 — Keeper removals depend on a DelegationManager pause held by a third party
**Severity:** Low · **Confidence:** 60 · **Origin:** [phase1: dos, erc4337+proxies]
**Location:** `SALib._redeem` (`src/sa/SALib.sol:553-563`); `LPManagerModule.decreasePosition` / `burnPosition` (`src/sa/LPManagerModule.sol:426-462`) · **Class:** G / H
The removals the module deliberately keeps open during its own pause go through `redeemDelegations`, which the canonical DM's owner can pause (from memory of the framework; consistent with the repo's exit tests). That owner is the framework deployer's address, not the operator. Clients are not locked — the direct exit does not redeem — but out-of-range positions stay in the pool while the keeper can only close hedges. **Fix:** none in the contracts; verify who controls the DM owner on chain 99901 and write the runbook ("on DM pause, clients exit directly").

### L-13 — Every keeper add or swap overwrites and zeroes the client's own token → Permit2 approval; the Permit2-side allowance lives to the end of the timestamp
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase1: signatures, general+erc20, dos+chain, defi-amm]
**Location:** `SALib._permit2Approve` (`src/sa/SALib.sol:533-545`), `modify` (`:587-598`), `swapVia` (`:621-624`); `ElysiumCustodyEnforcer.sol:311` · **Class:** A (side effect of the L-17 fix)
For a 7702 account — the user's ordinary wallet — `approve(Permit2, amount)` … `approve(Permit2, 0)` destroys any standing USDC → Permit2 approval the user relies on for other apps. Separately, `expiration = uint48(block.timestamp)` is valid while `block.timestamp <= expiration` (`lib/v4-periphery/lib/permit2/src/AllowanceTransfer.sol:79`), and Nitro produces several blocks per second, so the unused remainder is not "this block only" as the enforcer comment says. It is not exploitable: the ERC-20 allowance behind it is 0 and both spenders pull only from their own caller. **Fix:** document for 7702 clients; append `Permit2.approve(token, spender, 0, 0)` (the enforcer allows amount 0); correct the comment.

### L-14 — Swap bracket: account code keeps the output above `minOut` (or unspent input) unbooked
**Severity:** Low · **Confidence:** 70 · **Origin:** [both] (phase 1: defi-amm; phase 2: agent 8 asymmetry lead)
**Location:** `LPManagerModule.swap` (`src/sa/LPManagerModule.sol:488-494`) · **Class:** A (root-cause doc sibling 4)
`out` only needs to be ≥ `minOut`, and `_post` allows the input side to fall by `amountIn`. An upgraded account receiving 3,988 USDC for 100 HYPE (`minOut` 3,940) can forward 48 USDC inside the bracket; the snapshot hides it. Up to about 1.2% of swap notional per swap (about 2.4% of account value per day at full turnover) leaves the fee base. This is the same residual the client acknowledges for adds, but it is not listed for swaps. **Fix:** have `SwapExecutor` expose the last output per payer in transient storage and require the account delta to equal it; or list it as a residual.

### L-15 — Swaps take no keeper-supplied minimum or deadline, and turnover is charged on the full `amountIn`
**Severity:** Low · **Confidence:** 70 · **Origin:** [phase1: defi-amm]
**Location:** `LPManagerModule.swap` (`src/sa/LPManagerModule.sol:480-485`) · **Class:** new (adjacent to L-15 / I-3 of round 1)
The only way to tighten `minOut` is to bias `keeperPrice`, which must stay within the band of the anchor. With spot at the favourable band edge (anchor × 1.015) a sale cannot quote above spot, so an honest keeper's swap accepts a full 1.5% below spot, and the price limit sits about 3% away. A sandwicher keeps about 1.2% per swap — inside the stated "band + slippage" bound, but the keeper cannot reduce it. **Fix:** add a `minOut` argument and use `max(argument, computed floor)`; optionally a deadline.

### L-16 — The anchor can be walked, a fee charged and the anchor walked back in one transaction (M-7 residual, sharper than stated)
**Severity:** Low · **Confidence:** 65 · **Origin:** [phase1: defi-amm, oracles]
**Location:** `LPManagerModule.reportPrice` (`src/sa/LPManagerModule.sol:360-368`), `_fresh` (`:795-798`), `chargeFee` (`:564-585`) · **Class:** D / E
`_fresh` accepts an anchor written earlier in the same transaction (age 0). In one keeper transaction: buy the pool to 41.4 → `reportPrice(41.99)` (+4.98%, unclipped) → `chargeFee` for every due account → sell back → `reportPrice(40)` (total under the 10% window). An account with 50,000 USDC of HYPE exposure pays about 373 USDC on phantom profit, with no arbitrage exposure for the keeper and no clawback. `feeRecipient` gains; a thief holding only the keeper key does not. **Fix:** in `_fresh`, also require `block.timestamp > lastPriceTime`.

---

## Informational

- **I-1 — The drift bound is `e^cap`, and the documents disagree.** `SALib.movePrice` (`src/sa/SALib.sol:431-448`) sums `|Δ|/min` per step, so split reports compound: +10.52% / −9.52% at 1000 bps, +22.14% / −18.13% at the 2000 bps hard cap. The root-cause document says `e^{±cap}`; the response says "10% per 24 h". With the band (L-5) a walked anchor is up to +12.2% above market: 0.92% of account value in fee for an account with 50% base exposure. The clip formulas, rounding direction and cost symmetry are sound. [phase1: precision-math, oracles]
- **I-2 — Client-collected LP fees: the acknowledged leakage is all LP fee income since the keeper last touched a position.** A client that collects before each weekly `chargeFee` shields all of it; a transferred-out NFT's uncollected fees also leave value unbooked (`SALib.sol:284-290` books principal only). Operational mitigation: the keeper collects (`decreasePosition(…, 0, 0, 0)`) immediately before `chargeFee` in the same multicall. [both: defi-amm, precision-math; agent 3]
- **I-3 — Keeper and guardian are not excluded as account owners, contrary to the root-cause document.** `SALib.sol:182` excludes only `hedgeTreasury` and `feeRecipient`, and only on the hybrid branch; the document says four roles. No exploit found. Fix the document or the code. [both: four phase-1 agents; agent 7]
- **I-4 — `ownerOf` reverts on a dirty-bit answer.** `abi.decode(r, (address))` (`SALib.sol:201`) reverts on a non-canonical address word, so `live()` and the `isActive` view revert with empty data instead of `NotLive` / `false`. Only an upgraded account can cause it and only for itself. Use a masked decode. [phase1: signatures, dos, erc4337]
- **I-5 — The keeper can spend a 7702 account's whole native balance.** HYPE is both the base token and the EOA's gas token; after `swap(a, true, a.balance, p)` the client needs outside HYPE or a sponsor to send `revoke`. Invariant H has a funding dependency for this account kind. Consider a small native reserve for `KIND_EIP7702`. [phase1: general]
- **I-6 — A hostile guardian can hold the module paused for two timelock delays, and the NatSpec rotation order is wrong.** The guardian holds `CANCELLER_ROLE` (`src/VaultTimelock.sol:48`) and can cancel `setPaused(false)`, `setKeeper` and `setGuardian` (not self-operations, `:131`). `cancel` works on waiting operations, so step 2 of the documented rotation survives only if it is scheduled after step 1 has executed. Client exits stay open. Module guardian and timelock canceller remain separate slots. [both: dos, access-control; agent 2]
- **I-7 — The one-shot price range is consumed by any in-range report, including a zero move.** `SALib.sol:434-437` precedes the room test, so a routine `reportPrice(lastPrice)` burns the approval; `approvePrice` also accepts an `until` in the past (`LPManagerModule.sol:613`). Consume the range only when `move > room`. [phase1: dos, oracles]
- **I-8 — Rotating a hybrid owner is a permanent exit from the module for that address.** `live` is false, `register` reverts `BadAccount` for every caller because the new owner does not re-derive the address, and the stale pinned owner keeps `revoke` (its only power). `returnHedgeMargin` and `deposit` keep working. State it in the client-facing text. [phase1: dos, access-control]
- **I-9 — No sequencer-outage or keeper-deadline handling.** After downtime shorter than `maxPriceAge` both pool and anchor are stale but "fresh"; the first keeper transaction can trade or charge at pre-outage prices. Unchanged from round 1 (I-3 / I-8). [phase1: dos, oracles]
- **I-10 — `_conserved` tolerance.** `v0 / 100_000 + 2` scales with the whole account value, not the position touched: account code can take 0.001% of the account per keeper removal unbooked (dust). Honest rounding can reach 3 raw units, so a removal on an account under 0.10 USDC can revert. The low-resolution price (about 7.5 significant digits) does not hurt the check — the error is second order. [both: precision-math, oracles, defi-amm; agent 10]
- **I-11 — Design notes.** (a) `transferOut`'s exact-delta check and `SAWindow.add`'s saturation at 2^96 − 1 (`src/sa/SAWindow.sol:51`) are sound for USDC units and WAD fractions. (b) A guardian-approved equity below the stored value writes `netMargin` down and so lowers the hedge-cap base (by design, L-4 of round 1); the enforcer's 35%-of-idle window still applies. (c) A client can revoke before the first `feeInterval` and move to a new account with a new owner; this is the same economics as the accepted "revoke before the fee" and needs an operator rule, not code. [phase2: agents 2, 3]

---

## Leads (confidence below 50 — plausible, not confirmed)

- **Removal value conservation is checked only at pool spot.** `_conserved` (`src/sa/LPManagerModule.sol:761-763`) uses `pp`. With spot away from the anchor, an upgraded account can send out the HYPE proceeds of a removal and bring in `x × pp` USDC; both checks pass and the books at the anchor fall by `x × |anchor − pp|`. At a normal 1.5% gap this is a mark difference that disappears when the anchor converges; it becomes fee evasion only if the client holds spot displaced around the keeper's transaction (not atomic for the client). Confidence 45. Cheap hardening: check conservation at both `pp` and `lastPrice`. [phase1: defi-amm]
- **Positional use of a keeper batch.** Code in an upgraded account's `executeFromExecutor` runs inside the keeper's transaction and can trade the pool with outside funds ahead of the next entries, which then fill up to band + slippage worse. Inside the stated bound; not walked with values. Confidence 40. [phase1: erc4337+proxies]
- **Pinned owner after an account changes hands.** If owner E hands a hybrid account to M and M upgrades it so that `owner()` still returns E, `onboard` keeps pulling from E's allowance into an account E no longer controls. Needs E's standing allowance (M-3) and an unusual transfer of control. Confidence 35. [phase1: erc4337+proxies]

---

## Round-1 findings — status at `ace88c9`

| ID | Status | Evidence |
|---|---|---|
| C-1 | **Partly fixed** | Payer is the CREATE2-derived pinned owner; treasury and fee recipient excluded (`SALib.sol:182`); 7702 refused (`LPManagerModule.sol:328`). The bare allowance pull remains (M-3). |
| H-1 | **Fixed** | Keeper return ≤ the account's `hedgeEquity` (`LPManagerModule.sol:530`); paid into the account, exact delta. |
| H-2 | **Fixed** | Recipient delta + `_post` (`SALib.sol:645-646`); ledgers written after. |
| H-3 | **Fixed** | `_sync` writes the snapshots (`SALib.sol:301-302`); zero-fee return is safe (`LPManagerModule.sol:578`). |
| M-1 | **Partly fixed** | Replace / resume are client-only (`SALib.sol:232`). First registration still any delegation, any caller (L-3). |
| M-2 | **Fixed** | `returnHedgeMargin` always syncs and snapshots, live or not. |
| M-3 | **Fixed** | Epoch + stored value + era bound; every ledger write bumps the epoch. (Pause does not void — L-7.) |
| M-4 | **Fixed** | `SALib.value` has no spot term; `_fresh` gates fee and send. |
| M-5 | **Partly fixed** | Subscribers refused, direct drain on removals closed. Open siblings: M-1 (increase), M-2 (other tracked position). |
| M-6 | **Fixed** | `_spend[delegator][keccak256(terms)]` (`ElysiumCustodyEnforcer.sol:194`), redeemer check (`:168`). |
| M-7 | **Partly fixed** (as the client states) | Window is 1x per any 24 h; charge symmetric; range one-shot. New liveness cost (M-4); real bound larger than stated (L-5, I-1); same-transaction walk + fee (L-16). |
| M-8 | **Fixed** | `revoke` has no external dependency. |
| L-1 | Fixed | `until > type(uint64).max` reverts (`SALib.sol:151`). |
| L-2 | **Regressed** | The min/max rule reads unbanded spot (H-1); `revoke` + `register` is still an on-demand sync (L-9). |
| L-3 | Partly fixed | Probes gas-capped; reason copied in full before truncation; no per-entry gas (L-4). |
| L-4 | Fixed | Approved equity writes `netMargin` down (`SALib.sol:469-470`). |
| L-5 | Fixed | Empty args, 65-byte signature (`SALib.sol:139`). |
| L-6 | Fixed | Sends paused; keeper-only cuts have cap 0. Approved hedge values still apply while paused (L-7). |
| L-7 | Fixed | Validation, registration, era. The documents' "cleared by a pause" is false for hedge approvals (L-7 here). |
| L-8 | Partly fixed | Constructor and setters covered; ownership path (L-6) and deploy-script checks (L-8 here) are not. |
| L-9 | Fixed | Uncollected fees counted in `v0` (`LPManagerModule.sol:414`). |
| L-10 | Fixed | Sync before the `MAX_POSITIONS` check (`:382-383`). |
| L-11 | Fixed | Partial-fee mark exact to 1 raw unit. |
| L-12 | Partly fixed | Flag exists but is cleared by an equal report (L-1). |
| L-13 | Partly fixed | Mint read back; increase is not (M-1); a transferred NFT's uncollected fees are unbooked (I-2). |
| L-14 | Fixed | `live()` re-checks designator / owner. Side effects: I-4, I-8. |
| L-15 | Acknowledged, unchanged | Enforcer bounds destinations, not value. |
| L-16 | Partly fixed | Sends and fees use `_fresh`; hedge step is age-only (L-2); flow booking has no gate (H-1). |
| L-17 | Fixed (module) | ERC-20 approvals reset in the same redemption; Permit2-side allowance and the side effect on 7702 wallets: L-13. |
| I-1 | Fixed | Enforcer limit is a 35% sliding window. |
| I-2 | Acknowledged, unchanged | Blocklisted treasury / fee recipient needs a new module. |
| I-3 | Partly (as stated) | Zero slippage rejected; hard-cap combinations and missing deadline unchanged. |
| I-4 | Acknowledged, unchanged | See I-6. |
| I-5 | Partly fixed | New mismatches: owner exclusions (I-3), pause voiding hedge approvals (L-7), "copied ≤ 256 bytes" (L-4), "10%" (I-1). |
| I-6 | Acknowledgement holds | |
| I-7 | Acknowledgement holds | No clawback is what makes H-1, L-1 and L-16 permanent. |
| I-8 | Acknowledgement holds | |

No round-1 fix was found to be bypassed for custody: C-1's treasury drain, H-1's cross-account return and H-2's faked transfers are closed.

---

## Access-Control Inventory

NR = `nonReentrant`, WNP = `whenNotPaused`. Line numbers from `src/sa/LPManagerModule.sol` unless prefixed.

| Entry point | Guard | Who | Moves value |
|---|---|---|---|
| `register` :312 | NR; first time open; replace / resume needs account or pinned owner (`SALib.sol:232`); needs an anchor | anyone / client | no |
| `onboard` :320 | NR; as `register`; hybrid only when amount ≠ 0 | anyone | USDC pinned owner → account |
| `deposit` :335 | NR; registered | anyone | USDC sender → account |
| `revoke` :343 | account or pinned owner; no NR; no pause | client | no |
| `reportPrice` :360 | NR, keeper; pool band on the reported price | keeper | no |
| `mintPosition` :371, `increasePosition` :399, `swap` :468 | NR, keeper, WNP; keeper price; `_live` | keeper | account ↔ own position / pool |
| `decreasePosition` :426, `burnPosition` :445 | NR, keeper; `_live`; no pause; no price gate | keeper | position → account |
| `sendHedgeMargin` :501 | NR, keeper, WNP; `_fresh`; `_live`; cap | keeper | USDC account → hedgeTreasury |
| `returnHedgeMargin` :523 | NR; keeper (≤ own equity) or treasury (any); registered | keeper / treasury | USDC treasury → account |
| `reportHedgeEquity` :547 | NR, keeper; registered | keeper | no |
| `chargeFee` :564 | NR, keeper, WNP; `_fresh`; `_live`; interval; hedge report | keeper | USDC account → feeRecipient |
| `multicall` :590 | keeper; self-delegatecall, `msg.sender` stays keeper | keeper | per inner call |
| `approvePrice` :612, `approveHedgeEquity` :623 | guardian | guardian | no |
| `setPaused` :642 | true: guardian or owner; false: owner | guardian / owner | no |
| `setKeeper` :654, `setGuardian` :660, `setParams` :668, `transferOwnership`, `acceptOwnership` | owner / pending owner | timelock | no |
| `ElysiumCustodyEnforcer.beforeHook` (`ElysiumCustodyEnforcer.sol:156`) | DelegationManager only; mode 0; redeemer = module | DM | filters execution |
| `SwapExecutor.swap` (`SwapExecutor.sol:67`) | NR | anyone | caller → pool → caller |
| `SwapExecutor.unlockCallback` (`:89`) | PoolManager, inside own `swap` | PoolManager | payer → pool → payer |
| `VaultTimelock.schedule*` / `execute*` / `cancel` / `updateDelay` | PROPOSER / EXECUTOR / CANCELLER (self-ops: PROPOSER) / self | operator, guardian | forwards value |
| `DeploySA.run` | chain id and role requires | deployer | deploys |

**Roles.** Owner = VaultTimelock (two-step transfer, renounce reverts, 24 h–30 d delay, 7-day grace). Keeper: instant; pause stops mint / increase / swap / send / fee and zeroes the anchor and hedge-step caps; decrease, burn, return, hedge report and multicall stay open. Guardian: instant pause, cannot unpause; one-shot approvals; separate CANCELLER grant on the timelock. hedgeTreasury / feeRecipient: immutable. Client: account + pinned owner (written only at `SALib.sol:235`). **Unguarded:** first `register`, `onboard`, `deposit`, `SwapExecutor.swap`. Through `multicall` the keeper reaches every module selector as an ordinary caller; no privilege is gained and each inner call keeps its own guard.

## Threat Model — catalog answers

| # | Threat | Answer |
|---|---|---|
| T1 | Anyone moves the pinned owner's USDC through `onboard` | **M-3** |
| T2 | Anyone chooses the stored delegation at first registration | **L-3** |
| T3 | Fake or look-alike account takes a victim's identity | Invariant holds — CREATE2 re-derivation and exclusions (`SALib.sol:181-185`) |
| T4 | Hostile account code inside brackets | **M-1, M-2, L-10, L-14**; transfers cannot be faked (recipient delta) |
| T5 | Client times direct flows around syncs | **L-9**, I-2; otherwise the min/max rule always books against the client |
| T6 | Client reaches another client's margin | Invariant holds — equity rises only by a verified send or guardian approval; keeper return ≤ own equity |
| T7 | One account blocks the keeper batch | **L-4** |
| T8 | Client exit blocked | Invariant holds — `revoke` has no dependency; funding caveat I-5 |
| T9 | Keeper walks the anchor | **L-16**, L-5, I-1 (acknowledged residual, larger than stated) |
| T10 | Keeper syncs at a chosen spot | **H-1** |
| T11 | Keeper removes at a displaced spot / while paused | Invariant holds — a remover at a displaced spot receives ≥ the position's value at the true price; the manipulator loses. Loss exists only through H-1 |
| T12 | Slippage per 24 h | Bounded by turnover × (band + slippage); **L-15** |
| T13 | Hedge ledger abuse | Cap holds at send; **L-1, L-2**; no cross-account path |
| T14 | Fee above feeBps of real profit | **H-1**, L-1, L-16 |
| T15 | `multicall` reaches non-keeper functions | Invariant holds for privilege; it is the carrier for M-3 |
| T16 | Guardian approvals | Hold for binding; **L-7**, **M-4**, I-7 |
| T17 | Pool manipulator / MEV | **H-1** (first registration), M-4 (blocks `_fresh`), L-15 |
| T18 | Third-party donations / budget exhaustion | Invariant holds — budgets are charged only inside keeper actions; donations are contributions |
| T19 | Owner powers | Hard caps hold; **L-6** |
| T20 | SwapExecutor payer confusion | Invariant holds — payer = recipient = caller; callback only from own `swap` |
| T21 | Enforcer backstop | Invariant holds — default deny, state per (delegator, terms hash); it is the limit that caps H-1 at 20% of idle per 7 days |
| T22 | Deployment | **L-8** |

## Invariant Verification

Verdict for every inferred invariant of the pre-scan catalog (`holds` / `violated → finding` / partly).

| ID | Property | On-chain (pre-scan) | Verdict |
|---|---|---|---|
| I-1 | `params` within hard caps | Yes | holds |
| I-2 | Roles pairwise distinct | No | violated → L-6 |
| I-3 | `revoked` toggled only by the client | Yes | holds |
| I-4 | `_sync` books and snapshots in one step | Yes | holds |
| I-5 | Every path syncs; snapshots equal live state after each call | No | violated → M-2 (partial closing snapshot); `deposit` / `onboard` / `revoke` are booked at the next sync by design |
| I-6 | Hedge ledgers written after a verified send | Yes | holds |
| I-7 | `hedgeEquity` rises only by send or guardian approval | Yes | holds |
| I-8 | `hedgeEpoch` bumps on every ledger change | Yes | holds |
| I-9 | max(equity, netMargin) ≤ cap × value at all times | No | not enforced after the send (value can fall; by design) — no finding; the cap is a send-time check |
| I-10 | One fee per `feeInterval` | Yes | holds |
| I-11 | Fee ≤ 20% of idle and ≤ feeBps of profit above the mark | Yes | arithmetic holds; the *profit* input is violated → H-1 |
| I-12 | Any 24 h window ≤ 1x cap | No | holds for `charge`; guardian range exceeds by design → M-4, I-1 |
| I-13 | Stored anchor within band of the pool when written | No | violated (clipped value not band-checked) — harmless alone because `_fresh` re-checks; feeds L-2 |
| I-14 | Price range one-shot, cleared by pause / guardian change | Yes | holds (I-7: consumed by a zero move) |
| I-15 | Hedge approval one-shot, bound to epoch / era / value | Yes | holds (L-7: survives a pause) |
| I-16 | ≤ 4 tracked positions | Yes | holds |
| I-17 | Tracked positions are module-minted with stored ticks | Yes | holds |
| I-18 | Pinned hybrid owner re-derives the address | Yes | holds |
| I-19 | Module liveness matches the signed expiry | Yes | holds |
| I-20 | Every redeeming action ends with a directional post-check | Yes | holds — but directional is not sufficient → M-1, M-2, L-14 |
| I-21 | No allowance outlives the action | No | partly violated → L-13 (Permit2 side; not exploitable) |
| I-22 | Fee / send need a fresh, unclipped, in-band anchor | Yes | holds (L-16: age 0 accepted) |
| I-23 | Every value that gates a fee is at a fresh banded anchor | No | **violated → H-1**, L-1, L-2 |
| I-24 | Enforcer: ≤ 35% of idle per 24 h per (delegator, terms) | Yes | holds |
| I-25 | Enforcer: one fee per 7 days, ≤ 20% of balance | Yes | holds |
| I-26 | Enforcer default deny | Yes | holds |
| I-27 | SwapExecutor keeps no tokens | Yes | holds |
| I-28 | Timelock delay in [24 h, 30 d] | Yes | holds |
| I-29 | Ready operations expire after 7 days | Yes | holds |
| I-30 | Keeper-only report never raises equity; decrease ≤ room | Yes | holds (cap input: L-2) |
| X-1 | Module and enforcer fee constants equal | No | holds today (7 days / 2000 bps on both sides); not asserted in the constructor |
| X-2 | Module and enforcer hedge bounds limit the same quantity | No | different bases by design; no path found where the keeper alone exceeds the module cap |
| X-3 | Terms hash names this module and its recipients | Yes | holds |
| X-4 | Module-built executions fit the enforcer shapes | Yes | holds |
| X-5 | Swap output is paid only to the account | Yes | holds |
| X-6 | Module guardian = timelock canceller | No | violated → I-6 (separate slots) |
| E-1 | A client flow never changes `profit` | No | **violated → H-1**, M-1, M-2, L-9, I-2 |
| E-2 | Value leaves only as capped margin or a fee on real profit | No | **violated → H-1** (fee on principal, capped only by the enforcer) |
| E-3 | Keeper cannot move value between accounts | Yes | holds |
| E-4 | Without the guardian the anchor moves ≤ e^cap per 24 h and fees use an in-band anchor | No | holds as `e^cap` (I-1); L-16 |

---

## Recommended order of work

1. **H-1** — clamp the pool term in `_sync` (four lines), then decide on the pending-while-not-fresh rule for stale anchors. Add displaced-spot regression tests for all five ungated paths.
2. **M-1 + M-2** — liquidity read-back on increase and the "other tracked positions unchanged" check at the end of every bracket. Together they restore the class-A claim for the fee base; the hostile-account test harness already exists.
3. **M-3** — restrict the allowance fallback.
4. **M-4** — drop the clipped flag from `_fresh` or redefine it by distance; cap the window charge of a guardian range.
5. Lows: L-1, L-2, L-5, L-7 and L-11 are one-line changes; L-4 needs an assembly `delegatecall`; L-6 an override; L-8 script `require`s.
6. Correct the documents where they disagree with the code (I-1, I-3, L-4, L-7, the rotation NatSpec in I-6).

The module is stated at 596 bytes under EIP-170; put the new checks in `SALib`.

> This review is a time-boxed, automated multi-agent analysis with orchestrator reconciliation. It is not a guarantee that the code is free of defects. No finding was confirmed by executing code.
