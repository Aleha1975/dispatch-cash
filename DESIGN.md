# Dispatch.cash — GuardedSwap design

**What it is.** Dispatch.cash copies the trades of selected Base traders into each client's own MetaMask smart account. The client never hands over funds: a delegation lets the Dispatch executor call one contract, GuardedSwap, and nothing else. GuardedSwap sits between the account and the KyberSwap aggregator router and is the only path through which the executor can move the client's money. Its purpose is to make a stolen executor key nearly worthless.

**Threat model.** The executor key leaks. The attacker can call `buy`/`sell`/`announce` on behalf of every client account and can build any router calldata. The attacker cannot change the delegation, cannot withdraw and cannot call the router directly. The guardian key (pause only) may also leak. The router and its executor are trusted infrastructure; the tokens are not.

## Rules (v11)

| Rule | What it enforces |
| --- | --- |
| Recipient | Everything a swap returns — tokens, ETH, change — is paid to the calling account. There is no recipient parameter; the router calldata is decoded on-chain and must name the account (buy) or this contract (sale, forwarded after settlement). |
| Route check | Only `swap(SwapExecutionParams)` of the pinned router, run by the pinned executor; of the router's `flags` only bit `0x200` may be set (the one bit live routes carry and the router never reads; every bit the router dispatches on — partial fill, extra ETH, claim, burn, simple mode, fees, approve — is refused); no fee receivers, no `permit`; declared tokens and amounts must match; a buy may not hand its input to any `srcReceivers`. |
| Price floor | Every buy is recorded in the account's lot for that token: its reference price (first buy) and its cost-weighted average. The floor price is the higher of the two. A fast sale must return at least 50% of the floor price for the tokens given up. |
| Only the lot | A sale can cover at most the tokens this contract saw bought for the account. Airdrops and positions opened before the gate are the owner's to sell directly. The lot is reconciled with the account's balance at the start of every call and closes when the account holds nothing. |
| Slow path | Below the fast floor, or under a pause, a sale needs `announce(token, amount)` one hour earlier (the operator's warning), never more than the lot, and must still return 20% of the floor price. |
| Rate limits | Per account and hour: 12 sales, 0.3 ETH into buys, 1 ETH out of sales. The delegation adds 0.5 ETH per 24 h. |
| Pause | The guardian can pause buys for at most 7 days, then must wait a day; a pause delays exits by an hour but never blocks them. The guardian has no other power. |
| Repeat buys | Priced within [0.5x, 4x] of the lot's reference, so repeats cannot move the floor step by step. |

No owner, no upgrade path, no funds held between calls. Anyone may call it; it can only ever pay the caller.

## What a stolen key can still do (documented residuals)

- Trade badly within the floors and the hourly budgets: at most 0.3 ETH per hour into buys with no price reference for the first buy of a lot (0.5 ETH per 24 h in the delegation), and sales down to 50% of the lot's cost (20% after an hour's announcement).
- The floor is relative to what was paid, not to the market: a position that has appreciated can be sold fast for 50% of its cost. No oracle exists for the long-tail tokens this engine trades; a market-based floor is a product decision.
- A route may deliver the sold tokens to a pool the aggregator chose; a planted sink cannot be told apart on-chain, and is bounded by the floors above.

## What the client keeps

- Withdrawals never pass through this contract; the client's own delegation and wallet are untouched.
- A drop of more than 80% from the floor price cannot be exited through the gate; the owner sells directly.
- Revoking the delegation ends everything at once.

## Audit history

Ten independent rounds (One Dollar Audit, October 2026) against v2 → v11, every report in `AUDIT.md` with the response to each finding. Rounds 1–7 reported 7 Critical and 6 High in total, each fixed in the next version with the auditor's proof of concept added as a test. Rounds 8–10 reported no Critical or High; rounds 9–10 no Medium. The last two versions answered findings by removing mechanisms (self-declared prices, guardian cancellations, a second router entry point) rather than adding them, after the pattern of rounds 2–7 — each new finding at the seam between a fix and an older mechanism — became clear.

## Verification

- Live: Base, `0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a` — [Basescan](https://basescan.org/address/0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a), [Sourcify exact match](https://sourcify.dev/server/v2/contract/8453/0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a).
- Tests: `forge test --no-match-contract Fork --fuzz-runs 2000` (74 unit tests) and `forge test --match-contract Fork --fork-url <base rpc>` (2 tests against the live router with real calldata).
- Static analysis: Slither, nothing beyond the documented accepted items.
