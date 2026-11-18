# SA audit round 7: response

Report (commit `e6a2de5`, branch `sa-r7`): `docs/audit/sa_round7_report_1255.md` (0 C, 0 H, 1 M, 2 L, 5 I). Fixes on
branch `sa-r8` off `e6a2de5`, one commit. Priorities for every decision are unchanged: client principal safety first,
then liveness, then the accuracy of our fee. A residual that can only lower the operator's fee is accepted and listed.

Sizes (runtime, EIP-170 = 24,576):
- `LPManagerModule` 24,155 B: 421 B margin (was 24,240 B / 336 B).
- `SABook` 8,339 B (linked; was 8,491 B).
- `SALib` 19,278 B (linked; was 19,308 B).
- The others are unchanged.

Tests:
- forge: 275 passed offline, 2 skipped (was 265 + 2).
  - New `SARound7.t.sol`: 12 tests; 9 fail on `e6a2de5`.
  - 2 round-6 tests removed, 2 adapted.
- Fork (`ELYSIUM_FORK=true`): SA 3/3. The pooled-vault `test_fork_FullLifecycle` still fails with `BadPrice`, as
  before (out of scope).
- Keeper pytest: 215 passed offline, 4 skipped (2 tests replaced).
- Keeper anvil e2e: 4/4.

## Why this round is different

Rounds 4, 5, 6 and 7 found the same family each time: a fee on principal when a client flow with a price-dependent part
(idle HYPE, a tracked position's liquidity) is booked later than it happened. Each round added precision:
- round 4: a day of waiting after the flow;
- round 5: a dust threshold and a raise measured from the last booking's anchor;
- round 6: a 24 h ring of keeper reports and a raise sized by its range.

Each time the auditors found the next gap. In round 7 the gaps were opposite flows that net out (M-1), and reports that
are not the market (L-1). **We stopped adding precision and replaced the mechanism with one rule that needs no price
record at all.**

### The rule (SABook.sync, SA-7)

A booking at a trusted anchor is a **priced booking** if idle base or any tracked position's liquidity changed at all
since the books' last look (in units, so 1 wei counts), or if the account carries a `flowSeen` mark (below). A priced
booking sets

    hwm = max(profit after the booking, hwm + priced)

Here `priced` = Σ |change| of each price-dependent component, valued at the anchor. The fee is charged only above
`hwm`. Only `hwm` rises, so the rule can only lower the fee.

Why it is enough. Let e be the unknown phantom: booked profit minus profit measured at each flow's own price.
1. **The `profit after the booking` term.** Booked profit after the booking = true profit + e. So whenever the account
   was at or above its mark, the new mark is at least the old mark + e. No part of e is ever charged. This holds for
   any number, sign and timing of flows, netting included. The uncharged gain up to the booking is forgone.
2. **The `hwm + priced` floor.** Below the mark, (1) alone does not cover the phantom. Example: the account is down 50
   from its mark, the client withdraws HYPE in a dip, and the withdrawal is booked after the recovery. The books then
   show 120 too much profit. `max(hwm, profit)` keeps `hwm`, so the next 120 of "recovery" would be charged. That is
   why this is a floor and not the plain `max(hwm, profit)` the brief proposed:
   - an outflow's value at its own price is ≥ 0, so e ≤ its value at the anchor;
   - an inflow booked at no less than half its arrival price also has e ≤ its value at the anchor.
   So `hwm + priced` ≥ `hwm + e` at any distance from the mark.
3. **`flowSeen`.** A sync at an untrusted anchor (the keeper's, the client's, or any module action's) cannot book. If it
   sees idle base or a tracked position differ from the books, it sets `Account.flowSeen`. The next booking is then a
   priced booking even if the client brought the same amount back in between. The keeper calls `sync(a)` once for
   every account with a pending flow while the anchor is not trusted. `sync` no longer reverts `StalePrice`; it books
   only at a trusted anchor.
4. **Opening.** A first registration opens the books in the same transaction at a trusted anchor (`SALib.register`
   returns true, the module syncs; `hwm == SALib.OPEN` marks it). That is the moment the holdings come under
   management, so there is no lateness and no raise. At an untrusted anchor the holdings stay pending, and the first
   booking is a priced booking like any other.

### What was removed

| Removed | Introduced in | Why it is no longer needed |
|---|---|---|
| `Account.pricedFlowTime`, `FeeTooEarly(pricedFlowTime + 1 day)` in `chargeFee` | SA-4 M-2 | After a priced booking the fee is only on later gains |
| The 1% of \|contributed\| dust threshold | SA-5 L-1 | A threshold on the net cannot see opposite gross flows (M-1); it could not be bounded, so it is gone |
| `Account.bookPrice`, `Account.bookTime` | SA-5 M-4, SA-6 L-2 | No raise is sized by prices any more |
| `PriceBudget.seen` (the 24 h report ring), its write in `movePrice`, `SARange.since`, `SABook._late` | SA-6 M-1 | Same |
| `register(..., price)` argument | SA-6 L-2 | Replaced by the opening booking |
| Keeper: `BOOK_REFRESH_S` (zero-flow re-booking every 3 h), `FEE_FLOW_WAIT_S` / `fee_waits_flow` | SA-6, SA-4 | Same |

`SARange` keeps `bounds` / `record` / `reset` for the anchor drift budget, which is unrelated.

### Product cost (operator fee given up)

- **Typical account: hybrid, USDC in through `onboard` / `deposit`, the client does not move HYPE or NFTs.** No cost.
  USDC flows are booked at face value and are not priced bookings. The module's own actions are booked through the
  snapshot and are never flows: the whole suite charges its fees as before.
- **Any priced booking** (HYPE in or out, a direct NFT change, a 7702 client's own transaction paying gas from the
  account): the gain not yet charged at that moment carries no fee. With weekly fees, a flow at a random time costs
  about half a week's fee on average.
- **Floor**: matters only when the uncharged gain is smaller than the flow's value. The fee then waits for that much
  more gain. Example: a USD 50 HYPE withdrawal from an account at its mark costs the fee on the next USD 50 of gain,
  that is USD 7.50.
- **7702 accounts used as a wallet**: every own transaction spends HYPE gas from the account. The fee is then only on
  gains made after the client's last transaction before the fee. With one transaction a week that is about half the
  fee; with daily use about 85% of the fee is lost.
- **Fee avoidance**: anyone, including the client, can wipe the uncharged gain by sending 1 wei of HYPE to the account
  before the fee is booked. Repeated weekly, this avoids the fee entirely. It harms only the operator. A dust threshold
  would stop this, but it reopens M-1, so it was not added. If this matters commercially, the alternative is to drop
  term (1) and keep only the floor. That is dust-proof, but opposite flows that net out are then not covered at all
  (round-7 M-1 reopens). The choice is a one-line change in `SABook._raise`.

Before this round (round-6 machinery), a priced flow raised the mark by its value × the reported price range of the
last 3 to 6 h, which is usually a few percent of the flow, and it delayed the fee by a day.

## Status: Medium

| ID | Finding (short) | Status | Fix | Regression tests (`test/sa/SARound7.t.sol`) |
|---|---|---|---|---|
| M-1 | Opposite flows between two bookings net to zero in `priced`, so the raise does not apply | Fixed by redesign (the report's Option C, generalised) for every case where any change is seen: at the booking (a net change in units) or between bookings (`flowSeen`). Accepted residual: an exact round trip that nobody sees (below) | The rule above | `test_M1_PoC_OppositeFlowsSeenByKeeper`: the report trace, scaled. The account holds HYPE and 8,000 USDC of uncharged gain; 30% wick; all HYPE out at the bottom; the keeper's look; the same HYPE back at P0. Fee 1,200 on `e6a2de5`, cap 661 at the flows' prices; now ≈ 0. `test_M1_Sibling_PartialNettingNoLook`: all out at the bottom, half back, nobody looks. 814 vs cap 275 on `e6a2de5`. `test_M1_Sibling_DepositFirstRoundTrip`: 1,199 vs 1,050 on `e6a2de5`. `test_M1_BelowMarkOutflowCoveredByFloor`: the floor, with no uncharged gain. `test_Residual_ExactUnseenRoundTripIsNoFlow`: the residual, documented |

## Status: Lows and Informationals

| ID | Status | Note |
|---|---|---|
| L-1 | Fixed by removal | No raise is sized by recorded reports any more, so there is no range that could miss the market. The rule does not use any price except the booking anchor. A stolen keeper's walked anchor at a booking: an outflow is covered by the floor at any anchor; an inflow booked at a walked-down anchor is covered while it is booked at ≥ half its arrival price (`refDriftBps` ≤ 10%). |
| L-2 | Fixed (recommended fix) | `PriceBudget.approvedAt`, stamped by `approvePrice`. A consumption sets `baseTime = approvedAt`. The first report still stamps its own time. `test_L2_ConfirmationCountsFromApproval`: approved at T, consumed at T + 23 h, fee at T + 25 h refused (`e6a2de5` allowed it). |
| I-1 | Fixed (suggested fix) | `_setParams` clears `priceBudget.until` when `poolBandBps` decreases (`test_I1_LowerBandClearsOpenRange`). |
| I-2 | Fixed by removal | `bookPrice` is gone. The opening booking happens only at a trusted anchor. |
| I-3 | Fixed (suggested fix) | `_trusted()` is false while paused, so `_sync` books nothing and the flow stays pending (`test_I3_PausedBooksNothing`). Swaps, adds and fees were already `whenNotPaused`; removals, margin returns and exits do not need a trusted anchor. |
| I-4 | Accepted | Inside residual 11 (hedge equity is keeper-attested). The fee counts at most min(hedgeEquity, netMargin). Refreshing only on an equal report would make every real hedge gain block the fee until the guardian approves it, for no principal gain: a stolen keeper simply reports the stored value. |
| I-5 | Accepted | The client's own trade or add from its own account code. No third party can start it. The design NatSpec no longer claims coverage of these cases. |

## Accepted residuals (restated; numbering as in round 6)

1. to 3.: Unchanged.
4. **Late booking (replaced).** The rule covers every priced booking and every `flowSeen` mark. Two gaps remain:
   - **Exact unseen round trip.** The client moves a price-dependent amount out and back to the wei, or the reverse,
     with no sync in between (no keeper look, no module action, no own sync), all inside one booking interval. The books
     are then identical to an account that made neither flow (`test_Residual_ExactUnseenRoundTripIsNoFlow`). The fee is
     exactly that account's fee. Against the flows' own prices it can be higher by up to `feeBps` × amount × the price
     gap between the two legs. Only the client can take base out, so only the client can start it. A 7702 account pays
     gas from the same balance, so its round trips are never exact. No on-chain record can see gross native transfers
     (the report's own conclusion).
   - **Below the mark, opposite or extreme flows.** When the account is below its mark at the booking and the flows
     are opposite (netting), or an inflow is booked below half its arrival price, the floor can be smaller than the
     phantom. The excess fee is then at most `feeBps` × min(e − priced, the account's real distance below its mark). It
     needs the client's own outflow (netting), or a > 50% fall between an inflow and its booking.
5. **Fee after a pool push**: as in round 6. The confirmation day now counts from the guardian's `approvePrice` (L-2).
6. **Fee deferral (restated)**: in a rally (until a confirmation); without a confirmation in the last day; and by the
   SA-7 rule. Every priced booking forgoes the uncharged gain, and the floor defers the fee by up to the flow's value.
   A third party can trigger it with 1 wei (see product cost). Our fee only.
7. **Stolen-keeper bound**: unchanged arithmetic (19.5% of nav at the anchor per 24 h, cap 40%). The fee part of
   round-7 L-1 is closed by the rule. Outflows are covered at any anchor; an inflow at a walked anchor is covered within
   2×.
8. to 11.: Unchanged. Additionally (I-3): while paused, nothing is booked.

## Where we read the report differently

- **M-1, which option.** Option B (holdings at either end) still misses outside capital, and it needs the price range.
  Option A only restates. We took Option C, generalised: not "after an untrusted interval" but "after any seen change":
  a net change in units at the booking, or a change seen by any sync before it. The cost is our fee, as the report
  says. We also added the floor, because Option C alone (`max(hwm, profit)`) does not cover a phantom when the account
  is below its mark. Our own review found that case. `SARound6.test_M1_PoC_WickRoundTripNoFeeOnPrincipal` and
  `SARound7.test_M1_BelowMarkOutflowCoveredByFloor` start with no uncharged gain, so `max(hwm, profit)` alone would
  charge the phantom there.
- **No dust threshold.** The brief allowed keeping the 1% rule only if it could be bounded. It cannot: under it, any
  gross round trip with a small net escapes. It is removed. The cost is fee avoidance with dust (product cost above).

## Tests changed

- New `test/sa/SARound7.t.sol` (12 tests). Run with `SATestBase.sol` against the sources of `e6a2de5`: 9 fail there.
  The other 3 pass on both: the floor sanity check, the exact-round-trip residual and the USDC sanity check.
- Removed (mechanism gone): `SARound6.test_M1_FlatMarketPricedFlowRaisesNothing` and
  `SARound6.test_M1_LongGapRaisesWholePricedValue`.
- Adapted:
  - `SARound4.test_M2_PoC_FeeWaitsADayAfterPricedFlow` → `test_M2_PoC_NoFeeOnGainBeforePricedFlow`: no wait; the fee
    right after the booking is 0.
  - `SARound3.test_M4_PoC_NoBookingOffTheBookBand`: `sync` off the band books nothing instead of reverting.
  - NatSpec of `SARound5.test_L1_DustDoesNotDelayFee` and `SARound6` M-1 / L-2 (both still pass, now through the floor
    and the opening).

## Keeper and web

- ABI regenerated: `account()` loses `pricedFlowTime`, `bookPrice` and `bookTime` and gains `flowSeen` (after
  `hedgeClipped`). `priceBudget()` returns `(lo, hi, until, base, baseTime, range, approvedAt)`.
- `sa_chain`:
  - `ACCOUNT_KEYS` and `AccountSnap.flow_seen` follow the new `account()`;
  - `priced_flow_time`, `book_price` and `book_time` are gone;
  - `GlobalSnap.trusted` is false while paused (I-3).
- `sa_keeper`:
  - `account_tick` marks a pending flow it cannot book (`sync(a)` once, while the anchor is not trusted);
  - it books at the first trusted moment as before;
  - no 3 h re-booking;
  - `fee` no longer waits a day after a priced flow.
- `web/account.js`: the `Account` struct follows the module.
- Tests:
  - `test_product.test_sa7_fee_books_pending_flow_then_charges` replaces `test_sa4_fee_waits_a_day_after_priced_flow`;
  - `test_product.test_sa7_account_tick_marks_flow_it_cannot_book` replaces `test_sa6_account_tick_refreshes_booking`.
