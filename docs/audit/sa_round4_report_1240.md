<!-- Plain-text rendering of LeftClaw job #1240 (HTML original; the IPFS copy is authoritative). -->

Elysium LP smart accounts, round 4 (final pre-pilot review) — LeftClaw Services
      🦞
      LeftClaw Services
      ·
      Smart Contract Audit
    Elysium LP smart accounts, round 4 (final pre-pilot review)
    Job #1240 · completed on-chain · report pinned to IPFS
      Job page #1240
      Canonical report IPFS
      Generated 2026-11-18
      1
High
      3
Medium
      13
Low
      9
Info
    Contents
      1. Answer to the question you asked
      2. Task 1 — status of the round-3 Mediums
      3. Findings
      4. R4 exit window — the three checks you asked for
      5. Task 3 — accepted residuals of sa_round3_response.md
      6. Leads (not confirmed; confidence below the floor or unverifiable here)
      7. Access-Control Inventory
      8. Threat Model
      9. Invariant Verification
      10. Notes and limits
Security Review — Elysium LP smart accounts, round 4 (final pre-pilot review)
Job: 1240 · Date: 2026-11-18
Repo: https://github.com/Aleha1975/dispatch-cash · branch elysium-lp-sa · commit 04420ec34171ad3280bd86cbd967bf18c41d6d6a (verified reachable on the remote as refs/heads/elysium-lp-sa)
Scope (11 files, 2,275 nSLOC): src/sa/LPManagerModule.sol · src/sa/SABook.sol · src/sa/SALib.sol · src/sa/SARange.sol · src/sa/SAWindow.sol · src/sa/SwapExecutor.sol · src/sa/ElysiumCustodyEnforcer.sol · src/sa/vendor/DelegationFramework.sol · src/V4PositionMath.sol · src/VaultTimelock.sol · script/DeploySA.s.sol. The pooled vault is out of scope. Not deployed; target chain Elysium mainnet (99901).
Severity counts: 0 Critical · 1 High · 3 Medium · 13 Low · 9 Informational
Reconciliation summary: Overlap: 10 · Phase-1-only: 16 · Phase-2-only: 0 · Re-examined leads kept: 16, demoted: 0 · Coverage holes closed: 1 · Invariants: 34 answered (24 hold, 10 violated, 0 unverified). Reporting floor: every finding of Low severity and above with confidence ≥ 50; lower-confidence items are under Leads.
1. Answer to the question you asked
Is there a principal-loss path for a pilot of about USD 250 at the script parameters with swapTurnoverBps 5000 and exitTurnoverBps 10000?
No path was found that sends client funds to an address outside the stated set (the client, the fixed pool, hedgeTreasury, feeRecipient). The enforcer, the recipient-verified transfers and the calldata-bound swap record hold.
No path was found that stops a client from stopping the module or exiting. revoke has no modifier and no external call; removals and margin returns work while the module is paused; client-direct actions need neither the module nor the DelegationManager.
One path charges a fee on principal far beyond the stated bound (H-1). It needs no attacker: a client that empties a tracked position and adds liquidity back to the same NFT makes the books record an astronomically large "yield". Every later chargeFee by an honest keeper then takes the 20 % idle-USDC cap, every feeInterval, with no end. The money goes to feeRecipient. This comes from the round-3 fee-checkpoint fix. For the pilot (the operator's own funds and its own fee recipient) the money stays with the operator; it must be fixed before any third-party client.
The stated stolen-keeper bound does not hold against the market (M-1). The bound of (band + slippage) × (turnover + exit) = 4.5 % per day is measured against the anchor, and one keeper report may move the anchor by the whole refDriftBps (10 %) with the pool pushed for a single transaction. The loss per unit of notional is about 13 %, not 3 %: up to roughly 13–19 % of account value on the first day. At USD 250 the pool-fee cost of the pushes (about USD 28 per round trip at the stated depth) is of the same order as the gain, so the attack does not pay at pilot size. It scales with account count and size.
The deploy script still sets swapTurnoverBps 20000 (L-12). The on-chain value is the script's until a timelocked setParams (≥ 24 h) lowers it.
Recommendation before the pilot: fix H-1 (a small change in SABook._feesOut), add the registration check to sync (M-3), put the pilot parameters in the script, and either lower refDriftBps to about the band for the pilot or add the per-report step limit of M-1. Until H-1 is fixed, do not modify tracked position NFTs directly from the client account.
How this review was run. x-ray pre-scan → context phase (3 agents: protocol map, access-control inventory, threat catalog) → breadth phase (8 checklist agents over 13 domains) → depth phase (12 attack agents, blind to the breadth findings, all 12 returned) → reconciliation with a coverage gate. No target code was built or run (audit policy: no execution of untrusted code), so the 228 tests were not executed and every trace below is a hand trace against the source and against the pinned Uniswap v4 sources under lib/. Test sketches are marked "not executed". The round-3 reports were used for Task 1 only; every finding below comes from this job's own phases.
2. Task 1 — status of the round-3 Mediums
Round-3 finding
Status
Basis
1226 M-1 / 1227 M-1 — client-collected LP fees booked as a contribution
Fixed for the reported case, regressed in the other direction
A client collect on an unchanged position is now booked as yield (_feesOut, book re-marks after module modifies). The checkpoint can now count yield the account never received: unbounded after a tick re-initialisation (H-1), bounded otherwise (L-1, L-2).
1227 M-2 — swap record not bound to the module's swap
Fixed
Count + keccak256(msg.data) + got ≥ minOut (LPManagerModule.sol:499). Identical calldata from account code is the same swap for the same account; the refund re-entry is blocked by the executor guard; the record is per payer and safe across multicall items. No way found to keep the hash and change the economics.
1227 M-3 / 1226 M-3 — fee on a gain sized by the drift window
Partly fixed
feeGate holds against the anchor's own history (no path found to pass sooner than 24 h after a higher value). Not covered: a flow booked at a walked anchor and charged later at an honest anchor (M-2), an anchor that was simply not reported while the market fell (M-2, variant), and a guardian range that clears the trailing low (L-4).
1227 M-4 / 1226 M-4 — booking at an anchor a full band from the pool
Partly fixed
The 50 bps book band is one pool read at the instant of the call. A keeper that pushes the pool for one transaction books at an anchor up to refDriftBps from the market (M-2).
1227 M-5 / 1226 M-2 (swap part) — keeper chooses the booking moment
Partly fixed
Swaps, mints and increases need _trusted() and anyone may sync(a). Residuals: trust exists only after keeper reports, so a keeper still decides when booking is possible (M-2); sync accepts unregistered addresses (M-3); one report is enough to move and use at exactly lastPriceMoved + minPriceStable (M-1).
1227 M-6 / 1226 L-1 — parked deposit sets the fee to zero
Fixed
Profit is value(anchor) − contributed right after a sync at the same anchor (LPManagerModule.sol:581-593).
1227 M-7 / 1226 L-2 / 1226 M-2 (budget part) — path-length drift budget
Fixed, with two notes
No sequence found in which a keeper alone moves the anchor more than refDriftBps from a value held in the trailing 24 h (bucket boundaries, the 24–27 h tail, values ≥ 2^112, cap 0 while paused all checked). Notes: one report may still use the whole budget (M-1); a lowered refDriftBps can move the anchor to an unreported value (L-8).
Answers to the four numbered questions:
SABook fee step. (feeGrowthInsideLast_now − mark) × n is exact for an unchanged position and for module modifies. It is not exact after a client modify between two trusted syncs. Position emptied and refilled with a boundary tick cleared: the difference wraps (H-1). Liquidity reduced and changed again, or NFT transferred out and emptied elsewhere: over-count bounded by fee growth × snapshot liquidity (L-1, L-2). Zero-liquidity positions handled by the module, positions at tick boundaries, subscribed positions and a client collect to another recipient are exact or under-count only.
SwapExecutor hash binding. No way found to produce the module's hash with different economics.
SARange / movePrice. A stolen keeper cannot exceed refDriftBps from a value held in the last 24 h. It can use all of it in one report (M-1). The guardian reset is unbounded by design (L-4, L-5).
Trusted gate and feeGate. Yes: every pool term is read at a single instant, so the anchor used for booking, swaps, adds and (indirectly) fees can be refDriftBps away from the market while the gates pass (M-1, M-2). The booking price always equals the price value() uses in the same call.
3. Findings
H-1. Emptying and refilling a tracked position makes _feesOut book a wrapped fee amount; chargeFee then takes 20 % of idle USDC every interval
Severity: High · Confidence: 90 · Origin: [both] — phase 1: general, precision-math, defi-amm, erc721, assembly (5 agents); phase 2: agents 1, 2, 6, 7, 10, 12 (and 5, 8, 9, 11 on the same root cause)
Location: SABook._feesOut (src/sa/SABook.sol:105-120), called from SABook.sync (SABook.sol:71-72, :80); consumed at SABook.sol:91-95, LPManagerModule.chargeFee (LPManagerModule.sol:593-595), SALib.hwmFee (SALib.sol:335-337)
Description. The books keep a mark of PoolManager's feeGrowthInsideLast per tracked position and treat the modular difference to the current value as fees paid out:
if (pmLiq == 0) n = old; // burned or emptied by the client: its last modify paid the fees on `old`
uint256 c0;
uint256 c1;
unchecked {
    c0 = FullMath.mulDiv(l0 - q.g0, n, 1 << 128);
    c1 = FullMath.mulDiv(l1 - q.g1, n, 1 << 128);
}
...
s.snapAsset += int256(ca);
s.snapBase += int256(cb);
The subtraction is valid only while both values are on the same fee-growth basis. Uniswap v4 changes the basis when a boundary tick is cleared and set up again:
Pool.modifyLiquidity computes the inside growth, calls Position.update, and only then deletes every tick whose gross liquidity fell to 0 (lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol:196-203, clearTick at :592-594).
On the next add, updateTick re-initialises the tick with feeGrowthOutside = feeGrowthGlobal if tick <= current tick, else 0 (Pool.sol:533-538). getFeeGrowthInside (Pool.sol:488-511, unchecked) then returns 0 on the new basis whether the price is below, inside or above the range.
Position.update owes nothing (liquidity before the change is 0) and overwrites feeGrowthInsideLast with the new-basis value (Position.sol:76-102).
The multiplier n = min(live, snapshot) is non-zero because the snapshot liquidity is refreshed only by a priced sync: if (price == 0) continue; (SABook.sol:72) comes before q.liq = liq (SABook.sol:80). An unpriced sync between the two client steps moves the mark but leaves q.liq at the old value.
Trace (not executed). HYPE = currency0. Tracked position T, liquidity L = 1e15, on ticks no other LP uses (the expected case for keeper-chosen ranges in the thin pilot pool). The mark is above 0: either an earlier module modify (collect, increase) after fees accrued, or an unpriced sync between steps 1 and 2 below.
The client decreases T to 0 directly through PositionManager and keeps the NFT. PoolManager stores last = F (old basis) and deletes both ticks.
With no priced sync in between (same batch; or the anchor is not trusted, which is the case for minPriceStable after every anchor move, whenever the pool is more than 50 bps from the anchor, and while the module is paused), the client adds liquidity L' ≥ L to T. The ticks are re-initialised; PoolManager stores last ≈ 0.
Any sync (keeper action, or anyone through sync(a)): pmLiq != 0, n = L. l0 − q.g0 = 2^256 − F, so c0 ≈ 1e15 × 2^128 ≈ 3.4e53. mulDiv does not revert (the result is below 2^256) and the int256 cast stays positive (n < 2^127 for tick spacing 60). snapBase and snapAsset each rise by about 3.4e53.
First priced sync: f = x − snapAsset + _mul(b − snapBase, price) is about −3.4e53, so contributed ≈ −3.4e53. Nothing ever resets contributed; re-registration does not.
chargeFee: profit = value − contributed ≈ +3.4e53. hwmFee returns fee = maxFee = 20 % of idle USDC, and the capped branch moves the mark by only fee × BPS / feeBps − fee, so profit stays above the mark for ever. With 100 USDC idle: 20, 16, 12.8, … every feeInterval; 59 % of idle USDC after four intervals. The enforcer allows exactly this (20 %, once per 7 days).
If only the upper tick is re-initialised the difference is a finite positive phantom amount instead of a wrap. If the mark and the new value are both 0 (a position never modified since a mint on fresh ticks, both steps in one batch) nothing is credited.
A keeper cannot cause this on its own: book re-marks after every module modify, and a keeper increase is preceded by a priced sync. A third party can lengthen the window by holding the pool more than 50 bps off the anchor (accepted residual 8).
Why it is in scope. The client's own action triggers it, but it is an ordinary action (withdraw all liquidity without burning, add back later), not hostile account code, and the result is a fee on principal by the honest keeper's routine job. Accepted residual 2 states the bound as "that liquidity's own fee income"; this case has no bound other than 20 % of idle USDC per interval, repeating.
Fix (recommended — bounds every _feesOut over-count, fails toward a lower operator fee). Inside growth can never exceed global growth over the same interval on one basis. Store the pool's global growth next to the mark and credit nothing when the difference is larger; and credit only a position nobody changed since the mark:
struct Pos { uint128 liq; uint256 g0; uint256 g1; uint256 G0; uint256 G1; }
// _feesOut
(uint128 pmLiq, uint256 l0, uint256 l1) = v.pm.getPositionInfo(...);
(uint256 G0, uint256 G1) = v.pm.getFeeGrowthGlobals(v.id);
uint256 d0; uint256 d1;
unchecked {
    d0 = l0 - q.g0; d1 = l1 - q.g1;
    // larger than the pool's own growth (or wrapped): PoolManager re-based the position. Count nothing.
    if (d0 > G0 - q.G0 || d1 > G1 - q.G1) { d0 = 0; d1 = 0; }
}
if (pmLiq != old || n != old) n = 0;   // a client modify since the mark: its fees stay a client flow
c0 = FullMath.mulDiv(d0, n, 1 << 128); c1 = FullMath.mulDiv(d1, n, 1 << 128);
q.g0 = l0; q.g1 = l1; q.G0 = G0; q.G1 = G1;   // also set G0 / G1 in book()
With both changes the residual over-count (liquidity removed and restored to exactly the snapshot value with no basis change) is at most global fee growth × snapshot liquidity over the gap, which is the bound residual 2 states.
Fix alternatives raised by the depth phase (kept verbatim in intent):
Option A — count nothing when the mark moved backwards: if (l0 < q.g0 || l1 < q.g1) n = 0; after the pmLiq == 0 line. Smallest change; does not cover the finite upper-tick case or L-1.
Option B — credit only an unchanged position: replace the pmLiq == 0 line with if (pmLiq != old || n != old) n = 0;. Covers L-1 and L-2; alone it does not see a decrease and re-add back to exactly the snapshot liquidity in one batch.
Option C — cap the credit by the idle surplus: ca = min(ca, max(0, balanceOf(a) − snapAsset)), same for base. Removes the wrap; a client deposit that coincides with a re-based position would then be counted as yield, so it is weaker than the global-growth cap.
Regression test to add (sketch, not executed): mint on fresh ticks → swaps in range → keeper decreasePosition(a, id, 0, 0, 0) (collect) → as the account: DECREASE_LIQUIDITY(id, all) + TAKE_PAIR, then INCREASE_LIQUIDITY(id, all) + settle → module.sync(a) → assert account(a).contributed is unchanged → warp feeInterval → assert chargeFee(a) == 0. Repeat with an unpriced sync (for example reportHedgeEquity) between the two account steps.
M-1. The stolen-keeper loss bound is measured against the anchor, and one report moves the anchor by the whole drift budget
Severity: Medium · Confidence: 80 · Origin: [both] — phase 1: oracles/flashloans (ORA-1), defi-amm (AMM-4), precision-math (MATH-3); phase 2: agent 3 (lead)
Location: LPManagerModule.reportPrice (LPManagerModule.sol:392-404), _checkPoolBand (:837-841), _trusted (:856-863), swap (:485-492), _add (:792-796); SALib.movePrice (SALib.sol:353-359)
Description. Every link between the anchor and the market is one read of the pool spot at the instant of a call:
return _freshOk() && block.timestamp >= lastPriceMoved + st && block.timestamp <= lastPriceTime + st
    && d * BPS <= pool * BOOK_BAND_BPS;
Nothing requires the pool to be near the anchor between those instants. The keeper can push the pool, call, and unwind (an EIP-7702 batch keeps msg.sender == keeper; consecutive transactions on a FIFO sequencer are nearly the same). The cost is the 0.3 % pool fee each way, with no inventory risk. movePrice then allows the full refDriftBps in one report:
uint256 up = Math.mulDiv(lo, WAD + capWad, WAD);
uint256 dn = Math.mulDiv(hi, WAD, WAD + capWad, Math.Rounding.Ceil);
swap and _add are bounded only relative to the anchor (limit at ref × (1 ∓ band), floor fair × (1 − maxSlippage)). The loss per unit of charged notional is therefore the anchor's distance from the market plus about 3 %. At exactly lastPriceMoved + minPriceStable the report that moved the anchor also satisfies the re-confirmation term, so one report is enough.
Trace (not executed; pilot parameters). Market = pool = anchor = 30. Account: 125 USDC + 4.1667 HYPE, positions burned (burns need no price).
T: one keeper transaction: sell HYPE into the pool to 27.27 → reportPrice(27.273e6) (inside the pool band; dn = ceil(30 / 1.1) = 27.2727, not clipped) → buy the HYPE back.
T + 300 s: one keeper transaction: push the pool to 27.27 again → swap(a, true, 4.1667e18, 26.864e6, 0). _trusted() holds. The sale goes to the exit window (notional 111.9 ≤ 1.0 × value). Floor = 111.93 × 0.985 = 110.25 USDC. The account sells HYPE worth 125 USDC for as little as 110.25 USDC: 11.8 % of the amount sold, against the stated 3 %. The keeper's unwind buys that HYPE back.
Same day: report 30 again (allowed: up = 27.273 × 1.1), wait 300 s, buy base on the turnover window at up to 3 % above the anchor.
Day-one loss on this path is about 7 % of value; with the turnover buy first (account all base before the exit sale) about 13 %; at the limits of both windows up to about 13 % × 1.5 ≈ 19 %. The stated figure is 4.5 %. The range expires 24–27 h after a value is replaced, so the walk repeats daily. A keeper that simply stops reporting while the market moves gets the same distance with no drift budget used.
Related corrections to the stated safety argument for the exit window: (i) sells are charged at keeperPrice, which may be one band below the anchor, so a 1× exit cap admits about 1.015× of anchor-valued base; (ii) "selling again needs base, which can only be re-bought on the turnover window" understates the turnover window: a USDC-only mint just below the pool is charged at slip / (slip + band) = 50 % of principal, the keeper fills it with its own sale, and the burn is free, so base is re-acquired at 2× per turnover unit. The exit cap itself stays absolute.
Mitigating facts. The 300 s between the walk and the use (the guardian can pause); push cost about USD 28 per round trip at the stated depth, which is of the order of the gain on one USD 250 account. multicall shares one push across all accounts.
Fix (smallest). Limit one keeper report to one band and one step per stable window, so a 10 % walk needs about seven confirmed reports over about 35 minutes in public view:
// reportPrice, keeper-only path (no guardian range)
uint256 step = Math.mulDiv(old, params.poolBandBps, BPS);
if (p > old + step) p = old + step; else if (p + step < old) p = old - step;
if (p != old && block.timestamp < lastPriceMoved + params.minPriceStable) p = old;
Also require a second report after a move (lastPriceTime > lastPriceMoved) in _trusted. For the pilot, setting refDriftBps near poolBandBps (300–500) and relying on approvePrice for larger moves gives the same effect with no code change. State the bound as (refDrift + band + slippage) × (turnover + exit).
M-2. A client flow can be booked at a price far from the market, and the fee is charged on the difference later
Severity: Medium · Confidence: 70 · Origin: [both] — phase 1: oracles (ORA-2), flashloans (FL-1); phase 2: agent 1 (SABook.sync, pending-flow-booked-at-later-price)
Location: SABook.sync (SABook.sol:73-78, :91-95); LPManagerModule._sync (LPManagerModule.sol:767-769), sync (:867-870), chargeFee (:580-602); SALib.feeGate (SALib.sol:375-378)
Description. A price-sensitive flow (idle base, position liquidity) is booked at lastPrice whenever _trusted():
f += x - s.snapAsset + _mul(b - s.snapBase, price);
Accepted residual 4 bounds the phantom gain at 50 bps × flow because the pool must be within BOOK_BAND_BPS of the anchor. With M-1 the anchor at the booking can be refDriftBps from the market while the pool is pushed to it for that one transaction. feeGate does not see this: it checks the anchor at fee time against the pool and the trailing low. After an up-walk and a return the trailing low is the honest value and the gate passes at once. Only keeper reports create trust, so nobody else can book the flow earlier at the honest anchor.
Trace A (stolen keeper, not executed). Market = anchor = 30. The client has withdrawn 4 HYPE directly; the flow is pending.
T: push the pool to 33, reportPrice(33e6), unwind.
T + 300 s, one transaction: push to 33; sync(a) books contributed −= 132 (honest: 120); unwind; reportPrice(30e6).
T + 600 s: _trusted() holds at 30; feeGate passes (lo = 30). Profit is 12 USDC too high; chargeFee sends 15 % × 12 = 1.80 USDC of principal to feeRecipient: 1.5 % of the flow against the stated 0.075 %. At the parameter caps it is 4 %.
Trace B (no attacker, not executed). The account holds 100 HYPE + 1,000 USDC, booked at 40. The client sends its 100 HYPE out on day 1. No priced sync follows (the keeper is idle, or the anchor is not trusted). On day 7 the anchor is 48. chargeFee → _sync books the outflow at 48: contributed falls by 4,800 instead of 4,000, profit is 800 too high, fee 120 USDC on principal. A client that calls sync(a) itself at the time of the flow avoids this only while the anchor is trusted.
Trace C (stale anchor). No report after the anchor followed the market to 33 and the market returned to 30. Push the pool to 33, reportPrice(33e6) (a move after the gap), and 300 s later, with the pool pushed again, chargeFee: the range holds only 33, the gate passes, and the fee is charged on a gain that no longer exists. Residual 5's "pushes the pool 1.5 % and holds it" is therefore not the cost: the cost is two pool fees, and the 1.5 % is measured against the anchor's low, not the market.
Impact. The beneficiary is feeRecipient, not the thief. The finding is a fee on principal beyond the stated bounds (residuals 3, 4, 5), capped by 20 % of idle USDC per feeInterval.
Fix. The step limit of M-1 makes the anchor at a booking at most one band from a value confirmed 300 s earlier and closes Trace A and C. For Trace B, record the last price-sensitive booking per account and delay the fee:
// SABook.sync, when a price-dependent term is non-zero
s.lastPricedFlow = block.timestamp;
// chargeFee
if (block.timestamp < s.lastPricedFlow + 1 days) revert FeeTooEarly(s.lastPricedFlow + 1 days);
and have the keeper (and the client UI) call sync(a) right after every direct client flow.
M-3. sync(a) has no registration check: anyone can open the books of a future client early, and appreciation before registration is charged as profit
Severity: Medium · Confidence: 85 · Origin: [phase1: access-control, general, erc4337, dos] (4 agents); re-examined and kept
Location: LPManagerModule.sync (LPManagerModule.sol:867-870); SABook.sync (SABook.sol:88-97); SALib.register (SALib.sol:252-261)
Description.
function sync(address a) external nonReentrant {
    if (!_trusted()) revert StalePrice();
    _sync(a);
}
deposit, returnHedgeMargin, reportHedgeEquity and approveHedgeEquity all require delegationHash != 0; sync does not. For an address that never registered, SABook.sync books its whole balance as a contribution at today's anchor and writes the snapshot. A first registration resets nothing; it only writes identity fields and if (old == 0) s.lastFeeTime = block.timestamp; (SALib.sol:261). The statement in the module header that registration "books nothing: what the account holds is booked by the first keeper sync at a trusted anchor" then does not hold: base held at the early sync stays in contributed at the old price.
Trace (not executed).
An EOA (a future 7702 client) holds 10 HYPE. The anchor is trusted at 20. Anyone calls module.sync(eoa): snapBase = 10e18, contributed = 200e6.
Weeks later HYPE is 30. The EOA sets the 7702 designator, adds 100 USDC and registers.
The first priced sync books only the 100 USDC: contributed = 300e6, value = 400e6.
After feeInterval, chargeFee computes profit 100e6 and sends 15 USDC of principal to feeRecipient, although the module earned nothing.
The caller gains nothing; the fee goes to feeRecipient. Hybrid accounts are normally empty before onboarding, so the exposure is mainly 7702 clients and pre-funded counterfactual addresses. This differs from accepted I-7 (profit while revoked): this client had signed nothing when the books were opened.
Fix.
function sync(address a) external nonReentrant {
    if (accounts[a].delegationHash == 0) revert NotRegistered();
    if (!_trusted()) revert StalePrice();
    _sync(a);
}
// SALib.register, first registration (defence in depth)
if (old == 0) { s.lastFeeTime = block.timestamp; s.snapAsset = 0; s.snapBase = 0; s.contributed = 0; s.hwm = 0; }
L-1. _feesOut counts fees on liquidity the position did not hold
Severity: Low · Confidence: 75 · Origin: [both] — phase 1: precision-math (MATH-2), defi-amm (AMM-2), erc721 (NFT-2); phase 2: agents 5, 6, 7, 8, 9, 11
Location: SABook.sync (SABook.sol:71), SABook._feesOut (SABook.sol:107)
Description. n = min(live, snapshot), or the full snapshot when pmLiq == 0, is the liquidity at the time of the sync, not the liquidity that earned the fees. PoolManager pays fees at each modify on the liquidity held just before it. The NatSpec claim "a client change in between can only make this smaller" (SABook.sol:50-52) is false in three sequences with no priced sync in between: (a) L → L1 → L (decrease, then re-add); (b) L → L1 → 0 (two-step removal; the comment "its last modify paid the fees on old" is wrong, it paid on L1); (c) emptied on shared ticks and refilled (growth of the empty period is counted).
Trace (not executed). q.liq = 100e12. Client decreases 100 → 40 at growth G1, increases 40 → 100 at G2 where the growth G1 → G2 pays 10 USDC on 60e12. PoolManager paid 6.67 USDC; the books credit 16.67. contributed falls by 10 USDC; fee 1.5 USDC on principal.
Impact. Bounded by fee growth in the range × snapshot liquidity over the gap between two priced syncs. The gap has no limit while the anchor is not trusted. This is the opposite direction of accepted residuals 1 and 2.
Fix. Covered by the H-1 fix (if (pmLiq != old || n != old) n = 0;). Alternative from the depth phase: delete if (pmLiq == 0) n = old; (covers case (b) only).
L-2. _feesOut counts fees that a new owner of the NFT received
Severity: Low · Confidence: 75 · Origin: [both] — phase 1: general (GEN-3), precision-math, defi-amm, erc721; phase 2: agents 3, 4 (findings), 1, 6, 7 (leads)
Location: SABook._feesOut (SABook.sol:107); caller SABook.sol:71; NatSpec SABook.sol:100-101
Description. The caller passes n = 0 for a position the account no longer owns and the NatSpec says "transferred out: 0", but if (pmLiq == 0) n = old; overrides it. If the client transfers a tracked NFT and the new holder empties it before the next priced sync, the fees accrued after the transfer (paid to the new holder) are booked as the account's yield. The new holder can enlarge the amount with PoolManager.donate before emptying, at its own cost; the fee goes to feeRecipient.
Fix. Apply n = old only when the account still owns the token or ownerOf reverted (burned); pass that flag from _liquidityOf. The H-1 fix (pmLiq != old → n = 0) also closes it.
L-3. A keeper burn after a direct client decrease books the removed liquidity at the pool spot
Severity: Low · Confidence: 65 · Origin: [both] — phase 1: defi-amm (AMM-3); phase 2: agent 4 (lead)
Location: SABook.lpRemove (SABook.sol:198-204); LPManagerModule._remove (LPManagerModule.sol:804-811)
Description. m = burn || liq > snap ? snap : liq; uses the snapshot liquidity for a burn even when the live liquidity is lower (the sync before a removal may be unpriced, so the snapshot is stale). PositionManager pays only the live part; book adds the principal of the whole snapshot at the current slot0. The client's earlier removal is then booked once, on the idle side, at the pool price of the burn, with no trusted gate. With the pool at the lower edge of a ±10 % range the phantom profit is about 2.9 % of the removed value (fee about 0.43 %).
Fix. Use m = min(snap, live PoolManager liquidity) for burns too and leave the rest of the snapshot liquidity to the priced sync.
L-4. A guardian price range is not bound to the anchor it was judged against, and using it clears the fee gate's trailing low
Severity: Low · Confidence: 75 · Origin: [both] — phase 1: signatures (SIG-3), oracles (ORA-3); phase 2: agents 5, 6, 10, 11 (leads)
Location: LPManagerModule.approvePrice (LPManagerModule.sol:640-646); SALib.movePrice (SALib.sol:361-366); SALib.feeGate (SALib.sol:375-378)
Description. Unlike a hedge approval (epoch, stored value, era), a price range stores only (lo, hi, until). It is consumed only by a report that would be clipped, so a range the honest keeper did not need stays open for up to a day. On use, SARange.reset forgets the history: the keeper gets a fresh ±refDriftBps in the next report (reach of an approval [lo, hi] is [lo / 1.1, hi × 1.1]), and feeGate's trailing low becomes the new anchor, so the "held for a day in public view" protection is gone for that jump. Extends accepted 1227 I-11.
Fix. Add expectedRef to approvePrice and void the range when the anchor leaves it by more than the band; void the range on the first report inside [lo, hi], clipped or not; after a guardian jump block a second move for one stable period and block fees for 24 h (or carry the pre-jump low into the new window). Operationally, set until to minutes.
L-5. Guardian and keeper together remove every on-chain bound; the guardian's brake cannot be overridden quickly
Severity: Low (two keys; guardian is trusted for these calls in the stated model) · Confidence: 80 · Origin: [both] — phase 1: access-control (AC-2); phase 2: agent 2 (lead, sendHedgeMargin), agent 11 (lead)
Location: approvePrice (LPManagerModule.sol:641), approveHedgeEquity (:656-661), setPaused (:670-681); SALib.moveHedge (SALib.sol:401-405); VaultTimelock.cancel (VaultTimelock.sol:148-151)
Description. Stated for completeness of the trust model, because the pilot plan runs the guardian as a bot (a second hot key):
approvePrice(1, 2^112 − 1, …) is valid and can be re-issued; the anchor then follows any pushed pool.
approveHedgeEquity has no cap on value. accountValue includes hedgeEquity, and the turnover and exit caps are value × bps, so an approved equity of 1e30 removes both window caps.
Approving equity 0 writes netMargin down (if (s.netMargin > v) s.netMargin = v;), which resets the hedgeCapBps check for the next sendHedgeMargin; the enforcer's 35 % is a rate per 24 h on idle USDC, not a total.
Only the guardian pauses instantly. The owner's pause goes through the timelock, and the guardian can cancel it, as well as setKeeper and setGuardian (rotation takes 2 × delay by design).
The guardian alone has liveness powers only; removals, margin returns and client exits keep working.
Fix. Bound both approvals on-chain (range within K × refDriftBps of the current anchor; equity not above netMargin plus a bounded gain), exclude approved equity above netMargin from the base of the window caps, and add a pause-only role (or let the timelock proposer pause directly) that the guardian cannot cancel. Keep the guardian key off the keeper's infrastructure.
L-6. exitTurnoverBps = 0 blocks every keeper base sale for an account with no tracked position; an exhausted exit window has no fallback
Severity: Low · Confidence: 85 · Origin: [phase1: general (GEN-4), dos (DOS-2), defi-amm (AMM-5)]; re-examined and kept
Location: LPManagerModule.swap (LPManagerModule.sol:487), _useTurnover (:883-886); comment at :128
Description. The window is chosen before the cap is known: sellBase && _positions[a].length == 0 routes the sale to the exit window, whose cap is exitTurnoverBps × value. With 0 the sale reverts WindowOverflow although the turnover window has room. The repo's own test documents this ("off: no exit sell at all", test/sa/SARiskOff.t.sol:110), but the parameter comment says "(0 = off)", and a timelocked "disable R4" would stop the keeper selling base for every account without a position (after a full burn, or a new 7702 account holding HYPE). The same holds when the exit window is spent. Also: a position the client emptied but still owns, a position the keeper decreased to zero without burning, and a subscribed position (which the module cannot burn) keep sells on the turnover window.
Fix. bool exit = sellBase && params.exitTurnoverBps != 0 && _positions[a].length == 0; and charge the remainder to the turnover window when the exit window lacks room.
L-7. A market move beyond refDriftBps inside the window disables the risk-off sale until the guardian acts
Severity: Low · Confidence: 85 · Origin: [phase1: oracles (ORA-4)]; re-examined and kept
Location: LPManagerModule._freshOk (LPManagerModule.sol:847), _checkKeeperPrice (:876), swap (:482)
Description. With an honest keeper and a fall of more than 10 % inside the trailing window, the anchor is clipped at hi / 1.1; _off(lastPrice, lastReported) is true, _trusted() is false and swap reverts StalePrice, including the exit sale that R4 added for exactly this market. Burns, decreases, returns and the client's direct exit still work. Capacity returns 24–27 h later or by approvePrice.
Fix. Allow the exit-window sale on a clipped anchor when the keeper price is below the anchor (selling at the pool below a lagging anchor can only understate), with minOut bounded at min(anchor, pool); or document that R4 depends on the guardian in a fast market.
L-8. After refDriftBps is lowered, a report can move the anchor to a value nobody reported
Severity: Low · Confidence: 85 · Origin: [phase1: oracles (ORA-5), dos (DOS-3)]; re-examined and kept
Location: SALib.movePrice (SALib.sol:356-359)
Description. if (dn > up) q = ref; else if (q > up) q = up; else if (q < dn) q = dn; assumes ref ∈ [dn, up]. After a cap reduction with a trailing range between 1 + cap and (1 + cap)², dn ≤ up holds but ref can lie outside. Example: range [100, 103.5], ref = 100, cap lowered to 2 %: up = 102, dn = 101.47; reportPrice(100) sets the anchor to 101.47. No fund impact; booking, swaps, adds and fees stop until the pool is within 50 bps of the anchor.
Fix. if (dn > up || ref > up || ref < dn) q = ref;, or re-seed the range in setParams when refDriftBps decreases.
L-9. A front-run permit can be pulled later against a standing allowance of the same amount
Severity: Low · Confidence: 75 · Origin: [phase1: signatures (SIG-1)]; re-examined and kept
Location: SALib.pull (SALib.sol:292-313); LPManagerModule.deposit (LPManagerModule.sol:366)
Description. The fallback accepts a consumed permit when it is the owner's last nonce, unexpired, and allowance == amount. The once-only slot is written only by pull; deposit spends the same module allowance without marking it. Sequence: the owner signs permit P (100 USDC, nonce k); anyone submits it directly; the owner calls deposit(a, 100e6); before the deadline the owner approves the module for 100 USDC again; anyone calls onboard(storedDelegation, 100e6, D, sigP) and the 100 USDC move to the owner's own account. No third party gains; the NatSpec claim "a standing allowance is never used" does not hold in this case.
Fix. Mark (msg.sender, nonces(msg.sender) − 1) as used whenever deposit spends a module allowance, or correct the NatSpec and the client documentation.
L-10. A second outstanding permit lets anyone block an onboarding
Severity: Low · Confidence: 75 · Origin: [phase1: signatures (SIG-2)]; re-examined and kept
Location: SALib.pull (SALib.sol:290-305)
Description. The fallback checks only nonce − 1. If the owner has another signed USDC permit outstanding, an attacker submits both; the module's digest is then computed with the wrong nonce and onboard reverts BadPermit for that signature for good. No funds move; the owner recovers with deposit or a new permit.
Fix. Let the caller pass the permit's nonce and accept any k < nonces(o) whose signature recovers to the owner, keeping the allowance, deadline and once-only checks.
L-11. renounceRole(EXECUTOR_ROLE) freezes ownership like the proposer renounce that round 3 blocked
Severity: Low · Confidence: 85 · Origin: [phase1: governance (GOV-1)]; re-examined and kept
Location: VaultTimelock.renounceRole (VaultTimelock.sol:138-141)
Description. if (role == PROPOSER_ROLE) revert NoRenounce(); — the operator is also the only executor and the timelock is its own admin. If the operator renounces EXECUTOR_ROLE, nothing can be executed again, including the grantRole that would repair it: the module can never be unpaused and keeper, guardian and params can never change. Client exits and margin returns still work.
Fix. if (role == PROPOSER_ROLE || role == EXECUTOR_ROLE) revert NoRenounce();
L-12. The deploy script sets swapTurnoverBps = 20000, not the stated pilot value, and does not read the parameters back
Severity: Low · Confidence: 90 · Origin: [both] — phase 1: general, precision-math, access-control, chain-specific, defi-amm; phase 2: agents 6, 9 (leads)
Location: DeploySA.run (script/DeploySA.s.sol:175, :179; read-back :200-210)
Description. swapTurnoverBps: 20000 and exitTurnoverBps: 10000 give (1.5 % + 1.5 %) × (2.0 + 1.0) = 9 % per 24 h against the anchor, before M-1. The pilot value 5000 exists only in the docs and in test/sa/SARiskOff.t.sol; docs/ARCHITECTURE.md records the default as a go-live step. setParams is owner-only, so the correction needs schedule plus ≥ 24 h (48 h default) while accounts can register as soon as the first reportPrice is made. The read-back checks roles and four wiring addresses; not params, hedgeTreasury, feeRecipient, asset, permit2, delegationManager, timestampEnforcer, nor that the operator holds CANCELLER.
Fix. Put the pilot values in the script (or read them from env with those defaults) and require the full params() tuple and the immutable recipients after the broadcast. Do not onboard before the on-chain params equal the stated ones.
L-13. The "OWNER must be a multisig" check passes for a 7702-delegated EOA
Severity: Low · Confidence: 85 · Origin: [phase1: access-control (AC-4), chain-specific (CHAIN-1)]; re-examined and kept
Location: script/DeploySA.s.sol:111
Description. require(owner.code.length != 0 || vm.envOr("ALLOW_EOA_OWNER", false), "OWNER must be a multisig"); — on this chain an EOA with a 7702 designator has 23 bytes of code, so a single key passes as proposer, executor and canceller without the override.
Fix. Reject designator code (0xef0100 ‖ impl, 23 bytes) and probe the multisig interface (for example getThreshold() >= 2).
Informational
I-1. A 7702 designator or hybrid owner change stops the module only while it lasts. · Severity: Info · Origin: [both] (phase 1 SIG-5; phase 2 agent 3 lead) · SALib.live (SALib.sol:225-229). The header calls the change "a revocation", but nothing is stored: if the designator or owner is restored, the keeper acts again on the old delegation. Tell clients that only revoke or disableDelegation is permanent, or add a permissionless poke(a) that sets revoked.
I-2. The owner EOA of a hybrid account cannot revoke before registration. · Severity: Info · Origin: [phase1: signatures (SIG-4)] · LPManagerModule.revoke (LPManagerModule.sol:375). Before the first registration s.owner is zero, so the pre-registration revoke works only from the account itself; a hybrid client must deploy the account first, and meanwhile anyone holding the signed delegation can register it. Registration alone moves nothing. Fix: also accept SALib.hybridAddress(_expect(), msg.sender) == a.
I-3. The permit success path does not check that the permit took effect. · Severity: Info · Origin: [phase1: erc20 (ERC20-1)] · SALib.pull (SALib.sol:291). A permit call that returns without reverting is treated as valid. With a conforming USDC this is not exploitable; if the issuer-upgradeable token ever answered permit as a no-op, onboard would pull from a standing allowance (round-2 M-3 again). Fix: require(nonces(o) == n + 1) after the try.
I-4. Keeper actions carry no deadline. · Severity: Info · Origin: [phase1: chain-specific (CHAIN-3)]. Swaps, adds and fees can land at most minPriceStable after the last confirming report; sendHedgeMargin up to maxPriceAge (1 h) later. No bypass of a bound. Optional deadline argument; the guardian bot should pause on sequencer recovery.
I-5. SABook.book narrows to uint128 unchecked, and increase / decrease are not read back. · Severity: Info · Origin: [phase1: general (GEN-6)] · SABook.sol:139. No reachable truncation was found (m ≤ snap; adds are bounded by PoolManager). Use SafeCast.
I-6. Sell notional is charged at keeperPrice, the cap is valued at the anchor. · Severity: Info · Origin: [phase1: precision-math (MATH-3)] · LPManagerModule.sol:486-487. A 1× cap admits about 1.015× of anchor-valued base. Charge max(fair, amountIn × ref).
I-7. Hybrid client exit with the DelegationManager paused rests on the EntryPoint path. · Severity: Info · Origin: [phase1: access-control (AC-6)]. Nothing on-chain in scope blocks an exit. The framework source is not in the repo, so whether a HybridDeleGator owner can act without the DelegationManager other than through EntryPoint.handleOps could not be confirmed here. Test the exit on a fork with the DelegationManager paused. 7702 clients transact directly.
I-8. Two guardian registries. · Severity: Info · Origin: [phase1: access-control (AC-5)]. The module guardian and the timelock CANCELLER are independent; setGuardian alone leaves the old key able to cancel every module operation. Script the two-step rotation as one runbook.
I-9. The module header mentions an anchor "path backstop" that the code does not have. · Severity: Info · Origin: [phase 0 open question; re-read in reconciliation] · LPManagerModule.sol:58-59 versus SALib.movePrice. The root-cause file says it was dropped; correct the comment.
4. R4 exit window — the three checks you asked for
(a) No path charges a risk-adding swap or an add to the exit window. Confirmed. _add passes false (LPManagerModule.sol:796); the predicate needs sellBase (:487); the two windows are separate rings. A sale with no position while hedge equity is still open leaves the account net short, which is keeper policy, not a booking error.
(b) Client-held or untracked positions. The predicate reads the tracked list after a priced sync, which drops positions the account no longer owns. States with an empty list: nothing minted, everything burned by the keeper (free, also while paused), all NFTs transferred out or burned by the client. A client-held untracked position does not matter: only idle base can be sold. A tracked position that is empty but still owned, or subscribed, keeps sells on the turnover window (L-6). The keeper chooses the window freely (a dust position routes sells to turnover, a burn routes them to exit).
(c) The stated bound. Against the anchor it holds: no cycle through LP positions was found that exceeds (turnover + exit) × value of charged notional per 24 h, and the worst loss per charged unit is about 3.0 % for swaps and at most 1 % for adds. Three corrections: the per-unit loss against the market is about refDrift + band + slippage (M-1); safety argument (3) is inaccurate (LP mints re-acquire base at 2× per turnover unit; the exit cap stays absolute); the script deploys 9 %, not 4.5 % (L-12).
5. Task 3 — accepted residuals of sa_round3_response.md
#
Residual
Bounded as stated?
Can it reach principal?
1
Fees of an NFT moved out and the fee share of a client partial decrease "are not counted as yield"
No. if (pmLiq == 0) n = old; counts them when the position is later emptied (L-1 case (b), L-2).
Yes, small: fee growth × snapshot liquidity over one gap between priced syncs × feeBps.
2
Several direct liquidity changes between two syncs, "bounded by that liquidity's own fee income"
No. Unbounded after a tick re-initialisation (H-1); otherwise bounded by the range's fee growth × snapshot liquidity, which is more than "its own fee income" (L-1).
Yes: H-1, 20 % of idle USDC per feeInterval, repeating.
3
Client timing inside the 50 bps booking band, ≤ 2 × 50 bps
Yes for the client-timing direction when booking is prompt. Not when the booking is late or made at a walked anchor (M-2).
Client-timing direction lowers the fee only. The reverse direction (M-2, Trace B) is a fee on principal.
4
Keeper booking at the band edge, phantom gain ≤ 50 bps × flow
No. Up to refDriftBps × flow with a pushed pool (M-2, Trace A): fee up to 1.5 % of the flow at script values.
Yes, to feeRecipient, capped by 20 % of idle USDC per interval.
5
Fee after a 1.5 % pool push held for minPriceStable
The 1.5 % holds against the anchor's trailing low, not against the market; no hold is needed (two instants), the cost is two pool fees; a stale anchor needs no walk (M-2, Trace C).
Yes, to feeRecipient, same cap.
6
Fee deferral in a rally
Yes.
No (operator's fee only).
7
Stolen-keeper oscillation ≈ (band + slippage) × turnover
No against the market: add refDriftBps per unit (M-1); and with the exit window the script default is 9 %, the pilot 4.5 %, both against the anchor.
Yes: M-1.
8
Liveness: pool held > 50 bps off the anchor
Yes; removals, returns and exits are independent of the pool. Side effect: it lengthens the stale-snapshot window of H-1 / L-1 / L-3 and the delayed booking of M-2.
Not by itself.
9
Unchanged from round 2 (keeper-attested equity, multicall gas, 7702 approval resets, partial fills, add weighting, feeBps change, timelock roles, USDC blacklist, treasury allowance)
Yes as stated. Notes: guardian-approved equity has no cap and feeds the window caps (L-5); the add weighting lets a keeper re-acquire base at 2× per turnover unit (section 4).
Only with guardian + keeper together (L-5).
6. Leads (not confirmed; confidence below the floor or unverifiable here)
Hybrid exit with the DelegationManager paused (see I-7): depends on framework code that is not in the repo.
DelegationManager v1.3.0 hook order for several executions sharing one context, and whether the enforcer's balance read at hook time can precede account code of an earlier execution in the same redemption: the scope assumes "hook immediately before each execution". Not verifiable without the framework source.
Deployed venue code: PoolManager, PositionManager and Permit2 are pinned by runtime-hex fixtures; USDC and the DelegationManager runtime are not hash-checked in the script. Not inspected on chain 99901 in this review.
7. Access-Control Inventory
LPManagerModule
Function
Guard
Caller
Moves value
register
nonReentrant; anchor exists; caller check only when replacing / resuming / pre-revoked (SALib.sol:249)
anyone (first time); else account or pinned owner
no
onboard
as register; hybrid only; isActive; owner permit
anyone with the client's delegation + permit
USDC owner → account
deposit
nonReentrant; registered
anyone
USDC caller → account
revoke
msg.sender == a or pinned owner; no modifier, no external call
client
no
sync
nonReentrant; _trusted(); no registration check (M-3)
anyone
no
reportPrice
onlyKeeper; pool band
keeper
no
mintPosition, increasePosition
onlyKeeper, whenNotPaused, trusted keeper price, _live
keeper
account → pool
decreasePosition, burnPosition
onlyKeeper, _live, not subscribed; no pause or price gate
keeper
pool → account
swap
onlyKeeper, whenNotPaused, trusted keeper price, _live
keeper
account ↔ pool
sendHedgeMargin
onlyKeeper, whenNotPaused, anchor age, _live, cap
keeper
account → hedgeTreasury
returnHedgeMargin
keeper (≤ hedgeEquity) or hedgeTreasury; registered; never paused
keeper / treasury
treasury → account
reportHedgeEquity
onlyKeeper; registered
keeper
no
chargeFee
onlyKeeper, whenNotPaused, trusted, _live, interval, hedge fresh, feeGate
keeper
account → feeRecipient
multicall
onlyKeeper; self-delegatecall, inner guards intact
keeper
per inner call
approvePrice, approveHedgeEquity
onlyGuardian; TTL ≤ 1 day; no width / value bound (L-4, L-5)
guardian
no
setPaused(true)
guardian or owner
guardian / owner
no
setPaused(false), setKeeper, setGuardian, setParams, transferOwnership
owner (timelock); _distinct; hard caps
owner
no
acceptOwnership
pendingOwner
pendingOwner
no
Other contracts
Function
Guard
Caller
SwapExecutor.swap
nonReentrant; amount and value checks
anyone (pays and receives itself)
SwapExecutor.unlockCallback
msg.sender == poolManager and guard entered
PoolManager inside swap
ElysiumCustodyEnforcer.beforeHook
DelegationManager only; mode 0; redeemer == module in the signed terms
DelegationManager
VaultTimelock.schedule / scheduleBatch
PROPOSER; delay ≤ 30 d; mixed batches revert
operator
VaultTimelock.execute / executeBatch
EXECUTOR; not expired
operator
VaultTimelock.cancel
CANCELLER; self-operations need PROPOSER
operator, guardian
VaultTimelock.updateDelay, grantRole, revokeRole
the timelock itself
timelock
VaultTimelock.renounceRole
caller == account; PROPOSER refused (EXECUTOR not: L-11)
role holder
VaultTimelock.receive
none
anyone
DeploySA.run
forge script
deployer
Roles. Owner = VaultTimelock (two-step transfer, renounce disabled; no fund-moving function). Keeper and guardian: single addresses set by the owner. hedgeTreasury, feeRecipient: immutable. Client: the account and its pinned owner (derived from the CREATE2 address for a hybrid, the account itself for 7702). All six module roles are pairwise distinct (constructor and setters).
Pause. Blocked while paused: mint, increase, swap, sendHedgeMargin, chargeFee. Working: decrease, burn, reportPrice (drift cap 0), reportHedgeEquity (keeper cap 0), returnHedgeMargin, register, onboard, deposit, revoke, sync, approvals, owner setters.
Entrypoints: 38 external/public state-changing functions in source, 38 in the inventory.
8. Threat Model
ID
Actor → reach
Invariant that must hold
Result
T1
Stolen keeper → swaps, mints, increases with pool pushes
Loss ≤ (band + slippage) × (turnover + exit) per 24 h
Holds against the anchor; not against the market → M-1
T2
Stolen keeper → reportPrice + own pool trades
Anchor ≤ refDriftBps from any value of the trailing 24 h
Invariant holds; one report uses all of it → M-1, M-2
T3
Stolen keeper → exit window
Only base sales with no tracked position; ≤ 1× cap
Invariant holds (section 4); L-6
T4
Stolen keeper → hedge send / report / return
Exposure ≤ hedgeCapBps at a send; equity only down
Invariant holds for the keeper alone; with the guardian → L-5
T5
Stolen keeper → chargeFee
Fee ≤ feeBps × profit above the mark, ≤ 20 % idle, per interval
Cap and interval hold; profit can be wrong → H-1, M-2, M-3, L-1..L-3
T6
Stolen keeper → removals at a pushed pool
Removal returns the position's own tokens
Invariant holds (a push through the range favours the account); L-3 for a stale snapshot
T7
Stolen keeper → multicall
Inner guards unchanged
Invariant holds
T8
Client's ordinary direct actions → books
Yield counted ≤ fees received
Violated → H-1, L-1, L-2
T9
Hostile account code → redemptions
Effects stay in its own account
Invariant holds (record keyed by payer and hash-bound; transfers verified at the recipient)
T10
Third party → sync, deposit, register, onboard
Booking only for registered accounts at a trusted anchor; permit once
sync on unregistered → M-3; permit edge cases L-9, L-10
T11
Pool-price manipulator → gates
Cannot block removals, returns, exits
Invariant holds; can stop booking, swaps, adds, fees (accepted) and R4 sales (L-7)
T12
Compromised guardian
One-shot, ≤ 1 day, voided by pause; liveness only
Alone: invariant holds. With the keeper → L-4, L-5
T13
Relayer / front-runner → permits and delegations
Funds only owner → own account; nonce once
Invariant holds; L-9, L-10, I-2
T14
Owner (timelock) → params, roles
Hard caps; ≥ 24 h
Invariant holds; L-8, L-11
T15
Anyone → SwapExecutor
Module books only its own call
Invariant holds
T16
DelegationManager owner / USDC issuer
Client-direct exit unaffected
Invariant holds in scope; I-7
T17
Deployer / environment
Wiring and parameters as stated
L-12, L-13
T18
Keeper + sequencer time → bucket boundaries
≤ 1× cap per 24 h; 24 h memory of the anchor
Invariant holds
9. Invariant Verification
Inferred invariants from the mechanical pre-scan (34 rows), each answered.
ID
Property
On-chain
Verdict
I-1
A face-value contribution moves snapshot and contributed equally
Yes
holds — _book writes both
I-2
A priced sync moves contributed by exactly live − snapshot
Yes
holds — same function and price as value
I-3
A margin send moves amount from idle snapshot to equity and net margin
Yes
holds — ledgers written after the verified transfer
I-4
A margin return moves amount from equity to idle
No
violated by design — a treasury return above equity is realised hedge PnL (accepted 1226 I-2); the money is the treasury's
I-5
params always inside the hard caps
Yes
holds — single writer _setParams
I-6
≤ 4 tracked positions
Yes
holds
I-7
max(equity, netMargin) ≤ hedgeCapBps × value
No
violated → L-5 (cap checked at a send only; guardian write-down resets it)
I-8
A keeper-only anchor move stays inside the trailing-range clamp
Yes
holds — verified by three agents incl. bucket boundaries; edge case L-8 after a cap reduction
I-9
Anchor never moves more than refDriftBps from a value of the trailing 24 h
No
violated → L-4 (guardian path, by design); the free first report precedes any registration
I-10
Window notional ≤ cap in the current + 8 previous buckets
Yes
holds
I-11
Window caps are a fixed fraction of the account value
No
violated → L-5 (approved equity inflates the base); a walked anchor moves it by ≤ 10 % (M-1)
I-12
Anchor values below 2^112
Yes
holds — RangeOverflow
I-13
snapPos.liq changes only by what the module asked, or to live at a priced sync
Yes
holds — and that staleness between priced syncs is what H-1 / L-1 use
I-14
delegationHash never returns to 0
Yes
holds
I-15
First anchor report is free once
Yes
holds
I-16
Guardian approvals are one-shot and voided by pause / guardian change
Yes
holds — a price range stays open until a clipped report uses it (L-4)
I-17
revoked cleared only by the client
Yes
holds
I-18
At most one fee per feeInterval
Yes
holds
I-19
The anchor is trusted only if fresh, stable, re-confirmed and within 50 bps of the pool
Yes
holds as coded — the pool terms are single-instant reads (M-1) and one report satisfies both time terms at exactly moved + minPriceStable
I-20
The module acts only before the delegation's expiry
Yes
holds
I-21
live − snapshot equals everything the client did (computed effect equals executed effect)
No
violated → L-3 (burn uses the snapshot liquidity); otherwise the computed amounts match PoolManager's rounding and only the account's own code can sit between compute and execution
I-22
Fees credited = (last − mark) × liquidity, "a client change can only make this smaller"
No
violated → H-1, L-1, L-2
I-23
revoke is one plain call, not pausable; every redemption checks _live
Yes
holds
I-24
Every value held in the last 24 h is inside the range bounds
Yes
holds
X-1
The executor record the module books is the record of its own call
Yes
holds
X-2
The module's fee rule is never looser than the enforcer's
Yes
holds
X-3
A margin send the module admits is admitted by the enforcer
No
violated — liveness only, accepted (1226 L-16)
X-4
The stored delegation carries this deployment's enforcer terms
Yes
holds
X-5
Flows and value use the same valuation function and price
Yes
holds
X-6
Every fee transfer passes the enforcer's own interval check
No
holds — re-read in reconciliation: both clocks are written in the same transaction at each fee, and the module's starts no earlier than the enforcer's (0), so the module's interval implies the enforcer's
E-1
A client flow cannot change profit
No
violated → H-1, M-2, M-3, L-1, L-2, L-3
E-2
Keeper loss ≤ (band + slippage) × (turnover + exit) per 24 h
No
violated against the market → M-1
E-3
USDC leaves only to the pool, the treasury within the cap, the fee recipient within the fee rule
No
recipients hold; the amount bounds are violated → L-5 (treasury cap with the guardian), H-1 (fee on principal)
E-4
The client can stop the module and act on its account in any pause state
Yes
holds
Coverage: 38 entrypoints, 38 addressed. 18 threat rows, 18 answered. 34 inferred invariants, 34 answered. Holes closed this pass: 1 (X-6).
Completeness: 24 unique (Contract, function) across both phases, 24 covered.
10. Notes and limits
Not executed. No test, script or build was run. Traces are hand traces; confidence values reflect that. The first thing to do with H-1 is to run the regression sketch on your fork test base.
Dependencies were read at the pinned submodule commits (v4-periphery c6e4754, v4-core 59d3ecf, OpenZeppelin c64a1ed). The contracts deployed on Elysium were not compared with these sources. The MetaMask Delegation Framework source is not in the repo; its behaviour is assumed as the scope's interfaces and docs state it.
Out of scope as agreed: Hyperliquid, the bridge, treasury custody, the keeper's off-chain code, Uniswap v4 / Permit2 / USDC / the Delegation Framework themselves, and fee-accuracy residuals that only lower the operator's fee.
Pipeline record: 1 pre-scan doc helper + 3 context agents + 8 checklist agents + 12 attack agents (12 of 12 returned, none respawned). Breadth domains: general, precision-math, defi-amm, oracles + flashloans, signatures + erc20, access-control + governance, erc4337 + erc721, chain-specific + assembly + dos.
This review was performed by an AI system. AI analysis cannot verify the complete absence of vulnerabilities and no guarantee of security is given. A human security review, a staged rollout and on-chain monitoring are strongly recommended before funds of third parties are managed.
    Canonical copy: this is a styled rendering of the immutable report delivered on IPFS —
       https://bafkreifttmxymvg3qhkomhvdwdxusmloze5hlqv45wujp7fsgdlq2q47ze.ipfs.community.bgipfs.com/.
       If the two ever differ, the IPFS copy is authoritative.
    Audited by LeftClaw Services 🦞 — job
       #1240 on Base. Rendered 2026-11-18.
