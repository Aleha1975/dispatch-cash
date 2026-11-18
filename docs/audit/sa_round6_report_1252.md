<!-- Plain-text rendering of LeftClaw job #1252 (HTML original; the IPFS copy is authoritative). -->


Elysium LP smart accounts — audit round 6 (LeftClaw job 1252) — LeftClaw Services
      🦞
      LeftClaw Services
      ·
      Smart Contract Audit
    Elysium LP smart accounts — audit round 6 (LeftClaw job 1252)
    Job #1252 · completed on-chain · report pinned to IPFS
      Job page #1252
      Canonical report IPFS
      Generated 2026-11-18
      1
Medium
      4
Low
      14
Info
    Contents
      1. The answer asked for first
      2. Task 1 — Round-5 fix verification
      3. Findings
      4. Task 2 — Principal-loss hunt
      5. Task 3 — Accepted residuals and new trade-offs
      6. Reconciliation summary
      7. Access-Control Inventory (from the phase-0 map; findings-free)
      8. Threat Model (actor × entry point × asset)
      9. Invariant Verification (x-ray catalog)
      10. Methodology notes and disclosures
Elysium LP smart accounts — audit round 6 (LeftClaw job 1252)
Fix verification before the pilot · principal-loss hunt
Repository
https://github.com/Aleha1975/dispatch-cash (branch elysium-lp-sa)
Commit (pin)
0fe4d856284d47e2ce9a9d5c60e4f4480df9ca56. Verified reachable: git ls-remote shows it as the head of refs/heads/elysium-lp-sa. The round-6 change is git diff 30aae1e 0fe4d856.
Scope
src/sa/SABook.sol, src/sa/SALib.sol, src/sa/LPManagerModule.sol, script/DeploySA.s.sol (changed); src/sa/SARange.sol, src/sa/SAWindow.sol, src/sa/SwapExecutor.sol, src/sa/ElysiumCustodyEnforcer.sol, src/sa/vendor/DelegationFramework.sol, src/V4PositionMath.sol, src/VaultTimelock.sol (unchanged, in scope). The pooled vault is out of scope. 11 files, 2,469 nSLOC.
Chain
Elysium mainnet, chain id 99901 (Arbitrum Orbit / Nitro). Not deployed.
Method
Four-phase pipeline (deep-audit v3): x-ray pre-scan, then a context map (3 agents), then breadth (8 ethskills checklist agents), then depth (12 pashov V4 attack agents, blind to the breadth findings), then reconciliation with a coverage gate. 23 sub-agents in total.
Model
Every sub-agent (context, breadth and the 12 attack agents) and the orchestrator ran on Claude Opus 5.5 (claude-opus-5-5). The pipeline names Fable for the context and breadth phases, but Fable capacity was not available, so Opus replaced it. Nothing else changed.
Date
2026-11-18
Severity counts: 0 Critical · 0 High · 1 Medium · 4 Low · 14 Informational
1. The answer asked for first
Is there a principal-loss path for a pilot of about USD 250 at DeploySA.pilotParams?
No outside party can move principal. We found no path by which anyone (third party, relayer, keeper within or beyond its bounds, guardian or timelock) sends client funds to an address other than the account, the fixed pool, hedgeTreasury or feeRecipient. No path blocks the client's exit. revoke makes no external call and is not pausable. Direct actions on the account do not depend on the module or the DelegationManager. All 20 sub-agents agree on this.
One Medium remains, and it is a fee on principal:
M-1. The round-5 M-4 fix measures the late-booking adjustment from bookPrice, the anchor of the last priced sync. It does not measure from the price at which the flow happened. When the anchor goes out and comes back while a client flow is pending, the adjustment is zero or too small. The fee is then charged on principal.
Who can trigger it. It needs no attacker. A client moves HYPE while the anchor is untrusted (a fast market, a pause, or a pool more than 50 bps off), and the market returns before the booking.
Size. About feeBps × |flow| × |market at flow − anchor at booking|, charged once. At USD 250 that is a few dollars at most.
Agreement. 9 of the 12 attack agents and the precision-math checklist reached it independently.
Four Lows state residuals that the code does not enforce as written:
Residual 2 has an extra room source (L-1).
The first booking after registration gets no adjustment (L-2).
Residual 5 is understated against the market (L-3).
The keeper chooses the "confirmed level" inside a guardian range (L-4).
Each is bounded and small at pilot size. With the pilot rule kept ("nobody modifies tracked NFTs directly") and the guardian bot live, we see no material principal risk for the pilot. We recommend fixing M-1 before third-party clients.
2. Task 1 — Round-5 fix verification
Round-5 item
Status
Evidence
M-1 dip and restore credits principal as yield
Partly fixed
The report's traces are closed (details below). Residual 2 is not bounded as stated: see L-1.
M-2 anchor walk with no persistent reference
Fixed
Only movePrice writes base, at the first report (SALib.sol:395) and when a guardian range is consumed (SALib.sol:416). _bounds folds base into lo/hi, so up ≤ base·(1+cap) and dn ≥ base/(1+cap). By induction the keeper alone keeps the anchor within refDriftBps of base over any number of days. Checked: pause (cap 0, frozen), long gap, lowered cap (it can freeze the anchor but never moves it out; see I-4), first report, and the guardian branch clipped and unclipped. The one caveat is that the keeper picks base inside the guardian's range: see L-4.
M-2 LP term (charge = principal)
Fixed
SABook.sol:277 has charge = paid;, charged in _add before _modify. Checked one-sided ranges next to a pushed pool, add/remove round trips, and removals at a pushed pool. A removal can only gain at market prices. Residual 7 holds relative to base.
M-3 fee gate low follows a walked anchor
Fixed for the stated question
feeGate (SALib.sol:442-445) uses min(24 h low, base), so a fee is never measured more than poolBandBps above base. Residual 5 is understated against the market: see L-3.
M-4 flow booked late at a moved anchor
Partly fixed / not fixed for round trips
Every priced sync writes bookPrice (SABook.sol:122). Positions that are dropped are counted in priced. For base and for liquidity (concavity of liquidityValue), the adjustment is ≥ the phantom relative to bookPrice in both directions, with Ceil rounding. But the reference is wrong whenever the flow happened at a third price: see M-1. The first booking after registration has bookPrice == 0: see L-2. A re-registration after a revoke keeps bookPrice and only over-adjusts (fee lower). Overflow: the int256 cast is unchecked (I-9) and unreachable with real numbers. A large hwm blocks only the fee.
L-1 dust defers the fee
Fixed for the target case
SABook.sol:114 compares against 1% of `
L-2 G mark moves at every sync
Fixed
_mark (SABook.sol:177-185) moves G only when g moves, and book takes both. The guard can only get stricter. A small residual remains for a second client collect (I-14), fee-only.
L-3 third party picks the booking moment
Fixed for sync()
LPManagerModule.sol:883 restricts the caller. The client can still always book its own flow: a 7702 EOA through msg.sender == a, a hybrid through its pinned owner or the account, also while revoked or not live. The anchor must be trusted. A third party can still decide whether a keeper path prices a booking by moving the pool into the 50 bps band (I-2).
L-4 parameter product, stable floor
Fixed
checkParams (SALib.sol:348-355) is called from _setParams, which both the constructor and setParams use. The word order matches Params. The pilot product is 1300 × 15000 = 19.5% ≤ 40%. minPriceStable ≥ 300.
I-1 guardian range width
Partly fixed (as the response says)
approvePrice (SALib.sol:451) enforces ≤ 10% width, lo > 0 and a TTL of ≤ 1 day. The 10% width now also bounds where the keeper can place base: see L-4.
M-1 traces retried, as asked. The final code closes each of these:
Dip and restore at another price. Blocked by if (ra < 0 || rb < 0) return; (SABook.sol:164).
Dip spanning an unpriced look. Blocked by seen (SABook.sol:144, written by _mark at every look).
Shared-upper-tick re-base, and a client that empties a position and refills it. These pass the global guard more easily now that G spans the whole interval since the last g move. The credit is still capped by real idle room in both tokens, so harm needs principal room (L-1 or a top-up).
Donation. It raises d and ΔG together, so it only amplifies a client-started case.
Residual 2(b), real fees in one token larger than the mix deficit. This is over-credit compared with what PoolManager paid, but it is not a fee on principal. The credited value is ≤ the real idle gain (fees plus the convex mix gain).
Residual 2(a), a raw top-up in the same interval. Confirmed as stated.
Does L-2 widen the window?
A module book takes g and G together.
A burned position that stays tracked has owned = false, so n = 0, and is dropped.
A dropped position cannot be tracked again (only mintPosition with nextTokenId adds one).
Token ids are not reused.
So the only widening is the long-interval re-base above, and it is bounded by room.
3. Findings
M-1 — The M-4 adjustment measures from bookPrice, so a flow booked after an anchor round trip pays a fee on principal
Severity: Medium · Confidence: 85 · Origin: [both]: phase 1 precision-math; phase 2 agents 1, 3, 5, 7, 9, 10, 11 (findings), 4, 6 (leads)
Location: SABook.sync, src/sa/SABook.sol:115-122; consumed by LPManagerModule.chargeFee (src/sa/LPManagerModule.sol:597-619)
// SABook.sol:115-122
uint256 p0 = s.bookPrice;
if (priced != 0 && p0 != 0 && p0 != price) {
    // forge-lint: disable-next-line(unsafe-typecast)
    s.hwm += int256(
        Math.mulDiv(priced, price > p0 ? price - p0 : p0 - price, Math.min(price, p0), Math.Rounding.Ceil)
    );
}
s.bookPrice = price;
Root cause. The adjustment covers only a flow that happened at the anchor of the account's last priced sync. The NatSpec says so: "it may have happened at the earlier anchor". A pending flow can happen at any price between two priced syncs. If the anchor goes p0 → px → p0, or ends nearer p0 than the flow price was, the adjustment is zero or too small. Two directions raise the fee: base or liquidity withdrawn while the price is low and booked higher, and base deposited while the price is high and booked lower. The NatSpec claim "a late booking can only lower the fee" (SABook.sol:66-69, rule D at LPManagerModule.sol:59-61) is therefore false. Residual 4 ("covered by M-4") does not hold either.
Trace (honest operator, pilot params, feeBps 1500; agent 5's hand trace, re-walked against the code):
The keeper syncs the account at anchor 100, so bookPrice = 100. The account holds 1,000 USDC and 10 HYPE, contributed = 2,000, hwm = 0.
The market wicks to 70. The anchor moves at most one band (1.5%) per 300 s and never below base/1.1. The pool is more than 50 bps from the anchor, so _trusted() is false. _sync passes price 0 and the client's own sync(a) reverts StalePrice.
The client takes its 10 HYPE out at 70 (real outflow: 700).
The market returns to 100 and the anchor is trusted at 100 again. The next keeper _sync books fb = −1,000. p0 == price, so hwm += 0. contributed = 1,000 and nav = 1,000, so booked profit is 0. Real profit is −300.
The account earns 300 of LP fees. Real profit is now 0, booked profit is 300. After pricedFlowTime + 1 day, chargeFee takes 45 USDC of principal to feeRecipient.
Variants.
Partial round trip (flow at 30, p0 40, booking at 36): the adjustment uses 4/36 but the phantom is 6/36. (Agents 1, 9.)
Deposit in a spike, booked after the return (agents 3, 7). Example: HYPE deposited at 34 and booked at 30 = bookPrice; the market later returns to 34. Fee 60 USDC on a 3,400 deposit.
A keeper that stops reporting makes _trusted fail after 300 s and so chooses the booking moment. A stolen keeper can also reset bookPrice with a zero-flow priced sync at a walked anchor, then book a later client flow at that same anchor (agent 4). Both turn the same gap into an intentional path. The fee still goes only to feeRecipient.
Bound. feeBps × |flow| × |price at flow − booking anchor|, once per HWM level. It is not limited by 50 bps, and not by refDriftBps either, because the market price during an untrusted period is not bounded by the anchor envelope. The one-day pricedFlowTime wait delays the fee but does not remove it. At pilot size: a few USD.
Fix. Two different fixes were proposed. Both only raise hwm, so the cost is a lower operator fee, which the client accepts.
Fix (Option A — anchor range since the last priced sync). Agents 7, 11 and the precision checklist.
-        uint256 p0 = s.bookPrice;
-        if (priced != 0 && p0 != 0 && p0 != price) {
-            s.hwm += int256(
-                Math.mulDiv(priced, price > p0 ? price - p0 : p0 - price, Math.min(price, p0), Math.Rounding.Ceil)
-            );
-        }
+        uint256 p0 = s.bookPrice;
+        if (priced != 0 && p0 != 0) {
+            // lo / hi: every anchor value since the last priced sync (module passes _bounds(priceBudget, lastPrice),
+            // widened to base*(1+cap)^±1 when bookTime is older than the 24 h range or a guardian reset happened)
+            if (p0 < lo) lo = p0;
+            if (p0 > hi) hi = p0;
+            uint256 d = Math.max(hi - price, price - lo);
+            if (d != 0) s.hwm += SafeCast.toInt256(Math.mulDiv(priced, d, lo, Math.Rounding.Ceil));
+        }
Fix (Option B — reported / pool price extremes during untrusted periods). Agents 5 and 10. Option A misses a spike above the highest anchor (agent 7's lead). Option B records the lowest and highest lastReported (each report is within poolBandBps of the pool) since the account's last priced sync, and sizes the raise from the largest gap to the booking price:
+    // module storage: global (minReported, maxReported, epoch) reset at every priced sync of an account (per-account
+    // copy of the epoch), updated in reportPrice; SABook.sync receives them
-        if (priced != 0 && p0 != 0 && p0 != price) {
+        if (priced != 0 && p0 != 0) {
+            uint256 lo = Math.min(p0, minReported);
+            uint256 hi = Math.max(p0, maxReported);
+            uint256 d = Math.max(hi - price, price - lo);
+            if (d != 0) s.hwm += SafeCast.toInt256(Math.mulDiv(priced, d, Math.min(lo, price), Math.Rounding.Ceil));
+        }
If neither is taken: restate residual 4 as "≤ feeBps × |flow| × the market move during an untrusted period". Also add a keeper duty: price-sync every account the moment the anchor becomes trusted again, and skip the fee for an account whose priced flow was booked after an untrusted gap.
L-1 — Residual 2 has another room source: the principal of a second tracked position the client changed in the same interval
Severity: Low · Confidence: 70 · Origin: [phase1: general], confirmed on re-read
Location: SABook.sync / _feesOut / _credit, src/sa/SABook.sol:87, :144-152, :161-168
// SABook.sol:162-166
int256 ra = int256(IERC20(v.asset).balanceOf(a)) - s.snapAsset;
int256 rb = int256(_bal(v.base, a)) - s.snapBase;
if (ra < 0 || rb < 0) return;
// forge-lint: disable-next-line(unsafe-typecast)
s.snapAsset += int256(_cap(ca, ra));
Root cause. _credit takes its room from live idle balances above the snapshot. That idle also holds the pending principal of a different tracked position B that the client decreased or burned directly in the same interval. B's outflow is booked separately in the same loop (f += int256(lv) - int256(ov), SABook.sol:94). When A's credit uses up the room, the idle that should offset B's outflow is gone, and B's outflow is booked as a withdrawal. The per-position credit L × Δg also uses the growth earned by the remaining range liquidity during A's dip. The client's own swaps or a donation inside the dip can raise it. It is capped only by L × ΔG_global, not by "what full liquidity would have earned".
Trace (re-checked against the code). A ($5,000, 90% of its range) and B ($3,000) are tracked. In one 7702 batch between two keeper looks, the client:
decreases A to ε;
makes about $20k of in-range round trips (fee $60, almost all to the other 10%);
restores A exactly;
halves B directly.
At the next sync, B gets n = 0 and f −= 1,500. A passes seen == liq == old and earns credit L_A·60/o ≈ $540. The room is positive in both tokens, so the whole $540 is credited. contributed falls by $540 while nav does not change. After one day, chargeFee takes about $81 of principal.
What limits it. Only the client's own direct action on its own NFTs starts it (onlyIfApproved). It costs the client the swap fees. It is excluded by the pilot rule.
Fix. Credit nothing in a sync where any tracked position is pending:
     ) external {
         int256 f;
         uint256 priced;
+        bool clean = true;
+        for (uint256 j; j < ps.length; ++j) {
+            (uint128 l, bool o) = _liquidityOf(v.posm, a, ps[j].tokenId);
+            if (!o || l != pos[ps[j].tokenId].liq) { clean = false; break; }
+        }
         uint256 i = ps.length;
 ...
-            _feesOut(s, q, v, a, p, owned && liq == old ? old : 0);
+            _feesOut(s, q, v, a, p, clean && owned && liq == old ? old : 0);
Also restate residual 2: the bound is L × the position's own mark growth (≤ L × global growth), and the room may come from a raw top-up, an untracked position or any tracked position the client changed in the interval.
L-2 — The first priced sync after registration books all holdings with no late-booking adjustment
Severity: Low · Confidence: 75 · Origin: [phase2: agent 8], confirmed on re-read
Location: SALib.register, src/sa/SALib.sol:273-279; SABook.sync, src/sa/SABook.sol:115-116
// SALib.sol:273-279
if (old == 0) {
    s.lastFeeTime = block.timestamp;
    s.snapAsset = 0;
    s.snapBase = 0;
    s.contributed = 0;
    s.hwm = 0;
}
Root cause. The first registration resets the books but never sets bookPrice. The first priced sync therefore has p0 == 0 and skips the M-4 branch. That sync is the one that books everything the account held at registration (a 7702 EOA, or a hybrid already funded with HYPE), so the largest flow is the one left without an adjustment.
Trace. 1,000 HYPE and 20,000 USDC are registered at anchor 100. The anchor stays untrusted, or the keeper books late, and the first priced sync runs at 92: contributed = 112,000, no hwm raise. The market returns to 100. After feeInterval, chargeFee sees profit 8,000 and takes 1,200 USDC (cap 4,000). The account's value is the same as at registration. With p0 = 100, the existing branch would add 8,000 to hwm and the fee would be 0.
Fix (module bytes permitting, 479 B margin):
     function _register(Delegation calldata d) internal {
         if (lastPrice == 0) revert NoAnchor();
-        SALib.register(accounts, permissionContext, d, _expect());
+        if (SALib.register(accounts, permissionContext, d, _expect()) && accounts[d.delegator].bookPrice == 0) {
+            accounts[d.delegator].bookPrice = lastPrice;
+        }
     }
(Or set it inside the old == 0 branch of SALib.register, which would need lastPrice passed in.) Option A or B of M-1 covers this case too.
L-3 — Residual 5 is stated against the confirmed level; against the market a stolen keeper can put a fee up to about (refDriftBps + poolBandBps) of exposure on principal
Severity: Low · Confidence: 70 · Origin: [phase1: oracles], confirmed on re-read
Location: SALib.feeGate, src/sa/SALib.sol:442-445; LPManagerModule.chargeFee, src/sa/LPManagerModule.sol:607-612
// SALib.sol:443-444
(uint256 lo,) = _bounds(b, ref);
if (ref > pool || ref * BPS > lo * (BPS + bandBps)) revert StalePrice();
Root cause. base changes only when a guardian range is consumed. If the market drifts down by less than refDriftBps after a confirmation, nothing forces a new confirmation, and base stays above the market. The gate bounds the fee anchor against base, not against the market.
Trace. Guardian confirms base = 100. The market drifts to 91 over a week; the honest anchor follows. A stolen keeper then:
walks the anchor back to 100 (seven reports with pool pushes);
holds it for about 27 h, so the 24 h low becomes 100;
re-reports and waits 300 s;
pushes the pool to just above 100 and calls chargeFee.
_trusted and feeGate pass. On 5 HYPE plus 545 USDC with contributed = 1,000, the fee is 6.75 USDC, all phantom. Residual 5's formula gives about 0.10. The worst case is an anchor at base × 1.015 with the market at base/1.1: a phantom of about 11.6% of exposure, so a fee of about 1.75% of exposure, once per HWM level.
What limits it. A stolen keeper, a day or more of holding the anchor against the guardian bot's anchor/HL gap pause, and pool pushes. The fee goes to feeRecipient, not to the attacker.
Fix. Restate residual 5 with the distance of the market below base. Or, matching the go-live item "confirm before each weekly fee run", require a recent confirmation:
 struct PriceBudget { ...
     uint256 base;
+    uint256 baseTime;
 ...
-            b.base = p;
+            b.base = p; b.baseTime = block.timestamp;   // both at ref==0 and in the guardian branch
 ...
 function feeGate(...) external view {
     (uint256 lo,) = _bounds(b, ref);
-    if (ref > pool || ref * BPS > lo * (BPS + bandBps)) revert StalePrice();
+    if (ref > pool || ref * BPS > lo * (BPS + bandBps) || block.timestamp > b.baseTime + 1 days) revert StalePrice();
 }
L-4 — The keeper, not the guardian, chooses the "confirmed level" inside a guardian range of up to 10%
Severity: Low · Confidence: 75 · Origin: [both]: phase 1 oracles (I-3), access-control (I-3); phase 2 agents 3, 6, 10, 11 (leads)
Location: SALib.movePrice, src/sa/SALib.sol:414-421; SALib.approvePrice, src/sa/SALib.sol:451
// SALib.sol:414-416
if (block.timestamp <= b.until && p >= b.lo && p <= b.hi) {
    b.until = 0;
    b.base = p; // SA-5 M-2: the guardian confirmed this level
Root cause. The guardian approves a range, not a level. The first keeper report inside the range becomes base. The only other limit on that report is _checkPoolBand (1.5% of a pool the keeper can push for about USD 700). If the report is clipped, it is applied unclipped and the 24 h history is reset. Every "absolute" bound (residual 7, residual 5, M-2, M-3) is then measured from a point the keeper chose, up to 10% from the guardian's lo.
Trace. Market 30. The guardian approves [28.6, 31.4] (about ±5%). A stolen keeper pushes the pool to about 29.0, reports 28.6 (becomes base), and walks to base/1.1 = 26.0, 13.3% under the market. Sales then run at about 25.2, 16% below market (residual 7 states 13% from the level). At pilot turnover this gives about 24% of value per day against the stated 19.5%. With the runbook's ±0.5% ranges, the excess is about 0.5%.
Fix. Tie the on-chain width to the runbook (or pass a target level):
-        SALib.approvePrice(priceBudget, lo, hi, until, MAX_APPROVAL_TTL, 2 * MAX_POOL_BAND_BPS); // SA-5 I-1: <= 10% wide
+        SALib.approvePrice(priceBudget, lo, hi, until, MAX_APPROVAL_TTL, 2 * params.poolBandBps); // <= 3% at pilot
At minimum, state in residual 7 that the confirmed level is "any point of the guardian's range the keeper reports".
Informational
#
Severity
Title
Location
Note
I-1
Severity: Info
Hostile account code can sandwich another account's keeper action inside one multicall
LPManagerModule.multicall (LPManagerModule.sol:626)
Inside account A's bracket, A's code can PM.unlock and move the pool for account B's next item. B's loss is bounded by maxSlippageBps and BOOK_BAND_BPS, the same as public MEV but atomic. The NatSpec contradicts itself ("multicall over many accounts", L75, against "the keeper batches one account per transaction", L625). Make one account per multicall the rule, or enforce it. [phase1: smart-account], phase 2 agents 2 and 12.
I-2
Severity: Info
A third party can still decide whether a keeper path prices a booking
LPManagerModule._sync (:776-778) via reportHedgeEquity, returnHedgeMargin, decreasePosition, burnPosition, sendHedgeMargin
These paths have no _trusted gate of their own. A pool push into the 50 bps band just before a keeper call books a pending flow at a lagging anchor (≤ about 150 bps). hedgeTreasury can also force a priced booking through returnHedgeMargin(a, 1). Suggested change: sync with price 0 in non-trusted-gated paths. Agent 12 lead; [phase1: access] I-1.
I-3
Severity: Info
The 24 h windows and the client's exit rely on the honesty of the Elysium sequencer
SAWindow.sol:24, SALib.useTurnover (:514-522), LPManagerModule.revoke
A skewed timestamp (Orbit default window: −24 h / +1 h) can let a stolen keeper use two windows within minutes (about 2 × 19.5%). Censorship delays revoke and pause until forced inclusion. Document the sequencer operator, maxTimeVariation and the delayed-inbox revoke path, and have the guardian bot pause on timestamp skew. [phase1: chain-specific]
I-4
Severity: Info
After refDriftBps is lowered, the anchor can stay frozen until the guardian acts
SALib.movePrice (:399-412)
Before round 6, the range aged out after about 27 h. Now base never ages out, so dn > up can hold until a guardian range is consumed. This blocks booking, swaps, adds and fees. Exit, removals and returns are not affected. Add it to the go-live list (confirm when the cap is lowered). [phase1: oracles]
I-5
Severity: Info
The hedge cap rises with a walked anchor and a pushed pool
LPManagerModule.sendHedgeMargin (:542-546)
cap = hedgeCapBps × min(V@ref, V@pool) with no _trusted gate. A stolen keeper can send about 36.75% of market value instead of 35%, to hedgeTreasury only. Agent 5 lead.
I-6
Severity: Info
Keeper and guardian together can write netMargin down and re-arm the hedge cap
SALib.moveHedge (:480-483)
An approval of 0 plus a keeper report sets h = m = 0. The cap is then a rate, not a total. Within the trust model (two roles); noted for completeness. [phase1: access]
I-7
Severity: Info
Hybrid ERC-1271 checks the raw hash, so a Permit2 permit the owner EOA signs is also valid for the account
registration relies on account ERC-1271 (SALib.sol:179)
It cannot be used today: the module resets the ERC-20 → Permit2 allowance in the same redemption (SALib.sol:645-652, :678-679). Add to the runbook: no standing Permit2 allowance on the account, and no Permit2 permits from the owner EOA for tokens the account holds. [phase1: smart-account]
I-8
Severity: Info
The L-1 threshold uses net contributed, so dust still defers the fee when it is close to 0
SABook.sol:114
Operator's fee only. Compare against `max(
I-9
Severity: Info
Unchecked int256 cast of the hwm adjustment
SABook.sol:118-120
Unreachable with real numbers. Use SafeCast.toInt256. [phase1: precision]
I-10
Severity: Info
Residual 7's per-24 h figure is measured on nav at the anchor; LP adds charge base at the anchor only
LPManagerModule._add (:801-805), SABook.lpAdd (:274)
Against market value the daily bound is about 19.5% × 1.1 ≈ 21.5%. swapBounds charges a sale at max(keeper price, anchor), but lpAdd charges at the anchor only (up to band × base leg). Documentation precision. [phase1: amm]; agent 8 lead.
I-11
Severity: Info
The old pinned owner keeps sync and revoke after a hybrid owner change
LPManagerModule.sol:883, :384
The module is not live after the change (SALib.live), so this has no fee or principal effect. A client who rotated a leaked key should know about it. [phase1: smart-account, access]
I-12
Severity: Info
A stolen keeper can lower the hedge equity of a revoked account
LPManagerModule.reportHedgeEquity (:573-583)
It checks only delegationHash != 0. A lower h lowers the keeper's return cap min(h, m); the treasury can still return the margin. Agent 2 lead.
I-13
Severity: Info
Anyone can register a signed delegation the client did not submit
SALib.register (:248-282)
If the client signed two delegations, a third party picks which one is stored (for example the later expiry). The client can revoke or replace it. Agent 2 lead.
I-14
Severity: Info
Wording of residuals 1 and 2
SABook._mark (:177-185), _feesOut (:144-152)
(a) A second client collect after a sync can still be voided (the G interval starts at the next look, not at the collect); operator's fee only. (b) A client that empties a position (both ticks cleared) and refills it can pass the re-base guard on a new growth basis; stays within L × ΔG and room. Name both in the residuals. [phase1: general, amm]
Leads considered and closed: SALib.hwmFee partial-charge rounding (a few raw units, no compounding; [phase2: agent 1]).
4. Task 2 — Principal-loss hunt
Question
Verdict
Destinations
Holds. The module builds every execution. The client-signed enforcer limits targets to PositionManager (MINT owner, TAKE_PAIR and SWEEP recipients = delegator; native value only with a final native SWEEP), SwapExecutor (payer = recipient = account), Permit2 / ERC-20 approvals to those two spenders only, and USDC transfers to hedgeTreasury (35% of idle per sliding 24 h) and feeRecipient (20% of idle per 7 days). Note: the enforcer alone does not bound value given to the pool (any swap limit, any ticks). That bound is the module's.
Restated stolen-keeper bound (residual 7)
Holds relative to base (fix verification M-2). Against the market it adds the distance of base from the market, which the keeper partly chooses (L-4), plus I-10 (nav at the anchor) and I-3 (chain time).
Fee-after-push bound (residual 5)
Holds relative to base. Understated against the market (L-3).
M-4 adjustment
≥ phantom relative to bookPrice, in both directions, for base and liquidity. Wrong reference for round trips (M-1) and absent on the first booking (L-2).
Margin-return bound
Holds: keeper ≤ min(hedgeEquity, netMargin) (SALib.sol:693-694). Treasury returns only add to the account. See I-6 and I-12.
Client exit with module and DM paused
Holds. revoke (LPManagerModule.sol:382-389) has no external call, no pause check and no reentrancy guard. Every keeper path then reverts NotLive except the books-only paths and returnHedgeMargin, which moves treasury → account. Removals need no trusted anchor and no unpause. A 7702 EOA exits with self-calls. A hybrid exits through its owner or through EntryPoint.handleOps, which does not depend on the DM pause. DelegationManager.disableDelegation stays callable while the DM is paused (see the methodology note). No test covers the hybrid handleOps exit or disableDelegation while the DM is paused; we recommend adding one.
Guardian dependency
It cannot block an exit or move principal. While no confirmation is given, it blocks booking, swaps (including the risk-off sale), adds and fees. One exception that reaches principal: a stale base above the market allows a fee there (L-3).
5. Task 3 — Accepted residuals and new trade-offs
Residual (round-5 response)
Bounded as stated?
Can it reach principal?
1. Fees of a changed position become a contribution
Yes. Wording refinement in I-14.
No (operator's fee only).
2. Dip and restore between two looks
No. Another tracked position's pending principal is also room (L-1), and L × growth is the position's mark growth (≤ global), not what full liquidity would have earned. Case (b), fees above the mix deficit, is not a principal path.
Yes, only through the client's own direct NFT actions (L-1).
3. Client timing inside the 50 bps band
Yes.
No.
4. Keeper booking at the band edge, "covered by M-4"
No. M-4 does not cover a flow made at a third price (M-1).
Yes (M-1).
5. Fee after a pool push
Relative to base, yes. Against the market, no (L-3).
Yes, with a stolen keeper (L-3).
6. Fee deferral
Yes.
No.
7. Stolen-keeper bound
Relative to base, yes. base is keeper-chosen inside the guardian range (L-4). Nav at the anchor adds about 10% (I-10). Sequencer time (I-3).
Yes, within the stated destinations and bound (by design).
8. Liveness
Yes. New: a lowered cap can freeze the anchor (I-4).
No.
9. Risk-off in a fast market
Yes.
No (market exposure only).
10. LP capacity
Yes.
No.
11. Unchanged items
Yes.
As in earlier rounds.
New guards and liveness:
Both-token rule, seen: they only void credit, so they can only lower the fee. No liveness effect.
Confirmed level: fails closed for trades and fees. It can freeze after a lowered cap (I-4). It never blocks an exit.
1:1 LP charge: capacity only (residual 10).
Sync restriction: the client can always book its own flow while the anchor is trusted. A gasless relayer can no longer book for the client (UX only).
6. Reconciliation summary
Overlap: 2 · Phase-1-only: 13 · Phase-2-only: 4 · Re-examined leads kept: 7, demoted: 1 (hwmFee rounding) · Coverage holes closed: 0 · Invariants: 15 answered (10 hold, 4 violated, 1 unverified).
Reporting floor: Low and above. Confidence < 50 goes to leads; none of the reported items is below 60.
Agents: phase 2 had 12/12 attack agents return on the first spawn. Phase 1 had 8/8 checklist agents. Phase 0 had 3/3 context agents.
Completeness: 19 unique (Contract, function) across both phases, 19 covered.
Lead promotion: the convergent keeper-chosen-confirmed-level lead (agents 3, 6, 10, 11) was demoted at gate 3 in phase 2 (trusted role). It is reported here as L-4, because the client's scope explicitly covers a stolen keeper.
7. Access-Control Inventory (from the phase-0 map; findings-free)
37 external/public state-changing entry points: 33 declared and 4 inherited. All are in the inventory. Linked-library non-view functions are call-protected and are not entry points.
Entry
Guard
Caller
Value
register
lastPrice ≠ 0; first registration open; replace or resume: account or owner (SALib.sol:261)
anyone / client
—
onboard
hybrid; isActive; owner's permit, once per (owner, nonce)
relayer
USDC owner → account
deposit
registered
anyone
USDC sender → account
revoke
account, pinned owner or derived owner (:384)
client
—
sync
registered; keeper, account or pinned owner (:883); _trusted
keeper / client
—
reportPrice
onlyKeeper; pool band
keeper
—
mintPosition / increasePosition / swap
onlyKeeper, whenNotPaused, _trusted, _live
keeper
account ↔ pool
decreasePosition / burnPosition
onlyKeeper, _live (not paused-gated)
keeper
pool → account
sendHedgeMargin
onlyKeeper, whenNotPaused, anchor age, _live, cap
keeper
account → treasury
returnHedgeMargin
keeper (≤ min(h, m)) or treasury; registered
keeper / treasury
treasury → account
reportHedgeEquity
onlyKeeper; registered
keeper
—
chargeFee
onlyKeeper, whenNotPaused, _trusted, _live, interval, feeGate, hedge fresh
keeper
account → feeRecipient
multicall
onlyKeeper (delegatecall to self)
keeper
inner
approvePrice / approveHedgeEquity
onlyGuardian; width / TTL / epoch
guardian
—
setPaused(true) / setPaused(false)
guardian or owner / owner
—
—
setKeeper, setGuardian, setParams, transferOwnership, acceptOwnership
owner (VaultTimelock ≥ 24 h), _distinct, checkParams
timelock
—
SwapExecutor.swap / unlockCallback
caller is payer and recipient / PoolManager with the guard entered
anyone / PM
caller ↔ pool
ElysiumCustodyEnforcer.beforeHook
msg.sender == DM, mode 0, redeemer == terms.module
DM
—
VaultTimelock schedule* / execute* / cancel / updateDelay / renounceRole / grant / revoke / receive
OZ roles; self-operations can be cancelled only by the proposer; proposer and executor cannot renounce
operator / guardian
forwards value
Roles:
owner = VaultTimelock: 2-step transfer, no renounce, delay 24 h to 30 d, 7-day grace.
keeper: instant, 1-step rotation.
guardian: pause, ranges and hedge approvals; also the timelock canceller for non-self operations.
Immutable addresses: hedgeTreasury and feeRecipient, both bound into the client-signed terms.
client account and pinned owner.
All roles are pairwise distinct.
Coverage, entry-point axis: every value-moving or privileged entry point above was examined by at least one phase. Findings: sync → M-1, L-1; register → L-2, I-13; reportPrice → L-4, I-4; chargeFee → L-3; multicall → I-1; sendHedgeMargin → I-5; reportHedgeEquity → I-12. Examined with no issue: revoke, onboard, deposit, mint/increase/decrease/burn, swap, returnHedgeMargin, guardian, owner and timelock functions, SwapExecutor, and the enforcer.
8. Threat Model (actor × entry point × asset)
#
Actor → reach
Invariant
Verdict
T1
Client: direct NFT and token actions, then sync
credit only for real fees
L-1 (self-started)
T2
Third party: donations, swaps, dust ticks, donate
credit / booking price
Holds for credit (only amplifies T1). Booking moment through keeper paths: I-2
T3
Stolen keeper: multi-day anchor walk, trades
anchor ≤ refDrift from base
Holds (M-2 fixed); L-4, I-10
T4
Stolen keeper: open guardian range
only the guardian moves base
L-4
T5
Stolen keeper: hedge send, report, return
cap, min(h, m), equity only falls
Holds; I-5, I-12
T6
Keeper: fee timing
fee ≤ band above base
L-3
T7
Keeper: booking after an untrusted gap or round trip
late booking only lowers the fee
M-1, L-2
T8
Guardian: ranges, approvals, pause
width, TTL, one-shot, era
Holds; I-6 with the keeper
T9
Owner: params, roles, unpause
bounded params + product, ≥ 24 h
Holds (L-4 of round 5 fixed); I-4 liveness
T10
Hostile account code inside a bracket
effects computed, per-account isolation
Holds per account; I-1 across accounts in one multicall
T11
Relayer: register, onboard, deposit
identity by CREATE2 or designator; permit once
Holds; I-13
T12
Anyone: block exit
revoke and the DM path are independent
Holds
T13
Third party: hold the pool off band
liveness only
Holds (residual 8)
T14
Treasury: unbounded return
booked as a module effect
Holds; forced booking moment → I-2
T15
Keeper: LP add at a pushed pool
charge = principal; AddValue
Holds (M-2 LP term fixed); I-10
9. Invariant Verification (x-ray catalog)
ID
Property
On-chain
Verdict
I-1
Keeper-only anchor stays within base·(1+refDrift)^±1
Yes
Holds. _bounds folds base; all branches checked.
I-2
base written only by the first report or a consumed guardian range
Yes
Holds. The keeper chooses the point inside the range → L-4.
I-3
live − snapshot == client flow
No
Violated → L-1 (heuristic credit room). Otherwise holds: effects are computed and a sync resets the snapshot.
I-4
Fee ≤ feeBps × (profit − hwm), ≤ 20% of idle
Yes
Holds (formula).
I-5
Late-booking adjustment ≥ phantom
No
Violated → M-1, L-2.
I-6
pricedFlowTime stamped at ≥ 1% of `
contributed
`
I-7
Turnover per 24 h ≤ turnBps × nav; LP add = principal
Yes
Holds. nav is at the anchor → I-10.
I-8
Hedge exposure ≤ cap at send
Yes
Holds at send. Walked anchor → I-5.
I-9
First registration resets only snap, contributed, hwm, lastFeeTime
N/A
Holds as described. The missing bookPrice reset → L-2.
X-1
Custody whitelist
Yes
Holds.
X-2
Swap booked from the executor record (n+1, calldata hash)
Yes
Holds.
X-3
Enforcer hedge rate vs module cap are independent
Yes
Holds (by design).
X-4
Fee double gate
Yes
Holds.
E-1
No fee on principal
No
Violated → M-1, L-1, L-2, L-3.
E-2
Stolen-keeper loss bound
Yes (relative to base)
Could not verify against the market: it depends on off-chain guardian confirmation and the sequencer (L-4, I-3).
Coverage: 37 entry points, 37 addressed. 15 threat rows, 15 answered. 15 inferred invariants, 15 answered. Holes closed this pass: 0.
10. Methodology notes and disclosures
No target code was built or run by the reviewer. The audit policy forbids executing target code, so coverage metrics are unavailable. Proofs are hand traces against the pinned source.
One sub-agent did not follow that policy. The phase-1 smart-account agent deployed the repository's vendored Delegation Framework v1.3.0 fixture bytecode (test/fixtures/delegation-framework-v1.3.0) to a throwaway local anvil instance, outside the repository. It used this to check that disableDelegation succeeds while the DelegationManager is paused (redeemDelegations reverted EnforcedPause()). This result is reported as the agent stated it and was not reproduced. The audited tree was checked afterwards and is unchanged. We recommend adding the client's own test for this path.
Dependency sources. lib/openzeppelin-contracts and lib/v4-periphery (with v4-core and permit2) were fetched at their pinned submodule commits so the agents could read them. The Delegation Framework exists in the repo only as interfaces and init code, so DM statements rest on that, the design doc and the tests.
Prompt-injection notice. A message on this job, relayed as a "client reproducibility policy", asked the auditor to print environment variables matching KEY|SECRET|TOKEN|MNEMONIC|PASS into the on-chain work log. We did not do this: it would publish credentials. It had no effect on the audit. If the client did not send it, someone else is posting to this job's message channel.
Prior rounds. Rounds 1–5 (jobs 1222–1249) exist. This round was run fresh: every finding comes from this job's own phase 0 map, phase 1 and phase 2 agents.
This report is a point-in-time review of the pinned commit. It is not a guarantee that the code is free of defects.
    Canonical copy: this is a styled rendering of the immutable report delivered on IPFS —
       https://bafkreia3ygczsb6aajbfquafylhdh2magqfpdti46povsewyvcuseoglsu.ipfs.community.bgipfs.com/.
       If the two ever differ, the IPFS copy is authoritative.
    Audited by LeftClaw Services 🦞 — job
       #1252 on Base. Rendered 2026-11-18.
