# SA audit round 1: response

Report: `docs/audit/sa_round1_report_1224.md` (1 Critical, 3 High, 8 Medium, 17 Low, 8 Info). Branch `sa-r1-fixes` off
`smart-account` (`591f787`). Root-cause analysis written before the fixes: `docs/audit/sa_round1_rootcause.md`.
The pooled vault is shelved: vault-only code (`LPVaultBase`, `UniV4LPVault`, `RiskBudgets`) is unchanged; the shared
issues from vault round 2 (`docs/audit/round2_report_1223.md`) are fixed where the SA path uses them.

| Commit | Scope |
|---|---|
| `c97f915` | Contracts (`LPManagerModule`, `SALib`, new `SAWindow`, `ElysiumCustodyEnforcer`), regression suite `test/sa/SARegressions.t.sol`, ported module tests, `SAHostile.sol` |
| `1f8f4e9` | Fork test (`test/fork/SmartAccount.fork.t.sol`) on the new semantics |
| `cdaa152` | Keeper (`sa_chain.py`, `sa_keeper.py`, ABI), keeper tests, web exit, `DeploySA` L-8 checks, design doc section 6 |
| docs commit (this file) | this file, `docs/audit_sa_round2.txt` |

Sizes (runtime, EIP-170 = 24,576): `LPManagerModule` 23,980 (596 margin), `SALib` 19,440 (linked), `ElysiumCustodyEnforcer`
7,802, `SwapExecutor` 3,402 (unchanged).

Tests: forge 177 offline (CustodyEnforcer 27, LPManagerModule 31, SARegressions 33, plus the unchanged vault suites);
fork `ELYSIUM_FORK=true` 10 (SA 3 + vault 7) against `https://rpc.elysium.kinetiq.xyz`; keeper pytest 53 (incl. the anvil-fork
SA end-to-end and vault end-to-end). Regression tests are named `test_<ID>_PoC_*` (the auditor's scenario) and
`test_<ID>_Sibling_*` (another path of the same root cause).

## Root-cause classes (one line each)

- **A** Client-controlled code was trusted for identity, consent and transfer outcomes. Now: identity by CREATE2 derivation / 7702 designator, owner pinned, transfers verified at the recipient, post-checks after every action, code/owner change = revocation.
- **B** Flow snapshots were the caller's job. Now: `SALib.sync` books AND re-snapshots in one step on every path.
- **C** The delegation was not pinned. Now: one stored delegation per account; a different one, or resuming after a revoke, needs the client; enforcer state is keyed by (delegator, terms hash).
- **D** Value at unbanded spot / stale anchor. Now: value at the anchor with no spot term; sends and fees need a fresh, unclipped anchor within the pool band; no keeper-only hedge step on a stale anchor.
- **E** Budget primitive admitted 2x per day. Now: `SAWindow`, nine 3 h buckets, 1x in any 24 h window, symmetric charge.
- **F** Guardian approvals not bound to what was judged. Now: one-shot, TTL ≤ 1 day, bound to (account, epoch, stored value, value, guardian era); every margin move bumps the epoch; pause / guardian change clear them.
- **G** Shared treasury and pause semantics. Now: keeper returns bounded by the account's own hedge equity, margin always back into the account, pause stops custody growth and keeper-only equity cuts.
- **H** Exit liveness. Now: `revoke()` (no external calls, not pausable) + TRY-mode exit batch, checked by state.

## Findings

Status: **Fixed** (code + regression test), **Partly** (fixed as described, residual stated), **Ack** (acknowledged, documented, no code change), **Rebutted** (with reason).

| ID | Class | Status | Change | Tests (`test/sa/…` unless noted) |
|---|---|---|---|---|
| C-1 | A | Fixed | `SALib.accountKind`: hybrid accepted only at the CREATE2 address derived from the reported owner (canonical proxy, no P256 keys, fixed salt); treasury / fee recipient never owners; owner pinned; `onboard` pulls only from the pinned owner into that owner's account; 7702 accounts cannot take an amount | `SARegressions.test_C1_PoC_FakeAccountClaimingTreasuryOwner`, `test_C1_Sibling_CanonicalProxyOwnedByTreasury`, `test_C1_Sibling_OwnerRotatedAfterRegistration`, `LPManagerModule.test_Onboard_FundsOnlyIntoTheOwnersAccount` |
| H-1 | G | Fixed | Keeper return ≤ the account's `hedgeEquity` (`HedgeCap`); the treasury itself may return more; margin goes into the account (bound is equity, not net margin: see Rebuttals) | `test_H1_PoC_KeeperReturnBoundedByAccountEquity`, `test_H1_Sibling_BoundIsEquityNotNetMargin` |
| H-2 | A | Fixed | `SALib.transferOut` verifies the recipient's balance delta (`TransferMismatch`) and the account-side post-check; ledgers written after; `live()` re-checks 7702 designator / hybrid owner | `test_H2_PoC_UpgradedAccountDivertsHedgeMargin` (real UUPS upgrade), `test_H2_Sibling_UpgradedAccountDivertsFee`, `test_H2_Sibling_7702Redelegated` |
| H-3 | B | Fixed | `sync` writes the snapshot; zero-fee return no longer leaves a stale snapshot; every path (fee, report, return, multicall repeats) books once | `test_H3_PoC_ZeroFeeDoesNotDoubleBook`, `test_H3_Sibling_OtherPathsBookOnce` |
| M-1 | C | Fixed | Replacing the stored delegation or registering after `revoke` needs `msg.sender` ∈ {account, pinned owner} (`NotOwnAccount`) | `test_M1_PoC_OlderDelegationAfterExit`, `test_M1_Sibling_SameHashAfterRevoke`, `LPManagerModule.test_ReRegister_ByTheClientKeepsBooks` |
| M-2 | B | Fixed | `returnHedgeMargin` always syncs and snapshots, live or not, and pays only the account; `payoutAddress` removed | `test_M2_PoC_ReturnWhileNotLiveIsBooked`, `test_M2_Sibling_ExpiredThenClientWithdraws` |
| M-3 | F | Fixed | `approveHedgeEquity(a, expectedEpoch, expectedStored, value, until)`: registered, epoch and stored value must match, TTL ≤ 1 day, era-bound; send / return bump the epoch | `test_M3_PoC_MarginMoveVoidsApproval`, `test_M3_Sibling_StaleExpectationsAndGuardianChange` |
| M-4 | D | Fixed | `SALib.value` values positions as principal at sqrt(price) + uncollected fees at the given price (no spot term); `_fresh()` = recent, unclipped, anchor within pool band for sends and fees | `test_M4_PoC_ValueIgnoresSpot`, `test_M4_Sibling_BandAndAgeOnEveryValuePath` |
| M-5 | A | Fixed | Subscribed positions refused (`Subscribed`) on increase / decrease / burn; mint read back (`BadMint` incl. subscriber bit); directional post-checks; decrease / burn value-conservation check at the pool price (sibling found while testing) | `test_M5_PoC_SubscribedPositionRefused`, `test_M5_Sibling_AccountCodeDrainsInsideBracket`, `test_M5_Sibling_SubscribeInsideMint` |
| M-6 | C | Fixed | Enforcer state `_spend[delegator][keccak(terms)]`; `spend(delegator, termsHash)` view | `CustodyEnforcer.test_M6_StateKeyedByTerms`, `test_M6_PoC_SecondDelegationCannotConsumeModuleLimits` (end to end through the DM), `test_M6_Sibling_RenewalKeepsWindow` |
| M-7 | E/F | Partly | `SAWindow` for turnover, hedge step, anchor drift and the enforcer hedge limit (1x per any 24 h); anchor step charged \|Δ\|/min both ways; guardian price range one-shot, charged, validated, cleared by pause / guardian change. Residual: the anchor is still referenced to pool spot (no on-chain HL price); against the market a walked anchor is bounded by drift (10%/24 h) + band | `test_M7_PoC_TurnoverOncePerSlidingDay`, `test_M7_Sibling_AnchorWindowBothWays`, `test_M7_Sibling_HedgeStepSlidingWindow`, `test_M7_Sibling_GuardianRangeOneShot`, `LPManagerModule.test_H2_AnchorMovesOnlyWithinBudgetAndFreezesWhilePaused`, `CustodyEnforcer.test_HedgeBudget_35PercentPerSliding24h` |
| M-8 | H | Fixed | `revoke(a)` by the account or pinned owner (no external calls, not pausable); exit batch = revoke + disable + burns in ERC-7579 TRY mode; web and keeper check `account(a).revoked`, not the tx status | `test_M8_PoC_RacingBurnDefaultModeFailsSilently_TryModeExits`, `test_M8_Sibling_DirectRevokeAndRacing7702`, `LPManagerModule.test_Exit_*`, fork + keeper e2e exits |
| L-1 | C | Fixed | `until > type(uint64).max` → `BadDelegation(6)` | `LPManagerModule.test_Register_Rejects` |
| L-2 | B | Fixed | Base / liquidity inflows at min(anchor, pool), outflows at max; re-registering the stored delegation is a no-op | `LPManagerModule.test_Fee_DepositsAndWithdrawalsAreFlowsNotProfit` |
| L-3 | A | Partly | Failure reason copied ≤ 256 bytes; `owner()` probe gas-capped (30k), `isValidSignature` 200k. No per-entry gas stipend: `multicall` is keeper-only, so a griefing account only delays the keeper's own batch, which the keeper re-sends without that entry | `test_L3_MulticallTruncatesReason` |
| L-4 | G | Fixed | A guardian-approved equity writes `netMargin` down to it | `test_L4_ApprovedEquityWritesNetMarginDown` |
| L-5 | C | Fixed | Caveat `args` must be empty, signature exactly 65 bytes (`BadDelegation(9)`) | `LPManagerModule.test_Register_Rejects` |
| L-6 | G | Fixed | `sendHedgeMargin` is `whenNotPaused`; keeper-only equity decreases are frozen while paused (cap 0); returns and decreases / burns stay open | `LPManagerModule.test_M6_PauseStopsRiskNotExits` |
| L-7 | F | Fixed | `approvePrice`: lo > 0, lo ≤ hi, TTL ≤ 1 day; `approveHedgeEquity` requires registration; a refused report changes neither epoch nor approval; `setGuardian` bumps the era and clears the range | `test_M3_Sibling_StaleExpectationsAndGuardianChange`, `test_M7_Sibling_GuardianRangeOneShot`, `LPManagerModule.test_H1_HedgeEquityOnlyDownWithoutGuardian` |
| L-8 | G | Fixed | Constructor and setters: owner, keeper, guardian, treasury, fee recipient, module pairwise distinct; `DeploySA` checks the same and that the gator contracts exist. Treasury approval size stays an operator step (documented) | `LPManagerModule.test_L8_L13_RolesAndParams` |
| L-9 | B | Fixed | `increasePosition` counts the position's uncollected fees in `v0` | covered by `test_H3_*` add checks; `test_M5_PoC_SubscribedPositionRefused` (increase path) |
| L-10 | B | Fixed | `mintPosition` syncs before the `MAX_POSITIONS` check | `test_L10_MintAfterClientBurnAtMaxPositions` |
| L-11 | B | Fixed | Fee = min(full, 20% of idle); the mark advances only by the gain charged (`hwm + fee·BPS/feeBps − fee`) | `LPManagerModule.test_Fee_NeedsFreshUnclippedPriceAndChargesAtMostTheIdleSlice`, `testFuzz_HwmFee`, keeper `test_hwm_fee_partial_matches_salib` |
| L-12 | D | Fixed | Per-account `hedgeClipped` and `hedgeTime`; `chargeFee` reverts `StaleHedge` if equity ≠ 0 and the last report was clipped or older than `maxPriceAge`; keeper refreshes first | `LPManagerModule.test_H1_HedgeEquityOnlyDownWithoutGuardian`, fork test |
| L-13 | A | Fixed | `checkMinted`: owner, truncated poolId, ticks, no subscriber, liquidity from PositionManager; flows and value use one per-position function; unowned positions dropped at sync | `test_M5_Sibling_SubscribeInsideMint`, `LPManagerModule.test_Fee_DirectBurnByClientIsNotAFlowOfValue` |
| L-14 | A | Fixed | `live()` = registered, not revoked, before expiry, 7702 codehash == designator / hybrid `owner()` == pinned owner; every keeper action reverts `NotLive` otherwise; `isActive` also checks the DM's disabled flag | `test_C1_Sibling_OwnerRotatedAfterRegistration`, `test_H2_Sibling_7702Redelegated` |
| L-15 | — | Ack | The enforcer is a destination guard; value bounds are the module's (min-out, sqrtPrice limit at the anchor band, add check, turnover). Stated in the design doc | — |
| L-16 | D | Fixed | Sends need `_fresh()`; the keeper-only hedge step is 0 on a stale anchor; flows booked at min/max of anchor and pool | `test_M4_Sibling_BandAndAgeOnEveryValuePath` |
| L-17 | A | Fixed (module) / Ack (upstream) | Every ERC-20 approval to Permit2 is reset to 0 in the same redemption. HybridDeleGator's raw-hash ERC-1271 is upstream behaviour; with no residual allowance a replayed Permit2 signature has nothing to pull through the module's paths | `test_L17_NoResidualAllowances` |
| I-1 | E | Fixed | Enforcer hedge limit is a 35% cap per sliding 24 h window (not a decaying rate) | `CustodyEnforcer.test_HedgeBudget_35PercentPerSliding24h` |
| I-2 | G | Ack | Immutable operator addresses; a USDC blocklist needs a new module. The owner-EOA payout no longer exists (margin returns into the account) | — |
| I-3 | — | Partly | `maxSlippageBps == 0` rejected. Hard-cap combinations and keeper deadlines unchanged (timelocked; documented) | `LPManagerModule.test_L8_L13_RolesAndParams` |
| I-4 | — | Ack | Timelock semantics as described; unchanged | — |
| I-5 | — | Fixed | Comments and design doc section 6 rewritten to the new semantics | — |
| I-6 | A | Ack | Racing account deploy reverts the relayer batch once (the relayer re-checks code before the next attempt) | — |
| I-7 | — | Ack | HWM is absolute profit, no clawback; documented | — |
| I-8 | — | Ack | Nitro timestamps; wall-clock clocks; the EIP-170 margin is now 596 B | — |

Vault round-2 items on the shared path:

| Vault ID | Status on the SA path |
|---|---|
| M-2 / L-1 / L-2 (RiskBudgets 2x window, re-basing, rounding) | Fixed for SA by `SAWindow` (module and enforcer); `RiskBudgets` unchanged for the shelved vault |
| H-2 (guardian price range reusable) | Fixed: one-shot, charged, validated, cleared by pause / guardian change |
| M-3 (hedge approval not bound to the judged state) | Fixed: bound to epoch + stored value + era, margin moves bump the epoch |
| L-7 (anchor age) | Fixed: `_fresh()` for sends and fees; no keeper-only hedge step on a stale anchor |
| L-4 (pause semantics) | Fixed: see L-6 above |

## Rebuttals and deliberate deviations from the suggested fixes

1. **H-1 bound = hedge equity, not net margin.** The report suggests bounding a keeper return by the account's net margin. After
   a realised hedge loss net margin exceeds the account's equity; returning net margin would pay one client's loss out of the
   other clients' margin in the shared treasury. The keeper may return at most the account's current hedge equity; anything above
   it is a treasury decision (`msg.sender == hedgeTreasury`).
2. **C-1 allowance fallback kept.** `onboard` still falls back to an existing allowance when the permit fails (front-run
   tolerance). It is not a bare allowance pull any more: the payer is the pinned owner derived from the account address, and the
   destination is that owner's own account, so the worst case is moving the owner's USDC into the owner's account.
3. **Enforcer state keyed by terms hash, not by delegation hash.** Keying by the delegation hash (as suggested for M-6) would let a
   client reset the 35% window by re-signing the same terms; keying by (delegator, terms) separates the client's own delegations
   (other terms) from the module's while renewals keep their history (`test_M6_Sibling_RenewalKeepsWindow`).
4. **No codehash pin for hybrid accounts.** The proxy's own code is immutable; the implementation slot is not readable from the
   module. Identity, payer, treasury / fee transfers, tracked positions and flows no longer depend on what an upgraded
   implementation does (A), so an upgrade can only harm the upgrading client. Stated as a residual in the root-cause doc.

## Acknowledged residuals

- LP fees collected by the client directly (its own decrease / burn / collect) are booked as a client inflow. This lowers profit and
  therefore the fee (client-favourable leakage, bounded by uncollected fees). Seen in the keeper e2e (~0.4% of the margin after a
  week of volume).
- The anchor's only on-chain reference is the pool; drift is bounded to 10% per 24 h plus the band (M-7 residual).
- Adds: account code draining inside a mint / increase bracket is bounded by the H-3 add check (slippage) and charged to turnover;
  removals are now exact (value conservation).
