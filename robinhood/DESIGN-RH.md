# GuardedSwapRH — the v15 gate on Robinhood Chain (v3, round-2 response; not deployed)

**What it is.** GuardedSwap v15 (Dispatch, Base, `0x2c894b3a726b49d9e68e71d548157964e5e0fbb6`) ported to the AlphaCatch engine on Robinhood Chain (chain id 4663). The client's MetaMask smart account lets the executor call this gate instead of the Robinhood router `0x65050a9b7e5075a2ba5ced7b1b64ee66262c40dc`. Source: `src/GuardedSwapRH.sol`. Nothing has been deployed. Audit log: `AUDIT-RH.md`.

## Router facts (verified on chain, 22.10.2026, fork block 94 996 000)

Evidence: `test/research/RouterProbe.t.sol` (17 probes, `forge test --match-path 'test/research/*' -vvvv` prints every call), `test/Fork.t.sol`, and two real AlphaCatch trades: buy IDM `0x29dbd0d624fae3e82923ca9fdc7741a35e38e19df1ea1e1bfb8e079f30c42ebe`, sell GENIE `0x703cdfa3358444989f20dbd26ac927ec586962fa02e419e77183c27669923c33`.

| Question | Answer | Evidence |
| --- | --- | --- |
| What is it | OZ TransparentUpgradeableProxy (753 B). Implementation `0xe344e5923cb935cd559477d1199ad396e3dc7d29` (23 487 B, unverified — no source on Blockscout). ProxyAdmin `0x75fc5cd1794921e617d97e4afa2ff93613413be3`, owned by EOA `0x0C628d6535B781f6c703AD319aF8B1bCeC63FbB4` (nonce 3056), which also is `owner()` of the router (can `pause()`). **39 upgrades**; the last at block 89 860 705 (tx `0xd1f254006de6375cd72cca9ecf174b36b77fe6c46cbe477acee90bbb8af74fcb`). Revert strings call it "SwapX". | EIP-1967 slots; `Upgraded` logs on the proxy |
| Signature | `swap((uint8 version,address tokenIn,address tokenOut,address pool,uint24 fee,int24 tickSpacing,address hooks,bytes hookData,address poolManager,bytes32)[] hops, address recipient, uint256 amountIn, uint256 minOut, uint256 deadline)` = `0x4d819a2a` | selector DB + traces |
| Who receives | Always `msg.sender`. `recipient` must be zero: any non-zero value (a third party, or the caller itself) reverts `BAD_ARGS`. v3 pools are told `recipient = msg.sender` on a buy; v4 output is `take`n to `msg.sender`. | P1, P2, P16; `test_fork_router_refuses_a_recipient` |
| ETH in | The router spends **all of `msg.value`**, not `amountIn` (0.02 ETH sent with amountIn 0.01 bought twice as much; 0.005 sent with amountIn 0.01 also went through). No change is returned. It wraps 99% to WETH and unwraps for native v4 pools. | P3; IDM trace |
| ETH out | A sale ending in WETH **or** native is paid in **native ETH** to `msg.sender`; WETH balance of the caller stays 0. | P4, P11–P14 |
| Fee | 1% (`feeRate 100 / feeDenominator 10000`), in native ETH, to `feeCollector` EOA `0xE3ED4c49c9807367784ab0d0d087d8A6815E7427`: on a buy taken from `msg.value` up front, on a sale from the ETH output. `FeeCollected` event. `feeExcludeList(address)` exists (owner-managed). | traces; FeeCollected in both real txs |
| Pulling | `transferFrom(msg.sender, pool)` inside the v3 callback; `transferFrom(msg.sender, PoolManager)` + `settle` on v4. A plain ERC20 allowance to the router; above-allowance sale reverts `0x13be252b`. Exact allowances end at 0. | P4, P15, GENIE tx |
| Leftovers | None found: after 1-, 2- and 3-hop round trips the router held 0 ETH, 0 WETH and 0 of every intermediate token. | P11–P14 |
| Versions | 1 = v3-style pool, 2 = Uniswap v4. 0, 3, 5 dispatch to other libraries and revert on our data; **4 is a Virtuals path** (`VirtualsV4Lib: WRONG TOKENOUT`). | P9 |
| v3 pool address | The router **calls whatever `pool` it is given**, but pays only through its callback, which (a) reads `factory()` from the calling pool, (b) refuses a factory outside its own list (`SwapX: Invalid pool`) and (c) recomputes the CREATE2 address (`CallbackValidation: sender is not the pool`). Factories it accepts: Uniswap v3 `0x1f7d…2EfA`, Pancake v3 `0x0BFb…1865`, CL `0xE0c4…54A8`, CL `0x1ac9…B7F3`. A fake pool that names a fake or a real factory cannot get paid; a direct callback call against a victim allowance fails. A fake pool *can* report fake deltas: the router then tries to send that many wei of ETH it does not hold (`SwapX: send ETH out error`). | P6, P7, P8, P10, P16 |
| v3 key field | The v3 callback check keys on `fee` alone: any `tickSpacing` (0, 1, 60, 200, −7) passes on a fee-keyed Uniswap pool and on a tick-keyed CL pool; every wrong `fee` fails `CallbackValidation`. On tick-keyed factories `fee` carries the tick spacing (PONS: 50; the pool's live dynamic fee 1300 fails). | P17 |
| v4 fields | The router uses **its own** `V4_POOL_MANAGER` (`0x8366…0951`); the hop's `poolManager` field is ignored (a foreign address still swapped on the real PM). An uninitialised PoolKey reverts `PoolNotInitialized()`. Hooks are called by the PoolManager and can take part of the output (the live hook `0xe5e7…e044` takes ~3%). | P9; SGT round trip |
| Multi-hop | Works for v3→v3→v4 (QUBIT), v3→CL (PONS), 2×CL (1ac9 then E0c4). A broken chain reverts inside the router. | P11, P13, Fork |
| Deadline | `0` accepted, past reverts `Transaction too old`, `block.timestamp` accepted. | P9 |

## What is the same as v15

Everything that is not the route: loss budget (30% of cost basis, `Loss{amount, at}` fading over 7 days, booking more resets the clock), lots (`_trim`, `_trimmed`, `_settle`, rounding), hourly limits, guardian (pause buys and sells ≤ 7 days, 1-day cooldown, two-step rotation), cold key (`unlock` by `msg.sender`, `exit` by `tx.origin`, `replaceGuardian`), tolerant balance reads, per-call deltas, state final before ETH leaves, lock, no direct ETH, exact approve + best-effort reset, events, errors, views (`lotOf`, `budgetOf`, `floorFor`, `basis`, `loss`, `window`). Those functions are copied verbatim, so rounds 1–14 transfer to them.

## What changed and why

| v15 (Kyber) | RH | Why |
| --- | --- | --- |
| `routerData` (opaque calldata) decoded and checked | `Hop[]` (7 fields) checked, router call **encoded by the gate** | The executor can no longer name a recipient, a fee receiver, a flag, hook data or a PoolManager: those fields do not exist in its input. Removes the whole class of rounds 2/3/7 (srcReceivers, flags, simple mode). |
| `EXECUTOR` pinned | `WETH`, `POOL_MANAGER` pinned; constructor checks they equal the router's own `WETH()` / `V4_POOL_MANAGER()` | No executor in this router. |
| buy may pay the account directly | buy is always paid to the gate and swept to the account (measured on the account, as v15) | Router pays only `msg.sender`. |
| — | v3 hop: `pool` must equal `getPool(tokenIn, tokenOut, key)` of one of ≤ 4 immutable factories (fee- or tick-keyed); the gate asks the factory, never the pool | The router itself would call any address; fake pools are refused before the router is reached. |
| — | route rule: 1..3 hops, versions 1/2 only, buy ETH-side→token, sale token→ETH-side, contiguous, no intermediate ETH side or traded token, v3 never native, v4 names no pool | Fail closed on everything the router dispatches elsewhere (version 4 = Virtuals). |
| sales counted per hour | buys counted per hour too (`MAX_BUYS_PER_HOUR`, v3, round 2 H-2) | Tiny buys cannot multiply router calls. |
| loss charged at floor(cost) | charged at ceil(cost), lot released at floor (v3, round 2 L-1) | A loss is never under-booked; the remainder's cost never zeroes. |
| — | no WETH may arrive on the gate in any router call (v2: one check at the single call site, buys and sales) | The router pays native (verified); WETH arriving would be stranded. |
| executor's v3 `tickSpacing` forwarded (v1) | v3 hops are encoded with `tickSpacing 0`, `hooks 0` (v2, round 1 F-2) | The router keys on `fee`, which the gate checks; no unchecked v3 field reaches the router. |
| partial fill swept back to the account; `approve(0)` best-effort | a sale must consume exactly what the gate received, else `PartialFill` (v2, round 1 F-4) | A full fill spends the exact allowance whatever `approve(0)` does; the sale-side sweep is gone. Cost: a partially filled route reverts; sales are sized to the route. |

## Attack surface specific to this router

1. **Permissionless genuine sinks.** Anyone can create a real Uniswap v3 pool (or a v4 pool with any hook) at a ruinous price; the factory check passes. `test_fork_genuine_sink_pool_is_bounded_by_the_loss_budget` does exactly this on the live factory: the full lot is refused (`BudgetExceeded`), a fifth goes through (loss 0.002 of a 0.003 budget), the next fifth is refused. Same residual as Kyber's srcReceivers, bounded the same way; ends when the watcher pauses.
2. **Malicious v4 hooks** — same class as 1 (hook takes the delta), plus reentrancy into the gate (blocked by the lock) and ETH donations during a call (only ever reduce cost or raise proceeds of the account).
3. **Upgradeable, frequently upgraded router behind one hot EOA.** Nothing in the gate trusts it: exact allowance, output measured here and on the account, minOut. Worst case is denial of service, including `exit()` (then the owner sells from the wallet — through the same router, or directly on a pool). The watcher should alert on `Upgraded(address)` from the proxy and re-run the fork suite on the new implementation.
4. **Router pause** (`owner` = the same EOA) stops every buy, sale and exit through the gate.
5. **1% fee** is part of the price: a round trip costs ~2% + pool fees + hook fees (fork: 0.9606 of 0.01 back on BONER, 0.9222 on SGT through a 3% hook). This is booked as a loss on every losing round trip — the budget is cost-based exactly as in v15.
6. **Intermediate tokens are unconstrained** (USDG, stock tokens, anything). A thief can route through his own token; it is the same sink class (1).

## Open questions for the owner

1. Pancake v3 (`0x0BFb…1865`) is accepted by the router's callback check, but no AlphaCatch route uses it and no test exercised a real Pancake pool; left out of the factory list until one is verified. Add later = new deployment (factories are immutable).
2. Guardian key for RH: reuse Dispatch's pause key `0x5550C8E49616C15B89FdD1DaECddc493009e039B` (EOA on RH, 0 ETH) or a separate key on the RH watcher host?
3. Ask SwapX (router owner) to put the gate on `feeExcludeList`? Saves 1% per trade; unverified that they would.
4. The cold key `0xe90E76A6e5AC772193826218821D89e0aB0CEaBD` is an EOA on RH; it held 0 ETH at block 94 996 000 and 0.0012 ETH at block 95 060 000 — enough for a few calls; an evacuation of many accounts needs more gas there.
5. Re-signing: the current `swap` delegations target the router directly and the `approve` caveat pins spender = router. They must be replaced (target = gate, selectors `buy`/`sell`, value cap; approve spender = gate) and the old ones revoked or left to expire — otherwise a stolen key bypasses the gate. Plus an exit delegation to the cold key (`exit` + `approve(gate)`).
6. Delegation ceiling (round 1 F-1): the `buy`/`sell` delegation should carry a `nativeTokenPeriodTransfer` caveat — proposed 0.15 ETH per 24 h (24 buys × the largest ticket in use) — as Dispatch's carries 0.5 ETH per 24 h. It is the overall bound on buys the contract cannot set without a price.
7. Guardian incident step (round 1 F-3): after `replaceGuardian`, the new guardian's first transaction is `setPaused(false)` once the incident is over; the cold key cannot unpause by design.
8. The engine's own round-trip honeypot check and slippage stay; the engine must start passing `minOut` from its simulation (it does today) and build `Hop[]` (it already has the same fields in `route.mjs`).

## Proposed deployment parameters

| | |
| --- | --- |
| router | `0x65050a9b7e5075a2ba5ced7b1b64ee66262c40dc` |
| weth | `0x0bd7d308f8e1639fab988df18a8011f41eacad73` (checked against `router.WETH()`) |
| poolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` (checked against `router.V4_POOL_MANAGER()`) |
| v3 factories | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` (fee-keyed, Uniswap v3), `0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8` (tick-keyed), `0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3` (tick-keyed) — all three round-tripped on the fork |
| guardian | open question 2 |
| exit key | `0xe90E76A6e5AC772193826218821D89e0aB0CEaBD` (same cold key as Dispatch; EOA on RH, needs gas) |
| limits | constructor `(…, 24 sales / h, 12 buys / h, 0.05 ETH of buys / h, 0.5 ETH out of sales / h)` per account; delegation 0.15 ETH of buys / 24 h (`nativeTokenPeriodTransfer`). Measured on the owner's account: peak 3 buys and 0.048 ETH of buys in an hour. Measured on the owner's account over 308 h (300 trades): peak 3 buys / 0.048 ETH in an hour, peak 20 sales in an hour (a manual stop selling every position), 0.031 ETH out. 12 sales/h (Dispatch) would block a full manual stop. |

## Tests

`forge test --no-match-path 'test/research/*'` — 48 unit tests (v15's suite ported with the same scenarios and numbers, plus route/encoding/factory/WETH tests, the round-1 and round-2 regressions and the cold-key EOA/EIP-7702 paths), 7 invariants over 256 runs × 500 calls (cost basis = lot; lot ≤ balance; outstanding ≤ booked and gone within REFILL; **a booked loss never exceeds the budget**; **proceeds only to the account, the thief and the gate get nothing, no allowance left**; **no lot/cost underflow**; the handler mixes in partial fills, exits, owner transfers and a router that pays a thief), 10 fork tests against the live router at the chain head (the public RPC keeps little history; `RH_BLOCK` pins a block). Mutation check: doubling the budget, or skimming 1% of proceeds, each make the corresponding invariant fail.
