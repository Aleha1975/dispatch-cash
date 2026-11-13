# Design and threat model

## Why asynchronous

LP value depends on the pool price, which a single swap can move in a thin pool (Elysium HYPE/USDC v4 virtual
depth is a few hundred thousand USD). Synchronous ERC-4626 deposit/withdraw would let anyone enter or exit at a
manipulated or stale NAV. Here every share is minted or burnt only inside `settle`, by the keeper, at a NAV built
from a keeper price that must agree with the pool price within `poolBandBps`. Clients still need only one
transaction each way (redemptions are pushed).

## Accounting

- `pendingDepositAssets` and `totalClaimable` are segregated from NAV and checked after every keeper action
  (`_checkReserve`), so queued client money and unpaid claims can never be invested, swapped or sent to hedge.
- Locked redeem shares stay in `totalSupply` until settled: they carry PnL until their price is fixed.
- Virtual shares (offset 10^6, OZ style `+1` virtual asset) make donation / first-depositor inflation unprofitable
  (unit test: a 1-wei first depositor donating 100k USDC loses money; the victim loses < 1%).
- Rounding: shares out floor, assets out floor, LP principal floor, fee shares floor.
- Fee: `gain = (pps - HWM) * supply`, `feeAssets = gain * feeBps`, `feeShares = feeAssets * (S+V) / (NAV+1-feeAssets)`,
  then HWM = new pps. Invariant-tested: fee value never exceeds 20% of the gain.

## Threats and mitigations

| # | Threat | Mitigation | Residual |
|---|---|---|---|
| 1 | Keeper key stolen: drain to own address | No arbitrary calls. Token exits: clients (settlement), PositionManager with recipient = vault, PoolManager swap of the fixed pool (take to vault), immutable `hedgeTreasury` | Treasury is the operator's HL account: up to `hedgeCapBps` (35%) of NAV is under operator custody by design |
| 2 | Keeper sandwiches its own swaps / mints | Keeper price within band of pool and within `refDriftBps` of last settled price; min-out = fair value at keeper price - `maxSlippageBps`; swap notional <= `swapTurnoverBps` x NAV per rolling day (not per settlement: settling is free, a per-epoch budget could be reset at will) | Up to ~(band + slippage) per swap, bounded by turnover: worst case a few % of NAV per day until the guardian pauses |
| 3 | Keeper misreports NAV (price) | Price must sit within 1.5% of the pool | Within the band the keeper chooses: ~0.75% of NAV skew on a 50% HYPE leg per settlement; an accomplice depositing/redeeming could harvest that |
| 4 | Keeper misreports hedge equity | Absolute drift <= `hedgeStepBps` (5%) of NAV per rolling day; larger only with guardian's exact value for that epoch | 5%/day of NAV can be faked; monitor HL equity independently (guardian bot) |
| 5 | Pool price manipulation by third parties at settlement | Band check reverts settlement; mints/increases/swaps also band-checked | Keeper must wait for arbitrage; liveness depends on the pool tracking HL |
| 6 | Keeper offline / operator gone | `emergencyUnwind` after 72 h by anyone, pro-rata in-kind exit | Hedge margin off-chain until returned |
| 7 | Emergency unwind at a manipulated price | 72 h - 7 d: pool within 10% of last settled price; after 7 d unconditional | After 7 d an attacker can manipulate then trigger; cost is the swap round trip |
| 8 | Inflation / donation | Virtual shares; explicit reserve accounting | Donations go to holders |
| 9 | Reentrancy (native HYPE callbacks, POSM, PoolManager) | `nonReentrant` (transient) on every state-changing entry; `unlockCallback` only from PoolManager while `_swapping`; checks-effects before transfers in emergency redeem | `receive()` accepts native from anyone (harmless donation) |
| 10 | Redeemer that cannot receive USDC blocks the queue | `trySafeTransfer`; failure credits `claimable` | none |
| 11 | Queue spam | Keeper processes `maxDeposits`/`maxRedeems` per call; cancelled entries skipped | Gas cost to the keeper; `minDeposit` (<= 100 USDC) only for deposits |
| 12 | Guardian abuse | Guardian can only pause risk-increasing actions and approve one hedge value per epoch; cannot unpause or move funds | A malicious pause stops new deposits only |
| 13 | Owner key stolen | Cannot move funds; can swap keeper, widen params up to hard caps (band 5%, slippage 5%, turnover 5x) | Recommend a timelock on owner actions before TVL grows |
| 14 | Fee rate raised retroactively | Capped at 20%; applies from the next settlement to gains above the HWM | Gains between the last settlement and the change are charged at the new rate |
| 15 | Permit front-running | `permit` in try/catch; proceeds if allowance exists | none |
| 16 | Stuck positions in emergency | Per-position try/catch; `emergencyUnwind` can be re-called | Value in a position that never unwinds is excluded from in-kind payouts |

## Design deviations from the brief

- **Pause and settlement**: the brief says the guardian pauses "keeper actions". Settlement, liquidity removal and
  hedge returns stay available while paused, because otherwise a pause would block redemptions. Pause stops new
  deposits (requests and processing), mints, increases, swaps and hedge sends.
- **Swaps** go directly through `PoolManager.unlock` (exact input, own callback) instead of the Universal Router:
  smaller allowlist surface, no router calldata parsing, exact `minOut` check.
- **Redeem cancellation** only in emergency mode (needed for `emergencyRedeem`); allowing it at any time would give
  redeemers a free option against the keeper's pending settlement price.
- **Emergency** is permanent wind-down, not pausable/resumable, and pays out in kind (no oracle-free swap to USDC).
- **Hedge equity bound** is a rolling-day budget (5% of NAV) rather than per-settlement, so frequent settlements
  cannot compound it.
- **Factory**: none; one constructor-parameterised deployment per strategy (the vault is near EIP-170; position math
  is a linked library).

## Open items before launch

1. External audit; fuzz on fork with real HL-pool divergence data.
2. Owner timelock (e.g. OZ TimelockController) and multisig guardian bot that checks HL equity independently.
3. Elysium RPC/sequencer: v4 already requires Cancun (TSTORE) there; the vault uses transient reentrancy guard too.
4. Keeper must keep enough idle USDC buffer (e.g. 5-10% NAV) so routine redemptions settle without unwinding.
5. Ramses CL subclass (v3-style NPM: `positions()` view, `collect`, WHYPE ERC-20 base).
