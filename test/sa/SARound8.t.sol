// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";

/// Audit SA-8 (report 1256 of commit 3f0f42d, docs/audit/sa_round8_response.md) regressions. Every test marked
/// "fails on 3f0f42d" fails there and passes after the fix (checked by running this file and SATestBase.sol against
/// the old sources; the file uses only interfaces that exist there).
contract SARound8Test is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("alice"));
    uint256 internal constant FEE_BPS = 1500;

    function setUp() public {
        _setUpEnv(false);
    }

    // ------------------------------------------------------------------ helpers
    function _keeperSync(address a) internal {
        vm.prank(keeper);
        module.sync(a);
    }

    function _fee(address a) internal returns (uint256) {
        vm.prank(keeper);
        return module.chargeFee(a);
    }

    /// After `feeInterval`: a fresh, stable, guardian-confirmed anchor at the pool.
    function _feeTime() internal {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        _stable();
        _fresh();
        _stable();
    }

    /// A hybrid account (not registered yet) holding `hype` HYPE and `usd` USDC.
    function _funded(uint256 hype, uint256 usd) internal returns (address a) {
        a = _deployHybrid(vm.addr(ALICE_PK));
        vm.deal(a, hype);
        _deal(a, usd);
    }

    function _register(address a) internal {
        Delegation memory d = _moduleDelegation(a, ALICE_PK);
        vm.prank(relayer);
        module.register(d);
    }

    // ================================================================== M-1: the opening booking had no floor
    /// PoC (report trace, honest keeper, registrant picks the moment): the market (pool) is 40 bps above a trusted
    /// anchor; the account holds 1,000 HYPE. On 3f0f42d the registration booked the HYPE at the anchor with hwm = 0,
    /// and once the anchor caught up the gap was charged as profit (about 15% x 1,000 x 0.16 USDC). Now registration
    /// books nothing and the first booking is a priced booking like any other (hwm = max(profit, hwm + priced)): no
    /// fee on the gap. Fails on 3f0f42d.
    function test_M1_PoC_OpeningBelowMarketNoFeeOnPrincipal() public {
        address a = _funded(1_000 ether, 20_000e6);
        _stable();
        uint256 p0 = module.lastPrice();
        _moveTo(p0 * 10_040 / 10_000); // still within BOOK_BAND_BPS of the anchor: trusted
        uint256 mkt = poolPrice();
        _register(a);
        _reportTo(); // the anchor reaches the market
        _feeTime();
        uint256 f = _fee(a);
        // true profit: value now minus what the client brought, at the price it brought it
        int256 truth = int256(module.accountValue(a, module.lastPrice())) + int256(f)
            - int256(20_000e6 + 1_000 * mkt);
        uint256 cap = truth > 0 ? uint256(truth) * FEE_BPS / 10_000 : 0;
        assertLe(f, cap + 1e5, "no fee on the anchor's lag at registration");
    }

    /// Registration books nothing (SA-8 M-1): the registrant no longer chooses a booking moment or price (I-12 is
    /// gone with it). The first sync at a trusted anchor books the holdings and raises hwm by the HYPE's value (the
    /// floor of every priced booking). Fails on 3f0f42d (the registration booked the holdings with hwm = 0).
    function test_M1_RegistrationBooksNothingFirstBookingHasFloor() public {
        address a = _funded(100 ether, 20_000e6);
        _stable();
        _register(a);
        assertEq(_acct(a).contributed, 0, "nothing booked at registration");
        assertEq(_acct(a).hwm, 0);
        _keeperSync(a);
        uint256 p = module.lastPrice();
        assertEq(_acct(a).contributed, int256(20_000e6 + 100 * p));
        assertGe(_acct(a).hwm, int256(100 * p), "the floor: hwm + value of the HYPE booked");
    }

    /// USDC-only onboarding (the product path for a hybrid account) costs no fee: no base, no priced booking, hwm 0.
    /// Passes on both commits.
    function test_M1_UsdcOnlyOnboardingKeepsFullFee() public {
        (address a,) = _onboardHybrid(ALICE_PK, 20_000e6);
        _stable();
        _keeperSync(a);
        assertEq(_acct(a).contributed, 20_000e6);
        assertEq(_acct(a).hwm, 0, "no floor without base");
    }

    // ================================================================== L-1: the fee credit absorbed a base inflow
    /// Invested account with uncollected LP fees; pool back at the anchor, anchor trusted, everything booked.
    function _withFees() internal returns (address a, uint256 id) {
        (a,, id) = _invested(ALICE_PK, 30_000e6);
        uint256 ref = module.lastPrice();
        _volume(20_000, 10);
        _moveTo(ref);
        _syncTouch(a);
        _volume(20_000, 10);
        _moveTo(ref);
        _stable();
    }

    function _clientCollect(address a, uint256 id, address to) internal {
        bytes memory data = abi.encodeCall(
            IPositionManagerMin.modifyLiquidities,
            (V4PositionMath.removeData(false, id, 0, 0, 0, address(0), address(usdc), to), block.timestamp)
        );
        _clientExec1(ALICE_PK, a, POSM_ADDR, 0, data);
    }

    /// PoC (report trace A): the client collects its position's fees to its own wallet, then sends the base part
    /// back. On 3f0f42d the credit inferred from the fee mark filled the room the inflow made, so the base inflow was
    /// booked as nothing (unpriced: no contribution, no raise) although it came back at another price. Now the
    /// booking sees the raw base change first and gives no credit at all in it: the inflow is a priced contribution.
    /// Fails on 3f0f42d.
    function test_L1_PoC_BaseInflowNotAbsorbedByCredit() public {
        (address a, uint256 id) = _withFees();
        address eoa = vm.addr(ALICE_PK);
        uint256 h0 = eoa.balance;
        _clientCollect(a, id, eoa);
        uint256 b = eoa.balance - h0;
        assertGt(b, 1e15, "base fees collected");
        int256 c0 = _acct(a).contributed;
        vm.deal(a, a.balance + b); // the client sends the base back
        _stable();
        _keeperSync(a);
        assertApproxEqAbs(_acct(a).contributed, c0 + int256(b * module.lastPrice() / 1e18), 2, "a priced inflow");
        assertGe(_acct(a).hwm, _profit(a), "the booking is priced");
    }

    /// Sibling: the client collects into the account. The base fees change idle base, so nothing is credited: the
    /// collect is a priced contribution (our fee lower; never the client's principal). Fails on 3f0f42d (credited).
    function test_L1_Sibling_CollectWithBaseIsPricedContribution() public {
        (address a, uint256 id) = _withFees();
        (uint256 u0, uint256 h0) = (usdc.balanceOf(a), a.balance);
        int256 c0 = _acct(a).contributed;
        _clientCollect(a, id, a);
        uint256 p = module.lastPrice();
        uint256 fees = usdc.balanceOf(a) - u0 + (a.balance - h0) * p / 1e18;
        assertGt(a.balance, h0);
        _keeperSync(a);
        assertApproxEqAbs(_acct(a).contributed, c0 + int256(fees), 2, "no credit in a booking where base changed");
        assertGe(_acct(a).hwm, _profit(a));
    }

    // ================================================================== L-2: unpause re-confirms the anchor
    /// While paused the anchor is frozen but the keeper keeps refreshing it; the timelock unpauses. On 3f0f42d the
    /// frozen anchor was trusted in the same block (a pending flow booked at it at once). Now the unpause counts as an
    /// anchor move: nothing is booked until minPriceStable after it, with a report after it. Fails on 3f0f42d.
    function test_L2_UnpauseReconfirmsAnchor() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _stable();
        _keeperSync(a);
        vm.prank(guardian);
        module.setPaused(true);
        bytes memory data = abi.encodeCall(LPManagerModule.setPaused, (false));
        vm.prank(operator);
        timelock.schedule(address(module), 0, data, bytes32(0), bytes32(0), 2 days);
        uint256 p = module.lastPrice();
        uint256 end = vm.getBlockTimestamp() + 2 days + 1;
        while (vm.getBlockTimestamp() < end) {
            vm.warp(vm.getBlockTimestamp() + 240);
            vm.prank(keeper);
            module.reportPrice(p);
        }
        vm.deal(a, a.balance + 1 ether); // a pending price-dependent flow
        int256 c0 = _acct(a).contributed;
        vm.prank(operator);
        timelock.execute(address(module), 0, data, bytes32(0), bytes32(0));
        _keeperSync(a);
        assertEq(_acct(a).contributed, c0, "the frozen anchor is not trusted at the unpause");
        _stable();
        _keeperSync(a);
        assertGt(_acct(a).contributed, c0, "booked once re-confirmed");
    }

    // ================================================================== L-3: a refresh is not checked against the pool
    /// A third party holds the pool 2% away (beyond poolBandBps). On 3f0f42d every report, even one that only
    /// re-reports the stored anchor, reverted PoolPriceOff, so the anchor aged out (margin sends stopped after
    /// maxPriceAge). Now a pure refresh is accepted; a move off the band still reverts, and nothing is booked while
    /// the pool is off (every consumer re-checks the pool). Fails on 3f0f42d.
    function test_L3_RefreshAcceptedOffPoolBand() public {
        (address a,) = _onboardHybrid(ALICE_PK, 10_000e6);
        _stable();
        _keeperSync(a);
        uint256 p = module.lastPrice();
        _moveTo(p * 10_200 / 10_000);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(keeper);
        module.reportPrice(p);
        assertEq(module.lastPriceTime(), vm.getBlockTimestamp(), "refreshed");
        assertEq(module.lastPrice(), p);
        vm.prank(keeper);
        vm.expectRevert();
        module.reportPrice(p * 1001 / 1000); // a move off the pool band
        _deal(a, usdc.balanceOf(a) + 1_000e6);
        int256 c0 = _acct(a).contributed;
        _keeperSync(a);
        assertEq(_acct(a).contributed, c0, "not trusted while the pool is off");
    }
}
