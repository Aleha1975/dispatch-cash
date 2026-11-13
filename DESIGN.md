# Design and threat model

## Why asynchronous

LP value depends on the pool price, which a single swap can move in a thin pool (Elysium HYPE/USDC v4 virtual
depth is a few hundred thousand USD). Synchronous ERC-4626 deposit/withdraw would let anyone enter or exit at a
manipulated or stale NAV. Here every share is minted or burnt only inside `settle`, by the keeper, at a NAV built
from a price that must agree with the pool price within `poolBandBps` AND that may move the vault's own price
anchor only at a bounded daily rate. Clients still need only one transaction each way (redemptions are pushed).

## The three keeper budgets (one mechanism)

The keeper is a hot key and is treated as semi-trusted: a compromised keeper must not be able to take more than
a bounded, NAV-relative amount per day, and no limit may ever block a client's withdrawal. Every keeper input that
can move value goes through one of three budgets, all built on the same primitive in the linked library
`RiskBudgets`: an amount `used` spent at time `t` is restored linearly over the next 24 h
(`used' = used x (1 day - elapsed) / 1 day + new`). There is no window the keeper can reset (settling is free), and
any 24 h interval admits at most ~1.6x the budget (a fixed window admitted 2x in two blocks).

| Budget | Charged by | Size (default) | Base |
|---|---|---|---|
| Price anchor | every `settle` that moves `lastPrice` (relative move, compounding) | `refDriftBps` = 10%/day; 0 while paused | the anchor itself |
| Hedge equity | keeper-only decreases of the reported off-chain equity | `hedgeStepBps` = 5% of NAV/day | `lastNav`, which never contains the settling epoch's deposits |
| Turnover | swap notional; LP-add value at the anchor x slippage / (band + slippage) | `swapTurnoverBps` = 2x NAV/day | `lastNav` |

Guardian co-signatures bypass a budget for one specific value: `approvePrice(lo, hi, until)` lets settlements
in that range move the anchor freely (also while paused); `approveHedgeEquity(value, until)` lets one settlement
in the current epoch apply exactly `value` (also an increase). Hedge approvals are cleared by any margin send or
return, because they were judged against the old baseline.

A report that a budget has to clip **never reverts** (that would block redemptions). The vault applies the clipped
value (the anchor edge, or the old hedge equity), processes **redemptions only** (no deposits: they wait and stay
cancellable), and takes **no fee**. `Settled` carries the applied price and equity.

### Price anchor (`lastPrice`)

- `settle(price)` requires `price` within `poolBandBps` of the pool, then moves the anchor toward it within the
  price budget. NAV, flows and fee use the anchored price.
- `swap`, `mintPosition`, `increasePosition` require the keeper price within `poolBandBps` of the pool AND of the
  anchor. Swap min-out is fair value at the keeper price minus `maxSlippageBps`, so one swap loses at most
  band + slippage against the anchor.
- An LP add is a swap in effect. The vault measures what it paid (drop of its held value at the anchor, fees
  collected by an increase net against it), values the new liquidity at the anchor
  (`V4PositionMath.liquidityValue`), requires value >= paid x (1 - `maxSlippageBps`) and charges
  paid x slippage / (band + slippage) to turnover (an add can lose only the slippage, a swap band + slippage, so one
  turnover unit always stands for the same worst-case loss).
  A narrow single-sided "limit order" next to a displaced spot is worth much less at the anchor than it cost, so it
  reverts; an ordinary range around the pool price passes (its value at the anchor differs by IL-sized amounts).
- While paused the anchor is frozen unless the guardian approves a range: a hostile keeper cannot walk redemption
  prices after the guardian reacts.
- The keeper reports the anchor itself while the fresh price is within `anchor_hysteresis_bps` (25) of it, so
  ordinary chop costs no budget.

### Hedge equity

- The keeper alone can only LOWER the reported equity (decreasing budget above). Any increase needs the guardian.
  A fake increase was the round-1 H-1 problem: a budget relative to NAV is amplified by an accomplice's deposit
  (fake 5% of a 10x-inflated NAV, paid out to the accomplice's redeem). Decreases cannot be amplified that way: an
  accomplice who deposits at an understated NAV gains at most the understatement, which is bounded by the budget on
  the pre-deposit NAV, and earlier accomplice capital bears its own pro-rata part.
- `netMargin` = margin sent - margin returned. `sendHedgeMargin` requires
  `max(hedgeEquity, netMargin) + amount <= hedgeCapBps x lastNav`, so reporting equity down no longer frees room
  for more USDC at the treasury.
- Unhedged vault: `hedgeEquity` stays 0 (`settle` reverts `NoHedge` otherwise) and `hedgeStepBps` must be 0.

## Accounting

- `pendingDepositAssets` and `totalClaimable` are segregated from NAV and checked after every keeper action
  (`_checkReserve`), so queued client money and unpaid claims can never be invested, swapped or sent to hedge.
- Locked redeem shares stay in `totalSupply` until settled: they carry PnL until their price is fixed. Shares can
  enter the vault only through `requestRedeem` (`balanceOf(vault) == lockedShares` always).
- Redeem queue is FIFO; the head is paid partially with all idle USDC when it cannot be paid in full.
- Virtual shares (offset 10^6, OZ style `+1` virtual asset) make donation / first-depositor inflation unprofitable.
  A deposit that would mint 0 shares is refunded as a claim instead of being donated; dust redeems that would pay 0
  are refused.
- Rounding: shares out floor, assets out floor, LP principal floor, fee shares floor.
- Fee: `gain = (pps - HWM) * supply`, `feeAssets = gain * feeBps`, `feeShares = feeAssets * (S+V) / (NAV+1-feeAssets)`,
  then HWM = new pps. The HWM never decreases while shares exist; after a full exit (supply 0) it restarts from the
  current pps. A sub-unit fee that floors to 0 still raises the HWM (<= 1 raw unit per settlement uncharged).
- Failed USDC pushes (redeems, deposit cancellations, the USDC leg of `emergencyRedeem`) are credited to `claimable`;
  `claimTo(to)` lets a blocked owner route the claim elsewhere.

## Compromised-keeper damage per day (defaults, per channel)

| Channel | Bound | Defaults |
|---|---|---|
| NAV price (with an accomplice and pool pushes) | base exposure x anchor movement; anchor moves <= ~1.6 x `refDriftBps` per 24 h, only with the pool pushed within the band at each report, and not at all once the guardian pauses | 50% base: ~5-8% of NAV; ~5% for a single round trip within one day |
| Hedge equity | understatement <= `hedgeStepBps` of the pre-deposit NAV; fake increases impossible without the guardian | 5% |
| Execution (swaps + LP adds) | (`poolBandBps` + `maxSlippageBps`) x turnover against the anchor | 2.5% x 2 = 5% |
| Custody (not theft by the keeper) | `max(hedgeEquity, netMargin) <= hedgeCapBps` at the operator's treasury | 35% |

These are worst cases that need a compromised keeper, accomplice capital and (for price) repeated pool
manipulation. They are per channel, not additive in practice (each one consumes the same accomplice capital and
pool round trips). The operator can tighten `refDriftBps` and `swapTurnoverBps`; the cost is more guardian
co-signatures in fast markets and fewer re-ranges per day. The guardian bot (independent HL price and equity
check) is the backstop: pause freezes the anchor, fees and hedge increases while redemptions continue.

Known residual (price channel): the NAV error is proportional to the vault's base exposure, so accomplice capital
that the keeper converts into base before the price walk enlarges it. The anchor's daily rate, the pool band at
each report and the guardian pause bound the time and size of such a walk; there is no trustless price feed on
Elysium to remove it entirely.

## Threats and mitigations

| # | Threat | Mitigation | Residual |
|---|---|---|---|
| 1 | Keeper key stolen: drain to own address | No arbitrary calls. Token exits: clients (settlement), PositionManager with recipient = vault, PoolManager swap of the fixed pool (take to vault), immutable `hedgeTreasury` | Treasury is the operator's HL account: up to `hedgeCapBps` (35%) of NAV (max of reported equity and net margin sent) is under operator custody by design |
| 2 | Keeper sandwiches its own swaps / LP adds | Keeper price within the band of pool and anchor; swap min-out at keeper price - slippage; LP adds valued at the anchor within slippage; swap + add notional <= `swapTurnoverBps` x NAV per decaying day | <= (band + slippage) x turnover against the anchor: 5% of NAV/day at defaults |
| 3 | Keeper misreports NAV (price) | Price within the pool band; anchor moves <= `refDriftBps`/day; clipped reports process no deposits and take no fee; frozen while paused | In-band skew per settlement (~0.75% of NAV at 50% base); repeated skew bounded by the anchor's daily movement (see table above) |
| 4 | Keeper misreports hedge equity | Keeper can only lower it, <= `hedgeStepBps` of pre-deposit NAV/day; increases need the guardian's exact, expiring, epoch-bound value | Understatement <= 5%/day; stale reporting of a real loss is undetectable on-chain (guardian bot compares with HL) |
| 5 | Pool price manipulation by third parties at settlement | Band check reverts settlement; swaps/adds checked against pool and anchor | Keeper must wait for arbitrage; liveness depends on the pool tracking HL |
| 6 | Keeper offline / operator gone / keeper stalls redeems | Liveness clock = time since the redeem queue last made progress (or was empty); after 72 h anyone arms `emergencyUnwind`, executes 6 h later unless a settlement makes progress; pro-rata in-kind exit | Hedge margin off-chain until returned |
| 7 | Emergency unwind at a manipulated price | Removing liquidity at a pushed price costs the pusher; exit is in kind | none material (the 10% band of round 0 only delayed honest exits) |
| 8 | Inflation / donation | Virtual shares; explicit reserve accounting; zero-share deposits refunded | Donations go to holders |
| 9 | Reentrancy (native HYPE callbacks, POSM, PoolManager) | `nonReentrant` (transient) on every state-changing entry; `unlockCallback` only from PoolManager while `_swapping`; burn before pay in emergency redeem | `receive()` accepts native from anyone (harmless donation) |
| 10 | Client that cannot receive USDC | `trySafeTransfer`; failure credits `claimable`; `claimTo(to)` | none |
| 11 | Queue spam / head-of-line | `maxDeposits`/`maxRedeems` per call; cancelled entries skipped; head filled partially | Gas cost to the keeper; `minDeposit` (1 raw unit .. 100 USDC) only for deposits |
| 12 | Guardian abuse | Guardian can pause, co-sign one hedge value per epoch and price ranges; cannot unpause, move funds or change params | A malicious pause stops deposits, swaps and LP adds and freezes the anchor (redemptions continue at the frozen price until unpaused); a guardian that co-signs false values together with a hostile keeper defeats the budgets (two keys) |
| 13 | Owner key stolen | Owner is `VaultTimelock`: every change waits >= the delay (96 h in `Deploy`, floor 24 h, cap 30 d); guardian can cancel any vault operation; mixed self/vault batches revert; ready operations expire after 7 days; `renounceOwnership` disabled | After the delay: keeper swap, params up to hard caps. The operator can remove the guardian's cancel right with one self-only operation (visible for the full delay) |
| 14 | Fee rate raised retroactively | Capped at 20%; timelocked; applies from the next settlement to gains above the HWM | Gains between the last settlement and the change are charged at the new rate |
| 15 | Permit front-running | `permit` in try/catch; proceeds if allowance exists | none |
| 16 | Stuck positions in emergency | Per-position try/catch with >= 1M gas per attempt (a caller cannot induce a failure by under-supplying gas); `emergencyRedeem` refused while positions are open for 7 days | Value in a position that never unwinds is excluded from in-kind payouts after 7 days |

## Design deviations from the brief

- **Pause and settlement**: settlement, liquidity removal, hedge sends and returns stay available while paused, so a
  pause never blocks redemptions or a hedge top-up. Pause stops new deposits (requests and processing), mints,
  increases and swaps, freezes the anchor and the fee.
- **Swaps** go directly through `PoolManager.unlock` (exact input, own callback) instead of the Universal Router.
- **Redeem cancellation** only in emergency mode; allowing it at any time would give redeemers a free option against
  the keeper's pending settlement price.
- **Emergency** is permanent wind-down, not pausable/resumable, and pays out in kind.
- **Factory**: none; one constructor-parameterised deployment per strategy. Linked libraries `V4PositionMath`
  (valuation + PositionManager calldata) and `RiskBudgets` keep the vault under EIP-170.

## Open items before launch

1. Audit round 2 (`docs/audit_round2.txt`); fuzz on fork with real HL-pool divergence data.
2. Guardian bot (multisig-held key): compares keeper reports with HL price and equity, co-signs
   `approvePrice`/`approveHedgeEquity` with short deadlines, pauses on mismatch, watches `CallScheduled` events.
3. Elysium RPC/sequencer: v4 already requires Cancun (TSTORE) there; the vault uses transient reentrancy guard too.
4. Keeper must keep enough idle USDC buffer (e.g. 5-10% NAV) so routine redemptions settle without unwinding.
5. Ramses CL subclass (v3-style NPM: `positions()` view, `collect`, WHYPE ERC-20 base).
6. Confirm Elysium's `MaxCodeSize` (Orbit chain config) equals 24,576; vault runtime is 24,276 B.

## Accepted risks

- Fund-level HWM: capital that enters during a drawdown recovers to the mark without a fee (free ride).
- After a full exit (supply 0), anything left (dust, late hedge return) stays with the virtual shares and makes share
  units coarse; a later deposit that would buy 0 shares is refunded, others lose at most one share unit.
- Emergency in-kind payouts exclude hedge margin not yet returned; early emergency redeemers forgo it.
- A redemption processed in a clipped settlement is priced at the clipped (anchor-edge / old-equity) values. In a
  market moving faster than the budgets this can be above or below fair; the keeper waits up to
  `guardian_wait_s` for a co-signature before settling redeems clipped.
- `swap` has no caller min-out/deadline beyond `maxSlippageBps` (L-15): the anchor band bounds a delayed transaction.

## Audit round 1 (2026-11-13)

Report: `docs/audit/round1_report_1222.md`; response per finding: `docs/audit/round1_response.md`.
