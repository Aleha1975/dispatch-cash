# Dispatch.cash — GuardedSwap design

**What it is.** Dispatch.cash copies the trades of selected Base traders into each client's own MetaMask smart account. The client never hands over funds: a delegation lets the Dispatch executor call one contract, GuardedSwap, and nothing else. GuardedSwap sits between the account and the KyberSwap aggregator router and is the only path through which the executor can move the client's money. Its purpose is to make a stolen executor key nearly worthless.

**Threat model.** The executor key leaks. The attacker can call `buy`/`sell`/`announce` on behalf of every client account and can build any router calldata. The attacker cannot change the delegation, cannot withdraw and cannot call the router directly. The guardian key (pause only) may also leak. The router and its executor are trusted infrastructure; the tokens are not.

## Rules (v15)

| Rule | What it enforces |
| --- | --- |
| Recipient | Everything a swap returns — tokens, ETH, change — is paid to the calling account. There is no recipient parameter; the router calldata is decoded on-chain and must name the account (buy) or this contract (sale, forwarded after settlement). |
| Route check | Only `swap(SwapExecutionParams)` of the pinned router, run by the pinned executor; of the router's `flags` only bit `0x200` may be set (every bit the router dispatches on is refused); no fee receivers, no `permit`; declared tokens and amounts must match; a buy may not hand its input to any `srcReceivers`. |
| Loss budget | Every buy is recorded at cost. Selling below cost is a loss; losses per account must stay within 30% of the account's cost basis, and what is outstanding fades linearly over a week from its last booking — nothing but time or the cold key's unlock moves it. A sale beyond the budget does not go through. Sales at or above cost are never limited: taking profit is never delayed, one position crashing is far inside the budget, a thief dumping everything hits it within minutes. |
| Only the lot | A sale can cover at most the tokens this contract saw bought for the account; the lot is reconciled with the balance at every call and closes when the account holds nothing. |
| Rate limits | Per account and hour: 12 sales, 0.3 ETH into buys, 1 ETH out of sales. The delegation adds 0.5 ETH per 24 h. |
| Guardian | Pause the executor — buys and sells — for at most 7 days, then a day's cooldown. Never blocks `exit()` or the owner's own wallet. No other power. |
| Exit key | The operator's cold key, kept off the trading machine. `unlock` clears an account's losses when a crash was the market; `replaceGuardian` removes a guardian that misbehaves. `exit` sells a position outside the budget and the limits — still paid only to the account — to evacuate every client into ETH when the executor key is compromised. |

No owner, no upgrade path, no funds held between calls. Anyone may call it; it can only ever pay the caller.

## The incident protocol

Two watchers — one next to the engine, one on separate infrastructure with a mirrored journal — reconcile the gate's on-chain events with the engine's own journal: an event with no journal entry is a trade by a foreign key — a breach, not a heuristic. On a breach it pauses buys, stops the engine and alerts the operator. The operator, from a phone, either clears the budget (`unlock`: a market crash) or evacuates (`exit` for every position: a theft). Clients are not involved; their funds never left their own accounts. The executor key is then rotated and clients re-sign on their next visit.

## What a stolen key can still do (documented residuals)

- Trade badly within the loss budget and the hourly budgets: at most 0.3 ETH per hour into buys with no price reference for a buy (0.5 ETH per 24 h in the delegation), and sales below cost up to 30% of the account's cost basis per week.
- The budget is relative to what was paid, not to the market: a position that has appreciated can be sold at cost without touching it.
- A route may deliver the sold tokens to a pool the aggregator chose; a planted sink cannot be told apart on-chain, and is bounded by the loss budget. An `exit` runs outside the budget, so the exit transaction is built on the operator's side with an independent quote and is not signed below 90% of it.
- A token whose balance stops answering keeps its last known lot; the gate never takes an unreadable balance as empty.

## What the client keeps

- Withdrawals never pass through this contract; the client's own delegation and wallet are untouched.
- Positions the gate did not buy are the owner's to sell directly.
- Revoking the delegation ends everything at once.

## Security, as we say it to clients

The client-facing wording. It names only what a client can verify on chain or in this repository, states the limit honestly, and leaves out the operational detail (thresholds, alerting, key custody, standby mechanics).

> **Your funds never leave your account.** Dispatch does not take custody. Each client runs their own smart account; the engine receives a narrowly scoped permission to trade on it — never to withdraw. Withdrawals are signed only by the client.
>
> **Every trade passes through an on-chain gate.** Dispatch trades through its own verified contract, GuardedSwap, which sits between the client account and the DEX aggregator. The gate enforces, on chain, what a trading key is allowed to do: swap proceeds can only be paid to the account that owns the position, only positions the gate saw bought can be sold, and every account has a loss budget — a bounded share of its cost basis per week that trades can lose. A trade outside these rules does not execute, regardless of who signed it. Even a full compromise of the trading key is therefore limited to a known, bounded loss — the gate limits damage; it does not promise there can be none. The source is public and verified; the current deployment is linked from the app.
>
> **Independent review.** The gate has gone through repeated rounds of independent security review, with every finding either fixed or documented; the audit log, including what was found and how it was answered, is published alongside the code.
>
> **Monitoring and incident response.** Activity on the gate is reconciled continuously against the engine's own records on separate infrastructure; anything the engine did not initiate triggers an automatic halt of new trades and an operator response. A cold key kept off every server can, in an incident, move every client's positions into ETH — on the clients' own accounts, with no action required from clients.
>
> **Continuity.** The service runs on dedicated infrastructure with a warm standby, minute-level state replication and encrypted off-site key backups.

Deliberately not in the client wording: the numeric limits (they may still be tuned), the alerting channel, key addresses and custody, how failover is performed, and the auditing service's name.

## Audit history

Twelve independent rounds (One Dollar Audit, October 2026) against v2 → v13, every report in `AUDIT.md` with the response to each finding. Rounds 1–7 reported 7 Critical and 6 High in total, each fixed in the next version with the auditor's proof of concept added as a test. Rounds 8–10 reported no Critical or High; rounds 9–10 no Medium. Round 11, the first against the loss budget (v12), found that the budget's refill was measured against a live base the account's own calls could move (1 Critical, 2 High, 1 Medium); v13 freezes the refill rate at booking, guards the balance reads and measures the returned tokens on the account, with stateful invariant tests added. Round 12 (v13) found no Critical: one High — a cost-based budget's ceiling can be inflated by self-dealt buys at near-zero cost, which no contract mechanism closes without a price oracle or per-position floors; v14 answers it at the system boundary by making a pause stop the executor's sales as well as its buys, so the watchers' first reaction ends an attack. Round 13 (v14) found no Critical: two Highs on the seams of the earlier fixes (an unlock gate that a contract between the cold key and the gate could reach; a refill rate that drifted from the documented week) — v15 answered by removing the rate and gating unlock on the direct caller, and gave the cold key the power to replace a guardian. Round 14 (v15) found no Critical and no High: the cycle on the loss-budget design is closed. The last two versions answered findings by removing mechanisms (self-declared prices, guardian cancellations, a second router entry point) rather than adding them, after the pattern of rounds 2–7 — each new finding at the seam between a fix and an older mechanism — became clear.

## Verification

- Live: Base, `0x2c894b3a726b49d9e68e71d548157964e5e0fbb6` — [Basescan](https://basescan.org/address/0x2c894b3a726b49d9e68e71d548157964e5e0fbb6), [Sourcify exact match](https://sourcify.dev/server/v2/contract/8453/0x2c894b3a726b49d9e68e71d548157964e5e0fbb6).
- Tests: `forge test --no-match-path test/Fork.t.sol` (43 unit tests and 4 stateful invariants over random buy/sell/warp/unlock sequences) and `forge test --match-contract Fork --fork-url <base rpc>` (3 tests against the live router with real calldata, including an exit by the cold key).
- Static analysis: Slither (v2–v11), nothing beyond the documented accepted items.
