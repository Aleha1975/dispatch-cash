// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {V4PositionMath} from "../V4PositionMath.sol";
import {IPositionManagerMin} from "../interfaces/IExternal.sol";
import {SAWindow} from "./SAWindow.sol";
import {SARange} from "./SARange.sol";
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
///         permit-only onboarding pull (SA-2 M-3), the HWM fee rule, the budgets (sliding window, SA-1 M-7) and the
///         execution builders. The books (flows, valuation, the module's computed effect) are in SABook. Functions
///         taking `storage` arguments write only the module storage passed in.
library SALib {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_DELEGATION_LIFETIME = 400 days; // SA-4 I-3 (1241)

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint8 internal constant KIND_HYBRID = 1;
    uint8 internal constant KIND_EIP7702 = 2;

    /// ERC1967Proxy creation code of Delegation Framework v1.3.0 (test/fixtures/delegation-framework-v1.3.0).
    bytes internal constant PROXY_CREATION = hex"608060405260405161040a38038061040a83398101604081905261002291610268565b61002c8282610033565b5050610352565b61003c82610092565b6040516001600160a01b038316907fbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b90600090a280511561008657610081828261010e565b505050565b61008e610185565b5050565b806001600160a01b03163b6000036100cd57604051634c9c8ce360e01b81526001600160a01b03821660048201526024015b60405180910390fd5b7f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc80546001600160a01b0319166001600160a01b0392909216919091179055565b6060600080846001600160a01b03168460405161012b9190610336565b600060405180830381855af49150503d8060008114610166576040519150601f19603f3d011682016040523d82523d6000602084013e61016b565b606091505b50909250905061017c8583836101a6565b95945050505050565b34156101a45760405163b398979f60e01b815260040160405180910390fd5b565b6060826101bb576101b682610205565b6101fe565b81511580156101d257506001600160a01b0384163b155b156101fb57604051639996b31560e01b81526001600160a01b03851660048201526024016100c4565b50805b9392505050565b8051156102155780518082602001fd5b604051630a12f52160e11b815260040160405180910390fd5b634e487b7160e01b600052604160045260246000fd5b60005b8381101561025f578181015183820152602001610247565b50506000910152565b6000806040838503121561027b57600080fd5b82516001600160a01b038116811461029257600080fd5b60208401519092506001600160401b03808211156102af57600080fd5b818501915085601f8301126102c357600080fd5b8151818111156102d5576102d561022e565b604051601f8201601f19908116603f011681019083821181831017156102fd576102fd61022e565b8160405282815288602084870101111561031657600080fd5b610327836020830160208801610244565b80955050505050509250929050565b60008251610348818460208701610244565b9190910192915050565b60aa806103606000396000f3fe6080604052600a600c565b005b60186014601a565b6051565b565b6000604c7f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc546001600160a01b031690565b905090565b3660008037600080366000845af43d6000803e808015606f573d6000f35b3d6000fdfea264697066735822122008caabf4d08d0971ef1e07ddea0ed06ba372754bdd8d481deec8a72240bac12c64736f6c63430008170033";

    error BadDelegation(uint8 code);
    error BadAccount();
    error AddValue(uint256 got, uint256 paid);
    error BadMint();
    error Subscribed(uint256 tokenId);
    error TransferMismatch();
    error NotOwnAccount();
    error BadPermit();
    error StalePrice(); // same selector as LPManagerModule.StalePrice
    error HedgeCap(uint256 after_, uint256 cap); // same selector as LPManagerModule.HedgeCap
    error ZeroAmount(); // same selector as LPManagerModule.ZeroAmount
    error BadParam(); // same selector as LPManagerModule.BadParam

    event Registered(address indexed account, bytes32 delegationHash, uint8 kind, uint256 until, bool first);
    event HedgeMarginReturned(address indexed account, uint256 amount, uint256 hedgeEquity, uint256 netMargin);

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
        int256 snapAsset; // idle asset the books account for (SABook: moved by booking and by the module's own effect)
        int256 snapBase; // idle base the books account for
        uint256 lastFeeTime;
        uint256 feesPaid;
        uint256 hedgeTime; // last hedge report
        uint256 pricedFlowTime; // SA-4 M-2: last booking of a material client flow with a price term (fee waits 1 day)
        uint256 bookPrice; // SA-5 M-4: the anchor of the account's last priced sync (SA-6 L-2: or of its registration)
        uint256 bookTime; // SA-6 M-1: the time of the account's last priced sync (or of its first registration)
    }

    struct Budgets {
        SAWindow.W turnover; // swap + LP-add notional (asset units)
        SAWindow.W hedge; // keeper-only hedge decreases (asset units), net of guardian-approved increases
        uint256 hedgeApproved; // guardian: exact value
        uint64 hedgeApprovedEpoch; // hedgeEpoch + 1 at approval (0 = none)
        uint64 hedgeApprovedUntil;
        uint64 hedgeApprovedEra; // guardian era at approval (a guardian change voids it)
        SAWindow.W exit; // R4: sells of base into the asset while the account holds no tracked position (risk-off)
    }

    struct PriceBudget {
        uint256 lo; // guardian range, one-shot
        uint256 hi;
        uint256 until;
        /// SA-5 M-2 / M-3: the guardian-confirmed level: the first report, then every report that consumed a guardian
        /// range. It is part of every range bound (`_bounds`): a keeper-only walk stays within refDriftBps of it over
        /// any number of days, and a fee is measured at most poolBandBps above it.
        uint256 base;
        uint256 baseTime; // SA-6 L-3: when `base` was set (a fee needs a confirmation within CONFIRM_TTL)
        SARange.R range; // SA-3: trailing 24 h (min, max) of the anchor: the drift budget is net displacement
        /// SA-6 M-1: trailing 24 h (min, max) of every keeper report (each within poolBandBps of the pool when made):
        /// the market prices a pending client flow can have happened at, for SABook.sync's high-water-mark raise.
        SARange.R seen;
    }

    /// SA-6 L-3: a fee needs the guardian-confirmed level to be at most this old.
    uint256 internal constant CONFIRM_TTL = 1 days;

    /// keccak256("elysium.SALib.usedPermit"): (owner, nonce) of every permit the module pulled on (SA-3 L-5 / L-7)
    bytes32 internal constant USED_PERMIT = 0x6abd87adb26a402fe713f1d3f200068eae79f0e9a26a829d328b8969c2899fff;

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
                || until > block.timestamp + MAX_DELEGATION_LIFETIME
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
        if (a == e.hedgeTreasury || a == e.feeRecipient) revert BadAccount(); // SA-3 I-1: before both branches
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

    /// @notice `owner()` of a hybrid account (gas-capped; 0 on failure or a non-canonical word, SA-2 I-4). A
    ///         candidate, never trusted on its own.
    function ownerOf(address a) public view returns (address o) {
        (bool ok, bytes memory r) = a.staticcall{gas: 30_000}(abi.encodeCall(IHybridDeleGator.owner, ()));
        if (ok && r.length == 32) {
            uint256 w = abi.decode(r, (uint256));
            // forge-lint: disable-next-line(unsafe-typecast)
            if (w >> 160 == 0) o = address(uint160(w));
        }
    }

    /// @notice The module may act for `a`: registered, not revoked by the client, not expired, and the account's
    ///         7702 designator / hybrid owner unchanged since registration (L-14: the module stops acting; the
    ///         delegation itself stays valid in the DM, the client re-registers or revokes). The DelegationManager's
    ///         own disabled flag is checked by the DM at redemption (and by LPManagerModule.isActive).
    function live(Account storage s, address a, bytes32 designatorHash) public view returns (bool) {
        if (s.delegationHash == 0 || s.revoked || block.timestamp >= s.until) return false;
        if (s.kind == KIND_EIP7702) return a.codehash == designatorHash;
        return ownerOf(a) == s.owner;
    }

    /// @notice Register `d` for its delegator (module storage passed in). Returns false (no-op) for the stored,
    ///         non-revoked delegation, before any other check (SA-2 L-11: top-ups keep working in the delegation's
    ///         last day). Replacing it, or registering after a revoke: only the account or its pinned owner (M-1).
    ///         Registration books nothing (SA-2 L-9 / H-1): what the account holds is a pending flow until the next
    ///         keeper sync at a trusted anchor (SABook). SA-4 M-3: a first registration starts the books from zero
    ///         (LPManagerModule.sync refuses an unregistered address; this is defence in depth). SA-6 L-2: and at the
    ///         anchor `price` of the registration (bookPrice, bookTime), so the first priced sync, which books what the
    ///         account held, gets the late-booking raise of SABook.sync like every later one.
    function register(
        mapping(address => Account) storage accts,
        mapping(address => bytes) storage ctxs,
        Delegation calldata d,
        Expect memory e,
        uint256 price
    ) external returns (bool) {
        address a = d.delegator;
        Account storage s = accts[a];
        bytes32 old = s.delegationHash;
        if (old != 0 && old == e.dm.getDelegationHash(d) && !s.revoked) return false;
        (bytes32 h, uint8 kind, uint256 until, address o) = checkDelegation(d, e);
        // M-1 / SA-3 L-14: replacing, resuming after a revoke, or a first registration of a slot the account revoked
        // in advance: only the account or its (pinned / derived) owner
        if ((old != 0 || s.revoked) && msg.sender != a && msg.sender != (old != 0 ? s.owner : o)) {
            revert NotOwnAccount();
        }
        s.delegationHash = h;
        s.owner = o;
        s.kind = kind;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.until = uint64(until);
        s.revoked = false;
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        ctxs[a] = abi.encode(ds);
        if (old == 0) {
            s.lastFeeTime = block.timestamp;
            s.snapAsset = 0;
            s.snapBase = 0;
            s.contributed = 0;
            s.hwm = 0;
            s.bookPrice = price;
            s.bookTime = block.timestamp;
        }
        emit Registered(a, h, kind, until, old == 0);
        return true;
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

    /// @notice SA-2 M-3: move `amount` USDC from the pinned owner `o` into its account `a` only on a fresh EIP-2612
    ///         permit for exactly this spender and amount. A permit that was front-run is accepted only if this very
    ///         signature was the owner's last permit (nonce - 1), it has not expired and the allowance it set is
    ///         untouched. SA-3 L-5 / L-7: every (owner, nonce) is pulled on at most once, so a consumed permit cannot
    ///         be replayed against a later standing approval of the same amount. SA-4 L-9: the once-only slot is
    ///         written here only; if the owner spends that permit's allowance through `deposit` and approves the same
    ///         amount again before the deadline, the permit can still pull it once (into the owner's own account).
    ///         SA-4 I-3: a permit call that returns must have consumed the nonce.
    function pull(address asset, address o, address a, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s_)
        external
    {
        uint256 n = IERC20Permit(asset).nonces(o);
        try IERC20Permit(asset).permit(o, address(this), amount, deadline, v, r, s_) {
            if (IERC20Permit(asset).nonces(o) != n + 1) revert BadPermit();
        } catch {
            if (n == 0 || block.timestamp > deadline) revert BadPermit();
            n -= 1;
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    IERC20Permit(asset).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, o, address(this), amount, n, deadline))
                )
            );
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s_);
            if (err != ECDSA.RecoverError.NoError || signer != o || IERC20(asset).allowance(o, address(this)) != amount) {
                revert BadPermit();
            }
        }
        bytes32 slot = keccak256(abi.encode(o, n, USED_PERMIT));
        bool used;
        assembly {
            used := sload(slot)
            sstore(slot, 1)
        }
        if (used) revert BadPermit();
        IERC20 t = IERC20(asset);
        uint256 b0 = t.balanceOf(a);
        SafeERC20.safeTransferFrom(t, o, a, amount);
        if (t.balanceOf(a) - b0 != amount) revert TransferMismatch();
    }

    // ------------------------------------------------------------------ params
    /// @notice LPManagerModule._setParams bounds, on abi.encode(Params) (11 words in declaration order): feeBps <= 2000,
    ///         hedgeCapBps <= 3500, poolBandBps 1..500, maxSlippageBps 1..500, hedgeStepBps <= 2000, refDriftBps <= 2000,
    ///         swapTurnoverBps <= 50000, feeInterval 7..365 days, maxPriceAge 60 s..1 day, minPriceStable (SA-5 L-4)
    ///         300 s..1 day, exitTurnoverBps <= 10000, and (SA-5 L-4) the stolen-keeper bound per 24 h
    ///         (refDrift + band + slippage) x (turnover + exit) <= 40% of the value.
    function checkParams(bytes memory e) external pure {
        uint256[11] memory q = abi.decode(e, (uint256[11]));
        if (
            q[0] > 2_000 || q[1] > 3_500 || q[2] == 0 || q[2] > 500 || q[3] == 0 || q[3] > 500 || q[4] > 2_000
                || q[5] > 2_000 || q[6] > 50_000 || q[7] < 7 days || q[7] > 365 days || q[8] < 60 || q[8] > 1 days
                || q[9] < 300 || q[9] > 1 days || q[10] > 10_000 || (q[5] + q[2] + q[3]) * (q[6] + q[10]) > 4_000 * BPS
        ) revert BadParam();
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
    /// @notice Move the anchor `ref` toward `p` (SA-3: net displacement, not path length). The first report
    ///         (ref == 0) is free and sets the guardian-confirmed level `base`. A new anchor must stay inside
    ///         [max / (1 + cap), min * (1 + cap)], where min / max are the lowest / highest of `base` and every anchor
    ///         held during the trailing 24 h (SARange), so the anchor's 24 h range is at most 1 + cap, an oscillation
    ///         that comes back costs nothing and (SA-5 M-2) the anchor never leaves base * (1 + cap)^(+-1) without the
    ///         guardian, however many days the keeper walks. SA-4 M-1: one keeper report moves the anchor at most
    ///         `stepBps` of it, and not at all until the last move is `stable` (minPriceStable). Cap 0 (paused) freezes
    ///         the anchor. SA-4 L-8: when the window no longer contains the anchor (a lowered cap), only a value inside
    ///         the window is applied, never a clamp against the report. A report inside an open guardian range
    ///         (one-shot) consumes it (SA-4 L-4) and becomes the new `base`; if the report did not fit the keeper's
    ///         budget it is applied unclipped and starts a new window (history forgotten: an approval never leaves the
    ///         keeper without room, SA-3 M-7 / L-2). SA-6 M-1: every report is recorded in `seen`; SA-6 L-3: every
    ///         write of `base` stamps `baseTime`.
    function movePrice(PriceBudget storage b, uint256 ref, uint256 p, uint256 capWad, uint256 stepBps, bool stable)
        external
        returns (uint256, bool)
    {
        SARange.record(b.seen, p);
        if (ref == 0) {
            b.base = p;
            b.baseTime = block.timestamp;
            SARange.record(b.range, p);
            return (p, false);
        }
        (uint256 lo, uint256 hi) = _bounds(b, ref);
        uint256 up = Math.mulDiv(lo, WAD + capWad, WAD);
        uint256 dn = Math.mulDiv(hi, WAD, WAD + capWad, Math.Rounding.Ceil);
        uint256 st = stable ? Math.mulDiv(ref, stepBps, BPS) : 0;
        if (up > ref + st) up = ref + st;
        if (dn + st < ref) dn = ref - st;
        uint256 q = p;
        if (dn > up || ref < dn || ref > up) {
            if (p < dn || p > up) q = ref; // the window does not contain the anchor (cap 0, a lowered cap)
        } else if (q > up) {
            q = up;
        } else if (q < dn) {
            q = dn;
        }
        bool clipped = q != p;
        if (block.timestamp <= b.until && p >= b.lo && p <= b.hi) {
            b.until = 0;
            b.base = p; // SA-5 M-2: the guardian confirmed this level
            b.baseTime = block.timestamp;
            if (clipped) {
                SARange.reset(b.range);
                SARange.record(b.range, p);
                return (p, false);
            }
        }
        SARange.record(b.range, ref);
        SARange.record(b.range, q);
        return (q, clipped);
    }

    /// @dev (min, max) of the anchor's trailing 24 h range, `ref` and (SA-5 M-2 / M-3) the guardian-confirmed `base`.
    function _bounds(PriceBudget storage b, uint256 ref) private view returns (uint256 lo, uint256 hi) {
        (lo, hi) = SARange.bounds(b.range, ref);
        uint256 g = b.base;
        if (g != 0) {
            if (g < lo) lo = g;
            if (g > hi) hi = g;
        }
    }

    /// @notice SA-3 M-3 / M-6: a fee is measured at the anchor (the booking price), and only while the anchor is not
    ///         above the pool and not more than `bandBps` above the lowest anchor of the trailing 24 h. A walked-up
    ///         anchor must therefore be held in public view for a day before it can carry a fee. SA-5 M-3: nor more
    ///         than `bandBps` above the guardian-confirmed `base` (the low no longer follows a walk of several days).
    ///         SA-6 L-3: and only within CONFIRM_TTL of the confirmation (a stale `base` above a market that drifted
    ///         down would otherwise let the fee be measured up to refDriftBps above the market).
    function feeGate(PriceBudget storage b, uint256 ref, uint256 pool, uint256 bandBps) external view {
        (uint256 lo,) = _bounds(b, ref);
        if (ref > pool || ref * BPS > lo * (BPS + bandBps) || block.timestamp > b.baseTime + CONFIRM_TTL) {
            revert StalePrice();
        }
    }

    /// @notice SA-5 I-1: the guardian's one-shot range, at most `maxWidthBps` wide (lo > 0, until <= now + ttl). SA-6
    ///         L-4: the module passes 2 x poolBandBps (3% at the pilot values), so the level the keeper's report picks
    ///         inside the range is at most that far from the guardian's own bounds.
    function approvePrice(PriceBudget storage b, uint256 lo, uint256 hi, uint256 until, uint256 ttl, uint256 maxWidthBps)
        external
    {
        if (lo == 0 || lo > hi || hi * BPS > lo * (BPS + maxWidthBps) || until > block.timestamp + ttl) {
            revert BadParam();
        }
        b.lo = lo;
        b.hi = hi;
        b.until = until;
    }

    /// @notice New hedge equity for a keeper report `v`. The guardian's approval for exactly this account, epoch,
    ///         era and value (unexpired) is applied as is and consumed; it also writes `netMargin` down to `v` (L-4),
    ///         and an approved increase is credited back to the decrease window (net movement). Otherwise an increase
    ///         is refused (equity kept: understated, never a fee risk) and a decrease uses at most the room left in
    ///         the window of `cap` (0 while paused or on an anchor that is not fresh). Every report records its
    ///         time. `hedgeClipped` = a keeper decrease did not fit (stored equity may be above the real one, L-12);
    ///         it is cleared only by a decrease applied in full (the keeper re-reports the real value once the window
    ///         has room again: auto-clearing) or by a guardian approval, never by an equal or higher report (SA-2
    ///         L-1). Returns (applied, applied != v).
    function moveHedge(Account storage s, Budgets storage b, uint256 v, uint256 cap, uint64 era)
        external
        returns (uint256, bool)
    {
        uint256 old = s.hedgeEquity;
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
            s.hedgeTime = block.timestamp;
            return (v, false);
        }
        if (v >= old) {
            s.hedgeTime = block.timestamp;
            return (old, v != old); // SA-2 L-1: an equal / higher report never clears hedgeClipped
        }
        // SA-3 L-3: no keeper-only decrease is possible now (paused, anchor not fresh, step 0): no state change at
        // all (no flag that outlives the cause, no report time)
        if (cap == 0) return (old, true);
        s.hedgeTime = block.timestamp;
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

    /// @notice Charge `notional` to the account's turnover window (cap turnBps x nav), or, R4, to its exit window
    ///         (cap exitBps x nav) for an `exit` sale. SA-4 L-6: an exit sale that does not fit the exit window (or
    ///         with the exit window off) falls back to the turnover window; reverts beyond it.
    function useTurnover(Budgets storage b, uint256 notional, uint256 nav, uint256 turnBps, uint256 exitBps, bool exit)
        external
    {
        if (exit && notional <= SAWindow.room(b.exit, Math.mulDiv(nav, exitBps, BPS))) {
            SAWindow.add(b.exit, notional);
            return;
        }
        SAWindow.charge(b.turnover, notional, Math.mulDiv(nav, turnBps, BPS));
    }

    /// @notice (turnover used, hedge-decrease used, exit used) in the current 24 h windows.
    function used(Budgets storage b) external view returns (uint256, uint256, uint256) {
        return (SAWindow.used(b.turnover), SAWindow.used(b.hedge), SAWindow.used(b.exit));
    }

    /// @notice SA-3: the anchor's trailing 24 h range (max / min - 1, WAD) given the current anchor `ref`.
    function priceUsed(PriceBudget storage b, uint256 ref) external view returns (uint256) {
        if (ref == 0) return 0;
        (uint256 lo, uint256 hi) = _bounds(b, ref);
        return Math.mulDiv(hi - lo, WAD, lo);
    }

    /// @notice LPManagerModule.swap bounds: (turnover charge, min-out, sqrtPrice limit). The charge is the amount in
    ///         for a buy and, SA-4 I-6, the higher of the sale's value at the keeper price and at the anchor `ref`;
    ///         min-out = max(`minOut`, fair value at the keeper price minus `slip`) (SA-2 L-15); the pool may not be
    ///         pushed beyond `band` of the anchor. SA-4 I-5 (1241): a trade worth nothing at the keeper price reverts.
    function swapBounds(
        bool sellBase,
        uint256 amountIn,
        uint256 kp,
        uint256 ref,
        uint256 minOut,
        uint256 slip,
        uint256 band,
        bool baseIsCurrency0
    ) external pure returns (uint256 charge, uint256, uint160 limit) {
        uint256 fair = sellBase ? Math.mulDiv(amountIn, kp, WAD) : Math.mulDiv(amountIn, WAD, kp);
        charge = sellBase ? Math.max(fair, Math.mulDiv(amountIn, ref, WAD)) : amountIn;
        uint256 floor = Math.mulDiv(fair, BPS - slip, BPS);
        if (minOut < floor) minOut = floor;
        if (minOut == 0 || fair == 0) revert ZeroAmount();
        limit = _sqrtPriceAt(Math.mulDiv(ref, sellBase ? BPS - band : BPS + band, BPS), baseIsCurrency0);
        return (charge, minOut, limit);
    }

    // ------------------------------------------------------------------ misc
    /// @notice sqrtPriceX96 of the pool when one 1e18 base unit is worth `price` asset units, clamped to the valid range.
    function sqrtPriceAt(uint256 price, bool baseIsCurrency0) external pure returns (uint160) {
        return _sqrtPriceAt(price, baseIsCurrency0);
    }

    function _sqrtPriceAt(uint256 price, bool baseIsCurrency0) private pure returns (uint160) {
        uint256 q = baseIsCurrency0 ? FullMath.mulDiv(price, 1 << 192, 1e18) : FullMath.mulDiv(1e18, 1 << 192, price);
        uint256 s = Math.sqrt(q);
        if (s <= TickMath.MIN_SQRT_PRICE) s = TickMath.MIN_SQRT_PRICE + 1;
        if (s >= TickMath.MAX_SQRT_PRICE) s = TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(s);
    }

    // ------------------------------------------------------------------ execution builders (ERC-7579 single calls)
    /// @dev Permit2 allowance valid while block.timestamp <= expiration, i.e. for every block with this timestamp
    ///      (several on Nitro), which is why every use is followed by an amount-0 approval (SA-2 L-13).
    function _permit2Approve(address permit2, address token, address spender, uint256 amount)
        private
        view
        returns (bytes memory)
    {
        return DelegationFramework.single(
            permit2,
            0,
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                token,
                spender,
                uint160(amount),
                amount == 0 ? 0 : uint48(block.timestamp)
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
        bytes[] memory xs = new bytes[](9);
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
        if (leg0) {
            xs[n++] = _approve(currency0, permit2, 0);
            xs[n++] = _permit2Approve(permit2, currency0, posm, 0);
        }
        if (max1 != 0) {
            xs[n++] = _approve(currency1, permit2, 0);
            xs[n++] = _permit2Approve(permit2, currency1, posm, 0);
        }
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
            xs = new bytes[](5);
            xs[0] = _approve(cIn, permit2, amountIn);
            xs[1] = _permit2Approve(permit2, cIn, executor, amountIn);
            xs[2] = DelegationFramework.single(executor, 0, call);
            xs[3] = _approve(cIn, permit2, 0);
            xs[4] = _permit2Approve(permit2, cIn, executor, 0);
        }
        _redeem(dm, ctx, xs);
    }

    /// @notice LPManagerModule.returnHedgeMargin after its sync: `amount` USDC from the treasury (which approves the
    ///         module) into account `a`, booked as the module's own effect (value moves from hedge equity to idle: not
    ///         a flow). The keeper (not `byTreasury`) returns at most min(hedge equity, net margin sent) (SA-1 H-1,
    ///         SA-4 M-3 of 1241).
    function returnMargin(Account storage s, address asset, address treasury, address a, uint256 amount, bool byTreasury)
        external
    {
        uint256 h = s.hedgeEquity;
        uint256 m = s.netMargin;
        uint256 lim = h < m ? h : m;
        if (!byTreasury && amount > lim) revert HedgeCap(amount, lim);
        SafeERC20.safeTransferFrom(IERC20(asset), treasury, a, amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.snapAsset += int256(amount);
        if (amount >= h) s.hedgeClipped = false; // SA-3 L-3: nothing left that could be overstated
        s.hedgeEquity = amount >= h ? 0 : h - amount;
        s.netMargin = amount >= m ? 0 : m - amount;
        s.hedgeEpoch++;
        emit HedgeMarginReturned(a, amount, s.hedgeEquity, s.netMargin);
    }

    /// @notice USDC from the account to one of the module's two fixed recipients, verified at the recipient (H-2:
    ///         the account's code cannot fake a balance it does not control). The account's side is booked by the
    ///         computed snapshot (SA-2: snapAsset -= amount); anything else the account's code does inside the
    ///         bracket stays a pending client flow.
    function transferOut(IDelegationManager dm, bytes storage ctx, Account storage s, address asset, address to, uint256 amount)
        external
    {
        IERC20 t = IERC20(asset);
        uint256 r0 = t.balanceOf(to);
        bytes[] memory xs = new bytes[](1);
        xs[0] = DelegationFramework.single(asset, 0, abi.encodeCall(IERC20.transfer, (to, amount)));
        _redeem(dm, ctx, xs);
        if (t.balanceOf(to) - r0 != amount) revert TransferMismatch();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.snapAsset -= int256(amount);
    }
}
