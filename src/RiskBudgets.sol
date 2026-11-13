// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskBudgets
/// @notice Linked (external) library holding the vault's three keeper budgets, all built on one decaying-day
///         primitive: an amount `used` spent at time `t` is restored linearly over the following 24 h
///         (`used' = used * (1 day - elapsed) / 1 day + new`). Any 24 h window admits at most ~1.6x the budget,
///         and no window reset can be triggered by the keeper. Kept out of the vault to stay under EIP-170.
///         - price: cumulative relative movement of the price anchor (WAD fraction)
///         - hedge: keeper-only decreases of the off-chain hedge equity (asset units)
///         - turnover: swap + LP-add notional (asset units)
library RiskBudgets {
    uint256 internal constant WAD = 1e18;

    struct Budgets {
        uint256 priceUsed;
        uint256 priceTime;
        uint256 hedgeUsed;
        uint256 hedgeTime;
        uint256 turnoverUsed;
        uint256 turnoverTime;
        // guardian co-signatures
        uint256 hedgeApproved; // exact hedge equity value
        uint256 hedgeApprovedEpoch; // epoch + 1 (0 = none)
        uint256 hedgeApprovedUntil;
        uint256 priceApprovedLo;
        uint256 priceApprovedHi;
        uint256 priceApprovedUntil;
    }

    error Turnover();

    function _decay(uint256 used, uint256 t) private view returns (uint256) {
        uint256 dt = block.timestamp - t;
        return dt >= 1 days ? 0 : used * (1 days - dt) / 1 days;
    }

    /// @notice Move the anchor `ref` toward `p`. Free inside an unexpired guardian-approved range (and for the first
    ///         settlement, `ref == 0`); otherwise limited by the remaining price budget (`capWad`, WAD fraction of the
    ///         anchor per day). Returns the new anchor and whether the move had to be clipped.
    function movePrice(Budgets storage b, uint256 ref, uint256 p, uint256 capWad) external returns (uint256, bool) {
        if (ref == 0 || (block.timestamp <= b.priceApprovedUntil && p >= b.priceApprovedLo && p <= b.priceApprovedHi)) {
            return (p, false);
        }
        uint256 used = _decay(b.priceUsed, b.priceTime);
        uint256 room = capWad > used ? capWad - used : 0;
        uint256 move = Math.mulDiv(p > ref ? p - ref : ref - p, WAD, ref, Math.Rounding.Ceil);
        bool clipped = move > room;
        if (clipped) {
            move = room;
            uint256 d = Math.mulDiv(ref, room, WAD);
            p = p > ref ? ref + d : ref - d;
        }
        b.priceUsed = used + move;
        b.priceTime = block.timestamp;
        return (p, clipped);
    }

    /// @notice New hedge equity for a report `v` (!= old). The guardian's unexpired exact approval for this epoch is
    ///         taken as is (one-shot). Otherwise an increase is refused (old kept, clipped) and a decrease uses at most
    ///         the remaining budget `cap`.
    function moveHedge(Budgets storage b, uint256 old, uint256 v, uint256 epoch, uint256 cap)
        external
        returns (uint256, bool)
    {
        if (b.hedgeApprovedEpoch == epoch + 1 && b.hedgeApproved == v && block.timestamp <= b.hedgeApprovedUntil) {
            b.hedgeApprovedEpoch = 0;
            return (v, false);
        }
        if (v > old) return (old, true);
        uint256 used = _decay(b.hedgeUsed, b.hedgeTime);
        uint256 room = cap > used ? cap - used : 0;
        uint256 d = old - v;
        bool clipped = d > room;
        if (clipped) d = room;
        b.hedgeUsed = used + d;
        b.hedgeTime = block.timestamp;
        return (old - d, clipped);
    }

    /// @notice Charge `notional` to the turnover budget `cap`; reverts `Turnover()` beyond it.
    function useTurnover(Budgets storage b, uint256 notional, uint256 cap) external {
        uint256 used = _decay(b.turnoverUsed, b.turnoverTime) + notional;
        if (used > cap) revert Turnover();
        b.turnoverUsed = used;
        b.turnoverTime = block.timestamp;
    }
}
