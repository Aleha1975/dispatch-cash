# GuardedSwap

A one-purpose, immutable gate between a client's MetaMask smart account and the KyberSwap aggregator router on Base (chain id 8453).

The client grants its trading executor the right to call this contract instead of the router. Whatever a swap returns goes to the calling account and nobody else: there is no recipient parameter.

## Rules

1. **Recipient.** All swap output, change and unsold input are swept to `msg.sender`. Output is measured as the caller's balance change and must be at least `minOut` (> 0).
2. **Price floor.** `buy()` records ETH paid and tokens received per (account, token). `sell()` refuses to return less than 50% (`FLOOR_BPS`) of the recorded entry price for the tokens it knows.
3. **Slow path.** A sale below the floor, or of tokens never bought through the contract, requires `announce(token)` at least 1 hour earlier (`SLOW_DELAY`). One announcement allows one such sale and emits `SlowSaleArmed`.
4. **Rate limit.** Per account and rolling hour: at most `MAX_SELLS_PER_HOUR` sales and `MAX_BUY_ETH_PER_HOUR` of ETH spent on buys (deployment parameters; production 12 and 0.3 ETH).
5. **Pause.** `GUARDIAN` can pause and unpause `buy`, `sell` and `announce`. It has no other power and cannot move funds. Client withdrawals never pass through this contract.

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
| GuardedSwap | `0x91b51882805051b83efc53e7407a01894d341ca0` |
| Deploy tx | `0xaa8b9b7c1f24d18b4a921bf8e3f3b600eb82f52aa16490ba671a6b52f2c038af` (block 52764815, 18 Oct 2026) |
| Router | `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2) |
| Guardian (pause only) | `0x5550C8E49616C15B89FdD1DaECddc493009e039B` |
| Limits | 12 sells / hour, 0.3 ETH of buys / hour per account |
| Source verification | Sourcify exact match: https://sourcify.dev/server/v2/contract/8453/0x91b51882805051b83efc53e7407a01894d341ca0 |

## Constructor

`constructor(address router, address guardian, uint256 maxSellsPerHour, uint256 maxBuyEthPerHour)`

Production: router `0x6131b5fae19ea4f9d964eac0408e4408b66337b5` (KyberSwap MetaAggregationRouterV2), guardian = the operator's pause key, limits 12 and 0.3 ether.
