# SA audit round 2: response

Report: `docs/audit/sa_round2_report_1225.md` (0 Critical, 1 High, 4 Medium, 16 Low, 11 Info; commit `c5af69a`).
Branch `sa-r2-fixes` off `sa-relayer` (`c5af69a`). Root-cause analysis written before the fixes:
`docs/audit/sa_round2_rootcause.md` (classes B', D', A'' and the residuals of round-1 classes).

| Commit | Scope |
|---|---|
| `495e727` | Contracts (`LPManagerModule`, `SALib`, new `SABook`, `SwapExecutor` record), `DeploySA` L-8 checks, new `test/sa/SARound2.t.sol`, `SAHostile` modes 4-6, existing suites and the fork test on the new semantics |
| `a7311a5` | Keeper (`sa_chain.py`, `sa_keeper.py`, regenerated ABI), web (`account.js`) |
| docs commit (this file) | this file, `sa_round2_rootcause.md`, `docs/audit_sa_round3.txt`, design doc section 6 |

Sizes (runtime, EIP-170 = 24,576): `LPManagerModule` 23,899 (677 margin), `SALib` 16,174 (linked), `SABook` 6,452
(linked, new), `SwapExecutor` 3,627, `ElysiumCustodyEnforcer` 7,802 (unchanged).

Tests: forge 202 offline (`SARound2` 25 new; `SARegressions` 33, `LPManagerModule` 31, `CustodyEnforcer` 27, `Smoke` 1, the
shelved-vault suites unchanged); fork (`ELYSIUM_FORK=true`, `https://rpc.elysium.kinetiq.xyz`): SA 3/3 at latest and at block 6100000;
vault 7/7 at 6100000, 6/7 at latest (`test_fork_FullLifecycle…` of the shelved pooled vault reverts `BadPrice` at the
current market price; its code and test are unchanged on this branch and pass at 6100000). Keeper pytest 134 with
`ELYSIUM_FORK=1` at 6100000 (incl. SA e2e and relayer-API e2e on an anvil fork); SA e2e and API e2e also pass at latest.
Regression tests are named `test_<ID>_PoC_*` (the auditor's scenario) and `test_<ID>_Sibling_*` (another path of the
same root cause).

## Root-cause classes (one line each)

- **B'** The books were reconstructed from the account after each action. Now: the snapshot is computed (module
  effect from PoolManager / PositionManager / SwapExecutor state the account cannot write), `live − snapshot` is
  exactly the client's flow, booked at the anchor (the price `value` uses) only while the anchor is trusted.
- **D'** Price trust was one stored flag. Now: per cause, a pure function of state (clipped = anchor outside the band of
  the last report), and booking / fees need the anchor unchanged for `minPriceStable`.
- **A''** Consent from a standing allowance. Now: every pull needs a permit for exactly that payment.

## Findings

Status: **Fixed** (code + regression test), **Partly** (fixed as described, residual stated), **Ack** (documented,
no code change), **Rebutted** (with reason).

| ID | Class | Status | Change | Tests (`test/sa/SARound2.t.sol` unless noted) |
|---|---|---|---|---|
| H-1 | B' / D' | Fixed | Flows booked at the anchor only (same function and price as `value`), only while trusted; fee on min(V(anchor), V(pool)) − contributed after a sync; registration books nothing | `test_H1_PoC_KeeperSyncAtDisplacedSpot`, `test_H1_PoC_FirstRegistrationAtDisplacedSpot`, `test_H1_PoC_LaggingAnchorNoAttacker`, `test_H1_Sibling_EverySyncPathBooksAtTheAnchor`, `test_H1_Sibling_DepositWithdrawCyclesNetZero`, `test_H1_Sibling_WalkAndChargeInOneTransaction`, `test_Fee_PendingFlowsBookedFirst` |
| M-1 | B' | Fixed | Adds book the computed principal (slot0 before the action, rounded up), never the account's balances; a skipped execution is a pending outflow; a swap needs exactly one new executor record | `test_M1_PoC_SkippedIncreaseThenRedeposit`, `test_M1_Sibling_SkippedSwapReverts` |
| M-2 | B' | Fixed | Removals book the computed principal of min(requested, snapshot) + fees; every tracked position's snapshot is the books' own, so proceeds moved anywhere are a pending flow | `test_M2_PoC_BurnProceedsIntoOtherTrackedPosition`, `test_M2_Sibling_DecreaseProceedsIntoOtherTrackedPosition`, `test_M2_Sibling_SwapOutputSkimmedIsBooked`; `SARegressions.test_M5_*` (drain now exact to 2 wei) |
| M-3 | A'' | Fixed | `SALib.pull`: the permit must succeed; a front-run permit only if it is the same signature (nonce − 1, deadline, owner, allowance == amount); no standing allowance | `test_M3_PoC_StandingAllowanceNotPullable`, `test_M3_Sibling_PermitReplayAmountAndDeadline` |
| M-4 | D' | Fixed | `lastPriceClipped()` is a view (anchor outside the band of the last report), clears itself; the guardian range is used only when move > room and charges only the room | `test_M4_PoC_SaturatedWindowOneUnitDoesNotBlock`, `test_M4_Sibling_OscillationAndAutoClear`; `SARegressions.test_M7_*` |
| L-1 | D' | Fixed | An equal or higher hedge report never clears `hedgeClipped` | `test_L1_EqualReportDoesNotClearHedgeClipped` |
| L-2 | D' | Fixed | Keeper-only hedge step cap is 0 unless the anchor is fresh (age, not clipped, pool in band) | `test_L2_HedgeStepNeedsAFreshAnchor` |
| L-3 | C | Ack | First registration is permissionless by design (relayer); the client can disable any signed delegation in the DM before or after. Stated in the client text | — |
| L-4 | H | Partly | `multicall` copies at most 256 bytes of revert data (assembly; full data when `allowFailure` is false). No per-entry gas bound (Ack): one hostile account can make a batch run out of gas; the current keeper sends one transaction per action and does not use `multicall` | `LPManagerModule.t.sol` multicall tests |
| L-5 | D' | Fixed | Band measured against the reference (`_off(x, ref)`; the pool for keeper prices) | `test_L5_BandMeasuredAgainstThePool` |
| L-6 | G | Fixed | `transferOwnership` override runs `_distinct`; `_distinct` also checks `pendingOwner()` | `test_L6_OwnershipTransferKeepsRolesDistinct` |
| L-7 | F | Fixed | `setPaused(true)` bumps `guardianEra`, voiding every open hedge approval | `test_L7_PauseVoidsHedgeApprovals` |
| L-8 | G | Fixed | `DeploySA`: timelock delay in [24 h, 30 d], pool initialised with liquidity, DM not paused, CREATE2 deployer code hash, every framework address derived from its fixture init code, `hybridAddress` == `SimpleFactory.computeAddress` after broadcast | exercised by the anvil-fork SA e2e (deploys with the script) |
| L-9 | B' | Fixed | Registration (incl. revoke + re-register) books nothing; flows only at a trusted sync | `test_L9_ReRegisterBooksNothing` |
| L-10 | A | Ack | No on-chain rule; proposed operator rule: stop managing an account whose fee fails on two consecutive due dates (not yet in the keeper) | — |
| L-11 | C | Fixed | Re-registering the stored, non-revoked delegation returns before the delegation checks | `test_L11_TopUpInTheLastDay` |
| L-12 | G | Ack | Keeper removals depend on the DM pause (third party); client exit does not. Stated | — |
| L-13 | A | Partly | Permit2 allowances are reset to 0 (expiration 0) in the same redemption; the ERC-20 `approve(Permit2, 0)` reset still overwrites a 7702 wallet's own Permit2 approval (stated in the client text) | `test_L13_NoPermit2AllowanceLeft` |
| L-14 | B' | Fixed | Swap books `(paid, received)` from the executor record; anything the account forwards is a pending outflow | `test_M2_Sibling_SwapOutputSkimmedIsBooked` |
| L-15 | — | Partly | `swap(…, minOut)`: the keeper's min-out applies if above the floor; turnover is still charged on `amountIn` (fair value for sales) — intended, it bounds traded notional | `test_L15_KeeperMinOut` |
| L-16 | D' | Fixed | Fees (and booking) need the anchor unchanged for `minPriceStable` (default 300 s) | `test_H1_Sibling_WalkAndChargeInOneTransaction` |
| I-1 | D' | Ack | The drift bound is e^cap per 24 h (+10.52% / −9.52% at 1000 bps), as the auditor computed; this is the correct statement. With L-5 fixed the band adds at most 1.5% | — |
| I-2 | B' | Ack | Client-collected LP fees leave the fee base (bounded by fee income since the last keeper touch); keeper collects before `chargeFee` | — |
| I-3 | A | Ack | Keeper / guardian as account owner: no exploit; the round-1 root-cause text overstated it: on-chain only the treasury and fee recipient are excluded (hybrid branch) | — |
| I-4 | A | Fixed | `ownerOf` uses a masked decode | — (one-line change; existing identity tests) |
| I-5 | H | Ack | A 7702 account can be left without native gas after a swap; proposed operator rule: the keeper leaves a native reserve in 7702 accounts (not yet implemented) | — |
| I-6 | G | Ack | Guardian (canceller) can delay unpause / rotation for two delays; client exits stay open; the rotation must schedule step 2 only after step 1 executed (stated here; NatSpec to be corrected) | — |
| I-7 | D' | Fixed | Guardian range consumed only when move > room | `SARegressions.test_M7_*` |
| I-8 | A | Ack | Rotating a hybrid owner is a permanent exit; stated in the client text | — |
| I-9 | D' | Partly | After an outage shorter than `maxPriceAge`, fees additionally need `minPriceStable` with the pool in band; no sequencer feed on Elysium | — |
| I-10 | B' | Fixed (obsolete) | `_conserved` removed; removals are computed, no tolerance | `SARegressions.test_M5_*` |
| I-11 | — | Ack | Design notes, no change | — |

## Rebuttals and design choices

1. **Client-favour min/max booking price (suggested for H-1): not adopted.** It is the round-1 design that produced
   H-1: any flow price different from the price used for `value` turns into profit or loss, and a direction-
   dependent price lets a client cycle the same HYPE in and out and raise `contributed` by size × spread per round
   trip without bound (shielding real profit from the fee). One price (the anchor) makes a round trip exactly zero
   (`test_H1_Sibling_DepositWithdrawCyclesNetZero`). Displacement protection comes from booking only at a trusted
   anchor and charging the fee on min(V(anchor), V(pool)).
2. **"Read position liquidity back after each action, balances around the whole action" (suggested): replaced by
   computation.** Reading back the account after the action is exactly what lets account code hide value inside the
   bracket (M-1, M-2, L-14). Liquidity is read back for mints (`checkMinted`); everything else is computed from state
   the account cannot write, so conservation across all tracked positions holds by construction: the only difference
   between the books and the account is the client's own flow, booked at one price.
3. **M-3 front-run tolerance kept, narrowed.** Rejecting a front-run permit would let anyone block onboarding by
   submitting the signed permit first. Accepting it only for the same signature (nonce − 1, deadline, recovered
   owner, allowance == amount) gives the same consent as the permit itself.

## Acknowledged residuals

- Client-collected fees and uncollected fees of transferred-out positions (I-2).
- A keeper willing to hold the pool displaced by up to the band against arbitrage for `minPriceStable` can make the
  fee read at most band × base exposure as gain (≈ 0.11% of exposure per fee at the defaults). Raise
  `minPriceStable` via the timelock if pool depth falls.
- Flows stay pending while the anchor is not trusted: the UI shows `contributed + pending`, and the keeper holds the
  anchor value while a fee is due.
- A mint at `MAX_POSITIONS` may need a trusted sync first to drop positions the client burned.

## Keeper / web / API changes

- ABI regenerated; `swap` takes `minOut` (keeper passes 0: the module's floor applies); errors `BelowMinOutOrBadSwap`,
  `BadPermit`.
- `sa_chain`: `minPriceStable`, `lastPriceMoved`, `lastReported`; `AccountSnap.pending` (live − snapshot at the anchor)
  and `fee_profit`; `GlobalSnap.trusted()` mirrors `_trusted()`.
- `sa_keeper`: the fee waits for a trusted anchor and holds the anchor value meanwhile (re-reported for freshness).
- Relayer API: unchanged; it already required a permit over the owner's current nonce, which is now mandatory
  on-chain as well.
- Web: `int256` snapshots, `minPriceStable`, deposits shown including the pending client flow.
