# GuardedSwap

A one-purpose, immutable gate between a client's MetaMask smart account and the KyberSwap aggregator router on Base (chain id 8453).

The client grants its trading executor the right to call this contract instead of the router. Whatever a swap returns goes to the calling account and nobody else: there is no recipient parameter.

## Rules

1. **Recipient.** All swap output, change and unsold input are swept to `msg.sender`. Output is measured as the caller's balance change and must be at least `minOut` (> 0).
2. **Route check.** The router calldata (`swap` or `swapSimpleMode`) is decoded on-chain: the executor (`callTarget` / simple-mode caller) must be `EXECUTOR`, `approveTarget` zero or `EXECUTOR`, `dstReceiver` the caller or this contract, no fee receivers, `srcToken`/`dstToken` the declared pair, `amount` the declared amount, the router's `minReturnAmount` at least our `minOut`; a buy may not name any `srcReceivers`, a sale's `srcReceivers` must be contracts other than the caller with amounts summing to at most the input. Anything else reverts `BadRoute`.
7. **Per-call accounting.** Token and ETH balances are measured as deltas around the router call; anything sent to the contract outside a call is neither swept, nor counted, nor recoverable (direct ETH is refused). A repeat buy may not dilute the recorded entry price below half (`DilutesBasis`).
3. **Price floor.** `buy()` records ETH paid and tokens received per (account, token). `sell()` refuses to return less than 50% (`FLOOR_BPS`) of the recorded entry price; selling more than the recorded basis takes the slow path for the whole sale.
4. **Slow path.** A sale below the floor, or beyond the recorded basis, requires `announce(token, amount)` at least 1 hour earlier (`SLOW_DELAY`), covers up to that amount and expires 24 hours after the delay (`ANNOUNCE_TTL`). One announcement allows one such sale and emits `SlowSaleArmed`.
5. **Rate limit.** Per account and fixed hour window: at most `MAX_SELLS_PER_HOUR` sales and `MAX_BUY_ETH_PER_HOUR` of ETH spent on buys (deployment parameters; production 12 and 0.3 ETH). A burst at the window edge can reach twice the limit across two windows.
6. **Pause.** The guardian can pause buys; under a pause every sale takes the announced slow path, so a pause can delay an exit by an hour but never block it. The guardian is rotated in two steps (`proposeGuardian` / `acceptGuardian`), has no other power and cannot move funds. Client withdrawals never pass through this contract. Announcements can be cancelled by the account and are consumed partially.

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
| GuardedSwap v4 (current) | `0x970b033ab9965ce9c9f92584b529afa6100a994e` |
| Deploy tx | `0x196953e5ebc431b4c77763d33808f9195a612e1c118b44d1855c433f94df0d64` (block 52770426, 18 Oct 2026) |
| Executor (pinned) | `0x8F10B468b06c6FD214B65F87778827F7D113f996` (Kyber aggregation executor) |
| Previous | v3 `0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485` (round-2 subject), v2 `0x91b51882805051b83efc53e7407a01894d341ca0` (round-1 subject) |
| Router | `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2) |
| Guardian (pause only) | `0x5550C8E49616C15B89FdD1DaECddc493009e039B` |
| Limits | 12 sells / hour, 0.3 ETH of buys / hour per account |
| Source verification | Sourcify exact match: https://sourcify.dev/server/v2/contract/8453/0x970b033ab9965ce9c9f92584b529afa6100a994e |

## Constructor

`constructor(address router, address executor, address guardian, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour)`

Production: router `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2), guardian = the operator's pause key, limits 12 and 0.3 ether.
