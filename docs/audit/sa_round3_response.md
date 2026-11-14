# SA audit round 3: response

Reports (both at commit `ecb6eda`): `docs/audit/sa_round3_report_1226.md` (0 C, 0 H, 4 M, 22 L, 8 I) and
`docs/audit/sa_round3b_report_1227.md` (0 C, 0 H, 8 M, 27 L, 18 I, keeper K-1..K-13). Branch `sa-r3-fixes` off
`sa-r2-fixes` (`ecb6eda`). Root-cause analysis written before the fixes: `docs/audit/sa_round3_rootcause.md`
(classes F, S, R, T, P, A, G, O/K). Priorities used for every decision: client principal safety > liveness > accuracy
of our fee. A residual that can only lower the operator's fee is accepted and listed.

| Commit | Scope |
|---|---|
| `5dad034` | Contracts (`SABook` fee checkpoints, `SwapExecutor` calldata hash, new `SARange`, `SALib` range budget / fee gate / permit-once / hedge no-op, `LPManagerModule` trusted gate, `sync(a)`, fee at the anchor, Lows), `SAHostile` modes 7-8, new `test/sa/SARound3.t.sol`, existing suites on the new semantics |
| `9f758a0` | `VaultTimelock` (delay cap, `isExpired`, no proposer renounce, rotation NatSpec), `DeploySA` (code hashes, wiring, read-back), keeper (ABI, mirrors, policy), web comment |
| `35b2528` | Fork test and keeper e2e on the trusted-anchor gate; keeper re-checks trust between swap chunks |
| docs commit (this file) | this file, `sa_round3_rootcause.md`, `docs/audit_sa_round4.txt`, design doc section 6 |

Sizes (runtime, EIP-170 = 24,576): `LPManagerModule` 23,672 (904 margin; was 677), `SALib` 17,113 (linked),
`SABook` 6,993 (linked), `SARange` internal (inlined into SALib), `SwapExecutor` 3,774, `ElysiumCustodyEnforcer` 7,802
(unchanged), `VaultTimelock` 6,126.

Tests: forge 221 offline + 2 skipped (`SARound3` 19 new; `SARound2` 25, `SARegressions` 33, `LPManagerModule` 31,
`CustodyEnforcer` 27, `Smoke` 1, shelved-vault suites unchanged). Fork (`ELYSIUM_FORK=true`,
`https://rpc.elysium.kinetiq.xyz`): SA 3/3 at latest and at block 6100000. `DeploySA` simulated against the live chain
(no broadcast): all new code-hash and wiring checks pass. Keeper pytest 132 offline + 4 skipped; SA e2e and relayer-API
e2e on an anvil fork pass at latest and at 6100000.

## The question asked first: is 1227 M-2 a principal-loss path?

No. The substituted swap is paid from and to the client's own account by the client's own code; the record is keyed by
payer and written only inside the executor's unlock frame. The mis-booking changes only that account's profit, i.e. our
fee (down for a bad substituted trade; up at most by the gap the client's code itself paid for). No other account's,
third party's or operator's funds are reachable. Fixed anyway (class S), so the round-2 invariant has no exception.

## Status: Mediums

| ID | Finding (short) | Class | Status | Fix | Regression tests (`test/sa/`) |
|---|---|---|---|---|---|
| 1227 M-1 / 1226 M-1 | Client-collected LP fees booked as a contribution | F | Fixed | Per-position fee checkpoint `snapPos(id) = (liq, g0, g1)`; fees PoolManager paid out since the mark are yield, added to the snapshot before the flow (price-free) | `SARound3.test_M1_PoC_ClientCollectIsProfit`, `test_M1_Sibling_CollectToOutsideAndBurn` |
| 1227 M-2 | Swap record not bound to the module's swap | S | Fixed | Executor records `keccak256(msg.data)`; module requires its own call hash | `test_M2_PoC_SubstitutedSwapRefused`, `test_M2_Sibling_OtherDirectionRefused` (hostile modes 7, 8) |
| 1227 M-3 / 1226 M-3 | One pool read at the fee: walk + fee charges on the drift budget | P | Fixed (bounded residual) | `SALib.feeGate`: anchor not above the pool and within `poolBandBps` of its trailing 24 h low | `test_M3_PoC_WalkThenFeeGated`, `test_M3_Sibling_AnchorAbovePoolNoFee` |
| 1227 M-4 / 1226 M-4 | Booking at an anchor a full band from the pool (keeper edge / client timing) | T | Fixed (bounded residual) | Booking needs the pool within `BOOK_BAND_BPS` = 50 bps of the anchor; otherwise pending | `test_M4_PoC_NoBookingOffTheBookBand`, `test_M4_Sibling_SwapAndAddWaitForBand` |
| 1227 M-5 / 1226 M-2 (swap part) | Keeper chooses the booking moment; actions on pending funds | T | Fixed | Swaps / mints / increases need `_trusted()` (their sync books first); permissionless `sync(a)` | `test_M5_PoC_AnyoneBooksAtTrustedAnchor`, `test_M5_Sibling_SwapNeedsStableAnchor`; `LPManagerModule.t` H3 now expects `StalePrice` |
| 1227 M-6 / 1226 L-1 | Fee at min(V(anchor), V(pool)) after booking at the anchor | P | Fixed | Profit = V(anchor) − contributed after a sync at that anchor | `test_M6_PoC_ParkedDepositNeutral`, `test_M6_Sibling_ParkedWithdrawalNeutral` |
| 1227 M-7 / 1226 L-2 / 1226 M-2 (budget part) | Path-length drift budget; guardian jump fills it | R | Fixed | `SARange`: trailing 24 h (min, max), clamp to `[hi/(1+cap), lo(1+cap)]`; a guardian range resets it | `SARound2.test_M4_PoC*/Sibling*` (rewritten: 10 ±4% oscillations never clip; >10% net does), `SARegressions.test_M7_Sibling_AnchorWindowBothWays`, `test_M7_Sibling_GuardianRangeOneShot` |

## Status: Lows and Informationals

1226 report:

| ID | Status | Note |
|---|---|---|
| L-1 | Fixed | = 1227 M-6 |
| L-2 | Fixed | = 1227 M-7 |
| L-3 | Fixed | keeper-only decrease that cannot happen: no state change; full return clears `hedgeClipped` (`test_L3_HedgeFlagOnlyWhileItMatters`) |
| L-4 | Fixed | = 1227 M-2 (direction is in the hashed call) |
| L-5 | Fixed | trust needs a report within `minPriceStable`; a report after a longer gap is a move (`test_L5_ReportAfterGapIsAMove`) |
| L-6 | Acknowledged | a third party holding the pool off the band pauses booking / swaps / adds / fees; removals, returns, exits unaffected |
| L-7 | Fixed | permit `(owner, nonce)` used once (`test_L7_PermitFallbackOnce`) |
| L-8 | Acknowledged | multicall gas: the keeper batches one account per transaction |
| L-9 | Acknowledged | approval resets on 7702 wallets (documented to clients) |
| L-10 | Partly | keeper stop rule after 2 refused due dates (`sa.fee_refusals_stop`) |
| L-11 | Fixed (doc) | rotation NatSpec: step 2 only after step 1 executed; 2 × delay |
| L-12 | Fixed | per-operation delay ≤ `MAX_DELAY`; `isExpired(id)` (`test_L12_TimelockDelayCapExpiryRenounce`) |
| L-13 | Fixed | DeploySA: fixture code hashes, `POSM.poolManager()`, read-back of roles / wiring, probe from module getters |
| L-14 | Fixed | pre-registration `revoke`; `transferOwnership(0)` cancels (`test_L14_RevokeBeforeRegister`, `test_L_OwnershipCancelAndPauseRepeat`) |
| L-15 | Acknowledged | the enforcer bounds recipients; price bounds live in the module |
| L-16 | Acknowledged | a send the module allows can exceed the enforcer's 35%-of-idle; the keeper mirrors both |
| L-17 | Partly | `isActive` includes the DM pause; keeper actions stop, the client's exit does not |
| L-18 | Acknowledged | USDC blacklist of an immutable endpoint: redeploy |
| L-19 | Fixed (keeper) | sync of pending flows, fee-refusal rule, fee gate mirror |
| L-20 | Partly (keeper) | dust floor `sa.min_account_usd`; discovery unchanged |
| L-21 | Fixed (keeper) | hold only while the pool is inside the booking band; report failure never aborts the tick |
| L-22 | Fixed (keeper) | `minOut` = simulated output − 30 bps; removal minima from the burn slippage |
| I-1 | Acknowledged | client controls idle; the keeper frees USDC first |
| I-2 | Acknowledged | a treasury return above `hedgeEquity` is realised hedge PnL (profit) by design |
| I-3 | Fixed | comments updated (module header, SALib, VaultTimelock, DeploySA) |
| I-4 | No action | rounding against the client, ≤ 1 unit |
| I-5 | Acknowledged | see "stolen-keeper bound" below; pilot parameters lowered |
| I-6 | Acknowledged | module resets Permit2 allowances in the same redemption |
| I-7 | Acknowledged | profit accrued while revoked is charged after re-registration (stated to clients) |
| I-8 | Fixed (keeper) | swaps / adds only at a trusted anchor, after the sync |

1227 report:

| ID | Status | Note |
|---|---|---|
| L-1 | Partly (keeper) | = 1226 L-10 / I-1 |
| L-2 | Partly | one-unit decrease clearing the flag: a decrease applied in full is a real decrease; equal reports refresh `hedgeTime` (keeper-attested either way) |
| L-3 | Acknowledged | = 1226 L-6 |
| L-4 | Fixed | = 1226 L-5 |
| L-5 | Fixed | = 1226 L-7 |
| L-6 | Fixed | `onboard` reverts `NotLive` (`test_L6_OnboardNeedsLive`) |
| L-7 | Partly | adds need the pool within 50 bps of a trusted anchor; removals are exact against the same slot0 |
| L-8 | Acknowledged | = 1226 L-8 |
| L-9 | Acknowledged | partial fill reverts; the keeper halves the chunk |
| L-10 | Acknowledged | add charge weighting is conservative (more turnover charged) |
| L-11 | Acknowledged | `feeBps` changes are timelocked and apply forward from the next charge |
| L-12 | Fixed (doc) | = 1226 L-11 |
| L-13 | Partly | proposer cannot renounce; DeploySA requires a contract owner (multisig) unless `ALLOW_EOA_OWNER` |
| L-14 | Partly | cancel via `transferOwnership(0)`; no acceptance expiry |
| L-15 | Acknowledged | operator rule: the treasury approves just-in-time per return |
| L-16 | Fixed | = 1226 L-13 |
| L-17 | Acknowledged | = 1226 L-9 |
| I-1 | Fixed | treasury / fee recipient rejected before the 7702 branch |
| I-2 | Fixed | repeated `setPaused` reverts |
| I-3 | Fixed | = 1226 L-12 |
| I-4 | Acknowledged | multicall delegatecalls only this module's own functions, all role-checked |
| I-5 | Fixed | comments |
| I-6 | No action | rounding dust |
| I-7 | Acknowledged | `deposit` / returns use `safeTransferFrom` of USDC (no fee-on-transfer) |
| I-8 | Acknowledged | ECDSA-only onboard; a 7702 owner registers directly |
| I-9 | Acknowledged | sequencer clock |
| I-10 | Fixed | margin 904 bytes; assembly blocks marked memory-safe |
| I-11 | Partly | the guardian range resets the window; no width limit (guardian is trusted for that call) |
| I-12 | Acknowledged | fixed stipends on account staticcalls |
| I-13 | Acknowledged | = 1226 L-18 |
| I-14 | Acknowledged | the client registers the intended delegation itself |
| I-15 | No action | facts confirmed |
| I-16 | No action | no loss path (agreed) |
| I-17 | Acknowledged | = 1226 L-17 |
| K-1 | Fixed | swaps / adds only when trusted; `sync(a)` first |
| K-2 | Fixed | hold only inside the booking band, with a positive fee estimate |
| K-3 | Open | ledger reconciliation against chain events: before go-live beyond the pilot |
| K-4 | Partly | equity re-reported before the fee when old or clipped |
| K-5 | Partly | report failure isolated; per-action isolation inside an account not added |
| K-6 | Fixed | pool denominator; recency; booking band |
| K-7 | Fixed | `minOut` from simulation; the held anchor is never off the booking band |
| K-8 | Fixed | removal minima |
| K-9 | Acknowledged | serial loop; one report per tick |
| K-10 | Open | no quarantine for simulation / chain divergence |
| K-11 | Fixed | `ownerOf` in the reader; `sync(a)` drops moved positions |
| K-12 | Acknowledged | factory deploy kept strict (simulated first) |
| K-13 | Acknowledged | operator checklist: live adapter with live signer |

## Accepted residuals (each lowers only our fee, or is a stated keeper bound)

1. **Fees of an NFT the client moved out, and the fee share of a client partial decrease**, are not counted as yield
   (our fee lower).
2. **Several direct liquidity changes between two syncs** can count fees on the client's own added liquidity for part
   of the interval as yield (bounded by that liquidity's own fee income; self-inflicted).
3. **Client timing inside the 50 bps booking band**: ≤ 2 × 50 bps of contributed per round trip (our fee lower).
4. **Keeper booking at the band edge**: phantom gain ≤ 50 bps × flow, fee ≤ 0.075% of the flow (stolen keeper).
5. **Fee after a pool push**: a keeper that pushes the pool 1.5% and holds it `minPriceStable` charges on ≤ 1.5% ×
   base exposure × `feeBps` once per `feeInterval` (0.225% of exposure per week), paying the pool for it.
6. **Fee deferral in a rally**: the gate defers our fee up to a day (our fee only).
7. **Stolen-keeper oscillation inside the 10% range**: bounded by (band + slippage) × turnover ≈ 6% of NAV per day at
   the script defaults. For the pilot: `swapTurnoverBps` 5000, guardian bot pausing on anchor / HL divergence.
8. **Liveness**: anyone holding the pool > 50 bps off the anchor pauses booking, swaps, adds and fees (not removals,
   returns or exits).
9. Unchanged from round 2: hedge equity is keeper-attested (increases need the guardian); multicall gas; 7702 approval
   resets; partial fills; LP-add turnover weighting; `feeBps` change; timelock role layout; USDC blacklist; treasury
   return allowance (approve just-in-time).

## Rebuttals

- **1226 M-4 "book at the worse of anchor / pool"**: not adopted, for the round-2 reason (two prices make a round trip
  non-zero and repeatable). The booking band removes the cause (an anchor far from the pool) on both sides with one
  price; residuals 3 and 4 are the bound.
- **Path-length backstop for the drift budget**: dropped; any path budget either never binds or freezes the anchor on a
  volatile day (realised path ≈ σ² / hysteresis). Residual 7 is stated instead.
