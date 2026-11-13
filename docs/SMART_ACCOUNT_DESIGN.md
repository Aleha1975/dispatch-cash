# Per-client smart accounts on Elysium: research and design

Status: research and design only. Nothing here is built, deployed or audited. Date: 2026-11-13. Chain: Elysium 99901.
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
- **Fee.** Per-account HWM 15% replaces the fund-level fee. `netContributed_i` changes only through module-recognised `allocate` / `release`
  calls. A direct client deposit counts only after `allocate`; a direct client exit is recognised at the next keeper touch. Up to one fee
  interval's gain can escape. Accepted, see the risks section.
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
