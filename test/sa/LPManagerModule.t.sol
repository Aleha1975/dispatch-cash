// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SAWindow} from "../../src/sa/SAWindow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// LPManagerModule on the offline replica (real v4 + Delegation Framework bytecode): onboarding, keeper actions,
/// per-account budgets, HWM fee, client exit. Audit regressions are in SARegressions.t.sol.
contract LPManagerModuleTest is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("bob"));
    uint256 internal constant CAROL_PK = uint256(keccak256("carol"));
    address internal attacker = makeAddr("attacker");

    function setUp() public virtual {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ onboarding
    function test_Onboard_Hybrid_TwoSignaturesNoClientTx() public {
        address owner_ = vm.addr(ALICE_PK);
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 10_000e6);
        assertEq(vm.getNonce(owner_), 0, "client sent no transaction");
        assertEq(usdc.balanceOf(owner_), 0);
        assertEq(usdc.balanceOf(a), 10_000e6);
        SALib.Account memory s = _acct(a);
        assertEq(s.delegationHash, DM.getDelegationHash(d));
        assertEq(s.kind, 1);
        assertEq(s.owner, owner_, "owner pinned (derived from the address)");
        assertEq(s.contributed, 10_000e6); // SA-2: a USDC pull is booked at face value at once
        assertEq(s.snapAsset, 10_000e6);
        assertTrue(module.isActive(a));
        _stable();
        _buyBase(a, 1_000e6); // nothing pending: the first keeper touch books nothing more
        assertEq(_acct(a).contributed, 10_000e6);
    }

    function test_Onboard_7702() public {
        (address a,) = _onboard7702(BOB_PK, 5_000e6);
        assertEq(a, vm.addr(BOB_PK));
        assertEq(_acct(a).kind, 2);
        assertEq(_acct(a).owner, a);
        assertEq(_acct(a).contributed, 0); // SA-2: registration books nothing; pending until a trusted keeper sync
        assertEq(_pending(a), 5_000e6);
        _stable();
        _buyBase(a, 2_000e6);
        assertEq(_acct(a).contributed, 5_000e6);
        uint256 id = _mintAll(a);
        assertEq(POSM.ownerOf(id), a);
    }

    function test_Onboard_PermitFrontRunTolerated() public {
        address owner_ = vm.addr(ALICE_PK);
        _deal(owner_, 1_000e6);
        address a = _deployHybrid(owner_);
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(ALICE_PK, address(module), 1_000e6, dl);
        IERC20Permit(address(usdc)).permit(owner_, address(module), 1_000e6, dl, v, r, s); // someone front-runs
        vm.prank(relayer);
        module.onboard(d, 1_000e6, dl, v, r, s);
        assertEq(usdc.balanceOf(a), 1_000e6);
    }

    function test_Onboard_FundsOnlyIntoTheOwnersAccount() public {
        // the victim's permit cannot be pointed at the attacker's account: the module pulls only from the pinned
        // owner of the account being onboarded
        address victim = vm.addr(ALICE_PK);
        _deal(victim, 1_000e6);
        uint256 atkPk = uint256(keccak256("atk"));
        address atkAcct = _deployHybrid(vm.addr(atkPk));
        Delegation memory d = _moduleDelegation(atkAcct, atkPk);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(ALICE_PK, address(module), 1_000e6, dl);
        vm.expectRevert();
        module.onboard(d, 1_000e6, dl, v, r, s);
        assertEq(usdc.balanceOf(victim), 1_000e6);
        // a 7702 account cannot take an amount at all
        (, Delegation memory db) = _onboard7702(BOB_PK, 0);
        vm.expectRevert(LPManagerModule.NotOwnAccount.selector);
        module.onboard(db, 1, dl, v, r, s);
    }

    function test_Register_Rejects() public {
        address a = _deployHybrid(vm.addr(ALICE_PK));
        uint256 until = block.timestamp + 180 days;
        bytes memory T = _terms(address(module));
        Delegation memory d;

        d = _delegation(a, attacker, T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 1));
        module.register(d);

        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d.authority = bytes32(uint256(1));
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 2));
        module.register(d);

        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        Caveat[] memory one = new Caveat[](1);
        one[0] = d.caveats[0];
        d.caveats = one;
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 3));
        module.register(d);

        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = attacker; // no custody caveat
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 4));
        module.register(d);

        d = _delegation(a, address(module), abi.encode(address(module), attacker, feeTo), until, 1);
        d.caveats[0].enforcer = address(enforcer); // treasury not ours
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 4));
        module.register(d);

        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d.caveats[1].enforcer = attacker;
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 5));
        module.register(d);

        d = _delegation(a, address(module), T, block.timestamp + 12 hours, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 6));
        module.register(d);

        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d.caveats[1].terms = abi.encodePacked(uint128(block.timestamp + 1 days), uint128(until));
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 6));
        module.register(d);

        // L-1: an expiry the module cannot store
        d = _delegation(a, address(module), T, uint256(type(uint64).max) + 1, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, ALICE_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 6));
        module.register(d);

        // L-5: unsigned caveat args
        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, ALICE_PK);
        d.caveats[1].args = new bytes(4096);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 9));
        module.register(d);

        d = _delegation(a, address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, BOB_PK);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 7));
        module.register(d); // not the owner's key

        // disabled by the client
        address e = _upgrade7702(CAROL_PK);
        Delegation memory dc = _moduleDelegation(e, CAROL_PK);
        vm.prank(e);
        DM.disableDelegation(dc);
        vm.expectRevert(abi.encodeWithSelector(SALib.BadDelegation.selector, 8));
        module.register(dc);

        // accounts that are not canonical DeleGators
        uint256 pk = uint256(keccak256("plain"));
        d = _delegation(vm.addr(pk), address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, pk);
        vm.expectRevert(SALib.BadAccount.selector);
        module.register(d);
        vm.signAndAttachDelegation(HYBRID_IMPL, pk); // 7702 to some other implementation
        d = _sign(d, pk);
        vm.expectRevert(SALib.BadAccount.selector);
        module.register(d);
        d = _delegation(address(trader), address(module), T, until, 1);
        d.caveats[0].enforcer = address(enforcer);
        d.signature = new bytes(65);
        vm.expectRevert(SALib.BadAccount.selector);
        module.register(d);
    }

    function test_Register_NeedsAnchor() public {
        LPManagerModule m2 = new LPManagerModule(_config(address(timelock), keeper, guardian));
        address a = _deployHybrid(vm.addr(ALICE_PK));
        Delegation memory d = _delegation(a, address(m2), _terms(address(m2)), block.timestamp + 180 days, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, ALICE_PK);
        vm.expectRevert(LPManagerModule.NoAnchor.selector);
        m2.register(d);
    }

    function test_Keeper_CannotRedeemRaw() public {
        (address a,) = _onboardHybrid(ALICE_PK, 1_000e6);
        bytes[] memory c = new bytes[](1);
        c[0] = module.permissionContext(a);
        ModeCode[] memory m = new ModeCode[](1);
        bytes[] memory x = new bytes[](1);
        x[0] = abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(IERC20.transfer, (treasury, 1)));
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("InvalidDelegate()")));
        DM.redeemDelegations(c, m, x);
    }

    // ------------------------------------------------------------------ roles
    function test_OnlyKeeper() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
        uint256 p = poolPrice();
        address[2] memory who = [attacker, guardian];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.reportPrice(p);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.mintPosition(a, -60, 60, 1, 1, 1, p);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.increasePosition(a, id, 1, 1, 1, p);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.decreasePosition(a, id, 1, 0, 0);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.burnPosition(a, id, 0, 0);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.swap(a, true, 1, p, 0);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.sendHedgeMargin(a, 1);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.returnHedgeMargin(a, 1);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.reportHedgeEquity(a, 1);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.chargeFee(a);
            vm.expectRevert(LPManagerModule.NotKeeper.selector);
            module.multicall(new bytes[](0), false);
            vm.stopPrank();
        }
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotGuardian.selector);
        module.approvePrice(1, type(uint256).max, block.timestamp + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotGuardian.selector);
        module.approveHedgeEquity(a, 0, 0, 1, block.timestamp + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotGuardian.selector);
        module.setPaused(true);
    }

    function test_L8_L13_RolesAndParams() public {
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(_config(address(timelock), keeper, keeper));
        LPManagerModule.Config memory c = _config(address(timelock), keeper, guardian);
        c.params.feeBps = 2001;
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        c = _config(address(timelock), keeper, guardian);
        c.params.hedgeCapBps = 3501;
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        c = _config(address(timelock), keeper, guardian);
        c.params.feeInterval = 6 days;
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        c = _config(address(timelock), keeper, guardian);
        c.params.maxSlippageBps = 0; // I-3: would brick every swap and add
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        c = _config(address(timelock), keeper, guardian);
        c.feeRecipient = treasury;
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        // L-8: the hot key may not be the treasury or the fee recipient; the owner is distinct too
        c = _config(address(timelock), treasury, guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        c = _config(address(timelock), keeper, feeTo);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        c = _config(keeper, keeper, guardian);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        new LPManagerModule(c);
        // the enforcer / executor must be wired to the same venue
        c = _config(address(timelock), keeper, guardian);
        c.swapExecutor = address(new SwapExecutor(PM, PERMIT2, key));
        vm.expectRevert(LPManagerModule.BadWiring.selector);
        new LPManagerModule(c);

        assertEq(module.owner(), address(timelock));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        module.setKeeper(attacker);
        address[4] memory bad = [guardian, treasury, feeTo, address(timelock)];
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(LPManagerModule.BadParam.selector);
            vm.prank(address(timelock));
            module.setKeeper(bad[i]);
        }
        vm.expectRevert(LPManagerModule.BadParam.selector);
        vm.prank(address(timelock));
        module.setGuardian(keeper);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        vm.prank(address(timelock));
        module.setGuardian(treasury);
        vm.expectRevert(LPManagerModule.BadParam.selector);
        module.renounceOwnership();
        _schedule(address(module), abi.encodeCall(LPManagerModule.setKeeper, (attacker)));
        assertEq(module.keeper(), attacker);
    }

    // ------------------------------------------------------------------ price anchor and keeper price
    function test_M10_KeeperPriceWithinBandOfPoolAndAnchor() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 2_000e6);
        uint256 anchor = module.lastPrice();
        _moveTo(anchor * 10_250 / 10_000);
        uint256 p = poolPrice();
        vm.startPrank(keeper);
        vm.expectRevert(LPManagerModule.BadPrice.selector); // in band of the pool, not of the anchor
        module.swap(a, false, 100e6, p, 0);
        vm.expectPartialRevert(LPManagerModule.PoolPriceOff.selector); // the anchor itself is off the pool
        module.swap(a, false, 100e6, anchor, 0);
        // a price in band of both passes the price check; buying base would push the pool further past the
        // anchor band (L-15 limit), selling base moves it back
        vm.expectRevert();
        module.swap(a, false, 100e6, anchor * 10_140 / 10_000, 0);
        module.swap(a, true, 1 ether, anchor * 10_140 / 10_000, 0);
        vm.stopPrank();
    }

    function test_H2_AnchorMovesOnlyWithinBudgetAndFreezesWhilePaused() public {
        uint256 anchor = module.lastPrice();
        _moveTo(anchor * 112 / 100);
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.reportPrice(p);
        assertTrue(module.lastPriceClipped());
        assertApproxEqRel(module.lastPrice(), anchor * 110 / 100, 1e15);
        // budget used up: a second report cannot move it further
        vm.prank(keeper);
        module.reportPrice(p);
        assertApproxEqRel(module.lastPrice(), anchor * 110 / 100, 1e15);
        vm.warp(vm.getBlockTimestamp() + 27 hours); // the sliding window has passed
        vm.prank(keeper);
        module.reportPrice(p);
        assertFalse(module.lastPriceClipped());
        assertEq(module.lastPrice(), p);
        // paused: frozen, unless the guardian approves a range
        vm.prank(guardian);
        module.setPaused(true);
        _moveTo(p * 103 / 100);
        uint256 p2 = poolPrice();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(keeper);
        module.reportPrice(p2);
        assertEq(module.lastPrice(), p);
        vm.prank(guardian);
        module.approvePrice(p2 * 99 / 100, p2 * 101 / 100, block.timestamp + 1 hours);
        vm.prank(keeper);
        module.reportPrice(p2);
        assertEq(module.lastPrice(), p2);
    }

    // ------------------------------------------------------------------ swaps (L-15) and turnover
    function test_L15_SwapLimitedToAnchorBand() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        uint256 anchor = module.lastPrice();
        _moveTo(anchor * 9_760 / 10_000); // pool 2.4% below the anchor
        uint256 kp = anchor * 9_860 / 10_000; // within 1.5% of both
        uint256 hype = a.balance / 2;
        vm.prank(keeper);
        vm.expectRevert(); // selling base would push the pool further below the anchor band edge
        module.swap(a, true, hype, kp, 0);
        vm.prank(keeper);
        module.swap(a, false, 100e6, kp, 0); // buying base moves it back toward the anchor: fine
    }

    function test_SwapTurnoverIsPerAccount() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        (address b,) = _onboardHybrid(BOB_PK, 10_000e6);
        uint256 p = poolPrice();
        // 2x account value per 24 h window: 10k account -> ~20k notional
        for (uint256 i; i < 2; ++i) {
            vm.prank(keeper);
            module.swap(a, false, 4_000e6, p, 0);
            _moveTo(p);
            vm.prank(keeper);
            module.swap(a, true, a.balance, p, 0);
            _moveTo(p);
        }
        vm.prank(keeper);
        vm.expectRevert(SAWindow.WindowOverflow.selector);
        module.swap(a, false, 5_000e6, p, 0);
        vm.prank(keeper);
        module.swap(b, false, 5_000e6, p, 0); // bob's budget is his own
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _report();
        p = poolPrice();
        vm.prank(keeper);
        module.swap(a, false, 4_000e6, p, 0);
    }

    // ------------------------------------------------------------------ LP adds (H-3)
    function test_H3_LimitOrderMintAtDisplacedSpotReverts() public {
        (address a,) = _onboardHybrid(ALICE_PK, 20_000e6);
        uint256 anchor = module.lastPrice();
        _moveTo(anchor * 10_270 / 10_000);
        uint256 kp = anchor * 10_145 / 10_000;
        int24 t = _tick();
        int24 tu = t / 60 * 60 - 60; // just below spot: a USDC-only "limit order"
        int24 tl = tu - 60;
        uint128 liq =
            LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 10_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(SALib.AddValue.selector);
        module.mintPosition(a, tl, tu, liq, 0, 10_000e6, kp);
    }

    function test_H3_MintChargesTurnover() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        uint256 before = _turnoverUsed(a);
        _mintAll(a);
        assertGt(_turnoverUsed(a), before);
    }

    function test_TooManyPositionsAndUnknownPosition() public {
        (address a,,) = _invested(ALICE_PK, 20_000e6);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.UnknownPosition.selector);
        module.decreasePosition(a, 1, 1, 0, 0); // lp's NFT, not tracked for this account
    }

    // ------------------------------------------------------------------ hedge (M-5 of round 1, H-1, M-2)
    function test_M5_HedgeCapOnMaxOfEquityAndNetMargin() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _syncTouch(a);
        uint256 v = module.accountValue(a, module.lastPrice());
        uint256 cap = v * 3500 / 10_000;
        vm.prank(keeper);
        module.sendHedgeMargin(a, cap - 10e6);
        assertEq(usdc.balanceOf(treasury), cap - 10e6);
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.HedgeCap.selector);
        module.sendHedgeMargin(a, 20e6);
        // reporting a lower equity does not free room: net margin still counts
        _reportEquity(a, (cap - 10e6) * 95 / 100);
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.HedgeCap.selector);
        module.sendHedgeMargin(a, 20e6);
        // margin returns flow back into the account and free room
        vm.prank(keeper);
        module.returnHedgeMargin(a, 1_000e6);
        assertEq(_acct(a).netMargin, cap - 10e6 - 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 27 hours); // the enforcer's own 35% / 24 h window on idle USDC
        _report();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 500e6);
    }

    function test_H1_HedgeEquityOnlyDownWithoutGuardian() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        (address b,) = _onboardHybrid(BOB_PK, 10_000e6);
        _syncTouch(a);
        _syncTouch(b);
        vm.startPrank(keeper);
        module.sendHedgeMargin(a, 3_000e6);
        module.sendHedgeMargin(b, 3_000e6);
        uint256 ep = _acct(a).hedgeEpoch;
        // fake increase: refused, never reverts, does not move the epoch (L-7)
        module.reportHedgeEquity(a, 5_000e6);
        assertEq(_acct(a).hedgeEquity, 3_000e6);
        assertEq(_acct(a).hedgeEpoch, ep);
        // decrease beyond 5% of the account value per day: clipped to the budget
        module.reportHedgeEquity(a, 1_000e6);
        assertApproxEqAbs(_acct(a).hedgeEquity, 3_000e6 - 500e6, 1e6);
        assertTrue(_acct(a).hedgeClipped);
        vm.stopPrank();
        // guardian: exact value for this account, epoch and stored value
        SALib.Account memory s = _acct(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 4_000e6, block.timestamp + 1 hours);
        // the approval does not apply to another account
        _reportEquity(b, 4_000e6);
        assertEq(_acct(b).hedgeEquity, 3_000e6);
        _reportEquity(a, 4_000e6);
        assertEq(_acct(a).hedgeEquity, 4_000e6);
        assertEq(_acct(a).hedgeEpoch, s.hedgeEpoch + 1);
        assertFalse(_acct(a).hedgeClipped);
        // one-shot
        _reportEquity(a, 3_900e6);
        s = _acct(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, 4_000e6, block.timestamp + 1 hours);
        // cleared by a margin move (judged against the old state)
        vm.prank(keeper);
        module.returnHedgeMargin(a, 100e6);
        _reportEquity(a, 4_000e6);
        assertLt(_acct(a).hedgeEquity, 4_000e6);
        // expired approvals do nothing
        s = _acct(a);
        vm.prank(guardian);
        module.approveHedgeEquity(a, s.hedgeEpoch, s.hedgeEquity, s.hedgeEquity + 1_000e6, block.timestamp + 1 hours);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _reportEquity(a, s.hedgeEquity + 1_000e6);
        assertEq(_acct(a).hedgeEquity, s.hedgeEquity);
    }

    // ------------------------------------------------------------------ pause (round 1 M-6 / L-16; SA-1 L-6)
    function test_M6_PauseStopsRiskNotExits() public {
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 10_000e6);
        (address b,) = _onboardHybrid(BOB_PK, 10_000e6);
        _syncTouch(b);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 1_000e6);
        _buyBase(a, 3_600e6);
        uint256 id = _mintAll(a);
        vm.prank(guardian);
        module.setPaused(true);
        uint256 p = poolPrice();
        vm.startPrank(keeper);
        vm.expectRevert(LPManagerModule.IsPaused.selector);
        module.swap(a, false, 100e6, p, 0);
        vm.expectRevert(LPManagerModule.IsPaused.selector);
        module.mintPosition(a, -60, 60, 1, 1, 1, p);
        vm.expectRevert(LPManagerModule.IsPaused.selector);
        module.increasePosition(a, id, 1, 1, 1, p);
        vm.expectRevert(LPManagerModule.IsPaused.selector);
        module.chargeFee(a);
        // SA-1 L-6: the pause is a stop for custody growth and keeper-only equity cuts
        vm.expectRevert(LPManagerModule.IsPaused.selector);
        module.sendHedgeMargin(b, 100e6);
        module.reportHedgeEquity(a, 500e6);
        assertEq(_acct(a).hedgeEquity, 1_000e6, "frozen while paused");
        // risk-reducing actions continue
        module.decreasePosition(a, id, POSM.getPositionLiquidity(id) / 2, 0, 0);
        module.returnHedgeMargin(a, 200e6);
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        module.setPaused(false);
        // the client exits while paused
        _exitHybrid(ALICE_PK, a, d, a);
        assertFalse(module.isActive(a));
        vm.expectRevert();
        POSM.ownerOf(id);
        _schedule(address(module), abi.encodeCall(LPManagerModule.setPaused, (false)));
        assertFalse(module.paused());
    }

    // ------------------------------------------------------------------ fee
    function test_Fee_HighWaterMarkLifecycle() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        uint256 p0 = module.lastPrice();
        assertLe(_profit(a), 0); // swap fee + rounding
        // third-party volume earns LP fees
        _volume(200_000, 25);
        _moveTo(p0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _syncTouch(a); // collect fees into idle
        int256 profit = _profit(a);
        assertGt(profit, 0, "LP fees made a profit");
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        assertEq(f, uint256(profit) * 1500 / 10_000);
        assertEq(usdc.balanceOf(feeTo), f);
        assertEq(_acct(a).hwm, profit - int256(f));
        assertEq(_acct(a).feesPaid, f);
        // not again within the interval
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.FeeTooEarly.selector);
        module.chargeFee(a);
        // a drawdown below the mark charges nothing
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        vm.prank(keeper);
        assertEq(module.chargeFee(a), 0);
    }

    function test_Fee_DepositsAndWithdrawalsAreFlowsNotProfit() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _syncTouch(a);
        int256 p0 = _profit(a);
        int256 c0 = _acct(a).contributed;
        // the client sends 5k USDC directly to its account
        address owner_ = vm.addr(ALICE_PK);
        _deal(owner_, 5_000e6);
        vm.prank(owner_);
        usdc.transfer(a, 5_000e6);
        _syncTouch(a);
        assertEq(_acct(a).contributed, c0 + 5_000e6);
        assertApproxEqAbs(_profit(a), p0, 2);
        // ...and takes 3k USDC + 1 HYPE out with its own key
        _buyBase(a, 1_000e6);
        p0 = _profit(a); // the buy's pool fee
        int256 c1 = _acct(a).contributed;
        Execution[] memory xs = new Execution[](2);
        xs[0] = Execution(address(usdc), 0, abi.encodeCall(IERC20.transfer, (owner_, 3_000e6)));
        xs[1] = Execution(owner_, 1 ether, "");
        _clientExec(ALICE_PK, a, xs);
        uint256 ref = module.lastPrice(); // SA-2: every flow at the anchor, the price `value` uses
        _syncTouch(a);
        assertEq(c1, c0 + 5_000e6);
        assertApproxEqAbs(_acct(a).contributed, c1 - 3_000e6 - int256(ref), 2);
        assertApproxEqAbs(_profit(a), p0, 2, "a flow never moves profit");
        // no fee on any of it
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _stable();
        vm.prank(keeper);
        assertLe(module.chargeFee(a), 1e6 * 1500 / 10_000);
    }

    function test_Fee_DirectBurnByClientIsNotAFlowOfValue() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
        _syncTouch(a);
        int256 p0 = _profit(a);
        Execution[] memory xs = new Execution[](1);
        xs[0] = Execution(
            POSM_ADDR,
            0,
            abi.encodeCall(
                IPositionManagerMin.modifyLiquidities,
                (V4PositionMath.removeData(true, id, 0, 0, 0, address(0), address(usdc), a), block.timestamp)
            )
        );
        _clientExec(ALICE_PK, a, xs);
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.swap(a, false, 10e6, p, 0);
        assertEq(module.positionsOf(a).length, 0, "untracked after the client burned it");
        assertApproxEqRel(uint256(_acct(a).contributed), 10_000e6, 3e15);
        assertApproxEqAbs(_profit(a), p0, 30e6); // only the 10 USDC swap's fee and the anchor/pool spread
    }

    function test_Fee_NeedsFreshUnclippedPriceAndChargesAtMostTheIdleSlice() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _volume(200_000, 25);
        _moveTo(module.lastPrice());
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.StalePrice.selector);
        module.chargeFee(a);
        _report();
        _syncTouch(a);
        int256 profit = _profit(a);
        assertGt(profit, 0);
        uint256 full = uint256(profit) * 1500 / 10_000;
        uint256 idle = usdc.balanceOf(a);
        // L-11: almost everything is in the position: charge the 20%-of-idle slice, advance the mark by its gain
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        assertEq(f, Math.min(full, idle * 2000 / 10_000));
        if (f < full) {
            assertEq(_acct(a).hwm, int256(f * 10_000 / 1500) - int256(f));
            assertLt(_acct(a).hwm, profit - int256(full));
        }
    }

    function testFuzz_HwmFee(int128 profit, int128 hwm, uint16 bps, uint64 maxFee) public pure {
        bps = uint16(bound(bps, 1, 2000));
        (uint256 f, int256 h) = SALib.hwmFee(profit, hwm, bps, maxFee);
        if (profit <= hwm) {
            assertEq(f, 0);
            assertEq(h, hwm);
        } else {
            uint256 full = uint256(int256(profit) - hwm) * bps / 10_000;
            assertEq(f, Math.min(full, maxFee));
            assertGe(h, hwm);
            assertLe(h, int256(profit) - int256(f)); // never marks more gain than was charged for
            if (f == full) assertEq(h, int256(profit) - int256(f));
        }
    }

    // ------------------------------------------------------------------ client exit
    function test_Exit_Hybrid_OneTransaction() public {
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 10_000e6);
        _syncTouch(a);
        vm.prank(keeper);
        module.sendHedgeMargin(a, 1_500e6);
        _buyBase(a, 3_400e6);
        uint256 id = _mintAll(a);
        uint256 usdc0 = usdc.balanceOf(a);
        _exitHybrid(ALICE_PK, a, d, a);
        assertTrue(DM.disabledDelegations(DM.getDelegationHash(d)));
        assertTrue(_acct(a).revoked);
        assertFalse(module.isActive(a));
        assertGt(usdc.balanceOf(a), usdc0);
        vm.expectRevert();
        POSM.ownerOf(id);
        // the keeper can no longer act on the account
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(LPManagerModule.NotLive.selector);
        module.swap(a, false, 10e6, p, 0);
        // hedge margin comes back into the account (B: always bracketed, never to an address the account reports)
        int256 c0 = _acct(a).contributed;
        uint256 bal = usdc.balanceOf(a);
        vm.prank(keeper);
        module.returnHedgeMargin(a, 1_500e6);
        assertEq(usdc.balanceOf(a), bal + 1_500e6);
        assertEq(_acct(a).netMargin, 0);
        // the margin coming back is not a deposit; the client's burn is booked conservatively (in at min, out at max)
        assertApproxEqRel(_acct(a).contributed, c0, 1e15);
        assertLt(_acct(a).contributed, c0 + 1_000e6);
    }

    function test_Exit_7702_OneTransaction() public {
        (address a, Delegation memory d) = _onboard7702(BOB_PK, 10_000e6);
        _buyBase(a, 4_000e6);
        uint256 id = _mintAll(a);
        _exit7702(a, d, a);
        assertTrue(DM.disabledDelegations(DM.getDelegationHash(d)));
        assertFalse(module.isActive(a));
        vm.expectRevert();
        POSM.ownerOf(id);
        assertGt(usdc.balanceOf(a), 5_000e6);
    }

    function test_Exit_WorksWhileDelegationManagerPaused() public {
        (address a, Delegation memory d,) = _invested(ALICE_PK, 10_000e6);
        vm.prank(DM_OWNER);
        (bool ok,) = DM_ADDR.call(abi.encodeWithSignature("pause()"));
        assertTrue(ok);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert(); // management halts
        module.swap(a, false, 10e6, p, 0);
        // the client's own exit never goes through redeemDelegations
        _exitHybrid(ALICE_PK, a, d, vm.addr(ALICE_PK));
        assertGt(usdc.balanceOf(vm.addr(ALICE_PK)), 0);
        assertFalse(module.isActive(a));
    }

    function test_ReRegister_ByTheClientKeepsBooks() public {
        (address a,,) = _invested(ALICE_PK, 10_000e6);
        _syncTouch(a);
        int256 c0 = _acct(a).contributed;
        Delegation memory d2 = _delegation(a, address(module), _terms(address(module)), block.timestamp + 360 days, 2);
        d2.caveats[0].enforcer = address(enforcer);
        d2 = _sign(d2, ALICE_PK);
        vm.expectRevert(SALib.NotOwnAccount.selector); // M-1: not by a third party
        module.register(d2);
        vm.prank(vm.addr(ALICE_PK)); // the owner EOA, one plain transaction
        module.register(d2);
        assertEq(_acct(a).delegationHash, DM.getDelegationHash(d2));
        assertEq(_acct(a).contributed, c0);
        assertEq(_acct(a).until, block.timestamp + 360 days);
    }

    // ------------------------------------------------------------------ batching
    function test_Multicall_ManyAccounts() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        (address b,) = _onboardHybrid(BOB_PK, 10_000e6);
        uint256 p = poolPrice();
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(LPManagerModule.swap, (a, false, 3_000e6, p, 0));
        calls[1] = abi.encodeCall(LPManagerModule.swap, (b, false, 3_000e6, p, 0));
        calls[2] = abi.encodeCall(LPManagerModule.sendHedgeMargin, (b, 1_000_000e6)); // fails: over the cap
        vm.prank(keeper);
        vm.expectPartialRevert(LPManagerModule.HedgeCap.selector);
        module.multicall(calls, false);
        vm.prank(keeper);
        module.multicall(calls, true);
        assertGt(a.balance, 0);
        assertGt(b.balance, 0);
    }

    // ------------------------------------------------------------------ SwapExecutor
    function test_SwapExecutor_PaysCallerOnlyAndRefundsNative() public {
        address user = makeAddr("user");
        vm.deal(user, 2_000 ether);
        uint256 p = poolPrice();
        // limit 0.5% below spot: a big sell stops there, the rest of the native input is refunded
        uint160 lim = SALib.sqrtPriceAt(p * 9_950 / 10_000, true);
        vm.prank(user);
        uint256 out = executor.swap{value: 2_000 ether}(true, 2_000 ether, 1, lim);
        assertEq(usdc.balanceOf(user), out);
        assertGt(user.balance, 0, "unspent HYPE refunded");
        assertEq(address(executor).balance, 0);
        assertEq(usdc.balanceOf(address(executor)), 0);
        vm.expectRevert(SwapExecutor.NotPoolManager.selector);
        executor.unlockCallback(abi.encode(user, true, uint256(1), uint160(0)));
        vm.prank(user);
        vm.expectRevert(SwapExecutor.BadValue.selector);
        executor.swap{value: 1}(false, 1e6, 1, 0);
        vm.prank(user);
        vm.expectPartialRevert(SwapExecutor.BelowMinOut.selector);
        executor.swap{value: 1 ether}(true, 1 ether, type(uint128).max, 0);
    }

    // ------------------------------------------------------------------ gas (docs)
    function test_Gas_FullReRange() public {
        (address a,, uint256 id) = _invested(ALICE_PK, 10_000e6);
        _moveTo(module.lastPrice() * 10_100 / 10_000);
        _report();
        uint256 g = gasleft();
        vm.prank(keeper);
        module.burnPosition(a, id, 0, 0);
        uint256 gBurn = g - gasleft();
        g = gasleft();
        _buyBase(a, 500e6);
        uint256 gSwap = g - gasleft();
        g = gasleft();
        _mintAll(a);
        uint256 gMint = g - gasleft();
        g = gasleft();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 100e6);
        uint256 gHedge = g - gasleft();
        emit log_named_uint("burn", gBurn);
        emit log_named_uint("swap", gSwap);
        emit log_named_uint("mint", gMint);
        emit log_named_uint("hedge send", gHedge);
    }
}
