# Audit scope — round 11

**What to review:** `src/GuardedSwap.sol` (v12, this branch) and its interaction with the KyberSwap MetaAggregationRouterV2 on Base. One contract, no dependencies.

**Deployed:** Base (chain 8453), `0x455016186178544c1326cdbf9eb4a2d1a0c51ea4`, source verified on Sourcify (exact match):
https://sourcify.dev/server/v2/contract/8453/0x455016186178544c1326cdbf9eb4a2d1a0c51ea4

Previous subjects: v11 `0xdbc4fca0cc48baf929685b1393c1c93436ddbc9a` (round 10), v10 `0x72ac1cd4b96988b14b0a55b5bf962ba3eb314a39` (round 9), v9 `0x2ea0ed9b4eaf9e6c17231e10d56531ce77faef50` (round 8), v8 `0x061c0a41bb8d83e6fecc3142f3801fed9e5b88d4` (round 7), v7 `0xb1ef2b0c04e65b22e70bc6a54ddf454259d726e4` (round 6), v6 `0x259f17ed184ff97730407002140bcd512dca7a0a` (round 5), v5 `0x3511a33478465d2f6fd5ebfebf52160ef39ec7a1` (round 4), v4 `0x970b033ab9965ce9c9f92584b529afa6100a994e` (round 3), v3 `0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485` (round 2), v2 `0x91b51882805051b83efc53e7407a01894d341ca0` (round 1).

**What it must guarantee:** an executor key that calls this contract on behalf of a client's smart account can never move the account's ETH or tokens to anyone but the account itself; bad trades are bounded by a per-account loss budget (losses below cost at most 30% of the cost basis, refilling over a week; sales at or above cost are free), only the lot itself can be sold, and per-account hourly limits cap sales, ETH in and ETH out; a pause-only guardian can stop buys for at most seven days in eight and never blocks a sale; the operator's cold exit key can clear a budget (`unlock`) and run `exit` (a sale outside the budget and limits, still paid only to the account) to evacuate positions into ETH on the clients' own accounts when the executor key is compromised. Neither key can move funds anywhere else.

**Round 1 findings and what changed in v3**

| Finding | Status | Fix |
| --- | --- | --- |
| H-1 output check trusts attacker-chosen `token`; ETH routable to a third party | Fixed | `_checkRoute` decodes the router calldata (`swap` / `swapSimpleMode`): `dstReceiver` ∈ {caller, this}, no fee receivers, `srcToken`/`dstToken` = declared pair, `amount` = `msg.value` (buy) or tokens received (sell); `token` must have code |
| H-2 dust `buy()` disables the floor for the whole balance | Fixed | floor applies to the amount sold; selling more than the recorded basis makes the whole sale a slow one |
| M-1 floor relative to entry, not market | Accepted | documented; no oracle exists for the long-tail tokens in scope; bounded by hourly and daily limits |
| M-2 whole-contract ETH sweep is skewable / griefable | Fixed | per-call ETH accounting; pre-existing ETH is neither swept nor counted |
| L-1 fixed hour window, not rolling | Accepted | documented in NatSpec and README |
| L-2 announcements never expire, not bound to amount | Fixed | `announce(token, amount)`: valid from +1 h, for 24 h, up to `amount`, consumed by one sale |
| L-3 pause also blocks exits | Fixed | under a pause every sale takes the announced slow path; exits are delayed, never blocked |
| I-1 stray funds go to the next caller | Fixed | stray ETH stays in the contract |
| I-2 `balanceOf` unchecked for non-contract `token` | Fixed | `NotAContract` |
| I-3 documentation drift | Fixed | NatSpec and README rewritten |

**Round 2 findings and what changed in v4**

| Finding | Status | Fix |
| --- | --- | --- |
| C-1 `_sweepToken` reads the whole contract balance (stray / flash-loaned tokens inflate the basis; mis-credit; DoS) | Fixed | balances measured as per-call deltas around the router call; stray tokens are never swept or counted |
| C-2 `srcReceivers`/`srcAmounts`/`callTarget`/`approveTarget` unchecked | Fixed | executor pinned (`EXECUTOR`, simple-mode caller too), `approveTarget` zero or executor, buys may not name `srcReceivers`, sale `srcReceivers` must be contracts other than the caller with amounts ≤ input, router `minReturnAmount` ≥ our `minOut` |
| H-3 `buy()` has no floor; a bad repeat buy dilutes the basis | Fixed | a repeat buy may not set the entry price below half of the recorded one (`DilutesBasis`) |
| H-4 guardian is a bare immutable EOA | Fixed | two-step rotation (`proposeGuardian` / `acceptGuardian`); the key will be moved to a multisig |
| M-5 pause forces slow path; no cancel for announcements | Fixed / accepted | `cancelAnnounce` added; the pause-to-slow-path rule is the intended kill switch |
| M-6 `approve(0)` reset bricks BNB-style tokens | Fixed | reset is best-effort |
| L-7 partial slow sale consumes the whole announcement | Fixed | remainder stays usable |
| L-8 stray ETH stuck | Fixed | direct ETH refused (`receive` only from the router) |
| L-9 tokens returning `false` on success | Accepted | out of scope for the token set we trade |
| L-10 `announce` skips the contract check | Fixed | `NotAContract` |
| I-11…I-20 | Accepted / documented | fixed hour window, rounding drift, aliasing, flags/permit unchecked (covered by executor pinning), rebasing tokens, no oracle, constructor checks added (guardian ≠ router/executor, both contracts), `setPaused` under lock |

**Round 3 findings and what changed in v5**

| Finding | Status | Fix |
| --- | --- | --- |
| C-1 sale `srcReceivers` can be a planted sink; the slow path had no floor (up to 100% of a position) | Fixed / residual documented | the slow path keeps a 20% floor (`SLOW_FLOOR_BPS`, `BelowFloor`); the guardian can `cancelSlow` an armed announcement; sale `srcReceivers` cannot be restricted to the executor because the aggregator legitimately delivers input straight to the first pool — a planted sink is therefore bounded to the floors (50% fast, 20% announced), which is the documented residual |
| H-1 dilution guard compared with the running average; zero-basis bypass | Fixed | the first buy of a lot records a reference entry; repeats are compared with the reference (≥ 0.5x); a full exit resets the lot, so a new lot starts a new reference |
| M-1 no upper bound on a repeat buy's price | Fixed | ≤ 4x the reference (`REF_MAX_X`) |
| M-2 pause has no expiry or recovery | Fixed | a pause lifts itself after 7 days (`PAUSE_MAX`); the guardian may pause again |
| L-1 rotation distinctness, gross vs net hourly count, truncating casts | Fixed | `acceptGuardian` refuses router/executor; `_count` takes net spend; `TooLarge` on oversized `announce` amounts and ETH |
| L-2 rounding direction of the released cost; `_approveSoft`; fee-on-transfer leftover | Fixed / accepted | released cost rounded up (the remainder's floor never drifts upward); `_approveSoft` and the leftover sweep documented as accepted |
| I-1 README constructor drift | Fixed | README updated |

**Round 4 findings and what changed in v6**

| Finding | Status | Fix |
| --- | --- | --- |
| C-1 the slow-path floor priced only `min(sold, basis)`: untracked tokens and the excess over the basis sold with no price floor at all | Fixed | `announce(token, amount, minEth)` carries a price; a slow sale must return at least `minEth` pro rata over everything sold (tracked or not), and the tracked part must still clear 20% of its entry (`BelowFloor`). The watcher sees the announced price an hour ahead |
| H-1 guardian could re-arm the pause forever and cancel every announcement, blocking exits | Fixed | a pause may not be re-stamped; a new pause may start only 1 day after the last one ended (`PAUSE_COOLDOWN`); `cancelSlow` works only before maturity and once per account and token per 24 h (`CANCEL_COOLDOWN`), so the next announcement always matures |
| H-2 a stale announcement survived a full exit and armed a new lot | Fixed | a full exit and the first buy of a new lot both delete the account's announcement for that token |
| M-1 no value cap on sales | Fixed | `MAX_SELL_ETH_PER_HOUR` (production 1 ETH) on ETH taken out of sales per account and hour |
| M-2 router `permit` field forwarded unchecked | Fixed | `permit` must be empty (`BadRoute`) |
| M-3 a leftover allowance could brick zero-first tokens | Fixed | a non-zero allowance to the router is reset to zero before a new approval |
| M-4 multi-address tokens, M-5 rebasing tokens | Accepted / documented | not supported; stated in the README |
| M-6 the first buy of a lot has no price reference | Accepted / documented | the hourly ETH budget is the bound; the engine sets `minOut` from a fresh quote |
| M-7 `approveTarget` validated but allowance granted to the router | Verified | the router pulls the input itself (`transferFrom` by the router), confirmed by the fork test against the live router; `approveTarget` is the router's internal approval target |
| L-1 floors could truncate to zero | Fixed | ceiling division in every floor |
| L-2 unbounded `srcReceivers` | Fixed | at most 8 (`MAX_RECEIVERS`) |
| L-3 no deadline | Accepted | the executor submits directly, no relayer; `minOut` comes from a fresh quote |
| L-4 proposal hygiene | Fixed | `proposeGuardian` refuses zero, itself, router, executor; a proposal lapses after 7 days (`PENDING_TTL`) |
| L-5 failed refund unwinds the trade, L-7 unsupported token classes, L-8 double fee via `address(this)`, L-9 unbounded revert copy | Accepted / documented | callers must accept ETH; token classes listed in the README; prefer `dstReceiver = msg.sender` |
| L-6 router overpaying hit a bare panic | Fixed | `RouterOverpaid` |

**Round 5 findings and what changed in v7**

| Finding | Status | Fix |
| --- | --- | --- |
| C-1 the guardian's one cancel per day was spent by a decoy, then the real dump was re-announced and matured before the guardian could act | Fixed | an announcement made during the cancel cooldown matures only `SLOW_DELAY` after the cooldown ends (`announce`), so the guardian can always act on it once; worst case for an honest slow exit is a day and an hour |
| C-2 a partial sale could round the recorded entry cost to zero and leave the rest of the lot with no floor | Fixed | the running cost is gone: the floor is taken from the lot's reference price, which partial sales never touch |
| C-3 one repeat buy at the allowed boundary moved the blended floor of the whole lot | Fixed | same change: floors (fast 50%, slow 20%) come from the reference, so a repeat buy cannot move the floor of tokens already held |
| I-4 strict `allowance()` call | Fixed | tolerant `staticcall`, a misbehaving `allowance()` reads as 0 |
| Leads: unconstrained `targetData`/`clientData`/`flags`; `cancelAnnounce` front-run of `cancelSlow`; remainder deletion on a full exit; `refEthIn == 0` | Accepted / documented | the executor and `dstReceiver` are pinned and output is measured on the caller, so those fields can only change the route, not the payee; Base has no public mempool and a self-cancelled announcement never matures; the remainder deletion costs the account one extra delay; a zero-cost non-zero-output swap is not reachable through the pinned router (fork-tested routes) |

**Round 6 findings and what changed in v8** — this round was answered by removing mechanisms, not adding them (the findings of rounds 2–6 all arose where a fix interacted with an older mechanism: two price bases, two timers, states with different lifecycles, a limit on the defender that guaranteed a window to the attacker).

| Finding | Status | Fix |
| --- | --- | --- |
| H-1 a frozen reference under-protected tokens bought later at a higher price (floor as low as 12.5% of cost) | Fixed | the floor price is the higher of the reference and the cost-weighted average (one formula, both of round-5 C-3 and this round's H-1 closed); the average is reduced pro rata by sales, rounded down, so it never zeroes (round-5 C-2) |
| H-2 the guardian's cancel cooldown ended an hour before the maturity it had forced, so a hostile guardian could delay one exit forever | Fixed by removal | `cancelSlow`, `lastCancel` and `CANCEL_COOLDOWN` are gone; the guardian cannot touch announcements. The self-declared announcement price (`minEth`) is gone with them: `sell()` now handles only the lot this contract saw bought (`NotInLot`), so every slow sale is protected by 20% of the floor price and there is nothing left for a cancel to guard |
| M-1 a zero-first token with a leftover allowance could brick `sell()` | Fixed / documented | approve is tried directly, then after a zero; only a token that refuses `approve(0)` while demanding zero first remains unsupported (fails closed) |
| L-1 floor arithmetic could overflow for extreme raw units | Fixed | lots are bounded to 1e40 raw units (`MAX_LOT`) |
| L-2 views reported pre-trade state during the ETH refund hook | Fixed | all state is written before any ETH leaves |
| L-3 `swapSimpleMode` route check was dead code | Fixed by removal | only `swap(SwapExecutionParams)` is accepted |
| Info: zero-cost first buy | Fixed | a buy that spends nothing is refused |
| Info: rebasing, `balanceOf` lies on a self-seeded token, deploy-time trust in router/executor, returndata bombs, sequencer notes, `pausedAt` sentinel | Accepted / documented | as before |

**Round 7 findings and what changed in v9**

| Finding | Status | Fix |
| --- | --- | --- |
| C-1 `flags` was never checked: bit `0x20` inside the same `swap()` selector takes the deployed router into its simple mode, which pulls the sold tokens to pools named in `targetData`, a field this contract does not check | Fixed | every flag bit the router dispatches on (`0x01`–`0x100`: partial fill, extra ETH, claim, burn, simple mode, fees, approve) is refused; only `0x200`, which live routes carry and the router's verified source never reads, is accepted (`FLAGS_ALLOWED`). The lesson is recorded: the router's dispatch is read from its verified source, every field and every flag listed, and any value this contract does not understand is refused |
| M-1 `announce` was not bound to the lot and a repeat buy did not clear it | Fixed | an announcement never exceeds the lot (`NotInLot`); any buy of the token clears it |
| M-2 the first buy of a lot fixes the reference with no price bound | Accepted / documented | as round 4 M-6: the hourly ETH budget and the engine's quote-based `minOut` are the bound; no oracle exists for these tokens |
| M-3 fee-on-transfer / rebasing tokens could strand a lot above the real balance | Fixed | the lot shrinks by what the account gave up (pull-side fees included) and closes when the account holds none of the token |
| L-1 a sale paid to the caller directly reached its `receive()` before settlement | Fixed | a sale is paid to this contract only and forwarded after settlement (`dstReceiver == this`); ETH is accepted only while a trade is in progress (the live router unwraps through its executor, so the payer is not always the router itself); a buy may still deliver tokens to the caller |
| L-2 cost release rounds down (average drifts up) | Accepted / documented | protocol-favouring; erased on full exit |
| L-3 tokens that return `false` on success, L-4 issuer blacklisting the gate, L-5 `uint96` token ceilings, L-6 no deadline, L-7 public mempool, L-8 no minimum rotation delay, L-9 pause griefing bounded, L-10 returndata bombs, L-11 refund failure, L-12 `balanceOf` reverts, L-13 24-hour censorship | Accepted / documented | all self-only or already-documented trade-offs; the constructor now also bounds `maxSellsPerHour` to `uint64` (lead) |
| Lead: a partial fill leaves the router a standing allowance | Accepted / documented | only the router could spend it, and the router is trusted infrastructure; the cleanup `approve(0)` is best-effort by design |

**Round 8 findings and what changed in v10** — round 8 found no Critical and no High; the round-7 fixes hold against the router's verified source. What remains is economic (the guarantees are bounded by cost basis and by rate, not by market value) and lot bookkeeping.

| Finding | Status | Fix |
| --- | --- | --- |
| M-1 the floor is cost-based: an appreciated position can be sold fast for 50% of cost, and the sell cap bounds proceeds, not value given up | Accepted / documented, with the numbers | no oracle exists for these tokens; a market-based floor (owner-set band, high-water mark) is a product decision, not taken in this round. Stated in the README |
| M-2 buys are bounded per hour, not in total | Accepted / documented | the delegation that admits the executor to this contract carries its own daily cap (0.5 ETH per 24 h); the real bound is rate times time to revocation, stated in the README |
| L-1 a stale lot: tokens the owner moved out stayed in the lot (later arrivals sellable at the old floor, re-buys bricked by the old reference) | Fixed | the lot is reconciled with the account's balance at the start of every buy, sale and announcement (`_trim`): it never exceeds what the account holds (reduced pro rata, as if sold at cost), an empty balance closes it; tokens that arrive before the next call are indistinguishable from the lot and protected at its floor |
| L-2 a drop of more than 80% blocks even the announced exit | Accepted / documented | by design: the slow path is a delay, not a licence for dust; the owner sells directly |
| L-3 fee-on-transfer sweep drift | Accepted / documented | fee tokens are unsupported; the drift is protocol-favouring |
| L-4 a route returning everything plus a donation let `_settle` run with `sold == 0` | Fixed | a sale that moves nothing is refused (`ZeroAmount`) |
| I-1 `dstReceiver == 0`, I-2 token hooks see pre-state in `buy`, I-3 executor source unverified, I-4 `srcReceivers[i] == this` | Fixed (I-4) / accepted | the gate itself is refused as a receiver; the rest is conservative or documented |

**Round 9 findings and what changed in v11** — round 9 found no Critical, High or Medium; the rounding in `_trim` and in the cost release was proven algebraically, and the flag mask and `approveTarget` assumptions were re-verified against the router source. What remained were three Lows at the seams of the new reconciliation.

| Finding | Status | Fix |
| --- | --- | --- |
| L-1 `floorFor` / `slowFloorFor` quoted the raw record, not the reconciled lot | Fixed | the views run the same reconciliation without writing (`_trimmed`); `lotOf` exposes it |
| L-2 a fast sale, or a reconciliation, left a standing announcement larger than the lot | Fixed | the announcement is capped to the lot whenever the lot shrinks (`_capSlow` in `_trim` and after every sale) |
| L-3 a single `balanceOf() == 0` read closes the lot (reference and announcement included) | Accepted / documented | a lying token can only reset its own lot, which is the accepted first-buy residual; a transient zero from an honest token closes the lot, and the next buy opens a new one — no value moves |
| I-1 `cancelAnnounce` without the contract check, I-2 guardian == this, I-4 router == executor | Fixed | checks added |
| I-3 lapsed proposal not cleared, I-5 read-only reentrancy, I-6 fee-on-transfer refund leg, I-7 router assumptions | Accepted / confirmed | as documented |

**v12 — a product decision, not an audit response.** The 50% / 20% price floors of v5–v11 blocked honest exits on deep crashes (an hour's delay past −50%, no exit through the gate past −80%) and could not be explained to clients. No service without an oracle bounds a sale against the market (Enzyme's cumulative slippage policy needs one; Hyperliquid's agent wallets and exchange API keys bound nothing but withdrawal; intent systems need the owner's signature per trade), so v12 replaces the floors with the one bound that is explainable and does not need a price: a per-account loss budget, plus a cold exit key for the incident itself. Removed with the floors: announcements, the slow path, the first-buy reference and the repeat-buy band — four states fewer. The round-11 scope is this new budget/exit mechanism and its seams with the lot rule and the hourly limits.

**Round 10 findings (v11, no code change)** — round 10 found no Critical, High or Medium. The four Lows are recorded here with their disposition; none moves value and none is acted upon before the next call reconciles the lot. A further version is a product decision, not a security need.

| Finding | Status | Response |
| --- | --- | --- |
| L-1 the leftover returned by a sale is measured by this contract's balance drop, not by what the account receives (a fee on the return leg) | Accepted / documented | only fee-on-transfer tokens are affected, and those are unsupported; the next call's reconciliation (`_trim`) corrects the lot from the live balance before anything acts on it |
| L-2 the views have no read-only reentrancy guard and can quote a pre-settlement lot from inside an in-flight `sell()` | Accepted / documented | the contract never consumes its own views; integrators should treat `floorFor`/`slowFloorFor`/`lotOf` as valid only when no trade of theirs is in flight |
| L-3 the returndata of a failed router call is copied unbounded into `RouterFailed` | Accepted | self-only gas cost for the caller who chose the token |
| L-4 trailing bytes after the ABI-encoded `SwapExecutionParams` are not rejected | Accepted / verified | the router is Solidity: its `swap(SwapExecutionParams)` decodes its argument with the ABI decoder and never reads calldata beyond the tuple, so trailing bytes change nothing on either side |
| I-1 first-buy reference, I-2 `targetData`/`clientData` unread, I-4 `approveTarget` validated but unused, I-5 best-effort `approve(0)`, I-6 lot not re-priced when the balance returns, I-7 `uint192` narrowing in `_capSlow` (bounded by `MAX_LOT`), I-3 `proposeGuardian(this)` lapses harmlessly | Accepted / documented | as in earlier rounds |

**Tests:** `forge test --no-match-contract Fork --fuzz-runs 2000` (35 tests, the earlier rounds' PoCs that still apply included) and `forge test --match-contract Fork --fork-url <base rpc>` (3 tests against the live Kyber router with real calldata, including an exit by the cold key). All pass on Foundry 1.8.5 / solc 0.8.26.

**Round 11 findings (v12) and what changed in v13** — round 11 found 1 Critical, 2 High, 1 Medium, 3 Low. All three serious findings sit at the seam between the new loss budget and the live cost basis it was measured against; v13 freezes the one moving part and hardens the two token-facing calls.

| Finding | Status | Fix (v13) |
| --- | --- | --- |
| C-1 the budget's refill was computed from the live, account-wide cost basis: new buys sped up the refill (B), closing the lot after a full-exit loss froze it forever (D), and cycling close-and-redeploy compounded losses past 30% (C) | Fixed | the refill rate is stored with the loss (`Loss.rate` = the budget in force when it was booked) and decays against that; while a loss is outstanding the rate is never raised by a later booking (it can only follow a shrinking budget). A loss now outlives the lots it came from and fades in at most `REFILL`. Mechanism (A) — a 0.3 ETH buy adds 0.09 ETH of allowance — is the designed proportionality of a 30%-of-cost budget and is bounded by `MAX_BUY_ETH_PER_HOUR`; mechanism (E) — a stale lot inflating the ceiling — needs tokens to leave the account outside this gate (the executor's permissions cannot move them) or a negative rebase, and is documented as a residual |
| H-1 an unguarded `balanceOf` in `_trim` let a token whose balance stops answering block `sell()` and `exit()` for good | Fixed | balances are read through a `staticcall` that reports failure; an unreadable balance keeps the last known lot (`_trim`, `_trimmed`), is never taken as empty in `_settle`, and the outbound sweep falls back to what left this contract |
| H-2 `exit()` runs outside the loss budget, so a malformed route with `srcReceivers` chosen by whoever builds the exit transaction is not bounded | Accepted / documented | by design: exit exists for the cases the budget would block (a crash, a compromised executor). The exit transaction is built on the operator's own side with an independent quote and refuses a `minOut` below 90% of it; the gate measures `out` itself and reverts below `minOut`, so a sink route cannot take more than that margin. Not reachable from the executor's permissions (`exit` is not in them) |
| M-1 the tokens returned to the account after a partial sale were measured by this contract's balance drop, not by what the account received | Fixed | `_sweepToken` measures the delivery on the account, as `buy()` measures its output; what a transfer fee burns on the way back counts as given up |
| L-1 `EXIT_KEY` cannot be rotated | Accepted / documented | immutable by design; a lost cold key means a new deployment and re-signed permissions |
| L-2 a fee on the inbound `_pull` leg charges cost for tokens that never reached the router | Accepted / documented | fee-on-transfer tokens remain unsupported |
| L-3 constructor did not refuse `router`/`executor == address(this)` | Fixed | checked |

**Tests (v13):** `forge test --no-match-path test/Fork.t.sol` — 42 unit tests (7 new: frozen rate, fading after a full exit, rate never rising, rate following a shrinking budget, bricked balance on sell and exit, fee on the way back, constructor self-check) plus 4 stateful invariants over random buy/sell/warp/unlock sequences (`test/Invariants.t.sol`: cost basis equals the lots, lot within balance, outstanding never exceeds booked, the rate was a budget in force at a booking); `forge test --match-path test/Fork.t.sol --fork-url <base rpc>` — 3 tests against the live KyberSwap router. Deployed as v13 at `0xdbeeec5d37e7f73360e344b8fe24139232a112e6` (Base, block 52813358), Sourcify exact match.

**Round 12 findings (v13) and what changed in v14** — round 12 found no Critical; 1 High, 1 Medium, 2 Low, 3 Informational. The High is the limit of a cost-based budget without a price oracle, and v14 answers it at the system boundary rather than with another contract mechanism.

| Finding | Status | Response (v14) |
| --- | --- | --- |
| H-1 a compromised executor inflates `costOf` for free by buying a self-issued token through a self-owned pool (recovering the ETH as that pool's LP), raising the 30% ceiling until a real position can be dumped | Accepted as a contract residual, bounded by the system | Inside the contract this can only be closed with per-position floors (rejected: they block honest exits on crashes) or by excluding fresh buys from the base for hours (rejected: it blocks the honest sale of a position that crashed an hour after entry). What bounds it: every such buy is a `Bought` event the two watchers reconcile within minutes; the first foreign trade pauses the gate. **v14 makes the pause stop the executor's sales as well as its buys** (`sell()` reverts `IsPaused`; `exit()` and the owner's own wallet are never paused), so a paused gate ends both the inflation and the drain. The attack therefore needs about 78 hours of hourly foreign buys without any watcher reacting. The incident drill exercises exactly this path |
| M-1 `exit()` with an exact amount is denied by a 1-wei front-run sale that shrinks the lot | Accepted / tooling | The route is bound to the amount, so the gate cannot cap it. The operator's exit page rebuilds the transaction from a fresh lot and quote and retries (up to three times) when a sale lands first. Under v14 a paused gate removes the front-running sale altogether |
| L-1 `unlock()` gated on `msg.sender` while `exit()` uses `tx.origin` | Fixed | `unlock()` is gated on `tx.origin == EXIT_KEY` like `exit()` |
| L-2 `buy()`'s account-side balance reads were not under the tolerant wrapper | Fixed | `buy()` reads the account's balance through `_balanceOf`; a token that will not report it is refused with `BelowMinOut(0, minOut)` instead of a bare revert |
| I-1 `approveTarget` is never read by the router's `swap()` | Documented | the check stays as a belt-and-braces bound on the field; the comment says so |
| I-2 the pinned router and executor cannot be rotated | Accepted / documented | immutability is the design; a router change means a new deployment and re-signed permissions |
| I-3 the loss budget refills during a sequencer outage | Accepted / documented | bounded by outage length (12–24 h ≈ 7–14% of the week's refill) |

**Tests (v14):** 43 unit tests (new: a bricked balance refused on buy; the pause test now checks that sales stop and `exit()` still runs), 4 stateful invariants, 3 fork tests on the live router — all passing. Deployed as v14 at `0x257543fec106428c550fd3c5b375eba8d71bda5e` (Base, block 52816419), Sourcify exact match.
