# Dispatch.cash — GuardedSwap

The trade gate of [Dispatch.cash](https://dispatch.cash), the copy-trading engine on Base. Live contract: [`0xdbeeec5d37e7f73360e344b8fe24139232a112e6`](https://basescan.org/address/0xdbeeec5d37e7f73360e344b8fe24139232a112e6) (v12, source verified on [Sourcify](https://sourcify.dev/server/v2/contract/8453/0x2c894b3a726b49d9e68e71d548157964e5e0fbb6)). Design: [DESIGN.md](DESIGN.md). Audit history and responses: [AUDIT.md](AUDIT.md).

A one-purpose, immutable gate between a client's MetaMask smart account and the KyberSwap aggregator router on Base (chain id 8453).

The client grants its trading executor the right to call this contract instead of the router. Whatever a swap returns goes to the calling account and nobody else: there is no recipient parameter.

## Rules (v15)

1. **Recipient.** All swap output, change and unsold input are swept to `msg.sender`. Output is measured as the caller's balance change (buy) or the ETH that reached this contract (sale, forwarded after settlement) and must be at least `minOut` (> 0). ETH is accepted only while a trade is in progress.
2. **Route check.** Only `swap(SwapExecutionParams)` of the pinned router, run by the pinned executor; of `flags` only bit `0x200` may be set (the one bit live routes carry and the router's verified source never reads; every bit the router dispatches on is refused); `approveTarget` zero or the executor, `dstReceiver` this contract (a buy may also name the caller), no fee receivers, no `permit`, declared tokens and amounts must match, the router's `minReturnAmount` at least our `minOut`; a buy may not name any `srcReceivers`, a sale's `srcReceivers` (at most 8) must be contracts other than the caller and this contract with amounts summing to at most the input. Anything else reverts `BadRoute`.
3. **Loss budget.** Every buy is recorded in the account's lot for that token at cost. A sale that returns less than the cost of the tokens it gives up is a loss; losses accumulate per account and must stay within 30% (`BUDGET_BPS`) of the account's total cost basis, refilling linearly over a week (`REFILL`). A sale that would exceed the budget does not go through (`BudgetExceeded`). Sales at or above cost never touch the budget, so taking profit is never delayed; a crash of one position is far inside the budget; a thief dumping everything hits it within minutes.
4. **Only the lot is for sale.** `sell()` handles at most the tokens this contract saw bought for the account (`NotInLot`). Tokens that reached the account any other way are the owner's to sell directly. The lot shrinks by what the account gave up, never exceeds what the account holds (tokens the owner moved out leave the lot pro rata, as if sold at cost) and closes when the account holds none of the token.
5. **Rate limit.** Per account and fixed hour window: at most 12 sales, 0.3 ETH of net ETH spent on buys and 1 ETH taken out of sales (deployment parameters). A burst at the window edge can reach twice the limit across two windows. The delegation adds 0.5 ETH per 24 h.
6. **Guardian.** Pause the executor — buys and sells — for at most 7 days, then a day of cooldown. Never blocks `exit()` or the owner's own wallet. No other power.
7. **Exit key.** The operator's cold key, never on the trading machine. `unlock(accounts)` clears accumulated losses (a crash was the market, not a theft). `exit(token, amount, minOut, routerData)`, reached through the account's own delegation to the exit key (`tx.origin` is the key, `msg.sender` the account), is the same sale outside the loss budget and the hourly limits — used to turn every position into ETH on the clients' own accounts when the executor key is known to be compromised. Neither key can send anything anywhere but the account.
8. **Per-call accounting.** Balances are measured as deltas around the router call; anything sent to the contract outside a call is neither swept, nor counted, nor recoverable. A buy that spends nothing and a sale that moves nothing are refused. All state is written before any ETH leaves. Lots are bounded to 1e40 raw units.

Residual by design: a sale's `srcReceivers` are chosen by the aggregator and cannot be told apart from a planted sink on-chain; what such a sink can take is bounded by the loss budget. A buy has no price reference other than the hourly ETH budget. The budget is relative to what was paid, not to the market: a position that has appreciated can be sold at cost without touching it. Rebasing tokens are reconciled by the lot rule; fee-on-transfer tokens, tokens with several addresses for one balance, tokens that return `false` on success, and tokens that refuse `approve(0)` while demanding a zero allowance first are not supported.

No owner, no upgrade path, no funds kept between calls.

## Deployment on Base (live)

| | |
| --- | --- |
| GuardedSwap v15 (current) | `0x2c894b3a726b49d9e68e71d548157964e5e0fbb6` |
| GuardedSwap v14 | `0x257543fec106428c550fd3c5b375eba8d71bda5e` |
| GuardedSwap v13 | `0xdbeeec5d37e7f73360e344b8fe24139232a112e6` |
| GuardedSwap v12 | `0x455016186178544c1326cdbf9eb4a2d1a0c51ea4` |
| Deploy tx | `0xc0980d0af89e23f159b7a6c766d72e584c9b217848657c0edb4abeae93ec88e6` (block 52807106, 19 Oct 2026) |
| Executor (pinned) | `0x8F10B468b06c6FD214B65F87778827F7D113f996` (Kyber aggregation executor) |
| Previous | v11 `0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a` (round-10 subject), v10 `0x72ac1cd4b96988b14b0a55b5bf962ba3eb314a39` (round 9), v9 `0x2ea0ed9b4eaf9e6c17231e10d56531ce77faef50` (round 8), v8 `0x061c0a41bb8d83e6fecc3142f3801fed9e5b88d4` (round 7), v7 `0xb1ef2b0c04e65b22e70bc6a54ddf454259d726e4` (round 6), v6 `0x259f17ed184ff97730407002140bcd512dca7a0a` (round 5), v5 `0x3511a33478465d2f6fd5ebfebf52160ef39ec7a1` (round 4), v4 `0x970b033ab9965ce9c9f92584b529afa6100a994e` (round 3), v3 `0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485` (round 2), v2 `0x91b51882805051b83efc53e7407a01894d341ca0` (round 1) |
| Router | `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2) |
| Guardian (pause only) | `0x5550C8E49616C15B89FdD1DaECddc493009e039B` |
| Exit key (unlock, exit) | `0xe90E76A6e5AC772193826218821D89e0aB0CEaBD` (cold) |
| Limits | 12 sells / hour, 0.3 ETH of buys / hour, 1 ETH out of sales / hour per account |
| Source verification | Sourcify exact match: https://sourcify.dev/server/v2/contract/8453/0x2c894b3a726b49d9e68e71d548157964e5e0fbb6 |

## Views

`lotOf` returns the lot as the next call will reconcile it with the account's balance (`basis` is the raw record); `budgetOf` returns the losses on record (decayed) and the budget they must stay within; `floorFor` quotes the lowest ETH a sale of `amount` may return without exceeding the budget.

## Constructor

`constructor(address router, address executor, address guardian, address exitKey, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour, uint256 maxSellEthPerHour)`

Production: router `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2), guardian = the operator's pause key, limits 12, 0.3 ether and 1 ether.
