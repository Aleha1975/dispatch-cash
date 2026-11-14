# Security Audit — Elysium LP smart accounts, round 3 (LeftClaw job 1226)

**Repo:** https://github.com/Aleha1975/dispatch-cash (branch `elysium-lp-sa`)
**Commit:** `ecb6edaeb5dfae50adb6da2897dbce837e068a15` (the client's pin `ecb6eda`; reachable on the remote as `refs/heads/elysium-lp-sa`, checked with `git ls-remote`)
**Deployment:** not deployed. Target chain: Elysium mainnet, chain id 99901.
**Date:** 2026-11-14
**Method:** deep-audit v3 — x-ray pre-scan → context (protocol map, access-control inventory, threat catalog) → breadth (13 ethskills checklists + fix verification + keeper lens) → depth (pashov solidity-auditor V4, 12 attack agents, blind) → reconciliation and coverage gate.

**Scope (as submitted):** `src/sa/LPManagerModule.sol`, `src/sa/SABook.sol`, `src/sa/SALib.sol`, `src/sa/SwapExecutor.sol`, `src/sa/SAWindow.sol`, `src/sa/ElysiumCustodyEnforcer.sol`, `src/sa/vendor/DelegationFramework.sol`, `src/V4PositionMath.sol`, `src/VaultTimelock.sol`, `script/DeploySA.s.sol` (2,094 nSLOC). The keeper (`keeper/elysium_keeper/sa_keeper.py`, `sa_chain.py`) was read only where on-chain safety assumes operator behaviour. The pooled vault is out of scope.

**Severity counts:** 0 Critical · 0 High · 4 Medium · 22 Low · 8 Informational

---

## 1. Summary

**The structural flow-booking claim does not hold as written.** `SABook.value` and `SABook.sync` are not the same function: `value` counts uncollected LP fees, `sync` has no fee term. A client who collects the fees of a tracked position directly on PositionManager turns that fee income into a "contribution", and `profit` falls by the full amount (M-1). All 12 blind attack agents found this independently, as did 5 phase-1 agents. It is the round-2 item I-2, which the response acknowledged with a bound that is not correct, and whose stated mitigation ("the keeper collects before `chargeFee`") is not in the keeper.

The rest of the claim held up under attack:

- The module's computed effect of an LP add or removal equals what PositionManager and PoolManager do, to the wei, when the account runs the call it is given (section 4, Task 1 item 1).
- What a hostile account does inside a bracket (move slot0, skip the call, pre-mint the token id, trade in `receive`) ends as a flow that is neutral at the anchor or that harms only that account. The one record anomaly is the missing swap direction (L-4).
- No flow is booked twice.

Three more Medium findings concern price trust, not the books:

- One `reportPrice` can use the whole 24 h anchor budget, and swaps and LP adds need no stable anchor. A stolen keeper key that also moves the thin pool can trade every account about 10% off-market in one transaction (M-2).
- `_trusted()` reads the pool only at the moment of the call. A keeper can push the pool, report, wait 300 s, push again and charge a fee on a gain sized by the drift window, not by the band. The round-2 L-16 fix is partial and the stated residual (0.11%) is too low by an order of magnitude (M-3).
- One-price booking lets a client time HYPE flows against the visible gap between anchor and market and raise `contributed` for free. Rebuttal 1 does not hold (M-4).

No finding lets a third party take client funds directly. Custody held: the enforcer's recipient whitelist was checked against the PositionManager source and no allowed execution names a third-party recipient.

**What was not done.** No code was executed: the audit policy for this pipeline forbids building or running target code, so the Foundry suites were not run. The client asked for execution "if policy allows"; it does not. Concrete traces are attached in place of test runs, and the one test in this report is an untested sketch. Dependency behaviour was read from source at the pinned commits (OpenZeppelin v5.4.0, v4-periphery `c6e4754`, v4-core `59d3ecf`, Permit2, Delegation Framework v1.3.0 `bfbdf97`), not from memory. Not verifiable offline: the USDC implementation on chain 99901, the deployed bytecode of the v4 and framework contracts, the ArbOS version, and who controls the DelegationManager owner address.

**Reconciliation summary:** Overlap: 7 · Phase-1-only: 25 · Phase-2-only: 4 · Re-examined leads kept: 27, demoted: 2 · Coverage holes closed: 1 · Invariants: 28 answered (17 hold, 11 violated, 0 unverified). Reporting floor: Low severity and above are findings; anything below confidence 50 is listed under Leads.

---

## 2. Round-2 findings — status

| ID | Round-2 title (short) | Claimed | Status this round | Evidence |
|---|---|---|---|---|
| H-1 | Flows booked at a manipulable price | Fixed | **Partly fixed** | Booking at the anchor only while trusted (`LPManagerModule.sol:735`), registration books nothing, fee on min of two values (`:565`). The three reported paths are closed. A flow still books up to the band away from the market, now in both directions (M-4, L-1) |
| M-1 | Skipped / altered LP add booked from balances | Fixed | **Fixed** | Computed effect in `_add` (`LPManagerModule.sol:761-766`); one-record rule for swaps (`:478`). Caveat: L-4 |
| M-2 | Removal proceeds hidden inside the bracket | Fixed | **Fixed** | `m = burn \|\| liq > snap ? snap : liq;` (`SABook.sol:137`), no read-back |
| M-3 | Standing allowance used by `onboard` | Fixed | **Fixed** (caveat L-7) | `SALib.sol:277-292` |
| M-4 | Clip flag latched; guardian range burned | Fixed | **Partly fixed** | View-based clip (`LPManagerModule.sol:307-309`), range used only when the move exceeds the room (`SALib.sol:331`). A guardian jump still zeroes the room; the next move above the band blocks sends, fees and bookings for every account (L-2) |
| L-1 | `hedgeClipped` cleared by an equal report | Fixed | **Fixed, with a regression** | `SALib.sol:376`. The flag can now stick (L-3) |
| L-2 | Hedge step cap gated by age only | Fixed | **Fixed** | `LPManagerModule.sol:538` |
| L-3 | First registration accepts any signed delegation | Ack | **Acknowledged — unchanged** | `SALib.sol:239` (see L-14) |
| L-4 | `multicall` revert-data copy and gas | Partly | **Partly fixed** | 256-byte cap (`LPManagerModule.sol:596`); no per-item gas (L-8) |
| L-5 | Band measured against the argument | Fixed | **Fixed** | `LPManagerModule.sol:803` |
| L-6 | Distinctness on the ownership path | Fixed | **Fixed** | `LPManagerModule.sol:676-685` |
| L-7 | Hedge approvals survive a pause | Fixed | **Fixed** | `LPManagerModule.sol:644` |
| L-8 | `DeploySA` preconditions | Fixed | **Fixed** (residue L-13) | `DeploySA.s.sol:99-116`, `:164-178` |
| L-9 | `revoke` + `register` is an on-demand sync | Fixed | **Fixed** | `SALib.register` books nothing |
| L-10 | Account refuses only the fee transfer | Ack | **Acknowledged — unchanged** | L-10 of this report; the operator stop rule is not in the keeper |
| L-11 | No-op path ran every delegation check | Fixed | **Fixed** | `SALib.sol:237` |
| L-12 | Removals depend on the DelegationManager pause | Ack | **Acknowledged — unchanged** | L-17 |
| L-13 | Permit2 allowance and wallet approvals | Partly | **Partly fixed** | Amount-0 resets present; the client's own approvals are still wiped (L-9) |
| L-14 | Swap output above `minOut` unbooked | Fixed | **Fixed** | Booked from the executor record (`LPManagerModule.sol:477-483`) |
| L-15 | No keeper min-out or deadline | Partly | **Partly fixed** | Floor at `:468`; the keeper passes 0 (L-22) |
| L-16 | Walk, fee and walk back in one transaction | Fixed | **Partly fixed** | `:823` blocks the one-transaction form only (M-3) |
| I-1 | Drift bound is e^cap | Ack | Acknowledged — unchanged | |
| I-2 | Client-collected LP fees | Ack | **Not fixed; stated bound incorrect** | M-1 |
| I-3 | Keeper / guardian not excluded as owners | Ack | Acknowledged — unchanged | `SALib.sol:187` |
| I-4 | `ownerOf` reverts on a dirty word | Fixed | **Fixed** | `SALib.sol:207-210` |
| I-5 | 7702 native balance fully spendable | Ack | Acknowledged — unchanged | |
| I-6 | Guardian canceller, rotation text | Ack | Acknowledged — unchanged; the NatSpec still gives the unsafe order (L-11) | `VaultTimelock.sol:20-21` |
| I-7 | Range consumed by a zero move | Fixed | **Fixed** | `SALib.sol:331` |
| I-8 | Owner rotation is a permanent exit | Ack | Acknowledged — unchanged | |
| I-9 | No sequencer-outage handling | Partly | **Partly fixed; not protective after an outage** | L-5 |
| I-10 | `_conserved` tolerance | Obsolete | Not applicable any more | Function removed |
| I-11 | Design notes | Ack | Acknowledged — unchanged | |

Nothing regressed in custody. One direction regressed in H-1: in round 2 a flow could never be booked in the client's favour; now it can (M-4).

### Rebuttals

| Rebuttal | Verdict | Reason |
|---|---|---|
| 1 — book at one price, not min/max | **Does not hold** | The stated reason has the wrong sign: with inflows at the lower and outflows at the higher price a round trip lowers `contributed`; the unbounded farm exists only for the opposite, client-favour variant. "A round trip is exactly zero" is true only when both legs book at the same anchor; `test_H1_Sibling_DepositWithdrawCyclesNetZero` moves the pool between legs but never the anchor. One price opens a free path that a banded min/max would have closed (M-4). Neither design is error-free: min/max costs an honest client up to gap × `feeBps` per flow |
| 2 — computed effects in place of read-back | **Holds, with three caveats** | Skipped, extra and redirected executions, a pool moved inside the bracket, a pre-minted token id, native sweep and refund were traced; each ends as one pending flow. Caveats: uncollected fees have no snapshot term (M-1); the swap record has no direction (L-4); "state the account cannot write" is too strong for slot0 and fee growth, which account code can move after the pre-read (the effect is still neutral) |
| 3 — permit front-run tolerance kept, narrowed | **Holds, with a caveat** | A front-run of `permit` or of `onboard` neither blocks nor redirects. Caveat: a consumed permit can be used once more while its deadline is open (L-7) |

### Acknowledged residuals

| Residual | Stated bound | Verdict |
|---|---|---|
| Client-collected fees; fees of transferred-out positions | "fee income since the last keeper touch; keeper collects before `chargeFee`" | **Not correct.** True per event, not cumulatively: a client who collects shortly before each fee keeps about 100% of LP fee income out of the fee base. The keeper has no collect step (M-1, L-19) |
| Keeper holds the pool displaced for `minPriceStable` | ≈ 0.11% of exposure per fee | **Not correct.** The pool needs to be near the anchor at two instants only, and the displacement is bounded by the drift room (10% at defaults): about 1.5% of base exposure per fee (M-3) |
| Flows pending while the anchor is untrusted | exact, booked later | Exact in quantity, not in price (M-4); stale after an outage (L-5) |
| Mint at `MAX_POSITIONS` may need a trusted sync | self-inflicted | Correct |
| L-3, L-10, L-12, L-4, L-13, L-15, I-5 | as stated | Correct as bounds; see the matching findings for what is still missing |
| I-9 | partly | The stability window gives no protection after an outage (L-5) |

---

## 3. Findings

Each finding carries a severity (cost if real) and a confidence in brackets (how sure we are it is real). Origin tags: `[phase1: <lens>]`, `[phase2: agent N]`, `[both]`.

### Medium

#### M-1. `sync` books LP fees that the client collects as a contribution — the structural claim is false for fees

**Severity:** Medium · **Confidence:** [95] · **Origin:** [both] — phase 1: general, precision-math, defi-amm, fix-verification A, keeper lens; phase 2: all 12 agents
**Location:** `src/sa/SABook.sol:52-64` `sync()`, `src/sa/SABook.sol:96-100` `value()`

`value` counts the uncollected fees of every owned position:

```solidity
// SABook.sol:99-100
val += V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, price, v.baseIsCurrency0) + fa
    + Math.mulDiv(fb, price, WAD);
```

`sync` books idle deltas and liquidity deltas only. It has no fee term:

```solidity
// SABook.sol:52
int256 f = x - s.snapAsset + _mul(b - s.snapBase, price);
// SABook.sol:59
if (liq != old) {
// SABook.sol:77
s.contributed += f;
```

When the module collects (`_add`, `_remove`), `lpAdd` / `lpRemove` put the fees into the snapshot (`dAsset = int256(pa + fa);`, `SABook.sol:141`), so they stay profit. When the client collects, nothing puts them into the snapshot, so `live − snapshot` rises by the fees and `sync` books them as a client flow. `value` does not move (the fees went from "uncollected" to "idle"). `profit = value − contributed` falls by exactly the collected fees, permanently.

The client can do this with a canonical account and a plain call: it owns the NFT, PositionManager's `_decrease` is `onlyIfApproved(msgSender(), tokenId)`, and v4 allows a zero-liquidity modify on a position that has liquidity (`Position.sol:86` reverts only `if (liquidity == 0)`); PoolManager pays `callerDelta = principalDelta + feesAccrued` (`PoolManager.sol:171`). Any direct increase or decrease has the same effect, because every modify pays the fees. Moving the NFT out is a second path with the same root cause: `sync` books only `−liquidityValue(old)`, and the uncollected fees leave `value` with no matching outflow.

**Trace** (anchor 30 USDC per HYPE, `feeBps` 1500):

1. `contributed = 100,000e6`. Idle plus principal are worth `100,000e6`. The position holds `1,000e6` USDC + `33.33e18` HYPE of uncollected fees. `value = 102,000e6`, profit `2,000e6`, fee due `300e6`.
2. The client's account calls `PositionManager.modifyLiquidities` with `DECREASE_LIQUIDITY(tokenId, 0, 0, 0, "")` + `TAKE_PAIR(c0, c1, account)`. Idle rises by the fees; liquidity is unchanged.
3. The keeper calls `chargeFee`. `_sync` computes `f = 1,000e6 + _mul(33.33e18, 30e6) ≈ 2,000e6`; `contributed = 102,000e6`; `value` is still `102,000e6`; profit is 0; `hwmFee` returns 0.
4. The client repeats this before every fee (the due time `lastFeeTime + feeInterval` is public). LP fee income, the main yield of a hedged LP account, never pays the performance fee.

**Regression test (untested sketch; not run under audit policy — adapt the pool-key and address names to `SATestBase`):**

```solidity
function test_R3_ClientCollectedFeesLeaveProfit() public {
    (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
    _volume(200_000, 10);                 // LP fees accrue
    _stable(); _syncTouch(a);
    int256 p0 = _profit(a);               // includes the uncollected fees
    bytes[] memory ps = new bytes[](2);
    ps[0] = abi.encode(id, uint256(0), uint128(0), uint128(0), bytes(""));   // DECREASE_LIQUIDITY, 0 liquidity
    ps[1] = abi.encode(address(0), address(usdc), a);                         // TAKE_PAIR -> account
    bytes memory unlock = abi.encode(abi.encodePacked(uint8(0x01), uint8(0x11)), ps);
    _clientExec1(ALICE_PK, a, POSM_ADDR, 0,
        abi.encodeWithSignature("modifyLiquidities(bytes,uint256)", unlock, block.timestamp));
    _stable(); _syncTouch(a);
    assertEq(_profit(a), p0, "a fee collect by the client must not change profit");  // fails today
}
```

**Impact.** The operator loses the performance fee on LP fee income of any client who collects directly; no client funds are at risk. It also falsifies the claim "only market moves on booked holdings, LP fee growth and hedge equity change profit".

**Smallest fix.** Give `sync` the term `value` has. Keep a fee-growth checkpoint per tracked position, write it at every sync and after every module modify, and take the fees that left the position outside a module action out of the booked flow:

```diff
             uint128 old = snapLiq[p.tokenId];
+            // fees that left the position outside a module action are yield, not a client flow
+            (, uint256 l0, uint256 l1) =
+                v.pm.getPositionInfo(v.id, address(v.posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
+            unchecked {
+                uint256 c0 = FullMath.mulDiv(l0 - snapFee0[p.tokenId], old, 1 << 128);
+                uint256 c1 = FullMath.mulDiv(l1 - snapFee1[p.tokenId], old, 1 << 128);
+                (uint256 cb, uint256 ca) = v.baseIsCurrency0 ? (c0, c1) : (c1, c0);
+                f -= int256(ca) + int256(Math.mulDiv(cb, price, WAD));
+            }
+            snapFee0[p.tokenId] = l0;
+            snapFee1[p.tokenId] = l1;
             if (liq != old) {
```

For a position the account no longer owns, also subtract the fees that were uncollected at the checkpoint. This is exact for one client modify at the old liquidity; several client modifies at different liquidity between two syncs need the per-modify liquidity, so treat the remainder as an explicit, documented approximation. The module is 677 bytes under EIP-170, so the new storage and code belong in `SABook`. Until then, a keeper collect on a short cadence reduces the leak to one cadence of fees; it does not close it.

---

#### M-2. One report can use the whole anchor budget, and swaps and LP adds need no stable anchor

**Severity:** Medium · **Confidence:** [70] · **Origin:** [phase1: oracles, defi-amm] (phase 2 raised the budget-extraction lead without the one-step walk)
**Location:** `src/sa/SALib.sol:326-343` `movePrice()`; `src/sa/LPManagerModule.sol:375-387` `reportPrice()`, `:831-836` `_checkKeeperPrice()`, `:453-485` `swap()`

The anchor's only market reference is the same pool's spot price at the instant of the call (`_checkPoolBand(price);`, `LPManagerModule.sol:376`). A single report may use the entire 24 h window, because a move equal to the room is not clipped:

```solidity
// SALib.sol:329-330
uint256 room = SAWindow.room(b.window, capWad);
bool clipped = move > room;
```

`swap`, `mintPosition` and `increasePosition` then gate only on `_checkKeeperPrice` (keeper price within the band of the pool and of the anchor). They do not require `_trusted()`, `minPriceStable`, or any anchor age. The swap's floor and price limit are derived from the anchor that was just moved (`:467-471`). So the drift window bounds magnitude, not time: the guardian gets no reaction window.

**Trace** (stolen keeper key; defaults: drift 1000 bps, band 150, slippage 150, turnover 20000 bps; market and anchor at P):

1. Burn the accounts' positions (`burnPosition` has no price gate), which leaves each account about half USDC, half HYPE.
2. Buy HYPE in the pool until spot is 1.10·P. On roughly 150k USD per side this needs a few thousand USD; the attacker gets it back in step 5.
3. `reportPrice(1.10·P)`: inside the pool band; `move = 0.1e18 == room`, applied unclipped.
4. For each account: `swap(a, false, idleUSDC, 1.10·P, 0)`. The keeper price is in band of pool and anchor; the floor is `fair × 0.985`; the limit is the anchor plus the band. The account buys HYPE at about 1.10·P from the attacker's liquidity or inventory. Steps 3 and 4 fit in one `multicall`.
5. The attacker unwinds. Each account lost about 9% of the USDC it swapped — about 4–5% of NAV for a 50/50 account, for every account, with the gain going to the attacker. Another 10% is available every 24–27 h, mirrored on the sell side.

The keeper is a hot key and "keeper honesty within the bounds" is out of scope; this finding is about what the bounds are. Round 2 accepted "drift + band" as the M-7 residual. The new facts are that the whole drift is available in one step and that the value-moving actions do not wait for the stability window that the fee waits for.

**Smallest fix.** Apply the stability gate to value-moving actions, and cap one step:

```diff
     function _checkKeeperPrice(uint256 price) internal view {
         _checkPoolBand(price);
         uint256 ref = lastPrice;
         if (ref == 0) revert NoAnchor();
         if (_off(price, ref)) revert BadPrice();
+        // a moved anchor is usable for swaps / adds only after the guardian had time to react
+        if (block.timestamp < lastPriceMoved + params.minPriceStable) revert StalePrice();
     }
```

and in `movePrice` limit a single keeper-only step to `poolBandBps` (larger moves need the guardian range). This turns the one-transaction attack into a multi-step walk with a pause window at each step. A reference that a same-block push cannot move (a second signer for moves above one band, or a pool-independent price) is the stronger fix; a v4 pool without hooks has no built-in oracle.

---

#### M-3. `_trusted()` reads the pool only at the call: a fee can be charged on a gain sized by the drift window (L-16 partly fixed)

**Severity:** Medium · **Confidence:** [70] · **Origin:** [phase1: oracles, defi-amm, fix-verification A and B]
**Location:** `src/sa/LPManagerModule.sol:814-824` `_freshOk()` / `_trusted()`, `:552-574` `chargeFee()`

```solidity
// LPManagerModule.sol:816-817
return ref != 0 && block.timestamp <= lastPriceTime + params.maxPriceAge && !_off(ref, lastReported)
    && !_off(ref, poolPrice());
// LPManagerModule.sol:823
return _freshOk() && block.timestamp >= lastPriceMoved + params.minPriceStable;
```

The NatSpec says "a displaced anchor must be held against the pool for that long". The code does not enforce it. Nothing observes the pool between the anchor move and the fee; the pool must be within the band of the anchor at two instants only. And `profit = min(value(anchor), value(pool)) − contributed` (`:565`) protects against an anchor above the pool, not against both being displaced.

**Trace** (defaults; an account with 50,000 USD of HYPE exposure and a fee due):

1. Tx 1: push the pool to 1.10·P, `reportPrice(1.10·P)` (one step, as in M-2), let the pool return.
2. Wait 300 s. No report is needed (`maxPriceAge` is 3600 s). If hedge equity is non-zero, `reportHedgeEquity(a, sameValue)` refreshes `hedgeTime`.
3. Tx 2: push the pool to within 1.5% of 1.10·P, `multicall([chargeFee(a_1) … chargeFee(a_N)])`, let it return. `_freshOk` and `_trusted` pass; `_sync` books every pending flow at 1.10·P; both valuations are about 10% high on the HYPE exposure.
4. Phantom profit ≈ 5,000 USD; fee ≈ 750 USD (1.5% of exposure), capped at 20% of idle USDC. `hwm` advances; there is no clawback when the anchor walks back.

The proceeds go to the immutable `feeRecipient`, so a thief with only the keeper key gains nothing; this is over-charging by the operator role, bounded far above the documented 0.11%. `multicall([reportPrice(new), chargeFee])` does revert, which is all `test_H1_Sibling_WalkAndChargeInOneTransaction` asserts.

**Smallest fix.** The M-2 step cap bounds this to one band per stability window. In addition, require that the pool was seen in band at a second, later observation before a fee, for example a `reportPrice` of the unchanged anchor at least `minPriceStable / 2` after the move. At minimum, restate the residual as drift room × base exposure × `feeBps`.

---

#### M-4. One-price booking lets a client raise `contributed` by timing HYPE flows against the anchor (Rebuttal 1 does not hold)

**Severity:** Medium · **Confidence:** [65] · **Origin:** [both] — phase 1: fix-verification A, precision-math, oracles; phase 2: agent 3 (lead)
**Location:** `src/sa/LPManagerModule.sol:735` `_sync()`, `:822-824` `_trusted()`; `src/sa/SABook.sol:52` `sync()`

```solidity
// LPManagerModule.sol:735
SABook.sync(accounts[a], _positions[a], snapLiquidity, a, venue, _trusted() ? lastPrice : 0);
```

A flow is booked at the anchor whenever the anchor is trusted, and `_trusted()` allows the anchor up to `poolBandBps` (1.5%) from the pool and requires it to be at least `minPriceStable` old. Booking is neutral at that instant only. When the anchor later converges to the market, the booked HYPE reprices and profit moves by `q × (anchor − market)`. The client decides whether a flow is pending when a sync happens, and it can read `lastPrice`, `lastPriceMoved`, the pool price and the keeper's cadence on-chain. There is no loss leg: if no sync falls between the two moves, the net flow is zero. The size `q` is not tied to the account's managed capital, and a canonical account can do it with plain transfers.

**Trace** (market and pool 30.00; anchor held at 30.30, in band and stable):

1. The client sends 10,000 HYPE to the account. The next keeper sync books `contributed += 303,000`.
2. The keeper reports 30.00. After the stability window the client takes the 10,000 HYPE out; the next sync books `contributed −= 300,000`.
3. Net: `contributed` +3,000 USD with no capital change. 450 USD of fee is shielded. If the out-leg lands on an anchor below the market, the gain is up to twice the band per round trip.

The mirror hits the client: a keeper inside its bounds can report at the low edge of the band, wait, and sync a client's HYPE deposit, which creates band × flow of phantom profit at no pool cost.

How often the client finds a keeper sync between the two moves depends on the keeper's cadence, which is why the confidence is moderate. The keeper as written makes pending periods long (L-21).

**Smallest fix.** Book base and liquidity deltas at the price that is worse for whoever chose the flow, with both prices already inside the band:

```diff
-        SABook.sync(accounts[a], _positions[a], snapLiquidity, a, venue, _trusted() ? lastPrice : 0);
+        // inflows at the lower, outflows at the higher of the anchor and the pool price
+        SABook.sync(accounts[a], _positions[a], snapLiquidity, a, venue, _trusted() ? lastPrice : 0, poolPrice());
```

The exploit then needs the pool displaced in the same direction at the booking moment. The cost is a bias against an honest client of at most gap × `feeBps` per flow. This is the banded form of the round-2 recommendation; the farm that Rebuttal 1 describes belongs to the opposite (client-favour) variant.

---

### Low

#### L-1. `chargeFee` measures profit at the pool price but `sync` books flows at the anchor

**Severity:** Low · **Confidence:** [75] · **Origin:** [both] — phase 1: precision-math, oracles; phase 2: agents 7 and 8 (findings), 2, 4, 5, 10, 11 (leads)
**Location:** `src/sa/LPManagerModule.sol:562-568` `chargeFee()`

```solidity
// LPManagerModule.sol:565
int256 profit = int256(vp < v ? vp : v) - s.contributed;
```

`contributed` holds base flows at the anchor A; `vp` values the same base at the pool price P. While P < A (allowed up to the band), each HYPE the client parks in the account raises `contributed` by A and the measured value by only P. Example: A = 40.00, P = 39.42 (in band). The client sends 10,000 HYPE before the keeper's `chargeFee`: `contributed` +400,000, `vp` +394,200, measured profit −5,800 USD. In general a deposit of `profit / gap` of HYPE takes the fee to zero; `if (f == 0) return 0;` (`:568`) writes nothing. The client then takes the HYPE out (booked at the anchor, neutral). This defers the fee; it becomes a loss only if the client repeats it at every attempt or exits. A direct LP removal while P < A has the same sign.

**Fix (Option A — restrict):**

```diff
-        int256 profit = int256(vp < v ? vp : v) - s.contributed;
+        // flows are booked at the anchor: charge only when the pool does not value the account lower
+        if (vp < v) revert StalePrice();
+        int256 profit = int256(v) - s.contributed;
```

**Fix (Option B — allow-and-handle):** the M-4 change (book inflows at the lower of anchor and pool) removes this as well.

#### L-2. The anchor budget charges path length, and a guardian jump zeroes the room (M-4 partly fixed)

**Severity:** Low · **Confidence:** [60] · **Origin:** [phase1: oracles, fix-verification A]
**Location:** `src/sa/SALib.sol:328-341` `movePrice()`; `src/sa/LPManagerModule.sol:814-818`

Every move, up or down, is added to the window (`SAWindow.add(b.window, move);`), with no credit for a reversal (the hedge window has one). A day of +4% / −4% / +4% uses the whole 10% budget with no net move. A guardian-approved jump charges `min(move, room)`, which is all of the room (`SAWindow.add(b.window, room);`, `SALib.sol:333`). Once the room is 0 the anchor freezes for 24–27 h. If the market then moves more than 1.5%, `_freshOk` is false for every account: no `sendHedgeMargin`, no fee, no booking, hedge-decrease cap 0. Beyond about 3% of lag `_checkKeeperPrice` cannot be met and swaps and adds stop too. These are the moments when a short hedge needs margin. Removals, margin returns and client exits stay live. The project's own tests assert the remaining block (`test_M7_Sibling_GuardianRangeOneShot`).

**Fix.** Charge net displacement (credit an opposite move, as `SAWindow.credit` does for the hedge window). Let `sendHedgeMargin` run while the anchor is only clipped, with the cap sized on `min(value(anchor), value(pool))`.

#### L-3. `hedgeClipped` can stay set and block the account's fee (regression of the L-1 fix)

**Severity:** Low · **Confidence:** [80] · **Origin:** [phase1: fix-verification B, keeper lens, oracles]
**Location:** `src/sa/SALib.sol:376-387` `moveHedge()`; `src/sa/LPManagerModule.sol:538`, `:559`

```solidity
// SALib.sol:376
if (v >= old) return (old, v != old); // SA-2 L-1: an equal / higher report never clears hedgeClipped
// SALib.sol:381
s.hedgeClipped = clipped;
```

With cap 0 (paused, anchor not fresh, window full, or `hedgeStepBps == 0`), any lower report sets the flag and applies nothing. If the real equity then returns to or above the stored value, every honest report takes the `v >= old` branch and the flag stays. `chargeFee` reverts `StaleHedge` (`:559`) for as long as `hedgeEquity != 0`. The flag is not cleared when equity is paid down to 0 either. A third party can cause the first step by holding the pool 1.5% from the anchor during one keeper report (L-6). The shipped keeper re-reports the stored value when the ledger is within 0.5% of it and logs `fee_waits_hedge` with no guardian alert (`keeper/elysium_keeper/sa_keeper.py:360-362`, `:328`).

**Fix.** Do not set the flag when `cap == 0` because the anchor is not fresh (return without a state change), clear it in `returnHedgeMargin` when `amount >= h`, and have the keeper alert the guardian for an approval of the stored value when the flag is set and the ledger is at or above it.

#### L-4. The swap record has no direction; the module assigns the units from its own flag

**Severity:** Low · **Confidence:** [80] · **Origin:** [both] — phase 1: general, precision-math, defi-amm, signatures; phase 2: agent 6 (finding), 1, 2, 4, 5, 7 (leads)
**Location:** `src/sa/SwapExecutor.sol:92-97` `swap()`; `src/sa/LPManagerModule.sol:477-483` `swap()`

```solidity
// LPManagerModule.sol:478
if (n1 != n0 + 1 || got < minOut) revert BelowMinOutOrBadSwap(got, minOut);
// LPManagerModule.sol:482-483
if (sellBase) _apply(a, go, pi);
else _apply(a, pi, go);
```

The record holds (count, paid, out) only. Account code with a replaced implementation can skip the module's swap and make one swap of its own in the other direction; the check compares raw numbers across 6- and 18-decimal units.

- Module sells base (`minOut` in USDC units): the reversed swap's `got` in wei passes. The module books wei as USDC into `snapAsset`; the next sync collapses `contributed` and that client's own fee base explodes. Self-harm.
- Module buys base (`minOut` in wei): the reversed swap's `got` in USDC units passes only for a keeper `amountIn` of a few raw units. A keeper that colludes with the account can send `amountIn = 1` and make `contributed` astronomically high, after which no fee can ever be charged on that account. A colluding keeper could also simply not charge; the point is that the damage outlives a keeper rotation.

We found no path that gains for a client alone. It is a latent break of "the record describes the module's swap".

**Fix.** Record the direction and the requested input, and require them:

```diff
+            tstore(add(k, 3), or(shl(255, zeroForOne), amountIn))
```

and in the module revert unless the recorded direction equals `sellBase == baseIsCurrency0` and the recorded input equals `amountIn`.

#### L-5. A stale anchor is trusted at once after a sequencer or keeper gap; swap paths accept an anchor of any age

**Severity:** Low · **Confidence:** [60] · **Origin:** [phase1: fix-verification A, oracles]
**Location:** `src/sa/LPManagerModule.sol:816`, `:823`, `:831-836`

`_trusted()` asks that the anchor value be unchanged for `minPriceStable`; an outage satisfies that by itself, and the pool is as stale as the anchor, so it is in band. For any gap between 300 s and `maxPriceAge` (3600 s), the first sync after restart books pending flows at the pre-outage anchor and `chargeFee` passes its price gate. `_checkKeeperPrice` never reads `lastPriceTime`. There is no sequencer feed on this chain (round-2 I-9).

**Fix.** Require a recent re-confirmation as well: `block.timestamp <= lastPriceTime + minPriceStable` in `_trusted()` (reporting the stored value refreshes `lastPriceTime` without resetting `lastPriceMoved`), and an age check in `_checkKeeperPrice`.

#### L-6. A third party that holds the pool outside the band stops reports, fees, margin sends, bookings and hedge decreases

**Severity:** Low · **Confidence:** [60] · **Origin:** [phase1: oracles]
**Location:** `src/sa/LPManagerModule.sol:806-818`, `:538-541`

A displacement above 1.5% from the anchor makes `reportPrice(market)` revert `PoolPriceOff`, makes `_sync` a no-op, makes `chargeFee` and `sendHedgeMargin` revert, and runs `reportHedgeEquity` with cap 0 (which sets `hedgeClipped`, L-3). On about 150k USD per side that takes on the order of a thousand USD of notional, at a running arbitrage cost. The third party cannot choose a booking price and cannot make the state permanent. Decrease, burn, `returnHedgeMargin` and `revoke` stay live.

**Fix.** L-3's "no flag at cap 0" removes the lasting part. Document the guardian range as the liveness path.

#### L-7. A consumed onboarding permit can be used again while its deadline is open

**Severity:** Low · **Confidence:** [75] · **Origin:** [both] — phase 1: signatures, erc20, fix-verification A; phase 2: agent 6 (lead)
**Location:** `src/sa/SALib.sol:278-291` `pull()`

```solidity
// SALib.sol:289
if (err != ECDSA.RecoverError.NoError || signer != o || IERC20(asset).allowance(o, address(this)) != amount) {
```

The fallback cannot tell "front-run, not yet pulled" from "already pulled by an earlier `onboard`". After a normal `onboard` the nonce stays at `n` until the owner signs another USDC permit; `approve` does not move it. If the owner later approves the module for the same amount (the normal precondition of `deposit`), anyone can call `onboard` with the calldata of the first transaction (`_register` is a no-op for the stored delegation) and pull that allowance into the owner's own account. Funds only move from the owner to the owner's account, so this is an unintended, attacker-timed contribution, not theft. It contradicts "a standing allowance from `approve` is never used" (`SALib.sol:273`).

**Fix.** Make each permit usable once by the module: store the last nonce seen per owner and require `nonces(o) > seen` on both paths, or keep a `usedPermit[digest]` mapping.

#### L-8. `multicall` forwards all gas to each item (L-4 partly fixed)

**Severity:** Low · **Confidence:** [70] · **Origin:** [phase1: signatures+assembly, erc4337, dos]
**Location:** `src/sa/LPManagerModule.sol:589` `multicall()`

```solidity
ok := delegatecall(gas(), address(), r, c.length, 0, 0)
```

Inside an item, the DelegationManager calls the account's `isValidSignature` with no gas cap, once per execution (`DelegationManager.sol:176`), then `executeFromExecutor`. A hybrid owner can replace the implementation and keep `owner()`, so `SALib.live` still passes. Code that burns gas only on-chain (it can branch on `tx.gasprice` or `block.coinbase` so the keeper's simulation passes) consumes 63/64 of the remaining gas; with `allowFailure = true` the later items fail on the remainder. The keeper pays the full gas limit and other clients' actions in that batch are delayed. No funds move. The shipped keeper does not use `multicall`.

**Fix.** A per-item gas argument: `delegatecall(itemGas, …)` with `itemGas == 0` meaning all gas.

#### L-9. Approval set and reset through the account removes the client's own Permit2 approvals (L-13 partly fixed)

**Severity:** Low · **Confidence:** [75] · **Origin:** [phase1: erc20, fix-verification B]
**Location:** `src/sa/SALib.sol:476-492` `modify()`, `:516-520` `swapVia()`

Every USDC leg sets `token.approve(Permit2, amount)` and a Permit2 allowance, then writes both to 0. For a 7702 account this is the client's everyday wallet: a standing `USDC.approve(Permit2, max)` and the wallet's own Permit2 allowance to PositionManager are 0 after each keeper action. The enforcer allows only `amount <= balance` (`ElysiumCustodyEnforcer.sol:191`), so the module cannot restore the old value. No funds are at risk; the client's direct use of Permit2 fails until it approves again.

**Fix.** Build the two ERC-20 `approve` executions only when the existing allowance is below the amount, and rely on the Permit2-level allowance (same-timestamp expiry, reset to 0) as the per-action bound; or state that the account must be dedicated.

#### L-10. `live` pins only the owner of a hybrid account: replaced code can refuse only the fee (round-2 L-10, unchanged)

**Severity:** Low · **Confidence:** [70] · **Origin:** [both] — phase 1: general, erc4337; phase 2: agent 6 (lead)
**Location:** `src/sa/SALib.sol:214-221` `live()`, `:536-537` `transferOut()`

```solidity
// SALib.sol:220
return ownerOf(a) == s.owner;
```

The comment says "the account's code / owner unchanged since registration (L-14: a change is a revocation)". For a hybrid account only the owner is checked. `upgradeToAndCallAndRetainStorage` (`DeleGatorCore.sol:383`) keeps the owner. New code can run every module execution except `transfer(feeRecipient, …)`, or send one extra unit to the recipient inside the bracket (the recipient check is exact equality, `SALib.sol:537`), so `chargeFee` always reverts while management continues. The operator rule the response proposed (stop managing after two failed fees) is not in the keeper. An on-chain implementation check cannot be trusted either (`getImplementation()` is answered by the account), so treating account code as hostile is the right design.

**Fix.** Correct the comment and the client documentation; implement the off-chain stop rule, or a per-account "fee overdue" flag that blocks risk-adding actions.

#### L-11. Guardian rotation as documented can be vetoed by the outgoing guardian

**Severity:** Low · **Confidence:** [75] · **Origin:** [phase1: governance]
**Location:** `src/VaultTimelock.sol:20-21`, `:130-133`

```solidity
///           Guardian rotation = two operations: (1) a timelock-only batch `revokeRole/grantRole(CANCELLER)`,
///           (2) `vault.setGuardian(new)` (the old guardian no longer holds CANCELLER when it becomes ready).
```

OpenZeppelin `cancel` accepts any pending operation, waiting or ready (`TimelockController.sol:333-340`). Operation (2) is not a self-operation, so the old guardian can cancel it at any moment before (1) executes. The only sequence that works against a hostile guardian is: schedule (1), wait, execute, then schedule (2), wait again — 2 × delay (96 h at the script default, 60 days at `MAX_DELAY`). During that time the old key can pause again after any unpause and keeps `approvePrice` / `approveHedgeEquity`. Removals, margin returns and client exits keep working.

**Fix.** Correct the comment ("schedule (2) only after (1) has executed") and document the 2 × delay bound; or exempt `setGuardian` operations from the guardian's veto.

#### L-12. The per-operation timelock delay has no upper bound, and expired operations stay "ready"

**Severity:** Low · **Confidence:** [75] · **Origin:** [phase1: governance]
**Location:** `src/VaultTimelock.sol:73-83`, `:125-128`

The comment says "levers cannot be stockpiled and fired later". `MAX_DELAY` applies to `_delay`, not to the `delay` argument of an operation; OpenZeppelin checks only `delay < minDelay` (`TimelockController.sol:319-322`). The proposer can queue the same call under different salts with staggered delays so that the 7-day windows cover any horizon. Expiry is enforced only inside `execute` (`if (ts > 1 && block.timestamp > ts + GRACE_PERIOD) revert OperationExpired(id);`); `_timestamps[id]` is untouched, so `isOperationReady` stays true and the id cannot be scheduled again until someone cancels it. Everything is visible and cancellable.

**Fix.** In both `schedule` overrides: `if (delay > MAX_DELAY) revert DelayAboveCap();`. Add an `isExpired(id)` view.

#### L-13. `DeploySA` checks only code presence for the venue contracts

**Severity:** Low · **Confidence:** [80] · **Origin:** [phase1: access-control]
**Location:** `script/DeploySA.s.sol:91-97`, `:164-178`

The framework pieces are verified by CREATE2 derivation. PoolManager, PositionManager, Permit2, EntryPoint and USDC are checked for `code.length != 0` only (`:93`), although `test/fixtures/elysium/` holds their runtime hex. Neither the script nor the module constructor checks that the PositionManager is bound to this PoolManager and Permit2. A wrong address with code passes every check; clients then sign terms that name a module whose mints revert, and recovery is a redeploy plus re-signing. Also: only `paused()` is read from the DelegationManager, not its owner; "deep" is `getLiquidity != 0` (`:103`), which one wei satisfies; there are no post-deploy asserts on `module.owner()` or the timelock roles; the derivation probe uses a locally built `Expect`, not the deployed module's getters; `OWNER` is not required to be a contract; the header names `RiskBudgets` and omits `SABook` (`:28`); no test covers the script. The probe after `vm.stopBroadcast()` is fine, because forge simulates all of `run()` before it sends anything.

**Fix.** Compare `keccak256(code)` with the fixtures for the four venue contracts, require `IPositionManager(POSM).poolManager() == PM`, assert `module.owner() == address(timelock)`, and feed the probe from the module's getters.

#### L-14. A signed but unregistered delegation cannot be stopped at the module; a pending owner cannot be cleared

**Severity:** Low · **Confidence:** [65] · **Origin:** [phase1: access-control, signatures]
**Location:** `src/sa/LPManagerModule.sol:357-360` `revoke()`, `:676-686`; `src/sa/SALib.sol:237-239`

(a) First registration is open to anyone, and `revoke` reverts `NotRegistered` for an account that was never registered. A client who signed and handed over a delegation and then changes its mind has no module-level stop; the only stop is `DelegationManager.disableDelegation` from the account, and a counterfactual hybrid account must be deployed first. Until then any holder of the signature can register it, and the keeper can act in the same transaction. (b) `_distinct` rejects `address(0)`, so a mistaken `transferOwnership(n)` cannot be cancelled, only overwritten by another nomination, which costs another timelock round while the wrong nominee can accept.

**Fix.** (a) Let `revoke` set `revoked = true` for an unregistered account when `msg.sender == a`, and require the client for the first registration of a revoked slot. (b) Allow `transferOwnership(address(0))`.

#### L-15. The enforcer bounds recipients, not price

**Severity:** Low · **Confidence:** [80] · **Origin:** [phase1: erc4337]
**Location:** `src/sa/ElysiumCustodyEnforcer.sol:293-301`, `:225-237`, `:265-272`

The header calls the enforcer "the client-visible custody guarantee [that] does not trust the module". Recipients are sound. Economic terms are not checked: `minOut = 1` and any price limit pass (`if (amountIn == 0 || minOut == 0) revert BadAmount();`, `:298`), and liquidity, tick and slippage values of LP actions are decoded only for the canonical check. Not reachable by a keeper today, because the immutable module builds every call. It is the worst case of a module bug: a redeemer limited only by the enforcer could swap a whole balance into a sandwiched pool.

**Fix.** Reword the guarantee to "recipient whitelist, no price protection", or add a cheap backstop: require a non-zero price limit, or a per-24 h swap and LP-add notional window per (delegator, terms hash) like the hedge window.

#### L-16. A margin send the module allows can be refused by the enforcer

**Severity:** Low · **Confidence:** [70] · **Origin:** [phase1: erc4337, precision-math]
**Location:** `src/sa/ElysiumCustodyEnforcer.sol:332-335`; `src/sa/LPManagerModule.sol:498-501`

The module caps the total against account value (`hedgeCapBps` of `accountValue`, `:499`); the enforcer caps the sum of balance fractions per 24 h against idle USDC at the hook (35%). Account value 100,000 with 10,000 idle USDC: `sendHedgeMargin(a, 5_000)` gives a fraction of 50% and reverts, although the module allows 35,000. To send 20% of NAV the keeper must first hold 57% of NAV as idle USDC, which means removing LP and adding it back (turnover, slippage). An urgent top-up of an under-margined hedge can be impossible in one step. Liveness only.

**Fix.** Pre-check the enforcer rule in `sendHedgeMargin` with a clear error and document the keeper-side rule.

#### L-17. A DelegationManager pause halts every keeper action, including removals (round-2 L-12, unchanged)

**Severity:** Low · **Confidence:** [85] · **Origin:** [phase1: erc4337+proxies, dos]
**Location:** `src/sa/SALib.sol:451` `_redeem()`; `src/sa/LPManagerModule.sol:294-297` `isActive()`

`DelegationManager.pause()` is `onlyOwner` (`DelegationManager.sol:74`) and `redeemDelegations` is `whenNotPaused` (`:132`). The owner is a third party (constructor argument `0xB0403B32f54d0Bd752113f4009e8B534C6669f44` in the script). While paused, mint, increase, decrease, burn, swap, margin sends and fees all revert; positions stay in the pool unmanaged while the hedge stays open. `reportPrice`, `reportHedgeEquity`, `returnHedgeMargin`, `deposit`, `register`, `revoke` and client exits still work. `isActive()` still returns true.

**Fix.** Add `&& !delegationManager.paused()` to `isActive`. State in the documentation that removals called "allowed while paused" depend on the DelegationManager. Before launch, find out who controls that owner address on chain 99901.

#### L-18. A USDC blacklist or pause of an immutable recipient breaks the fee and margin-return paths for good

**Severity:** Low · **Confidence:** [60] · **Origin:** [phase1: erc20]
**Location:** `src/sa/LPManagerModule.sol:99-100`, `:520`, `:569`

`hedgeTreasury` and `feeRecipient` are immutable and signed into every client's enforcer terms. `returnHedgeMargin` can only pull from the treasury (`asset.safeTransferFrom(hedgeTreasury, a, amount);`). If the treasury is blacklisted, every margin return and send reverts for all accounts, each account's `hedgeEquity` stays in `value`, and margin returned from another address is booked as a client contribution. If the fee recipient is blacklisted, `chargeFee` reverts for every account, and the only way out is a new module and new delegations.

**Fix.** Accept and document, or add a return path from another funded address restricted to `msg.sender == hedgeTreasury`.

#### L-19. The keeper does not implement the mitigations the response relies on

**Severity:** Low · **Confidence:** [80] · **Origin:** [phase1: keeper lens]
**Location:** `keeper/elysium_keeper/sa_keeper.py:314-352` `fee()`

The response bounds I-2 by "the keeper collects before `chargeFee`" and L-10 by an operator stop rule. The keeper has neither. Its only position call before a fee frees idle USDC when idle is short (`self.act("decreasePosition", a, p.token_id, int(p.liquidity * q), 0, 0)`, `:341`), and `chargeFee` is a separate transaction (`:345`) with RPC reads in between; `multicall` is not used. A client that sweeps idle USDC after the keeper's decrease gets `maxFee ≈ 0`, `f == 0`, and `lastFeeTime` never advances; the keeper then repeats decrease + `chargeFee` every tick, paying gas and unwinding the client's LP.

**Fix.** Collect (`decreasePosition(a, id, 0, …)`) on a short cadence and before every fee; send collect, free-idle and `chargeFee` in one `multicall(…, false)`; implement the stop rule. This limits M-1, it does not close it.

#### L-20. Keeper: permissionless `register` plus unfiltered discovery lets dust accounts stall the tick

**Severity:** Low · **Confidence:** [55] · **Origin:** [phase1: keeper lens]
**Location:** `keeper/elysium_keeper/sa_keeper.py:153-167` `accounts()`, `:466-489` `tick()`; `src/sa/LPManagerModule.sol:326-328`

First registration needs no funds. The keeper adds every `Registered` account for good (`known = self.state.d.setdefault("known_accounts", [])`, `:160`) and processes them one by one, with about 11 `eth_call`s per account read and no minimum-value filter. The anchor is reported once at the start of the tick. With thousands of dust accounts a tick outlasts `maxPriceAge` (3600 s); `_freshOk()` then fails, so margin sends, hedge decreases, booking and fees stop and out-of-range burns are delayed for real clients. The cost to the attacker is gas for N hybrid deployments and registrations. The timing is an estimate; nothing was run.

**Fix.** Skip accounts below a value floor, bound tick time and re-run the anchor report between batches, batch reads.

#### L-21. Keeper: the anchor hold is over-triggered, can abort the whole tick, and is not used for pending flows

**Severity:** Low · **Confidence:** [70] · **Origin:** [phase1: keeper lens]
**Location:** `keeper/elysium_keeper/sa_keeper.py:182-187`, `:316-324`, `:466`

The hold exists and re-reports the stored value. Three problems: (1) `fee()` arms it before it knows a fee exists, and an account past `feeInterval` with no profit above its mark never advances `lastFeeTime`, so one such account re-arms a long hold at every untrusted tick and the anchor tracks the market with about 120 bps of hysteresis; (2) the held value can be outside the pool band when the report is due, `reportPrice` reverts `PoolPriceOff`, and `anchor()` is called outside any `try` (`:466`), so the tick aborts before the account loop and the hedge step; (3) there is no hold for a pending client flow with no fee due, so flows can stay pending for days — which widens M-4.

**Fix.** Arm the hold only when the estimated fee is above 0 or an account has a pending flow; never hold outside the pool band; wrap the report in a `try`.

#### L-22. Keeper passes `minOut = 0` and zero removal minimums (L-15 partly fixed)

**Severity:** Low · **Confidence:** [75] · **Origin:** [phase1: keeper lens, defi-amm]
**Location:** `keeper/elysium_keeper/sa_keeper.py:248`, `:256`, `:341`; `src/sa/LPManagerModule.sol:465-468`

```python
self.act("swap", a, sell_base, chunk, price, 0)
```

The only binding bound is the on-chain floor, 150 bps under `keeperPrice`, of which 30 bps is the pool fee. With the L-21 hold, `keeperPrice` can lag the market by 120 bps, so the floor can sit about 270 bps under the market in one direction. The probe returns the exact simulated output and the keeper discards it. The worst case per swap is about 1.2% of a chunk of at most 1,500 USD, and it needs ordering power on a sequencer chain. `decreasePosition(…, 0, 0)` has no minimums; we found no direct profit for a third party in sandwiching a removal.

**Fix.** Set `minOut` to the probe's output less 10–20 bps; pass minimums on decreases as the burn path does.

---

### Informational

#### I-1. The client controls the fee cap
**Severity:** Informational · **Confidence:** [70] · **Origin:** [both] — phase 1: erc20; phase 2: agents 11, 12 (leads)
`chargeFee` caps the fee at 20% of idle USDC at call time (`LPManagerModule.sol:567`) and `if (f == 0) return 0;` writes nothing. A client that keeps idle USDC near 0 pays no fee until the keeper frees USDC and charges in one `multicall`. Nothing is lost (the mark does not advance), nothing is collected. Inherent to a non-custodial design; see L-19 for the keeper side.

#### I-2. A treasury return above `hedgeEquity` counts as profit
**Severity:** Informational · **Confidence:** [80] · **Origin:** [both] — phase 2: agent 8 (lead); phase 1: erc20 note; x-ray invariant I-5
`_apply(a, int256(amount), 0);` raises the snapshot by `amount` while `hedgeEquity` falls by `min(amount, h)` (`LPManagerModule.sol:521-523`). Only `hedgeTreasury` can return more than `h`. The excess enters the fee base as profit. This reads as realised hedge PnL by design; state it in the documentation, because it is a second `value` term (`hedgeEquity`) that `sync` does not book.

#### I-3. Comments and documents contradict the code after the fixes
**Severity:** Informational · **Confidence:** [90] · **Origin:** [phase1: fix-verification B]
`LPManagerModule.sol:57-58` and `:127` predate the L-7 fix (the era is also bumped by a pause); `:608-609` says an in-range report "is applied unclipped and charged to the window" while the code uses the range only when the move exceeds the room; `ElysiumCustodyEnforcer.sol:36` and `:311` say "this block" for a Permit2 expiration that lasts the whole timestamp (several blocks on Nitro); `VaultTimelock.sol:20-21` keeps the unsafe rotation order; `DeploySA.s.sol:28` names `RiskBudgets`; `SALib.sol:214-216` claims a code change is a revocation.

#### I-4. Signed rounding of the base term moves profit up by at most 1 USDC unit per sync
**Severity:** Informational · **Confidence:** [80] · **Origin:** [phase1: precision-math; phase 2: agent 10 note]
`sync` books `floor((b1 − b0)·p)` with negative deltas toward minus infinity (`SABook.sol:196-201`); `value` moves by `floor(b1·p) − floor(b0·p)`. The flow is at most the value change and at least that minus 1. Against the client, not grindable for gain. No fix needed.

#### I-5. At the `_setParams` maxima a stolen keeper key can take about 50% of NAV per day
**Severity:** Informational · **Confidence:** [55] · **Origin:** [phase1: precision-math, access-control]
At the script parameters the swap bound is about 3% × 200% turnover ≈ 6% of NAV per 24 h (before M-2). At the timelock maxima (band 500, slippage 500, turnover 50,000 bps) it is about 50% per 24 h. Lower the maxima in `_setParams` (`LPManagerModule.sol:689-695`) toward the deployed values if that is not an accepted bound.

#### I-6. HybridDeleGator ERC-1271 is not bound to the account
**Severity:** Informational · **Confidence:** [60] · **Origin:** [phase1: erc4337]
`HybridDeleGator` accepts any hash the owner EOA signed, and Permit2 permit hashes do not contain the owner. A Permit2 permit the owner signs for its own wallet is also valid for the hybrid account while a USDC → Permit2 allowance stands on it. The module always resets that allowance in the same redemption, so there is no path through the in-scope code. Tell clients not to leave a Permit2 approval on the hybrid account.

#### I-7. Profit that accrues while an account is revoked or expired is charged after re-registration
**Severity:** Informational · **Confidence:** [70] · **Origin:** coverage gate (x-ray invariant I-17; neither phase examined it)
`lastFeeTime` is written at the first registration only (`if (old == 0) s.lastFeeTime = block.timestamp;`, `SALib.sol:249`), and books, `hwm` and `contributed` persist across `revoke` and re-registration. Market gains on the account's holdings during a period the module did not manage it are profit at the next `chargeFee`, which can come immediately after re-registration if `feeInterval` has elapsed. Losses carry over the same way. State the rule to clients, or reset the mark (`hwm = profit`) when a revoked account registers again.

#### I-8. Keeper trades pending base, and the status file mixes booked and pending figures
**Severity:** Informational · **Confidence:** [50] · **Origin:** [phase1: keeper lens]
`manage_lp` sizes from live balances, so HYPE a client sent while the anchor is untrusted is swapped or added before it is booked; it is later booked at the anchor of the booking time (symmetric phantom gain or loss; see M-4). The status row shows `contributed` (booked only) next to `profit` (which subtracts pending), with no `pending` field.

---

## 4. Answers to the client's tasks

### Task 1 — the structural flow-booking claim

1. **Is every module write to `snapAsset` / `snapBase` / `snapLiquidity` equal to the true effect, to the wei?** Yes, when the account runs the call it is given.
   - Branch: `Pool.modifyLiquidity` branches on `slot0.tick` (`Pool.sol:209`, `:218`); `SABook._principal` branches on the sqrt price (`SABook.sol:157-163`). They differ only when the price sits exactly on a range tick, and there the extra leg has zero length, so the amounts are equal.
   - Rounding: an add rounds up, a removal rounds down, in both.
   - Fees: `_fees` equals `Position.update` (liquidity before the change, wrapping growth subtraction, Q128 floor). PositionManager nets the fees into the caller delta, so the account gets `fees − principal` on an increase and `principal + fees` on a decrease or burn.
   - Settlement: SETTLE_PAIR pays the full debt (native from PositionManager's balance, USDC through Permit2 for the exact amount); CLOSE_CURRENCY settles or takes principal minus fees; TAKE_PAIR takes the full credit; the final SWEEP returns `max0 − debt`. Stray native in PositionManager is swept to the account and becomes a neutral inflow.
   - Zero liquidity: a zero-liquidity DECREASE on an empty position reverts; BURN skips the modify, and the computed effect is 0.
   - Live ≠ snapshot: a DECREASE above live liquidity reverts in PoolManager (the keeper must read live liquidity when a flow is pending); with client-added liquidity, or a burn with live ≠ snapshot, only `m` is booked and the rest stays one pending flow on both sides.
2. **Can account code make the computed effect differ in the client's favour?** No path found. Moving slot0 inside the bracket, skipping the call, pre-minting the token id, re-entering through `receive` with the PoolManager unlocked: each leaves profit at "pre-computed effect", and the difference is a flow that is neutral at the anchor. PositionManager re-entry is blocked by its locker, `SwapExecutor` re-entry by its guard, and transient record slots cannot collide short of a keccak collision. A second swap makes `n1 != n0 + 1` and reverts. The exception is one swap in the other direction (L-4), which gains only with a colluding keeper.
3. **Is `sync`'s valuation the same function as `value()`?** No. Uncollected fees (M-1). Hedge equity is the second term without a `sync` counterpart; it is handled by the hedge ledger except for a treasury return above equity (I-2). Dropped positions lose their uncollected fees without an outflow (M-1, second path). Positions the client adds are not tracked and not valued. Negative base deltas round against the client by at most 1 unit (I-4). `int256` snapshots below zero are handled by signed arithmetic.
4. **Booked twice or never?** Not twice. "Never" only while the anchor is never trusted; with the keeper as written, pending periods can be long (L-21). A position dropped while pending is handled by `m = snap` on burn. Revoke and re-register keep the books (I-7). `MAX_POSITIONS` with client-burned positions needs one trusted sync and is self-inflicted.
5. **Can the charged profit exceed the real gain?** Yes, with a keeper that moves the pool: M-3 (about 1.5% of base exposure per fee at defaults). `multicall([reportPrice, chargeFee])` reverts. A hedge-equity increase needs the guardian; an equal report refreshes `hedgeTime` and leaves `hedgeClipped` alone.
6. **Rebuttal 1.** Does not hold: M-4 and L-1.

### Task 2 — sibling paths

- A pending flow booked at a price of the client's choosing: M-4; of the keeper's choosing: the mirror in M-4; after an outage: L-5.
- The trusted gate as a liveness problem: for fees and bookings, anyone holding the pool beyond the band (L-6) and every anchor move (300 s closed); for margin sends, a clipped anchor (L-2); for fees, a stuck `hedgeClipped` (L-3). The client's own exit is not affected: `revoke` and direct actions never read the gate.
- Fee avoidance without an upgraded account: M-1, M-4, L-1, I-1. With one: L-10.

### Task 3 — rebuttals and residuals

See section 2.

### Task 4 — lenses requested for this round

| Requested lens | Ran? | Result |
|---|---|---|
| Execute the code / Foundry suites | **No** — audit policy forbids executing target code | Traces attached; one untested test sketch (M-1) |
| SwapExecutor (record, callback, refunds, limit, exact input, reentrancy) | Yes (defi-amm, assembly, general; attack agents) | Sound except L-4. Slots cannot collide with the guard or another payer. The callback needs PoolManager as caller and the guard entered. The record is written after the native refund call; a second swap in `receive` is blocked by the guard |
| Delegation Framework v1.3.0 internals from source | Yes — read at `bfbdf97` | Hook order confirmed (all signatures and disabled flags first, then per execution: custody `beforeHook`, timestamp `beforeHook`, `executeFromExecutor`, after-hooks). DM pause: L-17. `upgradeToAndCall` clears the owner, `…RetainStorage` keeps it: L-10. 7702 pinned by codehash. ERC-1271 without a gas cap at redemption: L-8. Not on disk: solmate `ERC721` and `@erc7579/lib/ExecutionLib.sol` |
| VaultTimelock as module owner | Yes | L-11, L-12. Role layout: operator = PROPOSER + EXECUTOR + CANCELLER; guardian = CANCELLER; admin = the timelock itself. Delay bounds hold through the `getMinDelay()` override. The `isSelfOperation` flag is a function of the id, so its persistence after a cancel is harmless |
| DeploySA.s.sol | Read, not simulated (no execution) | L-13 |
| Math precision on SABook | Yes | Sound to the wei (Task 1 item 1); I-4; M-1 is a missing term, not a rounding error |
| Keeper where on-chain safety assumes operator behaviour | Yes (read only) | L-19 – L-22, I-8, and the keeper halves of L-3 and M-1. Anchor hold: present, with defects. ABI: matches the contracts at this commit. Keys: one hot key; request fields reach only permissionless, on-chain-verified calls |

**Areas with less coverage this round:** the web front end and relayer API were not reviewed; `hl.py` and the Hyperliquid adapters were not reviewed; `DeploySA` and every numeric trace are hand-derived, not executed; deployed bytecode on chain 99901 was not compared with the sources read.

---

## 5. Leads (plausible, not confirmed — confidence below 50, or no complete path)

- **Keeper ledger: a missed `margin_sent` write is spread over other clients** [45] — `keeper/elysium_keeper/sa_keeper.py:230-231`. If `sendHedgeMargin` is mined after the 120 s wait times out, the ledger write is skipped; reconciliation spreads the extra treasury USDC over all clients and the keeper then writes the account's on-chain equity down. Not traced through `ledger.py` in full.
- **A keeper return is bounded only by the stored `hedgeEquity`** [phase2: agent 4] — `LPManagerModule.returnHedgeMargin`. A keeper that does not report one account's hedge loss can return the full sent margin from the shared treasury into that account. The money goes to the client's account, not the keeper; the treasury allowance is the other limit and its size is an operator decision.
- **`increasePosition` does not read the liquidity back** [phase2: agent 11] — replaced account code can skip a keeper increase so that the books record the cost of an add that did not occur. Bounded by `maxSlippageBps` of the principal; the fee saved looks like dust at 150 bps.
- **Permit fallback verifies with ECDSA only** [40] [phase1: erc20] — a contract-wallet owner's permit could not pass the fallback after a front-run. Countered by the signatures lens: a hybrid owner must be an ECDSA key, because the 65-byte delegation signature has to recover to `owner()`.

**Examined and dismissed:** the native refund in `SwapExecutor.swap` reverting for an account that refuses a plain transfer [phase2: agent 9] — the canonical DeleGator has an empty `receive()` (`DeleGatorCore.sol:150`), so only a replaced implementation causes it, and only for its own account.

---

## 6. Access-control inventory

| Function | Guard | Caller | Pause-gated | nonReentrant |
|---|---|---|---|---|
| `LPManagerModule.register` | `lastPrice != 0`; replace / after revoke: account or pinned owner (`SALib.sol:239`) | anyone (first) | no | yes |
| `LPManagerModule.onboard` | as register; hybrid only; owner permit | anyone | no | yes |
| `LPManagerModule.deposit` | registered | anyone | no | yes |
| `LPManagerModule.revoke` | account or pinned owner | client | no | no |
| `LPManagerModule.reportPrice` | `onlyKeeper` | keeper | no (cap 0 while paused) | yes |
| `mintPosition` / `increasePosition` / `swap` | `onlyKeeper`, `whenNotPaused`, `_live` | keeper | yes | yes |
| `decreasePosition` / `burnPosition` | `onlyKeeper`, `_live` | keeper | no | yes |
| `sendHedgeMargin` | `onlyKeeper`, `whenNotPaused`, `_fresh`, `_live` | keeper | yes | yes |
| `returnHedgeMargin` | keeper (≤ `hedgeEquity`) or `hedgeTreasury`; registered | keeper / treasury | no | yes |
| `reportHedgeEquity` | `onlyKeeper`; registered | keeper | no (cap 0 while paused or not fresh) | yes |
| `chargeFee` | `onlyKeeper`, `whenNotPaused`, `_trusted`, `_live` | keeper | yes | yes |
| `multicall` | `onlyKeeper`; delegatecall to self, no selector filter | keeper | per item | no (items take it) |
| `approvePrice` / `approveHedgeEquity` | `onlyGuardian` | guardian | no | no |
| `setPaused` | true: guardian or owner; false: owner | guardian / owner | — | no |
| `setKeeper` / `setGuardian` / `setParams` / `transferOwnership` | `onlyOwner` (+ `_distinct`, bounds) | owner = VaultTimelock | no | no |
| `acceptOwnership` | pending owner | pending owner | no | no |
| `renounceOwnership` | none; always reverts | anyone | — | — |
| `SwapExecutor.swap` | none | anyone (payer = recipient = caller) | — | yes |
| `SwapExecutor.unlockCallback` | PoolManager and guard entered | PoolManager | — | — |
| `ElysiumCustodyEnforcer.beforeHook` | DelegationManager; mode 0; redeemer = module in the signed terms | DelegationManager | — | no |
| `VaultTimelock.schedule` / `scheduleBatch` | PROPOSER; mixed self / non-self batch reverts | operator | — | no |
| `VaultTimelock.execute` / `executeBatch` | EXECUTOR; not expired | operator | — | no |
| `VaultTimelock.cancel` | CANCELLER; self-operations need PROPOSER too | operator, guardian | — | no |
| `VaultTimelock.updateDelay`, `grantRole`, `revokeRole` | the timelock itself | timelock | — | no |
| `DeploySA.run` | no caller check; chain id | deployer | — | — |

**Roles.** Module owner = VaultTimelock (two-step transfer, renounce disabled). Keeper and guardian: one-step replacement by the owner. `hedgeTreasury`, `feeRecipient`: immutable. Pinned owner: hybrid = the EOA whose address re-derives the account's CREATE2 address; 7702 = the EOA. The module's `guardian` and the timelock's CANCELLER are separate assignments. Linked libraries (`SALib`, `SABook`, `V4PositionMath`) run by delegatecall in the module; `SAWindow` is internal.

**Entry points with no caller restriction:** `register` (first), `onboard`, `deposit`, `SwapExecutor.swap`, the timelock's `receive` and receiver hooks, `DeploySA.run`.

`Coverage: 40 entrypoints, 40 addressed. 17 threat rows, 17 answered. 28 inferred invariants, 28 answered. Holes closed this pass: 1.`

Entry points with no finding, examined: `deposit` (a donation moves snapshot and `contributed` equally), `revoke` (one flag, no external call, safe during a redemption), `approvePrice` / `approveHedgeEquity` (one-shot, era- and epoch-bound), `setKeeper` / `setGuardian` / `setParams` (timelocked, bounded), `acceptOwnership`, `SwapExecutor.unlockCallback`, `ElysiumCustodyEnforcer.beforeHook` (recipients checked against PositionManager source: MINT owner, TAKE_PAIR and SWEEP recipients, CLOSE_CURRENCY to the locker), `VaultTimelock.execute` / `executeBatch` / `updateDelay`.

---

## 7. Threat model

| # | Actor → reach | Invariant that must hold | Result |
|---|---|---|---|
| T1 | Client, direct actions on its tokens and NFTs | a client flow moves `value` and `contributed` equally | **Addressed by M-1** (fees); holds for idle and liquidity |
| T2 | Client with replaced account code inside a redemption | the computed effect equals the real one, or the difference is neutral | Invariant holds — differences are booked once at the anchor; fee refusal is L-10 |
| T3 | Client, executor record | the record with count + 1 is the module's swap | **Addressed by L-4** |
| T4 | Client timing flows against the anchor / pool gap | a round trip nets zero | **Addressed by M-4, L-1** |
| T5 | Client, pending flows and position bookkeeping | no flow booked twice, never, or at a chosen price | Holds for twice / never; chosen price is M-4, L-5 |
| T6 | Keeper, anchor walk + fee | fee only on real gain | **Addressed by M-3** |
| T7 | Keeper, hedge reports and margin | hedge cap; keeper never raises equity | Invariant holds — increases need the guardian; return ≤ stored equity (lead on stale equity) |
| T8 | Keeper, swaps and adds at chosen prices | band, floor, turnover, add check | **Addressed by M-2**, I-5 |
| T9 | Pool price manipulator | slot0 use bounded by band and delay | **Addressed by L-6** (liveness); cannot choose a booking price |
| T10 | Relayer / third party: register, onboard, deposit | every pull authorised by a fresh permit; owner → own account only | **Addressed by L-7, L-14**; funds only reach the owner's own account |
| T11 | Guardian | pause never blocks removals, returns, exits; approvals one-shot | Invariant holds; rotation veto is L-11 |
| T12 | Owner / operator | params bounded; delay bounds | Invariant holds; L-12, I-5 |
| T13 | hedgeTreasury / feeRecipient | recipient delta; return semantics | I-2, L-18 |
| T14 | DelegationManager owner | client exit does not need the DM | Invariant holds; keeper removals stop (L-17) |
| T15 | Anyone on SwapExecutor / libraries / timelock | executor holds no funds; record keyed by caller | Invariant holds |
| T16 | Module vs enforcer limits | the two agree where it matters | **Addressed by L-16** (liveness); fee caps agree |
| T17 | Deployment | preconditions; first report bounded by the pool | **Addressed by L-13** |

---

## 8. Invariant verification

Inferred invariants from the x-ray pre-scan (guards G-1 … G-26 are per-call preconditions and are not listed).

| ID | Property | On-chain | Verdict |
|---|---|---|---|
| I-1 | A face-value USDC contribution moves `snapAsset` and `contributed` equally | Yes | holds — `_book` writes both |
| I-2 | Every module write to the snapshot equals the real effect of the module's own call | No | holds for LP and transfer paths (differences are booked as neutral flows); **violated → L-4** for a reversed swap |
| I-3 | `sync` values `live − snapshot` with the same function and price as `value` | No | **violated → M-1** (fees), I-2 (hedge equity), I-4 (rounding) |
| I-4 | A margin send moves hedge ledgers up and `snapAsset` down by the verified amount | Yes | holds — recipient delta, then writes |
| I-5 | A margin return is not a flow | No | **violated → I-2** for a treasury return above equity |
| I-6 | `params` stays inside the setter bounds | Yes | holds — `_setParams` is the only writer |
| I-7 | `_positions[a].length <= 4` | Yes | holds |
| I-8 | `snapLiquidity` equals the liquidity the books account for | No | holds in effect — a difference is booked as a flow at `liquidityValue`; lead on the increase path |
| I-9 | Booking and fees only on a fresh anchor unchanged for `minPriceStable` | Yes | holds as coded; **insufficient → M-3, L-5** |
| I-10 | At most one fee per `feeInterval` | Yes | holds |
| I-11 | The anchor moves at most `refDriftBps` per 24 h without a guardian range | Yes | holds; **the whole budget in one step → M-2**; path-length charging → L-2 |
| I-12 | `hedgeEquity` rises only by a verified send or a guardian approval | Yes | holds |
| I-13 | Roles pairwise distinct and non-zero | Yes | holds (timelock operator checked in the script only) |
| I-14 | High-water-mark arithmetic | Yes | holds — capped branch leaves exactly the uncharged remainder |
| I-15 | `guardianEra` only increases | Yes | holds |
| I-16 | Guardian approvals are one-shot | Yes | holds |
| I-17 | The fee clock starts at registration | No | **violated → I-7** (re-registration does not reset it) |
| I-18 | Window amounts fit 96 bits | No | holds in practice — saturation is unreachable for USDC amounts and WAD fractions |
| X-1 | The executor record describes the swap the module asked for | No | **violated → L-4** |
| X-2 | A PositionManager call changes idle by exactly the computed effect | No | holds for the call as built (to the wei); deviations by account code are neutral flows |
| X-3 | A transfer the module allows also passes the enforcer | No | **violated → L-16** (hedge); fee caps agree |
| X-4 | Module, enforcer and executor share one venue wiring | Yes | holds — constructor cross-check; PositionManager ↔ PoolManager wiring unchecked (L-13) |
| X-5 | `live` means code and owner unchanged | No | **violated → L-10** (hybrid implementation not pinned) |
| X-6 | The timelock is the only owner path, delay in [24 h, 30 d] | Yes | holds; per-operation delay unbounded above (L-12) |
| E-1 | No client action changes `profit` | No | **violated → M-1, M-4, L-1** |
| E-2 | The fee never exceeds `feeBps` of the real gain above the mark | No | **violated → M-3**, I-2 |
| E-3 | USDC leaves an account only to the two fixed recipients within the enforcer limits | Yes | holds |
| E-4 | Every allowed keeper action can be executed | No | **violated → L-2, L-3, L-6, L-16, L-17** |

---

## 9. Method and coverage

- **Phase 0a (x-ray):** entry-point map (33 in-scope declarations, 4 permissionless), 26 guards, 28 inferred invariants. Coverage metrics unavailable — target-code execution disabled by audit policy.
- **Phase 0 (context):** 3 agents (Fable 5.2). Protocol map, access-control inventory (40 entry points including 7 inherited timelock functions), 17-row threat catalog, 12 fragility clusters.
- **Phase 1 (breadth):** 8 agents over 13 local checklists — general, precision-math, erc20, defi-amm, erc4337, proxies, signatures, assembly, oracles, chain-specific, access-control, governance, dos — plus 2 fix-verification agents and 1 keeper-lens agent (Fable 5.2). 32 deduplicated items.
- **Phase 2 (depth):** pashov solidity-auditor V4, one pass, memory off: 12 attack agents on Opus 5.5, blind to phase-1 findings, in waves of 3 — math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, trust-gap, flow-gap. **12 of 12 returned work; no respawn was needed.** V4 gate result: 2 findings, 10 leads.
- **Phase 3 (reconcile):** cross-phase dedup by root cause, re-read of every phase-unique item against the source, three-axis coverage gate. Every `file:line` citation in this report was checked against the files at the pinned commit.

Prior reports in the repository (`docs/audit/sa_round1_*.md`, `sa_round2_*.md`) were read as part of the submission to establish fix status; every finding above comes from this job's own agents.

> This review was performed by an AI system. AI analysis cannot verify the complete absence of vulnerabilities and no guarantee of security is given. No code was executed in this review. A team security review, a bug bounty and on-chain monitoring are strongly recommended before deployment.
