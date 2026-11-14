# Per-client smart accounts on Elysium: research and design

Status: **built on branch `smart-account`** (section 6 has the as-built details, which supersede sections 2 and 4 where they differ). Not deployed, not audited; tested offline (replica), on a forge fork and on an anvil fork of Elysium. Date: 2026-11-13. Chain: Elysium 99901.
All on-chain facts below come from `eth_getCode` / `eth_call` against `https://rpc.elysium.kinetiq.xyz` (block ~6,023,600).

## TL;DR

- **The MetaMask 7702 delegator is on 99901, and it is genuine.** `EIP7702StatelessDeleGator` v1.3.0 is at `0x63c0c19a…E32B`.
  `DelegationManager` is at `0xdb9B…7dB3`, and its owner is `0xB0403B…9f44`, the same owner as on Ethereum mainnet.
  Their bytecode matches Base byte for byte, except for the chain id and the cached EIP-712 domain separator.
- **Prague/7702 is live on the chain.** A `0xef0100‖0x63c0…` designator resolves in `eth_call`, and the BLS precompile `0x0b` answers.
- **Most caveat enforcers are missing.** Only `ExactExecutionBatchEnforcer`, `LimitedCallsEnforcer` and `TimestampEnforcer` are deployed.
  The rest can be deployed permissionlessly at their canonical addresses: the Arachnid CREATE2 deployer is present and the init code is public.
- **The blocker: MetaMask will not 7702-upgrade an account on 99901 today.** MetaMask's production remote flag
  `confirmations_eip_7702.supportedChains` (extension and mobile, fetched 2026-11-13) does not contain `0x1863d`.
  On this chain `wallet_getCapabilities` returns nothing, `wallet_sendCalls` with an atomic batch fails with code 5710,
  and the "Switch to smart account" toggle does not offer the network. MetaMask also never exposes raw `signAuthorization` to dapps.
  So "one MetaMask signature = 7702 authorization + delegation" is **not possible on 99901 today**.
- **Narrow keeper rights are achievable with delegations, but not with the stock enforcers.**
  - `AllowedCalldata` cannot pin owners and recipients inside v4's nested `unlockData`.
  - The standard enforcers accept only single-call mode.
  - No stock enforcer expresses "≤ 35% of account value".
  - Recommendation: **an immutable `LPManagerModule` is the only delegate**, and it *builds* every call with recipient = client
    (safe by construction, not by parsing). A small custom **`ElysiumCustodyEnforcer`** caveat is the client-signed backstop that pins
    where tokens may go. `TimestampEnforcer` sets the expiry.
- **Launch path that works today: a per-client `HybridDeleGator`** (canonical MetaMask code, deployed by us via CREATE2) that the client's EOA owns.
  The delegation, module and enforcer are the same. MetaMask signs typed data (`eth_signTypedData_v4`) on any chain, so onboarding is
  2 typed-data signatures and 0 client transactions (relayer). When MetaMask adds `0x1863d` to the 7702 list, the same module and enforcer
  serve EOAs upgraded in place.
- **Gas: about 1.0M gas for a full re-range of one client**, which is ~0.0005 HYPE ≈ $0.04 at 0.5 gwei and $72.5/HYPE.
  100 clients cost ≈ 0.05 HYPE ≈ $3.6 per full round. A fee collect or hedge transfer is ~0.15M gas ≈ $0.005.

## 1. Delegation Framework contracts on 99901

Reference: `MetaMask/delegation-framework` `documents/Deployments.md`, v1.3.0 (repo HEAD `b4b8c41`, 2026-10-22). Elysium is not in its chain list.

| Contract | Canonical address | 99901 |
|---|---|---|
| DelegationManager | `0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3` | **found** (11,503 B; owner `0xB0403B32f54d0Bd752113f4009e8B534C6669f44` = mainnet owner; not paused) |
| EIP7702StatelessDeleGatorImpl | `0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B` | **found** (11,185 B; `NAME`=EIP7702StatelessDeleGator, `VERSION`=1.3.0, DM and EntryPoint v0.7 wired) |
| ExactExecutionBatchEnforcer | `0x1e141e455d08721Dd5BCDA1BaA6Ea5633Afd5017` | **found** (code identical to Base) |
| LimitedCallsEnforcer | `0x04658B29F6b82ed55274221a06Fc97D318E25416` | **found** (identical to Base) |
| TimestampEnforcer | `0x1046bb45C8d673d4ea75321280DB34899413c069` | **found** (identical to Base) |
| SimpleFactory, MultiSigDeleGatorImpl, HybridDeleGatorImpl | `0x69Aa…c77c`, `0x56a9…f3A7`, `0x48dB…FEC4` | missing |
| AllowedTargets / AllowedMethods / AllowedCalldata | `0x7F20…4EeB`, `0x2c21…42B5`, `0xc2b0…0f55` | missing |
| ValueLte, NativeTokenTransferAmount, ERC20TransferAmount, ERC20PeriodTransfer, ERC20Streaming | `0x92Bf…6A8F`, `0xF71a…0320`, `0xf100…D2Fc`, `0x474e…39aB`, `0x56c9…be00e` | missing |
| ExactCalldata, ExactExecution, ArgsEqualityCheck, BlockNumber, Deployed, Id, Nonce, Redeemer, LogicalOrWrapper, OwnershipTransfer | see Deployments.md | missing |
| All Native/ERC20/721/1155 BalanceChange and MultiOperationIncreaseBalance enforcers, MultiTokenPeriod, NativeTokenPayment, Native streaming/period, SpecificActionERC20TransferBatch, ApprovalRevocation | see Deployments.md | missing |

Also present: EntryPoint v0.7 `0x0000…a032` and v0.8 `0x4337…f108`, Arachnid CREATE2 `0x4e59…956C`, Multicall3, Permit2.

Notes:

- **Who controls the DelegationManager.** The DM owner can `pause()` all delegation redemptions on 99901. That would halt our keeper but never lock
  client funds. Who deployed the contracts is unknown. Anyone can replay MetaMask's CREATE2 deployment with the same constructor args, so their
  presence does **not** prove MetaMask supports Elysium in the wallet. The remote flag shows it does not (section 3).
- **Missing contracts can be deployed by us.** Every missing contract can be deployed at its canonical address from the v1.3.0 tag
  (same compiler settings, salt "GATOR"). We would deploy only what we use: HybridDeleGatorImpl (+ SimpleFactory), and AllowedTargets /
  AllowedMethods as defense in depth.
- **Chain notes.** The chain is Arbitrum Nitro: `ArbSys.arbOSVersion()` = 116, base fee 0.5 gwei, priority fee 0, and an L1 calldata price of 0
  from `ArbGasInfo`.
- **RPC quirk.** `eth_estimateGas` and `eth_call` on this RPC **ignore `authorizationList`**: the estimate was 21,229 gas with or without the
  authorization. Any self-built 7702 transaction must add ≥ 25,000 gas per authorization by hand.
- **RPC rate limit.** The RPC is Conduit-hosted and rate-limits batched calls (−32017), so the keeper must throttle.

## 2. Can one delegation give the keeper exactly the LP rights and nothing else?

### What the stock enforcers cannot do

- **Pinning v4 owners and recipients.** `PositionManager.modifyLiquidities(bytes unlockData, uint256 deadline)` takes
  `unlockData = abi.encode(bytes actions, bytes[] params)`. The owner (MINT_POSITION) and the recipient (TAKE_PAIR / SWEEP) are deep inside
  `params`. Their offsets depend on the action sequence and the hookData length. `AllowedCalldataEnforcer` pins one fixed byte range to one value.
  Covering mint, increase, decrease and burn would take a `LogicalOrWrapper` of per-shape groups with exact offsets: fragile, and one encoding
  variant (non-empty hookData, an extra SWEEP, a different action order) escapes it. **Not acceptable as the custody guarantee.**
- **Batch mode.** `AllowedTargets`, `AllowedMethods`, `AllowedCalldata` and `ValueLte` call `onlySingleCallTypeMode`, so they reject batch
  executions. A re-range must therefore be several single-call redemptions inside one `redeemDelegations` call. That works, but each one pays
  for validation.
- **Swaps.** v4 swaps need an `unlockCallback`. Neither the client EOA nor the DeleGator has one, so a swap must go through a router. Its recipient
  is again nested calldata.
- **"≤ 35% of account value".** `ERC20TransferAmount` and `ERC20PeriodTransfer` caps are absolute. Account value needs pool state, LP amounts and an
  anchored price, which is stateful logic no stock enforcer has. This also conflicts with the rule that ceilings are a % of the account.
- **Price and slippage bounds** against an anchor: none exist.
- **ERC-7715 Advanced Permissions** (`wallet_grantPermissions`, MetaMask flag `enabledAdvancedPermissions`) only offers token stream, periodic,
  allowance and revocation permission types. There is no arbitrary contract call, so it is useless for LP management.

### Recommended architecture (minimal trust)

```
keeper EOA ──calls──> LPManagerModule (immutable; the ONLY delegate)
                         │ builds calls itself: owner/recipient = client account, fixed PoolKey,
                         │ min-out, anchor/band checks, per-account budgets, 35% hedge cap, HWM fee
                         └──> DelegationManager.redeemDelegations([delegation], single-call execs)
                                  │ caveats (signed by client):
                                  │   ElysiumCustodyEnforcer  (custom, stateless where possible)
                                  │   TimestampEnforcer        (expiry, e.g. 180 d; re-sign to extend)
                                  └──> client account executes:
                                         Permit2.approve / USDC.approve(Permit2)
                                         PositionManager.modifyLiquidities (v4 actions)
                                         SwapExecutor.swap (pays msg.sender only)
                                         USDC.transfer(hedgeTreasury | feeRecipient)
```

The client signs one EIP-712 delegation with these fields:

- `delegate = LPManagerModule`
- `delegator = client account`
- `authority = ROOT`
- caveats `[ElysiumCustodyEnforcer(terms = hedgeTreasury, feeRecipient, poolId), TimestampEnforcer(until)]`

Because the delegate is the module, a stolen keeper key can only drive the module's code paths. It can never submit raw executions.

**`ElysiumCustodyEnforcer`** (new, ~200–300 lines, the client-visible guarantee; immutable). Its `beforeHook` runs per single execution and
allows only these:

| Target | Selector | Checks |
|---|---|---|
| PositionManager | `modifyLiquidities` | Decode `actions`; every action ∈ {MINT_POSITION, INCREASE_LIQUIDITY, DECREASE_LIQUIDITY, BURN_POSITION, SETTLE_PAIR, CLOSE_CURRENCY, TAKE_PAIR, SWEEP}; PoolKey == the fixed HYPE/USDC 3000/60/no-hook pool; every MINT owner, TAKE_PAIR recipient and SWEEP recipient == delegator; hookData empty. The `tokenId` of INCREASE/DECREASE/BURN must be owned by the delegator (`ownerOf`). Native value ≤ the delegator's balance (SWEEP returns leftovers). |
| Permit2 | `approve` | token = USDC, spender ∈ {PositionManager, SwapExecutor}. |
| USDC | `approve` | spender = Permit2. |
| SwapExecutor (ours) | `swap(poolKey, zeroForOne, amountIn, minOut)` | PoolKey fixed. The executor pulls via Permit2 from `msg.sender` and pays `msg.sender` only, so custody is safe by construction. |
| USDC | `transfer` | `to == hedgeTreasury`, or `to == feeRecipient` with the fee backstop below. |

Anything else reverts: other targets, `setApprovalForAll`, NFT transfers, native sends to EOAs, and approvals to other spenders.

The module enforces the rest. Each is a check on the custody-safe calls the enforcer allows:

- **Price.** One global price anchor for all accounts (reused `RiskBudgets.movePrice`). `report(price)` must be within `poolBandBps` of the pool
  and move at most `refDriftBps` per decaying day. The guardian can `approvePrice(lo, hi, until)`.
- **Per-account turnover.** `mapping(account => Budgets)`: swaps plus LP-add value ≤ `swapTurnoverBps` × account value per decaying day.
  An LP add is valued at the anchor (`V4PositionMath.liquidityValue`) and must be ≥ paid × (1 − slippage).
- **Hedge cap.** `max(reportedHedgeEquity_i, netMargin_i) + amount ≤ 35%` × account value_i. Account value counts LP amounts at the anchor,
  idle USDC/HYPE and hedge equity_i.
- **HWM fee.** 15% of the gain of `managedValue_i − netContributed_i` above that account's HWM. It is sent as USDC to `feeRecipient`.
- **Pause** (guardian): stops adds, swaps and fee. Never stops decreases or burns, margin returns, or anything the client does directly.

**Fee and hedge backstop in the enforcer.** The enforcer does not trust the module's value math. It enforces a coarse, %-based stateful
limit on the delegator's USDC balance at hook time:

- transfers to `hedgeTreasury` ≤ 35% per decaying day;
- transfers to `feeRecipient` ≤ 20% of the transferred-at-time balance, at most once per 7 days.

A module bug then still cannot send more than those slices to our own addresses, and nothing anywhere else.

**What the client keeps.**

- The client owns every position NFT and every token. It can call PositionManager or transfer directly at any time.
- It can revoke the delegation with `DelegationManager.disableDelegation`, or just let it expire.
- No keeper action, pause or limit can block an exit. This is stronger than the pooled vault, where the exit needed `settle` or the 72 h
  emergency path.

**Why not "keeper EOA = delegate + custom enforcer only".** That design works, but every execution would then come from off-chain calldata
that the enforcer must fully parse. With the module, the call is built in Solidity with recipient = client, and the enforcer is a second,
independent check. Two layers, and the client-signed layer is small enough to audit fully.

## 3. MetaMask support on 99901 (status 2026-11-13)

| Capability | 99901 today | Evidence |
|---|---|---|
| 7702 upgrade (extension/mobile "Smart account" toggle, or `wallet_sendCalls` triggering the upgrade) | **No** | MetaMask remote flag `confirmations_eip_7702.supportedChains` (client-config.api.cx.metamask.io, extension and mobile, prod) lists ~45 chains; `0x1863d` is absent. Support is allowlisted per chain, with signed delegator addresses (all `0x63c0…`). |
| `wallet_getCapabilities` → `atomic` | Nothing returned for 0x1863d | Docs: "If a chain ID has neither status, MetaMask will not return anything for that chain ID." [Send batch transactions](https://docs.metamask.io/wallet/how-to/send-transactions/send-batch-transactions/) |
| `wallet_sendCalls` atomic | Error 5710 ("EIP-7702 not supported on the specified chain ID") | Same docs page and the [wallet_sendCalls reference](https://docs.metamask.io/metamask-connect/evm/reference/json-rpc-api/wallet_sendCalls.md) |
| Dapp-requested raw 7702 authorization | **Never**, on any chain | The Smart Accounts Kit [EIP-7702 quickstart](https://docs.metamask.io/smart-accounts-kit/get-started/smart-account-quickstart/eip7702.md) uses a local key because viem `signAuthorization` does not support JSON-RPC accounts. MetaMask upgrades only to its own contract ([support article](https://support.metamask.io/configure/accounts/switch-to-or-revert-from-a-smart-account/)). |
| `eth_signTypedData_v4` on a custom network (delegation signature, USDC permit) | **Yes** | This is a standard method. The EIP-712 domain uses chainId 99901 and DM `getDomainHash()` = `0xbec2a594…45fd`. |

Consequence: the "1 signature = 7702 authorization + delegation" flow needs MetaMask to add `0x1863d` to its allowlist. That is a business
request to MetaMask/Consensys, which may be plausible given the HL ecosystem. Until then:

**Launch path, works today with plain MetaMask:**

1. The client signs (a) the delegation typed data (to its counterfactual `HybridDeleGator`, owner = client EOA) and (b) a USDC EIP-2612 permit.
2. Our relayer, paying gas in HYPE, deploys the HybridDeleGator via SimpleFactory, moves USDC in with the permit, and stores the delegation.

That is 2 signatures and 0 client transactions. Withdrawal is one `execute` signed by the owner EOA, either as a plain transaction or as a
sponsored ERC-4337 userOp (EntryPoint v0.7 exists on 99901).

The trade-off: funds sit at the client's own smart-account address (only the client's key can move them), not at the EOA itself. Our web page
must show its balance.

## 4. Reuse plan from `~/elysium-lp-vault`

**Carry over as is or nearly:**

- `src/V4PositionMath.sol`: price, amounts with uncollected fees, `liquidityValue`, and the mint/increase/remove calldata builders. These
  already take the recipient `me` as a parameter: pass the client account.
- `src/RiskBudgets.sol`: the decaying-day primitive. The price anchor stays global; the turnover and hedge budgets become per account.
- Keeper `strategy.py`:
  - unchanged per pool: `range_*`, `choose_price`, `sticky_price`, `anchor_move`, `CrashGuard`, `deploy_split`;
  - unchanged except fed per-account state: `turnover_room`, `hedge_move`.
- Keeper `hl.py`, `v4math.py`, `rpc.py` (User-Agent header, publicnode-only policy), `infra.py`, the systemd unit and the guardian-bot concept.

**Changes:**

- **Hedge.** One HL short = Σ of client LP HYPE deltas, kept on our HL account. A per-client ledger tracks `marginSent_i`,
  `marginReturned_i`, a daily delta-weighted PnL attribution → `hedgeEquity_i`, and reports per-account equity to the module under the
  H-1 rule. Margin is returned to the client's address. That direction needs no permission.
- **Fee.** Per-account HWM 15% replaces the fund-level fee. (As built, contributions are measured on-chain at every module action
  instead of through `allocate` / `release` calls; see section 6.)
- **Keeper loop.** It becomes per account: fetch state for N accounts, rebalance, and pack several clients per transaction (the module
  loops; ≤ ~25 clients per tx at ~1M gas each, under Nitro's 32M per-tx cap).
- **Removed.** Shares, the deposit/redeem queues, `settle`, `claimable`, virtual shares, `emergencyUnwind` / `emergencyRedeem`, and the web
  deposit-queue UI. The client holds the assets, so there is nothing to unwind for them.

**Audit-1 findings that carry over as design constraints:**

| Finding | Constraint in the new design |
|---|---|
| H-1 / M-9 | Keeper-reported hedge equity may only go down (≤ `hedgeStepBps` of the account value per decaying day). Any increase needs the guardian's exact, expiring value. A clipped report never reverts. |
| H-2 / M-4 / M-10 | One anchor, moved only by bounded-rate reports and frozen while paused. Every swap and add is checked against the pool band AND the anchor. |
| H-3 | An LP add is a swap: value at the anchor ≥ paid × (1 − slippage), charged to per-account turnover. |
| M-5 | The hedge cap applies to `max(reportedEquity_i, netMargin_i)`. |
| M-2 | Guardian approvals bind value, account, epoch and expiry, and are cleared by margin moves. |
| M-6 / L-16 | Pause must never block decreases, burns or margin returns. Client exits never touch the module. |
| I-2 | `sync(address(0))` before the native settle in `SwapExecutor`. |
| L-15 | Min-out on every swap, computed at the anchor. |
| L-13 | keeper ≠ guardian. Module parameters change only via `VaultTimelock`, or the module is fully immutable. Enforcer and module addresses are immutable in the signed delegation. |
| Residual | Hedge custody (≤ 35% per client at the operator's HL account) and stale reporting of a real hedge loss remain, as before. |

**Disappears with per-client accounts:** the accomplice-deposit amplification (H-1 root cause), first-depositor inflation, queue
head-of-line (M-7) and the in-kind emergency rules (M-8). No client's flows can move another client's price.

## 5. Gas per client per rebalance

Measured on an Elysium fork (`forge test --match-contract Fork --gas-report`, today's pool state). The vault-level figures include the vault's
own checks, so they are a fair proxy for the module.

| Step | Gas |
|---|---|
| burnPosition (decrease all + take) | ~156k |
| swap (unlock + settle/take) | ~158–200k (raw pool swap ~106k) |
| mintPosition (new NFT) | ~450k |
| increasePosition | ~244k |
| fee-only collect (`decrease 0`) | ~30–145k |
| Delegation overhead per `redeemDelegations` entry (signature check + custody-enforcer decode + Timestamp) | ~25–50k estimated × 3–5 entries |
| Module budgets + V4PositionMath valuation | ~60–100k estimated |

| Action | Gas | Cost at 0.5 gwei, HYPE $72.55 |
|---|---|---|
| Full re-range for one client (burn + swap + mint) | ~0.9–1.1M | ~0.0005 HYPE ≈ **$0.04** |
| Fee collect or hedge transfer for one client | ~0.1–0.2M | ≈ $0.005–0.01 |
| 100 clients, full re-range | ~100M | ≈ 0.05 HYPE ≈ **$3.6** per round |
| One-time onboarding (HybridDeleGator deploy + permit pull), paid by relayer | ~0.35–0.45M estimated | ≈ $0.015 |

- **Fees today.** Base fee 0.5 gwei (the floor), priority fee 0, block utilisation 1–3%, L1 calldata price 0. A burst of 100M gas exceeds
  Nitro's default speed limit (~7M gas/s) for ~15 s, which could lift the base fee. Spread the rounds over minutes.
- **Versus the pooled vault.** About 100× the gas of one pooled re-range, but still negligible in dollars.

## Open risks

1. **No MetaMask 7702 on 99901.** EOA-in-place custody depends on MetaMask allowlisting `0x1863d`, which is outside our control. Launch on
   per-client HybridDeleGator accounts.
2. **New custom code.** `ElysiumCustodyEnforcer`, `LPManagerModule` and `SwapExecutor` need an audit. The enforcer is the critical piece: it
   decodes the v4 action encoding. Fuzz it against v4-periphery `Actions` encodings, including non-canonical ones.
3. **DelegationManager pause.** The owner `0xB0403B…` can pause the DM on 99901. That halts management only; client funds stay safe.
4. **Fee leakage.** Per-account HWM fees can be avoided by a client who exits between keeper touches. Bounded by the fee interval.
5. **Hedge custody.** Up to 35% of each account's value sits at our HL account. When a client revokes, we must close their share of the short
   and return the margin promptly. This is an operational obligation; monitor it.
6. **Races with client actions.** A client acting directly (burning a position, moving USDC) can make keeper transactions revert. The keeper
   must re-read state and treat it as a withdrawal.
7. **RPC.** It ignores `authorizationList` in estimates and rate-limits batches. Not relevant to the HybridDeleGator path; relevant once 7702
   arrives.
8. **Missing contracts.** Canonical HybridDeleGatorImpl, SimpleFactory, AllowedTargets and AllowedMethods must be deployed by us at their
   canonical addresses. Verify the code hash against Base after deploying.

## 6. As built (branch `smart-account`, audit SA-1 fixes on `sa-r1-fixes`)

### Contracts (`src/sa/`, solc 0.8.26 via-IR, runs 1; runtime sizes)

| Contract | Bytes | Role |
|---|---|---|
| `LPManagerModule` | 23,980 (596 under EIP-170) | The keeper's only delegate. Ownable2Step (owner = `VaultTimelock`), transient reentrancy guard. |
| `SALib` (external, linked) | 19,440 | Delegation shape check, account identity (CREATE2 derivation / 7702 designator), registration, flow booking (`sync` writes the snapshot), valuation at a price, HWM fee, budgets (`movePrice`, `moveHedge`, turnover), execution builders with approval resets, verified transfers out. |
| `SAWindow` (internal) | — | Sliding 24 h budget: nine 3 h buckets; any 24 h window admits at most 1x the cap. |
| `ElysiumCustodyEnforcer` | 7,802 | Client-signed caveat (MetaMask Delegation Framework v1.3.0 `ICaveatEnforcer`). |
| `SwapExecutor` | 3,402 | v4 unlock-callback router: exact input, pays only `msg.sender`, min-out, sqrtPrice limit, refunds unused native. |
| `vendor/DelegationFramework.sol` | interfaces | `ModeCode`, `Caveat`, `Delegation`, `Execution`, DM / DeleGator / HybridDeleGator / SimpleFactory interfaces, EIP-712 hash. |

Reused unchanged: `V4PositionMath`, `VaultTimelock`. The SA path no longer uses `RiskBudgets` (it stays as is for the shelved vault). The pooled vault (`LPVaultBase`, `UniV4LPVault`) is untouched.
Deployment: `script/DeploySA.s.sol` (not run on a live chain) creates HybridDeleGatorImpl (+ its linked SCL library at CREATE2 salt 0)
and SimpleFactory from `test/fixtures/delegation-framework-v1.3.0` through the Arachnid CREATE2 deployer; the tests assert they land
on the canonical addresses `0x48dB…FEC4` and `0x69Aa…c77c`. DM, 7702 delegator and TimestampEnforcer are the ones already on 99901.

### The delegation (what the client signs)

`delegate = module`, `delegator = account`, `authority = ROOT`, `salt` any, exactly two caveats:

1. `ElysiumCustodyEnforcer`, `terms = abi.encode(module, hedgeTreasury, feeRecipient)` (non-zero, distinct). The module accepts only
   its own terms hash.
2. `TimestampEnforcer`, `terms = uint128(0) ‖ uint128(until)`, `until ≥ now + 1 day` (the web page uses 180 days).

`register` checks the shape (no caveat `args`, a 65-byte signature, expiry ≤ uint64), the account identity, the signature through the
account's ERC-1271 `isValidSignature`, and that the delegation is not disabled. Identity (SA-1 C-1 / H-2): a 7702 account is an EOA whose
code is the designator for `0x63c0…` (owner = the EOA); a hybrid account must sit at the SimpleFactory CREATE2 address of the canonical
ERC1967Proxy initialised with (owner, no P256 keys) under the fixed salt: `owner()` is only a candidate that must re-derive the address,
and the treasury / fee recipient can never be owners. The owner is pinned at registration. The first registration is permissionless
(relayer); replacing the stored delegation or resuming after a revoke needs the account or its pinned owner (SA-1 M-1). Re-registering
keeps the account's books.

### `ElysiumCustodyEnforcer.beforeHook` (default deny)

Called by the DelegationManager only; single-call default mode only; `redeemer == module` from the terms. Allowed executions:

| Target | Rule |
|---|---|
| PositionManager | `modifyLiquidities(unlockData, deadline)` only. The calldata, `unlockData` and every action's params must be the canonical ABI encoding (re-encoded and compared byte for byte). ≤ 16 actions from {MINT_POSITION, INCREASE_LIQUIDITY, DECREASE_LIQUIDITY, BURN_POSITION, SETTLE_PAIR, TAKE_PAIR, CLOSE_CURRENCY, SWEEP}; every other action code (0..255) reverts. MINT: the fixed PoolKey, `owner == delegator`, empty hookData. INCREASE/DECREASE/BURN: `ownerOf(tokenId) == delegator` and the position is in the fixed pool, empty hookData. SETTLE_PAIR / TAKE_PAIR: exactly (HYPE, USDC). TAKE_PAIR / SWEEP: `to == delegator` (no `MSG_SENDER` / `ADDRESS_THIS` sentinels). Native value > 0 only if the last action is SWEEP(native → delegator). |
| SwapExecutor | `swap(zeroForOne, amountIn, minOut, limit)` only, amounts > 0, value == amountIn iff native input. |
| Permit2 | `approve(token, spender, amount, expiration)`: token = the pool's ERC-20, spender ∈ {PositionManager, SwapExecutor}; amount 0 always allowed, otherwise `expiration ∈ {0, now}` (same-block) and amount ≤ the delegator's balance. |
| USDC | `approve(Permit2, ≤ balance)`; `transfer(hedgeTreasury, x)` within 35% of the idle USDC balance per sliding 24 h window (state per delegator AND terms hash, SA-1 M-6); `transfer(feeRecipient, x)` ≤ 20% of the idle USDC balance, at most once per 7 days. |
| anything else | reverts: other targets and selectors, native transfers, other spenders/recipients, batch or try modes, short calldata. |

Consequence for the keeper: hedge margin is limited by the account's **idle** USDC, so the keeper sends margin before the LP add
(and keeps a small idle buffer); a fee above 20% of idle USDC is charged partially, so the keeper frees USDC from the position first.

### Module

- **Contributions are measured on-chain.** Every module path that touches an account starts with `SALib.sync`, which books what
  changed since the last snapshot (idle USDC, idle HYPE, tracked positions' liquidity) as a client flow AND writes the new snapshot in
  the same step, so no path can book a flow twice (SA-1 H-3 / M-2). Inflows are valued at min(anchor, pool), outflows at max (L-2).
  After the action a directional post-check (idle may fall only by what the action spends) and, for decreases/burns, a value-conservation
  check at the pool price stop account code from moving value out inside the bracket (M-5); positions with a subscriber are refused.
  Positions the account no longer owns are dropped. A client may add or take funds directly at any time.
- **Liveness** (`isActive`): registered, not revoked, not expired, delegation not disabled, and the account's identity unchanged (7702
  designator, hybrid `owner()` == pinned owner): an owner change or a re-delegation is a revocation (L-14).
- **Account value** at a price: idle USDC + idle HYPE × price + each position's principal at sqrt(price) + its uncollected fees +
  reported hedge equity. No pool-spot term (M-4); fee and margin sends need an anchor that is fresh, unclipped and within the pool band.
- **Budgets** (`SAWindow`, sliding 24 h, 1x): per account turnover (swaps + LP adds) and keeper-only hedge decreases; one global anchor
  drift window, charged |Δ| / min both ways (M-7). Guardian price ranges and hedge approvals are one-shot, TTL ≤ 1 day, cleared by a pause
  / guardian change; a hedge approval binds (account, epoch, stored value, value, guardian era) and every margin move bumps the epoch (M-3).
- **HWM fee**: `fee = feeBps × (profit − hwm)` capped at 20% of idle USDC; a capped fee advances the mark only by the gain it charged
  (L-11). Needs a fresh unclipped anchor in band, a recent unclipped hedge report (L-12), `feeInterval` since the last fee, not paused.
- **Hedge margin**: `sendHedgeMargin` (keeper, not while paused, fresh anchor) is verified at the treasury (recipient delta, H-2).
  `returnHedgeMargin` (keeper or treasury, never paused) always pays INTO the account, live or not, inside a sync/snapshot bracket; the
  keeper may return at most the account's own hedge equity (H-1), the treasury itself any amount.
- **Onboarding**: `onboard(delegation, amount, permit)` registers and pulls USDC from the HybridDeleGator's **owner** into that account
  only (a permit cannot be redirected to another account; a front-run permit is tolerated). 7702 accounts already hold their funds.
- **Batching**: `multicall(bytes[], allowFailure)` (self-delegatecall) for many accounts per transaction.
- **Client stop**: `revoke(account)` by the account or its pinned owner: one plain call, no external calls, not pausable (M-8).
- Max 4 positions per account. `renounceOwnership` disabled. Owner, keeper, guardian, treasury, fee recipient and the module pairwise
  distinct (constructor and setters, L-8). Approvals the module builds are reset to 0 in the same redemption (L-17).

Audit-1 constraints carried over: H-1 / M-9 (equity only down without the guardian), H-2 / M-4 / M-10 (one bounded-rate anchor, frozen
while paused, every swap/add within band of pool and anchor), H-3 (adds valued at the anchor, charged to turnover), M-2 (approvals bind
account, epoch, value, expiry; cleared by margin moves), M-5 (cap on max(equity, net margin)), M-6 / L-16 (pause never blocks
decreases, burns, margin moves or client actions), I-2 (`sync` before native settle), L-13 (roles distinct, timelocked owner, immutable
enforcer/treasury/fee recipient), L-15 (min-out and a sqrtPrice limit at the anchor band edge on every swap). Each has a test in
`test/sa/LPManagerModule.t.sol`.

### Client exit

- **HybridDeleGator**: one transaction from the owner EOA: `EntryPoint.handleOps([op], owner)` with a zero-fee user operation
  (EIP-712 signed by the owner; domain `HybridDeleGator` / `1` / 99901 / account) whose `execute(batch, TRY)` runs
  `module.revoke(account)`, `DelegationManager.disableDelegation(d)` and `modifyLiquidities(BURN_POSITION, TAKE_PAIR → account)` for
  every position. TRY exec type: a failing burn (e.g. the keeper burned it first) cannot undo the revoke; the EntryPoint reports success
  even when the inner call failed, so the web page and the keeper check the result by state (`account(a).revoked`), not by status (M-8).
  Fork gas: 185k (one position, forge) / 272k (anvil, incl. calldata). A second identical transaction withdraws USDC + HYPE to the EOA.
- **7702**: one transaction from the EOA to itself (`execute` is `onlyEntryPointOrSelf`), 114k gas.
- Works while the module is paused and while the DelegationManager is paused (the exit never redeems a delegation).
- Afterwards every keeper call reverts (`NotLive`). The keeper closes the client's share of the HL short and pays its hedge equity
  back INTO the account with `returnHedgeMargin` (at most the on-chain hedge equity; any rest needs the treasury itself); the client
  withdraws it from the account. `netMargin` keeps the realised hedge cost
  (a flow counter, not a debt).

### Keeper (`keeper/elysium_keeper/sa_keeper.py`, `sa_chain.py`, `ledger.py`)

- `python -m elysium_keeper sa-run | sa-status | sa-onboard --request req.json`; config section `sa` (module, accounts / event scan
  from block, stagger, margin target 25% of value, idle buffer 3%, ledger path, relayer request directory).
- Tick: anchor (HL mid → same price choice as the vault keeper) → relayer queue → for each account, re-read from the chain: exited →
  wind down; live → margin first, LP (burn out of range, swap to the range split in ≤ $1.5k chunks with `eth_call` probes, mint or
  increase within the turnover room), fee when due, hedge target = LP HYPE + idle HYPE, report hedge equity (down only; alert the
  guardian for increases) → one netted HL order, fills split by the ledger → reconcile the ledger with treasury + HL equity + in transit.
- **Hedge ledger** (one HL account for all clients): `equity_i = margin in − margin out + short_i × (mark move) − own fill fees +
  reconciliation share (funding/slippage, by short notional)`; opposite wants are crossed internally without an order; a residual
  below the HL lot is handed to the other clients at the mark.
- Safety: HL adapter `dry_run` by default (live is double-gated as before); `unlocked` signer refuses non-local RPC; `keystore` needs
  `chain.allow_live_chain`; `readonly` plan mode; RPC sends a User-Agent and refuses Alchemy.
- Relayer: deploy the HybridDeleGator (SimpleFactory) + `module.onboard` in one Multicall3 `aggregate3` transaction, after checking the
  counterfactual address and simulating.
- Status file (`sa.status_path`): written atomically every tick (per account: owner, kind, active/revoked, expiry, value, idle,
  positions, contributed/profit/HWM/fees, hedge equity / net margin, ledger share; an account whose tick failed keeps its last row
  flagged `stale`). No alerts, errors or actions in it: it is served to clients by the relayer API.

### Relayer API (`keeper/elysium_keeper/sa_api.py`, `python -m elysium_keeper sa-api`)

Stdlib `http.server` on 127.0.0.1 (nginx proxies `/elysium-api/sa/`, `keeper/deploy/nginx_elysium_api.conf`); no key, never signs,
only validates and writes `<owner>.json` into `sa.requests_dir` (temp file + `link`, so it is atomic and never overwrites).

- `POST /elysium-api/sa/onboard` `{owner, kind, delegation, permit}` → `202 {ok, state: "queued", owner, account, kind}`;
  errors `{ok: false, error, detail}` (400 schema/shape, 401 signature, 409 `already_registered` / `already_queued`, 411/413/415,
  429, 503). Checks, all before anything is queued: strict schema (exact keys, hex shapes, uint as number or decimal string, no
  floats / duplicate keys, body ≤ 16 KB); the delegation equals `module_delegation(account, module, enforcer, treasury, feeRecipient,
  until, salt)` (delegate = module, ROOT, exactly the custody caveat with the module's terms + TimestampEnforcer `0 ‖ until`, empty
  args, 65-byte signature) with `until ∈ [now + MIN_DELEGATION_LIFETIME + 1 h, now + 400 d]`; account = CREATE2 HybridDeleGator of the
  owner (owner not a protocol address) or, for 7702, the owner EOA carrying the canonical designator; both EIP-712 signatures recover
  to the owner (low s, v ∈ {27, 28}, DM domain on 99901); delegation not disabled; account not registered; permit (hybrid only):
  token = `module.asset()`, spender = module, `0 < value ≤` the wallet's USDC balance, deadline in [now + 10 min, now + 1 day],
  signed over the owner's current nonce (a used or front-run permit no longer verifies). At start the API cross-checks the module's
  DM / TimestampEnforcer / factory / hybrid impl / 7702 impl / account salt / `enforcerTermsHash` against the constants it hashes with.
  One pending request per owner (an identical resubmission returns 200); rate limits per client IP (before any work) and per owner
  (after the delegation signature proved the owner).
- `GET /elysium-api/sa/status?owner=` → `{owner, account, kind, state, error, summary, keeper}`; `state` ∈ none / queued / failed (with
  the keeper's reason, URLs stripped) / onchain (registered, not yet in the keeper's file) / active / revoked; `summary` from the
  keeper's status file; `keeper` = last tick, age, fresh, paused, anchor.
- `GET /elysium-api/sa/health` → `{ok, pending, chain_id, module, keeper}` (503 if the queue is not writable).
- Logs: addresses and outcome codes only (the default access log, which prints IPs, is off). systemd unit
  `keeper/deploy/elysium-sa-api.service`: dedicated user in the keeper's group, `ProtectSystem=strict`, the keeper's state dir hidden
  except the queue (rw) and the status dir (ro), `NoNewPrivileges`, no capabilities, syscall filter.

### Web (`web/account.html`, `web/account.js`)

Plain MetaMask `eth_signTypedData_v4` on 99901: (1) the delegation (hash checked against `DelegationManager.getDelegationHash` before
signing), (2) the USDC permit (spender = module); POST to the relayer API, then follow `GET status` until the account is on
chain (the chain read is the fallback); a queued or failed request is shown on reload. The page shows the counterfactual account. A wallet already
upgraded to `0x63c0…` can use itself (one signature). Account view (value, net deposits, profit, fees, HWM, idle, hedge margin, ranges,
expiry), "Add USDC", "Stop and close positions" (one transaction; the user-op hash is checked against the account's own
`getPackedUserOperationTypedDataHash` before signing), "Withdraw to wallet". `?mock=1` walks through every state without a wallet.
The JS encodings (counterfactual address, delegation digest, user-op digest) were checked equal to the Python ones, which the anvil
e2e checks against the chain.

### Tests

- `test/sa/SARegressions.t.sol` (33): audit SA-1 regressions: for C-1, every High and every Medium the auditor's PoC and at least
  one sibling path from `docs/audit/sa_round1_rootcause.md` (hostile account code via a real UUPS upgrade, 7702 re-delegation, owner
  rotation, subscribers, racing burns against the exit), plus L-3 / L-4 / L-10 / L-17.
- `test/sa/CustodyEnforcer.t.sol` (27): every allowed shape, every action code 0..255, recipients/owners/sentinels, foreign pool and
  foreign tokenIds, non-canonical encodings, native value rules, targets/selectors, Permit2/ERC-20 spenders and amounts, hedge and fee
  %-limits, 4 fuzz tests, a rogue delegate through the real DelegationManager, redeemer mismatch.
- `test/sa/LPManagerModule.t.sol` (31): onboarding (hybrid, 7702, permit front-run, permit redirection), every `BadDelegation` code
  and non-canonical accounts, roles, L-13, M-10/H-2 anchor, L-15, per-account turnover, H-3 limit-order mint, M-5, H-1/M-2, M-6, HWM
  lifecycle, deposits/withdrawals/direct burns as flows, fee freshness/idle, exits (hybrid, 7702, DM paused), re-registration,
  multicall, SwapExecutor, gas.
- `test/fork/SmartAccount.fork.t.sol` (3, `ELYSIUM_FORK=true`): canonical framework on 99901, hybrid end to end with the real USDC
  permit (onboard → margin → swap → mint → volume → fee → exit → margin back into the account), 7702 end to end.
- Relayer API: `tests/test_sa_api.py` (schema rejects, bad / high-s / wrong-chain signatures, delegate / caveats / expiry, permit
  edge cases and replay after the nonce moved, already registered / disabled, 7702 designator, idempotency, per-IP and per-owner
  limits, status states, the HTTP layer) and `tests/test_sa_api_e2e_fork.py` (anvil fork: web-shaped body → API over HTTP → queue →
  keeper tick and `sa-onboard --request` → two accounts live → status active → replays 409 → revoke → status revoked).
- Keeper: `tests/test_sa_unit.py` (16: fee mirror, ledger, EIP-712 vs `eth_account`'s independent encoder, addresses) and
  `tests/test_sa_e2e_fork.py` (anvil fork: deploy script, two clients via relayer and request queue, ticks, convergence, fee, one-tx exit,
  wind-down, restart no-op).
- The test environment runs offline on a **replica**: the exact runtime code of Elysium's PoolManager, PositionManager, Permit2,
  EntryPoint v0.7 and the CREATE2 deployer is etched at their addresses (`test/fixtures/elysium`), chain id 99901.

### Gas (forge fork of Elysium, one client)

| Action | Gas |
|---|---|
| Relayer: deploy HybridDeleGator + onboard with permit | ~1.33M (incl. test overhead) |
| `sendHedgeMargin` | ~250k |
| `swap` | ~290k (replica) / ~455k (fork, cold) |
| `mintPosition` | ~650–670k |
| `burnPosition` | ~190k |
| Client exit (handleOps, 1 position) / 7702 | ~185k / ~114k |

A full re-range (burn + swap + mint) is ~1.1–1.3M gas, ≈ 0.0006 HYPE at 0.5 gwei.

### Open issues

1. Audit pending (`docs/audit_sa_round1.txt`). The enforcer's v4 decoding is the critical piece.
2. MetaMask still does not 7702-upgrade on 99901 (section 3): the 7702 path is built and tested but only usable once it does; until then
   MetaMask may also refuse the 7702 self-call exit (the HybridDeleGator path does not depend on it).
3. The relayer HTTP endpoint is written (`sa_api.py`, branch `sa-relayer`) but not deployed: needs the user/dirs, the API config,
   the nginx include, and an `sa-run` keeper unit with `sa.requests_dir` / `sa.status_path` set (see the unit file header).
4. Hedge margin top-ups are limited to 35%/day of idle USDC by the enforcer (by design); a client whose value is all in the LP gets
   top-ups only after the keeper frees USDC.
5. Fee leakage: a client can take profit out between keeper touches (booked as a withdrawal); fees collected by the client directly
   are booked as contributions. Bounded by the fee interval; accepted.
6. The live HL adapter and treasury ↔ HL bridging stay manual / gated exactly as for the pooled vault.
