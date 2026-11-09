# Engine and site changes for gate v18 (description only - no file was edited)

Files: `~/dispatch-elysium/engine-elysium/clone/exec.mjs` (line numbers as of 09.11) and `~/dispatch-elysium/site/components/engine/use-engine.ts`. Contract: `~/dispatch-elysium/gate-v18/src/GuardedGate.sol`. Proven by `e2e/e2e.mjs` (anvil fork of Elysium, real DelegationManager, real Hybrid account, TWO signed delegations + one funding transfer); its `d`/`dA` construction, `redeemData` and `call()` helpers are the reference code.

v18 keeps today's account model: tokens stay in the client's account, a sale pulls them through the account's `approve` to the gate, the lot is reconciled against the account's balance. So most of exec.mjs (holdings reads, `doSell` approve block, `tokenBal(token, st.sa)`) stays as it is for the live gate; the changes are the gate delegation, the new native paths and the constructor.

## 1. Two delegations (`buildDelegation`, exec.mjs ~393)
1. `approve` kind: **unchanged** (any token, `0x095ea7b3`, spender = gate in calldata word 0, `valueLte 0`, expiry). It is the second signature. `GUARD` must be the v18 address for `allowedCalldata`.
2. New kind `"gate"` replaces `swap + withdraw + gas + fee + feegas`:
```js
} else if (kind === "gate") {
  const sel = ["0xf496a610","0x3581f5bb","0x29610252","0x4f6d3aed","0x3ccfd60b"]; // buy sell payFee refundGas withdraw
  d = createDelegation({ environment: env, from: st.sa, to: exOf(st).address, salt,
        scope: { type: ScopeType.FunctionCall, targets: [GUARD], selectors: sel } });
  // the FunctionCall scope injects valueLte 0 when none is given: build the caveats directly (no value enforcer at all)
  const cav = createCaveatBuilder(env).addCaveat("allowedTargets", { targets: [GUARD] }).addCaveat("allowedMethods", { selectors: sel })
      .addCaveat("timestamp", { afterThreshold: 0, beforeThreshold: until }).addCaveat("limitedCalls", { limit: 100000 });
  d.caveats = cav.build ? cav.build() : cav;  d.guard = GUARD;
}
```
- NO `valueLte`, NO `nativeTokenPeriodTransfer`: value limits live in the gate (hourly buy 17.5, fee 20%, gas, withdraw to owner only). Delete `DAILY_ETH_CAP`, `max_trade_eth`, `fee_cap_eth`, `daily_eth` for this kind; the site's per-buy ticket cap is no longer a signed value (the gate's 17.5/h is the bound; keep an engine-side per-trade size policy).
- `PERM_DAYS` 90, `CALLS_CAP` 100000. `exit` unchanged (cold key, optional, `EXIT_SELS`); `exit_approve` unchanged (the sale pulls from the account, so the cold key still needs the approve permission for an evacuation).
- Required list (`permPlan`, ~603): `required = ["gate", "approve"]` (both modes); `optional_sign = ["exit", "exit_approve"]`; `GATE_KINDS`, `TRADE_KINDS` = `["gate","approve"]` (+ exits); `guardOf` = the gate both `gate` and `approve` name. `/prepare` anonymous path (`prepareAnon`, 456): allow `kind === "gate"` as the first (sign-in) signature; `approve` is signed second (authenticated by then).

## 2. `act()`: what changes per operation
| Operation | v17.2 flow | v18 |
| --- | --- | --- |
| buy | gate.buy, route paid to the account or gate | **unchanged** (selector and ABI identical; both receivers accepted). |
| sell | approve exactly the amount to the gate, then gate.sell | **unchanged**. Sells are no longer refused for count/size (remove the engine-side retry loop for `RateLimited` on sells; keep it for buys). On `BudgetExceeded` the engine does NOT retry and does NOT call `exitSell` (the executor can never use it): it alerts and the app offers the client "Sell now" (see `exitSell` below). The engine always uses `sell`. |
| fee | `redeemData(d, FEE_TO, fee, "0x")` | `redeemData(d, GUARD, fee, payFee())`. Compute `fee = min(owed15pct, gate.feeRoom(sa))` (view, same limits as the contract: 20% of balance per call; 20% of balance base per sliding 30 days; a withdrawal to the owner does not widen the base, so after a big withdrawal the fee may be paid in parts as the window slides). Charge right after a profit is realised and BEFORE any withdrawal. If clamped, keep `hwm_eth` for the unpaid part. |
| gas refund | native to FEE_TO/executor | `redeemData(d, GUARD, chunk, refundGas())`, chunks <= 0.02 HYPE, <= 0.1 per day; accumulate `gas_owed`. |
| withdraw native | `redeemData(d, st.owner, amt, "0x")` | `redeemData(d, GUARD, amt, withdraw())`; ANY amount in ONE call (no cap, works while paused); recipient is `owner()` of the account (assert once that it equals `st.owner`). Wallet-mode (eoa/7702): the gate pays the account itself, no special case. Full withdraw = `balance(sa)` exactly. |
| tokens | stay in the account | unchanged; the client moves them from his wallet. No engine token-withdraw. |
| exit (cold key) | exit + exit_approve | unchanged. |
| client exit (`exitSell`) | - | New, replaces the removed `setExitMode`. `exitSell(token, amount, minOut, routerData)` has the same arguments as `sell` (selector `0x1cc23c82`), is NOT in the gate delegation's method list (the 5 selectors stay exactly buy sell payFee refundGas withdraw), requires `tx.origin == owner`, ignores the loss budget and the price reference, books no loss, works while paused. **The engine never calls it.** The site's "Sell now" / "Exit" / "Exit everything" buttons call it from the CLIENT wallet directly: sign one delegation `account -> owner EOA` (caveats: allowedTargets [gate], allowedMethods [`0x1cc23c82`], timestamp, optional limitedCalls) and send `redeemDelegations` from the owner's EOA (see `d2` in `e2e/e2e.mjs`); the route (`routerData`) is built by the site exactly like a sale route (dstReceiver = gate, minReturn > 0). The tokens must still be approved to the gate (the `approve` delegation, or the owner approves from his wallet). A UserOp / bundler transaction does not work (tx.origin = bundler). 7702 / plain accounts call `exitSell` from their own EOA. |
| forget lot | - | New, account-only `forgetLot(token)` (selector `0x3e573af8`, not delegated): the app's "clean up" action when `TooManyLots`/`DustLot` appear or a junk token is stuck in the lot list; sent from the client wallet like `exitSell`. |
| `reconcile` | watcher calls it | unchanged (account / guardian / cold key). |

Other places:
- ABI: new `guardAbiV18`: `buy, sell, exitSell, exit, payFee, refundGas, withdraw, withdrawTo, forgetLot, feeRoom, ownerOf, pay(address), ref(address account, address token), lotOf, lotsOf, budgetOf, floorFor, reconcile, unlock, setPaused`; events `Bought, Sold, FeePaid, GasPaid, Withdrawn, LotForgotten, Reconciled`. `pay` and `window` getters changed shape (two-bucket sliding windows); only `feeRoom` should be used for fee sizing.
- `GUARD_ERR` add (checked with `cast sig`): `0x74b1a5d3 FeeLimit`, `0x48dd75ba GasLimit`, `0xac64a0a9 NoBeneficiary`, `0x67a2cc26 BadRecipient`, `0x345c7cac TokenUnreadable`, plus new `NotOwnerOrigin`, `DustLot` (recompute with `cast sig`). A new lot needs a buy of at least 0.001 HYPE (`DustLot`); `BudgetExceeded` can now also come from the price reference when a token's price fell > 30% below its recent high. `RateLimited` now only comes from buys.
- Deploy params struct (different from v17.2): `{router, executor(kyber), guardian, exitKey, feeTo, maxBuyEthPerHour 17.5e18, gasCallMax 0.02e18, gasDayMax 0.1e18}`.
- Watcher: pause on a foreign trade as today; also alarm on `Withdrawn` for amounts > 50% of an account without a client request (a thief's only "withdraw" is a DoS), and on `Sold` events booked with `lossAdded` far above the engine's own expectation.

## 3. Site (`use-engine.ts`): 2 signatures + 1 transfer
1. `first = "gate"` then `need = ["approve"]` (keeps the existing `need` loop: one more `signOne`). With `anon = true` the first `/prepare` creates no account and the first `/submit` signature is the sign-in (as `swap` today).
2. Progress text "1 of 2 signatures", then "2 of 2". `toSign` default list -> `["gate","approve"]`; `OPTIONAL_KINDS` unchanged (`exit`, `exit_approve`).
3. Renewal flows (~820, ~904, ~1141, ~1234): `gate` kind every 90 days (the approve permission renews with its own date); the "raise per-buy cap" flow goes away.
4. Withdraw dialog: no "partial / per day" text; one call moves the full amount ("Withdraw all"). Tokens: "your tokens stay in your wallet; sell to HYPE or move them yourself".
5. Texts: "One permission for the Dispatch gate (buy, sell, fee, withdraw to your own wallet), one to let it sell your tokens. No amount limit in the permission: limits are in the contract."
6. The prompt count is 3 (2 signatures + 1 transfer) only if the wallet is already on Elysium and holds the HYPE, and `mode` stays `"sa"` (the 7702 upgrade is an extra prompt).

## 4. Migration of accounts on the old gate (0x795f8ff1...146d5)
Old permissions keep working with the old gate (`st.legacy[gate]` machinery). A client who signs `gate` + `approve` for the new address trades on v18 for new buys; positions bought through the old gate are in the old gate's lot book and are sold through the legacy set (the lot lives in the old contract). Simplest: ask the handful of live accounts to re-sign both once and close old-gate positions first. Add the old gate to `GUARD_PREV`.

## Round 2 (audit job 1205): interface changes
- `ref(address)` became `ref(address account, address token)` returning `(uint256 price, uint64 at)`; price is wei per 1e30 raw units (was uint128 per 1e18). The engine does not read it (informational only).
- Buy window: after spending the full hourly cap in one slot, further buys are refused until the previous slot no longer counts in full (up to two slots). Treat `MAX_BUY_ETH_PER_HOUR` as a hard limit per span; `RateLimited` is the signal to wait.
- `feeRoom` / `payFee` / `refundGas` use the same conservative window (fees of the previous 30-day slot count in full until the slot ends); always size the fee with `feeRoom`.
- Selectors, the delegation method list and `sell` arguments are unchanged.

## Round 3 (audit job 1206): interface changes
- `pay(address)` and `window(address)` getters are gone; `windows(address) returns (buys, fees, withdrawn, gas)` gives the ring totals now (informational; size fees with `feeRoom`).
- Windows are rings of 6 sub-buckets plus the running one: after a full-cap buy the next buy is possible after at most 70 minutes (not 1 to 2 hours); plan buys as <= 17.5 HYPE per 60 minutes, a steady 2.5 per 10 minutes is always allowed. `RateLimited` / `FeeLimit` / `GasLimit` unchanged.
- `floorFor(account, token, amount)` now also covers the price-reference floor; pass at least this as `minOut` to avoid `BudgetExceeded` after the swap.
- Reference: at most one raise per 10 minutes, deleted when the lot closes. `ref(account, token)` keeps its shape. Selectors of buy/sell/payFee/refundGas/withdraw and the delegation method list are unchanged.
