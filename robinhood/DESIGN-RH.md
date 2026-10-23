# GuardedSwapRH — v5: the gate swaps against the pools itself (not deployed)

**What it is.** The AlphaCatch gate on Robinhood Chain (chain id 4663) between a client's MetaMask smart account and the market. v1–v4 called the Robinhood "SwapX" router `0x65050a9b7e5075a2ba5ced7b1b64ee66262c40dc`; v5 calls no router at all: a Uniswap-v3-style pool is swapped through `pool.swap` and the gate's own swap callback, a Uniswap v4 pool through the PoolManager's `unlock` / `swap` / `settle` / `take`. The executor still names structured hops; the gate checks them and makes every call itself. Source: `src/GuardedSwapRH.sol`. Audit log: `AUDIT-RH.md`. Nothing is deployed.

## Why the router goes

| | v4 (router) | v5 (pools) |
| --- | --- | --- |
| Fee | 1% of every swap in, 1% out, to the router's fee collector (`FeeCollected`) | none beyond the pools' own fees |
| Round trip, measured on a fork at the chain head (0.01 ETH ticket, same block, same pools) | BONER 3.94%, SGT 7.78%, QUBIT 5.02%, PONS 2.17%, NVDA 2.11%, TSLA 2.60% | BONER 1.99%, SGT 5.91%, QUBIT 3.09%, PONS 0.18%, NVDA 0.12%, TSLA 0.62% |
| Trust | an upgradeable proxy (39 upgrades) whose admin and owner is one EOA; it can pause or deny service, including `exit()` | the pinned PoolManager (immutable Uniswap v4 core) and pools that an allowed factory created |
| Allowance | an exact ERC-20 allowance to the router on every sale | none, ever: the gate pays pools by `transfer` inside their callback / before `settle` |
| Code paths reached | the router's dispatcher (versions 0–5, Virtuals path, fee logic) | `pool.swap`, `PoolManager.unlock/swap/sync/settle/take`, `WETH.deposit/withdraw` |

## Pool facts (verified on chain, 23.10.2026, block ~96.1M)

Evidence: `test/Fork.t.sol` (13 tests against the live chain head).

| Question | Answer |
| --- | --- |
| v3 pools | Uniswap v3 factory `0x1f7d…2EfA` (keyed by fee) and the tick-keyed CL factories `0xE0c4…54A8`, `0x1ac9…B7F3` (keyed by tick spacing). All three create pools with the Uniswap v3 interface: `swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data)` and a `uniswapV3SwapCallback` to the caller. Round trips through all three pass on the fork. |
| v4 | PoolManager `0x8366…0951` speaks the standard v4-core interface (`unlock`, `swap(PoolKey,SwapParams,bytes)`, `sync`, `settle`, `take`); native ETH is currency `address(0)`. |
| Stocks | Tokenized stocks are quoted in USDG. NVDA/USDG Uniswap v3 0.05% `0xd4EB…a3` (≈ 570k USDG of depth), TSLA/USDG 0.3% `0xf4AC…E3` (≈ 322k USDG). WETH/USDG 0.01% `0x52e6…71Ca` (≈ 6 128 WETH). Route WETH → USDG → stock: 0.12% (NVDA) and 0.62% (TSLA) for a round trip. |
| v4 hooks (census of all 1 066 892 v4 pools) | 700 933 have no hook. 709 929 (66.5%) have no swap-time return-delta permission (bits 2/3 of the hook address). The largest return-delta hooks: `0x4e34…a544` (217 728 pools; the launchpad hook, dynamic fee, `afterSwapReturnDelta`), `0x48b8…e8cc` (15 346), `0xe5e7…e044` (10 415; takes ≈ 3%). Of the last ~2M blocks' 12 615 new pools: 7 891 hookless, 2 969 on `0x4e34`. AlphaCatch's own history (300 trades): 35 hookless v4/v3 routes, 20 on `0xe5e7`, 3 on `0x4e34`, 9 on other hooks. |
| Gas | A gate round trip costs ≈ 0.66–1.0 M gas (2.6 M for the 3-hop QUBIT route); the router round trip ≈ 0.55–0.86 M. At 0.02 gwei that is ≈ 0.00002 ETH per round trip either way. |

## Rules (v5)

| Rule | What it enforces |
| --- | --- |
| Recipient | Everything a swap returns is paid to the gate, measured, and forwarded to the calling account (a buy: the token, measured on the account; a sale: native ETH, after state is final). There is no recipient parameter. |
| Route | 1–3 hops; a buy starts at the ETH side (native or WETH) and ends at the token, a sale the reverse; contiguous; no intermediate ETH side or traded token; versions 1 (v3 pool) and 2 (v4 PoolKey) only. |
| v3 hop | The pool must be what an allowed factory returns for `(tokenIn, tokenOut, key)` — the factory is asked, the pool never. The gate stores the expected pool, the input token and the hop's input in transient storage; the callback pays only that pool, once, only the input token, at most the input. |
| v4 hop | No pool address; the PoolKey goes to the pinned PoolManager. The callback runs only for the PoolManager during the gate's own unlock (transient flag). The swap is exact-input with no hook data; the PoolManager's answer must be exactly "the input owed in full, a positive output", then the gate settles the input and takes the output. |
| Hooks | A v4 hook passes when it is zero, when its address grants no swap-time return-delta permission (`BEFORE_SWAP_RETURNS_DELTA`, `AFTER_SWAP_RETURNS_DELTA`: the PoolManager then never lets it take part of the swap), or when it is one of at most four hooks fixed at deployment (proposed: `0xe5e7…e044`, `0x4e34…a544`, both round-tripped on the fork). |
| Full fill | Every hop must consume exactly its input; nothing of a route can stay on the gate; no WETH may remain; a sale must swap all it pulled. |
| Loss budget | As Base v16: losses must stay within 30% of the account's value at cost — native ETH plus open lots — read once when the sale starts, fading over 7 days from the last booking. |
| Lots, limits, pause, cold key, deadline | Unchanged from v4 (v15 lineage): only the lot is for sale; per-account hourly caps on sales, buys, ETH into buys and ETH out of sales; the guardian pauses the executor ≤ 7 days with a day's cooldown; the cold key unlocks, replaces the guardian and exits (outside the budget and the caps, never paused); every trade carries a deadline. |

### Why this hook rule

A pool's hook runs code inside the swap. What it can do to the gate is limited by the rules above regardless of the hook: it cannot re-enter (lock), cannot call either callback (transient flags and caller checks), cannot make the gate owe more than the hop's input or take less than a positive output (exact delta check), and cannot reach any allowance (there is none). What a hook *can* do is take value through the price — a dynamic fee, or, with a return-delta permission, part of the input or output. That is the same class as a genuine pool at a bad price, which anyone can open on any factory and which no rule can exclude; it is bounded by `minOut` for honest trades and by the loss budget for a stolen key. The rule therefore does not claim to make hooks safe; it shrinks the surface to hooks that either cannot take part of a swap at all, or that were reviewed and fork-tested before deployment. A new launchpad hook is a new deployment.

Alternatives considered: (a) hookless pools only — refuses 23 of AlphaCatch's 58 historical v4 routes and most new meme pools; (b) any hook — admits arbitrary return-delta code the engine's simulation cannot be trusted to predict (a hook can behave differently on the real transaction); (c) an allow-list the cold key can extend — a new power for the cold key, against the v15 principle that it has none beyond unlock, exit and replaceGuardian.

## Attack surface

1. **Genuine sinks** (unchanged): a real v3 pool or v4 pool (any allowed hook) at a ruinous price. Bounded by `minOut` and the loss budget; `test_fork_genuine_sink_pool_is_bounded_by_the_loss_budget` measures it on the live factory.
2. **Factory pools are trusted to be pool code.** Uniswap's factory deploys fixed pool code. The `0x1ac9` factory deploys EIP-1167 clones of a fixed implementation (`0x1172…9dc3`, verified from a pool's runtime); the `0xE0c4` factory deploys full pool code and is not a proxy (EIP-1967 slot empty). A factory owner able to register a hostile pool could make it ask for its input and pay little: the gate pays at most the hop's input, needs a positive output, and the trade then fails `minOut` (honest) or is bounded by the budget (thief) — the sink class of item 1.
3. **Fee-on-transfer tokens** cannot be paid into a pool in full; their sales revert and are made from the wallet (unchanged class; was the same through the router).
4. **The PoolManager** is trusted as immutable infrastructure (v4 core has no upgrade path); its owner can only set protocol fees (≤ 0.1% by the v4-core cap).
5. **Gas.** Direct swaps cost more gas inside the gate than a bare router call (the gate measures every hop), less than v4's gate-plus-router. At current RH gas prices it is ≈ 0.00002 ETH per round trip.

## Tests

`forge test --no-match-path 'test/research/*'` — 51 unit tests (v4's suite ported, budget numbers on the v16 base, new: pool calls made by the gate, v3 and v4 callback rules, hook rule, WETH-quoted v4 pools, a partial middle hop, ETH sent mid-buy, the 23 Oct case, a withdrawal shrinks the budget, a burst books at most 30%/1.3), 11 invariants over 256 runs × 500 calls in two suites (cost basis = lots; lot ≤ balance; outstanding loss within booked and gone within REFILL; a booked loss never exceeds its budget; proceeds only to the account, nothing to a thief, nothing left on the gate, no allowance; no underflow; a thief's burst with no time passing books ≤ 30% of the largest base; nothing leaves the account but booked losses; buys leave the base unchanged), 13 fork tests at the chain head (meme v3, meme v4 hooked native, 3 hops v3→v3→v4 with the launchpad hook, both CL factories, NVDA and TSLA via USDG at three ticket sizes, cold-key exit under pause, fake / wrong pools, callbacks from outside, limits, the genuine sink). Mutation checks: doubling the budget fails 8 tests; the v4 base fails 4; dropping the callback's caller check fails 2, its cap 2; the PoolManager caller check 4; the hook rule 2; the factory check 6; the per-hop full-fill check 1; skimming 1% of proceeds 6.

## Proposed deployment parameters

| | |
| --- | --- |
| weth | `0x0bd7d308f8e1639fab988df18a8011f41eacad73` |
| poolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| v3 factories | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` (fee-keyed), `0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8` (tick-keyed), `0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3` (tick-keyed) |
| hooks | `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044`, `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544` |
| guardian | the RH watcher's pause key |
| exit key | `0xe90E76A6e5AC772193826218821D89e0aB0CEaBD` (EOA; needs gas on RH) |
| limits | 24 sales / h, 12 buys / h, 0.05 ETH of buys / h, 0.5 ETH out of sales / h per account; delegation 0.15 ETH of buys / 24 h |
