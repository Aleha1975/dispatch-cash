<!-- Plain-text rendering of LeftClaw job #1241 (HTML original; the IPFS copy is authoritative). -->

Elysium LP smart accounts, round 4 (final pre-pilot review) — LeftClaw Services
      🦞
      LeftClaw Services
      ·
      Smart Contract Audit
    Elysium LP smart accounts, round 4 (final pre-pilot review)
    Job #1241 · completed on-chain · report pinned to IPFS
      Job page #1241
      Canonical report IPFS
      Generated 2026-11-18
      1
High
      4
Medium
      14
Low
      8
Info
    Contents
      1. Answer to the question you asked
      2. Task 1 — status of the round-3 Mediums
      3. Task 3 — accepted residuals (docs/audit/sa_round3_response.md)
      4. Round-4 exit window — your three checks
      5. Findings
      6. Examined and found sound
      7. Reconciliation summary
Security Audit — Elysium LP smart accounts, round 4 (final pre-pilot review)
Job: leftclaw.services #1241 · Date: 2026-11-18
Repo: https://github.com/Aleha1975/dispatch-cash · Commit: 04420ec34171ad3280bd86cbd967bf18c41d6d6a (head of branch elysium-lp-sa, verified reachable on the remote with git ls-remote)
Compiler / chain: solc 0.8.26, via-IR, cancun · Elysium mainnet 99901 (Arbitrum Orbit) · not deployed
Scope (11 files, 2,275 nSLOC): src/sa/LPManagerModule.sol, src/sa/SABook.sol, src/sa/SALib.sol, src/sa/SARange.sol, src/sa/SAWindow.sol, src/sa/SwapExecutor.sol, src/sa/ElysiumCustodyEnforcer.sol, src/sa/vendor/DelegationFramework.sol, src/V4PositionMath.sol, src/VaultTimelock.sol, script/DeploySA.s.sol. The pooled vault is out of scope.
Method: x-ray pre-scan → context (protocol map, access-control inventory, threat catalog) → 8 checklist agents over 14 checklists (breadth) → 12 blind attack agents (depth, 12 of 12 returned) → reconciliation with a three-axis coverage gate.
Severity counts: 0 Critical · 1 High · 4 Medium · 14 Low · 8 Informational
Limits of this review, stated plainly:
Nothing was compiled or run. Audit policy forbids executing target code, so every finding is a source trace with numbers, not a Foundry test. You asked for "a concrete trace or a Foundry test"; you get traces, plus a test recipe for the High finding. The 228-test count and the 23,996-byte module size are your figures, not re-measured.
Uniswap v4 behaviour was read from source at the repo's pinned submodule commits (v4-core 59d3ecf, v4-periphery c6e4754), not assumed.
The Delegation Framework source is not in the repo (only init-code fixtures). Statements about DelegationManager internals (hook order, checks at redemption, behaviour of disableDelegation while paused) could not be verified here.
1. Answer to the question you asked
Is there a principal-loss path for a pilot of about USD 250 at the script parameters with swapTurnoverBps 5000 and exitTurnoverBps 10000?
By a third party with no key: none found. No path moves funds out of an account to an address other than the client, the pool, hedgeTreasury or feeRecipient. The client can always revoke and exit, also with the module and the DelegationManager paused.
By a stolen keeper: yes, and larger than stated. The stated bound is 4.5% of value per day. The on-chain bound is about 10–13% of value on day 1 and it grows with each further day, because the bound is measured against the anchor and the keeper can place the anchor a full refDriftBps from the market in one transaction (M-1). At USD 250 that is about USD 25–32 on day 1 instead of USD 11.
By the client's own ordinary actions: yes, one path (H-1). A client who empties a tracked position directly and adds liquidity to the same NFT again can corrupt its books permanently, after which the keeper's routine chargeFee takes 20% of idle USDC every 7 days. In the pilot the operator is the client, so the rule is simple: do not empty and refill a tracked NFT directly until H-1 is fixed. Fix it before any external client is onboarded.
Recommendation for the pilot: it can run on the operator's own funds if (1) nobody touches tracked NFTs directly, (2) refDriftBps is lowered for the pilot (for example 300) or the M-1 per-step cap is added, (3) the guardian bot is live before the first reportPrice, and (4) swapTurnoverBps is edited in the script before broadcast, since the script still deploys 20000 and lowering it later takes at least 24 h (I-1).
2. Task 1 — status of the round-3 Mediums
Round-3 ID
Finding
Status
Evidence
1226 M-1 / 1227 M-1
Client-collected LP fees booked as a contribution
Partly fixed — the fix introduced H-1
A single client collect, decrease, increase or burn between two looks is exact or under-counted (traced against Position.update). A decrease followed by an increase is over-counted, and without bound when a tick is cleared.
1227 M-2
Swap record not bound to the module's swap
Fixed
Count + 1, keccak256(msg.data) and min-out at LPManagerModule.sol:499. Re-entry reverts on the executor guard; the native refund runs before the record is written; a second unlock is impossible; the count is transaction-wide and re-read per swap. No way found to produce a matching record with other economics.
1226 M-3 / 1227 M-3
Walk + fee on the drift budget
Partly fixed
feeGate works for one day. The residual bound (0.225% of exposure per week) is understated: the gate admits one band per 24–27 h, or a full refDriftBps after a one-day hold (L-2).
1226 M-4 / 1227 M-4
Booking a full band from the pool
Fixed (bounded as stated, against the anchor)
BOOK_BAND_BPS in _trusted (LPManagerModule.sol:861-862). The anchor's own distance from the market is M-1.
1227 M-5 / 1226 M-2 (swap part)
Keeper chooses the booking moment
Fixed, with one new gap
Swaps, mints and increases need _trusted; sync(a) is permissionless. New: sync accepts an address that never registered (M-2).
1227 M-6 / 1226 L-1
Fee at min(V(anchor), V(pool))
Fixed
Profit is V(anchor) − contributed after a sync at the same anchor (LPManagerModule.sol:593).
1227 M-7 / 1226 L-2 / 1226 M-2 (budget part)
Path-length drift budget
Fixed as specified; the per-step cap of 1226 M-2 was not adopted
Net displacement over the trailing 24 h is enforced. Bucket edges, the 24–27 h tail, values ≥ 2^112 and the guardian reset were checked and hold (section 6). But the whole budget is usable in one report, which is the root of M-1.
Your four specific questions
SABook fee step — is (feeGrowthInsideLast_now − mark) × n exactly what PoolManager paid? No. It is exact only while the position's liquidity was constant and never zero between the two looks. See H-1 (unbounded) and L-1 (transferred NFT burned elsewhere). Paths checked and found exact or under-counting: module modify, one client collect / decrease / increase / burn, NFT transferred out and not burned, subscribed positions (refused before any module action), tick-boundary cases of lpAdd / lpRemove, and unchecked wrap-around while liquidity stays above zero.
SwapExecutor hash binding — can account code produce the module's hash with different economics? No path found (row 1227 M-2 above).
SARange / movePrice — can a stolen keeper move the anchor more than refDriftBps from a value held in the last 24 h? No, not without a guardian range. But it can use the whole refDriftBps in one transaction and use the anchor 300 s later (M-1). A consumed guardian range forgets the history and gives a fresh ±refDriftBps at once (I-2). After the owner lowers refDriftBps the clamp can move the anchor against the report (L-8).
Trusted gate and feeGate — can the anchor used for booking or the fee be off the pool by more than the bands, or a flow be booked at another price than value() uses? Not against the pool at that instant. Booking and value use the same anchor. The weakness is that every pool read is a spot read inside the keeper's own transaction, so "within the band of the pool" does not mean "within the band of the market" (M-1, L-2, L-3).
3. Task 3 — accepted residuals (docs/audit/sa_round3_response.md)
#
Residual
Bounded as stated?
Reaches principal?
1
Fees of an NFT moved out / fee share of a partial decrease not counted
Yes for those two cases. One nearby case goes the other way: an NFT moved out and then burned by its new owner is counted as yield (L-1).
L-1 only: a fee on fees the account never received, small.
2
Several direct liquidity changes between two syncs
No. The stated bound ("that liquidity's own fee income") fails. With a cleared tick the over-count is about n × 2^128. Without a cleared tick it is the fee income of liquidity that was absent, not of liquidity the client added.
Yes — H-1.
3
Client timing inside the 50 bps booking band
Yes.
No (lowers the fee).
4
Keeper booking at the band edge
Yes against the anchor.
Fee only, ≤ 0.075% of the flow.
5
Fee after a pool push (0.225% of exposure per week)
No. About 1.5% per 24–27 h compounding over the fee interval, or refDriftBps after a one-day hold (L-2).
Yes, as a fee on principal to feeRecipient, capped at 20% of idle USDC per interval.
6
Fee deferral in a rally
Yes.
No.
7
Stolen-keeper oscillation ≈ (band + slippage) × turnover
No. The drift term is missing (M-1).
Yes — M-1.
8
Liveness: pool held > 50 bps off pauses booking, swaps, adds, fees
Yes, but "exits" there means the client's exit. The keeper's risk-off sell is among the blocked actions (M-4).
No theft; market exposure.
9
Round-2 carry-overs (keeper-attested equity, guardian increases, treasury allowance …)
Holds against the keeper alone and the guardian alone. Not against both together (M-3, L-4).
With both keys: yes.
4. Round-4 exit window — your three checks
(a) Does any path charge a risk-adding swap or an add to the exit window? No. _useTurnover has two call sites. swap passes sellBase && _positions[a].length == 0 (LPManagerModule.sol:487); _add passes false. Buys, sells with a tracked position and every LP add stay on the turnover window.
(b) Can a client-held or untracked position make the module think the account holds none in a way that matters? No. An untracked or transferred position is not in account value, so it only lowers the cap. The opposite case exists: a tracked NFT with zero liquidity, or one the client subscribed, keeps _positions non-empty, so sells stay on the turnover window (L-6).
(c) The stated bound. Not correct: see M-1. Two further facts: exitTurnoverBps = 0 blocks position-less sells entirely instead of falling back (L-5), and the exit sell is unavailable under pause, in a fall beyond refDriftBps, and while the pool is held 50 bps off (M-4).
5. Findings
H-1 — A client who empties and refills a tracked position gets a wrapped fee amount booked as yield; the fee then takes 20% of idle USDC every interval
Severity: High · Confidence: [90] · Origin: both phases (4 of 8 checklist agents, 11 of 12 attack agents, each independently)
Location: SABook._feesOut — src/sa/SABook.sol:102-121; called from SABook.sync at :71; realised in LPManagerModule.chargeFee at src/sa/LPManagerModule.sol:593-597
// SABook.sol:71-72
_feesOut(s, q, v, p, owned ? (liq < old ? liq : old) : 0, old);
if (price == 0) continue;
// SABook.sol:107-113
if (pmLiq == 0) n = old; // burned or emptied by the client: its last modify paid the fees on `old`
...
unchecked {
    c0 = FullMath.mulDiv(l0 - q.g0, n, 1 << 128);
    c1 = FullMath.mulDiv(l1 - q.g1, n, 1 << 128);
}
What is wrong. The step treats PoolManager's feeGrowthInsideLast of a position as a continuous counter and n = min(live, snapshot) as a floor on the liquidity held between two looks. Neither holds when the position's liquidity goes to zero and comes back. Read from v4-core at the pinned commit:
Pool.modifyLiquidity computes fee growth inside, updates the position, and only then calls clearTick on a tick whose gross liquidity reached zero (Pool.sol:184-203).
When liquidity returns, updateTick initialises the tick again: feeGrowthOutside is set to the global value only if tick <= current tick (Pool.sol:533-538). Fee growth inside then restarts at 0, whether the price is in, below or above the range.
Position.update pays fees on the liquidity before the update, which is 0, and always overwrites the mark (Position.sol:82-101).
So after "decrease to 0, then increase" the PoolManager mark is 0 while the books still hold the old mark q.g0 > 0. The unchecked subtraction wraps to about 2^256, and mulDiv(≈2^256, n, 2^128) ≈ n × 2^128. Nothing reverts: the result fits uint256 because n < 2^128, and int256 because n < 2^127.
A sync in between does not help unless the anchor is trusted: an untrusted sync refreshes the marks but skips the liquidity refresh (continue at :72), so n stays positive after the refill. With the deployed parameters any sync more than 300 s after the last report is untrusted.
Trace (base = currency0 = native HYPE, asset = currency1 = USDC):
The keeper mints token T for account A with liquidity 1e15 on ticks no other position uses. In a thin pool with keeper-chosen ticks this is the normal case.
The position earns 1 USDC of fees. The keeper collects with decreasePosition(A, T, 0, …). SABook.book stores the mark g1 = 1e6 × 2^128 / 1e15 ≈ 3.4e29.
The client, directly on PositionManager, sends DECREASE_LIQUIDITY(T, 1e15) and keeps the NFT. PoolManager liquidity is 0; the ticks are cleared.
The client sends INCREASE_LIQUIDITY(T, 1e15). This can be the same modifyLiquidities call as step 3. The ticks are initialised again; the PoolManager mark is 0.
Any sync runs — any keeper action, including reportHedgeEquity and returnHedgeMargin, or anyone's sync(A). n = min(1e15, 1e15), l1 − q.g1 = 2^256 − 3.4e29, so c1 ≈ 1e15 × 2^128 ≈ 3.4e53. snapAsset and snapBase each rise by about 3.4e53.
The next trusted sync books f = x − snapAsset + … (SABook.sol:91), about −3.4e53, into contributed (:95).
chargeFee: profit = int256(accountValue(a, ref)) − s.contributed ≈ 3.4e53 (LPManagerModule.sol:593). hwmFee returns the cap, 20% of idle USDC, and advances hwm only by fee × BPS / feeBps − fee. Profit stays far above hwm.
Every feeInterval the keeper's routine fee run sends another 20% of idle USDC to feeRecipient. The enforcer allows exactly that. After 10 intervals about 11% of the idle USDC is left.
Nobody is malicious in this trace. No function repairs contributed; re-registration keeps it. The client's only remedy is revoke.
Preconditions. (1) The client empties a tracked NFT directly and adds to the same NFT again. (2) No trusted sync of that account runs in between. (3) At least one of the position's ticks has no other liquidity at the moment it is emptied. (4) The books' mark differs from the new mark, which is true after any earlier module collect or modify, or after an untrusted sync between steps 3 and 4.
Bounded variants with the same root cause (not covered by residual 2 as worded):
Ticks shared with another LP, empty then refill: the books credit the range's fee growth for the time the position held nothing.
Dip and return (L → L₁ → L): over-count of (growth during the dip) × (L − L₁).
Two-step emptying with an untrusted look in between (L → L/2 → 0): pmLiq == 0 gives n = old = L, an over-count of (growth of the second leg) × L/2.
The NatSpec at SABook.sol:51-52 ("a client change in between can only make this smaller") is false for all of these.
Why High. The trigger is an action the design explicitly allows ("the client can always act on its account directly"), the loss is principal (20% of idle USDC per week, repeating), and the books cannot be repaired. It is not Critical because a third party cannot trigger it and the money goes to the operator's immutable feeRecipient.
Fix (smallest robust change). Bound the mark difference by something PoolManager cannot make jump, and never credit more than reached the account. Store the pool's global fee growth with each mark:
 struct Pos {
     uint128 liq;
     uint256 g0;
     uint256 g1;
+    uint256 G0; // feeGrowthGlobal0X128 at the books' last look
+    uint256 G1;
 }
 ...
 function _feesOut(...) private {
     (uint128 pmLiq, uint256 l0, uint256 l1) = v.pm.getPositionInfo(...);
+    (uint256 G0, uint256 G1) = v.pm.getFeeGrowthGlobals(v.id);
     if (pmLiq == 0) n = old;
     uint256 c0;
     uint256 c1;
     unchecked {
-        c0 = FullMath.mulDiv(l0 - q.g0, n, 1 << 128);
-        c1 = FullMath.mulDiv(l1 - q.g1, n, 1 << 128);
+        uint256 d0 = l0 - q.g0;
+        uint256 d1 = l1 - q.g1;
+        if (d0 > G0 - q.G0) d0 = 0; // growth inside can never exceed global growth: a jump is a tick reset
+        if (d1 > G1 - q.G1) d1 = 0;
+        c0 = FullMath.mulDiv(d0, n, 1 << 128);
+        c1 = FullMath.mulDiv(d1, n, 1 << 128);
     }
     (uint256 cb, uint256 ca) = v.baseIsCurrency0 ? (c0, c1) : (c1, c0);
+    // belt: fees PoolManager paid are in the account; never credit more than the idle balance holds above the snapshot
+    int256 ra = int256(IERC20(v.asset).balanceOf(a)) - s.snapAsset;
+    int256 rb = int256(_bal(v.base, a)) - s.snapBase;
+    if (ra < 0 || ca > uint256(ra)) ca = ra < 0 ? 0 : uint256(ra);
+    if (rb < 0 || cb > uint256(rb)) cb = rb < 0 ? 0 : uint256(rb);
     s.snapAsset += int256(ca);
     s.snapBase += int256(cb);
     q.g0 = l0;
     q.g1 = l1;
+    q.G0 = G0;
+    q.G1 = G1;
 }
Write G0 / G1 in SABook.book too (_feesOut needs a passed in). Both guards can only lower the credited yield, which is the direction you already accept. The phase-2 agents proposed three alternatives; any one closes the wrap: the idle-surplus clamp alone, the global-growth cap alone, or crediting nothing whenever PoolManager liquidity differs from the books' liquidity. The clamp alone still lets a wrapped credit absorb a client deposit made in the same interval, so use it together with the cap.
Regression test to add (not run here): mint on exclusive ticks → swaps → keeper collect → client DECREASE(all) + INCREASE in one batch → reportHedgeEquity (untrusted sync) → trusted sync → assert contributed moved only by the real flow and chargeFee returns 0.
M-1 — The stolen-keeper bound omits the anchor drift: day-1 loss is about 10–13% of value at pilot parameters, not 4.5%
Severity: Medium · Confidence: [85] · Origin: phase 1 (3 agents independently); phase 2 raised only the liveness side
Location: LPManagerModule.reportPrice — src/sa/LPManagerModule.sol:392-404; _trusted — :856-863; _checkKeeperPrice — :875-881; swap — :485-492; SALib.movePrice — src/sa/SALib.sol:353-359
// SALib.sol:354-355 — one report may use the whole budget
uint256 up = Math.mulDiv(lo, WAD + capWad, WAD);
uint256 dn = Math.mulDiv(hi, WAD, WAD + capWad, Math.Rounding.Ceil);
// LPManagerModule.sol:861-862 — the use gate reads the pool once, now
return _freshOk() && block.timestamp >= lastPriceMoved + st && block.timestamp <= lastPriceTime + st
    && d * BPS <= pool * BOOK_BAND_BPS;
What is wrong. The stated bound prices each unit of turnover at poolBandBps + maxSlippageBps = 3%. That is the loss against the anchor. The anchor's only tie to the market is the pool's spot price, read once inside the keeper's report transaction and once inside the keeper's using transaction. Nothing requires the pool to stay anywhere in between. The code comment says so itself (LPManagerModule.sol:853-855): "what bounds a keeper that also pushes the pool is the drift budget". The drift budget is 10% and one report may use all of it. So the per-unit loss against the market is refDriftBps + poolBandBps + maxSlippageBps.
The keeper key can run push → module call → unwind as one batch (EIP-7702 code on the keeper EOA keeps msg.sender == keeper), or as back-to-back transactions on a first-come sequencer. The pool is thin: by your figure about USD 700 moves it 1.5%.
Trace (pilot parameters; market M = 30.00; anchor 30.00, flat for 24 h; account worth USD 250 = 125 USDC + 4.1667 HYPE after its positions are burned — burnPosition has no budget and no trust gate):
t0, one batch. Sell HYPE into the pool until spot is 27.27. Call reportPrice(27_272_728): the pool-band check passes; dn = ceil(30e6 / 1.1) = 27_272_728, so the report is applied unclipped. Buy back to 30.00. Cost: two pool fees on a few thousand USD.
t0 + 300 s, one batch. Push spot to 27.20. No second report is needed: at exactly t0 + 300, both now >= lastPriceMoved + 300 and now <= lastPriceTime + 300 hold. Call swap(a, true, 4.1667e18, 26.87e6, 0). It is charged to the exit window (no tracked position; cap 1.0 × value). The floor is 110.28 USDC, which is 0.882 M. The account receives about 112.85 USDC for HYPE worth 125. Loss: about 12 (14.7 at the floor). Unwind.
Same batch: reportPrice(30_000_000) — inside the same 10% range, so it is free.
t0 + 600 s: push to 30.15; buy base with 118 USDC on the turnover window at up to 1.03 M. Report down again.
t0 + 900 s: sell that HYPE on the rest of the exit window at about 0.88–0.90 M.
Day-1 loss
Share of USD 250
Realisable through the pool
≈ 24.7
≈ 9.9%
At the contract floors
≈ 31.7
≈ 12.7%
Stated bound
11.25
4.5%
All of it fits in 15 minutes after the first on-chain sign. It is not a per-day bound either: the keeper can walk the anchor 10% per 24 h with no trades and then sell the whole base holding on one exit window; the worst sell price is 0.985 × 0.985 × M / 1.1^n — 0.80 M after 2 days. LP adds are charged at half their principal (slip / (slip + band)), so an add at a displaced anchor costs more per unit of budget. Budgets are per account, so one push serves every account in a multicall. At the script's swapTurnoverBps 20000 the same arithmetic gives about 21% against a stated 9%.
The exit window is what makes the day-1 number large: it lets 1.0 × value of base be sold in one step, at an anchor the keeper chose.
What still protects the client. The guardian bot has minPriceStable = 300 s between the displaced report and its first use to pause. That is off-chain and is the only control in that window.
Fix. In order of effect:
Add the per-step cap that 1226 M-2 proposed (only the stability gate was adopted):
// reportPrice, before movePrice: one keeper step <= poolBandBps, and no second step until the last one is stable
if (old != 0 && price != old) {
    if (block.timestamp < lastPriceMoved + params.minPriceStable) price = old;
    else {
        uint256 step = Math.mulDiv(old, params.poolBandBps, BPS);
        if (price > old + step) price = old + step;
        else if (price + step < old) price = old - step;
    }
}
A 10% walk then takes at least 7 stable windows (35 minutes), each needing its own pool push in public view. The guardian range remains the path for real jumps.
2. Lower refDriftBps for the pilot (for example 300) and treat it as part of the loss bound.
3. Restate residual 7 as about (refDriftBps + poolBandBps + maxSlippageBps) × (swapTurnoverBps + exitTurnoverBps) per day, more for adds.
4. Have the guardian bot pause on any anchor-versus-external-price gap above poolBandBps.
M-2 — Anyone can run sync on an address before it registers and fix the price its holdings are booked at
Severity: Medium · Confidence: [75] · Origin: phase 2 only (access-control agent); re-derived by the orchestrator
Location: LPManagerModule.sync — src/sa/LPManagerModule.sol:867-870; SALib.register — src/sa/SALib.sol:261
function sync(address a) external nonReentrant {
    if (!_trusted()) revert StalePrice();
    _sync(a);
}
What is wrong. deposit (:364), returnHedgeMargin (:542) and reportHedgeEquity (:562) all require delegationHash != 0. sync does not. For an unregistered address the books are all zero, so SABook.sync books the address's whole balance as a contribution at the current anchor: contributed = USDC balance + native balance × anchor. A first registration later resets nothing except lastFeeTime (SALib.sol:261), and later syncs book only differences. The design rule at register — "it books nothing: what the account holds is booked by the first keeper sync at a trusted anchor" — is therefore not the whole story: the first booking can be anyone's, at any earlier trusted anchor.
Trace (feeBps 1500):
Day 0: address X holds 1,000 HYPE and 10,000 USDC and is not registered. The trusted anchor is 20. Anyone calls sync(X): contributed = 10,000 + 1,000 × 20 = 30,000.
Day 60: X registers; the anchor is 30; value is 40,000. contributed stays 30,000.
Day 67: chargeFee: profit = 40,000 − 30,000 = 10,000; fee = 1,500 USDC, under the 20% idle cap of 2,000. The enforcer's first fee has no interval.
The module never managed the account while that gain accrued. With the intended flow the profit is 0.
Who is exposed. Any account that holds base before it registers: every 7702 account (the EOA already holds its funds), and a hybrid whose counterfactual address was funded with HYPE before onboarding. A hybrid funded only through onboard is not affected (its balance is 0 before, and onboard books at face value). The caller gains nothing; the fee goes to feeRecipient. The mirror case — the client syncing itself at a high anchor before registering — only lowers the fee.
Fix.
 function sync(address a) external nonReentrant {
     if (!_trusted()) revert StalePrice();
+    if (accounts[a].delegationHash == 0) revert NotRegistered();
     _sync(a);
 }
M-3 — A guardian hedge-equity approval has no size limit: keeper + guardian together lift every value-relative budget and can pull the treasury's allowance into any registered account
Severity: Medium (needs two operator keys) · Confidence: [80] · Origin: phase 1 only
Location: LPManagerModule.approveHedgeEquity — src/sa/LPManagerModule.sol:651-668; SALib.moveHedge — src/sa/SALib.sol:394-410; returnHedgeMargin — LPManagerModule.sol:544-546
// LPManagerModule.sol:656-661 — any `value` is accepted
if (s.delegationHash == 0 || s.hedgeEpoch != expectedEpoch || s.hedgeEquity != expectedStored
        || until > block.timestamp + MAX_APPROVAL_TTL) revert BadParam();
...
b.hedgeApproved = value;
// LPManagerModule.sol:544 — the keeper's pull limit is that same number
if (!byTreasury && amount > h) revert HedgeCap(amount, h);
What is wrong. The module header says the guardian "cannot unpause or move funds". Alone it cannot. But hedgeEquity is a term of accountValue, which is the base of the turnover and exit windows, the keeper's equity step and the fee profit; and it is the keeper's limit for moving USDC out of hedgeTreasury. None of approveHedgeEquity, the approval path of reportHedgeEquity, or returnHedgeMargin is pausable, and first registration is permissionless.
Traces (keeper and guardian keys both stolen):
(a) Turnover bound gone. Guardian approves 1,000,000e6 for a USD 250 account; keeper reports it. Value is now 1,000,250, so the turnover cap is about 500,125 USDC and the exit cap about 1,000,250. The stated per-day bound no longer limits swap volume.
(b) Fee. The inflated equity is profit: 20% of idle USDC per 7 days to feeRecipient.
(c) Treasury allowance. The attacker registers its own account X. Guardian approves equity A for X; keeper reports A; keeper calls returnHedgeMargin(X, A). A USDC moves from hedgeTreasury to X, up to the treasury's balance and its allowance to the module. That USDC is other clients' margin. It works while paused. The "approve just-in-time" rule narrows the window; it does not close it.
Fix. Bound what an approval can do with values only real transfers write:
// returnHedgeMargin: the keeper returns at most what this account really sent, net
uint256 lim = h < s.netMargin ? h : s.netMargin;
if (!byTreasury && amount > lim) revert HedgeCap(amount, lim);
// budgets (swap, _add, reportHedgeEquity): equity above netMargin does not widen any window
uint256 nav = accountValue(a, ref) - (h > m ? h - m : 0);
M-4 — The risk-off exit sell is unavailable in the conditions it exists for
Severity: Medium (liveness of the round-4 product; no theft) · Confidence: [80] · Origin: phase 1 (3 agents); phase 2 lead
Location: LPManagerModule.swap — src/sa/LPManagerModule.sol:474-490 (whenNotPaused at :478, _checkKeeperPrice at :482 → _trusted at :856-863); SALib.movePrice — src/sa/SALib.sol:355-359
What is wrong. The exit window only changes which budget is charged. The sell still needs: not paused; a trusted anchor (unchanged for 300 s, pool within 50 bps of it); and a full fill, because min-out is computed on the whole amountIn. Removals carry none of these gates. So the keeper can take an account out of the pool into raw HYPE and then be unable to sell it.
Scenarios:
Crash. A fall of more than 9.1% from the 24 h high clips the anchor at hi / 1.1. Example: high 30.00, market 26.40; the anchor stops at 27.27, which is 3.3% from the pool, so _freshOk is false. swap reverts StalePrice for 24–27 h, or until the guardian calls approvePrice and 300 s pass.
Trend. Any report that changes the anchor, even by one unit, restarts lastPriceMoved (:397). If the market moves 0.6% per 5 minutes the pool is always more than 50 bps from the last stable anchor.
Pause. The guardian bot pauses on divergence — exactly when a risk-off sale is wanted. Unpause is a timelocked call of at least 24 h that the guardian can cancel.
Third party. About USD 230 moves this pool 0.5%. Holding spot 50 bps off the anchor blocks every exit sell.
Throughput. One chunk may move the pool up to 1.5%; the gate is then false until arbitrage or a new stable window.
Residual 8 says "not removals, returns or exits". That is true for the client's own exit. It is not true for this swap.
Fix. Decide explicitly, then either document that risk-off stops at "burned to idle HYPE", or give the exit branch its own gate: keeper price within poolBandBps of the pool and the anchor, the existing min-out and price limit, but not the stable window or BOOK_BAND_BPS; sync with price 0 so flows stay pending. If exit sells should work under pause: if (paused && !exit) revert IsPaused(); plus a guardian approvePrice for the frozen anchor. Note the tension with M-1: a looser exit gate must not be reachable at a keeper-walked anchor, so pair it with the M-1 per-step cap.
Low findings
L-1 — A transferred-out NFT that its new owner burns is counted as yield on the old liquidity. SABook.sol:107. Severity: Low · Origin: both. sync passes n = 0 for a position the account no longer owns, but if (pmLiq == 0) n = old; overrides it. If the new owner burns or empties the NFT before the next trusted sync drops it, the books add (mark at burn − books' mark) × old. That includes fees accrued after the transfer and paid to someone else; profit rises by that part and feeBps of it is charged. The NatSpec ("transferred out counts nothing") is contradicted. Bounded by the position's fee income until the next trusted sync. One phase-2 agent judged this profit-neutral; re-derivation shows it is neutral only for fees accrued before the transfer. Fix: if (pmLiq == 0 && owned) n = old; — a client burn then falls under residual 1 — or rely on the H-1 idle-surplus clamp, which covers it.
L-2 — The fee-after-push bound (residual 5) is understated. SALib.feeGate — src/sa/SALib.sol:375-378. Severity: Low · Origin: phase 1. The gate compares the anchor with the lowest anchor of the trailing 24 h only. Each +1.5% becomes the new low after 24–27 h, and reports and the fee transaction use the same atomic pushes as M-1. Over a 7-day interval the anchor can be walked 1.015^7 ≈ +11% while passing the gate daily; or +10% in one report, held one day. Example: 125 USDC + 125 of HYPE, anchor pushed to 33 and held 27 h: profit 12.5 at an unchanged market, fee 1.875 USDC (1.5% of exposure against a stated 0.225%). Capped at 20% of idle USDC; goes to feeRecipient. Fix: gate on the lowest anchor since lastFeeTime, or restate the residual. The M-1 fixes bound this too.
L-3 — The hedge cap is measured on two keeper-pushable prices with no stable window. LPManagerModule.sendHedgeMargin — src/sa/LPManagerModule.sol:516-526. Severity: Low · Origin: phase 1. Only the anchor's age is checked (:516); min(V(anchor), V(pool)) (:525) does not help when the keeper raises both in the sending transaction. The cap against true value is 35% × (1 + drift × base share): 36.75% on day 1, about 51.6% after a 7-day walk. The enforcer's 35%-of-idle rate is the binding limit on day 1. Funds go to the immutable treasury. Fix: also take the value at the trailing-24 h low anchor (SARange.bounds already gives it).
L-4 — The hedge cap is not cumulative once the guardian co-signs a write-down. SALib.sol:401-405. Severity: Low (two keys; destination is the operator treasury) · Origin: phase 1. The approval path writes netMargin down to the approved value, outside hedgeStepBps and outside pause. After an approved 0 the full cap is available again on what remains: 1,000 USDC → 350 sent, approve 0, 227.5 sent … after 7 daily cycles about 49 USDC is left. Fix: give sends their own window that an approval cannot reset, or limit an approved write-down of netMargin to hedgeStepBps × value per 24 h.
L-5 — exitTurnoverBps = 0 blocks every base sale with no tracked position; exit sells never use unused turnover. LPManagerModule.sol:487, :883-886. Severity: Low · Origin: both. "Off" yields a cap of 0 and WindowOverflow, where round 3 admitted the same sale on turnover. A test shows this is intended; undoing it takes a timelock round. Fix: bool exit = sellBase && _positions[a].length == 0 && params.exitTurnoverBps != 0;.
L-6 — Window selection keys on the array length, not on liquidity. LPManagerModule.sol:487. Severity: Low · Origin: phase 1. A tracked NFT emptied through decreasePosition(all), emptied by the client, or subscribed by the client keeps _positions non-empty. Sells then run on swapTurnoverBps; at 5000 a full exit does not fit a day. The subscribed case cannot be cleared by the keeper (_remove reverts Subscribed). Only the account's owner can cause it. Fix: compute exit from tracked positions with non-zero liquidity that are not subscribed; have the keeper burn rather than decrease to zero.
L-7 — A 7702 account's gas balance is sellable. LPManagerModule.swap; SALib.modify — src/sa/SALib.sol:518-519. Severity: Low · Origin: phase 1. Native HYPE is both currency0 and the gas token, and neither the module nor the enforcer keeps a floor. An exit sell of the whole balance leaves the EOA unable to send revoke or any withdrawal until someone sends it HYPE. Hybrid accounts are not affected. The 7702 path is not usable on 99901 yet, per your design notes. Fix: a GAS_RESERVE check for KIND_EIP7702 after swaps and adds.
L-8 — After refDriftBps is lowered, movePrice can move the anchor against the report. SALib.sol:354-359. Severity: Low · Origin: phase 1. The clamp assumes the anchor is inside [dn, up]. With the cap lowered from 20% to 5%, a window of 100–110 and the anchor at 100, reportPrice(100) yields 104.77. The anchor is then outside the band of the pool and trust is lost for 24–27 h. Fix: if (dn > up || ref < dn || ref > up) q = (p >= dn && p <= up) ? p : ref;.
L-9 — The permit fallback can spend a later standing allowance. SALib.pull — src/sa/SALib.sol:293-305; LPManagerModule.deposit — :362-368. Severity: Low · Origin: phase 1. deposit spends the owner's allowance to the module without marking the used-permit slot. If a permit P was submitted directly, its allowance spent through deposit, and the owner later approves the same amount again, anyone can call onboard with the stale P before its deadline and move that amount into the owner's own account. Not a loss — the destination is the owner's account — but the NatSpec claim "a standing allowance is never used" is not exact. Fix: cap the fallback's lifetime (deadline <= block.timestamp + 1 hours) or correct the NatSpec.
L-10 — The timelock's EXECUTOR role can still be renounced. VaultTimelock.renounceRole — src/VaultTimelock.sol:138-141. Severity: Low · Origin: phase 1. Round 3 blocked only PROPOSER_ROLE (:139). The operator is the only executor; after renounceRole(EXECUTOR_ROLE, …) nothing can execute, including the grantRole that would repair it. The module could then never be unpaused and the keeper and guardian never rotated. Clients can still exit. Fix: if (role == PROPOSER_ROLE || role == EXECUTOR_ROLE) revert NoRenounce(); and grant before revoke in rotation batches.
L-11 — The guardian is the only instant pause. LPManagerModule.setPaused — :672-673. Severity: Low · Origin: phase 1. The owner is the timelock, so without a working guardian the earliest stop of a stolen keeper is 24–48 h away, at the full M-1 rate. Fix: a second pause-only role.
L-12 — DeploySA's "OWNER must be a multisig" check passes for a 7702-delegated EOA. script/DeploySA.s.sol:111. Severity: Low · Origin: phase 1. On a 7702 chain an EOA with a designator has code.length == 23. Fix: reject the 0xef0100 prefix; better, require a Safe-style getThreshold() >= 2.
L-13 — A 7702 code change or hybrid owner change is a suspension, not a revocation. SALib.live — src/sa/SALib.sol:225-229. Severity: Low · Origin: phase 1. live is stateless. If the EOA later delegates back to the canonical delegator, management resumes on the stored delegation with no register, unlike after revoke. The module header calls this "a revocation". No funds leave the stated destinations. Fix: correct the text, or add a permissionless lapse(a) that sets revoked when the account is not live before expiry.
L-14 — _trusted does not require a confirming report, and any changed report restarts the wait. LPManagerModule.sol:397, :861. Severity: Low · Origin: phase 1. One report at t0 satisfies both clocks at exactly t0 + minPriceStable; a Nitro timestamp spans several blocks, so that instant is easy to hit. "Re-confirmed" is therefore not enforced (it would come from the same key anyway). In the other direction, a change of one unit restarts the stable clock, which feeds M-4. Fix: restart lastPriceMoved only on a move above a small threshold; treat the "re-confirmed" wording as documentation, not a control.
Informational
I-1 — The deploy script ships swapTurnoverBps: 20000 (script/DeploySA.s.sol:175), not the pilot's 5000. setParams is timelocked, so an unedited deploy runs at four times the pilot turnover for at least 24 h; registration is open from the first reportPrice. The script reads back roles and wiring but not Params. Its comment asks for a "live and deep" pool but checks only non-zero liquidity, and the first report is unbudgeted. Read the pilot values from env with pilot defaults; read params() back.
I-2 — A consumed guardian range forgets the 24 h history (SALib.sol:361-364). The keeper picks any point in the range a pushed spot supports, gets a fresh ±refDriftBps at once, and the fee gate's trailing low becomes that point, so a fee is chargeable 300 s after an approved upward jump. Acknowledged as 1227 I-11. Keep ranges narrow and short; consider recording the pre-jump level after the reset.
I-3 — No upper bound on delegation lifetime (SALib.sol:161-162). A never-submitted signature with a far expiry stays registrable by anyone until it is disabled or pre-revoked. Add a maximum, for example 400 days.
I-4 — A hybrid owner cannot pre-revoke from its EOA. Before registration the stored owner is zero, so revoke(a) admits only the account itself, which for a hybrid means a self-bundled user operation. Also, the header's alternative stop (DelegationManager.disableDelegation) and its behaviour under a DM pause could not be verified from the repo. Document it; add a fork test.
I-5 — Base sells below 1e18 / price wei charge zero turnover (LPManagerModule.sol:486-490). About USD 1e-6 per swap; no economic effect. if (fair == 0) revert ZeroAmount();
I-6 — The timelock delay and the guardian's veto window run on the sequencer clock. The 24 h floor equals a typical force-inclusion delay. Keep the deployed delay at least twice the chain's force-inclusion delay.
I-7 — The DelegationManager owner on 99901 is an external address (0xB0403B32…9f44, script/DeploySA.s.sol:130). A DM pause stops decreasePosition, burnPosition and exit sells too, because every keeper action redeems. Client exits and margin returns are unaffected. Confirm who controls it on Elysium.
I-8 — Fee-lowering paths, listed for completeness (accepted direction, none reaches principal): a client that lowers a position to liquidity 1, syncs, and increases again pays no performance fee on its LP fees; an NFT moved out during an untrusted sync takes its collected fees out of the books; an equal hedge report refreshes hedgeTime without lowering equity (keeper-attested, residual 9).
6. Examined and found sound
Destinations. Every execution the module builds has owner / recipient = the account; the enforcer checks the same, canonically re-encoded, default deny. Recipients are the delegator, hedgeTreasury and feeRecipient only. The enforcer's action table matches PositionManager's decoders; the MSG_SENDER / ADDRESS_THIS sentinels are ruled out.
Client exit. revoke is one storage write with no modifier, no pause check and no external call. All six redeeming functions pass through _live. The exit never redeems a delegation, so it does not depend on the module, the keeper or the DM. Only the client can resume. Exception to "everything is in the account": margin already at hedgeTreasury comes back only through the keeper or the treasury.
SwapExecutor. Payer = recipient = msg.sender; no custody; the callback is reachable only from its own guarded swap; the record cannot be substituted.
SARange / SAWindow. A value recorded in a bucket expires 24 h + 1 s to 27 h later, never earlier; every value held in the last 24 h is covered (recorded when applied, when replaced, and the current value is always included). The clamp preserves dn ≤ lo ≤ hi ≤ up under a constant cap, so there is no self-freeze. Values ≥ 2^112 revert and are unreachable at these prices. Packing, saturation and credit are sound.
Books, other paths. lpAdd / lpRemove rounding matches PoolManager (up on add, down on remove) including tick-boundary cases; the uint128 cast at SABook.sol:139 cannot underflow (m ≤ snap on every path); deposits and donations are profit-neutral; the capped high-water-mark formula is correct.
Onboarding. CREATE2 identity (the PROXY_CREATION constant is byte-identical to the fixture), the 7702 designator parse, the no-op registration path, replacement and resume rules, and the single-use permit slot (same key in both branches).
multicall. Self-delegatecall keeps msg.sender = keeper; owner and guardian functions stay unreachable; each item takes and releases the guard; the assembly is memory-safe.
Reentrancy from client code. From inside a redemption, account code can reach only revoke(a) for itself.
VaultTimelock against OpenZeppelin 5.4.0: delay floor and cap, per-operation cap, expiry, mixed-batch rule, and the rule that the guardian cannot cancel self-operations all hold.
7. Reconciliation summary
Phase 1 raw: 37 findings from 8 agents → 25 after dedup. Phase 2: 12 findings and 15 leads from 12 agents → 2 findings and 8 leads after dedup and gate. Unified: 27. Overlap: H-1 (both phases), L-1 and L-5 (phase-1 findings matching phase-2 leads), M-4 (phase-1 finding, phase-2 lead). Phase-2-only: M-2. Phase-1-only: M-1, M-3 and the remaining Lows. Coverage holes closed: 0 · Invariants: 33 answered (23 hold, 10 violated or not enforced — 4 of those by documented design, 0 unverified).
Coverage: 35 entrypoints, 35 addressed. 15 threat rows, 15 answered. 33 inferred invariants, 33 answered. Holes closed this pass: 0.
One disagreement between agents was resolved by re-derivation: whether a transferred-and-burned NFT is profit-neutral (L-1). It is not, for fees accrued after the transfer.
Threat catalog answers
#
Threat
Answer
T1
Stolen keeper: swaps and adds against a pool it also trades
M-1
T2
Stolen keeper: anchor away from the market
M-1, L-14
T3
Stolen keeper: margin beyond the cap, treasury redirected
Alone: bounded, L-3. With the guardian: M-3, L-4
T4
Stolen keeper: fee on principal
L-2; H-1 needs the client's own action
T5
Stolen keeper: multicall
Holds
T6
Hostile client account code
Holds — only self-harm or client-favourable mis-booking found
T7
Honest client acting directly on tracked positions
H-1, L-1
T8
Third party: register, onboard, deposit, sync
M-2, L-9, I-3; otherwise holds
T9
Third party moving pool spot
Liveness only — M-4
T10
Guardian alone
Moves no funds; I-2; can hold the module paused
T11
Keeper + guardian
M-3, L-4
T12
Owner (timelock)
Bounded parameters; L-8, L-10
T13
Direct use of SwapExecutor
Holds
T14
DM owner / USDC issuer
I-7; documented blacklist residual
T15
Deploy script
I-1, L-12
Invariant verification
ID
Property
On-chain (pre-scan)
Verdict
I-1
Params within hard caps
Yes
holds
I-2
Roles pairwise distinct
Yes
holds
I-3
Keeper-only anchor range ≤ 1 + refDriftBps over 24 h
Yes
holds — but usable in one step (M-1); breaks after a lowered cap (L-8)
I-4
Anchor never more than refDriftBps from a 24 h value
No
violated by design through a guardian range → I-2
I-5
Margin send conserves value
Yes
holds
I-6
Margin return conserves value
No
by design: a treasury return above equity is profit (acknowledged)
I-7
Deposit books equal amounts on both sides
Yes
holds
I-8
live − snapshot = client flow; a flow cannot change profit
No
violated → H-1, L-1
I-9
At most 4 tracked positions
Yes
holds
I-10
Turnover per 24 h ≤ swapTurnoverBps × value
Yes
holds; the value base is inflatable with a guardian approval → M-3
I-11
Exit window charged only by base sells with no tracked position
Yes
holds
I-12
Hedge equity ≤ hedgeCapBps of value
No
violated → L-3, L-4, M-3
I-13
Keeper alone only lowers equity, within the step
Yes
holds
I-14
Hedge approval is one-shot
Yes
holds
I-15
Price range is one-shot
Yes
holds
I-16
A permit slot is used once
Yes
holds (L-9 is a different path)
I-17
Definition of a trusted anchor
Yes
holds as coded; a confirming report is not required → L-14
I-18
Fees at least feeInterval apart
Yes
holds
I-19
Fee ≤ feeBps × (profit − hwm), ≤ 20% idle USDC
Yes
holds given a correct profit
I-20
snapPos.liq is the liquidity the books account for
No
no underflow; stale after an untrusted sync → H-1
I-21
Packed bucket fields stay in range
Yes
holds
I-22
Timelock delay in [24 h, 30 d]
Yes
holds
I-23
Operations expire 7 d after ready
Yes
holds
I-24
SwapExecutor keeps no state or custody
Yes
holds
X-1
Module books exactly the executor's record of its own call
Yes
holds
X-2
Module and enforcer fee clocks agree
No
independent; fails closed (liveness only)
X-3
Module margin cap and enforcer limit agree
No
different bases (acknowledged L-16); see L-3
X-4
A flow is booked only at a non-zero, trusted price
Yes
holds; also for an unregistered address → M-2
X-5
The owner can always unpause and rotate
No
the guardian can veto for 2 × delay (documented); L-10, L-11
X-6
Enforcer and executor are wired to the module's venue
Yes
holds
E-1
Stolen-keeper extraction ≤ (band + slippage) × (turnover + exit)
No
violated → M-1
E-2
A fee is charged only on earned value
No
violated → H-1, M-2, L-1, L-2
E-3
Tokens leave only to the pool, treasury, fee recipient
Yes
holds
Access-control inventory (summary)
Caller
Functions
Pausable
Notes
Anyone
register (first), onboard, deposit, sync, SwapExecutor.swap
no
sync lacks a registration check (M-2)
Client (account / pinned owner)
revoke, replace or resume a registration
no
cannot be blocked
Keeper
reportPrice, mintPosition, increasePosition, swap, sendHedgeMargin, chargeFee (pausable); decreasePosition, burnPosition, reportHedgeEquity, multicall (not pausable)
partly
every bound in the design is a bound on this key
Keeper or treasury
returnHedgeMargin
no
keeper ≤ hedgeEquity; see M-3
Guardian
approvePrice, approveHedgeEquity, setPaused(true), timelock cancel (non-self operations)
–
no size limit on either approval
Owner (VaultTimelock, ≥ 24 h)
setKeeper, setGuardian, setParams, setPaused(false), transferOwnership
–
bounded; cannot move client funds
DelegationManager
ElysiumCustodyEnforcer.beforeHook
–
default deny
PoolManager
SwapExecutor.unlockCallback
–
only inside the executor's own swap
This review was performed by an AI audit pipeline. It cannot prove the absence of vulnerabilities, and no code was executed. Run the regression test described under H-1, re-test after the fixes, and keep on-chain monitoring (the guardian bot) live for the pilot.
    Canonical copy: this is a styled rendering of the immutable report delivered on IPFS —
       https://bafkreihzjqmehfw6jviaiapcwsyvz6ufr7txarcjmnqpr7vvi5xxrgx4jq.ipfs.community.bgipfs.com/.
       If the two ever differ, the IPFS copy is authoritative.
    Audited by LeftClaw Services 🦞 — job
       #1241 on Base. Rendered 2026-11-18.
