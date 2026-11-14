# SA audit round 2: findings grouped by root cause

Input: `docs/audit/sa_round2_report_1225.md` (0 C, 1 H, 4 M, 16 L, 11 I; commit `c5af69a`). Round 1:
`sa_round1_rootcause.md` (classes A-H), `sa_round1_response.md`.

Written before the fixes, as in round 1. The round-2 report shows the same pattern the pooled vault showed: the
round-1 fixes for flow booking (class B) closed the named paths, but the mechanism stayed the same (the module
reads the account's balances back after an action and decides with checks what the client "did"), and every check
had a gap. So this round replaces the mechanism instead of adding checks. The fixes are on branch `sa-r2-fixes`.

| Class | Root cause | Findings |
|---|---|---|
| B' | The books are written from what the account holds after a module action, and flows are valued at a price chosen per direction from unbanded / lagging prices | H-1, M-1, M-2, L-9, L-14, I-10 [L-15] |
| D' | Price trust is one global flag with the wrong semantics: set by a one-unit gap, cleared only by the next report, refreshed by a clipped report, and an anchor moved in the same transaction counts as trusted | M-4, L-1, L-2, L-5, L-16, I-1, I-7 |
| A'' | Consent to move money is taken from a standing ERC-20 allowance rather than from a signature for this payment | M-3 [L-11] |
| G / F / H | Residuals of round-1 classes (roles, pause, deploy, exit liveness) | L-3, L-4, L-6, L-7, L-8, L-10, L-12, L-13, L-15, I-3, I-5, I-6, I-8, I-9, I-11 |

---

## B'. The books are reconstructed from the account instead of being computed

**What went wrong.** In round 1, every module action was a bracket: `sync` (book what changed since the last
snapshot), the action, then `_snap` (read the account's balances and the touched position back as the new snapshot),
plus checks meant to stop account code from moving value inside the bracket (`_post`: idle may fall only by what the
action spends; `_conserved`: value at the pool price may not fall on a removal; `_checkAdd`: the H-3 add check).
Whatever the account held after the action became "booked". Every finding in this class is a way for account code
to change what it holds inside the bracket without failing a check:

- M-1: an increase whose execution the account skipped. The add check valued the *requested* liquidity; the
  snapshot read back the untouched idle; the account later re-deposited and was credited a second time.
- M-2: removal proceeds moved by account code into *another* tracked position. The closing snapshot covered only
  the touched position, so the next sync booked the other position's growth as a new contribution.
- L-14: a swap's output above `minOut` forwarded inside the bracket; `_post` allowed idle to fall by `amountIn`.
- I-10: `_conserved`'s tolerance scaled with the whole account.

Independently, H-1 and L-9 came from the price: round 1 booked inflows at min(anchor, pool) and outflows at max to
favour the client, and the pool price is slot0 at the moment of the sync, unbanded. A displaced spot (or a lagging
anchor with no attacker at all) became a permanent change to `contributed`, so a fee on principal, or (the other
way) a client-made gap in the books.

**Why checks cannot close it.** A check bounds one quantity on one path. The account's code runs inside every
redemption (`executeFromExecutor`, `isValidSignature`, `receive`), so it can move value between any two things the
check does not look at: the other positions (M-2), the other token (L-14), the request vs. the result (M-1). The
number of such pairs grows with every feature. The fix must make the books independent of what the account does.

**Invariant B'.**
1. The snapshot (idle asset, idle base, the liquidity of every tracked position) is the state the books account
   for. A module action never reads it back from the account; it adds its own effect, computed from state the
   account's code cannot write:
   - LP add / remove: the principal at PoolManager's slot0 sqrt price read *before* the action, for the liquidity
     the module asked for (add: rounded up, as PoolManager charges; remove: rounded down, as it pays), plus the
     uncollected fees from `getPositionInfo` / `getFeeGrowthInside` (paid out by any modify);
   - swap: `(paid, received)` from the SwapExecutor's per-payer transient record of the swap it just ran (the module
     requires exactly one new record for this account and `received >= minOut`);
   - transfers out (hedge margin, fee): the amount verified at the recipient;
   - deposits / onboard pull: the USDC amount (booked at face value at once);
   - margin returns: the amount the module transferred in.
2. Therefore `live − snapshot` is exactly what the client did, inside or outside a module bracket: a skipped
   execution, a skim, a redirect, a direct deposit or withdrawal, a direct LP change all look the same.
3. `sync` books `live − snapshot` as a client flow, valued with the same function and the same price as `value`
   (the anchor), and moves the snapshot to the live state. So at the moment of booking `value` and `contributed`
   move by the same amount: **a client flow cannot change profit**, whatever the pool or the anchor lag is.
4. `sync` books only while the anchor is trusted (D'). Otherwise it does nothing: the flow stays pending, still
   exact, and is booked at the next trusted sync. Fees run only after a sync with a trusted anchor, so every pending
   flow is booked before profit is measured.
5. A removal only removes what the books know: m = min(requested, snapshot) of a tracked position (burn: the
   snapshot). Liquidity the client added or removed directly stays pending on both sides (position and idle), so it
   is booked once, at the anchor.

Profit between two trusted syncs is then `Δvalue − flow` = price moves on the booked holdings + LP fee growth +
hedge equity changes. The module never needs to detect account behaviour.

**Price: one price, not min/max in the client's favour (rebuttal of the suggested direction).** We considered
booking inflows at min(anchor, spot) and outflows at max (with spot banded). That is what round 1 did, and it is the
cause of H-1: any price for flows that differs from the price used for `value` turns the difference into profit or
loss. With a direction-dependent price the difference is not even bounded: a client can cycle the same HYPE in and
out; each round trip raises `contributed` by size × (max − min) with no capital change, which lowers measured profit
permanently and shields real profit from the fee. Banding only limits the step (1.5% per cycle at the default band);
repetition makes it unbounded. With one price, a round trip is exactly zero (test
`test_H1_Sibling_DepositWithdrawCyclesNetZero`). The protection the suggestion aimed at (displacement must never
become a fee on principal) is given instead by: (a) booking only at a trusted anchor, (b) the fee measured at
min(value at anchor, value at pool) − contributed.

**Fee on a conservative gain.** `chargeFee` requires a trusted anchor, syncs (booking every pending flow), and charges
on `min(V(anchor), V(pool)) − contributed`. A keeper who displaces the pool upward cannot raise the min; a walked
anchor needs the pool within the band of it for `minPriceStable`.

**Structural changes.**
- New linked library `SABook` (`sync`, `value`, `lpAdd`, `lpRemove`). `_snap`, `_post`, `_conserved`, `_held`,
  `_checkAdd`, `SALib.sync/post/held/signedDelta/addCharge` removed.
- `snapAsset` / `snapBase` are `int256` (the computed snapshot may sit above live after a client withdrawal).
- `SwapExecutor` writes `(count, paid, received)` per payer to transient storage; `lastSwap(payer)` view.
- `deposit` / `onboard` book at face value immediately; registration books nothing (closes L-9 and the
  first-registration path of H-1).
- H-3 add check kept, on the computed principal at the anchor (`SABook.lpAdd`), turnover on the same quantity.

**Siblings we checked.** Every module path that changes account state: register (books nothing), onboard / deposit
(face value), mint / increase (computed add + `checkMinted` for mints), decrease / burn (computed remove of m),
swap (executor record), sendHedgeMargin (recipient delta), returnHedgeMargin (amount in), chargeFee (recipient delta),
reportHedgeEquity (no idle effect), revoke (no booking; the books freeze). Native HYPE refund in a mint (SWEEP): the
computed add covers only the principal; the swept surplus never left the account. Positions the client burned or
transferred out: dropped at the next trusted sync, their snapshot liquidity booked as an outflow.

**Residuals (stated, bounded).**
- Client-collected LP fees (I-2) and the uncollected fees of a position the client transfers out leave the fee
  base. Bounded by LP fee income since the keeper last touched the position. Operational mitigation: the keeper
  collects before `chargeFee`.
- Account code that moves the pool inside an LP-add bracket changes what PoolManager actually charges; the
  difference is pending and booked at the anchor like any other client flow (profit unchanged); the client pays the
  swap fee.
- A keeper who holds the pool displaced by up to the band for `minPriceStable` against arbitrage can make a fee read
  at most band × base exposure of phantom gain (1.5% × exposure × 15% fee). Costly in a pool of this depth; the
  window can be raised by the timelock.
- A mint at `MAX_POSITIONS` may need a trusted sync first to drop positions the client burned.

## D'. Price trust: per cause, self-clearing, never in the same transaction as a move

**What went wrong.** `lastPriceClipped` was a stored global flag: set by any unapplied part of a report (M-4: a
one-unit gap), cleared only by the next fully applied report, and the guardian range charged its whole move to the
window, saturating it for 24-27 h. `hedgeClipped` was cleared by re-reporting the stored value (L-1). The keeper-only
hedge step cap looked only at the anchor age, which a clipped report refreshes (L-2). `_checkPoolBand` measured the
band against the argument (L-5). `_fresh` accepted an anchor written earlier in the same transaction, so walk + fee +
walk back was possible (L-16). The guardian range was consumed by any in-range report (I-7).

**Invariant D'.** Trust is a pure function of current state, per cause, and clears itself:
- anchor clipped ⇔ the anchor is outside the band of the keeper's last report (`lastPriceClipped()` is a view over
  `lastPrice` / `lastReported`);
- fresh ⇔ reported within `maxPriceAge` AND not clipped AND the pool within the band of the anchor (`_freshOk`);
- trusted ⇔ fresh AND the anchor value unchanged for `minPriceStable` (new parameter, [60 s, 1 day], default 300 s;
  `lastPriceMoved` is written only when the value changes). Booking and fees need trusted, so no anchor move and
  fee (or booking) in one transaction or block;
- hedge clipped: only a lower report clears it, or a guardian approval;
- band measured against the reference (`_off(x, ref)`), the pool for keeper prices;
- the guardian range is used only when the move exceeds the room, and charges only the room.

**Siblings.** Keeper-only hedge cap (now 0 unless fresh); margin sends (fresh); LP adds / swaps (keeper price in band
of pool and anchor). I-1 (drift compounds to e^cap) is documented with the correct bound.

## A''. Consent: a payment needs a signature for that payment (M-3)

**What went wrong.** `onboard` could pull from the pinned owner's standing allowance for any amount at any time; the
permit could fail silently. Round 1 treated the permit as optional because of front-running.

**Invariant.** Every pull from the owner is authorised by a permit signed for this amount and this deadline.
**Change.** `SALib.pull`: the permit must succeed; if it reverts (front-run), the pull proceeds only if the same
signature was used: the owner's nonce is exactly one past the signed one, the deadline has not passed, the signature
recovers to the owner for (owner, module, amount, nonce − 1, deadline), and the allowance equals the amount. A
standing allowance is never used. **Sibling:** L-11 (top-ups in the delegation's last day) fixed: re-registering the
stored, non-revoked delegation returns before the delegation checks.

## Residuals of round-1 classes

- L-3 (first registration with any signed delegation): the relayer / API is the expected first registrant; the
  client can disable the delegation in the DM. Documented.
- L-4: multicall copies at most 256 bytes on failure (assembly); no per-entry gas bound (the keeper skips accounts
  whose calls fail). Partly.
- L-6 / L-7 / L-8 / L-15: fixed. L-13: the Permit2-side allowance is now zeroed in the same redemption (no
  allowance survives to the end of the timestamp); the ERC-20 `approve(Permit2, 0)` reset still overwrites a 7702
  wallet's standing Permit2 approval (partly; stated in the client text).
- L-10 (account refuses only the fee transfer): no on-chain rule; an operator rule (stop managing an account whose
  fee fails on two consecutive due dates) is proposed and not yet implemented in the keeper.
- L-12 (DM pause by a third party): documented; client exit does not depend on it.
- I-3 / I-5 / I-6 / I-8 / I-9 / I-11: documented in the response.
