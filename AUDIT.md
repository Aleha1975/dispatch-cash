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

**Round 13 findings (v14) and what changed in v15** — round 13 found no Critical; 2 High, 2 Medium, 4 Low, 7 Informational. Both Highs and one Medium sit on seams created by the round-11/12 fixes themselves, so v15 removes a mechanism rather than adding one.

| Finding | Status | Response (v15) |
| --- | --- | --- |
| F-1 `unlock()` gated on `tx.origin` (the round-12 L-1 change) is a confused deputy: a contract the cold key happens to call can clear any account's budget | Fixed | `unlock()` is gated on `msg.sender == EXIT_KEY` again (an EIP-7702 account calling the gate directly still passes; nothing between the key and the gate ever does); `accounts.length` capped at `MAX_UNLOCK` (64) |
| F-4 the frozen refill rate (round-11 C-1 fix) drifts from the documented "fades within REFILL" in both directions | Fixed by removal | `Loss.rate` is gone. What is outstanding fades linearly over `REFILL` from its last booking; booking more resets the clock on the larger amount. The decay no longer reads the budget or the cost basis at all, so new buys, closed lots or a shrinking base can neither speed it up nor freeze it — the same guarantee C-1 wanted, with one rule instead of two |
| F-3 with v14's sell-side pause a hostile guardian could hold the executor in a 7-of-8-day cycle with no remedy | Fixed | `replaceGuardian(address)` by the cold key: the new guardian lifts the pause at once. The cold key gains no other power over the guardian. The sell-side pause stays (it is what lets the watchers end a drain) |
| F-2 the contract's reads of its own balance are strict, so a token that stops answering for the gate's address blocks `sell()` and `exit()` for that token | Accepted / documented | The gate measures its own balance to know what the router took and what came back; without that it cannot settle a sale honestly, so it must not proceed. Such a token is sold by the owner from the wallet, outside the gate |
| F-5 the first increment of the round-12 H-1 inflation can happen inside one transaction, before any watcher reacts | Accepted / documented | One increment is bounded by the hourly buy cap (0.3 ETH → 0.09 ETH of allowance); the watchers' pause bounds every further one |
| L-1 unbounded `accounts` in `unlock()` | Fixed | `MAX_UNLOCK` |
| L-2 `_decayed` with a backward timestamp | Fixed | no decay for `block.timestamp <= at` |
| L-3 the unreadable-balance fallback in `_sweepToken` can understate a booked loss | Accepted / documented | only for a token that stops answering the account's balance mid-sale; the lot is reconciled at the next call |
| I-1 no containment if `EXIT_KEY` itself is compromised | Accepted / documented | by design: the cold key can only pay the owning account and replace the guardian |
| I-2 … I-7 (overflow under misconfigured parameters, `tx.origin` reachability of `exit`, L1→L2 aliasing, zero-cost rounding, opposite rounding directions, read-only reentrancy of views) | Documented | unchanged from the earlier rounds' dispositions |

**Tests (v15):** 42 unit tests (new: a loss fades over a week whatever the base does, keeps fading after the lot closes, booking more resets the clock, the cold key replaces a guardian that holds the pause), 4 stateful invariants (now including: outstanding loss is zero within `REFILL` of its booking), 3 fork tests on the live router — all passing. Deployed as v15 at `0x2c894b3a726b49d9e68e71d548157964e5e0fbb6` (Base, block 52819182), Sourcify exact match.

**Round 14 findings (v15, no code change)** — round 14 found **no Critical and no High**; one Medium that the report itself calls informational-grade, two Lows that re-confirm accepted residuals, five Informational. The audit cycle on the loss-budget design is closed with v15.

| Finding | Status | Response |
| --- | --- | --- |
| M-1 `acceptGuardian()`'s `msg.sender == address(0)` branch is unreachable | Accepted / documented | dead defensive branch; no path depends on it |
| L-1 `exit()` keeps a `tx.origin` gate (operator-side confused deputy) | Accepted / documented | `exit()` must run through the account's own delegation, so `msg.sender` is the account; it can only sell the account's lot and pay that account. The exit transaction is built on the operator's phone with an independent quote |
| L-2 `_decayed` multiplication bound under extreme deployment parameters | Accepted / documented | production limits keep it far from overflow (`MAX_LOT`, hourly caps) |
| I-1 … I-5 (7702 vs the constructor EOA check, `replaceGuardian` leaves the pause to the new guardian, fixed hourly windows, `MAX_LOT` vs `ethIn`, tests not re-run by the reviewer) | Documented | as designed |

**v16 — a product correction, not an audit response (round 15 scope).** In production on 23 Oct 2026 an account holding about 0.78 ETH and one position bought for 0.040 ETH could not sell that position after a 63% drop: the loss (0.0255 ETH) exceeded 30% of the open lots (0.0121 ETH), the only base v15 knew. `unlock()` could not help — it clears what is outstanding, while the sale alone was over the budget — and the position was sold by the cold key's `exit()`. Every account with few open lots is in the same position. v16 changes one definition and nothing else:

| | v15 | v16 |
| --- | --- | --- |
| Budget base | `costOf[account]` (open lots at cost) | `costOf[account] + account.balance` (native ETH plus open lots at cost), one function `_base` used by the sale, `budgetOf` and `floorFor` |
| When it is read | inside `_settle`, before the sold cost leaves | once in `_sale`, after the lot is reconciled and before the tokens are pulled or the router is called |
| Effect of the gate's own trades | a buy raised the base by what it spent (round 12 H-1) | a buy moves ETH into a lot at cost and leaves the base unchanged; a sale moves `out` into ETH and the released cost out of the lots, so the base changes by exactly `out − cost` |

Options considered and rejected: a high-water mark of the base (a second base for one notion; after the owner withdraws, a stolen key could lose 30% of an account that is no longer there), and a fixed minimum budget in ETH (one constant for accounts of every size: on a small account it is the whole account). Seams examined before submission: ETH sent to the account raises the base, but only the owner can take ETH out, so a sender leaves it there — a donation of X buys the sender 0.3·X of budget at the cost of X; the router call cannot raise the base of the sale it is part of (read before it); a withdrawal shrinks the base at once (no high-water). New residual, stated in the README: on an account that holds mostly ETH the budget exceeds the cost of its positions, so a stolen key can dump them in full; the bound is a share of the account, and the watchers' pause ends the drain.

**Tests (v16):** 48 unit tests (new: the 23 Oct case, buys leave the base unchanged, a withdrawal shrinks the budget at once, a thief's burst books at most 30%/1.3 of the account, a thief buying and dumping at production limits for 48 hours stays within 30% × (1 + 48 h / week), unlock does not lift the rule); 6 stateful invariants (new: with no time passing, losses booked by any sequence of buys at any price and sales at 1–300% of entry stay within 30% of the largest base seen; nothing leaves the account but booked losses; every buy leaves the base unchanged); fork tests on Base: the 23 Oct case replayed one block before the cold key's exit with the live router calldata — v15 as deployed refuses (`BudgetExceeded`, also after `unlock`), the same sale with v16's code at that address goes through and books the loss (0.02552 of a 0.24742 budget); pause and exit unchanged; the three earlier fork tests with fresh routes. Mutation checks: doubling the budget fails the burst invariant and two unit tests; restoring the v15 base fails five of the six new unit tests.

**Round 15 findings (v16) and what changed in v17** — round 15 (automated review of v15, re-checked against v16) reported one High, one Medium and one Low that still apply to v16, all at the seam between the account-wide base of v16 and the per-token reconciliation it inherited; plus the v15 finding "reversible purchases manufacture allowance", which v16's base already closes.

| Finding | Status | Response (v17) |
| --- | --- | --- |
| H stale cost of other lots: `buy`/`_sale` reconciled only the traded token while the base summed every lot's cost; a lot the owner had moved out (or that rebased down) kept its cost in the base, so a stolen key could dump another lot almost free (lot A 0.20 withdrawn, lot B 0.02, all of B sold for 1 wei: v16 admits it against 30% of 0.22) | Fixed | A per-account registry of open lots (`_lots` + `_lotIdx`, at most `MAX_LOTS` = 32; a buy of a new token past the cap reverts `TooManyLots`, after first reconciling every lot so that lots the owner emptied free their slots). An entry is added when a lot opens and removed at both places a lot is deleted (`_trim` on an empty balance, `_settle` on a full sale), through one function `_closeLot`. Every sale — `exit()` included — reconciles all registered lots (`_trimAll`) before the base is read; `exit()` stays outside the budget and only keeps the books true. `budgetOf` and `floorFor` compute the same base through `_trimmed` over the registry without writing |
| M ETH returned straight to the account during a buy (by the route or by the token's transfer hook) was counted as spent, because `spent` was measured on the gate's balance only; a fully refunded buy recorded full cost and inflated the base (with v16's base the account's ETH did not even drop) | Fixed | `buy` reads `msg.sender.balance` once `msg.value` has left it and again after the router call and the token sweep, before the gate forwards its own change; any increase is subtracted from `spent` (floored at zero, so a fully refunded buy still reverts `ZeroAmount`). The change forwarded by the gate is measured on the gate and paid after the second reading, so it is counted once. The hourly buy cap counts the reduced spend |
| L `floorFor` quoted the untrimmed base, so a sale at the quoted floor could revert `BudgetExceeded` after the owner moved tokens out | Fixed | the views use the reconciled base (`_quotedBase`), and a sale at exactly `floorFor` passes while 200 wei below it reverts (test) |
| v15 "reversible purchases manufacture allowance" (lot A 0.04, 0.20 cash; buy B 0.20; sell A for 0.001; sell B for 0.199) | Closed by v16 | the cash is in the base already and a buy only moves it into a lot: the budget is 0.072 with or without the buy of B, and the A sale gets the same verdict either way (it is admitted — a 0.039 loss on a 0.24 account is inside 30%; it is refused, `BudgetExceeded(0.039, 0.012)`, when the 0.20 is not the account's). Step 1 manufactures nothing |

New with the registry: every balance read (`_balanceOf`) is capped at `BALANCE_GAS` (100 000) and copies at most 32 bytes of answer, so a token planted in the registry by a stolen key (bought, then made to burn gas or return a huge answer) cannot run the walk over all lots out of gas and block the account's sales and its exit; such a token reads as unreadable and is skipped. A sale walks at most 32 lots: about 14 000 gas per extra lot cold, about 630 000 for a sale with 32 open lots, at most about 3.3 M if every other lot burns its whole read allowance. The new storage is declared after `_lock`, so the earlier slots keep v16's layout (the cbPIGGY fork replay etches v17 over v15's storage and registers the one lot).

Residuals (v17): a lot whose token stops answering `balanceOf` for the account — or needs more than `BALANCE_GAS` to — keeps its last reconciled cost in the base until it answers again (the round-11 rule that an unreadable balance is never taken as empty); a stolen key can fill the registry with 32 junk lots whose transfer the owner cannot complete, after which buys of new tokens revert `TooManyLots` for that account (no funds at risk; sales, exit and the owner's wallet are unaffected; remedy: the watchers' pause and a new gate); ETH that reaches the account during a buy from a third party is indistinguishable from a refund and lowers the recorded cost (conservative: a lower cost means a smaller base and a larger booked loss); ETH paid to the account directly during a sale is not counted as proceeds (conservative in the same direction).

**Tests (v17):** 57 unit tests (new: the High example — `BudgetExceeded(0.02 − 1 wei, 0.006)` where v16 admitted the dump; the partial-withdrawal variant, with the reconciliation written by the next sale at cost; the round-15 reversible-purchase sequence with and without the buy; a fully refunded buy reverts `ZeroAmount`, a partial refund through the route and a refund in the token's transfer hook reduce the recorded cost, change through the gate and past it each counted once; `floorFor` equals the sale's acceptance threshold after a partial owner transfer; the `MAX_LOTS` cap and a freed slot; a lot whose `balanceOf` reverts and one that burns all gas do not block the sale or the exit of another lot; the registry through buy, partial sale, full sale, emptied-by-owner and exit); 7 stateful invariants (the handler now trades three tokens and moves tokens out of the account as the owner; new: `costOf` equals the sum of `ethIn` over the registry; a token is listed exactly once when its lot is open and never otherwise; every booked loss is within the budget `budgetOf` quoted before the sale); fork: the cbPIGGY replay on Base (v17 code at the v15 address, lot registered) passes, pause and exit unchanged. `test/Fork.t.sol`'s two router tests fail identically on v16 and v17 (`RouterFailed`: their Kyber routes were built for an earlier block and need fresh fixtures). Mutation checks: reconciling only the traded token fails four unit tests and the stateful invariants; dropping the refund subtraction fails both refund tests; not shrinking the registry fails four unit tests and the registry invariant; quoting the untrimmed base in the views fails three unit tests.
