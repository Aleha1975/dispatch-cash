# SA audit round 8: response

Report (commit `3f0f42d`, branch `sa-r8`): `docs/audit/sa_round8_report_1256.md` (0 C, 0 H, 1 M, 4 L, 12 I). Fixes on
branch `sa-r9` off `3f0f42d`, one commit. Priorities are unchanged: client principal safety first, then liveness, then
the accuracy of our fee. A residual that can only lower the operator's fee is accepted and listed.

Direction for this round: remove the cases by design, not with more precision. Both fee findings (M-1, L-1) were
special cases of the SA-7 rule. The fix removes the special cases, so every booking goes through the one rule.

Sizes (runtime, EIP-170 = 24,576):
- `LPManagerModule` 24,142 B: 434 B margin (was 24,155 B / 421 B).
- `SABook` 8,107 B (linked; was 8,339 B).
- `SALib` 19,267 B (linked; was 19,278 B).
- The others are unchanged.

Tests:
- forge: 281 passed offline, 2 skipped (was 275 + 2).
  - New `SARound8.t.sol`: 7 tests; 6 fail on `3f0f42d`. The 7th is a sanity check (USDC-only onboarding keeps the
    full fee).
  - 1 round-7 test removed (`test_Open_RegistrationBooksHoldings`, the mechanism is gone); 2 adapted (below).
- Fork (`ELYSIUM_FORK=true`): SA 3/3. The pooled-vault `test_fork_FullLifecycle` still fails (`BelowMinOut` today),
  as before (out of scope).
- Keeper pytest: 216 passed offline, 4 skipped (1 new test).
- Keeper anvil e2e: 4/4 on a fork pinned at block 7,938,529 (also passes at 7,688,529). At the chain head of
  2026-11-18 (block 7,988,529), `test_sa_end_to_end` fails at one assertion: client 3 has no position after the
  arbitrage loop. The audited commit `3f0f42d` fails at the same assertion at the head, so this comes from the live
  pool state, not from this change. It is a test-harness follow-up.

## The rule, now without exceptions

A booking at a trusted anchor in which idle base or any tracked position's liquidity changed at all (in units), or
that follows a `flowSeen` mark, sets

    hwm = max(profit after the booking, hwm + priced)

`priced` = Σ |change| of each price-dependent component, valued at the anchor. Round 7 had two places where a
price-dependent change reached the books without this rule:

1. **The opening booking (M-1).** The first registration booked the holdings with no raise.
2. **The fee credit (L-1).** `_feesOut` moved `snapBase` before `_bookIdle` tested `b != snapBase`, so a base inflow
   up to the base fees the client had collected was absorbed and never seen.

Both are removed. There is no opening booking, and the fee credit can no longer touch base.

## Status: Medium

| ID | Finding (short) | Status | Fix | Regression tests (`test/sa/SARound8.t.sol`) |
|---|---|---|---|---|
| M-1 | The opening booking has no floor: a registration at an anchor below the market leads to a fee on principal | Fixed by removal (report's Option A, taken one step further) | `SALib.register` resets the books to zero (`hwm` = 0, no `OPEN` marker) and the module no longer syncs in `register`. What the account holds is a pending inflow like any other. The first sync at a trusted anchor books it under the one rule: `hwm = max(profit, 0 + value of the base held)`. `SALib.OPEN` and the `open` path in `SABook` are deleted | `test_M1_PoC_OpeningBelowMarketNoFeeOnPrincipal`: the report trace, 1,000 HYPE, pool 40 bps above a trusted anchor at registration. Fee 24.0 USDC on `3f0f42d` against a cap of 0 at the client's own price; now 0. `test_M1_RegistrationBooksNothingFirstBookingHasFloor`. `test_M1_UsdcOnlyOnboardingKeepsFullFee` (sanity, passes on both) |

### Why Option A and not "no HYPE at registration"

We considered the preferred design first: require the account to hold no base (and no tracked positions) at the first
registration, so onboarding is USDC-only and the account buys HYPE through the module. We did not take it:

- **7702 accounts.** A 7702 account is the client's own EOA. It pays its own gas in native HYPE (revoke, withdrawals,
  burns), and the keeper keeps a gas reserve in it on purpose (`eip7702_gas_reserve_hype`, SA-4 L-7). A zero-HYPE rule
  would make a 7702 client empty its wallet before registering, and then fund it again just to be able to exit.
- **Griefing.** A native balance cannot be refused. With a zero-base rule, anyone could block any registration with
  1 wei of HYPE sent to the account just before it.
- **Exclude a gas reserve from the books.** This was the other alternative. It touches every valuation and every module
  effect on `snapBase` (a swap that crosses the reserve line is no longer linear in the books). It is more code in the
  most sensitive path and the module has 434 B left.

Option A needs no new rule. The opening becomes what an untrusted opening already was in round 7. It is sound for the
same reason as every other inflow: e ≤ value of the base at the booking anchor whenever the anchor is at least half the
market. That covers the honest 0.5% gap, the 1.5% pushed gap and the stolen-keeper walk (about 9%). Registration no
longer books, so the registrant also no longer chooses a booking moment or price. This closes I-12 too.

The cost falls only on accounts that hold base when they come under management (product impact below). For a hybrid
account onboarded with USDC (the product path) it is zero: no base, no priced booking, `hwm` stays 0.

## Status: Lows

| ID | Finding (short) | Status | Fix | Regression tests |
|---|---|---|---|---|
| L-1 | The fee credit absorbs a client base inflow before the priced test; over-credit after an unseen dip and restore | Fixed for every base path (the brief's direction). One USDC-only residual remains, below | `SABook.sync` decides "a price-dependent change happened" on the raw balances, before any credit: `dirty = idle base != snapBase \|\| a tracked position is pending`. In a dirty sync no credit at all is given, in either token. The base credit is removed (it could only be 0 now), so the credit is USDC only and never moves `snapBase`. `_credit` / `_cap` are deleted | `test_L1_PoC_BaseInflowNotAbsorbedByCredit`: trace A (fees collected to the client's wallet, the base part sent back). `3f0f42d` booked nothing; now a priced contribution. `test_L1_Sibling_CollectWithBaseIsPricedContribution`: a collect into the account is no longer credited |
| L-2 | An unpause makes a frozen anchor trusted in the same block | Fixed (recommended fix) | `setPaused(false)` sets `lastPriceMoved = block.timestamp`. The anchor is trusted again `minPriceStable` later, after a report made after the unpause | `test_L2_UnpauseReconfirmsAnchor`: the keeper refreshed the frozen anchor through a 2-day pause; the sync in the unpause block booked on `3f0f42d`, now it books nothing until re-confirmed |
| L-3 | An honest `reportPrice` reverts while the pool is held away; the anchor ages out | Fixed (recommended fix) | `reportPrice` checks the pool band only for a move: `if (price != lastPrice \|\| price == 0) _checkPoolBand(price)`. A pure refresh keeps the anchor fresh. Every consumer re-checks the pool at use: `_freshOk` (poolBandBps), `_trusted` (50 bps), and the hedge cap is on min(value at anchor, value at pool). Keeper: when the pool is off the market but the market (HL) is within 50 bps of the stored anchor, it re-reports the stored anchor when due and takes no risk-adding action; it does not follow the pushed pool | `test_L3_RefreshAcceptedOffPoolBand` (reverted on `3f0f42d`; a move off the band still reverts; nothing is booked while the pool is off). Keeper: `test_sa8_anchor_refreshed_while_pool_held_off` |
| L-4 | solc 0.8.26 (via-IR, optimizer) is inside the range of `YulOptimizerKnowledgeBaseStaleBookkeeping` | Accepted until deployment; a deployment gate | Nothing is deployed. Before deployment: build with solc ≥ 0.8.38, re-run the whole suite (forge, fork, keeper e2e), re-measure the module size. Not done in this round: 0.8.38 is not installed offline, and changing the compiler would change every runtime byte the auditors read. Doing it before the next round would hide the fix diff | — |

### L-1 residual (USDC only)

The credit remains for USDC, in a sync where idle base equals the books to the wei and no position is pending. Its job
is to keep the client's own USDC fee collects as yield (round-3 M-1). Report trace B can still over-credit the USDC part
if all of these hold, with no sync between the steps:

1. the client itself dips a tracked position's liquidity and restores exactly the same liquidity;
2. it deposits USDC afterwards;
3. idle HYPE at the booking equals the books to the wei.

Condition 3 is hard to meet. An in-range decrease and increase move HYPE, rounded in opposite directions, and pay the
accrued HYPE fees. So it needs either zero HYPE fee growth on the position over the interval, or the client topping up
HYPE to the wei. Only the NFT owner can modify the position, so only the client can start it. Bound: `feeBps` × the
USDC fee growth on the dipped liquidity over the dip. That is an LP-fee amount, not a share of the account. Removing the
USDC credit entirely would close it, but every client USDC collect would then become a contribution (the round-3 M-1
fee-base erosion). We kept the credit; the choice is a one-function change in `SABook._feesOut`.

## Status: Informationals

| ID | Status | Note |
|---|---|---|
| I-1 | Wording fixed (residual (a) restated below) | All three preconditions are accepted as stated by the report. The fee-credit widening is gone with L-1 (except the USDC residual above) |
| I-2 | Documentation aligned with the code | `docs/SMART_ACCOUNT_DESIGN.md`: an open range is consumed by the next keeper report inside it (also a refresh), which re-bases `base` with `baseTime = approvedAt`. An `approvePrice` with `until` in the past is a cancel; kept as such. `approvedAt` is the inclusion time; the guardian's runbook sets `until` from submission and the fee gate's one day counts from inclusion. No `asOf` argument (module size) |
| I-3 | Accepted, operator rule | The keeper charges every account before a `setParams` that raises `feeBps` executes (24 h timelock notice; clients may revoke first). Ownership transfer to a non-timelock is an operator decision under the same timelock |
| I-4 | Accepted | Real yield on capital booked late; only the client's direct add while nothing can be booked |
| I-5 | Accepted, wording | The enforcer is described to clients as a destination guarantee; amounts are bounded by the module |
| I-6 | Accepted, keeper rule | One account per `multicall` (the keeper does not use `multicall` today; it sends one transaction per action). No state is harmed by a gas-burning hybrid implementation; a batch would be retried without that account |
| I-7 | Accepted | A delayed removal at a pushed price favours the LP; keeper minimum amounts bound it |
| I-8 | Fixed | Module header rule D rewritten (no day of waiting, no report range); exit sentence corrected for hybrids (`revoke` is a plain owner call; `disableDelegation`, burns and withdrawals go through `EntryPoint.handleOps`); `SABook.sync` NatSpec says positions are dropped only at a trusted sync |
| I-9 | Accepted, deployment runbook | Before deployment, compare the runtime code of the DelegationManager, EIP7702StatelessDeleGator, TimestampEnforcer, HybridDeleGator implementation, factory and SCL library with a local deployment of the fixture init code (`cast code`). A chain-operator assumption, as the report says |
| I-10 | No change | The first report is the checked market price (runbook) |
| I-11 | No change | Dust ≤ 10⁻⁶ USD per event |
| I-12 | Fixed by M-1 | Registration books nothing at any anchor; the registrant decides nothing |

## Fee griefing with dust (our own product issue)

Anyone can send 1 wei of HYPE to an account before a fee run. The booking is then priced, and the uncharged gain up to
it is forgone.

We looked for a simple fix: native HYPE below a fixed dust amount arriving "without client action" would not be a
priced flow, only a plain contribution. **Not implemented: it is not sound.**
- The books cannot tell who sent native HYPE. "Without client action" can only mean "a net base increase of at most
  DUST".
- A client who takes X HYPE out at one price and returns X + δ (0 < δ ≤ DUST) at another, with no sync in between,
  would then be booked as a plain contribution of δ. The phantom is X × (price gap), not δ × price. That is round-7 M-1
  again, for any X, whenever the return lands within DUST above the outflow.
- Residual (a) today needs the round trip to be equal to the wei. With the rule it would widen to "within DUST above".
  The bound stays unbounded in X. This reopens a principal case to save operator fee, so it fails the brief's test.
- Booking dust at zero value makes it worse: a 7702 client's own gas refund would then be charged as profit.

**Accepted as an operator-only residual.** Why it is limited in practice:
- The griefer gains nothing.
- Elysium is an Arbitrum Orbit chain with a first-come-first-served sequencer and no public mempool, so a fee run
  cannot be front-run by watching for it.
- The dust wipes only the gain up to the booking that sees it. With the keeper's regular syncs, a griefer has to send
  dust before every sync to wipe a whole week, paying gas each time.

Monitoring: every booking emits `Flow` on-chain, so a pattern of repeated small HYPE inflows into an account is visible
(an alert on it is a keeper follow-up, not built yet). If griefing appears, the alternative from round 7 still applies: drop
the "profit after" term and keep only the floor. That makes the rule dust-proof, but it reopens unseen netting (round-7
M-1). We do not take it now.

## Accepted residuals (restated; numbering as in round 6 and 7)

1. to 3.: Unchanged.
4. **Late booking.** The rule covers every priced booking, every `flowSeen` mark and now every first booking after a
   registration. Two gaps remain:
   - **(a) Unseen round trip with idle base and tracked liquidity equal to the wei** (round-8 I-1). Price-dependent
     amounts move out and back (or in and out) with no sync in between: no keeper look, no module action, no own sync.
     At the booking, idle HYPE and every tracked position's liquidity equal the books to the wei. Only those must
     match, not the books: a swap round trip that restores HYPE leaves a USDC difference, booked as a plain USDC flow.
     The client starts it (only the client can take base or liquidity out). On a 7702 account a third party can
     complete it by refunding the client's gas to the wei. The fee is that of an account that made neither flow;
     against the flows' own prices it can be higher by up to `feeBps` × amount × the price gap between the legs.
     Round 8 removed the fee-credit widening (L-1). The USDC credit residual above is the only credit case left.
   - **(b) True profit below the mark at the booking** (round-8 note on Task 1). The condition is the account's true
     profit after the flows, not its booked position: an account exactly at its mark is exposed if the losing leg of
     opposite flows is what puts it below. It needs opposite flows (the client's own outflow among them), or an inflow
     booked below half its arrival price. Excess fee ≤ `feeBps` × min(e − priced, the true distance below the mark
     after the flows).
5. **Fee after a pool push**: unchanged.
6. **Fee deferral**: unchanged, plus the floor at the first booking (product impact below) and the dust griefing above.
7. **Stolen-keeper bound**: unchanged arithmetic (19.5% of nav at the anchor per 24 h through swaps and adds, cap 40%).
   Every inflow booked at a walked anchor, the first booking after a registration included, is covered within 2×.
   L-2: the walked anchor no longer survives an unpause as trusted.
8. **Pool held off the anchor** (restated with L-3):
   - More than 50 bps: mint, increase, swap (incl. the risk-off sale), `chargeFee` and bookings wait (flows marked).
   - More than `poolBandBps`: also moves of the anchor and keeper-only hedge-equity decreases.
   - Keeps working: removals, burns, margin returns, `reportHedgeEquity` (keeper decreases only within band), anchor
     refreshes (L-3), so `sendHedgeMargin` keeps working (cap on min(anchor, pool) value).
   - Operator rule (not enforced on-chain): keeper swaps are sized so their own impact stays under `BOOK_BAND_BPS`;
     a larger swap blocks adds and swaps for every account until the pool is arbitraged back.
9. to 11.: Unchanged.

## Product impact

- **Hybrid account onboarded with USDC (the product path).** No change. Nothing is booked at registration; the USDC is
  booked at face value by `onboard` at once.
- **Any account holding HYPE when it comes under management (every 7702 wallet; a hybrid funded with HYPE first).** The
  first booking raises `hwm` by the value of that HYPE. The fee starts only once the gain exceeds it. Example: the
  pilot 7702 wallet with 3 HYPE + 130 USDC waits for about USD 120 of gain, which is up to USD 18 of fee forgone, once.
  Mitigation without code: a 7702 client swaps its HYPE to USDC before registering and keeps only the gas reserve
  (`eip7702_gas_reserve_hype`). The floor is then a few dollars, and the keeper buys the HYPE through the module.
- **Client collects its own LP fees directly.** If HYPE fees reach the account, nothing is credited: the collect is a
  priced contribution and the uncharged gain is forgone. USDC fees collected with idle HYPE unchanged stay yield.
  The web app offers no direct collect.
- **Unpause.** Bookings, swaps, adds and fees resume `minPriceStable` (300 s) after the unpause, following a fresh
  report.
- **Pool push.** The anchor stays fresh; margin sends keep working.
- **Dust griefing.** Unchanged, accepted (above).

## Where we read the report differently

- **M-1, which option.** The report recommends Option B (a floor sized by the anchor's maximum distance from the
  market). That keeps the fee on the HYPE held at registration but adds a parameter-derived precision term to exactly
  the path that broke. Option A removes the path: the opening is no longer special at all. We took a step past Option A
  and stopped booking in `register` altogether (I-12 goes with it).
- **L-1, which option.** Option A (mark any credited sync as priced) leaves the credit in place for base and then
  forgoes the uncharged gain every time. Option B adds the credited value to the floor. The brief's direction is
  simpler: no credit in any sync where idle base changed, so a credit can never hide a base flow. Base credits are
  therefore gone entirely.

## Tests changed

- New `test/sa/SARound8.t.sol` (7 tests). Run with `SATestBase.sol` against the sources of `3f0f42d` (git worktree):
  6 fail there, 1 passes on both (USDC-only onboarding sanity).
- Removed (mechanism gone): `SARound7.test_Open_RegistrationBooksHoldings`.
- Adapted:
  - `SARound3.test_M1_PoC_ClientCollectIsProfit` and `SARound5.test_L2_PlainCollectAfterSyncIsYield`. The client now
    collects to its wallet and returns the USDC part, so the USDC credit (with its global-mark logic) is still covered.
    The base fees leave the profit as yield taken out. A collect into the account is covered by
    `SARound8.test_L1_Sibling_CollectWithBaseIsPricedContribution`.
  - `SATestBase._pending` / `_credit` follow the new credit rule.

## Keeper and web

- No ABI change (no function, event or struct changed). `keeper/abi/LPManagerModule.json` is unchanged.
- `sa_chain.ModuleReader.pending`: the mirror of `SABook.sync` gives no credit while idle base differs from the
  snapshot, and the credit is USDC only.
- `sa_keeper.anchor`: SA-8 L-3 refresh rule (above).
- Onboarding: no requirement changed, so the relayer and the web wizard need no new check. A first registration books
  nothing, and the web view already shows idle minus the snapshot as pending, so a fresh account shows its holdings as
  pending until the keeper's first trusted sync. Comment in `web/account.js` updated.
