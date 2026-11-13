# SA audit round 1: findings grouped by root cause

Input: `docs/audit/sa_round1_report_1224.md` (1 C, 3 H, 8 M, 17 L, 8 I; commit `591f787`) and the shared-component
sections of the pooled-vault round 2 report `docs/audit/round2_report_1223.md` (RiskBudgets M-2 / L-1 / L-2, guardian
price range H-2, hedge approval M-3, anchor age L-7, pause L-4).

Why this document exists: in the pooled vault, round 2 showed that about half of the round-1 fixes closed the
auditor's proof of concept and left the root cause open. So every finding below is assigned to one root cause; each
class states the invariant that must hold, the structural change that enforces it (rather than a guard on the named
path), and the sibling paths that share the cause but were not named. The fixes are on branch `sa-r1-fixes`; the
per-finding status is in `sa_round1_response.md`.

Eight classes. Every finding of the report is in exactly one primary class (secondary links in brackets).

| Class | Root cause | Findings |
|---|---|---|
| A | The module trusts state and behaviour of client-controlled code (`owner()`, `getImplementation()`, executions, receive hooks, subscribers) | C-1, H-2, M-5, L-13, L-14, L-17, I-6 [L-3] |
| B | Flow accounting snapshots are written by the caller, not by the primitive | H-3, M-2, L-2, L-9, L-10, I-5 [M-5, L-13] |
| C | The delegation the module acts under is not pinned to the client's choice | M-1, M-6, L-1, L-5 [L-14] |
| D | Decisions that gate fees and custody value positions at unbanded spot or use a stale / clipped anchor | M-4, L-11, L-12, L-16, I-7 [M-7a] |
| E | The budget primitive does not mean what the documents say (window, zero writes, gross vs net, asymmetric) | M-7 (b), I-1, vault M-2, L-1, L-2 |
| F | Guardian approvals are not bound to the state that was judged, not one-shot, not cleared | M-3, M-7 (c), L-7, vault H-2, M-3, L-6 |
| G | Shared-treasury and pause semantics: movements not bounded by the account's own ledger; pause not a stop | H-1, L-4, L-6, L-8, I-2, I-3, I-4, vault L-4, L-7 |
| H | Exit liveness rests on an all-or-nothing batch whose failure is invisible | M-8, L-3 [L-15, I-8] |

---

## A. Client-controlled code is trusted for identity, consent and transfer outcomes

**What went wrong.** The module asked the account who its owner is (C-1), asked it what implementation it runs
(C-1 variant 3, H-2), and judged its executions by the account's own balance (H-2). All three answers come from code
the client controls: the HybridDeleGator owner can rotate keys or upgrade the implementation through its own
`execute`, a 7702 EOA can re-point its designator, and a non-canonical contract can answer anything. The same trust
appears where the module lets client code run inside its own bracket (position subscribers, the account's
`receive()`, `executeFromExecutor`) and where it records what the keeper asked for instead of what PositionManager
holds (L-13).

**Invariant A.** (1) Who pays into an account and who owns it are fixed by facts the account cannot change after
creation. (2) Every transfer that matters to a third party (treasury, fee recipient, other clients) is verified at a
balance the account cannot influence. (3) Every tracked position is described by PositionManager state, not by the
keeper's request or the account's behaviour. (4) Whatever client code does inside a module action can only make the
module's books more conservative, never let value leave unbooked. (5) A change of account code or owner after
registration is a revocation.

**Structural changes.**

- *Identity by derivation, not by question.* A hybrid account is accepted only if its address equals
  `SimpleFactory.computeAddress(keccak(ERC1967Proxy ‖ (HybridDeleGatorImpl, initialize(owner, [], [], []))), ACCOUNT_SALT)`
  for the `owner` it reports. The CREATE2 address commits to the implementation, the owner and the absence of P256
  keys at creation, so the reported owner is checked against the address, not believed. The owner is pinned in the
  module at registration. A 7702 account is the EOA itself (owner = account) and is recognised from its code (the
  designator), not from a call.
- *Payer = pinned owner, payee = the owner's unique account.* `onboard` pulls only from the pinned owner and only into
  the one account derived from that owner. No address can be the pinned owner of an account it did not sign for (the
  delegation signature is checked by the account, whose only signer at creation is that owner). The owner may not be
  the hedge treasury, fee recipient, keeper or guardian.
- *Recipient-side verification.* Hedge sends and fees are verified by the recipient's USDC balance delta (we own
  both recipients; USDC has no hooks), plus the account-side delta; the ledgers are written only after both.
- *Mint read back from PositionManager.* After a mint the module reads `getPoolAndPositionInfo(tokenId)` and
  `getPositionLiquidity(tokenId)`: fixed pool, the requested ticks, the requested liquidity, owned by the account, no
  subscriber. The stored ticks come from PositionManager.
- *No client code inside a bracket on the module's books.* Subscribed positions are refused for increase / decrease /
  burn. Each action ends with a directional post-check against the pre-action snapshot (`_post`): idle balances may
  fall at most by what the action itself spends (decrease / burn / return: nothing; swap: the input; add: the
  maxima; hedge / fee: the exact amount, already verified at the recipient). The closing snapshot covers only the
  position the action touched, so a change to any other tracked position inside the bracket is still booked as a
  flow at the next sync.
- *Code / owner change = revocation.* Every redeeming keeper action re-checks that a 7702 account still carries the
  designator it was registered with and that a hybrid account's `owner()` (gas-capped call) still equals the pinned
  owner. `isActive` reports the same.
- *Approvals reset.* Every ERC-20 approval to Permit2 built by the module is followed by `approve(Permit2, 0)` in the
  same redemption (L-17).

**Sibling paths the report did not name** (all closed by the same changes):

1. `payoutAddress` paid post-revoke margin to `owner()` read live: a client-controlled redirect of treasury funds.
   Removed; margin always goes back to the account itself (see class B).
2. `deposit` is safe (pulls only from `msg.sender`), but `onboard` reached `_register` with a hash mismatch from
   any caller, so the C-1 pull also worked against a freshly re-registered account: now registration of a different
   delegation needs the client (class C), and the payer is derived.
3. Native HYPE paid to the account (SWEEP after a mint, SwapExecutor output) runs the account's `receive()` inside
   the bracket: covered by the directional post-check.
4. `swap` measured `out` at the account only; a hostile account could also move other value out during the swap.
   Covered by `_post` on the input currency (the output is checked against min-out as before).
5. `increasePosition` on a position the client subscribed after the mint: refused like decrease / burn.
6. `_lpAmounts` valued token ids the account no longer owned until the next sync (L-13, also overstated the hedge
   step cap): valuation now goes through the same per-position function as flows, and every action syncs first
   (including `reportHedgeEquity`).
7. HybridDeleGator's raw-hash ERC-1271 (L-17): the residual ERC-20 allowance was the only thing a replayed owner
   signature could pull through; it is now always reset to 0.
8. Found while writing the regressions: on `decreasePosition` / `burnPosition` the directional post-check alone is
   not enough. The proceeds raise idle USDC above the pre-action snapshot, so account code that sends part of the
   proceeds away inside the bracket still passes `_post`, and the closing snapshot then hides the missing value as a
   loss (fee evasion of the M-5 kind, without a subscriber). Fixed with a value-conservation check: the account value
   at the pool price (unchanged inside the call) may not fall by more than rounding (0.001% + 2 wei) across a removal.
   Test: `test_M5_Sibling_AccountCodeDrainsInsideBracket` (real UUPS upgrade of the HybridDeleGator).
   On adds the same drain is bounded by the H-3 add check (`paid` ≤ value received / (1 − slippage)) and charged to
   turnover; on swaps by min-out and `_post` on the input.

**Residual (stated, not fixed).** A hybrid owner can still upgrade its proxy to arbitrary code; the module cannot read
the ERC-1967 slot. After the changes above that only harms the client's own account: identity, payer, treasury and fee
transfers, tracked positions and flows no longer depend on what that code does.

## B. Flow-accounting snapshots are the caller's job

**What went wrong.** `_sync` booked flows and left the snapshot update to a later `_snap`. Every path had to remember
both. `chargeFee` returned between them when the fee was zero (H-3), `returnHedgeMargin` skipped both when the account
was not live (M-2), `register` turned them into an on-demand booking for anyone (L-2), `mintPosition` read tracked
state before syncing (L-10), and `increasePosition` netted collected fees into `paid` (L-9: an accounting bracket that
mixes two effects).

**Invariant B.** After every module call that touches an account, the snapshots equal the live state; every change
between two snapshots is either booked once as a flow, or is the post-checked effect of the module's own action. No
path, including early returns, zero-fee, non-live, re-registration and wind-down, is exempt.

**Structural changes.**

- `_sync` books the flow **and** writes the snapshots (idle USDC, idle HYPE, every tracked position's liquidity) in
  the same step. A caller that returns early after `_sync` can no longer leave a stale snapshot; booking twice is
  impossible because the second `_sync` sees zero difference.
- `_snap` after the action covers only what the action changed (idle balances + the touched position).
- `returnHedgeMargin` always pays the account (never the owner EOA) and is always bracketed, live or not.
- Re-registering the stored delegation is a no-op (no sync); a different delegation needs the client (class C).
- First registration goes through the same `_sync` from zero snapshots (one booking rule for everything).
- Flows are booked conservatively for the operator: a value-increasing flow (deposit, client LP add) at the lower of
  anchor and pool price, a value-decreasing flow at the higher (L-2 and the anchor-lag part of L-13). Positions and
  flows use the same valuation function (`SALib.liquidityValue` at the anchor, see class D).
- `increasePosition` adds the position's uncollected fees (valued at the anchor) to `paid` before the H-3 check (L-9).
- `mintPosition` syncs before checking `MAX_POSITIONS` (L-10).

**Sibling paths the report did not name.**

1. `reportHedgeEquity` used `accountValue` without syncing, so positions the client had burned or transferred still
   counted toward the step cap: now synced.
2. `sendHedgeMargin` wrote the ledgers before the transfer was verified (H-2 ordering): now after.
3. A partial fee (L-11) is a second early-return shape in `chargeFee`: handled by the same `_sync` rule.
4. Fees the client collects directly are still booked as a contribution (the design's documented leakage, open
   issue 5). Fixing it would need a per-position fee-growth snapshot; bounded by uncollected fees and in the client's
   favour, so it stays acknowledged.

## C. The delegation is not pinned to the client's choice

**What went wrong.** Anyone could register any delegation the client had ever signed, in any order (M-1); the
enforcer's stateful limits were keyed by delegator only, so the client's own second delegation could consume them
(M-6); unsigned `args` rode along (L-5); the stored expiry was narrowed so that the module's idea of liveness differed
from the DelegationManager's (L-1).

**Invariant C.** The module acts under exactly one delegation per account; only the client can replace it or stop
it; every piece of state derived from "the delegation" (enforcer limits, expiry, liveness) is keyed by what the client
signed and matches what the DelegationManager enforces.

**Structural changes.**

- First registration is permissionless (relayer onboarding). Replacing the stored delegation, or registering again
  after a revoke, requires `msg.sender` = the account or its pinned owner.
- `revoke(a)` (account or pinned owner; no external call, not pausable) stops the module for that account (class H).
- The enforcer keys its state by `(delegator, keccak256(terms))`. Our terms are fixed per module, so renewals keep
  their history, and a delegation with other terms (another redeemer) has its own slot and cannot touch ours.
- `checkDelegation` requires empty caveat `args`, a 65-byte signature, and `until <= type(uint64).max`.

**Sibling paths.**

1. `onboard` called `_register` whenever the hash differed: covered by the same client-only rule.
2. Re-registering the stored hash was an on-demand `_sync` (L-2): now a no-op.
3. A revoked account re-registered by a third party with the same (still enabled) delegation: the revoke flag can only
   be cleared by the client.
4. The 7702 account that clears its designator and later re-delegates: liveness re-checks the code on every action
   (class A), so management resumes only if the exact registered designator is back, and `revoke` is the documented
   way to leave.

## D. Fee and custody decisions at unbanded spot or on a stale / clipped state

**What went wrong.** `accountValue` read LP amounts at pool spot and valued the base leg at the anchor. Spot can be
pushed, and LP value at a displaced spot exceeds the value at the anchor by `L(√s − √p)²/√s` (M-4). The fee checked
anchor age and the clipped flag but not the pool band; the hedge cap and the hedge step used an anchor of any age
(L-16); hedge equity entered the fee with no freshness and no clipped flag (L-12); a fee larger than 20% of idle could
never be collected (L-11).

**Invariant D.** Every value that gates a fee or a custody bound is the value at the anchor (positions valued by
liquidity at the anchor plus uncollected fees), taken only when the anchor is recent, unclipped and within the band of
the pool at that moment; hedge equity entering a fee was reported recently and not clipped downward.

**Structural changes.**

- `accountValue(a, price)` values positions with `liquidityValue(price)` + uncollected fees: no spot term at all.
- One gate `_fresh()` (anchor reported within `maxPriceAge`, not clipped, pool within `poolBandBps` of it) for
  `chargeFee` and `sendHedgeMargin`.
- Per-account `hedgeTime` and `hedgeClipped`: a report (also an unchanged one) records the time; a decrease clipped by
  the budget sets the flag. `chargeFee` requires a recent, unclipped report while the account has hedge equity. A
  refused increase does not block the fee (it understates value, in the client's favour).
- Partial fee: `min(fee, 20% of idle)`; the mark advances by the gain actually charged (L-11).

**Sibling paths.**

1. The turnover cap used the same spot-dependent value: now the anchor value too.
2. `reportHedgeEquity`'s step cap: anchor value after a sync.
3. First registration's opening `contributed`: booked by the conservative flow rule.

## E. The budget primitive

**What went wrong.** The decaying-day primitive restores linearly from the last write, so any 24 h window admits
`cap × (1 + T / 1 day)`: 2x (M-7 b, vault M-2). Every write re-bases the decay, including zero-size writes (vault
L-1). The hedge budget sums gross decreases and approved increases give nothing back (vault L-2). The price charge
`|p − ref| / ref` is asymmetric, so the anchor compounds (vault M-2). The enforcer's hedge limit is a decaying rate
with the same shape (I-1).

**Invariant E.** For every budget, the charges inside any 24 h window sum to at most the cap; a zero charge changes
nothing; guardian-confirmed movement back up is credited (the budget measures net keeper-only movement); a price step
costs the same up and down.

**Structural change.** A new sliding-window primitive `SAWindow` (internal library, used by the module and the
enforcer): nine 3-hour buckets in a ring; a charge goes into the current bucket; the room is
`cap − sum(last nine buckets)`. Any 24 h window touches at most nine consecutive buckets and every charge in it is
still inside the sum when a later charge in the same window is checked, so the admitted total in any 24 h window is
`<= 1x` the cap (capacity returns 24–27 h after a spend). No decay arithmetic, so no re-basing; a zero charge writes
nothing. `credit` removes from the newest buckets first (used for guardian-approved hedge increases). The price charge
is `|p − ref| / min(p, ref)`, so within 24 h the anchor stays within `ref × e^{±cap}`.

Used by: price anchor (global), turnover and hedge-decrease budgets (per account), and the enforcer's hedge fraction
(per delegator and terms). `RiskBudgets` is left as is for the shelved pooled vault.

**Sibling paths.** The enforcer's own rate (I-1) is now the same window (35% of idle per any 24 h, charged as a
fraction of the balance at each send, so still a rate on a moving balance; stated as such). The keeper's
`turnover_room` mirror now reads the module's own view instead of re-implementing the decay.

## F. Guardian approvals not bound to the judged state

**What went wrong.** A hedge approval took no expected epoch or stored value, and margin moves did not change the
epoch (M-3, vault M-3). A price range was free, unclipped and reusable until expiry (M-7 c, vault H-2). Neither was
validated, both survived a guardian change and a pause, and a refused report bumped the epoch (L-7, vault L-6).

**Invariant F.** A guardian approval authorises exactly one transition, from the exact state the guardian saw, to one
value; it is consumed on use, expires within a fixed TTL, and is voided by any change of that state, by a guardian
change and by a pause.

**Structural changes.**

- `approveHedgeEquity(a, expectedEpoch, expectedStored, value, until)`: reverts unless the account is registered and
  `hedgeEpoch == expectedEpoch` and `hedgeEquity == expectedStored`; `until <= now + 1 day`. `hedgeEpoch` increments
  on every change of `hedgeEquity` or `netMargin` (reports that change it, margin sends, margin returns) and only
  then: a refused or unchanged report does not move it.
- `approvePrice(lo, hi, until)`: `0 < lo <= hi`, `until <= now + 1 day`; consumed by the first report that uses it;
  the move is charged to the price window (it is not clipped, but later unapproved moves see the room it used).
- `setGuardian` and `setPaused(true)` clear the price approval; `setGuardian` also invalidates all hedge approvals
  (a global approval nonce stored with each approval).
- A guardian-approved equity also writes `netMargin` down to the approved value when it is lower (L-4: realised hedge
  losses no longer ratchet the cap shut, and only the guardian can confirm them).

**Sibling paths.** Approvals parked on unregistered addresses (now rejected); an approval applied after a margin move
in either direction (both bump the epoch); an approval raising equity while paused (still allowed, it is the
guardian's own value; a pause freezes only keeper-only movement).

## G. Shared treasury and pause semantics

**What went wrong.** `returnHedgeMargin` took any amount up to the shared treasury allowance, into any registered
account (H-1). The pause left margin sends and keeper-only equity decreases open (L-6, vault L-4). Roles could overlap
with the immutable treasury and fee recipient (L-8).

**Invariant G.** Value leaves the shared treasury only into the account whose own ledger says it is owed, at most that
amount, unless the treasury itself sends it; the keeper can never move value between accounts; a pause stops every
keeper action that increases operator custody or lowers a client's recorded claim, and nothing that returns value.

**Structural changes.**

- Keeper return `<= hedgeEquity` of that account (the per-account ledger the guardian bounds upward). Not `netMargin`:
  after a hedge loss `netMargin > hedgeEquity`, and returning `netMargin` would pay one client's realised loss out of
  the other clients' margin. The treasury may return more by calling itself (its own decision; it lands in the account
  as value, not as a contribution).
- Paused: `sendHedgeMargin` reverts; keeper-only hedge decreases are frozen (cap 0); returns, decreases and burns stay
  open.
- keeper, guardian, owner, hedge treasury and fee recipient pairwise distinct (constructor and setters).

**Sibling paths.** A compromised keeper sending from every account and then returning: each return bounded by that
account's ledger and paid into that account. A keeper registering its own account (ledger 0): nothing to return.
Documented: the treasury approves per return in operation (the deploy notes), and the remaining Informational items
(blocklist, timelock) are acknowledged in the response.

## H. Exit liveness

**What went wrong.** The documented one-transaction exit was one default-mode batch (disable + burns). One failing
burn reverts the revocation too, and under `handleOps` the failure is silent (M-8).

**Invariant H.** The client's "stop managing my account" step is one call with no external dependency that either
succeeds or reverts visibly; unwinding positions is per-step tolerant and verified by state, not by transaction
status.

**Structural changes.**

- `LPManagerModule.revoke(a)`: callable by the account or its pinned owner EOA (a plain transaction from the owner
  reverts visibly on failure); no external calls; works while the module or the DelegationManager is paused.
- The exit user operation runs in **try** mode: `revoke`, `disableDelegation`, then one burn per position with zero
  minimums. A failing burn (already burned by a racing keeper, a subscriber, a USDC pause) no longer undoes the
  revocation. The web page and the keeper tests verify `isActive == false` and `disabledDelegations(hash)` after
  inclusion, not the transaction status.
- `multicall` truncates the reason it logs (L-3); the account's `owner()` call is gas-capped.

**Sibling paths.** 7702 self-call exit: same try-mode batch. Exit while the DelegationManager is paused (no
redemption involved). Exit retried after a partial success (`disableDelegation` on an already disabled hash fails
alone in try mode).
