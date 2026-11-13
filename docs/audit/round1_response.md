# Audit round 1: response

Report: `docs/audit/round1_report_1222.md` (3 High, 10 Medium, 17 Low, 4 Info). Branch `audit-r1-fixes`.

Commits:

| Commit | Scope |
|---|---|
| `e46504b` | Vault: price anchor, hedge/turnover budgets, LP-add value check, queue and liveness fixes, `RiskBudgets` library |
| `884629a` | Timelock: mixed batches, expiry, delay cap |
| `15ffb2b` | Deploy script validation |
| `b49ea47` | Regression suite `test/AuditRound1.t.sol` + fork tests |
| `7dac385` | LP adds charged to turnover weighted by their loss bound |
| `e3f61f1` | Keeper follows the new semantics |
| docs commit (this file) | `DESIGN.md`, `README.md`, this file, `docs/audit_round2.txt` |

Tests: `test/AuditRound1.t.sol` (unit, mock venue) and `test/fork/UniV4LPVault.fork.t.sol` (Elysium fork,
`ELYSIUM_FORK=true`). Every High and Medium has at least one regression test.

## Root cause and the shared fix

H-1, H-2, H-3, M-4, M-9 and M-10 have one root cause: the keeper's inputs (price, hedge equity, LP adds) were each
bounded against a base the keeper itself could move (pool spot, a NAV inflated by a deposit, an anchor that
`settle` rewrote, or nothing). The fix is one mechanism, not six patches:

- a single **price anchor** `lastPrice` that only `settle` moves, at most `refDriftBps` per decaying day, frozen
  while paused, freely only inside a guardian-approved range;
- `settle`, `swap`, `mintPosition`, `increasePosition` all check the keeper price against the pool band AND the anchor;
- three budgets (anchor, hedge equity, turnover) on one decaying-day primitive (`RiskBudgets`), all relative
  (WAD fraction or `lastNav`, which never contains the settling epoch's deposits);
- a report that exceeds a budget is **clipped, never reverted**: redemptions still settle, deposits and fee wait.

## High

| ID | Status | Fix | Tests |
|---|---|---|---|
| H-1 | Fixed | The keeper alone can only lower hedge equity, within `hedgeStepBps` x `lastNav` per decaying day; `lastNav` is the pre-deposit NAV. Increases need the guardian's exact `approveHedgeEquity(value, until)`, bound to the epoch, one-shot. A fake increase (the amplified direction) is impossible without two keys; an understatement is bounded on the pre-deposit NAV, which an accomplice cannot inflate. | `test_H1_AccompliceDepositCannotFundFakeHedgeEquity`, `test_H1_UnderstateBoundedByBudgetOnPreDepositNav` |
| H-2 | Fixed | `settle` moves the anchor toward the reported price within the anchor budget (relative, compounding: <= e^0.1 per block, ~e^0.2 per 24 h at defaults); a clipped settlement applies the budget edge, mints no shares, takes no fee. A pushed spot can no longer rebase the anchor that every other check uses. | `test_H2_PushedSpotCannotRebaseAnchorOrMintCheapShares`, `test_H2_EmptySettlesWalkAnchorOnlyAtBudgetRate` |
| H-3 | Fixed | Mint/increase: keeper price within band of pool and anchor; the vault measures what it paid (drop of held value at the anchor) and the new liquidity's value at the anchor (`V4PositionMath.liquidityValue`), reverts `AddValue` if value < paid x (1 - `maxSlippageBps`); paid is charged to turnover weighted slippage / (band + slippage), so one turnover unit always stands for the same worst-case loss. | `test_H3_AddsChargeTurnoverAndNeedAnchorBand`, `test_fork_H3_LimitOrderMintAtDisplacedSpotReverts`, `test_fork_H3_MintChargesTurnover` |

## Medium

| ID | Status | Fix | Tests |
|---|---|---|---|
| M-1 | Fixed | `settle` reverts `NoHedge` if an unhedged vault reports equity; `_setParams` requires `hedgeStepBps == 0` without a treasury; Deploy forces cap/step to 0. | `test_M1_UnhedgedVaultRejectsHedgeEquity` |
| M-2 | Fixed | Approval binds value, epoch and an expiry (`until`), is consumed once, and is cleared by any `sendHedgeMargin` / `returnHedgeMargin`. | `test_M2_ApprovalClearedByMarginMoveAndExpires` |
| M-3 | Fixed | `VaultTimelock.scheduleBatch` reverts `MixedBatch` when a batch mixes self-targets and other targets, so the guardian can always cancel a vault operation. | `test_M3_MixedBatchRejected` |
| M-4 | Fixed | In-band skew now moves the anchor, which is budgeted per decaying day; alternating settlements consume the budget both ways. | `test_M4_BandSkewHarvestBoundedPerDay` |
| M-5 | Fixed | `netMargin` = sent - returned; the cap applies to `max(hedgeEquity, netMargin) + amount`. | `test_M5_CapOnNetMarginNotReportedEquity` |
| M-6 | Fixed | While paused: anchor budget 0 (frozen unless the guardian approves a range), no fee, no deposits, hedge increases only with approval. Redemptions continue (design rule: no limit blocks a withdrawal). | `test_M6_PauseFreezesNavInputsButNotExits` |
| M-7 | Fixed | The redeem head is filled partially with all idle USDC; the liveness clock `lastProgressTime` advances only when locked shares decrease or the queue is empty, so a keeper that settles without paying cannot hold off `emergencyUnwind`. | `test_M7_PartialFillAndLivenessMeasuresProgress` |
| M-8 | Fixed | `emergencyRedeem` reverts `PositionsOpen` while positions remain, until 7 days after the emergency started; `_unwindAll` requires >= 1M gas before each burn attempt (`UnwindOutOfGas`), so a caller cannot induce a failed burn by under-supplying gas. Emergency is now two-step (arm, execute >= 6 h later) and needs epoch != 0. | `test_M8_NoEmergencyRedeemWhilePositionsOpen`, `test_M8_GraceAfterSevenDays`, `test_fork_M8_UnwindOutOfGasReverts` |
| M-9 | Fixed | The hedge budget now charges only decreases (honest small up/down moves no longer accumulate as absolute drift); it decays continuously; an over-budget report is clipped, not reverted, so redemptions never stall and the keeper never needs to report a known-stale value (it reports the real one; the vault applies what the budget allows). | `test_M9_OverBudgetMoveDoesNotBlockRedeems` |
| M-10 | Fixed | Swaps and adds check the keeper price against the anchor as well as the pool, so the per-swap loss against the anchor is band + slippage; the anchor itself moves only within its budget. | `test_M10_SwapAtDriftedSpotRefused` |

## Low

| ID | Status | Notes / tests |
|---|---|---|
| L-1 | Fixed | Decaying-day budgets (no window to anchor); <= ~1.6x budget in any 24 h. `test_L1_NoDoubleBudgetAtWindowEdge` |
| L-2 | Fixed | Emergency needs epoch != 0; the liveness clock is the progress clock; the first settle is still gated by the pool band. Covered in `test_M7_*` |
| L-3 | Fixed | The 10% emergency band was removed (exit is in kind; it only delayed honest exits). Replaced by the two-step 6 h notice. Updated `LPVaultBase.t.sol` emergency tests |
| L-4 | Acknowledged | Sequencer downtime still counts toward 72 h. The two-step arm (6 h notice, any progress-making settlement disarms it) gives a resumed keeper a window. No on-chain sequencer-uptime feed on Elysium. |
| L-5 | Fixed | `claimTo(to)`; failed cancellation pushes credit `claimable`. `test_L5_ClaimToAndBlockedCancel` |
| L-6 | Fixed | The USDC leg of `emergencyRedeem` uses the push-or-credit path; one blocked leg no longer reverts the others. `test_L6_EmergencyRedeemNotAllOrNothing` |
| L-7 | Fixed | `_update` rejects transfers to the vault; constructor checks `feeRecipient != this`. `test_L7_NoStrayVaultShares`, `test_L13_L17_ConstructorValidation` |
| L-8 | Fixed | Zero-share deposits are refunded to `claimable`; zero-asset redeems are refused. `test_L8_ZeroShareDepositRefunded` |
| L-9 | Partly fixed | Deploy default delay 96 h, and Deploy requires > 72 h (also for a reused timelock). The contract floor stays 24 h for other deployments; documented. |
| L-10 | Fixed | Ready operations expire after `GRACE_PERIOD` = 7 days. `test_L10_L11_TimelockExpiryAndDelayCap` |
| L-11 | Fixed | `MAX_DELAY` = 30 days on construction and `updateDelay`. Same test |
| L-12 | Fixed | `renounceOwnership` reverts. `test_L12_RenounceDisabled`. (A pending `Ownable2Step` owner does not expire; the owner is the timelock, so a new transfer simply replaces it.) |
| L-13 | Fixed | keeper != guardian enforced in constructor and setters; Deploy checks chain id, role distinctness and a reused timelock's code, delay and roles. Guardian rotation is now two timelock operations (vault, then timelock roles) because mixed batches revert. `test_L13_L17_ConstructorValidation` |
| L-14 | Fixed | Deploy validates `HEDGE_CAP_BPS <= 5000` before narrowing. |
| L-15 | Acknowledged | `swap` keeps its own min-out (fair value at the keeper price minus slippage). A delayed transaction is bounded by the anchor band check; a caller deadline adds bytes for no extra bound. |
| L-16 | Fixed | `sendHedgeMargin` allowed while paused; DESIGN/README list exactly what pause stops. |
| L-17 | Fixed | Constructor requires `wrappedBase` to have code. `test_L13_L17_ConstructorValidation` |

## Informational

| ID | Status | Notes |
|---|---|---|
| I-1 | Fixed (docs) | HWM and hedge-step wording corrected in DESIGN/README. |
| I-2 | Fixed | `poolManager.sync(address(0))` before the native settle in `unlockCallback`. Covered by the fork swap tests. |
| I-3 | Fixed | Pragma pinned `0.8.26`; Deploy asserts USDC 6 / WHYPE 18 decimals and v4 contract code. |
| I-4 | Done | UniV4LPVault runtime 24,326 B (EIP-170 margin 250 B) after moving budgets into `RiskBudgets` and calldata encoding into `V4PositionMath`. Further additions must come out of the vault. |

## Leads

- Late hedge-margin return in wind-down: unchanged accepted risk (DESIGN "Accepted risks").
- Turnover scaling with a transient deposit: turnover is now on `lastNav` (pre-deposit) and the anchor bounds every
  swap; no amplification remains beyond the documented (band + slippage) x turnover.
- Code-executing keeper inside `unlock`: zero-capital spot displacement can no longer rebase the anchor; it can only
  skew within the band and the anchor budget, the same bound as an EOA keeper.

## Residual risk (stated, not fixed)

- Price channel with accomplice capital: NAV error = base exposure x anchor movement, so capital converted to base
  before a walk scales it. Bounded by the anchor's daily rate, the pool band at every report and the guardian pause;
  there is no trustless price feed on Elysium to remove it. Worst case at defaults ~5-8% of NAV per day.
- A keeper can withhold a real hedge loss (stale reporting); only the guardian bot (HL comparison) can detect it.
- In a market that moves faster than the budgets, clipped settlements price redemptions at the clipped values;
  guardian co-signatures (`approvePrice`, `approveHedgeEquity`) remove the clip. The keeper waits up to 2 h for them
  when redeems are queued.
