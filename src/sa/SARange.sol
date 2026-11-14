// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SARange
/// @notice Trailing 24-hour range of a value (audit SA-3, the anchor drift budget): nine 3-hour buckets in a ring, each
///         holding the lowest and the highest value seen in that bucket. `bounds` is the (min, max) over the current
///         bucket and the eight before it, together with the current value. Any 24 h window touches at most nine
///         consecutive buckets, so every value held during the last 24 h is inside the bounds (it is recorded both when
///         it is applied and when it is replaced). Unlike a sum of moves, an oscillation that comes back costs nothing:
///         only the net displacement inside the window counts.
///         Each entry packs (bucket index << 224 | min << 112 | max); values are capped below 2^112.
library SARange {
    uint256 internal constant SPAN = 3 hours;
    uint256 internal constant N = 9;
    uint256 internal constant M112 = (1 << 112) - 1;

    struct R {
        uint256[9] b;
    }

    error RangeOverflow();

    function _now() private view returns (uint256) {
        return block.timestamp / SPAN + 1; // + 1: index 0 means "empty"
    }

    /// @notice (min, max) of `cur` and every value recorded in the live buckets.
    function bounds(R storage r, uint256 cur) internal view returns (uint256 lo, uint256 hi) {
        lo = cur;
        hi = cur;
        uint256 i = _now();
        for (uint256 k; k < N; ++k) {
            uint256 e = r.b[k];
            uint256 idx = e >> 224;
            if (idx != 0 && idx + N > i) {
                uint256 mn = (e >> 112) & M112;
                uint256 mx = e & M112;
                if (mn < lo) lo = mn;
                if (mx > hi) hi = mx;
            }
        }
    }

    /// @notice Record `x` in the current bucket.
    function record(R storage r, uint256 x) internal {
        if (x > M112) revert RangeOverflow();
        uint256 i = _now();
        uint256 k = i % N;
        uint256 e = r.b[k];
        uint256 mn = x;
        uint256 mx = x;
        if (e >> 224 == i) {
            uint256 a = (e >> 112) & M112;
            uint256 c = e & M112;
            if (a < mn) mn = a;
            if (c > mx) mx = c;
        }
        r.b[k] = (i << 224) | (mn << 112) | mx;
    }

    /// @notice Forget the history (a guardian-approved level starts a new window).
    function reset(R storage r) internal {
        for (uint256 k; k < N; ++k) {
            r.b[k] = 0;
        }
    }
}
