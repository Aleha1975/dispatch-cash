# Elysium LP Smart Accounts — Security Audit, round 3 (verification of the round-2 root-cause fixes and the flow-booking design)

**Job:** leftclaw 1227 · **Date:** 2026-11-14 · **Auditor:** automated multi-agent pipeline (deep-audit v3)

**Repo:** https://github.com/Aleha1975/dispatch-cash · branch `elysium-lp-sa` · commit `ecb6edaeb5dfae50adb6da2897dbce837e068a15` (verified reachable: `git ls-remote` returns this hash for `refs/heads/elysium-lp-sa`)

**Scope (as the client stated it):** `src/sa/LPManagerModule.sol`, `src/sa/SABook.sol`, `src/sa/SALib.sol`, `src/sa/SwapExecutor.sol`, `src/sa/SAWindow.sol`, `src/sa/ElysiumCustodyEnforcer.sol`, `src/sa/vendor/DelegationFramework.sol`, `script/DeploySA.s.sol`, `src/V4PositionMath.sol`, `src/VaultTimelock.sol` (2,094 nSLOC). The keeper (`keeper/elysium_keeper/sa_chain.py`, `sa_keeper.py`) was read as a requested lens. The pooled vault is out of scope. Not deployed.

**Severity counts:** 0 Critical · 0 High · 8 Medium · 27 Low · 18 Informational

---

## The short version

The round-2 fixes close the round-2 PoCs as written. The new design does what it says for the paths it was built for: after a trusted sync, `profit` depends only on the snapshot (previous snapshot plus the module's computed effects) valued at the anchor, so a skipped or altered LP execution, a skim, or a move of slot0 inside a bracket cannot change it.

The central claim is still false in four places, and the bounded-keeper fee bound is much weaker than the response states:

1. **`sync` and `value` are not the same function.** `value` counts uncollected LP fees, `sync` does not. A client who collects the fees of a tracked position directly removes all LP fee income from the fee base (M-1). Twelve of twelve blind attack agents and five checklist agents found this independently. The client acknowledged it as I-2 "bounded by fee income since the last keeper touch"; the bound is the whole fee income.
2. **The swap is booked from a record that is not bound to the module's swap.** An upgraded account can substitute its own swap (any size, any price, either direction) and have its loss booked as a trading result (M-2).
3. **One price at booking does not mean one price over the life of the flow.** A flow is booked at the anchor, which may sit a full band from the pool (M-4), at a moment the keeper chooses (M-5), and the fee then measures it at `min(V(anchor), V(pool))` (M-6). Each of the three moves profit with no real gain or loss.
4. **`_trusted()` reads the pool at one instant.** `minPriceStable` constrains the anchor value only. A keeper that pushes the pool inside its own `reportPrice` and `chargeFee` transactions charges a fee on up to the 24 h drift budget of base exposure (about 1.6 % of exposure per fee at the defaults), not the 0.11 % in the response (M-3).

No finding lets anyone move client funds to an address outside the enforcer's list. No Critical or High was found: every Medium is a fee-base error (the operator loses fee income, or a bounded keeper over-charges a fee) or a liveness problem.

---

## How to read this report

- **Severity** is what the issue costs if it is real. **Confidence** (0–100) is how sure we are that it is real. They are separate fields on every finding.
- **Origin tags**: `[phase1: <checklist>]`, `[phase2: agent N]`, or `[both]`.
- Line numbers were checked against the files at the pinned commit. `M:` / `L:` / `B:` abbreviations in the round-2 table are `LPManagerModule.sol` / `SALib.sol` / `SABook.sol`.
- Dollar figures use the client's default parameters (`feeBps` 1500, `poolBandBps` 150, `maxSlippageBps` 150, `refDriftBps` 1000, `maxPriceAge` 3600, `minPriceStable` 300) unless stated.

### What ran

| Phase | What | Agents | Result |
|---|---|---|---|
| 0a | x-ray pre-scan (enumeration, grep-verified entry points, invariant synthesis, git analysis) | orchestrator + 1 doc-extraction helper | 31 declared entry points, 30 guards, 27 inferred invariants (9 not enforced on-chain) |
| 0 | context: access-control inventory, protocol map, external surface (v4, Permit2, OZ read from `lib/`) | 3 | 36 entry points incl. inherited, 16 threat rows, 12 fragility clusters |
| 1 | breadth: 8 checklist agents (general + DoS, precision-math, AMM + flash loans, account abstraction + proxies, signatures + ERC-20, oracles, access control + governance, chain-specific + assembly) | 8 | 95 raw findings before dedup |
| 1 (extra) | fix verification of every round-2 finding; keeper lens + Delegation Framework v1.3.0 from fixture bytecode | 2 | status table below; 19 keeper / framework items |
| 2 | depth: 12 blind attack agents (math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, trust-gap, flow-gap), no phase-1 output | 12 of 12 returned | 5 findings, 14 leads after dedup and gate |
| 3 | reconciliation, re-read of phase-unique findings, coverage gate | orchestrator | this report |

### Coverage caveats — read these

- **No target code was executed.** The client asked us to build and run the Foundry suites "if policy allows". Our audit policy disables target-code execution (build scripts, ffi and test hooks run inside an environment that holds job credentials). Every proof here is a hand trace through the source with concrete numbers; none is a passing Foundry test. The test files were read as documentation of what is covered.
- **Delegation Framework v1.3.0 source is not in the repo.** This round established its behaviour from a static disassembly of the fixture init code under `test/fixtures/delegation-framework-v1.3.0` (hook order, signature and disabled checks, pause scope, upgrade authority, ERC-1271 paths, selectors, typehashes). We could not verify that the code deployed on chain 99901 equals the fixtures; the deploy script's CREATE2 derivation is the only link.
- **The USDC implementation at `0xb47c…0B65` is not in the repo.** Permit, nonce, blacklist and upgrade behaviour are assumed to follow Circle's FiatToken where a finding depends on them, and the finding says so.
- **Pool-push costs are estimates** from "a few hundred thousand USD" of depth under two liquidity shapes.
- `SAWindow.sol` and the enforcer's `_checkModify` decoding were walked and no issue was found; they received less adversarial time than the books.
- The web front end and the relayer API were read only where they validate permits and delegations.

### Reconciliation summary

`Overlap: 13 · Phase-1-only: 40 · Phase-2-only: 0 · Re-examined leads kept: 40, demoted: 1 · Coverage holes closed: 0 · Invariants: 27 answered (19 hold, 8 violated, 0 unverified)`

Reporting floor: Low and above are findings; items with confidence below 50 are listed under Leads. Every phase-1-only finding was re-read against the source before it was kept. Four were kept with a lower severity than the agent gave: the sequencer-halt finding (Medium → Low), the multicall sandwich (Medium → Low: the shipped keeper does not batch accounts), the keeper anchor-hold item (Medium → Low: it amplifies M-4) and the dust-registration stall (Medium → Low: discovery is off by default). One phase-2 lead was demoted: "slot0 moved inside a removal" (no change of profit, see Leads). Phase 2 raised nothing that phase 1 had not also raised, but it changed the weight of two items: all twelve blind agents found M-1, and five found M-6, which phase 1 had only touched in passing.

`Coverage: 36 entrypoints, 36 addressed. 16 threat rows, 16 answered. 27 inferred invariants, 27 answered. Holes closed this pass: 0.`

---

## Answers to the client's tasks (short form)

### Task 1 — the structural flow-booking claim

| Question | Answer |
|---|---|
| 1. Is every module write to the snapshot the true effect of the module's call? | **Yes for LP adds, removals and transfers on an honest account.** The principal branch (`sp <= sa` / `sp < sb`, SABook.sol:157-164) gives the same amounts as PoolManager's tick-based branch at every boundary case; rounding is up for adds and down for removes as in `SqrtPriceMath`; the fee formula matches `Position.update`; SETTLE_PAIR / CLOSE_CURRENCY / TAKE_PAIR / SWEEP were checked against PositionManager. **No for swaps on a hostile account** (M-2) and **not verified for increases, decreases and burns** (the books assume the execution happened: L-7). |
| 2. Can account code make the computed effect differ from the real one in the client's favour? | **Yes: a substituted swap (M-2).** Moving slot0 or re-entering PositionManager only creates a pending flow and does not change profit. A skipped increase gains at most the slippage bound of that add (L-7). The transient record cannot be written from another context (only `SwapExecutor.swap`, for `msg.sender`). |
| 3. Is `sync`'s valuation the same function as `value`? | **No.** The uncollected-fee term is in `value` (SABook.sol:99-100) and not in `sync` (SABook.sol:52-63): M-1. Hedge equity is in neither side of a flow (correct). Dropped positions lose `LV + fees` in `value` and only `LV` in `sync` (same finding). Rounding differs by a few raw units per sync (I-6). Negative `int256` snapshots are handled. |
| 4. Can a flow be booked twice or never? | **Not twice.** We traced burn and decrease with snapshot above and below live liquidity, revoke and re-register, and positions dropped while pending: each flow is booked once. **Never is possible**: the keeper can keep the anchor untrusted with one-unit re-reports (M-5), and an anchor that is clipped after normal volatility stops all booking (M-7). `MAX_POSITIONS` needs a trusted sync to drop client-burned positions, as the response says. |
| 5. Can the fee exceed the client's real gain? | **Yes**, four ways: an atomic pool push at report and at fee (M-3, up to the drift budget), booking at the band edge (M-4, 0.225 % of each base flow), choosing the booking time (M-5, unbounded in price terms), and an equal hedge report that keeps lost equity "recent" (L-2). `reportPrice` + `chargeFee` in one multicall is blocked by `minPriceStable`. |
| 6. Does the one-price design open a path min/max would have closed? | **Yes: the band-edge booking in M-4** needs no capital and no pool move, and a client-favour min/max rule would close it. Min/max would not close M-3. See "Rebuttals". |

### Task 2 — sibling paths still open

| Root-cause class | Sibling still open | Finding |
|---|---|---|
| B' (books) | fee term missing from `sync`; swap record not bound to the module's swap; increase / decrease / burn not read back | M-1, M-2, L-7 |
| B' moved by the fix | a flow is now "pending", and is booked at a price and time that the keeper (or the client, by timing) selects; the module acts on funds whose flow is still pending | M-4, M-5 |
| D' (price trust) | the pool leg of `_trusted` is a same-transaction spot read; `min(V(anchor), V(pool))` conflicts with anchor booking | M-3, M-6 |
| D' as liveness | the trusted gate stops fees, margin sends, booking and hedge decreases when anyone moves the spot, when the drift window fills, and after a guardian-approved move | L-3, M-7 |
| A'' (consent) | the permit fallback accepts a consumed signature when a standing approval of the same amount exists; `onboard` pulls for an account that is no longer live | L-5, L-6 |

### Task 3 — rebuttals and residuals

Rebuttal 1 holds as a comparison and fails as a protection claim (M-4). Rebuttal 2 holds for LP actions and transfers and fails for the swap record (M-2). Rebuttal 3 holds with one narrow corner (L-5). Of the acknowledged residuals, the I-2 fee statement and the "≈ 0.11 % of exposure" keeper statement do not hold as written. Details are in "Round-2 findings — status" below.

### Task 4 — requested lenses

| Lens | Ran? | Result |
|---|---|---|
| Execute the code | **No — disabled by audit policy.** Concrete traces attached instead. | — |
| SwapExecutor (changed) | Yes | Record slot derivation, payer = `msg.sender`, unlock callback, native refund, exact-input semantics and reentrancy hold. The record lacks direction and `amountIn`: M-2. `RECORD` equals `keccak256("elysium.SwapExecutor.record")` (checked with `cast keccak`). |
| Delegation Framework v1.3.0 internals | Yes, from fixture bytecode | Hook order and the in-scope assumptions are confirmed; liveness is checked before, not during, a redemption; an upgraded hybrid stays `live` (I-16, L-1). |
| VaultTimelock | Yes | L-12, L-13, L-14, I-3. |
| DeploySA | Read, not simulated | L-16, I-5. |
| Math precision on SABook | Yes | No extractable rounding; I-6. |
| Keeper | Yes | K-1 … K-13. |

---

# Findings

## Medium

### M-1 — `sync` has no fee term: LP fees that the client collects are booked as a contribution

**Severity:** Medium · **Confidence:** 95 · **Origin:** `[both]` — phase 2 agents 1–12 (all twelve), phase 1 general, AMM, account-abstraction, fix-verification · **Location:** `SABook.sync` (src/sa/SABook.sol:52-64), `SABook.value` (src/sa/SABook.sol:96-100), `SALib.notSubscribed` (src/sa/SALib.sol:266-268) · Acknowledged by the client as I-2; worse than stated.

`value` counts the uncollected fees of every owned tracked position:

```solidity
val += V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, price, v.baseIsCurrency0) + fa
    + Math.mulDiv(fb, price, WAD);                                   // SABook.sol:99-100
```

`sync` books idle deltas and liquidity deltas only:

```solidity
int256 f = x - s.snapAsset + _mul(b - s.snapBase, price);            // SABook.sol:52
...
if (liq != old) { f += int256(liquidityValue(liq)) - int256(liquidityValue(old)); }   // SABook.sol:59-63
```

PoolManager pays the accrued fees on any modify of a position. When the client calls PositionManager directly (a zero-liquidity DECREASE plus TAKE_PAIR, or any increase or decrease), the fees move from "uncollected" to idle. `value` does not change; `sync` sees idle rise and adds the fees to `contributed`. Profit falls by exactly the fees. No hostile code is needed: the owner of a canonical hybrid, or a plain 7702 EOA, makes the call.

**Trace.** One tracked position, 100,000 USDC of liquidity value, 1,000 USDC + 50 HYPE of uncollected fees, anchor 20. `contributed` = 100,000, profit = 2,000, fee due 300.
1. Client: `modifyLiquidities([DECREASE(id, 0, 0, 0, ""), TAKE_PAIR(HYPE, USDC, account)])`. Idle +1,000 USDC +50 HYPE. `value` unchanged.
2. Keeper `chargeFee` → `_sync`: `f = 1,000e6 + 50e18 × 20e6 / 1e18 = 2,000e6`; `contributed` = 102,000.
3. Profit = 0. Fee = 0. The 300 USDC never comes back: `contributed` stays raised.

**Why the stated bound does not hold.** The response says "bounded by fee income since the last keeper touch; keeper collects before `chargeFee`". The client is always earlier in time: a collect every day (or every block) leaves the keeper's collect nothing. Two further paths remove even the race:
- The client calls `PositionManager.subscribe` on a tracked position. Every keeper path that could collect then reverts at `SALib.notSubscribed` (called at LPManagerModule.sol:423 and :775), while the position stays in `value` and the account stays live.
- The client transfers or burns the NFT: `value` loses `LV + fees`, `sync` books `-LV` only.

For a hedged LP strategy, LP fees are the profit. The fee base can be held at zero indefinitely while the account stays managed.

**Smallest fix.** Give the books their own fee checkpoint. Store PoolManager's `feeGrowthInside{0,1}Last` per tracked position whenever the module modifies it and at every sync. In `sync`, the fees paid out by a modify the module did not make are `(lastNow − lastSnap) × snapLiq / 2^128` per currency; subtract their anchor value from `f`. For a dropped position subtract its uncollected fees at the snapshot. This belongs in `SABook` (the module has 677 bytes of room).

```diff
  // SABook.sync, per tracked position, before snapLiq is overwritten
+ (, uint256 g0, uint256 g1) = v.pm.getPositionInfo(v.id, address(v.posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
+ unchecked {
+     uint256 c0 = FullMath.mulDiv(g0 - snapGrowth0[p.tokenId], old, 1 << 128);
+     uint256 c1 = FullMath.mulDiv(g1 - snapGrowth1[p.tokenId], old, 1 << 128);
+     (uint256 cb, uint256 ca) = v.baseIsCurrency0 ? (c0, c1) : (c1, c0);
+     f -= int256(ca) + _mul(int256(cb), price);
+ }
+ snapGrowth0[p.tokenId] = g0; snapGrowth1[p.tokenId] = g1;
```

Also treat a subscribed tracked position as a stop condition for the account (or drop it from `value`).

---

### M-2 — The swap is booked from an executor record that is not bound to the module's swap

**Severity:** Medium · **Confidence:** 75 · **Origin:** `[both]` — phase 1 fix-verification (substituted swap), general, AMM, account-abstraction, chain-specific (direction); phase 2 agents 4, 5, 6, 12 (direction, as leads) · **Location:** `LPManagerModule.swap` (src/sa/LPManagerModule.sol:474-483), `SwapExecutor.swap` (src/sa/SwapExecutor.sol:92-97)

The module accepts any single new record for the account and books it by the direction it asked for:

```solidity
(uint256 n1, uint256 paid, uint256 got) = x.lastSwap(a);
if (n1 != n0 + 1 || got < minOut) revert BelowMinOutOrBadSwap(got, minOut);   // LPManagerModule.sol:478
...
if (sellBase) _apply(a, go, pi);                                              // LPManagerModule.sol:482
else _apply(a, pi, go);
```

The record holds a count, `paid` and `out` (SwapExecutor.sol:94-96). It holds no direction, no `amountIn` and no limit, and the module does not check `paid <= amountIn`. The enforcer checks only the calldata the module built. An upgraded hybrid account (still `live`, because `SALib.live` compares only `owner()`, SALib.sol:220) can skip the module's call inside `executeFromExecutor` and make one `SwapExecutor.swap` of its own. Whatever that swap loses is booked as the module's trading result, not as a client flow.

**Trace A — substituted size (lowers the fee base without bound).** Anchor and pool 40. The account holds 1,000 HYPE and 100,000 USDC. Keeper: `swap(a, true, 100e18, 40e6, 0)`, so `minOut` = 3,940 USDC.
1. Inside its bracket the account sends 800 HYPE to a helper (a pending outflow).
2. The helper sells them into the pool and pushes the price down.
3. The account calls `SwapExecutor.swap{value: 170e18}(true, 170e18, 3_940e6, 0)` at about 23 and receives 3,940 USDC. Record: `(n0 + 1, 170e18, 3_940e6)`.
4. The helper buys back and returns the 800 HYPE plus its gain of about 2,800 (a pending inflow).
5. The module books −170 HYPE and +3,940 USDC: a loss of 2,860 at the anchor. The next trusted sync adds about +2,800 to `contributed`.
6. The client's wealth is unchanged apart from pool fees. Profit is down 2,860. The size is limited only by the input-side idle balance, on every keeper swap. The turnover charge and the price limit are bypassed.

**Trace B — opposite direction (wrong units).** Keeper sells 1,000 HYPE, `minOut` = 1.97e10 raw USDC. The account instead swaps 1 USDC for HYPE and receives about 5e16 wei; `5e16 >= 1.97e10` passes. The module books `snapAsset += 5e16` (50 billion USDC). This direction harms only the client. The direction that helps the client needs a keeper USDC→HYPE swap of a few raw units, which a normal keeper does not send; with a pair of equal decimals it would be reachable at normal sizes.

**Residual after the fix.** With the record bound to the call, a client can still trade against the module's own swap (push the pool inside the bracket, or before the keeper's transaction) down to the min-out floor. That loss is real for the account and a gain for the client's helper, so the fee base falls by at most `(poolBandBps + maxSlippageBps) × swap notional`, inside the turnover budget. This is the design bound; we report it so it is stated.

**Smallest fix.** Record the parameters and compare them (four more transient slots, or one hash):

```diff
  // SwapExecutor.swap
+ tstore(add(k, 3), keccak256(abi.encode(zeroForOne, amountIn, minOut, sqrtPriceLimitX96)))
  // LPManagerModule.swap
- if (n1 != n0 + 1 || got < minOut) revert BelowMinOutOrBadSwap(got, minOut);
+ if (n1 != n0 + 1 || argsHash != keccak256(abi.encode(zeroForOne, amountIn, minOut, limit)) || paid > amountIn || got < minOut)
+     revert BelowMinOutOrBadSwap(got, minOut);
```

---

### M-3 — `_trusted()` reads the pool at one instant: a two-transaction walk charges a fee on up to the drift budget

**Severity:** Medium · **Confidence:** 75 · **Origin:** `[both]` — phase 1 oracles, AMM + flash loans, fix-verification; phase 2 agents 2, 10 (leads) · **Location:** `LPManagerModule._freshOk` / `_trusted` (src/sa/LPManagerModule.sol:814-824), `reportPrice` (:375-387), `chargeFee` (:553, :562-565) · Residual acknowledged by the client as "≈ 0.11 % of exposure per fee"; worse than stated.

```solidity
return ref != 0 && block.timestamp <= lastPriceTime + params.maxPriceAge && !_off(ref, lastReported)
    && !_off(ref, poolPrice());                                                   // :816-817
return _freshOk() && block.timestamp >= lastPriceMoved + params.minPriceStable;   // :823
```

The 300 s condition is on the anchor value only. Nothing reads the pool between the report and the use, so the comment at :820-821 ("a displaced anchor must be held against the pool for that long") is not what the code does. The fee's second leg, `uint256 vp = accountValue(a, poolPrice());` (:563), is the same same-transaction spot read, so `min(V(anchor), V(pool))` gives no protection when the pool is pushed inside the fee transaction. The response's residual assumes the keeper must hold the pool displaced against arbitrage for `minPriceStable`. It does not have to hold anything.

**Trace.** Market, pool and anchor at 50; window empty. The keeper key acts atomically (EIP-7702 code on the keeper EOA keeps `msg.sender == keeper`; two back-to-back transactions also work).
1. Transaction 1: buy the pool to 1.084 P. `reportPrice(1.10 P)` passes `_checkPoolBand` (1.5 % of the pool) and fits the 10 % window. Sell back. Anchor = 1.10 P.
2. Any time: `reportHedgeEquity(a, storedValue)` refreshes `hedgeTime`.
3. Transaction 2, 300 s later: buy the pool to 1.10 P; `chargeFee(a)` for every due account; sell back. `_trusted()` holds; `v` and `vp` are both at 1.10 P.
4. An account with 1,000 HYPE of base exposure (50,000 USDC), flat at its mark, shows 5,000 of profit and pays 750 USDC on no gain: **150 bps of base exposure per fee** (157.8 bps at the exact e^0.1 bound), against the 11 bps in the response.
5. Cost: pool fees on two round trips of about 6–7k USDC notional on a full-range 300k pool (tens of USDC), more on a concentrated pool; no price exposure. The same displaced anchor books every pending flow and sizes the hedge cap.

Walking the anchor on consecutive days compounds the bound; the fee is then limited by the cap of 20 % of idle USDC per 7 days. The fee goes to `feeRecipient`, so this is over-charging by a dishonest or compromised keeper inside the on-chain bounds, which the client lists as out of scope for honesty but in scope for the size of the bound (task 1.5). Raising `minPriceStable` does not help.

**Smallest fix.** A same-transaction spot cannot be made trustworthy by waiting. Options, smallest first:
- In `_trusted()`, also require that the anchor's displacement over the window is small: `SAWindow.used(priceBudget.window) <= poolBandBps × (WAD / BPS)`. A walk must then be held for more than a day in public view before a fee or a booking.
- Store a `(timestamp, poolPrice)` sample at each `reportPrice` and require a sample from an earlier block, at least `minPriceStable` old and in band, before `_trusted()` is true.
- Charge on `min(V(anchor), V(pool), V(lowest anchor of the last 24 h))`.

---

### M-4 — Flows are booked at an anchor that may sit a full band from the pool: the keeper books at the edge, and a client times its flows against the gap

**Severity:** Medium · **Confidence:** 80 · **Origin:** `[both]` — phase 1 general, precision-math, AMM, fix-verification, keeper lens; phase 2 agents 2, 6, 9, 11 · **Location:** `LPManagerModule._sync` (src/sa/LPManagerModule.sol:734-736), `SABook.sync` (src/sa/SABook.sol:52, 61-63), `_freshOk` (src/sa/LPManagerModule.sol:816-817), `reportPrice` (:376)

Booking uses the anchor alone: `SABook.sync(..., _trusted() ? lastPrice : 0)` (:735). `reportPrice` accepts any price within `poolBandBps` of the pool, and `_trusted()` accepts an anchor up to a band from the pool. "Same function and same price as `value`" makes a booking profit-neutral at the instant of booking only. `contributed` keeps the anchor mark for good; `value` is re-marked when the anchor converges.

**Keeper side — no capital, no pool move.**
1. Pool and market at 40. Client deposits 1,000 HYPE.
2. Keeper `reportPrice(39.40)` (1.5 % under the pool, 1.52 % of the drift window). After 300 s any syncing call, for example `reportHedgeEquity(a, sameValue)`, books `contributed += 39,400`.
3. Keeper reports 40 and, when the fee is due, calls `chargeFee`: profit 600, fee 90 USDC, real gain 0.

| Case (defaults) | Phantom gain | Fee |
|---|---|---|
| One-way base flow F | 1.5 % × F | 0.225 % × F |
| Inflow booked at the low edge, outflow at the high edge | 3 % × F | 0.45 % × F |
| Hard caps (band 500, fee 2000), one way | 5 % × F | 1 % × F |

This includes the whole wallet of a newly registered 7702 client, because registration books nothing.

**Client side — the mirror.** The anchor is public and unchanged for at least 300 s before anything is booked, and a pending flow can be withdrawn before the keeper's next sync. A client deposits base only while the anchor is above the pool and withdraws only while it is below:
1. Market 50.00, anchor 50.60 (trusted). Client moves 20,000 HYPE in. Sync books `contributed += 1,012,000` for 1,000,000 of value.
2. Later, market 50.00, anchor 49.50. Client moves the HYPE out. Sync books `contributed −= 990,000`.
3. Net flow 0; `contributed` is up 22,000; 3,300 USDC of fee is shielded. Up to 2 × band × notional per cycle, for gas. Direct liquidity on a tracked position gives a smaller, second-order version of the same ratchet (`liquidityValue` at the anchor against tokens at slot0).

The keeper's own policy makes the gap routine: `SAKeeper.fee` holds the anchor value while any fee is due, within 0.8 × band of the pool (K-2).

**Rebuttal 1.** "One price makes a round trip exactly zero" is true only when both legs are booked at the same anchor value; `test_H1_Sibling_DepositWithdrawCyclesNetZero` keeps the anchor fixed. The min/max rule the client rejected would close the keeper side. It would reopen the client's spread farming unless each flow has one fixed price, so neither rule alone is enough.

**Smallest fix.** Use a much tighter band for booking than for acting: book only while `|anchor − pool| <= BOOK_BAND_BPS` (10–30 bps; the pool's own fee is a natural value) and leave the flow pending otherwise. This cuts the keeper side and the first-order client side linearly and the liquidity side quadratically. It does not need room in the module if the comparison is done in `SABook.sync` with the pool price passed in.

---

### M-5 — The keeper chooses when a flow is booked, and the module acts on funds whose flow is still pending

**Severity:** Medium · **Confidence:** 80 · **Origin:** `[both]` — phase 1 oracles, fix-verification, keeper lens; phase 2 agents 3, 4, 7, 10 (findings), 1, 5, 8, 9, 12 (leads) · **Location:** `LPManagerModule._sync` (src/sa/LPManagerModule.sol:734-736), `SABook.sync` (src/sa/SABook.sol:49, 52), `reportPrice` (src/sa/LPManagerModule.sol:380-383), `swap` (:463, :482-483) · The pending state is an acknowledged residual; its price consequence is not stated.

`sync` returns at `if (price == 0) return;` (SABook.sol:49) while the anchor is not trusted, and later values the flow at whatever the anchor is at the first trusted sync. Only keeper functions (and the treasury's `returnHedgeMargin`) call `_sync`; the client cannot make the module book. Trust is switched off for 300 s by any anchor change, and `if (p != old) { lastPrice = p; lastPriceMoved = block.timestamp; }` (:380-383) fires on a one-unit move, which costs about 2.5e-8 of the drift budget. `swap`, mint, increase, decrease and burn do not need a trusted anchor and move the snapshot by their computed effect, so `snapBase` can go negative while the flow stays denominated in the original token.

**Trace 1 — look-back on a held deposit.** A 7702 client registers with 1,000 HYPE at 39. The keeper first syncs at a trusted anchor on day 3 at 33, and charges on day 7 at 38. Profit reads 5,000 and the fee is 750 on a real change of −1,000 since registration. Mirror: a withdrawal at 36 booked at 40 gives 4,000 of phantom profit.

**Trace 2 — the shipped keeper, no intent.** The client sends 1,000 HYPE at 40 two minutes after an anchor move. `manage_lp` sells it in chunks (`_sync` is a no-op): `snapAsset += 39,880e6`, `snapBase = −1,000e18`. The price falls to 36. First trusted sync: `f = 1,000e18 × 36e6 / 1e18 = 36,000e6`. `contributed` = 36,000, value = 39,880, profit 3,880, fee 582 USDC. The client is down 120 against its deposit. The keeper never checks `pending` or `trusted` before acting (keeper/elysium_keeper/sa_keeper.py:204-207, 286-288).

Magnitude: `feeBps × base flow × |P_flow − P_book|`, limited by the fee cap per interval. An honest keeper with no drift has zero expected error, but the HWM charges gains and does not refund losses, so variance alone raises the expected fee. This contradicts "only market moves on booked holdings change profit".

**Smallest fix.**
- Add a permissionless `sync(address a)` that reverts unless `_trusted()`, so the client (or anyone) can fix the booking moment.
- In `swap`, `_add` and `_remove`, revert when the anchor is not trusted and the live base balance or liquidity differs from the snapshot (a flag returned by a `SABook` view keeps the module small).
- Keeper: skip swap, mint and increase while `pending != 0` and the anchor is not trusted; send a sync as soon as it is.

---

### M-6 — `chargeFee` values a base deposit at `min(V(anchor), V(pool))` after `_sync` booked it at the anchor: a parked deposit sets the fee to zero

**Severity:** Medium · **Confidence:** 80 · **Origin:** `[both]` — phase 2 agents 1, 2, 5, 6, 10 (findings), 4 (lead); phase 1 oracles (as part of the spot finding) · **Location:** `LPManagerModule.chargeFee` (src/sa/LPManagerModule.sol:555, 562-565), `_sync` (:735)

```solidity
_sync(a);                                               // books pending flows at lastPrice
...
uint256 v = accountValue(a, lastPrice);
uint256 vp = accountValue(a, poolPrice());
int256 profit = int256(vp < v ? vp : v) - s.contributed;    // :565
```

The `min` was added to protect the client from a displaced pool. It also means a base flow booked in the same call is valued at the pool price, not at its booking price. While the pool is below the anchor (allowed up to the band), a base deposit adds `B × anchor` to `contributed` and only `B × pool` to the value used.

**Trace.** Anchor 30.45, pool 30.00 (`_off` compares 4.5e9 > 4.5e9: false, so trusted). Idle 100,000 USDC, `contributed` 95,000, `hwm` 0: profit 5,000, fee due 750.
1. The client sends 12,000 HYPE (360,000 at the pool) to the account before the fee date.
2. `chargeFee` → `_sync`: `contributed += 12,000 × 30.45 = 365,400`. `vp` rises by 360,000.
3. Profit = 100,000 + 360,000 − 460,400 = −400. `hwmFee` returns 0, nothing is written, no event.
4. The client withdraws the HYPE; the next sync books it out at the anchor of that time.

The deposit needed is about `profit / gap` (67 × the profit at a 1.5 % gap) for one keeper call; the HYPE can be borrowed. The fee date is public (`lastFeeTime + feeInterval`), the pool is below the anchor about half the time without any help, and a client can push it there for tens of USDC. Because of the high-water mark this defers the fee each time; repeated at every interval it avoids it. A client with no deposit can lower profit by `gap × own base exposure` the same way (phase 2 agent 4).

This is the same root cause as M-4 seen from the fee side: one booking price, two valuation prices.

**Smallest fix.** Measure profit at the booking price and use the pool only as a gate:

```diff
- int256 profit = int256(vp < v ? vp : v) - s.contributed;
+ if (lastPrice > poolPrice()) revert StalePrice();   // account value rises with price, so V(anchor) <= V(pool) here
+ int256 profit = int256(v) - s.contributed;
```

With the tight booking band of M-4 the gate rarely blocks. Emit an event when `profit > hwm` is false only because of flows booked in the same call.

---

### M-7 — The drift budget counts path length, and a guardian-approved move fills it: ordinary volatility freezes the anchor and stops margin sends, swaps and adds

**Severity:** Medium · **Confidence:** 65 · **Origin:** `[phase1: oracles, fix-verification]` · **Location:** `SALib.movePrice` (src/sa/SALib.sol:328-342), `LPManagerModule._freshOk` (src/sa/LPManagerModule.sol:816), `_checkKeeperPrice` (:831-836) · Round-2 M-4 partly fixed.

`movePrice` charges `|p − ref| / min(p, ref)` for every report (`SAWindow.add(b.window, move);`, SALib.sol:341). The budget is the sum of absolute moves over 24–27 h, not net displacement. The keeper must report at least every `maxPriceAge` and whenever the pool leaves the band. Hourly absolute moves of 0.5–1 % sum to 12–24 % a day against a budget of 10 %. Once the room is 0 the anchor freezes, `_off(ref, lastReported)` turns true, and `_freshOk()` is false:

- no booking, no fee;
- `sendHedgeMargin` reverts, and keeper hedge decreases are refused and set `hedgeClipped`;
- when the market is more than about 3 % from the frozen anchor, no `keeperPrice` satisfies both bands at :832 and :835, so `swap`, `mintPosition` and `increasePosition` are impossible.

Only a guardian range restores the anchor, and it charges the whole remaining room (`SAWindow.add(b.window, room);`, SALib.sol:333), so each further move in the window needs another signature. The round-2 test `test_M4_PoC_SaturatedWindowOneUnitDoesNotBlock` itself asserts the window is full after the approved jump.

**Trace.** Anchor 50. Ten hourly reports of about 1 % each (50.5, 50.0, 50.6, …) use the 0.10 WAD budget. Hour 11: market 52. `reportPrice(52e6)`: room 0, anchor stays 50, `lastReported` = 52e6, `_off(50, 52)` true. `sendHedgeMargin` reverts `StalePrice` for at least 14 h. A swap needs `keeperPrice >= 52 × 0.985 = 51.22` and `<= 50 × 1.015 = 50.75`: empty.

This fails closed for fees and open for risk: margin top-ups and rebalancing stop in exactly the markets where the short hedge needs margin.

**Smallest fix.** Budget net displacement: credit the window when a move reverses an earlier one (`SAWindow.credit` already exists for hedge equity), and do not charge a guardian-approved move to the keeper's window. Let `sendHedgeMargin` fall back to the pool-band check when the anchor is clipped but the keeper's last report is in band of the pool.

## Low

### L-1 — A managed account can avoid the fee without leaving: refuse only the fee transfer, or keep idle USDC at zero

**Severity:** Low · **Confidence:** 80 · **Origin:** `[both]` — phase 2 agents 8 (finding), 2, 5, 9, 1 (leads); phase 1 account-abstraction, signatures, framework lens · **Location:** `SALib.live` (src/sa/SALib.sol:217-221), `LPManagerModule.chargeFee` (src/sa/LPManagerModule.sol:567-569), `SALib.transferOut` (src/sa/SALib.sol:537) · Acknowledged by the client as L-10; one variant is new.

- **Refusal.** `live` compares only `ownerOf(a) == s.owner` for hybrids (SALib.sol:220). The fixture bytecode confirms `upgradeToAndCall` is callable by the account itself, and the repo's own test asserts an upgraded account stays active (test/sa/SARegressions.t.sol:40). An implementation that reverts only `transfer(feeRecipient, …)`, or sends one extra unit so that `t.balanceOf(to) - r0 != amount` (SALib.sol:537), makes every `chargeFee` revert while all other actions continue. The NatSpec at SALib.sol:215 ("code / owner unchanged … a change is a revocation") is true only for 7702 accounts.
- **Silent zero (not covered by the proposed operator rule).** `maxFee = asset.balanceOf(a) * FEE_MAX_BPS / BPS` and `if (f == 0) return 0;` (LPManagerModule.sol:567-568). A client that keeps idle USDC at 0 gets `f = 0` with no revert, no event and no `lastFeeTime` write. The rule "stop managing an account whose fee fails on two consecutive due dates" does not see it. An upgraded hybrid can forward USDC out inside the removal bracket, so even an atomic `[decreasePosition, chargeFee]` yields 0.

**Fix.** Emit an event (or return a distinct value) when `profit > hwm` and `f == 0`. When the transfer of a due, positive fee fails, mark the account not live (`s.revoked = true`) instead of reverting. Correct the NatSpec; have the keeper compare the ERC-1967 implementation slot with `hybridImpl` before acting.

### L-2 — Hedge equity inputs to the fee gate: an equal report refreshes `hedgeTime`, and a one-unit decrease clears `hedgeClipped`

**Severity:** Low · **Confidence:** 75 · **Origin:** `[both]` — phase 1 oracles, fix-verification; phase 2 agents 3, 5, 7, 11 (leads) · **Location:** `SALib.moveHedge` (src/sa/SALib.sol:359, 376-381), `LPManagerModule.chargeFee` (src/sa/LPManagerModule.sol:559) · Round-2 L-1 fixed for the stated case only.

`s.hedgeTime = block.timestamp;` (:359) runs before `if (v >= old) return (old, v != old);` (:376). A report of the stored value passes the recency gate at LPManagerModule.sol:559 without re-measuring anything. A short hedge loses when HYPE rises, which is when the LP leg shows profit: LP +5,000, hedge −5,000, keeper re-reports 17,500, `chargeFee` takes 750 on a real gain of 0. Separately, `s.hedgeClipped = clipped;` (:381) records whether the last decrease fit, not whether stored equity reached the reported value: after a clipped report (stored 25,000, real 20,000), `reportHedgeEquity(a, stored − 1)` with one raw unit of room clears the flag. Room appears with any rise of account value, including a 1 USDC `deposit` by anyone.

**Fix.** Refresh `hedgeTime` only when a report is applied in full or approved. Store the last reported value and keep the flag while `hedgeEquity > lastReportedEquity`.

### L-3 — Anyone who moves the pool spot switches trust off: fees, margin sends, booking and hedge decreases stop, and `hedgeClipped` latches

**Severity:** Low · **Confidence:** 65 · **Origin:** `[phase1: oracles, AMM, general]`, phase 2 agents 4, 9 (leads) · **Location:** `LPManagerModule._freshOk` (src/sa/LPManagerModule.sol:814-818), `reportHedgeEquity` (:538-541), `SALib.moveHedge` (src/sa/SALib.sol:377-381)

With the spot more than 150 bps from the anchor, `chargeFee` and `sendHedgeMargin` revert, `_sync` books nothing, mint / increase / swap revert `PoolPriceOff`, and `reportHedgeEquity` runs with `cap = 0` (:538), so an honest lower report sets `hedgeClipped = true`; the fee then reverts `StaleHedge` until a later decrease applies in full, which outlasts the displacement. Cost on a pool of this depth: roughly 1–13k USDC of notional and tens to about 140 USDC per arbitraged push. A third party must hold the displacement (FCFS sequencer); a client's account code can do it for free inside a keeper redemption and leave it for the keeper's next calls.

**Fix.** Do not write `hedgeClipped` when `cap == 0` because of `!_freshOk()`: revert `StalePrice` for a decrease in that state. Use the earlier-block pool sample from M-3 for the predicates.

### L-4 — After a sequencer halt shorter than `maxPriceAge` the pre-halt anchor is trusted in the first block, and the keeper cannot correct it

**Severity:** Low · **Confidence:** 60 · **Origin:** `[phase1: chain-specific, oracles]` · **Location:** `LPManagerModule._freshOk` / `_trusted` (src/sa/LPManagerModule.sol:814-824), `_checkPoolBand` (:806-810) · Acknowledged as I-9 "partly"; the cited safeguard does not act.

The halt counts as elapsed time, the pool is frozen so it is in band, and `minPriceStable` is measured from the last anchor change, so it is already satisfied. `reportPrice(trueMarket)` reverts `PoolPriceOff` until arbitrage moves the pool. In that interval a keeper bot that mirrors `_trusted()` charges and books at the pre-halt price: with an 8 % move, 2,000 HYPE of exposure and 5,000 of booked profit, the fee is 750 against a fair 150.

**Fix.** Treat a report gap as a move: `if (p != old || block.timestamp > lastPriceTime + HEARTBEAT) lastPriceMoved = block.timestamp;` and require a report within `HEARTBEAT` in `_trusted()`.

### L-5 — The permit fallback accepts a consumed signature when a standing approval of the same amount exists

**Severity:** Low · **Confidence:** 70 · **Origin:** `[both]` — phase 1 signatures, general, account-abstraction, fix-verification; phase 2 agent 2 (lead) · **Location:** `SALib.pull` (src/sa/SALib.sol:277-292) · Round-2 M-3 fixed, with this corner.

The fallback proves the signature was the owner's last permit (`n − 1`), the deadline is open and `allowance(o, module) == amount` (:280-289). It does not prove the allowance came from that permit. `deposit` needs a plain allowance to the module (LPManagerModule.sol:351). Trace: the owner onboards 5,000 USDC by permit (deadline +30 d); on day 3 the owner sends `approve(module, 5_000e6)` to deposit into another account; anyone replays the public `onboard` calldata; the permit reverts, the fallback passes, and 5,000 USDC moves into the owner's own hybrid account; the owner's `deposit` reverts. No third party gains. The NatSpec "a standing allowance from `approve` is never used" (SALib.sol:273) is not fully true.

**Fix.** Mark each pulled permit as used (`usedPermit[keccak256(abi.encode(o, amount, deadline, r, s_))]`) and bound `deadline` in `onboard`.

### L-6 — `onboard` pulls the pinned owner's USDC with no liveness check

**Severity:** Low · **Confidence:** 70 · **Origin:** `[phase1: signatures]` · **Location:** `LPManagerModule.onboard` (src/sa/LPManagerModule.sol:337-342), `SALib.register` (src/sa/SALib.sol:237)

For the stored delegation `_register` returns before any check (SALib.sol:237), and `onboard` then calls `SALib.pull(address(asset), s.owner, a, …)` (:342) without `_live(a)`. The pull works after expiry, after the client disabled the delegation at the DelegationManager, and after the hybrid's owner was rotated. In the last case the old owner's outstanding permit moves its USDC into an account it no longer controls.

**Fix.** After `_register(d)` in `onboard`: `if (!SALib.live(s, a, designatorHash) || delegationManager.disabledDelegations(s.delegationHash)) revert NotLive();`.

### L-7 — Increases, decreases and burns are booked without a read-back; a displaced slot0 at the read leaves a phantom contribution of up to the slippage bound

**Severity:** Low · **Confidence:** 55 · **Origin:** `[both]` — phase 1 oracles, fix-verification; phase 2 agent 3 (lead) · **Location:** `LPManagerModule._add` (src/sa/LPManagerModule.sol:761-766), `_remove` (:776-780), `SABook.lpAdd` (src/sa/SABook.sol:115-124)

`_add` books `-pa, -pb` from slot0 read before the redemption and `snapLiquidity[p.tokenId] += liq;` (:766) with no check that PositionManager applied the liquidity (only a mint is read back). The only bound is `if (got * BPS < paid * (BPS - slip)) revert SALib.AddValue(got, paid);` (SABook.sol:118). An upgraded account that pushes the spot to the edge before the read and restores it before the modify (or skips the add) pays less than was booked; the surplus is a pending inflow booked into `contributed`: up to 150 bps of the add (22.5 bps in fee). A skipped decrease or burn is against the client. This is the bound the response's rebuttal 2 implies; we state its size.

**Fix.** After `_modify` in `_add`, require `posm.getPositionLiquidity(tokenId) == before + liq` and that slot0's `sqrtPriceX96` equals the value `lpAdd` used. PoolManager state cannot be faked by the account.

### L-8 — `multicall` across accounts: one account's code runs ahead of other accounts' entries and takes all gas

**Severity:** Low · **Confidence:** 60 · **Origin:** `[both]` — phase 1 account-abstraction, general; phase 2 agent 9 (lead) · **Location:** `LPManagerModule.multicall` (src/sa/LPManagerModule.sol:586-601), `SALib._redeem` (src/sa/SALib.sol:451) · Round-2 L-4 partly fixed, as the client states; two points go further.

- `ok := delegatecall(gas(), address(), r, c.length, 0, 0)` (:589). With `allowFailure`, an account that burns all gas leaves 1/64; later entries (including `burnPosition` or `returnHedgeMargin` for other accounts) fail out-of-gas while the transaction succeeds with `CallFailed(i, "")`.
- An upgraded hybrid ordered before another client's `swap` can move the pool inside its bracket; the victim's entry still passes `_checkKeeperPrice` and fills down to its floor (about 0.7 % of notional in the worked example; at most `maxSlippageBps`). On a chain with no public mempool this atomic position is not otherwise available.
- The NatSpec "at most 256 bytes … are ever copied into memory" (:578-579) holds only in the `multicall` frame.

The shipped keeper does not use `multicall`. **Fix.** Per-entry gas limits; one account per batch for hybrids, or re-check the pool price against the batch start before each entry.

### L-9 — Swaps revert on a partial fill, and revert when the spot is already past the anchor band edge

**Severity:** Low · **Confidence:** 75 · **Origin:** `[phase1: AMM]` · **Location:** `LPManagerModule.swap` (src/sa/LPManagerModule.sol:467-471, 478)

The floor is computed on the full `amountIn` (:467) while a swap stopped by the limit (:471) pays only `paid < amountIn`, so `got < minOut` reverts unless the fill is above 98.5 %. `_checkKeeperPrice` allows a spot up to about two bands from the anchor, but the limit is one band from it; in between PoolManager reverts `PriceLimitAlreadyExceeded`. No funds are lost; the keeper must split or wait.

**Fix.** Pro-rate the floor to the recorded `paid` (`got * amountIn >= minOut * paid`) and charge turnover on `paid`.

### L-10 — Size of the keeper's bound: LP adds are charged `slip / (slip + band)` of their notional

**Severity:** Low · **Confidence:** 65 · **Origin:** `[both]` — phase 1 AMM; phase 2 agent 11 (lead) · **Location:** `SABook.lpAdd` (src/sa/SABook.sol:116-119), `LPManagerModule.swap` (src/sa/LPManagerModule.sol:465-471)

`charge = Math.mulDiv(paid, slip, slip + band, Math.Rounding.Ceil);` (SABook.sol:119) lets adds worth 4 × NAV fit a 2 × NAV window at the defaults. With the pool pushed atomically (M-3), a keeper acting as counterparty can move about 3.6 % of NAV per day through swaps and about 6 % through adds; at the maxima `_setParams` allows (band 500, slippage 500, turnover 50,000) about 50 % of NAV per day. Keeper honesty inside the bounds is out of scope; this states the bound.

**Fix.** Charge adds their full notional, or add a per-account budget on realised slippage (`fair − got`, `paid − got`) of about 50 bps of NAV per 24 h, and lower the product of the three maxima.

### L-11 — A `feeBps` change applies to profit accrued under the old rate

**Severity:** Low · **Confidence:** 80 · **Origin:** `[phase1: AMM]` · **Location:** `LPManagerModule.setParams` (src/sa/LPManagerModule.sol:667-669), `chargeFee` (:567)

`chargeFee` applies the current `params.feeBps` to all profit above `hwm`. 100,000 of uncharged profit at 1500 bps becomes a 20,000 fee after the timelock sets 2000 bps. Bounded by `MAX_FEE_BPS` and the 24 h delay.

**Fix.** Store the rate per account at each fee, or make an increase effective `feeInterval` after scheduling.

### L-12 — A compromised guardian can hold the module paused for two timelock delays; the documented rotation order is unsafe and the two guardian slots are independent

**Severity:** Low · **Confidence:** 85 · **Origin:** `[phase1: access-control + governance, fix-verification]` · **Location:** `VaultTimelock.cancel` (src/VaultTimelock.sol:130-133), NatSpec (src/VaultTimelock.sol:20-21), `LPManagerModule.setPaused` (src/sa/LPManagerModule.sol:640-650), `setGuardian` (:659-665) · Acknowledged as I-6; the NatSpec is not corrected at this commit.

Every module operation is a non-self operation that the guardian can cancel while it waits; the same key pauses at once (:642). NatSpec line 21 says step 2 is safe because "the old guardian no longer holds CANCELLER when it becomes ready", but cancellation happens while the operation is waiting, so scheduling both steps together loses step 2. Minimum forced pause is two delays (96 h at the default, 60 days at the cap). During it `sendHedgeMargin` reverts and the anchor is frozen. Separately, `setGuardian` writes only the module slot (:661) and the timelock's CANCELLER role is granted in the constructor (src/VaultTimelock.sol:48); a half-rotation gives no revert.

**Fix.** One self-operation `rotateGuardian(module, newGuardian)` on the timelock that swaps CANCELLER and calls `setGuardian`; or exempt `setGuardian` and `setPaused(false)` payloads from non-proposer cancel. Correct the NatSpec.

### L-13 — The timelock operator is one address with all three roles: self-operations bypass the guardian veto, a proposer can veto its own removal, a lost key is permanent

**Severity:** Low · **Confidence:** 80 · **Origin:** `[phase1: access-control + governance]` · **Location:** `VaultTimelock` constructor (src/VaultTimelock.sol:42-49), `cancel` (:130-133), `DeploySA.run` (script/DeploySA.s.sol:75, 126)

`TimelockController(minDelay, _one(operator), _one(operator), address(0))` (:43). `revokeRole(CANCELLER, guardian)` and `updateDelay(24 hours)` are self-operations that only a proposer can cancel, so the guardian's veto over a stolen operator key lasts one delay; after it the attacker sets keeper, guardian and maximum parameters. `renounceRole` is inherited, and no admin exists, so a lost operator key freezes ownership for good. The script does not require `OWNER` to be a contract.

**Fix.** Require a multisig (`owner.code.length != 0`), add a second independent proposer, block `renounceRole` for the last proposer.

### L-14 — A pending owner cannot be cleared and its acceptance never expires

**Severity:** Low · **Confidence:** 85 · **Origin:** `[phase1: access-control, fix-verification]` · **Location:** `LPManagerModule.transferOwnership` / `_distinct` (src/sa/LPManagerModule.sol:676-686) · Side effect of the round-2 L-6 fix.

`_distinct(n)` (:677) rejects `address(0)` (:683), which is the OpenZeppelin way to cancel a pending transfer. A wrong pending owner can only be replaced through another delayed, guardian-cancellable operation, and can accept at any later time, outside the timelock's 7-day grace period. `_distinct` also knows nothing about timelock role holders.

**Fix.** `if (n != address(0)) _distinct(n);` and an expiry on acceptance.

### L-15 — `returnHedgeMargin`: the keeper chooses which account receives the treasury's allowance, and the path is open while paused

**Severity:** Low · **Confidence:** 70 · **Origin:** `[phase1: access-control]` · **Location:** `LPManagerModule.returnHedgeMargin` (src/sa/LPManagerModule.sol:511-527)

The treasury's USDC allowance to the module is global; the keeper bound is the stored `hedgeEquity` (`if (!byTreasury && amount > h) revert HedgeCap(amount, h);`, :518), which only the keeper lowers. Account C sent 100,000 of margin and its hedge lost 60,000, not yet reported; the treasury approves 100,000 meant for account A; a compromised keeper calls `returnHedgeMargin(C, 100_000e6)`; C withdraws; the pooled treasury is short 60,000. No `whenNotPaused`, no `_live`.

**Fix.** A per-account return allowance written by `hedgeTreasury`, or have the treasury call the function itself in the same batch as its `approve`.

### L-16 — DeploySA: PoolManager, PositionManager, Permit2, EntryPoint and USDC are accepted on code length alone, and nothing is verified on-chain after broadcast

**Severity:** Low · **Confidence:** 85 · **Origin:** `[phase1: access-control, chain-specific, framework lens]` · **Location:** `DeploySA.run` (script/DeploySA.s.sol:92-97, 102-104, 163-178) · Round-2 L-8 fixed for the listed checks.

`PM.code.length != 0 && POSM.code.length != 0 && PERMIT2.code.length != 0 && DM.code.length != 0` (:93). The fixtures `test/fixtures/elysium/{PoolManager,PositionManager,Permit2,EntryPointV07}.runtime.hex` exist but only the CREATE2 deployer is compared. Nothing checks that PositionManager points at this PoolManager and Permit2. The EntryPoint matters for custody: the fixture bytecode shows a hybrid's `execute` is EntryPoint-only, so a hybrid owner's own exit goes through `EntryPoint.handleOps`. The "post-broadcast" probe at :165-178 runs in the local simulation, and the script never reads back owner, roles, delay or params. "Deep" at :101 is `getLiquidity != 0` (:103). The DelegationManager owner `0xB040…9f44` (:111) can pause every redemption; who holds it on chain 99901 is not established.

**Fix.** Compare `keccak256(X.code)` with the existing fixtures; add `POSM.poolManager() == PM`; move the wiring checks into a `verify()` script run against the live addresses; add a minimum-liquidity threshold; return the timelock address.

### L-17 — Approval resets wipe a 7702 wallet's own USDC→Permit2 approval and its Permit2 allowance to PositionManager

**Severity:** Low · **Confidence:** 85 · **Origin:** `[phase1: signatures + ERC-20]` · **Location:** `SALib.modify` (src/sa/SALib.sol:480-481, 491-492), `swapVia` (:516-520) · Acknowledged as L-13; wider than stated.

The response states only the final ERC-20 reset. In addition, the first `approve(Permit2, max1)` already replaces an unlimited approval with a finite one, and `Permit2.approve(USDC, PositionManager, 0, 0)` overwrites the wallet's own standing Permit2 allowance to the canonical PositionManager. After each keeper mint, increase or USDC-input swap, every Permit2-based app the wallet uses stops until the client re-approves. No allowance is left over and no third party can spend.

**Fix.** Restore the pre-action values instead of 0 (and relax the enforcer rule), or state both effects in the client text.

## Informational

### I-1 — The 7702 branch of `accountKind` returns before the operator-address exclusion

**Severity:** Informational · **Confidence:** 80 · **Origin:** `[phase1: general, account-abstraction, chain-specific, access-control]` · **Location:** `SALib.accountKind` (src/sa/SALib.sol:183 vs :187)

`return (KIND_EIP7702, a);` (:183) runs before the check of `e.hedgeTreasury` / `e.feeRecipient` (:187). A treasury or fee-recipient EOA with the canonical designator can register; `chargeFee` or `sendHedgeMargin` on it always revert `TransferMismatch`. Operator-only. **Fix:** `if (a == e.hedgeTreasury || a == e.feeRecipient) revert BadAccount();` before both branches.

### I-2 — `setPaused(true)` has no state check: every repeat call bumps `guardianEra` and clears the price range

**Severity:** Informational · **Confidence:** 80 · **Origin:** `[phase1: access-control]` · **Location:** `LPManagerModule.setPaused` (src/sa/LPManagerModule.sol:640-650)

A second `setPaused(true)` while paused (for example a stale timelock operation) voids the range and approvals the guardian issued during the pause (`guardianEra++`, :644). **Fix:** `if (p == paused) revert BadParam();`.

### I-3 — Expired timelock operations stay "Ready" in the base state and block their id; `schedule` has no upper delay

**Severity:** Informational · **Confidence:** 85 · **Origin:** `[phase1: governance]` · **Location:** `VaultTimelock._checkNotExpired` (src/VaultTimelock.sol:125-128)

`if (ts > 1 && block.timestamp > ts + GRACE_PERIOD) revert OperationExpired(id);` (:127) gates execution only. `isOperationReady` still reports true, the same id cannot be rescheduled until cancelled, and a proposer can queue the same lever with delays D, D + 7 d, … so one is always executable. `isSelfOperation` never being cleared is harmless (an id commits to its targets). The `getMinDelay` override is consistent.

### I-4 — `multicall` accepts any module selector

**Severity:** Informational · **Confidence:** 85 · **Origin:** `[phase1: access-control]` · **Location:** `LPManagerModule.multicall` (src/sa/LPManagerModule.sol:580-605)

Walked per selector: no privilege gain (guardian and owner functions revert for the keeper; `register`, `onboard`, `deposit` behave as a direct keeper call; nested `multicall` passes). A future unguarded function would become keeper-reachable in a batch. **Fix:** an allowlist of keeper selectors.

### I-5 — Comments that no longer match the code

**Severity:** Informational · **Confidence:** 90 · **Origin:** `[phase1: general, fix-verification, access-control]`

- LPManagerModule.sol:43-44 "every action ends with a directional post-check": removed with `_post`.
- LPManagerModule.sol:57-58 and :127 say only a guardian change voids approvals; a pause now does too.
- LPManagerModule.sol:820-821 "must be held against the pool for that long": see M-3.
- ElysiumCustodyEnforcer.sol:311 "Permit2: 0 = this block": the allowance lives for the whole timestamp (several Nitro blocks).
- DeploySA.s.sol:28 names "SALib / V4PositionMath / RiskBudgets" as linked; SABook is linked and RiskBudgets is not used.
- VaultTimelock.sol:7 lists a fee-recipient setter the module does not have; SwapExecutor.sol:25 says "no state" although the transient record exists.

### I-6 — Rounding sites: all dust, no repeatable extraction

**Severity:** Informational · **Confidence:** 85 · **Origin:** `[both]` — phase 1 precision-math, AMM; phase 2 agent 1 (lead)

Every site was compared with v4-core. `_principal` rounding and branching match PoolManager exactly; `_fees` matches `Position.update`. `_mul` (SABook.sol:196-201) rounds a base delta toward minus infinity while `value` floors balances: at most one raw unit per sync, against the client. `LV(liq) − LV(old)` is off by under ±3 raw units per position per sync. In the capped branch of `hwmFee` (SALib.sol:316) split fees can total one raw unit more than the unsplit fee. `movePrice`, the enforcer fraction and the add charge round against the keeper. SAWindow packing, saturation and bucket arithmetic hold.

### I-7 — `deposit` and `returnHedgeMargin` book face value with no balance-delta check

**Severity:** Informational · **Confidence:** 75 · **Origin:** `[phase1: signatures + ERC-20]` · **Location:** `LPManagerModule.deposit` (src/sa/LPManagerModule.sol:351-352), `returnHedgeMargin` (:520-521)

A self-deposit (`msg.sender == a`) raises `snapAsset` and `contributed` with no balance change; the next trusted sync books it back, so profit is unaffected, but `Flow` events and `account()` are misleading in between. **Fix:** the delta check `pull` already uses.

### I-8 — `onboard` is ECDSA-only; an owner EOA with 7702 code may not be able to onboard

**Severity:** Informational · **Confidence:** 45 · **Origin:** `[phase1: signatures, chain-specific]` · **Location:** `SALib.pull` (src/sa/SALib.sol:277, 288-289)

If the Elysium USDC validates owners with code through ERC-1271 (as FiatToken v2.2 does; not verifiable here), a 7702-delegated owner whose delegate rejects a raw digest signature cannot pass `permit`, and the fallback then fails too. No funds at risk; the owner must use `register` + `deposit`.

### I-9 — All time guards run on the sequencer's clock

**Severity:** Informational · **Confidence:** 55 · **Origin:** `[phase1: chain-specific]`

`minPriceStable` (300 s; minimum 60 s) and `maxPriceAge` are inside the usual Nitro future-time tolerance. A colluding sequencer and keeper can make a just-moved anchor "stable" in the next block. State that the sequencer is trusted for time and ordering.

### I-10 — EIP-170 margin is 677 bytes; the assembly blocks are not marked memory-safe

**Severity:** Informational · **Confidence:** 60 · **Origin:** `[phase1: chain-specific + assembly]`

The fixes in this report add checks. Put them in `SABook` / `SALib` where possible, add a CI size check, and annotate the five assembly blocks `("memory-safe")`. The `multicall` assembly (free pointer, 256-byte cap, revert bubbling) and `mstore(xs, n)` were walked and hold.

### I-11 — First report is free, and a guardian price range has no width limit or relation to the anchor

**Severity:** Informational · **Confidence:** 80 · **Origin:** `[phase1: oracles]` · **Location:** `SALib.movePrice` (src/sa/SALib.sol:327, 331-334), `LPManagerModule.approvePrice` (src/sa/LPManagerModule.sol:611)

`if (ref == 0) return (p, false);` (:327) is bounded only by one slot0 read, and the script leaves the first report to the operator. `approvePrice` checks only `lo == 0 || lo > hi || until > block.timestamp + MAX_APPROVAL_TTL` (:611). **Fix:** make the first report in the deploy flow against a checked pool price; bound the range width.

### I-12 — Fixed gas stipends on account staticcalls decide liveness

**Severity:** Informational · **Confidence:** 70 · **Origin:** `[phase1: general + DoS]` · **Location:** `SALib.ownerOf` (src/sa/SALib.sol:206), `checkDelegation` (:162)

Both fail closed. A gas-schedule change that lifts a proxied `owner()` above 30,000 gas would make every hybrid account not live at once, including for removals; clients can still exit directly.

### I-13 — USDC blacklist or pause with immutable endpoints

**Severity:** Informational · **Confidence:** 60 · **Origin:** `[phase1: signatures + ERC-20, general]` · **Location:** `LPManagerModule.returnHedgeMargin` (src/sa/LPManagerModule.sol:520), `SALib.transferOut` (src/sa/SALib.sol:535-537)

`hedgeTreasury` and `feeRecipient` are immutable and inside the signed enforcer terms. If the module is blacklisted, `returnHedgeMargin` is dead and margin sent back directly is booked as a client contribution while `hedgeEquity` stays. If `feeRecipient` is blacklisted, every `chargeFee` reverts for good. **Fix:** a treasury-push variant of `returnHedgeMargin` with a recipient-delta check; recipient contracts that can forward.

### I-14 — A stale signed delegation registered first blocks the relayed onboarding of the intended one

**Severity:** Informational · **Confidence:** 60 · **Origin:** `[phase1: account-abstraction]` · **Location:** `SALib.register` (src/sa/SALib.sol:237-239) · Adds to acknowledged L-3.

After anyone registers an older client-signed delegation, the relayer's `onboard` with the intended one reverts `NotOwnAccount` (:239) until the client sends its own transaction. Registration also starts the fee clock and makes a 7702 wallet's whole balance a pending inflow (M-4, M-5).

### I-15 — Delegation Framework facts established from the fixture bytecode

**Severity:** Informational · **Confidence:** 85 · **Origin:** `[phase1: framework lens]` · **Location:** `SALib._redeem` (src/sa/SALib.sol:442-452)

- `redeemDelegations` validates every context copy up front (delegate == caller, signature, disabled flag), then runs `beforeAllHook`, then per execution `beforeHook` → `executeFromExecutor` → `afterHook`, then `afterAllHook`. The custody `beforeHook` for execution i therefore sees the balances left by execution i − 1. The in-scope assumption holds.
- The disabled flag and signature are not re-checked between executions: a `revoke` or `disableDelegation` from account code inside execution i does not stop executions i + 1 … n of the same redemption.
- Registration caps `isValidSignature` at 200,000 gas inside a `try`; every later redemption calls it once per context copy (up to 9) with no cap. Hostile account code can pass registration and fail or burn gas on every redemption.
- `executeFromExecutor` is DelegationManager-only on both account kinds; try mode exists, and the enforcer's `BadMode` check is what keeps it out.
- Hybrid `execute` is EntryPoint-only, so "one plain transaction … from the account" in the module header is true for 7702 accounts and means `handleOps` for hybrids. `revoke` from the owner EOA is always a plain call.
- Selectors, typehashes, the EIP-712 domain, TimestampEnforcer comparisons and `SALib.PROXY_CREATION` match the fixtures byte for byte.

### I-16 — Removals have no price, band or minimum check: no loss path found

**Severity:** Informational · **Confidence:** 80 · **Origin:** `[phase1: AMM]` · **Location:** `LPManagerModule._remove` (src/sa/LPManagerModule.sol:770-781)

A removal at a manipulated spot pays the LP a bundle worth at least its fair value, so a sandwich loses money for the attacker. `value` understates a position when the spot differs from the anchor and steps up at removal (at most the band for a narrow range); this is conservative before and correct after.

### I-17 — The DelegationManager pause is held by a third party

**Severity:** Informational · **Confidence:** 50 · **Origin:** `[phase1: chain-specific, framework lens]` · Acknowledged as L-12.

`pause` is `onlyOwner` and stops only `redeemDelegations`; `disableDelegation` and the client's exit are unaffected. The owner is a constructor constant from other chains (script/DeploySA.s.sol:111). Confirm who controls it on 99901 and have the keeper monitor `paused()`.

---

# Keeper findings (requested lens: where on-chain safety assumes operator behaviour)

The keeper is Python and outside the Solidity scope. These items are reported because the client asked for the lens and because several on-chain claims rest on them. Files: `keeper/elysium_keeper/sa_keeper.py`, `sa_chain.py`, `rpc.py`.

### K-1 — The keeper acts on accounts with pending flows while the anchor is not trusted

**Severity:** covered by M-5 (not counted again) · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.account_tick` (sa_keeper.py:204-207), `manage_lp` (:286)

`account_tick` runs `margin`, `manage_lp`, `fee` whenever `not g.paused`; nothing looks at `pending` or `trusted`, and no sync-only transaction is sent. This is trace 2 of M-5.

### K-2 — The anchor hold is re-armed by every fee-due account with no chargeable profit

**Severity:** Low · **Confidence:** 75 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.fee` (sa_keeper.py:316-324)

`self._hold_until = max(self._hold_until, now + 2 * g.params["minPriceStable"] + self.sa.report_every_s)` runs before the keeper knows whether a fee exists. On-chain `lastFeeTime` advances only when `f != 0`, so every account older than 7 days below its high-water mark re-arms the hold on each untrusted tick. While armed, the anchor lags the market by up to 0.8 × band almost permanently, which is the gap M-4 needs. The hold branch has no pool check, so a stale re-report can revert `PoolPriceOff` outside any `try` and lose the tick. **Fix:** arm the hold only after computing `fee > 0`; clear it after `chargeFee`.

### K-3 — The hedge ledger is updated in memory after the on-chain margin move and saved at tick end; a timeout or crash desynchronises it

**Severity:** Medium · **Confidence:** 70 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.margin` (sa_keeper.py:230-231), `wind_down` (:398), `tick` (:493, :500), `Chain.transact` (rpc.py:260-261)

`self.act("sendHedgeMargin", …)` is followed by `self.ledger.margin_sent(…)`; the state is saved at :500. If the receipt wait raises `TimeoutError` (rpc.py:261) and the transaction is mined later, or the process dies first, the chain has `hedgeEquity += amt` and the ledger does not. Nothing rebuilds the ledger from on-chain `netMargin` or the margin events. Then `report_equity` lowers the client's on-chain equity (5 % of value per 24 h), `ledger.reconcile` (:493) spreads the "unexplained" treasury USDC over the other clients, and at exit the client is returned about nothing by the keeper. The reverse case (return mined, ledger not updated) repeats the return up to the remaining on-chain equity, out of other clients' margin. **Fix:** reconcile against chain facts at the start of each account tick; save a write-ahead intent; resolve the hash on timeout; never let `reconcile` distribute a large difference without an alert.

### K-4 — `chargeFee` can run on a hedge equity up to `maxPriceAge` old; the keeper reports equity after the fee, with a 0.5 % deadband

**Severity:** Low · **Confidence:** 70 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.fee` (sa_keeper.py:325-330), `report_equity` (:360), `account_tick` (:207-211)

The refresh before the fee re-reports the old value when it is merely aged; the routine report runs after `fee()` and skips differences below `max(10 ** 6, old // 200)`. See L-2 for the on-chain side. **Fix:** `multicall([reportHedgeEquity(a, exactLedgerValue), chargeFee(a)], false)`.

### K-5 — Any revert aborts the rest of that account's tick, including the hedge target and the equity report

**Severity:** Low · **Confidence:** 75 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.account_tick` (sa_keeper.py:204-211), `tick` (:483-486)

A revert in a mint, burn, decrease or `chargeFee` skips lines 208-211 for that account on every tick while the cause persists; the short stays at the old target while the LP changes. The fee path sends `decreasePosition` then `chargeFee` (:345) as separate transactions; if the fee reverts, the next tick redeploys the freed USDC and removes it again, which costs swap fees and turnover. **Fix:** batch `[decreasePosition, reportHedgeEquity, chargeFee]`; run `set_target` and `report_equity` in a `finally`.

### K-6 — `GlobalSnap.trusted()` measures the band against the anchor; the contract measures it against the pool

**Severity:** Low · **Confidence:** 90 · **Origin:** `[phase1: keeper lens]` · **Location:** `GlobalSnap.trusted` (sa_chain.py:248), `LPManagerModule._off` (src/sa/LPManagerModule.sol:801-804)

Keeper: `abs(self.pool_price - lp) * 10_000 <= lp * p["poolBandBps"]`. Contract: `d * BPS > ref * params.poolBandBps` with `ref` = the pool price. Anchor 40.000, pool 39.404: the mirror says trusted (0.596 <= 0.600), the contract says no (5,960 > 5,910.6). The keeper then removes liquidity for a fee that reverts `StalePrice` (K-5). **Fix:** use the pool as the denominator, or probe `chargeFee` with `eth_call` first.

### K-7 — Swaps pass `minOut = 0` and a `keeperPrice` that can be the held anchor

**Severity:** Low · **Confidence:** 65 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.swap` (sa_keeper.py:248, :256), `LPManagerModule.swap` (src/sa/LPManagerModule.sol:465-469)

Confirmed on-chain: the module's floor applies (`if (minOut < floor) minOut = floor;`). The floor is measured from the keeper's own price; with the hold it can sit 1.2 % from the Hyperliquid mid, so the worst accepted execution is about 2.7 % from it. The probe's returned `out` is discarded. **Fix:** pass `minOut = probeOut × (1 − 30 bps)` and a fresh `keeperPrice`.

### K-8 — Decrease for a fee uses zero minima; add maxima equal the whole balance

**Severity:** Low · **Confidence:** 70 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.fee` (sa_keeper.py:341)

`self.act("decreasePosition", a, p.token_id, int(p.liquidity * q), 0, 0)`. `_remove` has no price check on-chain (I-16 explains why a sandwich does not pay). The add maxima do not constrain anything; the real bound is the `AddValue` check. **Fix:** set decrease minima as for burn (slot0 amounts × 99 %).

### K-9 — One serial loop over every registered account with one anchor report per tick

**Severity:** Low · **Confidence:** 60 · **Origin:** `[phase1: keeper lens]` · **Location:** `SAKeeper.accounts` (sa_keeper.py:153-167), `tick` (:466)

With `sa.discover_from_block` set, every permissionless registration is appended and never pruned; about 50 `eth_call`s per account per tick. Once a tick exceeds `maxPriceAge`, the anchor expires mid-tick and margin sends, fees and bookings stop for all clients. Discovery is off by default (config.py:96), in which case relayer-onboarded accounts are not managed until added by hand. **Fix:** pre-filter with one multicall read; skip dust; re-run `anchor()` inside the loop.

### K-10 — No quarantine for accounts whose code behaves differently in simulation and on-chain

**Severity:** Low · **Confidence:** 55 · **Origin:** `[phase1: keeper lens, framework lens]` · **Location:** `Chain.transact` (rpc.py:245-251), `SAKeeper.tick` (sa_keeper.py:483-486)

Account code runs in every redemption, uncapped (I-15). An upgraded hybrid that succeeds under `eth_call` and burns the limit on inclusion makes the keeper send one doomed transaction per action every tick, with no backoff. **Fix:** per-account failure and gas counters, exponential backoff, a gas cap per action.

### K-11 — A position the client moved out of the account wedges that account's tick

**Severity:** Low · **Confidence:** 75 · **Origin:** `[phase1: keeper lens]` · **Location:** `ModuleReader.account` (sa_chain.py:313), `pending` (:336)

The reader takes liquidity from `getPositionLiquidity` with no `ownerOf` check, so `pending` shows 0 for a transferred NFT. `manage_lp` then calls `increasePosition` or `burnPosition` on that id; at a trusted anchor the sync drops the position and `_indexOf` reverts `UnknownPosition` (rolling the drop back); untrusted, the enforcer reverts. K-5 applies. **Fix:** read `ownerOf`; send a sync-only call first; the permissionless `sync(a)` of M-5 also solves it.

### K-12 — Relayer: the factory `deploy` call is not allowed to fail

**Severity:** Low · **Confidence:** 80 · **Origin:** `[phase1: keeper lens]` · **Location:** `Relayer.onboard` (sa_chain.py:402-407)

The API's delegation and permit checks are equal to or stricter than `checkDelegation` and `pull`. The one gap: anyone can deploy the same CREATE2 proxy between the `eth_getCode` check (:402) and inclusion; the batch reverts and the request fails once. **Fix:** `allowFailure = True` for the deploy call.

### K-13 — Smaller operational gaps

**Severity:** Informational · **Confidence:** 60 · **Origin:** `[phase1: keeper lens]`

`hl.adapter` defaults to `dry_run` (config.py:72) and nothing ties it to the chain signer: with a live signer, real USDC goes to the treasury while the hedge is simulated. `wind_down` sends one `reportHedgeEquity(a, 0)` (sa_keeper.py:389) and closes the ledger entry even if the step budget clips it. No alert before a delegation's `until`.

---

# Leads (confidence below 50, or examined and not confirmed)

- **`lpRemove` reads slot0 before account code runs** (phase 2 agent 7). Examined: after a trusted sync, profit equals the snapshot valued at the anchor minus `contributed`, and the live balances cancel. A different principal paid by PositionManager becomes a pending flow that moves `value` and `contributed` together. No change of profit. Not a finding.
- **A client keeps its own flows pending by pushing the pool out of band before each keeper transaction** (phase 2 agents 8, 9). Plausible on an FCFS chain only if the client can anticipate the keeper; the cost was not sized. The tight booking band of M-4 and the permissionless sync of M-5 remove the incentive.
- **Opposite-direction swap that raises `contributed`** (M-2 trace B, reverse case). Needs a keeper USDC→HYPE swap of a few raw units; there is no on-chain minimum `amountIn` beyond `!= 0` (LPManagerModule.sol:460). Closed by the M-2 fix.
- **`tx.gasprice` under `eth_call` on Nitro** (K-10). The assumption that it reads 0 in simulation was not verified.

---

# Round-2 findings — status at `ecb6eda`

Every round-2 finding was re-checked against the current code by a dedicated agent and the Medium-class verdicts were re-read by the orchestrator. Line prefixes: M = `src/sa/LPManagerModule.sol`, L = `src/sa/SALib.sol`, B = `src/sa/SABook.sol`, X = `src/sa/SwapExecutor.sol`, E = `src/sa/ElysiumCustodyEnforcer.sol`, D = `script/DeploySA.s.sol`. "F-n" in the last column refers to this report as follows: F-1 → M-2, F-2 → M-3, F-3 and F-5 → M-4, F-4 → M-1, F-6 → M-5, F-7 → L-5, F-8 → M-7, F-9 → L-2, F-10 → I-5 and L-14.

**Summary.** Fixed as claimed: M-2, M-3 (one corner), L-2, L-5, L-6, L-7, L-8, L-9, L-11, L-15 (as stated), I-4, I-7, I-10; M-1 and L-1 for their named PoCs. Partly fixed: H-1 and L-16 (the price gate checks the pool at one instant), L-14 (the record is not bound to the module's swap), M-4 (a guardian move still fills the window), L-4 and L-13 (as the client states). Acknowledged and unchanged: L-3, L-10, L-12, I-1, I-3, I-5, I-6, I-8, I-11. Worse than acknowledged: I-2. Not improved in substance: I-9. Regressed: none; one side effect (L-14 of this report, from the L-6 fix).

| ID | Round-2 title | Client status | Verdict | Evidence | Residual or new problem |
|---|---|---|---|---|---|
| H-1 | `_sync` books flows at unbanded spot | Fixed | **Partly fixed** | M:735 `SABook.sync(…, _trusted() ? lastPrice : 0)`; B:49 `if (price == 0) return;`; B:52 books at one price; `register` has no sync (L:228-252) | PoC paths 1 and 2 as written fail: nothing is booked off-band, and registration books nothing. The bound is now the band (free) or the drift cap (two transactions), not zero: F-2, F-3. Path 3 is closed up to the band, but the flow is priced at booking time, not flow time (F-6). The seven named tests cover a displaced spot at a fixed anchor only; none moves the anchor. |
| M-1 | `increasePosition` not read back | Fixed | **Fixed** | M:761-766 `lpAdd` → `_apply(a, dA, dB); snapLiquidity[p.tokenId] += liq;` | PoC re-traced: the skipped add is a pending outflow, the redeposit an inflow, net `contributed` change is −fees + ε (against the client). Sibling "do something else with the swap execution" is open (F-1). `test_M1_PoC_SkippedIncreaseThenRedeposit` covers the PoC; `test_M1_Sibling_SkippedSwapReverts` covers only a skipped swap, not a substituted one. |
| M-2 | Removal proceeds into another tracked position | Fixed | **Fixed** | M:776-780 `lpRemove` of `m = burn \|\| liq > snap ? snap : liq` (B:137); no per-position closing snapshot exists any more | PoC re-traced: idle pending −(P+fees), B pending +Δ, net ≈ 0. Sibling (NFT transferred out inside the burn bracket) books −(P+fees), correct. Both named tests cover the claim. |
| M-3 | `onboard` spends a standing allowance | Fixed | **Fixed** (one narrow corner) | L:277-292: permit must succeed, else `n − 1` digest, `signer == o`, `allowance == amount` | PoC `onboard(d, X, 0,0,0,0)` reverts at L:280 (`block.timestamp > deadline`). Corner: F-7. Tests cover the PoC, replay, wrong amount and expired deadline; not F-7. |
| M-4 | One-unit clip blocks; guardian move saturates window | Fixed | **Partly fixed** | M:307-309 `return _off(lastPrice, lastReported);`; L:331-334 `if (clipped && …) { b.until = 0; SAWindow.add(b.window, room);` | One-unit case closed. Saturation is not: the range is used only when `move > room`, and charging `room` always leaves room 0, so the anchor is frozen until buckets age out (up to 24–27 h). A further move of more than 1.5% re-blocks sends, fees and booking (F-8). The test itself asserts `pu == 0.1e18, "window full"`. |
| L-1 | `hedgeClipped` cleared by an equal report | Fixed | **Fixed** for the stated case | L:376 `if (v >= old) return (old, v != old);` | A report of `old − 1` with one raw unit of room clears the flag (L:379-381) while stored equity is still far above the reported value (F-9). Test covers the equal report only. |
| L-2 | Hedge step cap gated by age only | Fixed | **Fixed** | M:538 `uint256 cap = paused \|\| !_freshOk()` | A lower report at a non-fresh instant now sets `hedgeClipped` (room 0, L:379-381); self-clearing. Test covers the clipped case, not age or band. |
| L-3 | First registration with any signed delegation | Ack | **Acknowledged-unchanged** | L:239 gate applies only when `old != 0`; M:359 `revoke` still reverts before registration | See section 3. |
| L-4 | `multicall` copies full revert data, no gas bound | Partly | **Partly fixed, as stated** | M:596 `if gt(n, 256) { n := 256 }` before `returndatacopy` at M:599 | The inner frames (DM, SALib, the module function) still bubble the full revert data, so "at most 256 bytes are ever copied into memory" (M:578-579) is true only for the `multicall` frame. No gas bound (M:589 `delegatecall(gas(), …)`). |
| L-5 | Band measured against the argument | Fixed | **Fixed** | M:801-804 `return d * BPS > ref * params.poolBandBps;`; M:809 `_off(price, p)` | None. Test covers `reportPrice`; the keeper-price path against the anchor (M:835) is untested but uses the same function. |
| L-6 | Role distinctness on the ownership path | Fixed | **Fixed** | M:676-679 override; M:684 `x == pendingOwner()` | `transferOwnership(address(0))` now reverts, so a pending transfer can be replaced but not cancelled (F-10). Test covers both halves. |
| L-7 | Hedge approvals survive a pause | Fixed | **Fixed** | M:644 `guardianEra++;` | Comments at M:57-58 and M:127 still describe the old rule (F-10). Test covers. |
| L-8 | `DeploySA` preconditions | Fixed | **Fixed** (not executed) | D:99 delay bounds; D:102-104 pool and DM; D:105-109 deployer hash; D:111-116 `_canonical`; D:165-178 probe | PM, POSM, Permit2, USDC and EntryPoint code is still not compared with fixtures, and "deep" (D:101) is only `getLiquidity != 0`. Fixture files exist; I did not hash them. D:28 does not name SABook as linked. The "anvil-fork e2e" claim cannot be verified here. |
| L-9 | `revoke` + `register` as an on-demand sync | Fixed | **Fixed** | L:228-252 has no sync; no client-callable path syncs (`deposit` and `onboard` call only `_book`, M:343, 352) | PoC fails at the first step. Sibling: account code pushing the pool into band between two keeper calls in one transaction (F-5, last paragraph). Test covers. |
| L-10 | Account refuses only the fee transfer | Ack | **Acknowledged-unchanged** | L:537 exact recipient delta | See section 3. |
| L-11 | Top-ups revert in the last day | Fixed | **Fixed** | L:237 `if (old != 0 && old == e.dm.getDelegationHash(d) && !s.revoked) return false;` precedes `checkDelegation` | The no-op path now checks nothing, so `onboard` also works after expiry; the pull still needs a permit. Test covers. |
| L-12 | Removals depend on the DM pause | Ack | **Acknowledged-unchanged** | L:451 | See section 3. |
| L-13 | Permit2 approvals overwritten / live to end of timestamp | Partly | **Partly fixed, as stated** | L:488, 492, 520 append `_permit2Approve(…, 0)`; L:431 `amount == 0 ? 0 : uint48(block.timestamp)` | The ERC-20 `approve(Permit2, 0)` still overwrites a 7702 wallet's approval. E:311 and E:36 still say "this block". Test covers the Permit2 side. |
| L-14 | Swap output above `minOut` leaves unbooked | Fixed | **Partly fixed** | M:477-483 books `(paid, got)` from `x.lastSwap(a)` | A skim is now a pending outflow (test mode 6 covers it). The record is not bound to the module's swap, which re-opens the class without a bound (F-1). No test covers it. |
| L-15 | No keeper min-out / deadline; turnover on `amountIn` | Partly | **Partly fixed, as stated** | M:468 `if (minOut < floor) minOut = floor;` | No deadline; turnover still charged on full `amountIn` (M:466) on a partial fill. Test covers. |
| L-16 | Walk the anchor, charge, walk back in one transaction | Fixed | **Partly fixed** | M:822-824 `_freshOk() && block.timestamp >= lastPriceMoved + params.minPriceStable` | The one-transaction form is closed. The same result takes two transactions 300 s apart with an atomic spot push in each, and the bound rises to the drift cap (F-2). The test covers only the same-transaction path. |
| I-1 | Drift bound is e^cap | Ack | **Acknowledged-unchanged** | L:328-341 | "The band adds at most 1.5%" is right for the report. The distance between a trusted anchor and the market is not bounded by the band (F-2). |
| I-2 | Client-collected LP fees | Ack | **Acknowledged-unchanged, worse than stated** | B:52-64 has no fee term; B:96-100 does | F-4. |
| I-3 | Keeper / guardian as account owner | Ack | **Acknowledged-unchanged** | L:187 excludes only treasury and fee recipient | None. |
| I-4 | `ownerOf` reverts on dirty bits | Fixed | **Fixed** | L:208-210 `if (w >> 160 == 0) o = address(uint160(w));` | None. No dedicated test. |
| I-5 | Keeper can spend a 7702 account's whole native balance | Ack | **Acknowledged-unchanged** | M:453-485 has no reserve | See section 3. |
| I-6 | Guardian can delay unpause; rotation NatSpec | Ack | **Acknowledged-unchanged** | `src/VaultTimelock.sol:20-21` still has the old text | NatSpec not corrected, as the response says. |
| I-7 | Price range consumed by any in-range report | Fixed | **Fixed** | L:331 `if (clipped && block.timestamp <= b.until && …)` | `approvePrice` still accepts an `until` in the past (M:611); harmless. |
| I-8 | Rotating a hybrid owner is a permanent exit | Ack | **Acknowledged-unchanged** | L:220, L:187 | None. |
| I-9 | No sequencer-outage handling | Partly | **Not improved in substance** | M:823 | After an outage the anchor has been "unchanged" for the whole outage, so `minPriceStable` adds nothing to the first transaction. |
| I-10 | `_conserved` tolerance | Fixed (obsolete) | **Fixed (removed)** | grep: no `_conserved`, `_snap`, `_post`, `_checkAdd` in `src/sa` | M:43-44 still says "every action ends with a directional post-check" (F-10). |
| I-11 | Design notes | Ack | **Acknowledged-unchanged** | — | None. |

### Rebuttals

| # | Rebuttal | Verdict | Why |
|---|---|---|---|
| 1 | One booking price (the anchor) instead of client-favour min/max | **Holds as a comparison, fails as a protection claim** | With one price, a cycle booked at the same anchor value nets to zero, and min/max alone would let a client farm the spread. But the booking price is the anchor alone, a trusted anchor may sit a band from an undisturbed pool, and the keeper picks which accounts to sync on which edge: 0.225 % of each base flow in fee, with no capital (M-4). Min/max would close that path. The client-side mirror exists too (M-4), the fee's `min` conflicts with anchor booking (M-6), and `test_H1_Sibling_DepositWithdrawCyclesNetZero` keeps the anchor fixed. A tight booking band closes both sides without reopening H-1. |
| 2 | Computed effect instead of reading back liquidity and balances | **Holds for LP actions and transfers, fails for the swap** | After a trusted sync, profit depends only on the snapshot, so a skipped or altered LP execution cannot gain more than the add's slippage bound (L-7). The swap's "computed" input is a record that the account's own code can produce (M-2). The uncollected-fee term is in the computed effects and in `value` but not in `sync` (M-1). Reading back PoolManager / PositionManager state (not the account's balances) after an increase does not reintroduce the round-2 problem. |
| 3 | Front-run permit tolerance kept, narrowed | **Holds**, one corner | The fallback needs the owner's own signature over (owner, module, amount, nonce − 1, deadline), an open deadline and `allowance == amount`; funds only move from the pinned owner into that owner's own account. Corner: a later standing approval of the same amount (L-5). |

### Acknowledged residuals

| Residual | Holds as stated? | Note |
|---|---|---|
| Client-collected fees and fees of transferred-out positions (I-2) | **No — worse** | M-1. The bound is the whole LP fee income; a subscribed position removes even the keeper's chance to collect first. |
| "A keeper willing to hold the pool displaced … for `minPriceStable` … ≈ 0.11 % of exposure per fee" | **No** | M-3. Nothing is held; the bound is the drift budget (about 1.58 % of exposure in fee per walk at the defaults). Band × exposure × 15 % is 0.225 %, not 0.11 %, unless exposure is half the account. Raising `minPriceStable` does not help. |
| Flows stay pending while the anchor is not trusted | Holds, with a consequence not stated | M-5: the booking price and time are the keeper's choice, and the module acts on pending funds. |
| A mint at `MAX_POSITIONS` may need a trusted sync first | Holds | The keeper cannot burn a client-burned token either (the enforcer reverts), so a trusted sync is the only way. |
| L-3 first registration permissionless | Holds | I-14 adds the relayer block and the fee-clock start. |
| L-4 multicall | Holds | L-8 adds the silent-success and ordering points. |
| L-10 account refuses the fee | Holds; the operator rule is not implemented | L-1 adds the silent zero-fee variant the rule does not see. |
| L-12 DelegationManager pause | Holds | I-17. |
| L-13 Permit2 / ERC-20 approvals on 7702 wallets | Holds; wider than stated | L-17. |
| I-5 7702 native gas reserve | Holds | No reserve in code. |
| I-6 guardian can delay unpause | Holds | NatSpec not corrected (L-12). |
| I-8 owner rotation is a permanent exit | Holds | L-6 adds the pull after rotation. |
| I-9 sequencer outage | The "partly" is not real | L-4: `minPriceStable` is already satisfied after an outage. |

---


---

# Access-Control Inventory

From the phase-0 context pass (findings-free), reconciled against the grep-verified entry-point list. Abbreviations: `M` = src/sa/LPManagerModule.sol, `TL` = src/VaultTimelock.sol, `SX` = src/sa/SwapExecutor.sol, `ENF` = src/sa/ElysiumCustodyEnforcer.sol, `OZ-TC` = OpenZeppelin TimelockController, `OZ-AC` = AccessControl, `OZ-O2S` = Ownable2Step, `nR` = nonReentrant. "sync-set" = the fields `_sync` writes when the anchor is trusted.

### Entry-point table

| Contract.function | Guard (file:line) | Who can call | State written | Moves value? |
|---|---|---|---|---|
| M.register | nR M:326; `lastPrice != 0` M:366; replace/resume: `msg.sender == a or s.owner` SALib:239 | Anyone for a first registration; account or pinned owner otherwise. Stored non-revoked delegation returns early at SALib:237 for anyone | `accounts[a]` (delegationHash, owner, kind, until, revoked, lastFeeTime on first), `permissionContext[a]` | No |
| M.onboard | nR M:335; same as register; kind must be HYBRID M:341; permit by `s.owner` SALib:277-292 | Anyone | registration state, `snapAsset`, `contributed` | USDC pinned owner → account |
| M.deposit | nR M:347; registered M:349; amount != 0 M:350 | Anyone | `snapAsset`, `contributed` | USDC caller → account |
| M.revoke | `msg.sender == a or s.owner` M:360; registered M:359; no nR, no pause | Account or pinned owner | `accounts[a].revoked` | No |
| M.reportPrice | nR, onlyKeeper M:375 | keeper | `lastPrice`, `lastPriceMoved`, `lastReported`, `lastPriceTime`, `priceBudget` (window, `until`) | No |
| M.mintPosition | nR, onlyKeeper, whenNotPaused M:398 | keeper | sync-set, turnover window, `snapAsset/snapBase`, `snapLiquidity`, `_positions[a]` push | account → PoolManager |
| M.increasePosition | nR, onlyKeeper, whenNotPaused M:418 | keeper | same, without the push | account → PoolManager |
| M.decreasePosition | nR, onlyKeeper M:431-432 | keeper | sync-set, `snapAsset/snapBase`, `snapLiquidity` | PoolManager → account |
| M.burnPosition | nR, onlyKeeper M:441-442 | keeper | same, plus `_positions[a]` removal and `snapLiquidity` delete | PoolManager → account |
| M.swap | nR, onlyKeeper, whenNotPaused M:455-457 | keeper | sync-set, turnover window, `snapAsset/snapBase` | account ↔ PoolManager via SX |
| M.sendHedgeMargin | nR, onlyKeeper, whenNotPaused M:490 | keeper | sync-set, `hedgeEquity`, `netMargin`, `hedgeEpoch`, `snapAsset`; ENF `_spend.hedge` | USDC account → hedgeTreasury |
| M.returnHedgeMargin | nR M:511; `msg.sender == hedgeTreasury or keeper` M:512-513; keeper: `amount <= hedgeEquity` M:518; registered M:516 | keeper, hedgeTreasury | sync-set, `snapAsset`, `hedgeEquity`, `netMargin`, `hedgeEpoch` | USDC hedgeTreasury → account (treasury allowance to the module) |
| M.reportHedgeEquity | nR, onlyKeeper M:533; registered M:535 | keeper | sync-set, `hedgeTime`, `hedgeEquity`, `hedgeClipped`, `hedgeEpoch`, `netMargin`, `budgets[a]` hedge window and approval (SALib:354-388) | No |
| M.chargeFee | nR, onlyKeeper, whenNotPaused M:552 | keeper | sync-set, `hwm`, `lastFeeTime`, `feesPaid`, `snapAsset`; ENF `_spend.lastFeeTime` | USDC account → feeRecipient |
| M.multicall | onlyKeeper M:580; no nR | keeper | whatever the inner calls write (delegatecall to self M:589, `msg.sender` stays keeper, any module selector) | inner |
| M.approvePrice | onlyGuardian M:610; bounds M:611 | guardian | `priceBudget.lo/hi/until` | No |
| M.approveHedgeEquity | onlyGuardian M:623; state match M:626-629 | guardian | `budgets[a].hedgeApproved`, `…Epoch`, `…Until`, `…Era` | No |
| M.setPaused(true) | `msg.sender == guardian or owner()` M:642 | guardian, owner | `paused`, `priceBudget.until = 0`, `guardianEra++` | No |
| M.setPaused(false) | `_checkOwner()` M:646 | owner | `paused` | No |
| M.setKeeper | onlyOwner M:653; `_distinct` M:654 | owner | `keeper` | No |
| M.setGuardian | onlyOwner M:659; `_distinct` M:660 | owner | `guardian`, `guardianEra++`, `priceBudget.until = 0` | No |
| M.setParams | onlyOwner M:667; bounds M:689-695 | owner | `params` | No |
| M.transferOwnership | `_distinct(n)` M:677, then onlyOwner in super (OZ-O2S:43) | owner | pending owner | No |
| M.acceptOwnership (inherited) | `pendingOwner() == sender` OZ-O2S:60-66 | pending owner | `owner`, clears pending | No |
| M.renounceOwnership | `public pure`, always reverts M:671-673 | nobody | none | No |
| M views: poolKey, positionsOf, poolPrice, isActive, accountValue, lastPriceClipped, account, windows, public getters | none M:280-319 | Anyone | none | No |
| SX.swap | nR SX:76; amount and value checks SX:79-81 | Anyone; caller is the only payer and recipient | transient record `keccak(msg.sender, RECORD)` +0/+1/+2 SX:92-97 | caller → PoolManager; PoolManager → caller; native refund SX:89 |
| SX.unlockCallback | `msg.sender == poolManager and _reentrancyGuardEntered()` SX:113 | PoolManager, during `swap` | none | settle and take |
| SX.lastSwap, poolKey | none | Anyone | none | No |
| ENF.beforeHook | `msg.sender == delegationManager` ENF:165; `redeemer == module` from terms ENF:168; mode ENF:166 | DelegationManager | `_spend[delegator][keccak(terms)]` (hedge window, lastFeeTime) ENF:336, 344 | No |
| ENF.beforeAllHook / afterHook / afterAllHook | none; `pure`, empty ENF:141-154 | Anyone | none | No |
| ENF.decodeTerms, spend | none | Anyone | none | No |
| TL.schedule | onlyRole(PROPOSER) OZ-TC:272 via TL:81 | PROPOSER | operation timestamp; `isSelfOperation[id]` TL:82 | No |
| TL.scheduleBatch | onlyRole(PROPOSER) OZ-TC:297 via TL:93; mixed batch reverts TL:99 | PROPOSER | same; TL:100 | No |
| TL.execute | onlyRoleOrOpenRole(EXECUTOR) OZ-TC:363; `_checkNotExpired` TL:109 | EXECUTOR (anyone only if `address(0)` holds the role; the constructor does not grant that) | operation set done; target call | payable, forwards `value` |
| TL.executeBatch | same, OZ-TC:390; TL:120 | EXECUTOR | same | payable |
| TL.cancel | onlyRole(CANCELLER) OZ-TC:333; self-operation also needs PROPOSER TL:131 | CANCELLER | operation timestamp deleted | No |
| TL.updateDelay | `msg.sender == address(this)` TL:67; bounds TL:60-63 | timelock itself | `_delay` | No |
| TL.grantRole / revokeRole (inherited) | onlyRole(getRoleAdmin(role)) OZ-AC:120 / 135 | DEFAULT_ADMIN_ROLE holder, which is the timelock itself (OZ-TC:118; admin argument is `address(0)` at TL:43) | role membership | No |
| TL.renounceRole (inherited) | `callerConfirmation == msg.sender` OZ-AC:155-158 | any role holder, for itself | own role | No |
| TL.receive | none OZ-TC:156 | Anyone | ETH balance | accepts ETH |
| TL.onERC721Received / onERC1155Received / onERC1155BatchReceived (inherited) | none | Anyone | none | No |
| DeploySA.run | none (Foundry script); `require`s at DeploySA:74-109 | script runner | deploys timelock, executor, enforcer, module DeploySA:126-162 | No |
| SALib / SABook / V4PositionMath external and public functions | linked libraries, run by delegatecall from the module; no own guards | — | module storage passed in | via module |
| SAWindow | all `internal` | — | — | — |
| vendor/DelegationFramework.sol | interfaces and internal helpers only | — | — | — |

### Keeper-function gate matrix

| Function | whenNotPaused | `_live` | `_fresh` | `_trusted` | `_checkKeeperPrice` | `_sync` |
|---|---|---|---|---|---|---|
| reportPrice | No; `paused` sets the cap to 0 at M:379 | No | No | No | No; `_checkPoolBand` only, M:376 | No |
| mintPosition | Yes | Yes M:400 | No | Only inside `_sync` | Yes M:399 | Yes M:401 |
| increasePosition | Yes | Yes M:420 | No | Only inside `_sync` | Yes M:419 | Yes M:421 |
| decreasePosition | No | Yes M:771 | No | Only inside `_sync` | No | Yes M:772 |
| burnPosition | No | Yes M:771 | No | Only inside `_sync` | No | Yes M:772 |
| swap | Yes | Yes M:462 | No | Only inside `_sync` | Yes M:461 | Yes M:463 |
| sendHedgeMargin | Yes | Yes M:493 | Yes M:492 | Only inside `_sync` | No | Yes M:494 |
| returnHedgeMargin (keeper or treasury) | No | No; registered check M:516 | No | Only inside `_sync` | No | Yes M:519 |
| reportHedgeEquity | No; `paused` sets the cap to 0 at M:538 | No; registered check M:535 | No revert; `_freshOk()` read for the cap at M:538 | Only inside `_sync` | No | Yes M:536 |
| chargeFee | Yes | Yes M:554 | Implied by `_trusted` | Yes, reverts StalePrice M:553 | No | Yes M:555 |
| multicall | No | No | No | No | No | No (inner calls apply their own) |

In `_sync`, `_trusted()` only selects the price argument (anchor or 0) and never reverts.

### Roles

| Role | Granted | Revoked / transferred / renounced | Unlocks | Steps |
|---|---|---|---|---|
| Module owner | Constructor `Ownable(c.owner)` M:208; DeploySA passes the new timelock, DeploySA:146 | `transferOwnership` (owner, `_distinct`) then `acceptOwnership` (pending owner); renounce always reverts M:671 | setKeeper, setGuardian, setParams, setPaused (both directions), transferOwnership | Two-step |
| keeper | Constructor M:258; `setKeeper` M:653 | Overwritten by `setKeeper`; no renounce | reportPrice, mint, increase, decrease, burn, swap, sendHedgeMargin, returnHedgeMargin (capped), reportHedgeEquity, chargeFee, multicall | One-step, by owner |
| guardian (module) | Constructor M:259; `setGuardian` M:659 | Overwritten by `setGuardian`, which also bumps `guardianEra` and clears `priceBudget.until` | approvePrice, approveHedgeEquity, setPaused(true) | One-step, by owner |
| guardian (timelock CANCELLER) | TL constructor TL:48 | Only by timelock self-operation `revokeRole`/`grantRole`, or own `renounceRole`. Separate from the module `guardian` slot: `setGuardian` does not touch it | `TL.cancel` for non-self operations | One-step role change through a delayed self-operation |
| Timelock PROPOSER / EXECUTOR / CANCELLER (operator) | TL constructor TL:43 via OZ-TC:127-133; DeploySA passes env `OWNER`, DeploySA:126 | Same as above | schedule, scheduleBatch, execute, executeBatch, cancel (including self-operations) | Same |
| Timelock DEFAULT_ADMIN_ROLE | The timelock itself only, OZ-TC:118 | — | grantRole, revokeRole; `updateDelay` uses a separate self check at TL:67 | — |
| hedgeTreasury | Immutable, M:249; also inside `enforcerTermsHash` M:256 | None | returnHedgeMargin with no equity cap; only allowed recipient of hedge transfers (ENF:331) | Immutable |
| feeRecipient | Immutable, M:250 | None | No function; fee transfer recipient (ENF:338) | Immutable |
| Client account `a` / pinned owner `accounts[a].owner` | Set at registration SALib:241. 7702 kind: owner is the EOA itself (SALib:183). Hybrid kind: `owner()` accepted only if it re-derives the CREATE2 address (SALib:186-190) | Overwritten by re-registration; `revoke` sets `revoked`; a later code or owner change makes `live` false (SALib:217-221) | revoke; replace or resume registration; signs the delegation and the onboard permit | — |
| DelegationManager | Immutable in M:236 and ENF:74 | None; third-party contract | Only caller of `ENF.beforeHook` | Immutable |
| PoolManager | Immutable, SX:35 | None | Only caller of `SX.unlockCallback` | Immutable |

`_distinct` (M:681-686) rejects zero, keeper, guardian, hedgeTreasury, feeRecipient, owner, pendingOwner and the module itself for setKeeper, setGuardian and transferOwnership.

### State-changing entry points reachable by an arbitrary caller

- **`M.register`**: first registration of any delegator with a valid signed delegation; the stored, non-revoked delegation is a no-op.
- **`M.onboard`**: registration plus the USDC pull; needs the pinned owner's permit signature.
- **`M.deposit`**: any registered `a`; writes `snapAsset` and `contributed`.
- **`SX.swap`**: writes the caller's own transient record and moves the caller's own funds.
- **`TL.receive`**: accepts ETH.
- **No state**: the three empty enforcer hooks, the timelock token-receiver hooks and `M.renounceOwnership` (always reverts).


---

# Threat Model — catalog answers

| # | Actor → target | Answer |
|---|---|---|
| T1 | Client, direct actions → lower fee base | **Violated: M-1** (fees), M-4 (timing), M-6 (parked deposit). Liquidity adds, removes, transfers and burns are booked once and neutrally apart from the fee term. |
| T2 | Client, account code inside a redemption → snapshot below the real effect | **Violated for the swap: M-2.** LP: bounded by the add's slippage (L-7). Slot0 moves and re-entry: invariant holds — profit depends on the snapshot only. |
| T3 | Client → flow booked at a favourable price | **Violated: M-4, M-6.** |
| T4 | Client → avoid the fee and stay managed | **L-1** (acknowledged L-10 plus a silent variant); M-1 with `subscribe`. |
| T5 | Keeper → fee on client principal | **Violated: M-3, M-4, M-5**; L-2 (hedge report). |
| T6 | Keeper → value leak to the pool | Bounded as designed; the size is stated in L-10. |
| T7 | Keeper → margin beyond the cap, misstated equity | Invariant holds for sends (cap on max(equity, netMargin), verified transfer). L-15 (destination of returns), L-2. |
| T8 | Pool-spot manipulator → trust predicates | **Violated: M-3** (make trusted), **L-3** (make untrusted). |
| T9 | Relayer / anyone → unwanted registration, pull, deposits | First registration needs the client's signature (I-14). L-5, L-6 for the pull. Deposits are booked at face value and cannot change profit (I-7). |
| T10 | Guardian → raise equity, free the anchor, block unpause | Approvals are one-shot, bound to epoch, era and value, and expire: invariant holds. L-12 for the veto. |
| T11 | Owner → weak parameters | Hard bounds hold in `_setParams`; L-10 gives the worst product; L-11, L-13, L-14. |
| T12 | DelegationManager pause holder → stop keeper actions | Client exit never needs a redemption: invariant holds (I-17; hybrids exit through the EntryPoint, L-16). |
| T13 | Anyone calling SwapExecutor → forge another payer's record | Invariant holds: the record is written only for `msg.sender` after its own swap; the executor holds nothing between calls; the callback needs PoolManager and the guard. The record's content is the problem (M-2). |
| T14 | Anyone → consume enforcer limits | Invariant holds: `beforeHook` is DelegationManager-only and requires the redeemer named in the terms; state is keyed by (delegator, terms). |
| T15 | Deployment front-runner → wrong framework code, bad first anchor | CREATE2 addresses commit to the init code; front-running only makes a deployment step revert. L-16, I-11. |
| T16 | hedgeTreasury → shift value into an account | Trusted operator address by design; a return above equity is profit for that account. Examined, no issue. |

# Invariant Verification

Inferred invariants from the pre-scan (`I` single-contract, `X` cross-contract, `E` economic). Guards (§1 of the catalog) are per-call preconditions and are not listed.

| ID | Property | On-chain | Verdict |
|---|---|---|---|
| I-1 | live − snapshot equals the client's flow; every module snapshot write equals the true effect | No | **violated → M-2**, L-7 |
| I-2 | `sync` values a flow with the same function and price as `value` | No | **violated → M-1** |
| I-3 | `deposit` / `onboard` move `snapAsset` and `contributed` equally | Yes | holds — same amount on both lines of `_book` |
| I-4 | `sendHedgeMargin` moves equity, netMargin and `snapAsset` by the verified amount | Yes | holds — ledger written after the recipient-delta check |
| I-5 | `params` stay in their hard ranges | Yes | holds — single writer `_setParams` |
| I-6 | at most `MAX_POSITIONS` tracked positions | Yes | holds — guard before the only push |
| I-7 | anchor moves at most `refDriftBps` per 24 h unless a guardian range covers the report | Yes | holds — the bound is e^cap as acknowledged; it counts path length (M-7) |
| I-8 | while `_trusted()`, the anchor is within the band of the pool for `minPriceStable` | No | **violated → M-3**, L-3, L-4 |
| I-9 | turnover admitted in any 24 h window is at most the cap | Yes | holds — adds are weighted `slip / (slip + band)` (L-10) |
| I-10 | `max(equity, netMargin) + amount` within the hedge cap at a send | Yes | holds |
| I-11 | `hedgeEquity` stays within the cap relative to value afterwards | No | holds as designed — not enforced after the send; raising equity needs the guardian |
| I-12 | a revoked account is resumed only by the client | Yes | holds — SALib.sol:239 |
| I-13 | a hedge approval is one-shot and bound | Yes | holds |
| I-14 | a guardian price range is one-shot, cleared by pause and guardian change | Yes | holds (I-2 of this report: a repeat pause clears it too) |
| I-15 | one fee per `feeInterval` in the module and per 7 days at the enforcer | Yes | holds — both clocks are written in the same transaction |
| I-16 | the module acts only while the account is live | Yes | holds for keeper actions; `onboard` is not gated (L-6); liveness is not re-checked inside a redemption (I-15) |
| I-17 | fee within feeBps × (profit − hwm) and 20 % of idle USDC | Yes | holds — one raw unit of drift in the capped branch (I-6) |
| I-18 | profit measures only market moves on booked holdings, LP fees and hedge equity | No | **violated → M-4, M-5, M-6** |
| I-19 | roles pairwise distinct and non-zero | Yes | holds for module roles; gaps noted in I-1 and L-14 |
| X-1 | the swap record is (input of the module's call, output of the module's call) | No | **violated → M-2** |
| X-2 | only `SwapExecutor.swap` writes the record, keyed by `msg.sender` | Yes | holds |
| X-3 | the enforcer's fee clock and hedge rate never contradict the module | No | holds — liveness only; no fund effect found |
| X-4 | a redeemed execution was performed by the account as booked | No | **violated → L-7** (increase / decrease / burn), M-2 (swap) |
| X-5 | enforcer accepts only the module in the signed terms; module accepts only its own terms hash | Yes | holds |
| E-1 | no client action changes profit | No | **violated → M-1, M-2, M-4, M-6** |
| E-2 | the fee never exceeds feeBps of the client's real gain | No | **violated → M-3, M-4, M-5**, L-2 |
| E-3 | client tokens leave only to the pool, SwapExecutor, hedgeTreasury and feeRecipient | Yes | holds — enforcer decoding walked, default deny, recipient sentinels rejected |

27 answered: 19 hold, 8 violated, 0 could not verify.

---

# Recommended order of work

1. **M-1** — fee checkpoint in `SABook.sync`. It is the largest fee leak and the simplest to trigger.
2. **M-2** — bind the swap record to the call (`zeroForOne`, `amountIn`, `minOut`, limit; `paid <= amountIn`).
3. **M-4 + M-6 together** — a tight booking band, and profit measured at the booking price with the pool as a gate. One mechanism, two symptoms.
4. **M-5** — a permissionless trusted `sync(a)` and a refusal to transform unbooked flows while untrusted; keeper change to match.
5. **M-3** — a pool sample from an earlier block (or the window-used condition) in `_trusted()`; correct the residual text.
6. **M-7, L-2, L-3, L-4** — anchor budget on net displacement; hedge flag and recency; heartbeat.
7. **K-3** — ledger reconciliation against chain events before any go-live.
8. The remaining Lows, then the comments (I-5).

Because the module has 677 bytes of room, put new logic in `SABook` / `SALib` and add a size check to CI. After the changes, a stateful invariant test of `value − contributed` under random client actions (direct collects, transfers, deposits at displaced anchors, substituted swaps via `SAHostile`) would cover the class that three rounds have now found by hand.

---

*This review was performed by an automated multi-agent pipeline. Automated analysis cannot prove the absence of vulnerabilities, and no guarantee of security is given. No target code was executed in this round. A manual review, a bug bounty and on-chain monitoring are recommended before funds are managed.*
