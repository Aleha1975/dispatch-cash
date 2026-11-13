# Elysium LP Vault

On-chain core of a client-facing (optionally hedged) Uniswap v4 LP vault on **Elysium mainnet** (chain 99901,
native gas HYPE). Clients deposit USDC and receive vault shares; a keeper runs the LP position and (for the hedged
strategy) a HYPE perp short on Hyperliquid. Nothing in this repo has been deployed.

## Contracts

| File | Role |
|---|---|
| `src/LPVaultBase.sol` | Venue-independent core: ERC-20 shares, async deposit/redeem queues, settlement, performance fee + HWM, hedge margin, roles, pause, emergency wind-down. |
| `src/UniV4LPVault.sol` | Venue for one fixed Uniswap v4 pool (no hooks): PositionManager mint/increase/decrease/collect/burn, swaps via `PoolManager.unlock`. |
| `src/V4PositionMath.sol` | Linked library: pool price and position amounts (principal + unclaimed fees) read straight from PoolManager storage. |
| `src/interfaces/IExternal.sol` | Minimal PositionManager / Permit2 / WHYPE interfaces. |
| `script/Deploy.s.sol` | One vault per strategy (hedged or growth); not executed. |

One deployment = one strategy. The UI lists vaults; e.g. `HYPE/USDC v4 hedged` (hedgeTreasury set, hedge cap 35%)
and `HYPE/USDC v4 growth` (hedgeTreasury = 0, hedge cap 0). A Ramses CL vault later is another `LPVaultBase`
subclass implementing the same four hooks (`_poolPrice`, `_positionAmounts`, `_unwindAll`, `_positionCount`) against
its v3-style NPM, with `baseToken = WHYPE` (ERC-20) instead of native.

Target pool: `PoolKey(native HYPE, USDC 0xb47c…0B65, fee 3000, tickSpacing 60, hooks 0)`,
poolId `0xb303…65cc`; PoolManager `0xE2e1…23F1`, PositionManager `0x1d1C…E518`, Permit2 `0x0000…8BA3`.

## Client experience

- **Enter (1 signature + 1 tx)**: `requestDepositWithPermit(assets, deadline, v, r, s)` (USDC supports EIP-2612),
  or `approve` + `requestDeposit(assets)`. USDC is pulled immediately and queued; shares are minted at the next
  settlement at a fresh NAV. `cancelDeposit(id)` refunds while still queued (works paused and in emergency).
- **Exit (1 tx)**: `requestRedeem(shares)`. At the next settlement the shares are burnt and USDC is **pushed** to the
  client. No claim tx. If a push fails (e.g. a blocked address) the amount is reserved in `claimable` for `claim()`.
- No absolute limits on withdrawals. All caps are relative to NAV. `minDeposit` (default 1 USDC, hard max 100) only
  applies to new deposits.
- Share decimals = 12 (USDC 6 + 6 virtual-share offset). `lastPricePerShare()`, `previewRedeemLast(shares)`,
  `previewDepositLast(assets)` give indicative values at the last settled NAV.

## Roles and trust

| Role | Can | Cannot |
|---|---|---|
| owner (multisig) | set keeper, guardian, fee recipient, parameters within hard caps; unpause | move funds, change pool, asset, hedgeTreasury (immutable) |
| keeper (hot key) | `settle`; mint/increase/decrease/burn positions in the fixed pool (recipient always the vault); swap through the fixed pool with min-out; send margin to `hedgeTreasury` up to `hedgeCapBps` of NAV; pull margin back | send tokens anywhere else; spend queued deposits or unpaid claims; settle outside the pool price band; jump hedge equity > `hedgeStepBps`/day |
| guardian | pause (new deposits, mints, increases, swaps, hedge sends); co-confirm one exact large hedge equity value per epoch | unpause, move funds, change params |
| anyone | `emergencyUnwind()` after 72 h without settlement | anything before that |

Pause never blocks: `requestRedeem`, `settle` (redeems only; queued deposits wait), `cancelDeposit`, `claim`,
`decreasePosition`, `burnPosition`, `returnHedgeMargin`, `emergencyUnwind`, `emergencyRedeem`.

Hard caps (constants): fee <= 20%, hedge cap <= 50% NAV, pool band <= 5%, slippage <= 5%, hedge step <= 20%,
reference drift <= 30%, swap turnover <= 5x NAV per epoch. Defaults: fee 15%, hedge 35%, band 1.5%, slippage 1%,
hedge step 5%/day, drift 10%, turnover 2x.

Trust assumptions: the keeper reports the HYPE price and the off-chain hedge equity (bounded as above); the operator
holds the Hyperliquid account behind `hedgeTreasury`; the owner is a multisig (a timelock is recommended before
launch); Uniswap v4 PoolManager/PositionManager/Permit2 and the bridged USDC are trusted.

## NAV and fees

`NAV = idle USDC (minus queued deposits and claims) + (idle HYPE + WHYPE + LP HYPE) * keeperPrice + LP USDC + hedgeEquity`

LP amounts come from liquidity and ticks at the pool's current sqrtPrice plus uncollected fees (feeGrowthInside).
`settle` reverts unless the pool price is within `poolBandBps` of the keeper price. Performance fee: `feeBps` of the
gain of price-per-share above the high-water mark, minted as shares to `feeRecipient`; the HWM never decreases.
Deposits and redeems in one settlement use the same post-fee NAV; rounding always favours the vault.

## What the keeper must do each epoch (e.g. hourly, and at least every 72 h)

Price `P` = USDC raw per 1e18 wei HYPE (e.g. $71.15 -> `71_150_000`). Read pool price with `poolPrice()`.

1. **Read state**: `pendingDeposits()`, `pendingRedeems()`, queued redeem shares (`redeemRequests`), `idleAsset()`,
   `positionAmounts()`, `hedgeEquity()`, `lastNav()`, Hyperliquid account equity of the hedge account.
2. **Choose the price**: HL mark/oracle `P_hl`. If `|pool - P_hl| > band`, report `clamp(P_hl, pool * (1 +- band))`
   (or wait for arbitrage); never more than `poolBandBps` from the pool.
3. **Free liquidity for redemptions** (if queued redeems > idle USDC + queued deposits):
   `decreasePosition(id, L, min0, min1)` or `burnPosition(id, min0, min1)` -> `swap(true, hypeAmount, P)`
   (sell HYPE) and/or Hyperliquid withdraw -> treasury `approve(vault)` -> `returnHedgeMargin(amount)`.
4. **Settle**: `settle({epoch: epoch(), price: P, hedgeEquity: HL equity, maxDeposits: N, maxRedeems: M})`.
   If the HL equity moved more than 5% of NAV in the last day, the guardian first calls `approveHedgeEquity(value)`.
   Repeat with more items if the queues are longer than N/M (the epoch increments each call).
5. **Deploy new money**: `swap(false, usdcAmount, P)` for the HYPE leg -> `mintPosition(tl, tu, L, a0Max, a1Max, P)`
   (`a0Max` HYPE is sent as msg.value from the vault, leftover swept back) or `increasePosition(id, L, a0Max, a1Max, P)`.
6. **Hedge** (hedged vault): target short = LP HYPE delta. Need more margin: `sendHedgeMargin(amount)` (<= 35% of last
   NAV in total), bridge to HL, adjust the short. Too much margin: HL withdraw -> `returnHedgeMargin(amount)`.
7. **Fees**: `decreasePosition(id, 0, 0, 0)` collects LP fees to the vault (optional; NAV already counts them).
8. **Re-range** when out of range: `burnPosition` -> `swap` to rebalance -> `mintPosition`.

## Emergency (keeper offline 72 h)

`emergencyUnwind()` (anyone; within 10% of the last settled price until day 7, then unconditionally) burns all
positions into HYPE + USDC and switches to permanent wind-down. Holders call `emergencyRedeem(shares, to)` for a
pro-rata share of on-chain USDC, native HYPE and WHYPE; queued redeemers first `cancelRedeem(id)`; queued depositors
`cancelDeposit(id)`. Hedge margin at `hedgeTreasury` is off-chain: the operator must close the short and return it
with `returnHedgeMargin`; it then accrues to shares still outstanding, so holders should wait for that return.

## Client web page (`web/`)

Static page, no build step: `index.html` (markup + CSS), `app.js` (vanilla JS + viem 2.21.54 from jsDelivr),
`config.js` (chain, USDC, strategy list: fill `vault` and `deployBlock` after deployment), `mock/status.json`.
Serve the folder as-is (e.g. `python3 -m http.server -d web 8787`).

- Review without a wallet: `/?mock=1` (state switcher on top; `&s=<scenario>` deep-links one state).
- Local fork: `/?rpc=http://127.0.0.1:8545&vaults=<hedged>,<growth>&from=<deployBlock>&status=mock/status.json`.
  Without an injected wallet (or with `&devwallet=1`) the page uses the node's unlocked account `&acct=N`
  (default 0); `&batch=1` makes that dev wallet advertise EIP-5792 atomic batches.
- Deposit order: allowance already set -> `requestDeposit`; wallet reports `atomic.status == "supported"` ->
  `wallet_sendCalls` (approve + `requestDeposit`, one confirmation); else EIP-2612 permit (domain checked against
  `DOMAIN_SEPARATOR()`) + `requestDepositWithPermit`; else approve + `requestDeposit`.
- Every shown value uses the contract's own formulas: value = `previewRedeemLast` math, partial withdraw shares =
  `previewDepositLast` math, fees paid = the account's pro-rata part of each `Settled.feeShares` (reconstructed from
  events with `_accrueFee`'s formulas), deposited/withdrawn = `Deposited`/`Redeemed` events.

### Status endpoint `GET /elysium-api/status` (served by the keeper)

```jsonc
{
  "version": 1,
  "chainId": 99901,
  "updatedAt": 1763020800,            // unix seconds
  "strategies": [{
    "id": "hype-usdc-hedged",          // matches web/config.js strategies[].id
    "vault": "0x…" | null,
    "state": "live" | "paused" | "emergency" | "coming_soon",
    "feeApy7d": 0.284,                 // fraction; LP fees earned over 7 d / avg NAV, annualised (card headline)
    "feeApy30d": 0.251,                // fraction or null
    "netApy30d": 0.172,                // fraction or null; pps change over 30 d, after hedge cost and our fee
    "tvlUsdc": "412530.18",            // decimal string = lastNav() / 1e6
    "feeBps": 1500,                    // params().feeBps
    "pricePerShare": "1.031874",       // decimal string, USDC per 1e12 shares at the last settlement
    "lastSettleAt": 1763019000,        // unix seconds of the last Settled event
    "nextSettleAt": 1763022600,        // unix seconds, keeper's plan
    "pendingDepositsUsdc": "1250.00",  // pendingDepositAssets() / 1e6
    "pendingRedeemsUsdc": "300.00"     // queued redeem shares valued at the last NAV
  }]
}
```

The page reads only `id`, `state`, `feeApy7d`, `tvlUsdc`, `feeBps`; everything about the client's own position is
read on-chain. CORS: same origin as the page (or `Access-Control-Allow-Origin` if served elsewhere).

## Build and test

```
forge build
forge test                                   # unit + invariant (fork suite skipped)
ELYSIUM_FORK=true forge test --match-contract Fork -vv   # real Elysium pool on a local fork, nothing broadcast
# optional: ELYSIUM_RPC=https://rpc.volta.family ELYSIUM_FORK_BLOCK=<n>
```

The vault is ~24.0 KB (EIP-170 limit 24.576 KB, optimizer runs = 1, via-IR); position math lives in the linked
`V4PositionMath` library.
