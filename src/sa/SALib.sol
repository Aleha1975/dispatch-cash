// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {SAWindow} from "./SAWindow.sol";
import {
    Delegation,
    IDelegationManager,
    IDeleGatorCore,
    IHybridDeleGator,
    DelegationFramework,
    ModeCode
} from "./vendor/DelegationFramework.sol";

interface IModifyLiquidities {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IApprove {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPositionInfo {
    function positionInfo(uint256 tokenId) external view returns (uint256);
}

/// @title SALib
/// @notice Linked (external) library for the LPManagerModule, holding the logic that would not fit under EIP-170:
///         delegation and account checks at registration (identity by CREATE2 derivation, audit SA-1 C-1), the
///         per-account flow bookkeeping (`sync`: books AND re-snapshots, SA-1 H-3 / M-2), valuation at a given price
///         (SA-1 M-4), the HWM fee rule, the budgets (sliding window, SA-1 M-7) and the execution builders. Functions
///         taking `storage` arguments write only the module storage passed in; nothing here moves tokens.
library SALib {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    uint8 internal constant KIND_HYBRID = 1;
    uint8 internal constant KIND_EIP7702 = 2;

    /// ERC1967Proxy creation code of Delegation Framework v1.3.0 (test/fixtures/delegation-framework-v1.3.0).
    bytes internal constant PROXY_CREATION = hex"608060405260405161040a38038061040a83398101604081905261002291610268565b61002c8282610033565b5050610352565b61003c82610092565b6040516001600160a01b038316907fbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b90600090a280511561008657610081828261010e565b505050565b61008e610185565b5050565b806001600160a01b03163b6000036100cd57604051634c9c8ce360e01b81526001600160a01b03821660048201526024015b60405180910390fd5b7f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc80546001600160a01b0319166001600160a01b0392909216919091179055565b6060600080846001600160a01b03168460405161012b9190610336565b600060405180830381855af49150503d8060008114610166576040519150601f19603f3d011682016040523d82523d6000602084013e61016b565b606091505b50909250905061017c8583836101a6565b95945050505050565b34156101a45760405163b398979f60e01b815260040160405180910390fd5b565b6060826101bb576101b682610205565b6101fe565b81511580156101d257506001600160a01b0384163b155b156101fb57604051639996b31560e01b81526001600160a01b03851660048201526024016100c4565b50805b9392505050565b8051156102155780518082602001fd5b604051630a12f52160e11b815260040160405180910390fd5b634e487b7160e01b600052604160045260246000fd5b60005b8381101561025f578181015183820152602001610247565b50506000910152565b6000806040838503121561027b57600080fd5b82516001600160a01b038116811461029257600080fd5b60208401519092506001600160401b03808211156102af57600080fd5b818501915085601f8301126102c357600080fd5b8151818111156102d5576102d561022e565b604051601f8201601f19908116603f011681019083821181831017156102fd576102fd61022e565b8160405282815288602084870101111561031657600080fd5b610327836020830160208801610244565b80955050505050509250929050565b60008251610348818460208701610244565b9190910192915050565b60aa806103606000396000f3fe6080604052600a600c565b005b60186014601a565b6051565b565b6000604c7f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc546001600160a01b031690565b905090565b3660008037600080366000845af43d6000803e808015606f573d6000f35b3d6000fdfea264697066735822122008caabf4d08d0971ef1e07ddea0ed06ba372754bdd8d481deec8a72240bac12c64736f6c63430008170033";

    error BadDelegation(uint8 code);
    error BadAccount();
    error AddValue(uint256 got, uint256 paid);
    error BadMint();
    error Subscribed(uint256 tokenId);
    error Unexpected(uint256 asset, uint256 base);
    error TransferMismatch();
    error NotOwnAccount();

    event Registered(address indexed account, bytes32 delegationHash, uint8 kind, uint256 until, bool first);
    event Flow(address indexed account, int256 value);

    // ------------------------------------------------------------------ module storage types
    struct Account {
        bytes32 delegationHash; // 0 = never registered
        address owner; // pinned at registration: derived from the account address (hybrid) or the account (7702)
        uint8 kind; // KIND_HYBRID | KIND_EIP7702
        uint64 until; // delegation expiry (TimestampEnforcer)
        bool revoked; // set by the client with LPManagerModule.revoke; cleared only by the client re-registering
        bool hedgeClipped; // the last keeper decrease was clipped: stored equity may be above the real one
        int256 contributed; // net client contributions
        int256 hwm; // profit level already charged
        uint256 hedgeEquity; // off-chain hedge equity attributed to this account
        uint256 netMargin; // margin sent - margin returned (floored at 0; written down by a guardian approval)
        uint256 hedgeEpoch; // increments on every change of hedgeEquity or netMargin
        uint256 snapAsset; // idle asset at the last snapshot
        uint256 snapBase; // idle base at the last snapshot
        uint256 lastFeeTime;
        uint256 feesPaid;
        uint256 hedgeTime; // last hedge report
    }

    struct Budgets {
        SAWindow.W turnover; // swap + LP-add notional (asset units)
        SAWindow.W hedge; // keeper-only hedge decreases (asset units), net of guardian-approved increases
        uint256 hedgeApproved; // guardian: exact value
        uint64 hedgeApprovedEpoch; // hedgeEpoch + 1 at approval (0 = none)
        uint64 hedgeApprovedUntil;
        uint64 hedgeApprovedEra; // guardian era at approval (a guardian change voids it)
    }

    struct PriceBudget {
        SAWindow.W window; // relative anchor moves (WAD, charged against the lower of the two prices)
        uint256 lo; // guardian range, one-shot
        uint256 hi;
        uint256 until;
    }

    struct Expect {
        IDelegationManager dm;
        address module;
        address enforcer;
        bytes32 enforcerTermsHash; // keccak256(abi.encode(module, hedgeTreasury, feeRecipient))
        address timestampEnforcer;
        uint256 minLifetime;
        address hybridImpl;
        address eip7702Impl;
        address factory; // SimpleFactory (CREATE2 deployer of the HybridDeleGator proxies)
        bytes32 accountSalt;
        address hedgeTreasury;
        address feeRecipient;
    }

    struct Venue {
        IPoolManager pm;
        PoolId id;
        IPositionManagerMin posm;
        address asset;
        address base; // address(0) = native
        bool baseIsCurrency0;
    }

    // ------------------------------------------------------------------ registration
    /// @notice Validates a client-signed root delegation to the module and returns (delegationHash, account kind,
    ///         expiry, pinned owner). Codes: 1 delegate, 2 authority, 3 caveat count, 4 custody caveat, 5 timestamp
    ///         caveat, 6 expiry, 7 signature, 8 disabled, 9 caveat args / signature shape.
    function checkDelegation(Delegation calldata d, Expect memory e)
        public
        view
        returns (bytes32 h, uint8 kind, uint256 until, address owner)
    {
        if (d.delegate != e.module) revert BadDelegation(1);
        if (d.authority != DelegationFramework.ROOT_AUTHORITY) revert BadDelegation(2);
        if (d.caveats.length != 2) revert BadDelegation(3);
        // L-5: args are outside the signed hash; the stored context must be exactly what was signed
        if (d.caveats[0].args.length != 0 || d.caveats[1].args.length != 0 || d.signature.length != 65) {
            revert BadDelegation(9);
        }
        if (d.caveats[0].enforcer != e.enforcer || keccak256(d.caveats[0].terms) != e.enforcerTermsHash) {
            revert BadDelegation(4);
        }
        bytes calldata t = d.caveats[1].terms;
        if (d.caveats[1].enforcer != e.timestampEnforcer || t.length != 32) revert BadDelegation(5);
        until = uint128(bytes16(t[16:32]));
        // L-1: the module stores uint64; an expiry beyond it would make the module and the DM disagree on liveness
        if (
            uint128(bytes16(t[0:16])) >= block.timestamp || until < block.timestamp + e.minLifetime
                || until > type(uint64).max
        ) revert BadDelegation(6);
        (kind, owner) = accountKind(d.delegator, e);
        h = e.dm.getDelegationHash(d);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", e.dm.getDomainHash(), h));
        bytes4 r;
        try IDeleGatorCore(d.delegator).isValidSignature{gas: 200_000}(digest, d.signature) returns (bytes4 x) {
            r = x;
        } catch {}
        if (r != DelegationFramework.EIP1271_MAGIC_VALUE) revert BadDelegation(7);
        if (e.dm.disabledDelegations(h)) revert BadDelegation(8);
    }

    /// @notice (kind, owner) of an account, from facts the account cannot change after creation (C-1, H-2):
    ///         - 7702: the EOA's code is the designator of the canonical EIP7702StatelessDeleGator; owner = the EOA;
    ///         - hybrid: the address is the SimpleFactory CREATE2 address of the canonical ERC1967Proxy initialised
    ///           with (HybridDeleGatorImpl, initialize(owner, no P256 keys)) under `accountSalt`. The owner the
    ///           account reports is only a candidate: it is accepted iff it re-derives the account address.
    ///         Anything else reverts BadAccount.
    function accountKind(address a, Expect memory e) public view returns (uint8, address) {
        bytes memory code = a.code;
        if (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00) {
            address impl;
            assembly {
                impl := shr(96, mload(add(code, 35)))
            }
            if (impl != e.eip7702Impl) revert BadAccount();
            return (KIND_EIP7702, a);
        }
        if (code.length == 0) revert BadAccount();
        address o = ownerOf(a);
        if (o == address(0) || o == e.hedgeTreasury || o == e.feeRecipient || hybridAddress(e, o) != a) {
            revert BadAccount();
        }
        return (KIND_HYBRID, o);
    }

    /// @notice The counterfactual HybridDeleGator of `owner` (SimpleFactory.computeAddress).
    function hybridAddress(Expect memory e, address owner) public pure returns (address) {
        bytes memory init = abi.encodeCall(
            IHybridDeleGator.initialize, (owner, new string[](0), new uint256[](0), new uint256[](0))
        );
        bytes32 ch = keccak256(abi.encodePacked(PROXY_CREATION, abi.encode(e.hybridImpl, init)));
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), e.factory, e.accountSalt, ch)))));
    }

    /// @notice `owner()` of a hybrid account (gas-capped; 0 on failure). A candidate, never trusted on its own.
    function ownerOf(address a) public view returns (address o) {
        (bool ok, bytes memory r) = a.staticcall{gas: 30_000}(abi.encodeCall(IHybridDeleGator.owner, ()));
        if (ok && r.length == 32) o = abi.decode(r, (address));
    }

    /// @notice The module may act for `a`: registered, not revoked by the client, not expired, and the account's
    ///         code / owner unchanged since registration (L-14: a change is a revocation). The DelegationManager's
    ///         own disabled flag is checked by the DM at redemption (and by LPManagerModule.isActive).
    function live(Account storage s, address a, bytes32 designatorHash) public view returns (bool) {
        if (s.delegationHash == 0 || s.revoked || block.timestamp >= s.until) return false;
        if (s.kind == KIND_EIP7702) return a.codehash == designatorHash;
        return ownerOf(a) == s.owner;
    }

    /// @notice Register `d` for its delegator (module storage passed in). The first registration is permissionless
    ///         and books what the account already holds (zero snapshots). The stored delegation again: no-op (L-2).
    ///         Replacing it, or registering after a revoke: only the account or its pinned owner (M-1).
    function register(
        mapping(address => Account) storage accts,
        mapping(address => bytes) storage ctxs,
        mapping(address => V4PositionMath.Position[]) storage pos,
        mapping(uint256 => uint128) storage snapLiq,
        Venue storage v,
        Delegation calldata d,
        Expect memory e,
        uint256 ref,
        uint256 poolP
    ) external {
        (bytes32 h, uint8 kind, uint256 until, address o) = checkDelegation(d, e);
        address a = d.delegator;
        Account storage s = accts[a];
        bytes32 old = s.delegationHash;
        if (old == h && !s.revoked) return;
        if (old != 0 && msg.sender != a && msg.sender != s.owner) revert NotOwnAccount();
        _sync(s, pos[a], snapLiq, a, v, ref, poolP);
        s.delegationHash = h;
        s.owner = o;
        s.kind = kind;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.until = uint64(until);
        s.revoked = false;
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        ctxs[a] = abi.encode(ds);
        if (old == 0) s.lastFeeTime = block.timestamp;
        emit Registered(a, h, kind, until, old == 0);
    }

    // ------------------------------------------------------------------ flows and valuation
    /// @notice Book everything that changed since the last snapshot as a client flow AND write the new snapshot in
    ///         the same step (H-3, M-2: no caller can forget the snapshot). Inflows (value up) are booked at the lower
    ///         of `ref` and `poolP`, outflows at the higher (L-2: no anchor-lag arbitrage against the fee). Positions
    ///         the account no longer owns are dropped (their remaining liquidity is an outflow).
    function sync(
        Account storage s,
        V4PositionMath.Position[] storage ps,
        mapping(uint256 => uint128) storage snapLiq,
        address a,
        Venue storage v,
        uint256 ref,
        uint256 poolP
    ) external {
        _sync(s, ps, snapLiq, a, v, ref, poolP);
    }

    function _sync(
        Account storage s,
        V4PositionMath.Position[] storage ps,
        mapping(uint256 => uint128) storage snapLiq,
        address a,
        Venue storage v,
        uint256 ref,
        uint256 poolP
    ) private {
        (uint256 lo, uint256 hi) = ref < poolP ? (ref, poolP) : (poolP, ref);
        uint256 x = IERC20(v.asset).balanceOf(a);
        uint256 b = _bal(v.base, a);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 f = int256(x) - int256(s.snapAsset) + signedDelta(b, s.snapBase, b >= s.snapBase ? lo : hi);
        uint256 i = ps.length;
        while (i != 0) {
            --i;
            V4PositionMath.Position memory p = ps[i];
            (uint128 liq, bool owned) = _liquidityOf(v.posm, a, p.tokenId);
            uint128 old = snapLiq[p.tokenId];
            if (liq != old) {
                uint256 px = liq > old ? lo : hi;
                f += signedDelta(
                    V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, px, v.baseIsCurrency0),
                    V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, old, px, v.baseIsCurrency0),
                    WAD
                );
            }
            if (owned) {
                snapLiq[p.tokenId] = liq;
            } else {
                delete snapLiq[p.tokenId];
                uint256 last = ps.length - 1;
                if (i != last) ps[i] = ps[last];
                ps.pop();
            }
        }
        s.snapAsset = x;
        s.snapBase = b;
        if (f != 0) {
            s.contributed += f;
            emit Flow(a, f);
        }
    }

    /// @notice Directional post-check of a module action against the pre-action snapshot written by `sync`: idle asset
    ///         and base may have fallen at most by what the action itself spends (A: client code running inside the
    ///         bracket can never take value out unbooked).
    function post(Account storage s, address a, Venue storage v, uint256 maxAssetOut, uint256 maxBaseOut) external view {
        _post(s, a, v, maxAssetOut, maxBaseOut);
    }

    function _post(Account storage s, address a, Venue storage v, uint256 maxAssetOut, uint256 maxBaseOut) private view {
        uint256 x = IERC20(v.asset).balanceOf(a);
        uint256 b = _bal(v.base, a);
        if (x + maxAssetOut < s.snapAsset || b + maxBaseOut < s.snapBase) revert Unexpected(x, b);
    }

    /// @notice Idle asset + idle base at `price`.
    function held(Venue storage v, address a, uint256 price) public view returns (uint256) {
        return IERC20(v.asset).balanceOf(a) + Math.mulDiv(_bal(v.base, a), price, WAD);
    }

    /// @notice Account value at `price`: idle + positions the account still owns (principal at sqrt(price) plus
    ///         uncollected fees, base valued at `price`; M-4: no pool-spot term) + attributed hedge equity.
    function value(
        Venue storage v,
        Account storage s,
        V4PositionMath.Position[] storage ps,
        address a,
        uint256 price
    ) external view returns (uint256 val) {
        val = held(v, a, price) + s.hedgeEquity;
        for (uint256 i; i < ps.length; ++i) {
            V4PositionMath.Position memory p = ps[i];
            (, bool owned) = _liquidityOf(v.posm, a, p.tokenId);
            if (owned) val += _positionValue(v, p, price, true);
        }
    }

    /// @notice Uncollected fees of one position valued at `price`.
    function feesValue(Venue storage v, V4PositionMath.Position memory p, uint256 price) external view returns (uint256) {
        return _positionValue(v, p, price, false);
    }

    function _positionValue(Venue storage v, V4PositionMath.Position memory p, uint256 price, bool principal)
        private
        view
        returns (uint256 val)
    {
        (uint128 liq, uint256 last0, uint256 last1) =
            v.pm.getPositionInfo(v.id, address(v.posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
        if (liq == 0) return 0;
        if (principal) val = V4PositionMath.liquidityValue(p.tickLower, p.tickUpper, liq, price, v.baseIsCurrency0);
        (uint256 in0, uint256 in1) = v.pm.getFeeGrowthInside(v.id, p.tickLower, p.tickUpper);
        uint256 f0;
        uint256 f1;
        unchecked {
            f0 = FullMath.mulDiv(in0 - last0, liq, 1 << 128);
            f1 = FullMath.mulDiv(in1 - last1, liq, 1 << 128);
        }
        (uint256 fb, uint256 fa) = v.baseIsCurrency0 ? (f0, f1) : (f1, f0);
        val += fa + Math.mulDiv(fb, price, WAD);
    }

    /// @notice After a mint: the token is owned by the account, in the fixed pool, with exactly the requested ticks
    ///         and liquidity and no subscriber (L-13: what is tracked is what PositionManager holds).
    function checkMinted(Venue storage v, uint256 tokenId, address a, int24 tl, int24 tu, uint128 liquidity) external view {
        uint256 info = IPositionInfo(address(v.posm)).positionInfo(tokenId);
        if (
            v.posm.ownerOf(tokenId) != a || bytes25(bytes32(info)) != bytes25(PoolId.unwrap(v.id))
                || int24(int256(info >> 8)) != tl || int24(int256(info >> 32)) != tu || info & 0xff != 0
                || v.posm.getPositionLiquidity(tokenId) != liquidity
        ) revert BadMint();
    }

    /// @notice M-5: no client code (subscriber notifications) may run inside a keeper action on this position.
    function notSubscribed(IPositionManagerMin posm, uint256 tokenId) external view {
        if (IPositionInfo(address(posm)).positionInfo(tokenId) & 0xff != 0) revert Subscribed(tokenId);
    }

    function _bal(address token, address a) private view returns (uint256) {
        return token == address(0) ? a.balance : IERC20(token).balanceOf(a);
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

    // ------------------------------------------------------------------ fee
    /// @notice Per-account high-water-mark fee, at most `maxFee` (L-11: a partial fee advances the mark only by the
    ///         gain it actually charged). `profit` = account value - net contributions; `hwm` = profit already charged.
    function hwmFee(int256 profit, int256 hwm, uint256 feeBps, uint256 maxFee)
        external
        pure
        returns (uint256 fee, int256 newHwm)
    {
        if (profit <= hwm || feeBps == 0) return (0, hwm);
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = Math.mulDiv(uint256(profit - hwm), feeBps, BPS);
        if (fee <= maxFee) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return (fee, profit - int256(fee));
        }
        fee = maxFee;
        // forge-lint: disable-next-line(unsafe-typecast)
        newHwm = hwm + int256(Math.mulDiv(fee, BPS, feeBps)) - int256(fee);
    }

    // ------------------------------------------------------------------ budgets
    /// @notice Move the anchor `ref` toward `p`. The first report (ref == 0) is free. A guardian range covering `p`
    ///         is consumed by this report (one-shot) and its move is charged to the window without clipping (F);
    ///         otherwise the move is limited by the room left in the sliding 24 h window of `capWad`. A step costs
    ///         |p - ref| / min(p, ref), the same up and down (E).
    function movePrice(PriceBudget storage b, uint256 ref, uint256 p, uint256 capWad) external returns (uint256, bool) {
        if (ref == 0) return (p, false);
        uint256 move = Math.mulDiv(p > ref ? p - ref : ref - p, WAD, p > ref ? ref : p, Math.Rounding.Ceil);
        if (block.timestamp <= b.until && p >= b.lo && p <= b.hi) {
            b.until = 0;
            SAWindow.add(b.window, move);
            return (p, false);
        }
        uint256 room = SAWindow.room(b.window, capWad);
        bool clipped = move > room;
        if (clipped) {
            move = room;
            // up: p = ref (1 + room); down: p = ref / (1 + room)
            p = p > ref ? ref + Math.mulDiv(ref, room, WAD) : Math.mulDiv(ref, WAD, WAD + room, Math.Rounding.Ceil);
        }
        SAWindow.add(b.window, move);
        return (p, clipped);
    }

    /// @notice New hedge equity for a keeper report `v`. The guardian's approval for exactly this account, epoch,
    ///         era and value (unexpired) is applied as is and consumed; it also writes `netMargin` down to `v` (L-4),
    ///         and an approved increase is credited back to the decrease window (net movement). Otherwise an increase
    ///         is refused (equity kept: understated, never a fee risk) and a decrease uses at most the room left in
    ///         the window of `cap` (0 while paused). Every report records its time; `hedgeClipped` = stored equity
    ///         may be above the real one (L-12). Returns (applied, applied != v).
    function moveHedge(Account storage s, Budgets storage b, uint256 v, uint256 cap, uint64 era)
        external
        returns (uint256, bool)
    {
        uint256 old = s.hedgeEquity;
        s.hedgeTime = block.timestamp;
        if (
            b.hedgeApprovedEpoch == s.hedgeEpoch + 1 && b.hedgeApprovedEra == era && b.hedgeApproved == v
                && block.timestamp <= b.hedgeApprovedUntil
        ) {
            b.hedgeApprovedEpoch = 0;
            if (v > old) SAWindow.credit(b.hedge, v - old);
            bool changed = v != old;
            if (s.netMargin > v) {
                s.netMargin = v;
                changed = true;
            }
            s.hedgeEquity = v;
            if (changed) s.hedgeEpoch++;
            s.hedgeClipped = false;
            return (v, false);
        }
        if (v >= old) {
            s.hedgeClipped = false;
            return (old, v != old);
        }
        uint256 d = old - v;
        uint256 room = SAWindow.room(b.hedge, cap);
        bool clipped = d > room;
        if (clipped) d = room;
        s.hedgeClipped = clipped;
        if (d != 0) {
            SAWindow.add(b.hedge, d);
            s.hedgeEquity = old - d;
            s.hedgeEpoch++;
        }
        return (old - d, clipped);
    }

    /// @notice Charge `notional` to the account's turnover window `cap`; reverts beyond it.
    function useTurnover(Budgets storage b, uint256 notional, uint256 cap) external {
        SAWindow.charge(b.turnover, notional, cap);
    }

    /// @notice (turnover used, hedge-decrease used) in the current 24 h windows.
    function used(Budgets storage b) external view returns (uint256, uint256) {
        return (SAWindow.used(b.turnover), SAWindow.used(b.hedge));
    }

    function priceUsed(PriceBudget storage b) external view returns (uint256) {
        return SAWindow.used(b.window);
    }

    // ------------------------------------------------------------------ misc
    /// @notice sqrtPriceX96 of the pool when one 1e18 base unit is worth `price` asset units, clamped to the valid range.
    function sqrtPriceAt(uint256 price, bool baseIsCurrency0) external pure returns (uint160) {
        uint256 q = baseIsCurrency0 ? FullMath.mulDiv(price, 1 << 192, 1e18) : FullMath.mulDiv(1e18, 1 << 192, price);
        uint256 s = Math.sqrt(q);
        if (s <= TickMath.MIN_SQRT_PRICE) s = TickMath.MIN_SQRT_PRICE + 1;
        if (s >= TickMath.MAX_SQRT_PRICE) s = TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(s);
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

    function _approve(address token, address spender, uint256 amount) private pure returns (bytes memory) {
        return DelegationFramework.single(token, 0, abi.encodeCall(IApprove.approve, (spender, amount)));
    }

    /// @dev Redeem the account's stored delegation for single-call executions (one DelegationManager call). Runs in the
    ///      module's context (delegatecall), so the module is the redeemer.
    function _redeem(IDelegationManager dm, bytes storage ctx, bytes[] memory execs) private {
        bytes memory c = ctx;
        uint256 n = execs.length;
        bytes[] memory ctxs = new bytes[](n);
        ModeCode[] memory modes = new ModeCode[](n);
        for (uint256 i; i < n; ++i) {
            ctxs[i] = c;
            modes[i] = DelegationFramework.SINGLE_DEFAULT;
        }
        dm.redeemDelegations(ctxs, modes, execs);
    }

    /// @notice PositionManager call with exact approvals for ERC-20 legs and msg.value for a native leg:
    ///         [token.approve(Permit2, max), Permit2.approve(token, PositionManager, max, now)] per ERC-20 leg, then
    ///         modifyLiquidities{value: native max}(unlockData, now), then token.approve(Permit2, 0) per ERC-20 leg
    ///         (L-17: no residual allowance).
    function modify(
        IDelegationManager dm,
        bytes storage ctx,
        address currency0,
        address currency1,
        address permit2,
        address posm,
        bytes memory unlockData,
        uint256 max0,
        uint256 max1
    ) external {
        bytes[] memory xs = new bytes[](7);
        uint256 n;
        uint256 value;
        bool leg0 = currency0 != address(0) && max0 != 0;
        if (currency0 == address(0)) {
            value = max0;
        } else if (leg0) {
            xs[n++] = _approve(currency0, permit2, max0);
            xs[n++] = _permit2Approve(permit2, currency0, posm, max0);
        }
        if (max1 != 0) {
            xs[n++] = _approve(currency1, permit2, max1);
            xs[n++] = _permit2Approve(permit2, currency1, posm, max1);
        }
        xs[n++] = DelegationFramework.single(
            posm, value, abi.encodeCall(IModifyLiquidities.modifyLiquidities, (unlockData, block.timestamp))
        );
        if (leg0) xs[n++] = _approve(currency0, permit2, 0);
        if (max1 != 0) xs[n++] = _approve(currency1, permit2, 0);
        assembly {
            mstore(xs, n)
        }
        _redeem(dm, ctx, xs);
    }

    /// @notice SwapExecutor call: native input as value; ERC-20 input with exact approvals, reset afterwards (L-17).
    function swapVia(
        IDelegationManager dm,
        bytes storage ctx,
        address cIn,
        address permit2,
        address executor,
        uint256 amountIn,
        bytes memory call
    ) external {
        bytes[] memory xs;
        if (cIn == address(0)) {
            xs = new bytes[](1);
            xs[0] = DelegationFramework.single(executor, amountIn, call);
        } else {
            xs = new bytes[](4);
            xs[0] = _approve(cIn, permit2, amountIn);
            xs[1] = _permit2Approve(permit2, cIn, executor, amountIn);
            xs[2] = DelegationFramework.single(executor, 0, call);
            xs[3] = _approve(cIn, permit2, 0);
        }
        _redeem(dm, ctx, xs);
    }

    /// @notice USDC from the account to one of the module's two fixed recipients, verified at the recipient (H-2:
    ///         the account's code cannot fake a balance it does not control) and by the directional post-check.
    function transferOut(
        IDelegationManager dm,
        bytes storage ctx,
        Account storage s,
        Venue storage v,
        address a,
        address to,
        uint256 amount
    ) external {
        IERC20 t = IERC20(v.asset);
        uint256 r0 = t.balanceOf(to);
        bytes[] memory xs = new bytes[](1);
        xs[0] = DelegationFramework.single(address(t), 0, abi.encodeCall(IERC20.transfer, (to, amount)));
        _redeem(dm, ctx, xs);
        if (t.balanceOf(to) - r0 != amount) revert TransferMismatch();
        _post(s, a, v, amount, 0);
    }
}
