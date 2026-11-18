<!-- Plain-text rendering of LeftClaw job #1256 (HTML original; the IPFS copy is authoritative). -->


Elysium LP smart accounts, round 8 (LeftClaw job 1256) — LeftClaw Services
      🦞
      LeftClaw Services
      ·
      Smart Contract Audit
    Elysium LP smart accounts, round 8 (LeftClaw job 1256)
    Job #1256 · completed on-chain · report pinned to IPFS
      Job page #1256
      Canonical report IPFS
      Generated 2026-11-18
      1
Medium
      4
Low
      12
Info
    Contents
      The answers you asked for first
      Findings
      Leads
      Task-by-task answers
      Threat Model
      Invariant Verification
      Access-Control Inventory
      Process notes and limits
Security audit — Elysium LP smart accounts, round 8 (LeftClaw job 1256)
Repo: https://github.com/Aleha1975/dispatch-cash — commit 3f0f42d3e529a7b62b10eb21de240afc3ba755a6 (branch elysium-lp-sa; the client's sa-r8 commit, one commit on top of e6a2de5). The commit is reachable on the remote: git ls-remote returns it as refs/heads/elysium-lp-sa.
Deployed source: none. The contracts are not deployed (target chain: Elysium mainnet, chain id 99901).
Scope: src/sa/SABook.sol, src/sa/SALib.sol, src/sa/SARange.sol, src/sa/LPManagerModule.sol (changed this round); src/sa/SAWindow.sol, src/sa/SwapExecutor.sol, src/sa/ElysiumCustodyEnforcer.sol, src/sa/vendor/DelegationFramework.sol, src/V4PositionMath.sol, src/VaultTimelock.sol, script/DeploySA.s.sol (unchanged). 2,523 nSLOC. The shelved pooled vault is out of scope.
Method: x-ray pre-scan → context map (3 agents) → breadth pass (8 checklist agents) → depth pass (12 attack agents, blind to the breadth pass) → reconciliation with a coverage gate. 23 hunting and context agents ran; all 12 depth lenses returned.
Date: 2026-11-18
Severity counts: 0 Critical · 0 High · 1 Medium · 4 Low · 12 Informational
Reconciliation summary: Overlap: 3 · Phase-1-only: 14 · Phase-2-only: 0 · Re-examined leads kept: 14, demoted: 0 · Coverage holes closed: 0 · Invariants: 29 answered (26 hold, 3 violated, 0 unverified). Reporting floor: every finding of Low severity and above with confidence ≥ 50 is a finding; nothing fell below that floor, so the Leads section is empty.
Completeness: 26 unique (Contract, function) across both phases, 26 covered.
Coverage: 46 entrypoints in inventory, 46 addressed. 17 threat rows, 17 answered. 29 inferred invariants, 29 answered. Holes closed this pass: 0.
The answers you asked for first
Can a fee be charged on principal through a client flow, beyond your two stated residuals? Yes, in two places. Everything else in your argument held under every trace the 20 hunting agents ran.
The opening booking (M-1). It is the one booking of a price-dependent inflow that gets neither term of the rule: hwm stays 0 and no priced is added. If the anchor is below the market when a first registration lands, the gap on all HYPE the account holds is later charged as profit. The gap is up to about 0.5% with no manipulation, about 1.5% if the registrant pushes the thin pool toward a lagging anchor in the same transaction, and about 9.1% under a stolen keeper that has walked the anchor down. The fee on principal is then 0.075%, 0.225% and 1.36% of the HYPE value held at registration. This also makes your round-7 L-1 statement ("inflows within 2x are covered at a walked anchor") untrue for the opening inflow.
The fee credit (L-1). _feesOut / _credit moves snapBase up before _bookIdle tests b != s.snapBase. A client base inflow no larger than the base fees the client collected in the same interval is absorbed as "yield", so the booking is unpriced. After an unseen liquidity dip and restore the credit is also larger than the fees PoolManager paid, and a deposit fills the difference. Only the client can start either case, and the amounts are bounded by LP fees.
Your two residuals. Both are real and both are stated a little too narrowly (I-1, and the note under "Task 1" below):
(a) is not limited to an exact round trip that leaves the books identical. Through the fee credit it need not be exact (L-1). A third party can complete it on a 7702 account by refunding the client's gas to the wei. An in-account swap round trip that restores HYPE to the wei leaves a USDC difference, which is booked as a plain USDC flow.
(b) reads "below the mark". The precise condition is that the account's true profit is below the mark at the booking, and the losing leg of the netted flows is itself what puts it there. An account exactly at its booked mark (the state right after every fee and every priced booking) is exposed. Your response document's bound (feeBps × min(e − priced, the real distance below the mark)) is correct.
Principal-loss paths at the pilot (about USD 250, DeploySA.pilotParams). None found. No agent in either pass found a path by the keeper (inside or beyond its bounds), the relayer, a third party, the guardian or the timelock that moves tokens or position NFTs out of an account other than into the pool, to hedgeTreasury or to feeRecipient. The custody enforcer independently limits destinations to those. The client can always exit: revoke makes no external call and is not pausable, and direct withdrawals and burns need no module state. For a pilot account of 3 HYPE + 130 USDC, the worst fee on principal we could build is about USD 1.64, once, under a stolen keeper (M-1); with an honest keeper it is about USD 0.27.
Round-7 Medium and Lows — status.
Round-7 item
Status at 3f0f42d
M-1 opposite flows net to zero in priced
Fixed for every flow a sync sees (flowSeen, unit-based moved). Residuals (a) and (b) remain as you state, with the wider preconditions in L-1 and I-1.
L-1 recorded range is not the market
Closed by removal. The floor covers outflows at any anchor and inflows within 2× — except the opening inflow, which has no floor (M-1).
L-2 confirmation day counted from consumption
Fixed. approvedAt is written only at SALib.sol:478; baseTime only at SALib.sol:409 (first report) and SALib.sol:431. Nothing else writes either. See I-2 for two timing notes.
Round-7 Informationals: I-1 fixed (LPManagerModule.sol:743); I-2 fixed by removal, and replaced by M-1 (the opening now needs a trusted anchor but has no floor); I-3 fixed (_trusted() is false while paused; this blocks only bookings, swaps, adds, margin sends and fees); I-4 and I-5 accepted by you, unchanged.
Findings
M-1 — The opening booking has no high-water-mark floor, so a first registration at an anchor below the market leads to a fee on principal
Severity: Medium
Confidence: 90
Origin: [both] — phase 1: oracles, defi-amm, general, access-control, erc4337, chain-specific · phase 2: agents 1, 3, 6, 7, 8, 9, 10, 11 (findings) and 2, 4, 5, 12 (leads)
Location: SABook.sync — SABook.sol:89-90; SABook._bookIdle — SABook.sol:167; LPManagerModule._register — LPManagerModule.sol:394-397; SALib.register — SALib.sol:272, SALib.sol:289; LPManagerModule._trusted — LPManagerModule.sol:875-882
Description. A first registration books everything the account holds at lastPrice in the same transaction, and skips both terms of the rule:
// SABook.sol:89-90
bool open = s.hwm == SALib.OPEN; // the first registration's own sync: no lateness, no raise
if (open) s.hwm = 0;
// SABook.sol:167-169
if (open || !moved) return false;
s.hwm += SafeCast.toInt256(priced);
return true;
So contributed = idle USDC + idle HYPE × anchor and hwm = 0. If the market is above the anchor at that moment, contributed is short by HYPE × (market − anchor). Module actions never raise hwm, so once the anchor reaches the market that gap is profit above the mark, and chargeFee takes feeBps of it. The client had no gain.
Three facts make the gap reachable:
The opening price is tied only to the pool at one instant. _trusted() needs the anchor stable for minPriceStable, reported within minPriceStable, within poolBandBps of the last report and within 50 bps of pool spot (d * BPS <= pool * BOOK_BAND_BPS, LPManagerModule.sol:881). It does not look at the guardian-confirmed base or the 24 h range. feeGate later checks the anchor at fee time, not at booking time, and only against a high anchor.
The first registration is permissionless. The caller check at SALib.sol:272 applies only when old != 0 || s.revoked. Whoever holds the signed delegation (the relayer, or anyone who saw it in the calldata of a reverted register / onboard) picks the transaction. sync(a) was restricted to the keeper, the account and its owner for exactly this reason (LPManagerModule.sol:891); register now reaches the same booking without that restriction.
Every other inflow has the floor. The same holdings booked at an untrusted opening are marked (flowSeen) and the later booking sets hwm ≥ priced. Only the trusted opening is unprotected. In round 7 the first booking still received the late-booking raise; this is new with the removal.
Traces (pilot parameters; all numbers in USDC per HYPE).
Honest keeper, registrant pushes the pool (no privileged key).
t0: the anchor moves to 40.00. The market rises to 40.60.
t0+240: the keeper reports 40.60. The anchor is not yet stable, so movePrice keeps 40.00. lastReported = 40.60; |40.60 − 40.00| × 10⁴ = 6,000 ≤ 40.60 × 150 = 6,090, so the anchor does not count as clipped.
t0+300 … t0+360: every _trusted() term holds except the pool term (the pool is at 40.60). In one transaction the registrant sells about USD 470 of HYPE (pool to 40.19; 0.19 ≤ 0.5% × 40.19), calls register(d), and buys back. Cost: about USD 3 of pool fees.
The account holds 100 HYPE + 500 USDC. Opening: contributed = 100 × 40.00 + 500 = 4,500, hwm = 0. Value at the market: 4,560.
t0+360: the anchor moves to 40.60. Seven days later, with the price unchanged and no client flow, feeGate passes and chargeFee computes profit = 60 > hwm = 0, fee = 15% × 60 = 9 USDC (0.225% of the HYPE value).
Stolen keeper.
base = anchor = market = 40. The keeper reports 39.40, 38.81, 38.23, 37.65, 37.09, 36.53, 36.364 (the dn bound ceil(40 / 1.1), SALib.sol:415): one 1.5% step per 300 s with the pool pushed along, about 35 minutes.
With the pool held within 50 bps of 36.364 for 300 s, _trusted() is true and a first registration lands for an account with 3 HYPE + 130 USDC (true value 250). Opening: contributed = 130 + 3 × 36.364 = 239.09, hwm = 0.
The anchor returns to 40. After 24–27 h the low leaves the range ring; a routine guardian confirmation keeps baseTime fresh.
Day 7: profit = 250 − 239.09 = 10.91, fee = 1.64 USDC, 1.36% of the HYPE value, charged once.
Other variants. With no push and an honest keeper the gap is at most 50 bps (fee ≤ 0.075% of the HYPE value at every trusted opening where the anchor is below the market). After a sequencer stall shorter than minPriceStable, the first block sees the pre-stall anchor and an un-arbitraged pool, so the gap is the market move during the stall. After an unpause (L-2) a frozen anchor is trusted at once.
Limits. The fee goes to the immutable feeRecipient; a key thief or a third party gains nothing, so the incentive sits with the operator side. Only accounts that hold HYPE (or tracked liquidity) at registration are exposed: every 7702 EOA, and a hybrid account funded with HYPE before registration. A hybrid account onboarded with USDC through onboard is not affected. Any priced booking before the first fee wipes the phantom (1 wei of HYPE, or the gas of any transaction a 7702 client sends). An anchor above the market at the opening only lowers the fee.
Why Medium. It is a bounded, one-time fee on principal, not a loss of custody. It is rated above the round-7 L-1 sibling because it applies to the whole HYPE balance of the account rather than to one flow, because a variant needs no privileged key, and because it is a direct counter-example to the claim this round was built to establish.
Recommendation. Give the opening a floor. The agents proposed three fixes; they differ in what they cost you.
Option A — the same floor as every priced booking. The opening then behaves like an untrusted opening already does (hwm = value of the HYPE held). Simplest, but the fee starts only after the profit exceeds that value:
-        if (open || !moved) return false;
+        if (!open && !moved) return false;
         s.hwm += SafeCast.toInt256(priced);
         return true;
Option B — a floor sized by the largest distance the anchor can have from the market. This is the smallest change that closes the path and keeps the fee: devBps = refDriftBps + poolBandBps covers the stolen-keeper walk; poolBandBps + BOOK_BAND_BPS covers only the honest-keeper cases:
-        if (open || !moved) return false;
+        if (open) {
+            // devBps = poolBandBps + BOOK_BAND_BPS (or refDriftBps + poolBandBps to cover a walked anchor)
+            s.hwm = SafeCast.toInt256(Math.mulDiv(priced, devBps, BPS, Math.Rounding.Ceil));
+            return false;
+        }
+        if (!moved) return false;
         s.hwm += SafeCast.toInt256(priced);
         return true;
Option C — restrict when or by whom the opening is booked at the anchor; otherwise pass price 0 so the holdings stay pending and take the normal floor later. Two forms were proposed:
-        if (SALib.register(accounts, permissionContext, d, _expect())) _sync(d.delegator);
+        if (SALib.register(accounts, permissionContext, d, _expect())) {
+            address a = d.delegator;
+            uint256 ref = lastPrice;
+            uint256 rep = lastReported;
+            bool tight = (ref > rep ? ref - rep : rep - ref) * BPS <= rep * BOOK_BAND_BPS;
+            SABook.sync(accounts[a], _positions[a], snapPos, a, venue, tight && _trusted() ? ref : 0);
+        }
-        if (SALib.register(accounts, permissionContext, d, _expect())) _sync(d.delegator);
+        if (SALib.register(accounts, permissionContext, d, _expect())) {
+            address a = d.delegator;
+            // only the account or its owner opens at the anchor; any other caller leaves the holdings pending
+            bool own = msg.sender == a || msg.sender == accounts[a].owner;
+            SABook.sync(accounts[a], _positions[a], snapPos, a, venue, own && _trusted() ? lastPrice : 0);
+        }
Option C alone does not cover a stolen keeper (the anchor and the last report agree during a walk). We recommend Option B with refDriftBps + poolBandBps, optionally together with the caller rule. The module is 421 bytes under EIP-170, so check the size after the change; Options A and B are inside the SABook library.
L-1 — The fee credit can absorb a client base inflow before the priced test, and over-credits after an unseen liquidity dip and restore
Severity: Low
Confidence: 80
Origin: [both] — phase 1: precision-math, defi-amm · phase 2: leads from agents 1, 3, 4, 7, 9, 10
Location: SABook._feesOut — SABook.sol:200-208; SABook._credit — SABook.sol:217-225; SABook._bookIdle — SABook.sol:159
Description. At every sync, _feesOut infers "fees the client collected itself" from the advance of the position's fee mark times the snapshot liquidity, and _credit adds that amount to the snapshot, capped only by the idle surplus:
// SABook.sol:204-208
uint256 d0 = l0 - q.g0;
uint256 d1 = l1 - q.g1;
if (d0 > G0 - q.G0 || d1 > G1 - q.G1) n = 0; // re-based by PoolManager (cleared tick): count nothing
c0 = FullMath.mulDiv(d0, n, 1 << 128);
c1 = FullMath.mulDiv(d1, n, 1 << 128);
// SABook.sol:220-224
if (ra < 0 || rb < 0) return;
s.snapAsset += int256(_cap(ca, ra));
s.snapBase += int256(_cap(cb, rb));
This runs before _bookIdle evaluates the priced test:
// SABook.sol:159
bool moved = s.flowSeen || b != s.snapBase; // SA-7: any price-dependent change, even 1 wei
The credit does not check that the surplus in idle is the collected fee. Two consequences, both needing a direct client modify of a tracked position that no sync sees before the booking:
(A) Room filled by principal. If the client collects fees to another address (or collects and withdraws them) and later sends base in, any inflow D ≤ the collected base fees fills the room. snapBase becomes equal to the balance, moved is false, nothing is added to contributed and there is no raise. The out-and-in of base at two prices is unpriced without being exact to the wei. For a 7702 account the gas it pays is absorbed the same way, so gas no longer makes its round trips inexact.
(B) Over-credit after a dip and restore. PoolManager pays fees on the liquidity held at each modify. If the client removes x and later restores exactly x, liq == old == seen holds and the credit is computed with the full L for the whole interval, although only L − x earned fees while x was out. The excess headroom growth × x is filled by whatever sits in idle, so a deposit is booked as yield, not as a contribution.
This answers your question "fees credited by _feesOut in the same sync": such a flow exists.
Trace (A). A tracked position holds 1 HYPE of uncollected fees; anchor 40. The client collects with TAKE_PAIR to its own wallet (1 HYPE leaves at 40). Later, at anchor 60, the client sends 1 HYPE back. Sync: c = 1 HYPE, rb = 1 HYPE, snapBase += 1, moved = false. True contribution is −40 + 60 = +20; booked is 0. Booked profit is 20 too high; the fee on principal is 3 USDC. Bound: feeBps × base fees × (p_in − p_out).
Trace (B). Anchor 40; position worth 200 USDC with liquidity L; account at its mark. The client decreases 90% directly, 14 days pass, the client re-adds exactly the same liquidity at the same pool price, then deposits 50 USDC + 0.015 HYPE. Full L would have earned 0.80 USDC + 0.020 HYPE in the 14 days; the remaining 10% really earned 0.08 USDC + 0.002 HYPE. The credit is 1.10 USDC + 0.0245 HYPE (capped by the room), so snapBase == b and moved is false. Booked contribution is 49.28; the true contribution is 50.60. Profit is overstated by 1.32 USDC with hwm unchanged, and the next fee takes about 0.20 USDC of principal.
Limits. Only the client can start it (only the NFT owner can modify the position). A sync between the two legs stops it (seen differs and flowSeen is set, or the marks are retaken). The amounts are bounded by LP fees, not by the size of the account.
Recommendation. Treat a sync that applied a credit as a priced interval, so hwm is raised to at least the profit after it. Two forms were proposed:
Option A — mark when a credit is applied:
function _credit(...) private {
    ...
    uint256 da = _cap(ca, ra);
    uint256 db = _cap(cb, rb);
    if (da != 0 || db != 0) s.flowSeen = true; // an inferred credit: the booking is priced
    s.snapAsset += int256(da);
    s.snapBase += int256(db);
}
Option B — mark when the fee mark moved, and put the credited value in the floor:
// _feesOut, before _mark
if (l0 != q.g0 || l1 != q.g1) s.flowSeen = true;
// and carry the credited (ca, cb) to _bookIdle: priced += ca + mulDiv(cb, price, WAD)
Both cost only the operator: the uncharged gain is forgone when a client collects fees itself, the same class as the residuals you already accept.
L-2 — An unpause makes a frozen anchor trusted in the same block
Severity: Low
Confidence: 70
Origin: [phase1: oracles] — re-examined and kept
Location: LPManagerModule.setPaused — LPManagerModule.sol:691-702; LPManagerModule.reportPrice — LPManagerModule.sol:418; LPManagerModule._trusted — LPManagerModule.sol:880
Description. While paused the anchor is frozen (drift cap 0), but every report still refreshes lastPriceTime and lastReported. lastPriceMoved is written only on a move or after a gap:
// LPManagerModule.sol:418
if (p != old || block.timestamp > lastPriceTime + params.minPriceStable) lastPriceMoved = block.timestamp;
setPaused(false) writes only paused (LPManagerModule.sol:700). So in the first block after the unpause _trusted() can be true with no fresh move and no new stable window, if the last report made during the pause is within poolBandBps of the frozen anchor and the pool is within 50 bps of it. With an honest keeper this is harmless. It matters when the pause was the answer to a walked anchor: the walked value survives the pause and is usable at once.
Trace. A stolen keeper walks the anchor to 36.36 (market 40); the guardian pauses. The stolen key remains the keeper until the timelocked setKeeper executes and keeps reporting 36.36 while it holds the pool near it. The timelock batch [setKeeper(new), setPaused(false)] executes. In the next block _trusted() is true (lastPriceMoved is days old, lastPriceTime at most 120 s old). A first registration takes the M-1 opening at 36.36, or a client sync books at it, before the new keeper's first report. The new keeper's first honest report (40 against 36.36) ends it.
Recommendation.
} else {
    _checkOwner();
    lastPriceMoved = block.timestamp; // an anchor frozen through a pause is re-confirmed for minPriceStable
}
L-3 — An honest reportPrice reverts while the pool is held away from the market, so the anchor's age, margin sends and keeper hedge decreases depend on pool spot
Severity: Low
Confidence: 80
Origin: [phase1: dos, defi-amm, oracles] — re-examined and kept
Location: LPManagerModule.reportPrice — LPManagerModule.sol:408; LPManagerModule._checkPoolBand — LPManagerModule.sol:855-859; LPManagerModule.sendHedgeMargin — LPManagerModule.sol:539; LPManagerModule._trusted — LPManagerModule.sol:875-882
Description. Every report, including one that only re-reports the stored anchor, must be within poolBandBps of pool spot:
// LPManagerModule.sol:407-408
function reportPrice(uint256 price) external nonReentrant onlyKeeper {
    _checkPoolBand(price);
// LPManagerModule.sol:539
if (ref == 0 || block.timestamp > lastPriceTime + params.maxPriceAge) revert StalePrice();
In this pool about USD 700 moves spot 1.5% and about USD 235 moves it 0.5%. A third party who holds the pool away from the market therefore reaches further than your residual 8 lists:
Pool against the anchor
What stops
What keeps working
more than 50 bps
mint, increase, swap (including the risk-off sale), chargeFee, bookings (deferred and marked)
decrease, burn, returnHedgeMargin, reportHedgeEquity, sendHedgeMargin, reportPrice
more than 150 bps
also: every honest reportPrice (PoolPriceOff), keeper-only hedge-equity decreases (cap 0)
decrease, burn, returnHedgeMargin; sendHedgeMargin until the anchor is older than maxPriceAge (3,600 s)
After the push ends, the first report counts as a move and trust returns minPriceStable later. The keeper's own swaps can do the same: the swap limit is 1.5% from the anchor, so a keeper swap that moves spot more than 0.5% blocks the next add or swap for every account.
Trace. Anchor = market = 30.00. The attacker buys HYPE with about USD 700; the pool is at 30.48. The keeper reports 30.00: 0.48 × 10⁴ = 4,800 > 30.48 × 150 = 4,572, so it reverts. One hour later sendHedgeMargin reverts StalePrice for every account, so a hedge cannot be topped up on-chain. The estimated cost to the attacker is about USD 7 per push (pool fee plus the reversion), and nobody gains value directly.
Impact. No principal moves inside the module, and removals, margin returns, revoke and direct exits do not read the anchor. The effect is on management liveness: rebalancing, the risk-off sale and margin top-ups stop while the push lasts. A margin top-up that cannot be sent can matter off-chain for a hedged position; that side is out of scope.
Recommendation. Let a pure refresh skip the report-time pool check (every consumer re-checks pool proximity at use), or write the keeper rule down: when the market is outside the pool band, report the in-band value closest to the market and follow no further than freshness needs.
function reportPrice(uint256 price) external nonReentrant onlyKeeper {
    if (price != lastPrice || lastPrice == 0) _checkPoolBand(price);
    ...
Also size keeper swaps so that their own impact stays under BOOK_BAND_BPS, and restate residual 8 to include reports, margin sends and keeper hedge decreases.
L-4 — The pinned compiler (solc 0.8.26, via-IR, optimizer on) is inside the range of a known Yul-optimizer bug
Severity: Low
Confidence: 60
Origin: [phase1: chain-specific] — re-examined and kept (the bug list was checked again during reconciliation)
Location: build configuration — foundry.toml:6-10
Description.
solc = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 1
via_ir = true
The official Solidity bug list (docs/bugs_by_version.json, read on 2026-11-18) lists six known bugs for 0.8.26. Five do not apply by their own conditions (named arguments in require with a custom error, delete of a memory bytes element without via-IR, two that need mutual recursion, and arrays at the end of storage). One remains: YulOptimizerKnowledgeBaseStaleBookkeeping (severity low, introduced 0.8.19, fixed in 0.8.38, condition: the Yul optimizer is on). The optimizer can treat two storage or memory locations as distinct when their addresses came from different values of one reassigned variable and coincide at run time; a load can then return an old value or a needed store can be removed.
Whether the bug triggers depends on the generated IR. This audit did not build the target (policy), so the finding is unverified in both directions. Source patterns of the described shape: the ring loops over one storage base in SAWindow.used / credit and SARange.bounds, the swap-and-pop on _positions (SABook.sol:115-117), and the reassigned buffer in multicall. A mis-compiled window or range read would weaken a keeper budget.
Recommendation. Before deployment, build with solc 0.8.38 or later and re-run the whole suite, or run the check from the compiler advisory on the exact build. Re-measure the module size after any compiler change (it is 421 bytes under the limit).
I-1 — Residual (a) is wider than "an exact round trip that leaves the books identical, started only by the client"
Severity: Info
Confidence: 80
Origin: [both] — phase 1: chain-specific, defi-amm, erc4337 · phase 2: lead from agent 5
Location: SABook._bookIdle — SABook.sol:158-159; SABook.sync — SABook.sol:121
Three cases reach the same fee result as residual (a) with a different precondition:
A third party can complete it on a 7702 account. Your response says a 7702 account's round trips are never exact because it pays gas. The gas cost of a transaction is public, and a plain transfer to an EOA always succeeds, so anyone can send exactly that many wei back before the next look. Then b == s.snapBase, the booking is unpriced and the uncharged gain is kept. The operator has the motive. The phantom is tiny (gas × price move); the precondition is wider, the bound is not.
Only idle base and tracked liquidity must match to the wei, not the books. A client who sells X HYPE in the pool and buys exactly X back (an exact-output swap) leaves a USDC difference. _bookIdle adds an idle-asset difference to f but never to priced or moved (SABook.sol:158-159), so the difference is booked as a plain USDC flow. Example: 1,000 USDC + 100 HYPE, contributed 2,000, anchor 13; the client sells at 12 and buys back at 13. The sync books contributed = 1,900; booked profit is 300 where the profit at the flows' own prices is 200. The books cannot tell this from a USDC withdrawal, so there is no code fix; the residual text should say "idle base and tracked liquidity equal to the wei".
Through the fee credit the round trip need not be exact (L-1).
A 7702 account that sends sync or register itself is a related case: the balance is read without the gas prepayment and the refund arrives after the transaction, so the next booking is always priced. That only lowers the fee.
Recommendation. Restate residual (a) with these preconditions. No code change beyond L-1.
I-2 — Guardian range: any in-range report consumes it, a dead until is accepted, and approvedAt is the inclusion time
Severity: Info
Confidence: 80
Origin: [phase1: oracles, chain-specific]
Location: SALib.movePrice — SALib.sol:428-431; SALib.approvePrice — SALib.sol:472-478
The consumption test does not depend on clipped, so a routine report inside the range consumes it and re-bases base, also when the report equals the anchor. docs/SMART_ACCOUNT_DESIGN.md says the range is "consumed only by a report that needs it"; the code and the fee flow rely on the opposite.
approvePrice accepts until < block.timestamp: a range that can never be consumed but still overwrites lo, hi, until, approvedAt and emits PriceApproved. In effect it is a cancel.
approvedAt = block.timestamp is the time the guardian's transaction is included, not the time the guardian judged the level. If inclusion lags signing by hours (sequencer stall, stuck nonce) and the guardian chose until from the signing time, a fee can be measured up to almost two days after the judgement. The other fee gates still apply.
Recommendation. Align the document with the code. Optionally require until >= block.timestamp, and let the guardian pass the judgement time (asOf <= block.timestamp, until <= asOf + ttl, approvedAt = asOf).
I-3 — A feeBps increase applies to gains already made; all parameters change under a signed delegation
Severity: Info
Confidence: 85
Origin: [phase1: defi-amm, access-control]
Location: LPManagerModule.chargeFee — LPManagerModule.sol:616; LPManagerModule._setParams — LPManagerModule.sol:741-746
The client signs (module, hedgeTreasury, feeRecipient) only. All eleven parameters can change under that signature inside the checkParams bounds. chargeFee reads params.feeBps at charge time, so a rise from 1500 to 2000 applies to profit accrued before it (uncharged gain 100: fee 20 where the client expected 15). The ≥ 24 h timelock lets a client revoke first. transferOwnership can also hand ownership to an address that is not a timelock after one delay, so the 24 h notice is not an on-chain invariant.
Recommendation. Document it, or have the keeper charge all accounts before a rate change takes effect.
I-4 — LP fees earned by liquidity the client added directly, before it is booked, count as yield
Severity: Info
Confidence: 75
Origin: [phase1: defi-amm]
Location: SABook.lpRemove — SABook.sol:363-370; SABook._value — SABook.sol:319-323
_fees multiplies fee growth by PoolManager's live liquidity; lpRemove books all of it as the module's effect and _value counts all of it. If the client adds liquidity to a tracked position while nothing can be booked (pause, untrusted anchor), the fees that liquidity earns before its booking are profit under the fee. This is real yield, not principal, but it is earned on capital the books do not yet hold.
Recommendation. Document it, or scale the fee part by min(snapshot, live) / live.
I-5 — The custody enforcer bounds destinations, not amounts against value or profit
Severity: Info
Confidence: 85
Origin: [phase1: access-control]
Location: ElysiumCustodyEnforcer._checkSwap — ElysiumCustodyEnforcer.sol:293-301; ElysiumCustodyEnforcer._checkTransfer — ElysiumCustodyEnforcer.sol:321-349
Walked on its own, beforeHook guarantees that value can only reach the delegator's own positions in the fixed pool, the SwapExecutor (which pays the caller), hedgeTreasury or feeRecipient. It does not enforce the amounts in the trust model: a swap of any size with minOut = 1 passes; the hedge window is 35% of whatever USDC is idle per 24 h, compounding, with no cap on the total; the fee check is 20% of idle USDC every 7 days with no link to profit. The bounds "≤ hedgeCapBps of value", "≤ feeBps of profit above the HWM", slippage and turnover exist only in the module. Not exploitable today: the redeemer must be the module, the module is immutable and builds every call itself. This states what the last line of defence is worth if a module bug were found.
Recommendation. Describe the enforcer to clients as a destination guarantee.
I-6 — multicall(allowFailure = true) has no gas bound per item
Severity: Info
Confidence: 80
Origin: [phase1: dos]
Location: LPManagerModule.multicall — LPManagerModule.sol:640
ok := delegatecall(gas(), address(), r, c.length, 0, 0)
A hybrid account's implementation is client code and runs inside every redemption bracket. An item that burns its gas leaves 1/64 of the remainder for all later items. The NatSpec states the rule "one account per multicall"; the code does not enforce it. No state is harmed; the keeper retries without that account.
Recommendation. Enforce the rule, or add an optional gas cap per item.
I-7 — PositionManager calls use block.timestamp as the deadline; removals have no staleness bound
Severity: Info
Confidence: 80
Origin: [phase1: defi-amm]
Location: SALib.modify — SALib.sol:665
modifyLiquidities(unlockData, block.timestamp) never expires. Swaps and adds are bounded in practice by _trusted (a report within 300 s). decreasePosition and burnPosition are not; a delayed keeper removal executes whenever it is included, limited only by the keeper's minimum amounts. A removal at a pushed price favours the LP, so there is no value at risk.
Recommendation. Optionally add a deadline argument to the two removal functions.
I-8 — Documentation no longer matches the code in three places
Severity: Info
Confidence: 90
Origin: [phase1: general, erc4337]
Location: LPManagerModule contract NatSpec — LPManagerModule.sol:58-62, LPManagerModule.sol:35-37; SABook.sync NatSpec — SABook.sol:67
Rule D of the module header still describes the removed day of waiting ("a day after the last booking of a material price-dependent client flow") and the removed report range ("the anchors at both ends and every keeper report between"). chargeFee has no such wait.
SABook.sol:67 says positions the account no longer owns "are dropped" without saying that this happens only at a priced sync.
The header says the client can "stop the module with one plain transaction (revoke, or DelegationManager.disableDelegation from the account)". For a hybrid account only revoke is a plain owner-EOA call; disableDelegation, burns and withdrawals go through EntryPoint.handleOps (this rests on knowledge of Delegation Framework v1.3.0; its source is not in the repo). Nothing in scope blocks that exit.
Recommendation. Replace the header text with the rule text of SABook.sync, and correct the two sentences.
I-9 — DeploySA proves the address derivation, not the runtime code, of some Delegation Framework contracts
Severity: Info
Confidence: 75
Origin: [phase1: chain-specific]
Location: DeploySA._canonical — DeploySA.s.sol:79-84; DeploySA._create2 — DeploySA.s.sol:72; DeploySA.run — DeploySA.s.sol:171-176
For the DelegationManager, EIP7702StatelessDeleGator and TimestampEnforcer (and for the hybrid implementation, the factory and the SCL library when already present) the script checks that code exists and that the fixture init code derives the address. That implies the code only if contract creation is the only way code reaches an address. On an Orbit chain the genesis allocation and chain-owner upgrades can place code anywhere. PoolManager, PositionManager, Permit2, EntryPoint and the CREATE2 deployer do get a runtime comparison (_sameCode). Not exploitable by an outside party; it needs the chain operator.
Recommendation. Add runtime fixtures for the six contracts and call _sameCode on each.
I-10 — The first base and baseTime come from the keeper's first report alone
Severity: Info
Confidence: 85
Origin: [phase1: oracles] · [phase2: agents 2, 5 examined, no issue]
Location: SALib.movePrice — SALib.sol:407-411
The first report sets base = p and baseTime = block.timestamp with no guardian. Both passes checked whether a fee can ride on it: it cannot. A fee needs feeInterval (≥ 7 days) after a registration, a registration needs the first report, and the fee gate needs baseTime within one day. The base bound on the anchor drift does start from the keeper's level, so the first report should be the checked market price, as the deploy script comment says.
Recommendation. None in code. Keep the operator step in the runbook.
I-11 — Rounding dust enters profit without a raise
Severity: Info
Confidence: 85
Origin: [phase1: precision-math]
Location: SABook._value — SABook.sol:314, SABook.sol:322-323; SALib.hwmFee — SALib.sol:386
_value floors idle base and each position's uncollected base fees separately, so a fee collect can raise nav by one raw USDC unit with contributed unchanged. The capped branch of hwmFee floors the charged gain, so two partial charges can exceed the uncapped fee by one unit. Repeated client collects floor k times in PoolManager and once in _feesOut. Each effect is at most 10⁻⁶ USD per event. Not exploitable.
Recommendation. None needed.
I-12 — A third-party registration at an untrusted anchor uses up the opening
Severity: Info
Confidence: 75
Origin: [phase1: dos, access-control]
Location: SABook.sync — SABook.sol:89-90, SABook.sol:121; LPManagerModule._register — LPManagerModule.sol:395-396
open is consumed whatever the price is. A third party who submits the client's delegation first while the anchor is untrusted (a 50 bps pool push is enough) makes the opening book nothing; for an account holding HYPE flowSeen is set and the first later booking raises hwm by the whole base value. This harms only the operator's fee, the class you accept, and it is the safe side of M-1. It is listed because it shows that the registrant decides between "no fee on the holdings for a long time" and "a fee on the anchor's lag". Separately, if a client signed two valid delegations and a third party registers the other one first, the relayer's register reverts NotOwnAccount and the client must replace it itself.
Recommendation. Covered by the M-1 fix (one opening rule for both anchors).
Leads
None. Every item that reached reconciliation had a complete trace or was merged into a finding above.
Task-by-task answers
Task 1 — the fee rule
Is profit after a booking ≥ true profit + e on every booking path? Yes for keeper sync, client / owner sync, the sync inside every module action, chargeFee's own sync and the first booking after an untrusted registration or a re-registration: all go through _sync → SABook.sync, and a priced booking always ends with hwm ≥ nav − contributed. The opening at a trusted anchor is the exception (M-1): it sets no mark at all.
Is there a price-dependent flow that a booking does not treat as priced?
A position dropped (not owned) or burned but still tracked: priced. At a trusted sync liq != old adds its whole book value to priced and drops it; at an untrusted sync _dirty sets flowSeen. A burn with snapshot above live stays tracked until that priced sync.
A liquidity change whose value rounds to 0: priced (s.flowSeen = true, SABook.sol:109).
Fees credited by _feesOut in the same sync: not always priced — L-1.
The module's own effect being inexact: we found it exact to the wei. _principal rounds up for adds and down for removals as PoolManager does, and picks the same branch at the tick edges; fees use the same formula on the liquidity before the change; swaps are booked from the executor record; transfers are verified at the recipient. A difference can come only from a hybrid account's own code inside the bracket (or stray native swept from PositionManager); it then becomes a priced flow of that same account, which only lowers the fee.
An idle-USDC-only difference after a base round trip: unpriced (I-1), inside residual (a).
The floor. hwm + priced ≥ hwm + e holds for every outflow of base or liquidity (the value at the flow is ≥ 0, so e ≤ the booked value) and for every inflow booked at no less than half its arrival price. For liquidity this follows from the position value being concave and increasing in price; a client's own add from idle and its own remove into idle reduce to the same rule. It holds above and below the mark. |lv − ov| errs on the safe side by at most 2 raw units. We re-ran round-7 M-1 and its variants (partial netting, deposit first, in-account round trip, liquidity round trip), the round-6 wick, the deposit in a spike and the first booking after registration: each is priced when any sync saw it or any unit differs, and the result is covered except inside residuals (a) and (b) and in M-1 and L-1.
Note on residual (b). After a priced booking the excess fee base is min(mark − true profit after the flows, e − priced) when both are positive. "At or above the mark" in your argument therefore has to mean the true profit, after the losing leg. Example: an account exactly at its mark H (USDC plus the flow only) receives 100 HYPE at 10 and sends 99 out at 8 before any booking. True profit is H − 200; booked profit is H; priced = 8; hwm = H + 8. A later real gain of 300 is charged on 292 where 100 is fair. This is inside your stated bound, but the account was not below its booked mark before the flows.
flowSeen. Only _bookIdle clears it (SABook.sol:160), and that call then always applies the raise unless open; a first registration resets it on fresh books (SALib.sol:290). A flow cannot be pending, seen by a sync and still booked as unpriced. Residual (a) is what is left, with the wider preconditions of I-1 and L-1.
The opening. Anyone holding the signed delegation can make it happen at an anchor below the market: M-1. hwm cannot stay at OPEN after the registration transaction (_register always syncs when register returns true, and SABook.sol:90 clears it at any price; a revert undoes the registration). A non-first registration cannot take the opening path (old != 0 returns false and never resets the books or flowSeen; delegationHash never returns to 0).
Reverts. None reachable. _nav cannot underflow (_value already includes hedgeEquity ≥ h − m); SafeCast.toInt256(priced) would need about 2²⁵⁵; liquidityValue cannot overflow below the 2¹¹² anchor cap; FullMath.mulDiv(d, n, 2¹²⁸) cannot overflow for n < 2¹²⁸; OPEN is cleared before any arithmetic. A sync, a removal, a margin return and an exit cannot be blocked by the rule.
Task 2 — round-7 fixes
L-2: fixed. Writers of approvedAt: SALib.sol:478 only. Writers of baseTime: SALib.sol:409 (first report, reachable once because lastPrice never returns to 0) and SALib.sol:431. Pause, setGuardian and _setParams only zero until; a stale approvedAt is never read because until becomes non-zero only together with a new approvedAt.
I-1: fixed (LPManagerModule.sol:743). A raised band leaves an open range narrower than twice the new band; in the constructor the old band is 0.
I-3: fixed. !paused in _trusted changes only the price _sync passes; every other user of _trusted was already whenNotPaused. Removals, margin returns, sync (mark only), register, deposit and revoke keep working. See L-2 for the unpause.
L-1: closed by removal for every flow after the opening: an outflow at an anchor walked up 10% has e = b(A − M) ≤ bA = priced; an inflow at an anchor walked down has e ≈ 0.1·bA ≤ bA. The opening inflow is not covered (M-1).
Task 3 — principal-loss hunt
No path found. USDC leaves an account through the module only in SALib.transferOut, to the two immutable recipients, with the amount verified at the recipient. PositionManager calls built by the module pay only the delegator; the SwapExecutor pays only its caller and its record is bound to the module's calldata. The enforcer rejects every other target, selector, recipient, action and plain value transfer, and its state changes only for the DelegationManager with the signed module as redeemer. Approvals are exact and reset in the same redemption. Hostile account code can change only its own books and can reach only revoke re-entrantly. The stolen-keeper bound is unchanged: (10 + 1.5 + 1.5)% × (50 + 100)% = 19.5% of nav per 24 h through swaps and adds, hedge sends to the treasury within the cap, plus the fee effects in M-1.
Exit: revoke (LPManagerModule.sol:382-389) is one storage write with no external call, no reentrancy guard and no pause. A 7702 client transacts directly. A hybrid client exits through EntryPoint.handleOps, which does not use the DelegationManager; that route was traced from the design document and from knowledge of Delegation Framework v1.3.0, not executed, because the framework source is not in the repository. returnHedgeMargin needs no redemption, no trusted anchor and no unpaused module.
Threat Model
Each row is an invariant the context phase named for the hunting phases to falsify.
#
Actor
What they can reach
Invariant that must hold
Verdict
T1
Client, any flows
direct transfers, direct liquidity changes, sync
every price-dependent flow is a priced booking; hwm after it ≥ profit after it and ≥ hwm + priced
Holds, except the fee-credit path — L-1
T2
Client, opposite flows in one interval
deposit / withdrawal, swap and liquidity round trips
a netted flow that any sync saw is still priced; only the exact unseen round trip remains
Holds for seen flows; the remainder is wider than stated — I-1, L-1
T3
Third party
native or USDC transfer in, deposit, pool trades
a donation cannot create a fee on principal
Invariant holds — a base donation is a priced inflow, a USDC one raises contributed; see I-1 for the gas refund
T4
Third party pushing the pool
_trusted, _checkPoolBand, feeGate
an untrusted interval leaves flows pending and marked
Invariant holds for bookings; liveness effects — L-3
T5
Relayer / delegation holder
first register / onboard
the opening happens only at a trusted anchor, once, for a first registration; hwm never stays at OPEN
Once-only and OPEN hold; the opening price is not protected — M-1, I-12
T6
Client re-registering after revoke
replace / resume path
a non-first registration never takes the opening path or clears flowSeen
Invariant holds — old != 0 returns false, books kept
T7
Honest keeper choosing moments
sync, module actions, chargeFee
the raise covers the phantom whatever the moment
Invariant holds inside the stated residuals; opening — M-1
T8
Stolen keeper
anchor walk, bookings and opening at a walked anchor, fee, swaps, adds, hedge sends
loss ≤ the stated 24 h bound; outflows covered at any anchor, inflows within 2×
Bound holds for swaps, adds, sends and non-opening flows; opening inflow not covered — M-1; unpause — L-2
T9
Stolen keeper
margin return, hedge report, margin send
return ≤ min(hedgeEquity, netMargin); equity rises only with the guardian
Invariant holds — SALib.sol:715-716, moveHedge approval path
T10
Guardian
pause, approvePrice, approveHedgeEquity, timelock cancel
pause blocks only bookings, swaps, adds, sends and fees
Invariant holds; range notes — I-2
T11
Owner (timelock)
setParams, role setters, unpause
params inside checkParams; no setter moves funds
Invariant holds; fee-rate change — I-3; unpause — L-2
T12
Hostile account code
redemption brackets, receive code, revoke
the snapshot moves only by the computed effect; a difference stays a flow of that account
Invariant holds — record, recipient and mint checks; batch gas — I-6
T13
Anyone
SwapExecutor.swap, enforcer no-op hooks, timelock receive
executor pays only the caller; enforcer state only for the DelegationManager and the signed module
Invariant holds
T14
Any party except the client
every path that moves tokens or NFTs out
destinations ∈ {pool, client, hedgeTreasury ≤ cap, feeRecipient ≤ fee}
Invariant holds — no path found; enforcer scope note — I-5
T15
Module / DelegationManager paused
—
revoke, direct withdraw and burn need no module state
Invariant holds; documentation — I-8
T16
Client / anyone
values that make sync revert
SABook.sync does not revert for any reachable state
Invariant holds — every revert site traced
T17
Deployer / first report
DeploySA.run, first reportPrice
the first report is bounded by the pool band; no registration before it
Invariant holds; notes — I-9, I-10; compiler — L-4
Invariant Verification
The inferred invariants of the pre-scan, each answered by the hunting phases. "On-chain" is the pre-scan's own reading of whether the code enforces the property.
ID
Property
On-chain
Verdict
I-1
hwm never decreases after the opening
Yes
holds — every writer raises or keeps it
I-2
hwm == OPEN exists only inside the first-registration transaction
Yes
holds — _register always syncs; SABook.sol:90 clears it at any price
I-3
flowSeen is cleared only by a booking that applies the raise
No
holds, with one exception by design: the opening clears a flag that register has just reset (see M-1)
I-4
contributed changes only with a simultaneous snapshot move
Yes
holds
I-5
the snapshot moves only by a booking, a fee credit or a computed effect
Yes
holds
I-6
a booking in which idle base changed in units is always priced
No
violated → L-1 (the credit moves snapBase first)
I-7
every price-dependent flow changes idle base or tracked liquidity in units at the booking
No
violated → I-1 (a swap round trip leaves only a USDC difference; inside residual (a))
I-8
the opening booking can happen only in the first registration's transaction
Yes
holds
I-9
at most 4 tracked positions per account
Yes
holds
I-10
at most one fee per feeInterval
Yes
holds — module and enforcer clocks written together
I-11
an open guardian range is never wider than 2 × the current band
Yes
holds — round-7 I-1 fix
I-12
after a consumed range baseTime is the approval time
Yes
holds — see I-2 for inclusion time
I-13
base / baseTime always reflect a guardian judgement
No
not enforced for the first report; no fee can use it (I-10) — holds in effect
I-14
the anchor moves at most one step per stable window inside the range and base bounds
Yes
holds in every branch of movePrice
I-15
fee = feeBps of the gain above hwm, capped at 20% of idle USDC
Yes
holds — dust only (I-11)
I-16
a booking happens only when _trusted()
Yes
holds — see L-2 for the unpause and M-1 for what _trusted does not cover
I-17
a module removal books at most min(requested, snapshot, live)
Yes
holds
I-18
a hedge send / return moves the hedge ledgers and the snapshot together
Yes
holds
X-1
the fee transfer is bounded by module and enforcer
Yes
holds
X-2
a hedge send is bounded by the module cap and the enforcer window
Yes
holds
X-3
the booked swap effect equals the executor record of the module's call
Yes
holds — count and calldata hash per payer
X-4
the effect computed before a PositionManager call equals what the call moves
No
holds for canonical account code (exact to the wei); a hybrid's own code can break it only for its own account, as a priced flow
X-5
SABook.sync gets a non-zero price only at a trusted anchor
Yes
holds — one call site, LPManagerModule.sol:784
X-6
a first registration is always followed by a sync in the same transaction
Yes
holds
X-7
USDC leaves through the module only to the two fixed recipients, verified
Yes
holds
E-1
no fee on principal from a booking-price phantom
No
violated → M-1, L-1 (plus the stated residuals)
E-2
funds leave only to {pool, client, hedgeTreasury, feeRecipient}
Yes
holds
E-3
the fee and booking price is within the anchor budget of a guardian-confirmed level
Yes
holds for fees; the opening price is not tied to the guardian level (M-1)
E-4
the fee is gated on a guardian confirmation at most one day old
No
holds in effect (I-10, I-2)
29 answered: 26 hold, 3 violated, 0 could not be verified.
Access-Control Inventory
46 state-changing external / public entry points in the source, 46 in the inventory (25 in LPManagerModule including the inherited acceptOwnership and the always-reverting renounceOwnership; 2 in SwapExecutor; 4 in the enforcer, three of them pure no-ops; 14 in VaultTimelock including inherited role and receive functions; DeploySA.run). Line numbers are from the in-scope files; rows marked (OZ) are inherited OpenZeppelin 5.4.0 behaviour. Every privileged or value-moving entry point was examined by at least one hunting agent; the access-control checklist walked all of them and found the guards as listed.
Entry points
LPManagerModule (src/sa/LPManagerModule.sol)
Function
Guard (line)
Who
State written
Value moved
register(d) :347
none in module; lastPrice != 0 :395; in SALib.register, replace / resume / pre-revoked slot needs msg.sender == a or owner (SALib :271-274)
anyone for a first registration; account or pinned owner otherwise
accounts[a], permissionContext[a]; first time also books via _sync :396
none
onboard(d,amount,permit) :355
none; kind == HYBRID :363; isActive :364; owner-signed EIP-2612 permit (SALib.pull :365)
anyone (relayer)
as register; snapAsset, contributed
USDC: pinned owner → its account
deposit(a,amount) :370
none; registered :372; amount ≠ 0 :373
anyone
snapAsset, contributed
USDC: msg.sender → account :374
revoke(a) :382
msg.sender is a, s.owner, or the EOA whose derived hybrid address is a :384
client
accounts[a].revoked
none
sync(a) :888
registered :890; msg.sender is keeper, a or s.owner :891
keeper / client
books of a (SABook.sync)
none
reportPrice(price) :407
onlyKeeper :407 (modifier :279-282); pool band :408
keeper
lastPrice, lastPriceMoved, lastReported, lastPriceTime, priceBudget
none
mintPosition(...) :428
onlyKeeper whenNotPaused :436; _checkKeeperPrice :437; _live :438
keeper
books, _positions, snapPos, turnover budget
account → pool (via DelegationManager)
increasePosition(...) :449
onlyKeeper whenNotPaused :456; _checkKeeperPrice :457; _live :458
keeper
books, snapPos, turnover
account → pool
decreasePosition(...) :467
onlyKeeper :470; _live :821
keeper
books, snapPos
pool → account
burnPosition(...) :477
onlyKeeper :480; _live :821
keeper
books, snapPos, _positions
pool → account
swap(a,...) :498
onlyKeeper whenNotPaused :501-502; _checkKeeperPrice :506; _live :507
keeper
snapAsset/snapBase, turnover / exit window
account ↔ pool via SwapExecutor
sendHedgeMargin(a,amount) :536
onlyKeeper whenNotPaused :536; anchor age :539; _live :540
keeper
hedgeEquity, netMargin, hedgeEpoch, books
USDC: account → hedgeTreasury :550
returnHedgeMargin(a,amount) :562
msg.sender is hedgeTreasury or keeper :563-564; registered :567
keeper / treasury
hedge ledgers, books (SALib.returnMargin :569)
USDC: hedgeTreasury → account
reportHedgeEquity(a,value) :576
onlyKeeper :576; registered :578
keeper
hedgeEquity, hedge epoch / clipped / time, hedge window
none
chargeFee(a) :601
onlyKeeper whenNotPaused :601; _trusted :602; _live :603; interval :607; feeGate :612
keeper
hwm, lastFeeTime, feesPaid, books
USDC: account → feeRecipient :618
multicall(data,allowFailure) :631
onlyKeeper :631; delegatecall to self :640
keeper
whatever the inner calls write
as the inner calls
approvePrice(lo,hi,until) :664
onlyGuardian :664 (modifier :284-287)
guardian
priceBudget range fields
none
approveHedgeEquity(...) :672
onlyGuardian :674; epoch / stored / TTL :677-680
guardian
budgets[a].hedgeApproved*
none
setPaused(p) :691
p != paused :692; true: guardian or owner :694; false: _checkOwner :698
guardian / owner
paused; on pause priceBudget.until, guardianEra
none
setKeeper(k) :705
onlyOwner :705; _distinct :706
owner
keeper
none
setGuardian(g) :711
onlyOwner :711; _distinct :712
owner
guardian, guardianEra, priceBudget.until
none
setParams(p) :719
onlyOwner :719; SALib.checkParams :742
owner
params, maybe priceBudget.until :743
none
transferOwnership(n) :729
onlyOwner inherited via super :731 (OZ); _distinct unless zero :730
owner
pendingOwner
none
renounceOwnership() :723
pure, always reverts :724
nobody
none
none
acceptOwnership() (OZ)
msg.sender == pendingOwner
pending owner
owner, clears pendingOwner
none
SwapExecutor (src/sa/SwapExecutor.sol)
Function
Guard (line)
Who
State written
Value moved
swap(...) :74 payable
nonReentrant :77; amount :80 and msg.value :82 checks
anyone
transient record keyed by msg.sender :93-100
input msg.sender → PoolManager (Permit2 or native); output → msg.sender; native refund :90
unlockCallback(data) :116
msg.sender == poolManager and guard entered :118
PoolManager, inside own swap
none of its own
Permit2 transferFrom(payer → PoolManager) :137; take to payer :141
ElysiumCustodyEnforcer (src/sa/ElysiumCustodyEnforcer.sol)
Function
Guard (line)
Who
State written
Value moved
beforeHook(...) :156
msg.sender == delegationManager :165; mode :166; redeemer == module from terms :168; target / selector allow-list :176-199
DelegationManager
_spend[delegator][keccak(terms)] hedge window and lastFeeTime (:336, :344)
none itself; gates the delegated execution
beforeAllHook :141, afterHook :146, afterAllHook :151
none; pure, empty body
anyone
none
none
VaultTimelock (src/VaultTimelock.sol)
Function
Guard (line)
Who
State written
Value moved
schedule :80
delay <= MAX_DELAY :88; onlyRole(PROPOSER_ROLE) in super :89 (OZ)
proposer
operation timestamp, isSelfOperation :90
none
scheduleBatch :93
:101; PROPOSER in super :102 (OZ); all-self or none :107-108
proposer
as above :109
none
execute :113 payable
_checkNotExpired :118; onlyRoleOrOpenRole(EXECUTOR_ROLE) in super :119 (OZ)
executor
operation marked done
ETH value timelock → target
executeBatch :122 payable
:129; EXECUTOR in super :130 (OZ)
executor
as above
ETH → targets
cancel(id) :151
self-operation needs PROPOSER :152; onlyRole(CANCELLER_ROLE) in super :153 (OZ)
canceller
deletes operation
none
updateDelay :73
msg.sender == address(this) :74; floor / cap :75
timelock itself
_delay
none
renounceRole(role,account) :139
reverts for PROPOSER / EXECUTOR :142; account == msg.sender in super (OZ)
role holder (canceller only, in practice)
role membership
none
grantRole / revokeRole (OZ)
onlyRole(getRoleAdmin(role)); admin is the timelock itself (constructor admin = address(0) :50)
timelock itself
role membership
none
receive() (OZ)
none
anyone
none
ETH → timelock
onERC721Received, onERC1155Received, onERC1155BatchReceived (OZ)
none; return selector only
anyone
none
none
DeploySA (script/DeploySA.s.sol)
Function
Guard (line)
Who
State written
Value moved
run() :127
chain id :128; _checkOwner (Safe threshold ≥ 2 unless ALLOW_EOA_OWNER) :112-124
broadcaster
deploys VaultTimelock, SwapExecutor, enforcer, module :186-189; create2 of canonical contracts
none
src/sa/vendor/DelegationFramework.sol holds interfaces and internal helpers only (:41-72, :88, :99), so it has no entry points. SARange and SAWindow are internal libraries.
Roles
Role
Granted / changed
Revoke, renounce, transfer
Unlocks
Timing
Module owner (= VaultTimelock, Ownable(c.owner) :223)
constructor
two-step: transferOwnership :729 then acceptOwnership; zero address cancels a pending transfer; renounce reverts :724
setKeeper, setGuardian, setParams, setPaused(true/false), transferOwnership
every call passes through the timelock delay
Keeper
constructor :273; setKeeper :705
one-step replace by owner; no renounce
all onlyKeeper rows, sync, returnHedgeMargin
instant; replacement timelocked
Guardian (module)
constructor :274; setGuardian :711
one-step replace by owner; bumps guardianEra, clears price range
approvePrice, approveHedgeEquity, setPaused(true)
instant; replacement timelocked
hedgeTreasury, feeRecipient
constructor :264-265
none
treasury: returnHedgeMargin; feeRecipient unlocks nothing
fixed; also bound into enforcerTermsHash :271
Client account / pinned owner
SALib.register writes s.owner (SALib :276) from a signed delegation
revoke :382; re-register to resume; DelegationManager.disableDelegation out of scope
revoke, sync, replace / resume register; owner's permit for onboard
instant, not pausable
Relayer
none (no stored role)
n/a
register (first), onboard, deposit
instant
DelegationManager
enforcer constructor :130; module :251
none
beforeHook
fixed
PoolManager
SwapExecutor constructor :59
none
unlockCallback
fixed
Timelock PROPOSER + EXECUTOR (operator)
constructor :50
grantRole / revokeRole by the timelock itself; renounce blocked :142
schedule(+Batch), execute(+Batch); proposer may cancel self-operations
scheduling instant; execution after _delay (24 h–30 d :33-34, :67-70), expires 7 d after ready :136; role changes timelocked
Timelock CANCELLER
guardian _grantRole :55; operator also (stock OZ constructor grants proposers CANCELLER; DeploySA asserts both :236-237)
timelock-only grant / revoke; may renounce
cancel (non-self operations unless also proposer :152)
instant
Timelock admin
none (address(0) :50)
n/a
n/a
n/a
All constructor role addresses are required distinct and non-zero (:231-237); setters repeat this through _distinct :734-739.
Pause behaviour
While paused
Functions
Revert (whenNotPaused :289-292)
mintPosition, increasePosition, swap, sendHedgeMargin, chargeFee
Work, with reduced effect
reportPrice (drift cap 0 :414), reportHedgeEquity (keeper cap 0 :581), sync and other _sync callers (price 0, since _trusted is false :784, :880)
Work unchanged
register, onboard, deposit, revoke, decreasePosition, burnPosition, returnHedgeMargin, multicall, approvePrice, approveHedgeEquity, owner setters, all VaultTimelock and SwapExecutor functions
isActive also reads delegationManager.paused() :312, an external pause the module does not control.
Unguarded (arbitrary caller)
LPManagerModule.register (first registration, or re-submitting the stored delegation as a no-op)
LPManagerModule.onboard (needs a valid owner-signed delegation and permit)
LPManagerModule.deposit
SwapExecutor.swap
ElysiumCustodyEnforcer.beforeAllHook / afterHook / afterAllHook (no-op)
VaultTimelock.receive() and the token-receiver hooks (OZ)
LPManagerModule.renounceOwnership (callable, always reverts)
DeploySA.run (script)
Process notes and limits
No target code was built or run. Audit policy forbids executing an untrusted target's build or tests, so no Foundry test was run or written into the repository, and the client's "275 passed" figure was not reproduced. Every proof in this report is a trace with numbers taken from the code. Coverage metrics are unavailable for the same reason. The repository has 277 test functions in 17 files; none is a stateful fuzz or invariant test of the smart-account books, and the fee rule's argument is quantified over all flow sequences. A Foundry invariant test over random flow sequences (hwm, flowSeen, contributed, with a shadow ledger at each flow's own price) is the natural next step.
Models. Context and breadth agents ran on Claude Fable 5.2; the 12 depth agents ran on Claude Opus 5.5, blind to the breadth findings. 12 of 12 depth lenses returned (math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, trust-gap, flow-gap). No agent was respawned.
Breadth routing. Eight checklists ran: general, precision-math, defi-amm, oracles, access-control, erc4337 (which also read the signatures checklist for the delegation and permit items), dos, chain-specific. The erc20, governance and flash-loan checklists were not run as separate agents because of the eight-agent cap; USDC handling and VaultTimelock were covered by the general, access-control and dos agents.
What rests on knowledge, not on source in the repository. MetaMask Delegation Framework v1.3.0 is present only as init code. Statements about DelegationManager.redeemDelegations, the hook order, HybridDeleGator and the EntryPoint.handleOps exit rest on the vendored interfaces and on knowledge of that release. Uniswap v4 and OpenZeppelin sources were fetched from the repository's own submodules and read.
Chain assumptions not verified in code: EXTCODESIZE 23 and EXTCODEHASH of the designator for a delegated EOA; ArbOS support for PUSH0, transient storage, MCOPY and EIP-7702; the 24,576-byte code limit; an honest sequencer clock; 18 decimals for native HYPE; a client's ability to force its own transactions through the parent chain.
Severity of M-1. The agents that raised it rated it between Low and Medium. This report uses Medium for the reasons given in the finding; the bounds are stated there so you can weigh it yourself.
Earlier rounds. The repository contains the reports of earlier audit rounds (docs/audit/, jobs 1224 to 1255). This audit is an independent run: every finding above comes from this job's own context map and its own 20 hunting agents at commit 3f0f42d.
This review was performed by AI agents. It cannot prove the absence of vulnerabilities, and it is not a guarantee of security. An independent human review, a bug bounty and on-chain monitoring are recommended before funds beyond the pilot are placed under this code.
    Canonical copy: this is a styled rendering of the immutable report delivered on IPFS —
       https://bafkreiae6du7jt44k63hbeboufcu4edb4mmyqrdywzellhs7j7v2cwqury.ipfs.community.bgipfs.com/.
       If the two ever differ, the IPFS copy is authoritative.
    Audited by LeftClaw Services 🦞 — job
       #1256 on Base. Rendered 2026-11-18.
