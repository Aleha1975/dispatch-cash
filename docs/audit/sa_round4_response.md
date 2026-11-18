# SA audit round 4: response

Reports (both at commit `04420ec`, branch `sa-r4-riskoff`): `docs/audit/sa_round4_report_1240.md` (0 C, 1 H, 3 M,
13 L, 9 I) and `docs/audit/sa_round4_report_1241.md` (0 C, 1 H, 4 M, 14 L, 8 I). Fixes on branch `sa-r5` off `04420ec`,
one commit. Priorities used for every decision, unchanged: client principal safety > liveness > accuracy of our fee. A
residual that can only lower the operator's fee is accepted and listed.

The two reports overlap heavily. Deduplicated, there are 1 High, 5 Mediums, 21 Lows and 13 Infos. The tables below
list every finding of both reports with its status; the ID of the other report is given where they are the same
finding.

Sizes (runtime, EIP-170 = 24,576): `LPManagerModule` 24,122 (454 margin; was 23,996 / 580), `SALib` 18,343 (linked;
was 17,173), `SABook` 7,699 (linked; was 6,993), `SwapExecutor` 3,774 (unchanged), `ElysiumCustodyEnforcer` 7,802
(unchanged), `VaultTimelock` 6,155 (was 6,126), `V4PositionMath` 6,059 (unchanged). To stay under the limit the
margin-return bookkeeping (`SALib.returnMargin`) and the swap bounds (`SALib.swapBounds`) moved into SALib, and the
budget value (`SABook.nav`) lives in SABook.

Tests: forge 244 offline + 2 skipped (was 228 + 2). New `test/sa/SARound4.t.sol` (15 tests) and
`SARegressions.test_SA4_M1_OneStepPerStableWindow`. Fourteen of the fifteen new `SARound4` tests were run against
the sources of `04420ec` (same test file, the two walk helpers added to the old base) and fail there. The fifteenth is a
non-regression sibling (a USDC-only flow does not delay the fee). Example: the H-1 PoC drives `contributed` to
-3.27e55 on `04420ec`. Existing suites were updated where the new rules change the expected behaviour (listed under
"Tests changed"). Fork (`ELYSIUM_FORK=true`, public RPC, read only): SA 3/3. Keeper pytest 212 offline + 4 skipped
(was 208 + 4). The keeper SA e2e and relayer-API e2e run on a local anvil fork and pass; they deploy with the
changed `DeploySA` script.

## The question asked first: a principal-loss path for the pilot?

The reports agree: no third party can move funds to an address outside {client, pool, hedgeTreasury, feeRecipient},
and nobody can stop a client exit. Three things reached principal, and all three are now fixed:

- **H-1**: a fee on principal after an ordinary client action (empty and refill a tracked NFT). Fixed. The booked
  yield is now bounded by the pool's global fee growth and by what reached the account.
- **M-1**: the stolen-keeper bound is measured against the anchor, and one report moved the anchor the whole
  `refDriftBps`. Fixed as the auditors propose. One keeper report moves the anchor at most `poolBandBps`, and only after
  the last move was stable for `minPriceStable`. A 10% walk now takes about seven reports over 35 minutes in public view,
  and the guardian bot can pause in that time. The bound stated in residual 7 has been corrected.
- **M-3 of 1241**: keeper and guardian together could inflate hedge equity, widen every window and pull treasury USDC.
  Fixed. The keeper returns at most the net margin the account really sent, and equity above that net margin widens
  no window and carries no fee.

Pilot rule from both reports, kept until this round is verified: nobody modifies tracked NFTs directly from the client
account.

## Status: High and Mediums

| ID | Finding (short) | Status | Fix (where) | Regression tests (`test/sa/`) |
|---|---|---|---|---|
| 1240 H-1 / 1241 H-1 | Empty and refill a tracked position: `_feesOut` books a wrapped fee amount; `chargeFee` then takes 20% of idle USDC every interval | Fixed (both recommended guards) | `SABook._feesOut`: (1) `Pos` stores the pool's `feeGrowthGlobal{0,1}` with the mark (`G0`, `G1`, written in `book` and every sync). A mark difference larger than the global growth since the mark (or a wrapped one) means PoolManager re-based the position, and nothing is credited. (2) Credit only a position that is still owned and has the books' liquidity (`owned && liq == old ? old : 0`), so the `pmLiq == 0 ? old` override is gone. (3) 1241's belt: never credit more than the idle balance holds above the snapshot. Every guard can only lower the yield counted. | `SARound4.test_H1_PoC_EmptyRefillOneBatch` (one batch: decrease all, increase all), `test_H1_Sibling_EmptyUnpricedSyncRefill` (two transactions with an unpriced sync between), `test_H1_Sibling_DipAndReturnCountsNoExtra` (L → L/2 → L: credit ≤ what PoolManager paid) |
| 1240 M-1 / 1241 M-1 | Stolen-keeper bound measured against the anchor; one report moves the anchor the whole `refDriftBps` | Fixed (recommended fix) | `SALib.movePrice(…, stepBps, stable)`: the keeper's window is also clipped to `ref ± poolBandBps`, and to `ref` (no move) while `block.timestamp < lastPriceMoved + minPriceStable`. `reportPrice` passes `poolBandBps` and that flag. A guardian range still applies a clipped report unclipped. The "second report" part of the 1240 fix is not added (see 1241 L-14). | `SARegressions.test_SA4_M1_OneStepPerStableWindow`; `LPManagerModule.t.test_H2_*` rewritten (first report moves 1.5%, ten steps to the 10% budget) |
| 1240 M-2 | A client flow booked at a price far from the market; the fee is charged on the difference later | Fixed (recommended fix) | `Account.pricedFlowTime`, stamped by `SABook.sync` when a booked flow has a price-dependent term (idle base, or a tracked position's liquidity changed). `chargeFee`: `next = max(lastFeeTime + feeInterval, pricedFlowTime + 1 days)` → `FeeTooEarly(next)`. Keeper: books every pending flow with `sync(a)` at the first trusted moment (unchanged), and before a due fee; waits out the day (`fee_waits_flow`). See the note under "Where we read the reports differently". | `SARound4.test_M2_PoC_FeeWaitsADayAfterPricedFlow`, `test_M2_Sibling_UsdcFlowDoesNotDelay` |
| 1240 M-3 / 1241 M-2 | `sync(a)` has no registration check: anyone opens the books of a future client early | Fixed (both parts) | `LPManagerModule.sync`: `NotRegistered` for `delegationHash == 0`. `SALib.register`, first registration: `snapAsset`, `snapBase`, `contributed`, `hwm` reset to 0 (defence in depth). | `SARound4.test_M3_PoC_SyncRefusesUnregistered` |
| 1241 M-3 (1240 L-5, equity part) | Guardian equity approval unbounded: keeper + guardian lift every value-relative budget and pull the treasury's allowance | Fixed (recommended fix) | `SALib.returnMargin` (from `returnHedgeMargin`): the keeper returns at most `min(hedgeEquity, netMargin)`. The treasury itself may still return more, e.g. realised hedge profit. `SABook.nav` = value − max(0, hedgeEquity − netMargin) is the base of the turnover and exit windows, of the keeper's equity step and of the fee profit. | `SARound4.test_M3b_PoC_KeeperReturnCappedByNetMargin`, `test_M3b_Sibling_ApprovedEquityWidensNoWindowNoFee` |
| 1241 M-4 (1240 L-7) | The risk-off exit sale is unavailable in a crash beyond `refDriftBps`, in a trend, while paused, and while a third party holds the pool off the band | Decided: fail-closed, documented (one of the two options the auditor recommends), plus the safe part fixed | The exit sale keeps every swap gate: not paused, trusted anchor. Any looser gate (an exit branch without the stable window or the booking band, or exit sales while paused) can be reached at a keeper-walked or pool-pushed anchor. That is exactly the M-1 path, and it moves principal. Liveness of risk-off is a product property, not principal, so the gate stays. In a fall beyond the drift budget the guardian bot calls `approvePrice` (go-live list item 3); until then the account sits in idle HYPE, still hedged if it was. Fixed alongside: L-6 (no blocking when the exit window is off or full). Note: the M-1 step makes the anchor follow a fast move at 1.5% per 5 minutes, so in a crash the exit sale waits for the anchor or for a guardian range. | (behaviour unchanged; `SARiskOff` suite) |

## Status: Lows and Informationals

1240 report:

| ID | Status | Note |
|---|---|---|
| L-1 | Fixed | = H-1 guard (2): a changed position credits nothing; the dip-and-return case is credited at most what reached the account (`test_H1_Sibling_DipAndReturnCountsNoExtra`) |
| L-2 | Fixed | = 1241 L-1: a position no longer owned credits nothing (`n` is 0, nothing overrides it); idle-surplus cap |
| L-3 | Fixed | `SABook.lpRemove`: `m ≤` live PoolManager liquidity for burns too; a burned position whose snapshot was not all removed stays tracked (worth 0 in `value`) until the next priced sync books the rest as the client's outflow at the anchor and drops it (`LPManagerModule._remove`) (`test_L3_BurnAfterClientDecreaseBooksLive`) |
| L-4 | Partly | `movePrice`: the first report inside an open range consumes it, clipped or not (`SARegressions.test_M7_Sibling_GuardianRangeOneShot` updated). No `expectedRef`, no fee block after a guardian jump: the guardian is trusted for that call; operator rule: `until` in minutes, range a few % wide |
| L-5 | Partly | equity part fixed (= 1241 M-3). Accepted: unbounded `approvePrice` width, no pause-only role, guardian can cancel an owner pause. Two operator keys; the guardian key stays off the keeper's infrastructure |
| L-6 | Fixed | `SALib.useTurnover`: an exit sale goes to the turnover window when `exitTurnoverBps` is 0 or the exit window has no room (`SARiskOff.test_R4_ExitWindowCapAndOff` updated, `SARound4.test_L6_ExitWindowFullFallsBackToTurnover`). The bound stays (turnover + exit) per 24 h |
| L-7 | Decided | = 1241 M-4 |
| L-8 | Fixed | `movePrice`: when the window does not contain the anchor, only a report inside the window is applied, never a clamp against the report (1241's form) (`test_L8_LoweredCapNoMoveAgainstReport`) |
| L-9 | Accepted (NatSpec corrected) | the destination is the owner's own account; `SALib.pull` and `onboard` NatSpec now describe the one case a same-amount standing allowance is used |
| L-10 | Accepted | liveness only, no funds move; the owner recovers with `deposit` or a new permit |
| L-11 | Fixed | `VaultTimelock.renounceRole`: `PROPOSER_ROLE` and `EXECUTOR_ROLE` refused (`test_L11_NoExecutorRenounce`) |
| L-12 | Fixed | `DeploySA.pilotParams()`: `swapTurnoverBps` 5000, `exitTurnoverBps` 10000; after the broadcast the full `params()` tuple, `asset`, `hedgeTreasury`, `feeRecipient`, `permit2`, `delegationManager`, `timestampEnforcer`, `eip7702Impl`, not paused and the owner's `CANCELLER_ROLE` are read back |
| L-13 | Fixed | `DeploySA._checkOwner`: owner code must not be a 7702 designator (`0xef0100…`, 23 bytes) and `getThreshold()` must return ≥ 2 (Safe), unless `ALLOW_EOA_OWNER` (anvil tests only) |
| I-1 | Fixed (comment) | module header rule A: a code / owner change suspends the module while it lasts; only `revoke` / `disableDelegation` are permanent |
| I-2 | Fixed | `revoke`: also the EOA whose counterfactual HybridDeleGator is `a` (`SALib.hybridAddress`, pure) (`test_I2_HybridOwnerPreRevoke`) |
| I-3 | Fixed | `SALib.pull`: a permit call that returns must have consumed the nonce (`nonces(o) == n + 1`) |
| I-4 | Accepted | no deadlines on keeper actions; no bound is bypassed; the guardian bot pauses on sequencer recovery |
| I-5 | Fixed | `SABook.book`: SafeCast for the liquidity |
| I-6 | Fixed | `SALib.swapBounds`: a sale is charged at the higher of its value at the keeper price and at the anchor |
| I-7 | Acknowledged | offline tests run the v1.3.0 bytecode fixtures: `SARegressions.test_M8_Sibling_DirectRevokeAndRacing7702` revokes with the module and the DelegationManager paused. The full hybrid exit through `handleOps` with the DM paused is to be added to the fork suite before third-party clients |
| I-8 | Acknowledged | runbook: guardian rotation = timelock `CANCELLER` revoke / grant, then `setGuardian`, as one procedure |
| I-9 | Fixed (comment) | module header rule E: no path backstop; the per-step limit is stated instead |

1241 report:

| ID | Status | Note |
|---|---|---|
| L-1 | Fixed | = 1240 L-2 |
| L-2 | Accepted (bound restated) | fee-after-push: with the M-1 step the gate still admits about one band per 24–27 h; residual 5 restated below. Each step needs a pool push at the report and at the fee, and stays in public view for a day |
| L-3 | Accepted | the hedge cap is measured on pushable prices; the destination is the immutable treasury; the enforcer's 35%-of-idle per 24 h binds on day 1; keeper returns now need net margin actually sent |
| L-4 | Accepted | the write-down resets the cap only with the guardian's co-signature (two keys); the destination is the treasury |
| L-5 | Fixed | = 1240 L-6 |
| L-6 | Partly | the fallback (L-5) removes the blocking; a zero-liquidity or subscribed tracked NFT still routes sales to the turnover window. Keeper policy: burn, never decrease to zero; subscribing is the client's own act |
| L-7 | Fixed (keeper) | `sa_keeper.gas_reserve`: a 7702 account keeps `eip7702_gas_reserve_hype` (0.05) native HYPE in exit sales and deploys. On-chain: accepted (the 7702 path is not live on 99901) |
| L-8 | Fixed | = 1240 L-8 |
| L-9 | Accepted | = 1240 L-9 |
| L-10 | Fixed | = 1240 L-11 |
| L-11 | Accepted | = 1240 L-5 (pause-only role) |
| L-12 | Fixed | = 1240 L-13 |
| L-13 | Fixed (comment) | = 1240 I-1 |
| L-14 | Fixed (doc) | `_trusted` NatSpec: "reported within the last minPriceStable", not a second-report requirement (the same key would sign it). The one-unit restart is kept: with the M-1 step the anchor cannot move again inside the stable window anyway, and the keeper holds the anchor while the pool is inside the booking band |
| I-1 | Fixed | = 1240 L-12 |
| I-2 | Partly | = 1240 L-4 |
| I-3 | Fixed | `SALib.checkDelegation`: expiry ≤ now + 400 days (`MAX_DELEGATION_LIFETIME`, the API's `delegation_max_days`) (`test_I3_DelegationLifetimeCapped`) |
| I-4 | Fixed / acknowledged | pre-registration revoke from the hybrid owner EOA fixed (= 1240 I-2); `disableDelegation` under a DM pause as 1240 I-7 |
| I-5 | Fixed | `swapBounds`: `fair == 0` reverts `ZeroAmount` (`test_I5_DustSellRefused`) |
| I-6 | Acknowledged | deployed delay 48 h ≥ 2 × the 24 h force-inclusion delay; keep it so |
| I-7 | Acknowledged | the DM owner on 99901 is the framework deployer's address; the script refuses a paused DM; to be confirmed with MetaMask before third-party clients |
| I-8 | No action | fee-lowering paths |

## Accepted residuals (each lowers only our fee, or is a stated bound)

1. **Fees of a position the client changed** (collect plus a liquidity change, decrease, increase, burn, transfer) are
   not counted as yield: they become a contribution when the flow is booked (our fee lower). Fees the client
   collected to an outside address leave the profit (not credited above the idle surplus). A plain client collect on
   an unchanged position stays yield (round-3 M-1 fix).
2. **Liquidity removed and restored to exactly the books' value with no tick reset** between two looks: the credit
   is at most min(liquidity × the range's growth, the idle surplus). That is the fees that reached the account plus
   any client deposit made in the same interval.
3. **Client timing inside the 50 bps booking band**: ≤ 2 × 50 bps of contributed per round trip (our fee lower).
4. **Keeper booking at the band edge**: phantom gain ≤ 50 bps × flow against the pool at that instant. With the M-1
   step the anchor is at most one `poolBandBps` from a value that stood for `minPriceStable`. The fee waits a day after
   the booking (M-2) and is ≤ `feeBps` × (anchor − market) × the priced flow.
5. **Fee after a pool push**: the gate admits an anchor ≤ `poolBandBps` above its trailing 24 h low. A keeper that
   pushes the pool at every report and at the fee can raise the low by one band per 24–27 h. Over a 7-day interval
   that is about (1.015^7 − 1) ≈ 11% of base exposure, × `feeBps` ≈ 1.6% of exposure per week, to the fee recipient,
   capped at 20% of idle USDC. It needs a push at every report for a week (the anchor must stay fresh) in public view.
   The guardian bot pauses on an anchor / HL gap above `poolBandBps`.
6. **Fee deferral**: in a rally (gate), and for a day after a client flow with a price term (M-2). Our fee only.
7. **Stolen-keeper bound, restated** (both M-1): per 24 h, about (`refDriftBps` + `poolBandBps` + `maxSlippageBps`) ×
   (`swapTurnoverBps` + `exitTurnoverBps`) × value against the market. LP adds can cost more per unit of budget (added
   at slip / (slip + band) of principal). At the pilot values this is 13% × 1.5 ≈ 19% of value per day at the contract
   floors. What changed is the speed: one band per `minPriceStable` per report, so reaching the full drift takes about
   seven reports and 35 minutes. The control is the guardian bot (pause on an anchor / HL gap above `poolBandBps`). A
   pause stops swaps, adds, margin sends and fees at once.
8. **Liveness**: a third party holding the pool > 50 bps off the anchor pauses booking, swaps (the risk-off exit sale
   included, M-4), adds and fees. Removals, margin returns and the client's own exit are not affected.
9. **Risk-off in a fast market** (M-4): the exit sale needs a trusted anchor and no pause. In a fall beyond
   `refDriftBps`, or faster than one band per 5 minutes, it waits for the anchor or for a guardian `approvePrice`.
10. Unchanged from rounds 2–3: hedge equity is keeper-attested (increases need the guardian); multicall gas; 7702
    approval resets; partial fills; `feeBps` change; timelock role layout; USDC blacklist; treasury return allowance
    (approve just-in-time); guardian range width (trusted call).

## Where we read the reports differently

- **1240 M-2's delay does not remove a phantom gain; it delays the fee.** A flow booked at a walked anchor stays in
  `contributed`. What bounds the phantom is the M-1 step: at a booking the anchor is at most one band from a value that
  stood 300 s. The day of delay gives the guardian a full day to see a booking at a moved anchor before any fee rides on
  it. Trace B (a late booking with no attacker) is closed by prompt booking, not by the delay: the keeper books every
  pending flow with `sync(a)` at the first trusted tick (round-3 L-19) and, since this round, before a due fee. We
  implemented the recommended fix as asked and state the bound as above.
- **The step limit bounds speed, not size** (both M-1). Both reports say so. We restate the bound (residual 7) instead
  of claiming 4.5%.
- **1241 M-4**: taken as a decision, not a defect. Loosening the exit gate is the M-1 path; see the table.
- **1241 H-1's idle-surplus belt** changes one round-3 behaviour: fees collected to an outside address are no longer
  booked as a withdrawal of profit. They now simply leave the profit, which lowers our fee only
  (`SARound3.test_M1_Sibling_CollectToOutsideAndBurn` updated).
- **1240 M-1 (ii)**, LP mints re-acquire base at 2× per turnover unit: correct, and it is the direction residual 7 now
  states ("LP adds can cost more per unit of budget").

## Tests changed (new semantics)

- `LPManagerModule.t.test_H2_AnchorMovesOnlyWithinBudgetAndFreezesWhilePaused`, `SARound2.test_M4_*`,
  `SARegressions.test_M7_Sibling_AnchorWindowBothWays`: anchor moves walked one step per `minPriceStable`
  (`_reportSteps`, `_reportTo` in `SATestBase`).
- `SARegressions.test_M7_Sibling_GuardianRangeOneShot`: a report inside the range consumes it (1240 L-4).
- `SARiskOff.test_R4_ExitWindowCapAndOff`: `exitTurnoverBps` 0 = turnover window (L-6).
- `SARound3.test_M1_Sibling_CollectToOutsideAndBurn`: outside collect is not credited (H-1 belt).
- `SATestBase._pending` mirrors the new `_feesOut`.

## Keeper and web

- ABI (`keeper/abi/LPManagerModule.json`) regenerated: `account()` has `pricedFlowTime`, `snapPos()` returns
  `(liq, g0, g1, G0, G1)`.
- `sa_chain.pending` mirrors the new fee rule (owned and unchanged, global-growth cap read with `extsload`, idle-surplus
  cap). `AccountSnap.nav`, `fee_profit` without equity above the net margin, `keeper_return_cap`.
- `sa_keeper`: `fee` books a pending flow first and waits a day after a priced flow (`fee_waits_flow`).
  `return_margin` caps at `min(hedgeEquity, netMargin)` and alerts for the treasury's part. Windows are measured on
  `nav`. The exit room includes the turnover fallback. 7702 gas reserve. `anchor_budget` alerts only when the anchor
  did not move although its last move was stable; plain M-1 stepping is logged as `anchor_stepping`.
- New revert paths the keeper meets: `NotRegistered` from `sync`, `FeeTooEarly(pricedFlowTime + 1 day)` from
  `chargeFee`, `HedgeCap(amount, min(equity, netMargin))` from `returnHedgeMargin`. All are avoided by the mirrors
  above.
- `web/account.js`: the `Account` struct and the `params()` tuple follow the module. No flow change: the keeper books
  client flows.
- Tests: `test_product.test_sa4_*`, `test_riskoff.test_keeper_exit_falls_back_to_turnover_room`,
  `test_keeper_7702_keeps_gas_reserve`.
