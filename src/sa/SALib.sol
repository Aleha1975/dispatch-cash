// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {Delegation, IDelegationManager, IDeleGatorCore, DelegationFramework} from "./vendor/DelegationFramework.sol";

interface IModifyLiquidities {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IApprove {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title SALib
/// @notice Linked (external) library for the LPManagerModule: delegation checks at registration, account-kind
///         detection, the per-account HWM fee rule and price -> sqrtPrice conversion. Pure/view, no token movement.
library SALib {
    uint256 internal constant BPS = 10_000;

    uint8 internal constant KIND_HYBRID = 1;
    uint8 internal constant KIND_EIP7702 = 2;

    error BadDelegation(uint8 code);
    error BadAccount();
    error AddValue(uint256 got, uint256 paid);

    struct Expect {
        IDelegationManager dm;
        address module;
        address enforcer;
        bytes32 enforcerTermsHash; // keccak256(abi.encode(module, hedgeTreasury, feeRecipient))
        address timestampEnforcer;
        uint256 minLifetime;
        address hybridImpl;
        address eip7702Impl;
    }

    /// @notice Validates a client-signed root delegation to the module and returns (delegationHash, account kind,
    ///         expiry). Codes: 1 delegate, 2 authority, 3 caveat count, 4 custody caveat, 5 timestamp caveat,
    ///         6 expiry too close, 7 signature, 8 disabled.
    function checkDelegation(Delegation calldata d, Expect memory e)
        external
        view
        returns (bytes32 h, uint8 kind, uint256 until)
    {
        if (d.delegate != e.module) revert BadDelegation(1);
        if (d.authority != DelegationFramework.ROOT_AUTHORITY) revert BadDelegation(2);
        if (d.caveats.length != 2) revert BadDelegation(3);
        if (d.caveats[0].enforcer != e.enforcer || keccak256(d.caveats[0].terms) != e.enforcerTermsHash) {
            revert BadDelegation(4);
        }
        bytes calldata t = d.caveats[1].terms;
        if (d.caveats[1].enforcer != e.timestampEnforcer || t.length != 32) revert BadDelegation(5);
        until = uint128(bytes16(t[16:32]));
        if (uint128(bytes16(t[0:16])) >= block.timestamp || until < block.timestamp + e.minLifetime) {
            revert BadDelegation(6);
        }
        kind = accountKind(d.delegator, e.hybridImpl, e.eip7702Impl);
        h = e.dm.getDelegationHash(d);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", e.dm.getDomainHash(), h));
        bytes4 r;
        try IDeleGatorCore(d.delegator).isValidSignature(digest, d.signature) returns (bytes4 x) {
            r = x;
        } catch {}
        if (r != DelegationFramework.EIP1271_MAGIC_VALUE) revert BadDelegation(7);
        if (e.dm.disabledDelegations(h)) revert BadDelegation(8);
    }

    /// @notice 1 = HybridDeleGator proxy on the canonical implementation, 2 = EOA upgraded (EIP-7702) to the
    ///         canonical EIP7702StatelessDeleGator. Anything else reverts.
    function accountKind(address a, address hybridImpl, address eip7702Impl) public view returns (uint8) {
        bytes memory code = a.code;
        if (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00) {
            address impl;
            assembly {
                impl := shr(96, mload(add(code, 35)))
            }
            if (impl == eip7702Impl) return KIND_EIP7702;
            revert BadAccount();
        }
        if (code.length == 0) revert BadAccount();
        try IDeleGatorCore(a).getImplementation() returns (address impl) {
            if (impl == hybridImpl) return KIND_HYBRID;
        } catch {}
        revert BadAccount();
    }

    /// @notice Per-account high-water-mark fee. `profit` = account value - net contributions (both at the anchor);
    ///         `hwm` = the profit level already charged. Returns the fee and the new mark (profit after the fee).
    function hwmFee(int256 profit, int256 hwm, uint256 feeBps) external pure returns (uint256 fee, int256 newHwm) {
        if (profit <= hwm) return (0, hwm);
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = Math.mulDiv(uint256(profit - hwm), feeBps, BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        newHwm = profit - int256(fee);
    }

    /// @notice sqrtPriceX96 of the pool when one 1e18 base unit is worth `price` asset units, clamped to the valid range.
    function sqrtPriceAt(uint256 price, bool baseIsCurrency0) external pure returns (uint160) {
        uint256 q = baseIsCurrency0 ? FullMath.mulDiv(price, 1 << 192, 1e18) : FullMath.mulDiv(1e18, 1 << 192, price);
        uint256 s = Math.sqrt(q);
        if (s <= TickMath.MIN_SQRT_PRICE) s = TickMath.MIN_SQRT_PRICE + 1;
        if (s >= TickMath.MAX_SQRT_PRICE) s = TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(s);
    }

    // ------------------------------------------------------------------ execution builders (ERC-7579 single calls)
    function _permit2Approve(address permit2, address token, address spender, uint256 amount)
        private
        view
        returns (bytes memory)
    {
        return DelegationFramework.single(
            permit2,
            0,
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)", token, spender, uint160(amount), uint48(block.timestamp)
            )
        );
    }

    /// @notice PositionManager call with exact, same-block approvals for ERC-20 legs and msg.value for a native leg:
    ///         [token.approve(Permit2, max), Permit2.approve(token, PositionManager, max, now)] per ERC-20 leg, then
    ///         modifyLiquidities{value: native max}(unlockData, now).
    function modifyExecs(
        address currency0,
        address currency1,
        address permit2,
        address posm,
        bytes memory unlockData,
        uint256 max0,
        uint256 max1
    ) external view returns (bytes[] memory xs) {
        xs = new bytes[](5);
        uint256 n;
        uint256 value;
        if (currency0 == address(0)) {
            value = max0;
        } else if (max0 != 0) {
            xs[n++] = DelegationFramework.single(currency0, 0, abi.encodeCall(IApprove.approve, (permit2, max0)));
            xs[n++] = _permit2Approve(permit2, currency0, posm, max0);
        }
        if (max1 != 0) {
            xs[n++] = DelegationFramework.single(currency1, 0, abi.encodeCall(IApprove.approve, (permit2, max1)));
            xs[n++] = _permit2Approve(permit2, currency1, posm, max1);
        }
        xs[n++] = DelegationFramework.single(
            posm, value, abi.encodeCall(IModifyLiquidities.modifyLiquidities, (unlockData, block.timestamp))
        );
        assembly {
            mstore(xs, n)
        }
    }

    /// @notice SwapExecutor call: native input as value; ERC-20 input with exact same-block approvals.
    function swapExecs(address cIn, address permit2, address executor, uint256 amountIn, bytes memory call)
        external
        view
        returns (bytes[] memory xs)
    {
        if (cIn == address(0)) {
            xs = new bytes[](1);
            xs[0] = DelegationFramework.single(executor, amountIn, call);
        } else {
            xs = new bytes[](3);
            xs[0] = DelegationFramework.single(cIn, 0, abi.encodeCall(IApprove.approve, (permit2, amountIn)));
            xs[1] = _permit2Approve(permit2, cIn, executor, amountIn);
            xs[2] = DelegationFramework.single(executor, 0, call);
        }
    }

    // ------------------------------------------------------------------ contribution flows
    /// @notice Value change (at `ref`) of the account's tracked positions since the last snapshot, plus the idle
    ///         deltas passed in; positions the account no longer owns are dropped. Used by the module's `_sync`.
    function flow(
        V4PositionMath.Position[] storage ps,
        mapping(uint256 => uint128) storage snapLiq,
        IPositionManagerMin posm,
        address a,
        uint256 ref,
        bool baseIsCurrency0,
        int256 idleFlow
    ) external returns (int256 f) {
        f = idleFlow;
        uint256 i = ps.length;
        while (i != 0) {
            --i;
            V4PositionMath.Position memory p = ps[i];
            (uint128 liq, bool owned) = _liquidityOf(posm, a, p.tokenId);
            uint128 old = snapLiq[p.tokenId];
            if (liq != old) {
                f += signedDelta(
                    V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, ref, baseIsCurrency0),
                    V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, old, ref, baseIsCurrency0),
                    1e18
                );
            }
            if (!owned) {
                delete snapLiq[p.tokenId];
                uint256 last = ps.length - 1;
                if (i != last) ps[i] = ps[last];
                ps.pop();
            }
        }
    }

    /// @notice Store the current liquidity of every tracked position.
    function snapLiquidity(V4PositionMath.Position[] storage ps, mapping(uint256 => uint128) storage snapLiq, IPositionManagerMin posm)
        external
    {
        for (uint256 i; i < ps.length; ++i) {
            snapLiq[ps[i].tokenId] = posm.getPositionLiquidity(ps[i].tokenId);
        }
    }

    function _liquidityOf(IPositionManagerMin posm, address a, uint256 tokenId) private view returns (uint128, bool) {
        try posm.ownerOf(tokenId) returns (address o) {
            if (o != a) return (0, false);
        } catch {
            return (0, false);
        }
        return (posm.getPositionLiquidity(tokenId), true);
    }

    /// @notice (now - then) x price / 1e18 as a signed amount (losses rounded up).
    function signedDelta(uint256 now_, uint256 then_, uint256 price) public pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (now_ >= then_) return int256(Math.mulDiv(now_ - then_, price, 1e18));
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int256(Math.mulDiv(then_ - now_, price, 1e18, Math.Rounding.Ceil));
    }

    /// @notice H-3 check for an LP add: the new liquidity valued at the anchor (`got`) must be worth >= `paid` x
    ///         (1 - slippage). Returns the turnover charge paid x slippage / (band + slippage), rounded up.
    function addCharge(int24 tl, int24 tu, uint128 liquidity, uint256 ref, bool baseIsCurrency0, uint256 paid, uint256 slip, uint256 band)
        external
        pure
        returns (uint256)
    {
        uint256 got = V4PositionMath.liquidityValue(tl, tu, liquidity, ref, baseIsCurrency0);
        if (got * BPS < paid * (BPS - slip)) revert AddValue(got, paid);
        return Math.mulDiv(paid, slip, slip + band, Math.Rounding.Ceil);
    }
}
