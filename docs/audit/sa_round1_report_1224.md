# Elysium LP Smart Accounts — Security Audit (round 1)

**Job:** leftclaw.services #1224 · **Date:** 2026-11-13 · **Method:** deep-audit v3 (x-ray pre-scan → context map → checklist agents → blind attack agents → reconciliation + coverage gate)

**Repo:** https://github.com/Aleha1975/dispatch-cash · branch `elysium-lp-sa` · **commit `591f787bfc0825e0eb913c176a23032c07aefa4d`** (verified reachable on the remote as `refs/heads/elysium-lp-sa`). Not deployed — no on-chain address to pin. Target chain per the client: Elysium, chain id 99901.

**Scope (as submitted):** `src/sa/ElysiumCustodyEnforcer.sol`, `src/sa/LPManagerModule.sol`, `src/sa/SALib.sol`, `src/sa/SwapExecutor.sol`, `src/sa/vendor/DelegationFramework.sol`, `script/DeploySA.s.sol`; reused and re-checked only for how the new code uses them: `src/V4PositionMath.sol`, `src/RiskBudgets.sol`, `src/VaultTimelock.sol` (1,633 nSLOC in total). `docs/SMART_ACCOUNT_DESIGN.md` (section 6) was read as the specification. Dependencies were read at the pinned submodule commits (OpenZeppelin 5.4.0, v4-periphery `c6e4754`, v4-core `59d3ecf`, permit2 `cc56ad0`). The MetaMask Delegation Framework is not vendored as source in the repo; it was read from the upstream tag `v1.3.0` (commit `bfbdf97`). Nothing was compiled or executed (audit policy: no target-code execution), so every proof is a hand trace against the source.

**Severity counts:** 1 Critical · 3 High · 8 Medium · 17 Low · 8 Informational

---

## How to read this report

- **C-1 needs no privileged key.** Anyone can move the hedge treasury's USDC (and any other USDC approved to the module) into an account they control. It should block deployment.
- H-1 needs a compromised keeper; H-2 needs a hostile client; H-3 happens under honest operation.
- The custody enforcer's Uniswap v4 decoding — the piece the client called critical — held up: no calldata was found that the enforcer accepts and PositionManager reads differently, and no accepted execution sends tokens, native HYPE or a position NFT anywhere but the delegator or the fixed pool. The serious findings are in the module, not in the enforcer.
- Each finding carries **Severity** (cost if real) and **Confidence** (how sure we are it is real) as separate fields, plus an origin tag: `[both]` = raised independently by the checklist phase and by the blind attack phase.
- Items the design doc lists under "Open issues" / "Open risks" are not re-reported unless the real exposure differs from what is stated.

### Coverage caveat — read this

The pipeline spawned every agent it is meant to spawn (3 context, 8 checklist, 12 attack). **All 8 checklist agents returned. Only 4 of the 12 blind attack agents returned**; the other 8 were stopped by an automated model safeguard before producing output. Per the methodology they were not respawned and the orchestrator did not substitute their lenses.

| Phase | Lens | Status |
|---|---|---|
| 1 | general · precision-math · erc20+signatures · erc4337+proxies · defi-amm+flashloans (enforcer v4 decoding) · access-control+governance · dos+chain-specific · oracles+erc4626 (fee / hedge ledger) | all returned |
| 2 | economic-security · invariant · first-principles · asymmetry | returned |
| 2 | **math-precision · access-control · execution-trace · periphery · boundary · numerical-gap · trust-gap · flow-gap** | **did not run** |

The seven lenses the client asked for by name:

| Requested lens | Dedicated phase-2 lens | Where the ground was still covered |
|---|---|---|
| economic-security | **ran** | also oracles+erc4626 checklist |
| first-principles | **ran** | — |
| asymmetry | **ran** | — |
| execution-trace | **did not run** | redemption trace, reentrancy and mid-batch behaviour were walked by the erc4337+proxies and general checklist agents (M-5, L-3) |
| periphery | **did not run** | native plumbing, Permit2, SwapExecutor, EntryPoint, factory and the vendored interfaces were walked by the amm, erc20 and erc4337 checklist agents |
| boundary | **did not run** | boundary values were walked by the precision-math checklist agent (L-1, L-11, I-3) |
| flow-gap | **did not run** | `_sync` / `_snap` flow gaps were walked by the general checklist agent (H-3, M-2, M-5) |

So the depth phase is thin: every High and above was found independently by both phases, but for the four lenses that did not run there is only one independent pass. Treat the absence of a finding in multi-call execution traces, periphery plumbing and boundary values as weaker evidence than usual, and consider re-running those lenses after the fixes.

### Reconciliation summary

`Overlap: 9 · Phase-1-only: 27 · Phase-2-only: 1 · Re-examined leads kept: 8, demoted: 0 (severity adjusted on 11) · Coverage holes closed: 0 · Invariants: 28 answered (12 hold, 16 violated, 0 unverified)`

`Completeness: 11 unique (Contract, function) in phase-2 raw, 11 covered.` Reporting floor: Informational and above.

`Coverage: 35 entrypoints, 35 addressed. 14 threat rows, 14 answered. 28 inferred invariants, 28 answered. Holes closed this pass: 0.`

---

## Answers to the client's focus questions

| # | Question | Short answer | Findings |
|---|---|---|---|
| 1 | Can accepted calldata make PositionManager send value anywhere but the delegator, or touch another pool? | No path found. Unlisted action codes revert; recipients are compared literally with the delegator (sentinels fail); CLOSE_CURRENCY pays the locker, which is the account; native value needs a final SWEEP to the delegator; token ids are checked for owner and pool immediately before execution; ids minted in the same call fail the owner check. | — |
| 2 | Is the canonical-encoding check complete? | Yes. Outer args, `unlockData` and every params blob are decoded, re-encoded and compared by hash; dirty bits, shifted offsets, trailing bytes and length mismatches revert; hookData must be empty; the deadline is deliberately free. | — |
| 3 | Does `abi.decode` match `CalldataDecoder` for every blob? | Yes, for all eight actions, field by field. PositionManager's decoder is strictly more permissive; the enforcer rejects what it would tolerate. The ERC-7579 framing is sliced identically. | — |
| 4 | Can a same-block allowance survive or be used by a third party? | It lasts to the end of the timestamp (several Nitro blocks), and the ERC-20 allowance to Permit2 is never reset, but neither is usable by a third party: both spenders pull only from their own caller. | L-17 |
| 5 | Can the stateful limits be reset or multiplied? | Not multiplied or reset. But the state is keyed by delegator only, so the client itself can consume the fee clock and hedge budget through a second delegation. The hedge limit is a rate, not a cap. | M-6, I-1 |
| 6 | Is the module the only way to exercise the delegation? Can other delegations widen keeper rights? | Yes, the module is the only redeemer, and nothing widens the rights. But any other delegation the client signed can be registered by anyone. | M-1, L-5 |
| 7 | register / onboard: malicious registration, permit redirection, poisoning, blocking; account-kind detection | A permit can be redirected and, worse, any allowance to the module can be spent (C-1). The hybrid kind is self-reported. Re-registration cannot be blocked. | C-1, H-2, M-1, L-5 |
| 8 | Is "revoke + burn" always possible in one transaction? | The revocation alone, yes — not pausable, not blockable. The documented combined batch is all-or-nothing and fails silently under `handleOps`. | M-8, M-1 |
| 9 | EIP-7702 / account changes after registration | The kind is never re-checked; account code can change what executions do, and `isActive` ignores it. | H-2, L-14 |
| 10 | Contribution flows: gain as contribution or the reverse? | Yes, beyond the documented leakage: zero-fee path double-booking, not-live returns, subscriber callbacks, anchor-lag booking. | H-3, M-2, M-5, L-2, L-13 |
| 11 | HWM fee | The formula is exact. The fee base can be overstated (pool spot, hedge report) and the fee can become uncollectable. | M-4, L-11, L-12 |
| 12 | Hedge ledger; cross-client effects | The vault's M-5 is fixed for sends. The return side is unbounded on a shared allowance, and the vault's M-2 ordering gap remains. | H-1, M-3, L-4 |

---

# Findings

## Critical

### C-1 — `onboard` pulls USDC from whatever address the account reports as `owner()`, on any existing allowance to the module — including the hedge treasury's

**Severity:** Critical · **Confidence:** 95 · **Origin:** [both] (phase 1: general, erc20+signatures, erc4337+proxies, access-control, dos; phase 2: economic-security, invariant, first-principles, asymmetry)
**Location:** `LPManagerModule.onboard` (`src/sa/LPManagerModule.sol:320-331`), `SALib.accountKind` (`src/sa/SALib.sol:87-91`)

```solidity
// src/sa/LPManagerModule.sol:324-330
address a = d.delegator;
if (accounts[a].delegationHash != delegationManager.getDelegationHash(d)) _register(d);
if (amount == 0) return;
if (accounts[a].kind != SALib.KIND_HYBRID) revert NotOwnAccount(); // a 7702 account already holds its funds
address owner_ = IHybridDeleGator(a).owner();
try IERC20Permit(address(asset)).permit(owner_, address(this), amount, deadline, v, r, s) {} catch {}
asset.safeTransferFrom(owner_, a, amount); // booked as a contribution at the next sync
```

**What is wrong.** `onboard` is permissionless. The payer is read from the account at call time, and the permit is wrapped in `try/catch`, so when the permit fails the transfer still runs on any allowance `owner_` already gave the module. Nothing proves that `owner_` agreed to fund account `a`. The account controls what `owner()` returns, in three independent ways:

1. **Canonical account, owner chosen at creation.** `HybridDeleGator.initialize(owner, keyIds, x, y)` accepts any `owner` and lets the deployer add its own P256 key, which can sign the delegation and later control the account (reference `HybridDeleGator.sol:101`).
2. **Canonical account, owner changed later.** `transferOwnership` and `updateSigners` are `onlyEntryPointOrSelf` (reference `HybridDeleGator.sol:218`, `:242`); the account can point `owner()` at any address and restore it in the same batch.
3. **Non-canonical account.** `accountKind` accepts any contract whose own `getImplementation()` returns `hybridImpl`:

```solidity
// src/sa/SALib.sol:88-90
try IDeleGatorCore(a).getImplementation() returns (address impl) {
    if (impl == hybridImpl) return KIND_HYBRID;
} catch {}
```

**Who has an allowance to the module.** The hedge treasury, by design: `returnHedgeMargin` pulls with the module's own `safeTransferFrom` (`src/sa/LPManagerModule.sol:529`), and the deploy script lists the approval as a post-deploy step (`script/DeploySA.s.sol:26`: "the treasury approves the module for USDC"; the test base approves `type(uint256).max`, `test/sa/SATestBase.sol:245`). Also any wallet that approved the module to use `deposit`, and any client whose permit signature is seen before it is used.

**Trace.** The treasury holds client margin and has approved the module. A caller registers a correctly shaped delegation for an account whose `owner()` returns `hedgeTreasury` (any of the three ways above) and calls `onboard(d, amount, 0, 0, 0, 0)`: registration passes, the stored kind is HYBRID, `owner_ = hedgeTreasury`, the permit reverts and is swallowed, and `safeTransferFrom(hedgeTreasury, a, amount)` succeeds. The account then moves the USDC out with its own key. The call is repeatable whenever the treasury holds USDC. With `owner()` set to a client's EOA, the same call takes that client's standing allowance, or its onboarding deposit if the permit signature is replayed first.

**Impact.** Direct loss, by anyone, of all USDC at the treasury (every client's hedge margin in transit) and of any USDC approved to the module. The NatSpec "Funds can only go into the owner's own account" (`src/sa/LPManagerModule.sol:318-319`) and the design claim "a permit cannot be redirected to another account" do not hold. The existing test `test_Onboard_FundsOnlyIntoTheOwnersAccount` only covers an account whose owner is the caller.

**Fix.** Bind the pull to the payer's consent for this destination, and never use a bare pre-existing allowance on behalf of an address read from the account.

```diff
 address owner_ = IHybridDeleGator(a).owner();
-try IERC20Permit(address(asset)).permit(owner_, address(this), amount, deadline, v, r, s) {} catch {}
+if (owner_ == hedgeTreasury || owner_ == feeRecipient) revert NotOwnAccount();
+bool ok;
+try IERC20Permit(address(asset)).permit(owner_, address(this), amount, deadline, v, r, s) { ok = true; } catch {}
+// a pre-existing allowance is used only when the payer itself calls
+if (!ok && msg.sender != owner_) revert NotOwnAccount();
 asset.safeTransferFrom(owner_, a, amount);
```

This minimal change still lets a valid permit be redirected to an account that names the signer as owner (variant 1). The complete fix is an owner-signed authorisation that names the destination account (an EIP-712 `Onboard(account, amount, nonce, deadline)` checked in the module, or a Permit2 witness transfer). Independently, take the treasury out of the module's general allowance: let the treasury push (`transferFrom(msg.sender, …)` when the caller is the treasury) or put the allowance behind a small puller contract that only `returnHedgeMargin` can use. A codehash check on the account is not sufficient (variants 1 and 2 use the canonical implementation). The module has about 629 bytes of EIP-170 margin; measure the fix.

---

## High

### H-1 — `returnHedgeMargin` takes a caller-chosen amount bounded only by the shared treasury allowance

**Severity:** High · **Confidence:** 90 · **Origin:** [both] (phase 1: five agents; phase 2: all four)
**Location:** `LPManagerModule.returnHedgeMargin` (`src/sa/LPManagerModule.sol:520-538`)

```solidity
// src/sa/LPManagerModule.sol:529-534
asset.safeTransferFrom(hedgeTreasury, to, amount);
if (asset.balanceOf(to) - before != amount) revert TransferMismatch();
uint256 h = s.hedgeEquity;
uint256 m = s.netMargin;
s.hedgeEquity = amount >= h ? 0 : h - amount;
s.netMargin = amount >= m ? 0 : m - amount;
```

`amount` is not compared with the account's `hedgeEquity` or `netMargin`; both ledgers are floored at zero instead. The source is the one treasury allowance shared by all accounts, and the destination is any registered account (or its `owner()` once the delegation is not live). `register` is permissionless, so the keeper can register an account of its own with empty ledgers and call `returnHedgeMargin(own, treasury balance)`. The function is not stopped by the module pause or by a DelegationManager pause, and it consumes no budget. In one `multicall` the keeper can first send up to the cap from every client account to the treasury and then pull the total.

**Impact.** A compromised keeper takes all USDC at the treasury plus up to `hedgeCapBps` (35%) of every account's value. This is the only keeper action with no on-chain bound, and it breaks both "keeper damage stays inside the budgets" and "one client's hedge accounting cannot affect another's". On a real client's account, an over-return becomes fee-able "profit".

**Fix.** Bound the keeper path by the account's own ledger; a hedge gain above it already needs the guardian's `approveHedgeEquity` first.

```diff
 Account storage s = accounts[a];
 if (s.delegationHash == 0) revert NotRegistered();
+if (msg.sender == keeper && amount > s.hedgeEquity) revert HedgeCap(amount, s.hedgeEquity);
```

Operationally the treasury should approve per return, not keep a standing maximum.

---

### H-2 — Hedge-margin and fee transfers are verified only as a balance drop at the account, and the account's code is client-controlled

**Severity:** High · **Confidence:** 85 · **Origin:** [both] (phase 1: general, erc20+signatures, erc4337+proxies; phase 2: economic-security, invariant, first-principles)
**Location:** `LPManagerModule.sendHedgeMargin` (`src/sa/LPManagerModule.sol:508-513`), `chargeFee` (`:572-576`), `SALib.accountKind` (`src/sa/SALib.sol:77-92`), `_register` (`src/sa/LPManagerModule.sol:360`)

```solidity
// src/sa/LPManagerModule.sol:508-513
s.hedgeEquity = h + amount;
s.netMargin = m + amount;
budgets[a].hedgeApprovedEpoch = 0; // M-2: an approval was judged against the old baseline
uint256 before = asset.balanceOf(a);
_exec1(a, address(asset), 0, abi.encodeCall(IERC20.transfer, (hedgeTreasury, amount)));
if (before - asset.balanceOf(a) != amount) revert TransferMismatch();
```

The module raises the hedge ledgers, asks the account (through the DelegationManager) to transfer, and then checks only that the account's balance fell. It never checks that `hedgeTreasury` received anything; `chargeFee` has the same shape for `feeRecipient` (`:573`). The enforcer validates the calldata, but the call is executed by the account's own `executeFromExecutor`. That code is the client's: the hybrid kind is self-reported at registration (see C-1), a genuine proxy can be upgraded afterwards (`_authorizeUpgrade` is `onlyEntryPointOrSelf`), a 7702 EOA can re-point its designator, and the stored `kind` is never re-checked. The DelegationManager validates the signature by asking the same account.

**Trace.** An account whose execution sends the same amount to another address of the client passes the check. For a margin send of 25,000 on a 100,000 account, the books show `hedgeEquity = netMargin = 25,000` and `HedgeMarginSent` is emitted, while the treasury received nothing. When the client later disables the delegation, the documented wind-down "pays its hedge equity back with `returnHedgeMargin`" — 25,000 of other clients' margin from the shared treasury. For a fee, `hwm`, `lastFeeTime` and `feesPaid` advance and the fee recipient receives nothing, so the client stays managed and pays no fee.

**Impact.** A hostile client extracts up to the hedge cap of its own account value per cycle from the shared treasury, through the operator's normal flows. The margin variant relies on the keeper acting on the module's books and events (the designed flow); the fee variant is complete on-chain. Swaps and mints for such an account are self-harm only, with one exception: `mintPosition` checks only `ownerOf(tokenId) == a` (`:408`) and stores the keeper's ticks, so the tracked position may not be the one the module thinks it is (L-13).

**Fix.** Verify the destination as well as the source; USDC has no transfer hooks, so this cannot be faked.

```diff
 uint256 before = asset.balanceOf(a);
+uint256 tBefore = asset.balanceOf(hedgeTreasury);
 _exec1(a, address(asset), 0, abi.encodeCall(IERC20.transfer, (hedgeTreasury, amount)));
-if (before - asset.balanceOf(a) != amount) revert TransferMismatch();
+if (before - asset.balanceOf(a) != amount || asset.balanceOf(hedgeTreasury) - tBefore != amount) revert TransferMismatch();
```

Do the same for `feeRecipient` in `chargeFee`, and write the hedge ledgers after the verified transfer. As defence in depth, re-run the kind check on each action and derive the kind from something the account cannot answer for itself (the ERC-1967 slot via the proxy's runtime codehash, or a CREATE2 derivation from the factory).

---

### H-3 — `chargeFee` books client flows and returns without a snapshot when the fee is zero, so the same flow is booked again

**Severity:** High · **Confidence:** 90 · **Origin:** [both] (phase 1: general, precision-math, dos, oracles+erc4626; phase 2: invariant, first-principles)
**Location:** `LPManagerModule.chargeFee` (`src/sa/LPManagerModule.sol:561-569`), `_sync` (`:709-720`)

```solidity
// src/sa/LPManagerModule.sol:561, 566-569
_sync(a);
...
int256 profit = int256(accountValue(a, lastPrice)) - s.contributed;
int256 newHwm;
(f, newHwm) = SALib.hwmFee(profit, s.hwm, params.feeBps);
if (f == 0) return 0;
```

`_sync` adds the difference between live balances and the stored snapshots to `contributed` (`:717`). Every other path follows it with `_snap`. Here, when the fee is zero, the function returns with `contributed` written and the snapshots unchanged, so the next `_sync` — any action, including a second `chargeFee` — books the same difference again. `lastFeeTime` is not advanced on this path, so the call can be repeated immediately, also inside one `multicall`.

**Trace (honest keeper).** Account value 100,000, `contributed` 100,000, `hwm` 0, fee interval elapsed. The client withdraws 20,000 USDC directly. The keeper's periodic `chargeFee`: `_sync` sets `contributed = 80,000`, profit is 0, the call returns. On the next tick (or the next action) `_sync` books −20,000 again: `contributed = 60,000`, profit 20,000, and the next `chargeFee` sends a 3,000 USDC fee to the fee recipient although the client made nothing. The mirror case: a deposit before a zero-fee call is booked twice and shields the same amount of later profit from fees.

**Impact.** Clients are charged the performance fee on their own withdrawals under ordinary operation; a compromised keeper can do it on purpose and repeat the zero-fee call to erase a drawdown first. Each charge is bounded by 20% of idle USDC per 7 days, but `contributed` and `hwm` stay wrong. The module comment "Module actions are bracketed by `_sync` / `_snap`" (`:60-61`) is false on this path.

**Fix.**

```diff
-if (f == 0) return 0;
+if (f == 0) {
+    _snap(a);
+    return 0;
+}
```

Better, make `_sync` write the snapshots itself so no caller can forget, and add an invariant test that after every external module function the snapshots equal the live balances and liquidity.

---

## Medium

### M-1 — Disabling the registered delegation does not end management: anyone can register any other delegation the client signed

**Severity:** Medium · **Confidence:** 85 · **Origin:** [both] (phase 1: four agents; phase 2: all four)
**Location:** `LPManagerModule.register` / `_register` (`src/sa/LPManagerModule.sol:313-315`, `:340-372`), `SALib.checkDelegation` (`src/sa/SALib.sol:47-73`)

```solidity
// src/sa/LPManagerModule.sol:357-361
bool first = s.delegationHash == 0;
if (!first) _sync(a); // re-registration keeps the books; recognise what the client did meanwhile
s.delegationHash = h;
s.kind = kind;
s.until = uint64(until);
```

`register` is permissionless and accepts any correctly shaped delegation that is signed, not itself disabled, and has at least one day left. It overwrites the stored hash, expiry and `permissionContext` with no ordering rule. Re-registration is the documented renewal flow, so clients normally have several valid delegations (different salt or expiry), and their signatures are public calldata. `disableDelegation` acts on one hash. After a client exits by disabling the current delegation, anyone can call `register` with an older one: `isActive` is true again and the keeper — honest automation or a compromised key — resumes swaps, mints and margin sends on whatever is still in the account (the withdrawal is a second transaction). The same call can replace a long-lived delegation with a shorter one.

**Fix.** Give re-registration an order: store the salt (or expiry) and accept a replacement only if it is strictly newer, and not after the stored delegation was disabled; or restrict re-registration to the account. Have the exit flow disable every delegation the client signed for the module.

```diff
 bool first = s.delegationHash == 0;
+if (!first && msg.sender != a && (until <= s.until || delegationManager.disabledDelegations(s.delegationHash))) revert BadParam();
```

### M-2 — Margin returned while the module considers the account not live is never booked as a flow

**Severity:** Medium · **Confidence:** 80 · **Origin:** [both] (phase 1: five agents; phase 2: invariant, asymmetry)
**Location:** `LPManagerModule.returnHedgeMargin` (`src/sa/LPManagerModule.sol:525-536`), `payoutAddress` (`:302-308`)

```solidity
// src/sa/LPManagerModule.sol:525-527, 536
bool live = isActive(a);
if (live) _sync(a);
address to = payoutAddress(a);
...
if (live) _snap(a);
```

When `isActive(a)` is false there is no `_sync` / `_snap`. For a hybrid account the USDC goes to `owner()`: `hedgeEquity` falls, `contributed` does not. For a 7702 account the USDC lands in the account without a snapshot and the next `_sync` books it as a fresh contribution. Either way profit is understated by the returned amount, and the books are kept when the client re-enables (`enableDelegation` needs no module call) or re-registers. Example: `contributed` 100,000, value 110,000 including 30,000 hedge equity; disable, return 30,000, enable, deposit the 30,000 back: profit is −20,000 instead of +10,000, and the next 30,000 of gains pay no fee. The cycle repeats each time. "Not live" is also reachable for a delegation the DelegationManager still accepts (L-1). The design's accepted fee leakage does not cover this path.

**Fix.**

```diff
-if (live) _snap(a);
+if (live || to == a) _snap(a);
+else s.contributed -= int256(amount); // paid to the owner EOA: a withdrawal
```

### M-3 — A guardian hedge approval binds to the epoch read at execution, and margin moves do not change the epoch (vault M-2 carried over)

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase 1: access-control, oracles+erc4626]
**Location:** `LPManagerModule.approveHedgeEquity` (`src/sa/LPManagerModule.sol:610-617`), `sendHedgeMargin` (`:510`), `returnHedgeMargin` (`:535`), `RiskBudgets.moveHedge` (`src/RiskBudgets.sol:68-71`)

```solidity
// src/sa/LPManagerModule.sol:610-615
function approveHedgeEquity(address a, uint256 value, uint256 until) external onlyGuardian {
    RiskBudgets.Budgets storage b = budgets[a];
    uint256 ep = accounts[a].hedgeEpoch;
    b.hedgeApproved = value;
    b.hedgeApprovedEpoch = ep + 1;
    b.hedgeApprovedUntil = until;
```

A margin move clears an approval that already exists, but the approval takes no expected epoch or expected stored equity, and `sendHedgeMargin` / `returnHedgeMargin` do not increment `hedgeEpoch`. A margin move that lands between the guardian's judgement and its transaction leaves a valid approval for a baseline the guardian never saw. Example: stored equity 300,000, true 400,000; a return of 250,000 lands first (stored 50,000, the cash now idle in the account); the approval of 400,000 lands; `reportHedgeEquity(400,000)` is applied exactly. Account value is overstated by 250,000, and `chargeFee` can take up to 15% of it (the idle gate passes because the returned USDC is idle). The send direction understates value instead.

**Fix.** Have the guardian state what it judged, and move the epoch on margin moves.

```diff
-function approveHedgeEquity(address a, uint256 value, uint256 until) external onlyGuardian {
+function approveHedgeEquity(address a, uint256 expectedEpoch, uint256 expectedStored, uint256 value, uint256 until) external onlyGuardian {
+    Account storage s = accounts[a];
+    if (s.delegationHash == 0 || s.hedgeEpoch != expectedEpoch || s.hedgeEquity != expectedStored) revert BadParam();
```

### M-4 — Fee, hedge cap and hedge step value LP at pool spot with no band check, so any displacement of spot overstates account value

**Severity:** Medium · **Confidence:** 80 · **Origin:** [both] (phase 1: general, precision-math, amm, oracles+erc4626; phase 2: first-principles, two leads)
**Location:** `LPManagerModule.accountValue` (`src/sa/LPManagerModule.sol:296-299`), `chargeFee` (`:560-566`), `sendHedgeMargin` (`:506`), `reportHedgeEquity` (`:548`), `V4PositionMath.amounts` (`src/V4PositionMath.sol:50`)

```solidity
// src/sa/LPManagerModule.sol:560, 566
if (lastPriceClipped || block.timestamp > lastPriceTime + params.maxPriceAge) revert StalePrice();
...
int256 profit = int256(accountValue(a, lastPrice)) - s.contributed;
```

`accountValue` reads position amounts at the pool's current sqrt price and values the base leg at the anchor. For liquidity `L` with spot `s` and anchor `p` the marked value exceeds the value at the anchor by `L(√s − √p)²/√s`, which is never negative. Mint, increase and swap check the pool band; `chargeFee`, `sendHedgeMargin` and `reportHedgeEquity` do not. The fee gate only says the anchor was within band of spot at some moment in the last `maxPriceAge`. Contribution flows are booked with `liquidityValue` at the anchor, so the difference appears as profit.

| Position range, spot pushed to | Inflation of LP value | Fee at 15% |
|---|---|---|
| ±10%, to the edge | 2.3–2.8% | ≈ 0.4% |
| ±50%, to +50% | 8.7% | 1.3% |
| full range, to 4× | 25% | 3.75% |

The fee recipient gains and the client loses (the HWM ratchets, so it is a prepayment only if the client stays and later earns it). The hedge cap rises by 35% of the inflation. A third party who moves the pool gains nothing; a keeper that can batch can do it at the cost of pool fees. The design doc's section 2 says LP is counted "at the anchor"; the code uses spot. This is the vault's round-2 valuation issue in the fee and cap paths.

**Fix.** Call `_checkPoolBand(lastPrice)` in the three functions, or value positions with `liquidityValue(…, lastPrice)` plus uncollected fees so that value and flows use the same price.

### M-5 — A position subscriber lets the client run code inside the `_sync` / `_snap` bracket: unbooked withdrawals and keeper-batch griefing

**Severity:** Medium · **Confidence:** 75 · **Origin:** [phase 1: general, erc4337+proxies, amm, dos]
**Location:** `LPManagerModule.decreasePosition` / `burnPosition` (`src/sa/LPManagerModule.sol:438-462`); `lib/v4-periphery/src/base/Notifier.sol:40`, `:124`

```solidity
// src/sa/LPManagerModule.sol:443-446
_sync(a);
_indexOf(a, tokenId);
_modify(a, V4PositionMath.removeData(false, tokenId, liquidity, amount0Min, amount1Min, currency0, currency1, a), 0, 0);
_snap(a);
```

The client owns the position NFT and can `subscribe` any contract to it directly. PositionManager then calls that contract, with all remaining gas, during every keeper increase, decrease or burn of that position. The module's guard blocks re-entry into the module, but the subscriber can make the (canonical) account act — through a pre-signed user operation at the EntryPoint, or a second delegation of the client's own. Whatever leaves the account inside the bracket is absorbed by the final `_snap` and never booked as a withdrawal; decrease and burn have no balance post-check. Profit is then understated permanently, beyond the documented leakage. The same callback can revert (blocking keeper decreases and burns of that position) or burn gas (L-3).

**Fix.** Refuse to act on subscribed positions (`positionManager.subscriber(tokenId) != address(0)` → revert or treat as dropped), and after decrease or burn require that idle balances did not fall.

### M-6 — The enforcer's limits are keyed by delegator only, so a client can consume its own fee clock and hedge budget through a second delegation

**Severity:** Medium · **Confidence:** 80 · **Origin:** [phase 1: erc20+signatures, erc4337+proxies, access-control]
**Location:** `ElysiumCustodyEnforcer` (`src/sa/ElysiumCustodyEnforcer.sol:85`, `:164-165`, `:317-333`)

```solidity
// src/sa/ElysiumCustodyEnforcer.sol:330-333
if (s.lastFeeTime != 0 && block.timestamp < s.lastFeeTime + FEE_INTERVAL) {
    revert FeeTooSoon(s.lastFeeTime + FEE_INTERVAL);
}
s.lastFeeTime = uint64(block.timestamp);
```

The module, treasury and fee recipient come from the terms of whichever delegation is being redeemed, but the state is `spend[delegator]`. A client can sign a second root delegation that names its own addresses in the terms and redeem a one-unit USDC transfer to its own "fee recipient". That sets `spend[account].lastFeeTime`, and the module's `chargeFee` then reverts `FeeTooSoon` for 7 days; repeated weekly, the account stays managed and never pays a fee. The same works for the hedge fraction (blocking `sendHedgeMargin`). Third parties cannot write another delegator's slot, and the limits cannot be multiplied or reset this way.

**Fix.** Key the state by the signed terms: `spend[delegator][keccak256(terms)]`, or by the `delegationHash` passed to the hook.

### M-7 — The shared anchor and its budgets carry the vault's open issues: per-swap loss against the market is drift + band, the window admits 2x, and a guardian range is reusable

**Severity:** Medium · **Confidence:** 75 · **Origin:** [phase 1: oracles+erc4626, precision-math, access-control]
**Location:** `LPManagerModule.reportPrice` (`src/sa/LPManagerModule.sol:378-386`), `approvePrice` (`:601-606`), `RiskBudgets` (`src/RiskBudgets.sol:35-38`, `:44-46`)

The module reuses `RiskBudgets` unchanged, so three properties carry over, now across all accounts at once because the anchor is global:

- **Anchor follows a moved pool.** The only reference for a report is pool spot in the same transaction. Swap and add bounds are "band + slippage against the anchor"; against the market they are `refDriftBps + poolBandBps` (about 11.8% at defaults) once the anchor has been walked. The cost of moving the pool is fixed while the effect applies to every account. A report equal to the reachable value is "unclipped", and a report equal to `lastPrice` refreshes `lastPriceTime` at no budget cost.
- **2x in 24 hours.** Linear decay re-based at each write admits `cap × (1 + T / 1 day)`: turnover 4x account value (about 12% of value at 1.5% + 1.5%), keeper-only hedge decreases 10%, anchor +21% in the first 24 hours. The NatSpec figure "~1.6x" (`src/RiskBudgets.sol:9`) is wrong.
- **Reusable price range.** Inside an unexpired `approvePrice` range every report is free, unclipped (so fee-eligible), effective while paused and unlimited in count; `lo`, `hi` and `until` are unvalidated.

**Fix.** As recommended for the vault: make the price approval one-shot and cap `until`; state the bounds as 2x and drift + band (or enforce the intended ones); consider a reference that a same-transaction push cannot move (previous-block spot or a short TWAP) and a minimum interval between anchor moves.

### M-8 — The documented one-transaction exit batch is all-or-nothing and fails silently at the EntryPoint

**Severity:** Medium · **Confidence:** 75 · **Origin:** [phase 1: dos, erc4337+proxies]
**Location:** `docs/SMART_ACCOUNT_DESIGN.md:334-339` ("Client exit"); `LPManagerModule.burnPosition` (`src/sa/LPManagerModule.sol:451-462`)

The exit is one `execute(batch)` in default mode: `disableDelegation(d)` plus one burn per position. Any failing leg reverts the whole batch, including the revocation: the keeper burned or re-ranged that token id just before (a routine race), the minimum amounts are not met after a pool move, USDC is paused, the position has a reverting subscriber, or `d` is already disabled on a retry. For a hybrid account EntryPoint v0.7 does not revert `handleOps`: the nonce is consumed, the transaction shows as successful, and the delegation is still enabled while the client believes it has left. The revocation on its own cannot be blocked by anyone (it is delegator-only and not pausable), so the claim "nothing in the module can block that" holds for the revocation but not for the documented batch.

**Fix.** Run `disableDelegation` first in try mode (or as its own first user operation), use zero or wide minimums for exit burns, skip the disable when already disabled, and have the page verify `disabledDelegations(hash)` after inclusion rather than transaction success.

---

## Low

### L-1 — The delegation expiry is narrowed from uint128 to uint64
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] · **Location:** `LPManagerModule._register` (`src/sa/LPManagerModule.sol:361`), `SALib.checkDelegation` (`src/sa/SALib.sol:60-62`)
`s.until = uint64(until);` after a uint128 lifetime check. A delegation signed with `until = 2**64` is valid at the TimestampEnforcer indefinitely but stored as 0: `isActive` is false while every keeper action still redeems, `payoutAddress` returns the owner, and margin returns take the unbooked path of M-2. **Fix:** reject `until > type(uint64).max`, or store uint128.

### L-2 — Flows are booked at the anchor of the moment, and `register` is an on-demand `_sync` / `_snap`
**Severity:** Low · **Confidence:** 65 · **Origin:** [phase 1: oracles+erc4626] · **Location:** `LPManagerModule._sync` (`src/sa/LPManagerModule.sol:709-720`), `_register` (`:358`, `:365`)
Base flows are valued at the current anchor, which lags the market by up to the band (more when clipped or frozen). Re-registering the stored delegation is permissionless and runs `_sync` then `_snap`, so a client chooses when its flows are booked: HYPE moved in while the anchor is high and out after it is lowered leaves `contributed` inflated with no capital inside (about 1.5% of the amount per round trip at a 1.5% lag). Operator fee loss only; first registration books at whatever the anchor is. **Fix:** book base inflows at `min(anchor, pool price)` and outflows at the max; skip `_sync` / `_snap` when the hash is unchanged.

### L-3 — `multicall` has no per-call gas bound and copies unbounded returndata
**Severity:** Low · **Confidence:** 80 · **Origin:** [both] · **Location:** `LPManagerModule.multicall` (`src/sa/LPManagerModule.sol:584-598`)
Client-controlled code runs inside keeper actions with all forwarded gas (a position subscriber, the account's `isValidSignature` / `executeFromExecutor` after a code change, `owner()` in `payoutAddress`). One account that burns gas or returns a large revert payload leaves the later entries of a batch without gas, even with `allowFailure = true`. No funds at risk; the keeper pays and other clients' actions are delayed. **Fix:** a gas stipend per entry with a `gasleft()` floor, and a cap on copied returndata.

### L-4 — `netMargin` never forgives realised hedge losses, so the hedge cap ratchets shut
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: precision-math, dos] · **Location:** `LPManagerModule.sendHedgeMargin` (`src/sa/LPManagerModule.sol:503-509`), `returnHedgeMargin` (`:531-534`)
The cap applies to `max(hedgeEquity, netMargin) + amount`, and `netMargin` falls only by USDC actually returned. Cumulative realised short losses consume the cap permanently; once they reach `hedgeCapBps × value`, `sendHedgeMargin` reverts for that account forever and no role can reset it. **Fix:** a guardian-approved write-down of `netMargin` to the approved equity, or document it as the lifetime custody-loss limit.

### L-5 — Caveat `args` are outside the delegation hash, unbounded, and stored by anyone
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] · **Location:** `SALib.checkDelegation` (`src/sa/SALib.sol:54-59`), `LPManagerModule._register` (`src/sa/LPManagerModule.sol:362-364`)
`getDelegationHash` covers neither `caveats[i].args` nor `signature`. Anyone can re-register a client's delegation with tens of kilobytes of `args`; the blob is then loaded, copied once per execution and passed to every hook on each keeper action. Custody is unaffected (both enforcers ignore `args`); the effect is gas and batch packing until someone re-registers clean. **Fix:** require empty `args` and bound `signature.length` in `checkDelegation`.

### L-6 — Pause is not a stop for a compromised keeper
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: access-control] · **Location:** `LPManagerModule.sendHedgeMargin` (`src/sa/LPManagerModule.sol:498`), `reportHedgeEquity` (`:543`), `decreasePosition` (`:438`), `burnPosition` (`:451`)
`whenNotPaused` is on mint, increase, swap and fee only. While paused the keeper can still burn every position with zero minimums, send up to the cap of every account to the treasury, lower each account's hedge equity at the budget rate, and (until H-1 is fixed) return any amount. The only stop is `setKeeper` after the timelock delay (48 h default), which the guardian cannot schedule. **Fix:** block `sendHedgeMargin` and unapproved `reportHedgeEquity` decreases while paused, or add a guardian-settable keeper freeze that leaves bounded returns open.

### L-7 — Guardian approvals are unvalidated; a refused report voids a pending approval
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] · **Location:** `LPManagerModule.approvePrice` (`src/sa/LPManagerModule.sol:601-606`), `approveHedgeEquity` (`:610-617`), `reportHedgeEquity` (`:551`), `setGuardian` (`:636-640`)
`approvePrice` accepts any `lo`, `hi`, `until`. `approveHedgeEquity` has no registration check and no cap on `until`, so an approval can be parked on an unregistered address. `s.hedgeEpoch++` runs even when an increase is refused, so the keeper can cancel each guardian approval with one refused report (liveness only). `setGuardian` and `setPaused(true)` clear nothing, so a rotated-out guardian's open price range stays live. **Fix:** validate `lo <= hi` and cap `until`; require registration; clear approvals in `setGuardian`.

### L-8 — Role separation and `DeploySA` checks are incomplete
**Severity:** Low · **Confidence:** 85 · **Origin:** [both] · **Location:** `LPManagerModule` constructor (`src/sa/LPManagerModule.sol:222-227`), `setKeeper` (`:630-634`); `script/DeploySA.s.sol:47-51`, `:60-73`
Only `keeper != guardian` and `treasury != feeRecipient` are enforced on-chain. Nothing prevents `hedgeTreasury == keeper` (the hot key then custodies margin) or `feeRecipient == keeper`, and both are immutable and signed into every delegation. The script checks pre-existing contracts for code only (no code hash, no `DelegationManager.paused()` / `owner()`, no pool-initialised check), skips a CREATE2 fixture whenever the address has code, and leaves the first `reportPrice` (free of the drift budget) and the treasury approval (size unspecified; see C-1, H-1) as manual steps. **Fix:** require all role and operator addresses to be pairwise distinct; pin code hashes; assert the DM is not paused and the pool is initialised; document per-return treasury approvals.

### L-9 — `increasePosition` nets collected fees and stray PositionManager native out of `paid`
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: amm, oracles+erc4626, precision-math] · **Location:** `LPManagerModule._checkAdd` (`src/sa/LPManagerModule.sol:764-769`), `SALib.addCharge` (`src/sa/SALib.sol:247-249`)
`paid` is the drop of the account's idle value across the whole call. An increase credits the position's uncollected fees `F`, and the final SWEEP returns any native a third party left in PositionManager, so `paid = cost − F − stray` while `got` is the full new liquidity. The check allows a loss of `F + slip × paid`, turnover is charged on the reduced figure, and with `F >= cost` there is no check and no charge. Bounded by the fees left uncollected in one position. **Fix:** collect fees in their own bracket before reading `v0`, or add the fee value to `paid`.

### L-10 — `mintPosition` checks `MAX_POSITIONS` before `_sync` drops positions the client removed
**Severity:** Low · **Confidence:** 90 · **Origin:** [both] · **Location:** `LPManagerModule.mintPosition` (`src/sa/LPManagerModule.sol:399-400`)
`if (_positions[a].length >= MAX_POSITIONS) revert TooManyPositions();` runs on the unsynced array. After the client burns tracked positions directly, mints revert until another action that completes (or a permissionless `register`) syncs the account. **Fix:** swap the two lines.

### L-11 — The fee is all-or-nothing against the 20%-of-idle cap, so a large accrued fee can become uncollectable
**Severity:** Low · **Confidence:** 80 · **Origin:** [phase 1: precision-math] · **Location:** `LPManagerModule.chargeFee` (`src/sa/LPManagerModule.sol:568-571`)
`f` is the whole `(profit − hwm) × feeBps` and must satisfy `f × BPS <= idle × 2000`; there is no partial charge. When `f` exceeds 20% of the account's total value (for example after the client withdraws most of it), `chargeFee` reverts `FeeNeedsIdle` indefinitely and even the collectable slice is lost. **Fix:** charge `min(f, idle × 20%)` and advance the mark proportionally.

### L-12 — The fee waits for an unclipped anchor but not for an unclipped or recent hedge report
**Severity:** Low · **Confidence:** 75 · **Origin:** [phase 1: precision-math, oracles+erc4626] · **Location:** `LPManagerModule.reportHedgeEquity` (`src/sa/LPManagerModule.sol:548-552`), `chargeFee` (`:560`)
`hedgeEquity` enters profit one for one. A decrease larger than the step budget is clipped (only an event says so), and an omitted report leaves equity stale, while LP gains are booked at the fresh anchor. Example: a 10% hedge loss with a 5% step overstates profit by 5% of value, a fee of 0.75% of value on non-profit. **Fix:** store a per-account `hedgeClipped` flag and report time, and require unclipped and recent in `chargeFee`.

### L-13 — Flows are valued at the anchor while value uses spot amounts; tracked positions are not verified
**Severity:** Low · **Confidence:** 70 · **Origin:** [both] · **Location:** `SALib.flow` (`src/sa/SALib.sol:196-204`), `LPManagerModule._lpAmounts` (`src/sa/LPManagerModule.sol:700-705`), `mintPosition` (`:404-410`)
A client's direct liquidity change moves idle balances by spot amounts but books the position leg with `liquidityValue` at the anchor, so `contributed` drifts by up to about the band on the client's own LP changes. A transferred-out NFT is booked without its uncollected fees. `_lpAmounts` keeps valuing a position the account no longer owns until the next sync (overstating `reportHedgeEquity`'s step cap). After a mint the module checks only `ownerOf(tokenId) == a` and stores the keeper's ticks; for an account whose code does not execute as written (H-2) the tracked token may be a different position. **Fix:** make `_lpAmounts` skip ids not owned by the account; after a mint, check the token's pool, ticks and liquidity; value flows and positions with the same function.

### L-14 — `isActive` ignores account code and signers; a cleared 7702 designator or an owner change is not a revocation
**Severity:** Low · **Confidence:** 75 · **Origin:** [phase 1: erc4337+proxies, erc20+signatures, dos] · **Location:** `LPManagerModule.isActive` (`src/sa/LPManagerModule.sol:289-292`)
`isActive` reads only the stored expiry and the disabled flag. After a hybrid owner rotation or upgrade every redemption reverts while `isActive` stays true, so the keeper never winds down. A 7702 EOA that clears its designator leaves the delegation valid (the DelegationManager takes its ECDSA branch for code-less delegators) but not executable; if the EOA is later upgraded again to the canonical implementation, management resumes with no new consent until the expiry. **Fix:** add a code check to `isActive`, document that leaving requires `disableDelegation`, and have the keeper treat persistent redemption failures as an exit.

### L-15 — The enforcer bounds destinations, not value
**Severity:** Low · **Confidence:** 85 · **Origin:** [phase 1: amm] · **Location:** `ElysiumCustodyEnforcer._checkSwap` (`src/sa/ElysiumCustodyEnforcer.sol:290-298`), `_checkModify` (`:211-260`)
The design says a module bug "still cannot send more than those slices to our own addresses, and nothing anywhere else". "The pool" is an unbounded sink: the enforcer accepts a swap of the whole balance with `minOut = 1` and any price limit (`limit;` at `:294`), mints with any ticks and maxima, chains of up to 16 actions, and operations on positions the module does not track. None of this is reachable through the current module (it computes `minOut` and the limit itself); it matters only if the module were defective. **Fix:** state in the client-facing text that the enforcer is a destination guarantee, or add a coarse stateful bound on swap input and a non-zero limit.

### L-16 — Hedge cap, hedge step and flow booking accept an anchor of any age
**Severity:** Low · **Confidence:** 75 · **Origin:** [phase 1: oracles+erc4626] · **Location:** `LPManagerModule.sendHedgeMargin` (`src/sa/LPManagerModule.sol:500-507`), `reportHedgeEquity` (`:548`), `_sync` (`:712`)
`maxPriceAge` and `lastPriceClipped` gate only the fee. `sendHedgeMargin` works while paused, exactly when the anchor is frozen: after a 50% drop under a pause, a cap of 35% of the anchor-based value is about 54% of the true value. Operator custody above the stated bound, not a third-party loss. **Fix:** require an unclipped anchor within band of the pool for `sendHedgeMargin`, or value base at the lower of anchor and pool price for the cap.

### L-17 — Approvals built by the module are never reset; the hybrid account's raw-hash ERC-1271 makes the owner's Permit2 signatures valid for the account
**Severity:** Low · **Confidence:** 70 · **Origin:** [phase 1: erc4337+proxies, erc20+signatures] · **Location:** `SALib.modifyExecs` / `swapExecs` (`src/sa/SALib.sol:132-177`)
After every mint, increase and ERC-20 swap the account's ERC-20 allowance to Permit2 keeps `max − used` with no expiry, and the Permit2 allowance lasts to the end of the timestamp ("same block" in the comments is inaccurate on Nitro). Neither is usable by a third party through PositionManager or SwapExecutor. But `HybridDeleGator.isValidSignature` checks the raw hash against `owner()`, and Permit2 permit digests do not contain the owner, so a Permit2 signature the owner made as an EOA is also valid for the smart account; the residual allowance gives such a replay something to pull through any third-party integration that lets a caller name the Permit2 owner. **Fix:** append `token.approve(Permit2, 0)` as the last execution (the enforcer already allows it).

---

## Informational

### I-1 — The enforcer's hedge limit is a rate on idle USDC, not a cap
**Severity:** Informational · `ElysiumCustodyEnforcer._checkTransfer` (`src/sa/ElysiumCustodyEnforcer.sol:318-326`). The limit is a decaying sum of `amount / balance-at-send`. With no top-ups it admits 35% of idle USDC in one block, about 58% in 24 hours, 82% in three days and 97% in seven; a defective module could first convert positions to USDC. The stock bound "treasury ≤ cap" therefore rests on the module's `netMargin` check; the enforcer alone buys reaction time. State this in the client-facing text.

### I-2 — A USDC blocklist or pause on the immutable operator addresses has no fallback
**Severity:** Informational · `src/sa/LPManagerModule.sol:97-98`, `:302-308`. If `feeRecipient` is blocklisted no fee can ever be charged; if `hedgeTreasury` is, sends and returns revert for all accounts; a blocklisted owner EOA blocks its own post-revoke return. Recovery needs a new module and new client signatures. Consider a rotatable beneficiary behind a fixed contract address and a client-settable payout address.

### I-3 — Parameter and boundary edges
**Severity:** Informational · `LPManagerModule._setParams` (`src/sa/LPManagerModule.sol:650-657`), `SALib.sol:155`. `maxSlippageBps == 0` is accepted but makes every swap and add revert. Hard-cap combinations are unsafe for existing clients after one delay (band 5% + slippage 5% + turnover 5x allows about 50% of value per day of execution loss; `hedgeStepBps` 20% zeroes equity in two days). Keeper actions carry no deadline (`modifyLiquidities` uses `block.timestamp`). A swap stopped by its price limit always reverts `BelowMinOut`; with the pool between one and two bands from the anchor, swaps in the away direction revert until the anchor follows.

### I-4 — Timelock as used here
**Severity:** Informational · `src/VaultTimelock.sol:42-49`, `:130-133`; `script/DeploySA.s.sol:72-73`. The default delay is 48 h (floor 24 h). The operator is the only proposer and executor; if it renounces its role or loses its key, no owner action (unpause, keeper rotation) is ever possible again. The guardian can cancel every `setPaused(false)` and `setGuardian`, so removing a hostile guardian takes two delays. The module's guardian and the timelock's canceller are separate slots.

### I-5 — Documentation and comment mismatches
**Severity:** Informational. "Module actions are bracketed by `_sync` / `_snap`" (`src/sa/LPManagerModule.sol:60-61`) is false for the zero-fee path and the not-live return. `SALib` says "Pure/view, no token movement" (`src/sa/SALib.sol:22`) but `flow` and `snapLiquidity` write module storage. "increments with every hedge report" (`src/sa/LPManagerModule.sol:140`): an equal report returns early. "otherwise its owner EOA" (`:301`): 7702 accounts and hybrids with a zero owner are paid at the account. "same-block" approvals are per timestamp. Design section 2 says LP is counted at the anchor; the code uses spot. `Registered` emits the full uint128 expiry while storage holds the narrowed value.

### I-6 — Account deployment and the vendored interface file
**Severity:** Informational. Account deployment through SimpleFactory is permissionless and `deploy` reverts on an existing address; the owner is bound into the CREATE2 address and initialisation is atomic, so an address cannot be pre-initialised with other keys, but a racing deploy reverts the relayer's batch once. `src/sa/vendor/DelegationFramework.sol` matches v1.3.0 in struct layouts, typehashes, hook and manager signatures, constants and the single-execution packing; `IDeleGatorCore.getImplementation` does not exist on the 7702 core (never called there), and a few vendored items are unused.

### I-7 — High-water-mark semantics
**Severity:** Informational · `SALib.hwmFee` (`src/sa/SALib.sol:96-102`). The mark is absolute USDC profit with no clawback: a fee on a gain later lost is not refunded. Profit includes unhedged HYPE appreciation at the anchor. A `feeBps` change through the timelock applies to profit already accrued. The formula itself is exact, floors in the client's favour, and the module and enforcer caps and clocks are consistent with each other.

### I-8 — Chain notes
**Severity:** Informational. Several Nitro blocks can share a timestamp (Permit2 expiry, deadline, decay clocks are safe within a transaction). Delegation expiry, fee interval and anchor age run on wall-clock time through sequencer downtime. Zero-fee user operations work on EntryPoint v0.7 but only self-bundled or relayed, and the owner EOA needs HYPE for the outer transaction. The build targets Cancun on a Prague chain (fine). The module has about 629 bytes of EIP-170 margin, so the fixes above should be measured and logic moved into `SALib` where possible. SwapExecutor, the module and the enforcer have no rescue for tokens sent by mistake.

---

## Access-Control Inventory

35 state-changing entry points in first-party code (LPManagerModule 20, ElysiumCustodyEnforcer 1, SwapExecutor 2, SALib 2 and RiskBudgets 3 linked-library externals, VaultTimelock 6, DeploySA 1), reconciled against the grep-verified pre-scan list with no disputes.

| Caller | Functions | Notes |
|---|---|---|
| Anyone | `register`, `onboard`, `deposit`; `SwapExecutor.swap`; the three no-op enforcer hooks | C-1, M-1, L-5 |
| Keeper | `reportPrice`, `mintPosition`, `increasePosition`, `decreasePosition`, `burnPosition`, `swap`, `sendHedgeMargin`, `returnHedgeMargin` (also treasury), `reportHedgeEquity`, `chargeFee`, `multicall` | pause blocks mint, increase, swap, fee only; a DelegationManager pause blocks everything that redeems |
| Guardian | `setPaused(true)`, `approvePrice`, `approveHedgeEquity`; timelock `cancel` | instant |
| Owner (timelock) | `setPaused(false)`, `setKeeper`, `setGuardian`, `setParams`, ownership transfer | every call waits the delay; `renounceOwnership` reverts |
| DelegationManager | `ElysiumCustodyEnforcer.beforeHook` | only writer of `spend` |
| PoolManager | `SwapExecutor.unlockCallback` | only during its own `swap` |

Examined, no issue: the enforcer's default-deny dispatch, canonical-encoding checks and per-action decoding against PositionManager; the redeemer and delegate binding (the module is the only redeemer; no redelegation is possible); `multicall` under self-delegatecall (role checks and guards hold per inner call); `SwapExecutor` (caller-only payer and recipient, callback gate, sync / settle / take order, native refund); the module-built executions against the enforcer branches; the fee formula and the two fee caps; the hedge-send cap on `max(hedgeEquity, netMargin)`; removals at a displaced spot (no loss); the delegation digest and domain against the framework; `deposit`; the vendored types against the v1.3.0 tag.

## Threat Model — catalog answers

| # | Threat row | Answer |
|---|---|---|
| T1 | Calldata the enforcer accepts moving value outside {account, pool, treasury, fee recipient} | Invariant holds for destinations; value into the pool is unbounded → L-15 |
| T2 | Registration of someone else's or an older delegation | Violated → M-1; L-5 |
| T3 | `onboard` payer = `account.owner()` | Violated → C-1 |
| T4 | Hostile client controlling account code | Violated → H-2; L-13, L-14 |
| T5 | Keeper and the shared treasury allowance; hedge cap and step | Violated → H-1; M-3, L-4, L-6 |
| T6 | Contribution bracketing and fee | Violated → H-3, M-2, M-5; L-2, L-13 |
| T7 | Anchor, band, turnover as loss bounds | Violated in part → M-7, M-4; L-9, L-16 |
| T8 | SwapExecutor and Permit2 allowances | Invariant holds; residuals → L-17 |
| T9 | Client exit and griefing | Revocation holds; batch → M-8; griefing → M-5, L-3 |
| T10 | Guardian alone / DM owner | Cannot move funds; freeze duration → I-4 |
| T11 | Owner key | Delay holds; hard-cap combinations → I-3 |
| T12 | `multicall` and reentrancy | Invariant holds; gas isolation → L-3 |
| T13 | Enforcer `spend` state | Third parties cannot write it; the client can → M-6 |
| T14 | Deployer inputs | L-8 |

## Invariant Verification

| ID | Property | On-chain | Verdict |
|---|---|---|---|
| I-1 | Snapshots equal live balances after every module action | Yes | violated → H-3 (zero-fee path), M-2 (not-live return) |
| I-2 | `contributed` changes only through `_sync` and first registration | Yes | holds as stated; flows booked twice → H-3 |
| I-3 | Fee formula, interval and idle cap | Yes | holds; collectability → L-11 |
| I-4 | Hedge cap at each send | No | holds at send time; base inflatable → M-4, L-16 |
| I-5 | Keeper alone never raises `hedgeEquity` through a report | Yes | holds; approval ordering → M-3 |
| I-6 | `sendHedgeMargin` moves the amount to the treasury | No | violated → H-2 |
| I-7 | A return is at most what the account has outstanding | No | violated → H-1 |
| I-8 | Anchor moves within the budget | Yes | holds as coded; window and free path → M-7 |
| I-9 | Keeper price within band of pool and anchor; swap limit at the band edge | Yes | holds |
| I-10 | At most 4 tracked positions, each owned at mint | Yes | holds; check order → L-10; token identity → L-13 |
| I-11 | Account kind is canonical | No | violated → C-1, H-2 |
| I-12 | One stored delegation matching the stored hash | Yes | holds; replaceable by anyone → M-1 |
| I-13 | Turnover within the cap | Yes | holds at charge sites; under-charge → L-9; 2x window → M-7 |
| I-14 | Fee needs a fresh unclipped anchor | Yes | holds; no pool-band check → M-4 |
| I-15 | Enforcer target and selector allow-list | Yes | holds |
| I-16 | Hedge transfers ≤ 35% of idle USDC per decaying day | No | holds as a rate, not a cap → I-1 |
| I-17 | Fee transfer ≤ 20% once per 7 days | Yes | holds; clock consumable by the client → M-6 |
| I-18 | `spend` written only under a DelegationManager call | Yes | holds |
| I-19 | SwapExecutor pays and is paid by its caller only | Yes | holds |
| X-1 | Module-built executions ⊆ enforcer-accepted shapes | No | holds — every built execution hits the intended branch; the enforcer accepts more → L-15 |
| X-2 | Enforcer decoding equals PositionManager decoding | No | holds — verified action by action |
| X-3 | Executions run as written on a canonical account | No | violated → H-2 |
| X-4 | LP amounts at spot are consistent with the anchor | No | violated → M-4, L-13 |
| X-5 | `owner()` is the account's consenting owner | No | violated → C-1 |
| E-1 | Tokens only go to the account, the pool, the treasury or the fee recipient | No | holds for the enforcer path; violated for module-held allowances → C-1, H-1 |
| E-2 | One client's hedge accounting cannot affect another's | No | violated → H-1, H-2 |
| E-3 | Fee only on real profit above the HWM | No | violated → H-3, M-3, M-4, L-12 |
| E-4 | The client can always exit in one transaction | Yes | holds for the revocation; documented batch → M-8; revival → M-1 |

Could not verify locally: the ERC-721 base of PositionManager (`ownerOf` reverting for burned or unminted ids) and the framework's ERC-7579 execution library are not vendored in the checkouts used; the equivalent OpenZeppelin decoder was read instead. Whether the CREATE2 fixtures equal the v1.3.0 build was not checked (no builds were run).

---

*This review was performed by an AI pipeline. AI analysis cannot verify the complete absence of vulnerabilities and no guarantee of security is given. Nothing was compiled or executed; fuzzing the enforcer against v4-periphery encodings (as the design doc itself asks) and a fork test of each fix are recommended before deployment.*
