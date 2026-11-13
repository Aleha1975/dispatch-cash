// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SAWindow
/// @notice Sliding 24-hour budget (audit SA-1 M-7, vault round 2 M-2 / L-1 / L-2). Nine 3-hour buckets in a ring; a
///         charge goes into the bucket of the current time; `used` is the sum of the current bucket and the eight
///         before it. Any 24 h window touches at most nine consecutive buckets, and a charge made inside a window is
///         still counted when any later charge inside the same window is checked, so the charges admitted in ANY
///         24 h window sum to at most the cap (1x, not 2x). Capacity returns 24-27 h after a spend. No decay
///         arithmetic: a zero charge writes nothing and nothing is re-based by frequent writes.
///         Each entry packs (bucket index << 96 | amount); amounts are capped at 2^96 - 1.
library SAWindow {
    uint256 internal constant SPAN = 3 hours;
    uint256 internal constant N = 9;
    uint256 internal constant AMT_MASK = (1 << 96) - 1;

    struct W {
        uint128[9] b;
    }

    error WindowOverflow();

    function _now() private view returns (uint256) {
        return block.timestamp / SPAN + 1; // + 1: index 0 means "empty"
    }

    /// @notice Sum of the charges in the current bucket and the eight before it.
    function used(W storage w) internal view returns (uint256 u) {
        uint256 i = _now();
        for (uint256 k; k < N; ++k) {
            uint256 e = w.b[k];
            uint256 idx = e >> 96;
            if (idx != 0 && idx + N > i) u += e & AMT_MASK;
        }
    }

    /// @notice cap - used, floored at 0.
    function room(W storage w, uint256 cap) internal view returns (uint256) {
        uint256 u = used(w);
        return cap > u ? cap - u : 0;
    }

    /// @notice Record `amount` in the current bucket (no cap check; callers compare with `room` first).
    function add(W storage w, uint256 amount) internal {
        if (amount == 0) return;
        uint256 i = _now();
        uint256 k = i % N;
        uint256 e = w.b[k];
        uint256 cur = (e >> 96) == i ? e & AMT_MASK : 0;
        cur += amount;
        if (cur > AMT_MASK) cur = AMT_MASK;
        // forge-lint: disable-next-line(unsafe-typecast)
        w.b[k] = uint128((i << 96) | cur);
    }

    /// @notice Charge `amount` against `cap`; reverts beyond it.
    function charge(W storage w, uint256 amount, uint256 cap) internal {
        if (amount > room(w, cap)) revert WindowOverflow();
        add(w, amount);
    }

    /// @notice Give back up to `amount`, newest buckets first (net movement: a confirmed move back up restores room).
    function credit(W storage w, uint256 amount) internal {
        uint256 i = _now();
        for (uint256 k; k < N && amount != 0; ++k) {
            uint256 idx = i - k;
            uint256 slot = idx % N;
            uint256 e = w.b[slot];
            if ((e >> 96) != idx) continue;
            uint256 cur = e & AMT_MASK;
            uint256 d = cur < amount ? cur : amount;
            amount -= d;
            // forge-lint: disable-next-line(unsafe-typecast)
            w.b[slot] = uint128((idx << 96) | (cur - d));
        }
    }
}
