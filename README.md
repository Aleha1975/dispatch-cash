# Dispatch.cash — GuardedSwap

The trade gate of [Dispatch.cash](https://dispatch.cash), the copy-trading engine on Base. Live contract: [`0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a`](https://basescan.org/address/0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a) (v11, source verified on [Sourcify](https://sourcify.dev/server/v2/contract/8453/0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a)). Design: [DESIGN.md](DESIGN.md). Audit history and responses: [AUDIT.md](AUDIT.md).

A one-purpose, immutable gate between a client's MetaMask smart account and the KyberSwap aggregator router on Base (chain id 8453).

The client grants its trading executor the right to call this contract instead of the router. Whatever a swap returns goes to the calling account and nobody else: there is no recipient parameter.

## Rules

1. **Recipient.** All swap output, change and unsold input are swept to `msg.sender`. Output is measured as the caller's balance change and must be at least `minOut` (> 0).
2. **Route check.** The router calldata (`swap(SwapExecutionParams)` only; of `flags` only bit `0x200` may be set — the one bit live routes carry and the router never reads — because the router dispatches on the others: bit `0x20` takes execution into its simple mode whose pools live in `targetData`, a field this contract does not check) is decoded on-chain: `callTarget` must be `EXECUTOR`, `approveTarget` zero or `EXECUTOR`, `dstReceiver` this contract (a buy may also name the caller), no fee receivers, no `permit`, `srcToken`/`dstToken` the declared pair, `amount` the declared amount, the router's `minReturnAmount` at least our `minOut`; a buy may not name any `srcReceivers`, a sale's `srcReceivers` (at most 8) must be contracts other than the caller with amounts summing to at most the input. Anything else reverts `BadRoute`.
7. **Per-call accounting.** Token and ETH balances are measured as deltas around the router call; anything sent to the contract outside a call is neither swept, nor counted, nor recoverable (ETH is accepted only while a trade is in progress, from whoever pays the sale — the router or its executor on unwrapping). The hourly ETH budget counts net spend; a buy that spends nothing is refused. A sale is paid to this contract and forwarded after settlement, so all state is written before any ETH leaves and a caller's `receive()` hook sees the post-trade state.
8. **Reference entry.** Every repeat buy is compared with the lot's reference, not with the running average, and must price the token within [0.5x, 4x] of it (`DilutesBasis`), so repeats cannot compound. Lots are bounded to 1e40 raw units (`MAX_LOT`).

Residual by design: a sale's `srcReceivers` are chosen by the aggregator (often the first pool) and cannot be told apart from a planted sink on-chain; what such a sink can take is bounded by the floors above (50% fast, 20% announced, of the floor price). **The floor is relative to what was paid, not to the market**: a position that has appreciated can be sold fast for 50% of its cost, and the hourly sell cap is a cap on proceeds, not on the value given up. The buy budget is per hour here (0.3 ETH) and per day in the delegation that lets the executor call this contract (0.5 ETH per 24 h, `nativeTokenPeriodTransfer`); the real bound on a stolen key is that rate times the time to revocation. A drop of more than 80% from the floor price cannot be exited through the gate at all (`BelowFloor` on the slow path): the owner sells directly. The first buy of a lot has no price reference other than the hourly ETH budget. Rebasing tokens, tokens with several addresses for one balance, tokens that return `false` on success, and tokens that refuse `approve(0)` while demanding a zero allowance before a new one are not supported.
3. **Price floor.** Every `buy()` is recorded in the account's lot for that token: the lot's reference price (its first buy) and its cost-weighted average price (all buys, reduced pro rata by sales, rounded down so it never zeroes). The floor price is the higher of the two, so a cheap repeat buy cannot pull the floor below the reference and an expensive one raises it. A fast `sell()` refuses to return less than 50% (`FLOOR_BPS`) of the floor price for the tokens sold (rounded up, never to zero). A full exit resets the lot.
3a. **Only the lot is for sale.** `sell()` handles at most the tokens this contract saw bought for the account (`NotInLot`). Tokens that reached the account any other way (airdrops, positions opened before the gate) are not the executor's to sell; the account owner sells them directly. There is no price to protect those with, so the gate does not pretend to. The lot shrinks by what the account gave up (pull-side fees included), never exceeds what the account holds (tokens the owner moved out, or a negative rebase, leave the lot pro rata, as if sold at cost; tokens that arrive before the next call are treated as the lot and protected at its floor) and closes when the account holds none of the token.
4. **Slow path.** A sale below the fast floor, or under a pause, requires `announce(token, amount)` at least 1 hour earlier (`SLOW_DELAY`), covers up to that amount (never more than the lot: a fast sale or a reconciliation that shrinks the lot caps the announcement too), expires 24 hours after the delay (`ANNOUNCE_TTL`) and is consumed partially. The slow path keeps a floor of its own: 20% of the floor price (`SLOW_FLOOR_BPS`). An announcement is the operator's hour of warning about the position actually sold: any buy of the token clears it, and so does a full exit. It never licenses a sale for dust. The account can `cancelAnnounce`; the guardian cannot touch announcements. `SlowSaleArmed` is the monitoring event.
5. **Rate limit.** Per account and fixed hour window: at most `MAX_SELLS_PER_HOUR` sales, `MAX_BUY_ETH_PER_HOUR` of net ETH spent on buys and `MAX_SELL_ETH_PER_HOUR` of ETH taken out of sales (deployment parameters; production 12, 0.3 ETH and 1 ETH). A burst at the window edge can reach twice the limit across two windows.
6. **Pause.** The guardian can pause buys; under a pause every sale takes the announced slow path, so a pause can delay an exit by an hour but never block it. A pause expires by itself after 7 days (`PAUSE_MAX`) and a new one may start only 1 day after the last one ended (`PAUSE_COOLDOWN`), so the fast path is open at least one day in eight whatever the guardian does. The guardian is rotated in two steps (`proposeGuardian` / `acceptGuardian` within 7 days, never to zero, itself, the router or the executor), has no other power, cannot move funds and cannot touch announcements. Client withdrawals never pass through this contract.

Audit round 1 (18 Oct 2026) findings and their fixes: H-1 route decoding (rule 2); H-2 whole-sale floor (rule 3); M-2 per-call ETH accounting (stray ETH is neither swept nor counted); L-2 bounded, expiring announcements (rule 4); L-3 pause never blocks exits (rule 6); I-2 `token` must be a contract. M-1 (floor is relative to entry, not market) and L-1 (fixed window) are accepted and documented.

No owner, no upgrade path, no funds kept between calls.

## Layout

- `src/GuardedSwap.sol` — the contract (Solidity 0.8.26, EVM cancun, no imports)
- `test/GuardedSwap.t.sol` — unit tests against a mock router and token, including fuzzing
- `test/Fork.t.sol` — Base mainnet fork tests against the live Kyber router using real router calldata (`test/fixtures.json`)
- `test/Mocks.sol` — mock token (optional fee-on-transfer) and mock router (configurable payee, re-entrancy)

## Running

```
forge build
forge test --no-match-contract Fork --fuzz-runs 2000
forge test --match-contract Fork --fork-url <base mainnet rpc>
```

Fixtures in `test/fixtures.json` are Kyber `route/build` responses for ETH→USDC (0.0005 ETH), USDC→ETH (1 USDC) and ETH→USDC paid to a foreign recipient. They carry a deadline; rebuild them if the fork tests report an expired route.

## Deployment on Base (live)

| | |
| --- | --- |
| GuardedSwap v11 (current) | `0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a` |
| Deploy tx | `0x038960227c7be178e3bce4f5701f68abac17e40590c9222207a2e7410a77201c` (block 52789806, 19 Oct 2026) |
| Executor (pinned) | `0x8F10B468b06c6FD214B65F87778827F7D113f996` (Kyber aggregation executor) |
| Previous | v10 `0x72ac1cd4b96988b14b0a55b5bf962ba3eb314a39` (round-9 subject), v9 `0x2ea0ed9b4eaf9e6c17231e10d56531ce77faef50` (round 8), v8 `0x061c0a41bb8d83e6fecc3142f3801fed9e5b88d4` (round 7), v7 `0xb1ef2b0c04e65b22e70bc6a54ddf454259d726e4` (round 6), v6 `0x259f17ed184ff97730407002140bcd512dca7a0a` (round 5), v5 `0x3511a33478465d2f6fd5ebfebf52160ef39ec7a1` (round 4), v4 `0x970b033ab9965ce9c9f92584b529afa6100a994e` (round 3), v3 `0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485` (round 2), v2 `0x91b51882805051b83efc53e7407a01894d341ca0` (round 1) |
| Router | `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2) |
| Guardian (pause only) | `0x5550C8E49616C15B89FdD1DaECddc493009e039B` |
| Limits | 12 sells / hour, 0.3 ETH of buys / hour, 1 ETH out of sales / hour per account |
| Source verification | Sourcify exact match: https://sourcify.dev/server/v2/contract/8453/0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a |

## Views

`floorFor` / `slowFloorFor` quote the lowest ETH a fast / announced sale of `amount` would accept, and `lotOf` returns the lot — all on the lot as the next call will reconcile it with the account's balance (`basis` is the raw record).

## Constructor

`constructor(address router, address executor, address guardian, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour, uint256 maxSellEthPerHour)`

Production: router `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2), guardian = the operator's pause key, limits 12, 0.3 ether and 1 ether.
