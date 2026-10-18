# Audit scope — round 2

**What to review:** `src/GuardedSwap.sol` (v3, this branch) and its interaction with the KyberSwap MetaAggregationRouterV2 on Base. One contract, no dependencies.

**Deployed:** Base (chain 8453), `0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485`, source verified on Sourcify (exact match):
https://sourcify.dev/server/v2/contract/8453/0xf563ddf97a6c9ec1d1366dde3410f5aa2c07b485

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

**Tests:** `forge test --no-match-contract Fork --fuzz-runs 2000` (29 tests, the round-1 PoCs included) and `forge test --match-contract Fork --fork-url <base rpc>` (2 tests against the live Kyber router with real calldata). All pass on Foundry 1.8.5 / solc 0.8.26.
