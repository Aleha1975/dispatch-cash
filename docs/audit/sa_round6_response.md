# SA audit round 6: response

Report (commit `0fe4d85`, branch `sa-r6`): `docs/audit/sa_round6_report_1252.md` (0 C, 0 H, 1 M, 4 L, 14 I). Fixes on
branch `sa-r7` off `0fe4d85`, one commit. Priorities used for every decision, unchanged: client principal safety >
liveness > accuracy of our fee. A residual that can only lower the operator's fee is accepted and listed. Where a fix
had to choose between exact fee accounting and a rule that cannot charge principal, we chose the second.

Sizes (runtime, EIP-170 = 24,576): `LPManagerModule` 24,240 (336 margin; was 24,097 / 479), `SALib` 19,308 (linked;
was 19,222), `SABook` 8,491 (linked; was 8,180). `SwapExecutor` 3,774, `ElysiumCustodyEnforcer` 7,802, `VaultTimelock`
6,155 and `V4PositionMath` 6,059 are unchanged. The new logic sits in the libraries (`SABook._late`, `SABook._dirty`,
`SARange.since`, `SALib.movePrice` / `feeGate` / `register`); the module only passes `priceBudget` and `lastPrice` on.

Tests: forge 265 offline + 2 skipped (was 256 + 2). New `test/sa/SARound6.t.sol` (9 tests). It was run with the new `SATestBase.sol` against
the sources of `0fe4d85`: the 7 finding tests fail there and pass now. The wick PoC charges a 540 USDC fee on
principal on `0fe4d85` and 0 now. The L-1 PoC books 87.5 USDC of yield PoolManager never paid, now ≤ 5. The L-2 PoC and
the deposit sibling charge 48 USDC each, now ≤ 1. The other 2 tests (a flat market raises nothing; the hybrid exit with
the module and the DelegationManager paused) are sanity and coverage and pass on both. Fork (`ELYSIUM_FORK=true`,
public RPC, read only): SA 3/3 (the hybrid end-to-end confirms the level before its fee). The pooled-vault `test_fork_FullLifecycle` still fails with `BadPrice` as before (pooled code untouched, out of scope). Keeper pytest 215 offline + 4 skipped (was 213 + 4). Keeper anvil e2e: 4/4 (SA, relayer API and pooled; they deploy with the `DeploySA` script). The SA e2e now has the guardian confirm the level before the weekly fee step.

## The answer asked for first

The report finds no path by which anyone moves principal to an address other than the account, the pool,
`hedgeTreasury` or `feeRecipient`, and no way to block an exit. Its one Medium and four Lows are fee-on-principal
paths. All five are fixed:

- **M-1** (a flow booked after an anchor round trip pays a fee on principal): every priced booking now raises the
  high-water mark by the largest gain the flow can have had at **any price the keeper reported** since the account's
  previous priced booking, both anchors included (Option B of the report, with Option A's anchors). Beyond 24 h without
  a priced booking the raise is the whole priced value.
- **L-1** (another pending position is room for a credit): no credit at all in a sync where any tracked position is
  pending.
- **L-2** (first booking after registration): registration stores the anchor and the time, so the first booking is
  raised like every other.
- **L-3** (stale confirmed level above the market): a fee needs the guardian's confirmation within the last day.
- **L-4** (keeper picks the level inside a wide range): a guardian range is at most 2 × `poolBandBps` wide (3% at the
  pilot values).

The pilot rule ("nobody modifies tracked NFTs directly") stays until this round is verified.

## Status: Medium

| ID | Finding (short) | Status | Fix (where) | Regression tests (`test/sa/SARound6.t.sol`) |
|---|---|---|---|---|
| M-1 | The SA-5 M-4 adjustment measures from `bookPrice`, so a flow made at a third price and booked after an anchor round trip pays a fee on principal | Fixed: Option B (reported extremes) with Option A's anchors and a long-gap rule | (1) `SALib.PriceBudget.seen`: a new `SARange` ring (nine 3 h buckets, 24–27 h) of every keeper report, written in `SALib.movePrice` (so it costs the module no bytes). Each report was within `poolBandBps` of the pool when made. (2) `Account.bookTime`: the time of the account's last priced sync (and of its first registration, L-2). (3) `SARange.since(ring, price, bookTime)`: the min and max of every bucket from `bookTime`'s bucket on, and whether that bucket is still in the ring. (4) `SABook.sync` → `_late`: `[lo, hi]` = those extremes together with `bookPrice` and this anchor; `hwm += ceil(priced × max(hi − price, price − lo) / lo)` (`SafeCast`, I-9). If `bookTime`'s bucket has left the ring: `hwm += priced`. Every priced sync writes `bookPrice` and `bookTime`. Why it covers the flow: a base amount or an LP position has a value V(P) that is concave with V(0) ≥ 0, so \|V(P′) − V(P)\| ≤ V(P) × \|P′ − P\| / P for any P′; here V(P) is the flow's part of `priced` and P′ any price in `[lo, hi]`. Only `hwm` rises: the fee can only be lower. (5) Keeper: re-books every active account at a trusted anchor at least every 3 h (a zero-flow `sync` only refreshes `bookTime`), so the long-gap rule is the outage case, and books a pending flow at the first trusted moment (as before). | `test_M1_PoC_WickRoundTripNoFeeOnPrincipal` (the report's trace, a 30% wick, the keeper reporting; fee 540 USDC on `0fe4d85`, 0 now), `test_M1_Sibling_DepositInSpikeBookedAfterReturn` (48 → ≤ 1 USDC), `test_M1_LongGapRaisesWholePricedValue`, `test_M1_FlatMarketPricedFlowRaisesNothing` (sanity: no reported move, no raise) |

## Status: Lows and Informationals

| ID | Status | Note |
|---|---|---|
| L-1 | Fixed (recommended fix) | `SABook._dirty`: if any tracked position is not owned or PoolManager's liquidity differs from the books', `_feesOut` gets `n = 0` for every position in that sync. Residual 2 restated below (`test_L1_PoC_OtherPositionPendingIsNoRoom`: 87.5 USDC of yield on `0fe4d85`, ≤ 5 now). |
| L-2 | Fixed (recommended fix, in the library) | `SALib.register(…, price)`: a first registration sets `bookPrice = lastPrice` and `bookTime = now` with the rest of the books. The module passes `lastPrice` (it is non-zero: `NoAnchor` otherwise). A re-registration after a revoke keeps both (they can only be older: a larger raise) (`test_L2_PoC_FirstBookingAfterRegistrationAdjusted`: 48 USDC on `0fe4d85`, ≤ 1 now). |
| L-3 | Fixed (the report's second option) | `PriceBudget.baseTime` is written with every write of `base` (the first report and every report that consumes a guardian range). `SALib.feeGate` reverts `StalePrice` when `now > baseTime + 1 day` (`CONFIRM_TTL`). This turns the go-live item "confirm before each weekly fee run" into a rule. Cost: no fee without a confirmation within the day (liveness of our fee only). Keeper: `GlobalSnap.base_fresh`, the fee waits and raises `fee_needs_confirm` with a ±0.5% range (`test_L3_FeeNeedsRecentConfirmation`). |
| L-4 | Fixed (recommended fix) | `approvePrice` passes `2 × params.poolBandBps` as the width cap (3% at the pilot values; was 10%). The keeper's report still picks the point inside the range: residual 7 states it (`test_L4_GuardianRangeAtMostTwoBands`; `SARound5.test_I1_*` and `SARegressions.test_M7_Sibling_GuardianRangeOneShot` updated). |
| I-1 | Documented (keeper rule) | The NatSpec no longer says "multicall over many accounts": the keeper batches one account per multicall (the keeper already sends one account's actions per transaction). Not enforced on chain (module bytes). The loss is bounded by `maxSlippageBps` and `BOOK_BAND_BPS` as for public MEV. |
| I-2 | Accepted (covered by M-1) | A third party who pushes the pool into the 50 bps band before a keeper call still chooses whether that call books. The booking's price no longer matters beyond the reported range: the M-1 raise covers the flow at every reported price. Pricing those paths at 0 would also make priced bookings rarer (larger raises). |
| I-3 | Go-live list | The sequencer operator and `maxTimeVariation` go in the runbook, with the delayed-inbox `revoke` path. The guardian bot pauses on timestamp skew. |
| I-4 | Go-live list | Confirm the level (`approvePrice`) in the same operation that lowers `refDriftBps`. |
| I-5 | Accepted | The cap is about 36.75% of market value instead of 35%, to `hedgeTreasury` only, with a stolen keeper and a pool push. |
| I-6 | Accepted | Needs both the keeper and the guardian (two roles). |
| I-7 | Runbook | No standing Permit2 allowance on an account; the owner EOA signs no Permit2 permit for tokens its account holds. Not usable today (the module resets the allowance in the same redemption). |
| I-8 | Accepted | Fee deferral only (operator's fee). The report's suggested replacement is cut off in the rendering (`max(`); we keep 1% of \|contributed\| (`sync` has no nav). |
| I-9 | Fixed | `SafeCast.toInt256` on the raise (`SABook.sync`). |
| I-10 | Documented | Residual 7 restated against market value (about 21.5% per 24 h at the pilot values instead of 19.5%). |
| I-11 | Documented | A client who rotates the hybrid owner after a key leak should also `revoke`; the old owner keeps `sync` and `revoke`, with no fee or principal effect (the module is not live after the change). |
| I-12 | Accepted | A lower `hedgeEquity` only lowers the keeper's return cap; the treasury can still return the margin. |
| I-13 | Accepted | The client signed both delegations; it can revoke or replace the stored one. |
| I-14 | Documented | Both cases are named in residuals 1 and 2 below. |

Report section 4 recommendation, "no test covers the hybrid handleOps exit or `disableDelegation` while the DM is
paused": added `test_Exit_HybridHandleOpsWithModuleAndDMPaused`. With the module and the DelegationManager both
paused, one `EntryPoint.handleOps` transaction from the owner revokes, disables the delegation and burns the position
into the owner. It passes on both commits, which confirms the agent's anvil observation.

## Accepted residuals (each lowers only our fee, or is a stated bound)

1. **Fees of a position the client changed** (collect plus a liquidity change, decrease, increase, burn, transfer) are
   not counted as yield. They become a contribution when the flow is booked (our fee lower). The same holds for a
   client collect while idle is below the snapshot in either token (SA-5 M-1), and (SA-6 L-1) for every collect in a
   sync where any tracked position is pending. A second client collect after a sync can still be voided, because the
   global-growth interval starts at the next look, not at the collect (I-14 (a)). Fees the client collected to an
   outside address leave the profit.
2. **Dip and restore between two looks** (restated per L-1 and I-14). The credit needs no tracked position pending, the
   position itself unchanged now and at the last look, and both tokens at or above the snapshot. It is at most
   min(L × the position's own fee-mark growth over the interval, the idle surplus in each token). The mark growth is
   at most L × the pool's global growth, and the client's own swaps or a donation during the dip can raise it. The
   surplus can still come from a direct top-up outside `deposit`, from an untracked position, or from real fees in the
   other token above the mix deficit. A position the client empties (both ticks cleared) and refills can pass the
   re-base guard on a new growth basis, still within L × ΔG and the room (I-14 (b)). Only the client's own direct
   action on its own NFTs starts any of this. The pilot rule holds.
3. **Client timing inside the 50 bps booking band**: ≤ 2 × 50 bps of contributed per round trip (our fee lower).
4. **Late booking (restated, M-1)**: the raise covers the flow at every price inside the recorded range (the
   previous booking's anchor, every keeper report since that booking's 3 h bucket, this anchor). Not covered: a market
   excursion **between two keeper reports** beyond the recorded range (the keeper reports at least every 120 s at the
   pilot values), and a keeper that **stops reporting** while the market moves (a stolen or failed keeper; the fee
   still goes only to `feeRecipient`). The fee on principal is then at most `feeBps` × \|flow\| × (the excursion
   beyond the recorded range) / price, once. Beyond 24 h without a priced booking the raise is the whole priced value:
   that covers any outflow (its value at the flow cannot be below 0) and an inflow made at up to twice the booking
   price.
5. **Fee after a pool push (restated, L-3)**: the gate admits an anchor at most `poolBandBps` above the lower of its
   trailing 24 h low and a level the guardian confirmed **within the last day**. Against the market the phantom adds
   the market's move since that confirmation (at most one day) and the keeper's choice inside the guardian's range
   (≤ 2 × `poolBandBps`, L-4), times base exposure × `feeBps`, once per HWM level.
6. **Fee deferral**: in a rally (until the guardian confirms the new level); without a confirmation in the last day
   (L-3); for a day after a material (≥ 1% of contributed) priced client flow; and by the M-1 raise. That raise applies
   to every priced flow, sized by the reported range since the previous booking's bucket, even when the flow really
   happened at the booking price. With the keeper re-booking every 3 h this is about the range of the last 3–6 h. A
   flow booked after an outage longer than the ring, or the first booking after a re-registration that follows a long
   revoke, raises the mark by its whole priced value. Our fee only.
7. **Stolen-keeper bound (restated, L-4 / I-10 / I-3)**: the anchor never goes more than `refDriftBps` from the
   confirmed level. The confirmed level is any point of the guardian's range that the keeper reports, so it can sit
   up to 2 × `poolBandBps` (3%) from the guardian's own bound. A trade is never worse than about (`refDriftBps` +
   `poolBandBps` + `maxSlippageBps`) from that level (13% at the pilot values). Per 24 h, at most (`swapTurnoverBps` +
   `exitTurnoverBps`) × nav can be traded at that gap: 19.5% of nav at the anchor, about 21.5% of market value (nav is
   measured at the anchor). `checkParams` caps the product at 40%. The 24 h windows trust the sequencer's clock (I-3).
   Controls: the guardian bot's pause on the anchor / HL gap and on timestamp skew, and the confirmation duty.
8. **Liveness**: a third party holding the pool > 50 bps off the anchor pauses booking, swaps (the risk-off exit sale
   included), adds and fees. When the market moves more than `refDriftBps` from the confirmed level, the anchor waits
   for the guardian. A lowered `refDriftBps` can freeze the anchor until the guardian confirms (I-4). New: no fee
   without a confirmation within the day (L-3). Removals, margin returns and the client's own exit are never affected.
9. **Risk-off in a fast market**: unchanged. The exit sale needs a trusted anchor and no pause; in a fall beyond
   `refDriftBps` from the confirmed level it waits for a guardian `approvePrice`.
10. **LP capacity**: unchanged (adds charged 1:1).
11. Unchanged from rounds 2–5: hedge equity is keeper-attested (increases need the guardian); the hedge cap with a
    walked anchor (I-5); keeper and guardian together can write `netMargin` down (I-6); multicall gas and one account
    per multicall (I-1); 7702 approval resets and Permit2 (I-7); partial fills; `feeBps` change; timelock role layout;
    USDC blacklist; treasury return allowance (approve just-in-time); anyone may register a delegation the client
    signed (I-13).

## Where we read the report differently

- **M-1, which option.** Option A (the anchor range) misses a market spike beyond the anchor, as the report says; the
  anchor is bounded by its drift budget, but the market during an untrusted period is not. We took Option B, with two
  changes. First, a global (min, max) reset at every account's priced sync would need per-account epochs. Instead we
  keep a 24 h ring of 3 h buckets of reports and query it from each account's `bookTime` bucket. That is a superset of
  the interval (fee lower, never higher). Second, the ring does not reach past 24 h, so an older `bookTime` takes the
  whole priced value; the keeper refreshes every account's booking every 3 h, so this is the outage case. We kept the
  report's conservative denominator `min(lo, price)`. By concavity `price` would suffice, but the cost is only fee.
- **M-1 does not close the unreported excursion.** No on-chain record can show a price between two reports, or while
  the keeper does not report. The report's Option B has the same limit. It is residual 4, bounded by `feeBps` × flow ×
  the unrecorded excursion. The keeper reports at least every 120 s.
- **L-3**: we took the stricter of the two options (a confirmation within a day for every fee). Restating residual 5
  alone would have left a stale `base` usable for a week.
- **I-2** is subsumed by M-1 rather than fixed as suggested. Pricing the non-gated paths at 0 would make priced
  bookings rarer and the M-1 raise larger, for no principal gain.

## Tests changed (new semantics)

- L-3: every successful `chargeFee` in the older suites is preceded by `_fresh()`, a guardian confirmation of the
  stored anchor (`SATestBase._fresh`). This touches 24 call sites in `LPManagerModule.t`, `SARegressions`, `SARound2`,
  `SARound3`, `SARound4` and `SARound5`.
- L-4: guardian ranges in `SARound5.test_I1_GuardianRangeWidthBounded` and
  `SARegressions.test_M7_Sibling_GuardianRangeOneShot` are now at most 3% wide.
- `priceBudget()` returns `(lo, hi, until, base, baseTime, range, seen)`: `SARegressions` destructuring updated.

## Keeper and web

- ABI (`keeper/abi/LPManagerModule.json`) regenerated: `account()` has `bookTime`; `priceBudget()` has `baseTime` and
  `seen`. The library errors appended to the module ABI are as before.
- `sa_chain`: `AccountSnap.book_time`; `PRICE_BUDGET_KEYS` with `priceBaseTime`; `GlobalSnap.price_base_time` and
  `base_fresh(now)` (SA-6 L-3, `CONFIRM_TTL_S`). `pending` mirrors L-1: no credit while any tracked position is
  pending.
- `sa_keeper`: `account_tick` re-books an account at a trusted anchor when its `bookTime` is older than
  `BOOK_REFRESH_S` (3 h) as well as when a flow is pending (M-1). `fee` waits and raises `fee_needs_confirm` when the
  confirmation is older than a day (L-3). The `anchor_budget` alert says ranges are at most 2 × `poolBandBps` wide.
- New revert paths the keeper meets: `StalePrice` from `chargeFee` on a confirmation older than a day (avoided by
  `base_fresh`), and `BadParam` from `approvePrice` for a range wider than 2 × `poolBandBps`.
- `web/account.js`: the `Account` struct has `bookTime`. No flow change.
- `test_sa_e2e_fork`: the guardian confirms the level before the weekly fee step; `SmartAccount.fork.t` confirms before
  its fee.
- Tests: `test_product.test_sa6_fee_waits_for_recent_confirmation`, `test_product.test_sa6_account_tick_refreshes_booking`.

## Go-live list (additions)

- Guardian bot: confirm (`approvePrice(hl × 0.995, hl × 1.005, now + 1 h)`) within the 24 h before each fee run; the
  keeper raises `fee_needs_confirm` when a due fee waits for it. Ranges at most 2 × `poolBandBps` wide.
- Guardian bot: pause on sequencer timestamp skew (I-3). Runbook: the sequencer operator, `maxTimeVariation` and the
  delayed-inbox `revoke` path.
- Lowering `refDriftBps` through the timelock: confirm the level in the same operation (I-4).
- Runbook (I-7): no standing Permit2 allowance on an account; no Permit2 permits from the owner EOA for tokens the
  account holds.
- Keeper: reports at least every 120 s (already so) and re-books every account every 3 h (M-1).
