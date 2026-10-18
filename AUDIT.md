# Audit scope — round 4

**What to review:** `src/GuardedSwap.sol` (v5, this branch) and its interaction with the KyberSwap MetaAggregationRouterV2 on Base. One contract, no dependencies.

**Deployed:** Base (chain 8453), `0x3511a33478465d2f6fd5ebfebf52160ef39ec7a1`, source verified on Sourcify (exact match):
https://sourcify.dev/server/v2/contract/8453/0x3511a33478465d2f6fd5ebfebf52160ef39ec7a1

Previous subjects: v4 `0x970b033ab9965ce9c9f92584b529afa6100a994e` (round 3), v3 `0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485` (round 2), v2 `0x91b51882805051b83efc53e7407a01894d341ca0` (round 1).

**What it must guarantee:** an executor key that calls this contract on behalf of a client's smart account can never move the account's ETH or tokens to anyone but the account itself; a bad trade is bounded by a 50% floor against the recorded entry price, an announced 1-hour slow path, and per-account hourly limits; a pause-only guardian can stop buys and delay sales but never block an exit or touch funds.

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

**Tests:** `forge test --no-match-contract Fork --fuzz-runs 2000` (43 tests, the round-1, round-2 and round-3 PoCs included) and `forge test --match-contract Fork --fork-url <base rpc>` (2 tests against the live Kyber router with real calldata). All pass on Foundry 1.8.5 / solc 0.8.26.
