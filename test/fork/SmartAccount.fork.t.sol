// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../sa/SATestBase.sol";

/// Smart-account flow end to end on a local fork of Elysium mainnet (chain 99901): the real HYPE/USDC v4 pool, the real
/// USDC (EIP-2612 permit), the DelegationManager / EIP7702StatelessDeleGator / TimestampEnforcer already deployed
/// there; HybridDeleGatorImpl + SimpleFactory created at their canonical CREATE2 addresses. Enable with
/// ELYSIUM_FORK=true (optionally ELYSIUM_RPC, ELYSIUM_FORK_BLOCK). Nothing is broadcast.
contract SmartAccountForkTest is SATestBase {
    uint256 internal constant ALICE_PK = uint256(keccak256("fork-alice"));
    uint256 internal constant BOB_PK = uint256(keccak256("fork-bob"));
    bool internal preDM;
    bool internal pre7702;
    bool internal preTs;

    function setUp() public {
        if (!vm.envOr("ELYSIUM_FORK", false)) {
            vm.skip(true);
            return;
        }
        // record what is live on chain before our CREATE2 deploys run
        string memory rpc = vm.envOr("ELYSIUM_RPC", string("https://rpc.elysium.kinetiq.xyz"));
        vm.createSelectFork(rpc);
        preDM = DM_ADDR.code.length > 0;
        pre7702 = EIP7702_IMPL.code.length > 0;
        preTs = TIMESTAMP_ENFORCER.code.length > 0;
        _setUpEnv(true);
    }

    function test_Fork_FrameworkIsCanonical() public view {
        assertTrue(preDM && pre7702 && preTs, "DM / 7702 / Timestamp live on Elysium");
        assertGt(HYBRID_IMPL.code.length, 0);
        assertGt(SIMPLE_FACTORY.code.length, 0);
        assertEq(DM.getDomainHash(), keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DelegationManager"),
                keccak256("1"),
                uint256(99901),
                DM_ADDR
            )
        ));
        assertEq(IDeleGatorCore(HYBRID_IMPL).getImplementation(), address(0)); // implementation, not a proxy
    }

    function test_Fork_Hybrid_EndToEnd() public {
        address owner_ = vm.addr(ALICE_PK);
        uint256 g = gasleft();
        (address a, Delegation memory d) = _onboardHybrid(ALICE_PK, 2_000e6);
        emit log_named_uint("gas deploy account + onboard (relayer)", g - gasleft());
        assertEq(vm.getNonce(owner_), 0, "client sent no transaction");

        uint256 p = poolPrice();
        g = gasleft();
        vm.prank(keeper);
        module.sendHedgeMargin(a, 600e6);
        emit log_named_uint("gas hedge send", g - gasleft());
        assertEq(usdc.balanceOf(treasury), 600e6);

        g = gasleft();
        vm.prank(keeper);
        module.swap(a, false, 650e6, p);
        emit log_named_uint("gas swap", g - gasleft());
        g = gasleft();
        uint256 id = _mintAll(a);
        emit log_named_uint("gas mint", g - gasleft());
        assertEq(POSM.ownerOf(id), a);
        uint256 v = module.accountValue(a, module.lastPrice());
        assertApproxEqRel(v, 2_000e6, 0.02e18);

        // the module cannot be used to move funds anywhere else: a raw redeem by the keeper fails at the DM
        bytes[] memory c = new bytes[](1);
        c[0] = module.permissionContext(a);
        bytes[] memory x = new bytes[](1);
        x[0] = abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(IERC20.transfer, (keeper, 1)));
        vm.prank(keeper);
        vm.expectRevert();
        DM.redeemDelegations(c, new ModeCode[](1), x);

        // fee: third-party volume, price back, one week later
        _volume(5_000, 6);
        _moveTo(module.lastPrice());
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _report();
        uint128 half = POSM.getPositionLiquidity(id) / 2;
        vm.prank(keeper);
        module.decreasePosition(a, id, half, 0, 0);
        int256 profit = int256(module.accountValue(a, module.lastPrice())) - _contributed(a);
        vm.prank(keeper);
        uint256 f = module.chargeFee(a);
        if (profit > 0) assertEq(f, uint256(profit) * 1500 / 10_000);
        else assertEq(f, 0);
        assertEq(usdc.balanceOf(feeTo), f);
        emit log_named_int("profit before fee (USDC 6d)", profit);

        // exit: one EntryPoint transaction from the owner's EOA
        g = gasleft();
        _exitHybrid(ALICE_PK, a, d, a);
        emit log_named_uint("gas exit (handleOps)", g - gasleft());
        assertFalse(module.isActive(a));
        vm.expectRevert();
        POSM.ownerOf(id);
        vm.prank(keeper);
        module.returnHedgeMargin(a, 600e6);
        assertEq(usdc.balanceOf(owner_), 600e6);
    }

    function test_Fork_7702_EndToEnd() public {
        (address a, Delegation memory d) = _onboard7702(BOB_PK, 2_000e6);
        assertEq(a, vm.addr(BOB_PK));
        _buyBase(a, 800e6);
        uint256 id = _mintAll(a);
        assertEq(POSM.ownerOf(id), a);
        uint256 g = gasleft();
        _exit7702(a, d, a);
        emit log_named_uint("gas exit (7702 self-call)", g - gasleft());
        assertTrue(DM.disabledDelegations(DM.getDelegationHash(d)));
        vm.expectRevert();
        POSM.ownerOf(id);
        uint256 p = poolPrice();
        vm.prank(keeper);
        vm.expectRevert();
        module.swap(a, false, 10e6, p);
    }

    function _contributed(address a) internal view returns (int256 c) {
        (,,, c,,,,,,,,) = module.accounts(a);
    }
}
