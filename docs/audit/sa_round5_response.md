# SA audit round 5: response

Report (commit `30aae1e`, branch `sa-r5`): `docs/audit/sa_round5_report_1249.md` (0 C, 0 H, 4 M, 4 L, 9 I). Fixes on
branch `sa-r6` off `30aae1e`, one commit. Priorities used for every decision, unchanged: client principal safety >
liveness > accuracy of our fee. A residual that can only lower the operator's fee is accepted and listed.

Sizes (runtime, EIP-170 = 24,576): `LPManagerModule` 24,097 (479 margin; was 24,122 / 454), `SALib` 19,222 (linked;
was 18,343), `SABook` 8,180 (linked; was 7,699), `SwapExecutor` 3,774, `ElysiumCustodyEnforcer` 7,802, `VaultTimelock`
6,155, `V4PositionMath` 6,059 (all three unchanged). To make room, the parameter bounds moved from
`LPManagerModule._setParams` into `SALib.checkParams` and the guardian range into `SALib.approvePrice`.

Tests: forge 256 offline + 2 skipped (was 244 + 2). New `test/sa/SARound5.t.sol` (12 tests). All twelve were run
against the sources of `30aae1e` (the same file; it reads the new getters raw so it compiles there) and all twelve fail
there: for example the M-1 PoC books 91 USDC of yield that PoolManager never paid, the M-2 PoC walks the anchor to
-17% of the confirmed level by day 2, and the M-4 PoC charges a 144 USDC fee on a phantom profit. Fork
(`ELYSIUM_FORK=true`, public RPC, read only): SA 3/3. Keeper pytest 213 offline + 4 skipped (was 212 + 4). The keeper SA
e2e and relayer-API e2e run on a local anvil fork and pass; they deploy with the `DeploySA` script.

## The question asked first: a principal-loss path for the pilot?

The report finds no third-party path to principal and no way to block an exit. Four Mediums reached principal in bounded
ways. All four are fixed:

- **M-1** (dip and restore of a tracked position): the credit now needs both tokens at or above the snapshot and
  PoolManager's liquidity unchanged at the last look as well as now. The global mark moves only with the position's
  mark (L-2), as the report asks for both together.
- **M-2** (stolen-keeper bound not per 24 h): the anchor is now bound to `refDriftBps` around a guardian-confirmed
  level. The first report sets it, and after that only a report that consumes a guardian range moves it. However many
  days the keeper walks, the anchor never leaves `base × (1 + refDriftBps)^(±1)`. LP adds are charged at their whole
  principal.
- **M-3** (the fee gate's low follows a walked anchor): the gate's low is the lower of the trailing 24 h low and the
  confirmed level. So the fee is measured at most `poolBandBps` above a level the guardian confirmed.
- **M-4** (a flow booked late at a moved anchor): the recommended high-water-mark adjustment. A priced flow booked at an
  anchor other than the account's previous priced booking raises the mark by the largest gain it can have had between
  the two.

The pilot rule ("nobody modifies tracked NFTs directly") is kept until this round is verified. One new operator duty
comes with M-2 / M-3: the guardian must confirm the market (`approvePrice` around the HL price, at most 10% wide). This
is needed when the market has moved more than `refDriftBps` from the confirmed level, and before a fee when the anchor
is more than `poolBandBps` above it. The keeper alerts for both (`anchor_budget`, `fee_needs_confirm`). Until the
guardian acts, the module fails closed: no booking, swaps or adds at a clipped anchor, and no fee. Removals, margin
returns and the client's exit are not affected.

## Status: Mediums

| ID | Finding (short) | Status | Fix (where) | Regression tests (`test/sa/SARound5.t.sol`) |
|---|---|---|---|---|
| M-1 | A dip and restore of a tracked position still books principal as yield (round-4 H-1 partly fixed) | Fixed: Option A and Option B, together with L-2 | `SABook._feesOut` / `_credit`: (1) Option A: nothing is credited while idle is below the snapshot in either token, since a restore at another price changes the mix and that is not yield. Then the per-token cap applies as before. (2) Option B: `Pos.seen` holds PoolManager's liquidity at every look (sync, priced or not, and every module `book`). The credit needs `seen == liq == books' liquidity`, so a dip that any look saw credits nothing. (3) L-2: the global mark `G0/G1` moves only when the position's mark `g0/g1` moves (and at every module touch), so both span one interval. | `test_M1_PoC_DipRestoreAtAnotherPriceNoYield` (the report's trace: 91 USDC credited on `30aae1e`, < 5 now), `test_M1_Sibling_DipSeenThenTopUpNoYield` (dip seen by an unpriced sync, then a restore and a direct top-up) |
| M-2 | The anchor's drift budget does not limit its distance from the market; residual 7 is not a per-24 h bound | Fixed: the anchor is bound to a guardian-confirmed level; LP adds at full principal | `SALib.PriceBudget.base`: set by the first report and by every report that consumes a guardian range. `SALib._bounds` folds `base` into the trailing range, so `movePrice` keeps the anchor within `refDriftBps` of `base` (an absolute bound; the 24 h range and the one-band step stay). `SABook.lpAdd`: `charge = paid` (it was paid × slip / (slip + band)). The guardian bot's pause on the cumulative anchor / HL gap is an operator item (go-live list). | `test_M2_PoC_MultiDayWalkBoundedByConfirmedLevel` (3 days of walking: still ≥ base / 1.1), `test_M2_Sibling_GuardianConfirmMovesLevel`, `test_M2_LP_AddChargedAtFullPrincipal` |
| M-3 | The fee gate's trailing low follows a walked anchor | Fixed: the M-2 reference, as the report allows | `SALib.feeGate`: the low is `min(trailing 24 h low, base)`. A fee is measured at most `poolBandBps` above the guardian-confirmed level, however long the walked level was held. | `test_M3_PoC_WalkedLowCarriesNoFee` (held 30 h above the level: charged on `30aae1e`, `StalePrice` now); `SARound3.test_M3_PoC_WalkThenFeeGated` extended (the fee after the guardian confirms) |
| M-4 | A priced client flow left pending through an untrusted-anchor period is booked at the later price; the fee lands on principal | Fixed (recommended fix) | `Account.bookPrice` = the anchor of the account's last priced sync. `SABook.sync`: `priced` = \|Δbase\| × price + Σ \|Δ liquidityValue\|. If `bookPrice ≠ 0`, `bookPrice ≠ price` and `priced ≠ 0`, then `hwm += ceil(priced × \|price − bookPrice\| / min(price, bookPrice))`. This only lowers the fee, and for liquidity it is ≥ the value change (dLV/dP = base amount ≤ LV / P). | `test_M4_PoC_LateBookedFlowCarriesNoFee` (fee 144 USDC on `30aae1e`, 0 now) |

## Status: Lows and Informationals

| ID | Status | Note |
|---|---|---|
| L-1 | Fixed | `SABook.sync`: `pricedFlowTime` is stamped only when the priced part of the flow is ≥ 1% of \|contributed\|. `sync` has no nav, and net contributions are its proxy. A smaller flow cannot carry a phantom anyway after M-4. Dust no longer defers the fee (`test_L1_DustDoesNotDelayFee`). |
| L-2 | Fixed (with M-1) | See M-1 (3) (`test_L2_PlainCollectAfterSyncIsYield`) |
| L-3 | Fixed | `LPManagerModule.sync(a)`: only the keeper, the account or its pinned owner (`NotOwnAccount` otherwise; registration is still checked first). The client can still book its own flow (round-3 M-5). A third party can no longer choose the booking moment (`test_L3_ThirdPartyCannotSync`; `SARound3.test_M5_PoC_*` updated). |
| L-4 | Fixed | `SALib.checkParams`: `minPriceStable ≥ 300`, and `(refDriftBps + poolBandBps + maxSlippageBps) × (swapTurnoverBps + exitTurnoverBps) ≤ 40% × BPS²`. The pilot is 19.5%; 40% rather than the report's example 30% so that the test parameters (turnover 2×) still fit. With LP adds at full principal, the product is the whole bound (`test_L4_ParamProductAndStableFloor`). |
| I-1 | Partly | `approvePrice`: at most 10% wide (`2 × MAX_POOL_BAND_BPS`) (`test_I1_GuardianRangeWidthBounded`). Not taken: recording the pre-jump anchor before the reset. That would block the keeper's room and the fee for a day after a guardian move, which SA-3 M-7 ruled out. The jump is to a level the guardian checked, and with M-2 it also becomes the confirmed level. |
| I-2 | Fixed (keeper) | On chain, one sale is still not split between the exit and turnover windows; the total bound is unchanged. `sa_keeper.risk_off` used to size one sale to exit room + turnover room, which is exactly the case the report describes (`WindowOverflow`). It now sells into the exit room first and into the turnover room in a second swap (`test_riskoff.test_keeper_exit_falls_back_to_turnover_room` updated). |
| I-3 | Accepted | `DeploySA._checkOwner` stays a threshold check. Comparing the Safe singleton or proxy code hash is an operator check at deploy (runbook). |
| I-4 | Accepted | The enforcer and module hedge limits are independent by design. The stock bound rests on the module. |
| I-5 | Accepted | At most one raw unit per priced flow to the profit side. |
| I-6 | Accepted | No sweep on the module, executor or enforcer (nobody should send tokens there). The approval reset is fail-safe. |
| I-7 | Acknowledged | As documented in round 4 (I-1 there): a hybrid owner change ends module management for that address. The client keeps `revoke` and margin returns. |
| I-8 | Acknowledged | Timelock freeze paths need the operator's own Safe. Runbook: never renounce `CANCELLER_ROLE`. |
| I-9 | Accepted | Gas stipends fail closed (the module stops managing). The client's exit does not depend on them. |

## Accepted residuals (each lowers only our fee, or is a stated bound)

1. **Fees of a position the client changed** (collect plus a liquidity change, decrease, increase, burn, transfer) are
   not counted as yield. They become a contribution when the flow is booked (our fee lower). The same holds for a
   client collect while idle is below the snapshot in either token (SA-5 M-1), for example after the client withdrew
   some USDC. Fees the client collected to an outside address leave the profit. A plain client collect on an unchanged
   position stays yield, also after keeper syncs (SA-5 L-2).
2. **Dip and restore between two looks** (restated per the report). A client that lowers and restores a tracked
   position with no look in between is credited at most min(L × the range's growth, the idle surplus in each token).
   Both tokens must be at or above the snapshot. Over-credit is possible only if the surplus comes from (a) a direct
   top-up the client made outside `deposit` in the same interval, or (b) fees actually received in the other token
   that exceed the mix deficit. It is bounded by L × growth over the interval (the fees full liquidity would have
   earned), and the fee on it by `feeBps` × that. Only the client's own action on its own NFT starts it. The pilot
   rule holds.
3. **Client timing inside the 50 bps booking band**: ≤ 2 × 50 bps of contributed per round trip (our fee lower).
4. **Keeper booking at the band edge**: ≤ 50 bps × flow against the pool at that instant, now covered by M-4. A late
   booking raises the HWM, and a third party can no longer pick the moment (L-3).
5. **Fee after a pool push (restated)**: the gate admits an anchor ≤ `poolBandBps` above the lower of its trailing
   24 h low and the guardian-confirmed level. The phantom is at most `poolBandBps` × base exposure × `feeBps` (≈ 0.2%
   of exposure), once per confirmation, not per week. It no longer grows with time.
6. **Fee deferral**: in a rally (the gate: until the guardian confirms the new level), for a day after a material
   (≥ 1% of contributed) priced client flow, and by the M-4 adjustment. That adjustment raises the HWM for every
   priced flow booked at an anchor other than the account's previous priced booking, even when the flow really
   happened at the later price. Our fee only.
7. **Stolen-keeper bound (restated)**: a stolen keeper never takes the anchor more than `refDriftBps` from the
   guardian-confirmed level, so a trade is never worse than about (`refDriftBps` + `poolBandBps` + `maxSlippageBps`)
   from that level (13% at the pilot values). This is an absolute bound: it does not grow with the number of days. LP
   adds cost the window what a swap costs. Per 24 h at most (`swapTurnoverBps` + `exitTurnoverBps`) × value can be
   traded at that gap: about 13% × 1.5 ≈ 19.5% of value per day at the pilot values, and `checkParams` caps the
   product at 40%. Against the market the gap is the above plus the distance of the market from the confirmed level,
   which the guardian keeps small by confirming. Controls: the guardian bot's pause on the anchor / HL gap, and the
   confirmation duty.
8. **Liveness**: a third party holding the pool > 50 bps off the anchor pauses booking, swaps (the risk-off exit sale
   included), adds and fees. New this round: when the market moves more than `refDriftBps` from the confirmed level,
   the anchor waits for the guardian. Removals, margin returns and the client's own exit are not affected.
9. **Risk-off in a fast market**: the exit sale needs a trusted anchor and no pause. In a fall beyond `refDriftBps` from
   the confirmed level (now also over several days, not only within 24 h), it waits for a guardian `approvePrice`.
10. **LP capacity (new trade-off, M-2)**: adds are charged 1:1, so at the pilot `swapTurnoverBps` 5000 the keeper adds
    at most about 50% of nav per day. The keeper's turnover floor widens ranges accordingly, and a full re-entry after
    risk-off takes three days instead of two (`SARiskOff.test_R4_RiskOffCycle`). Raising `swapTurnoverBps` through the
    timelock is possible within the L-4 product bound.
11. Unchanged from rounds 2–4: hedge equity is keeper-attested (increases need the guardian); multicall gas; 7702
    approval resets; partial fills; `feeBps` change; timelock role layout; USDC blacklist; treasury return allowance
    (approve just-in-time). The guardian range width is now bounded (I-1).

## Where we read the report differently

- **M-1 Option A alone does not close every mix change.** When the real fees in the deficit token exceed the mix
  deficit, both tokens are above the snapshot and the mix surplus in the other token passes the per-token cap. The
  over-credit is then at most about the fees actually received, which is why residual 2 names it. Option B as written
  (liquidity stored at each look) catches only a dip that spans a look, not one between two looks. We implemented both
  together with L-2, and residual 2 states what is left.
- **M-4's adjustment does not cover L-3 when the anchor did not move** between the two bookings (`bookPrice == price`,
  so the adjustment is 0). We fixed L-3 by restricting `sync(a)` instead.
- **M-3**: the report's first option, the lowest anchor since each account's `lastFeeTime`, needs per-account state
  that `movePrice` would have to update for every account. We used the report's second option, the M-2 reference. This
  is tighter (an absolute level, not a moving low) at the cost that a fee in a rally waits for the guardian's
  confirmation.
- **M-2, the LP term**: implemented as recommended (`charge = paid`). It costs re-range capacity at the pilot
  parameters (residual 10). That is a liveness and yield cost, not a principal one, and we accept it.
- **L-1**: the threshold is 1% of |contributed|, not nav / 10,000. `sync` does not compute nav, and after M-4 a
  smaller unstamped flow carries no phantom.

## Tests changed (new semantics)

- `module.sync(a)` in `SARound3` / `SARound4` is called as the keeper (L-3). `SARound3.test_M5_PoC_AnyoneBooksAtTrustedAnchor`:
  a stranger is refused, the owner EOA books.
- Guardian ranges at most 10% wide around the market: `SARegressions.test_M7_Sibling_GuardianRangeOneShot`,
  `SARound2.test_H1_PoC_LaggingAnchorNoAttacker`, `SARound2.test_M4_PoC_SaturatedWindowOneUnitDoesNotBlock`.
- Anchor beyond 10% of the confirmed level after 27 h needs the guardian: `LPManagerModule.t.test_H2_*`,
  `SARegressions.test_M7_Sibling_AnchorWindowBothWays`.
- Fee gate on the confirmed level: `SARound3.test_M3_PoC_WalkThenFeeGated` (gated, then charged after `_confirm`),
  `SARound3.test_M6_*` (+0.5% instead of +1%).
- LP adds at full principal: `SARiskOff.test_R4_RiskOffCycle` (re-entry over three days).
- `SATestBase`: `_pending` mirrors the new `_feesOut` (`seen`, both-token rule, positions in the module's order);
  `_confirm()` helper.

## Keeper and web

- ABI (`keeper/abi/LPManagerModule.json`) regenerated: `account()` has `bookPrice`, `priceBudget()` returns
  `(lo, hi, until, base, range)`, `snapPos()` returns `(liq, seen, g0, g1, G0, G1)`.
- `sa_chain`: `AccountSnap.book_price`. `GlobalSnap.price_base`. `fee_gate` uses `min(trailing low, base)`; new
  `base_gate` and `at_drift_limit`. `pending` mirrors the new credit rule (`seen`, both-token rule).
- `sa_keeper`: an LP add's turnover charge is its whole value (`deploy`, `rerange_charge`). `recommend.Model.add_share`
  is 1.0 (the turnover floor and the recommended widths follow). `anchor_budget` alerts name the confirmed-level limit
  and give a ±0.5% `approvePrice` range. New `fee_needs_confirm` alert when a due fee waits only for the guardian's
  confirmation.
- `sa_keeper.risk_off` (I-2): one exit sale per window (exit room first, then turnover room), never one sale over both.
- New revert paths the keeper meets: `NotOwnAccount` from `sync` for a third party (the keeper is allowed), `BadParam`
  from `approvePrice` for a range wider than 10%, `StalePrice` from `chargeFee` above the confirmed level (avoided by
  `fee_gate`).
- `web/account.js`: the `Account` struct has `bookPrice`; the comment on who may book follows L-3. No flow change.
- Tests: `test_sa_unit.test_sa5_fee_gate_and_drift_limit_use_confirmed_level`; `test_product.test_pos_half_width_and_charge`
  (add charge 1:1).

## Go-live list (additions)

- Guardian bot: confirm the market with `approvePrice(hl × 0.995, hl × 1.005, now + 1 h)` when the keeper raises
  `anchor_budget` (at the drift limit) or `fee_needs_confirm`, and at least before each weekly fee run. Pause on the
  cumulative anchor / HL gap above `poolBandBps`, not only on a single step.
- First report after deployment: the checked market price (it is the first confirmed level).
