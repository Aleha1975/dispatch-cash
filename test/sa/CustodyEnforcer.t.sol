// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";

/// Redeems a client's delegation with arbitrary executions: stands in for a fully compromised delegate (a module
/// bug or a stolen keeper with raw redemption rights). Only the custody caveat stands between it and the account.
contract RogueDelegate {
    IDelegationManager immutable dm;

    constructor(IDelegationManager dm_) {
        dm = dm_;
    }

    function run(bytes memory ctx, ModeCode mode, bytes memory exec) external {
        bytes[] memory c = new bytes[](1);
        c[0] = ctx;
        ModeCode[] memory m = new ModeCode[](1);
        m[0] = mode;
        bytes[] memory x = new bytes[](1);
        x[0] = exec;
        dm.redeemDelegations(c, m, x);
    }

    receive() external payable {}
}

interface IPosmExtra {
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
    function approve(address spender, uint256 id) external;
    function setApprovalForAll(address op, bool ok) external;
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) external payable;
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;
}

interface IPermit2Extra {
    function transferFrom(address from, address to, uint160 amount, address token) external;
    function lockdown(bytes calldata approvals) external;
    function invalidateNonces(address token, address spender, uint48 newNonce) external;
}

/// ElysiumCustodyEnforcer: every allowed shape passes, every other target / selector / recipient / action / value
/// is refused. Part 1 calls the hook directly (as the DelegationManager); part 2 redeems through the real
/// DelegationManager against a real HybridDeleGator with a rogue delegate.
contract CustodyEnforcerTest is SATestBase {
    address internal del = makeAddr("delegator");
    address internal mod = makeAddr("moduleStandIn");
    address internal attacker = makeAddr("attacker");
    bytes internal T; // terms
    uint256 internal ownId; // position of `del` in the pool
    uint256 internal otherId; // lp's position
    uint256 internal foreignPoolId; // `del`'s position in another pool
    PoolKey internal otherKey;

    function setUp() public {
        _setUpEnv(false);
        T = abi.encode(mod, treasury, feeTo);
        _deal(del, 100_000e6);
        vm.deal(del, 1_000 ether);
        // del owns a position in the pool (direct PositionManager use, no delegation involved)
        vm.startPrank(del);
        usdc.approve(PERMIT2, type(uint256).max);
        IPermit2Approve(PERMIT2).approve(address(usdc), POSM_ADDR, type(uint160).max, type(uint48).max);
        (int24 tl, int24 tu) = _range(500);
        ownId = POSM.nextTokenId();
        POSM.modifyLiquidities{value: 10 ether}(
            V4PositionMath.mintData(key, tl, tu, 1e13, 10 ether, 1_000e6, del), block.timestamp
        );
        // and one in a different pool (fee 500)
        otherKey = PoolKey(key.currency0, key.currency1, 500, 10, IHooks(address(0)));
        PM.initialize(otherKey, SALib.sqrtPriceAt(40e6, true));
        foreignPoolId = POSM.nextTokenId();
        POSM.modifyLiquidities{value: 10 ether}(
            V4PositionMath.mintData(otherKey, -887270, 887270, 1e13, 10 ether, 1_000e6, del), block.timestamp
        );
        vm.stopPrank();
        _deal(del, 100_000e6 - usdc.balanceOf(del)); // exactly 100k idle
        otherId = 1; // seeded by lp
        assertEq(IPositionManagerMin(POSM_ADDR).ownerOf(otherId), lp);
    }

    // ------------------------------------------------------------------ helpers
    function _x(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, data);
    }

    function _hookAs(address caller, bytes memory terms, ModeCode mode, bytes memory exec, address redeemer) internal {
        vm.prank(caller);
        enforcer.beforeHook(terms, "", mode, exec, bytes32(0), del, redeemer);
    }

    function _hook(bytes memory exec) internal {
        _hookAs(DM_ADDR, T, DelegationFramework.SINGLE_DEFAULT, exec, mod);
    }

    function _expectHookRevert(bytes memory exec, bytes4 err) internal {
        vm.expectPartialRevert(err);
        _hook(exec);
    }

    function _modify(bytes memory unlockData) internal view returns (bytes memory) {
        return abi.encodeCall(IPositionManagerMin.modifyLiquidities, (unlockData, block.timestamp));
    }

    function _unlock(bytes memory actions, bytes[] memory ps) internal pure returns (bytes memory) {
        return abi.encode(actions, ps);
    }

    function _one(uint8 a, bytes memory p) internal pure returns (bytes memory) {
        bytes[] memory ps = new bytes[](1);
        ps[0] = p;
        return abi.encode(abi.encodePacked(a), ps);
    }

    function _posm(bytes memory unlockData, uint256 value) internal view returns (bytes memory) {
        return _x(POSM_ADDR, value, _modify(unlockData));
    }

    function _mintParams(PoolKey memory k, address owner_, bytes memory hook) internal pure returns (bytes memory) {
        return abi.encode(k, int24(-600), int24(600), uint256(1e12), uint128(1 ether), uint128(100e6), owner_, hook);
    }

    // ------------------------------------------------------------------ allowed shapes
    function test_Allowed_MintIncreaseDecreaseBurnCollect() public {
        (int24 tl, int24 tu) = _range(300);
        _hook(_posm(V4PositionMath.mintData(key, tl, tu, 1e12, 1 ether, 100e6, del), 1 ether));
        _hook(_posm(V4PositionMath.increaseData(ownId, 1e12, 1 ether, 100e6, address(0), address(usdc), del), 1 ether));
        _hook(_posm(V4PositionMath.removeData(false, ownId, 1e12, 0, 0, address(0), address(usdc), del), 0));
        _hook(_posm(V4PositionMath.removeData(false, ownId, 0, 0, 0, address(0), address(usdc), del), 0));
        _hook(_posm(V4PositionMath.removeData(true, ownId, 0, 0, 0, address(0), address(usdc), del), 0));
    }

    function test_Allowed_SwapApprovalsAndTransfers() public {
        _hook(_x(address(executor), 1 ether, abi.encodeCall(SwapExecutor.swap, (true, 1 ether, 1, 0))));
        _hook(_x(address(executor), 0, abi.encodeCall(SwapExecutor.swap, (false, 100e6, 1, 0))));
        _hook(_x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, 100e6, uint48(block.timestamp)))));
        _hook(_x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), address(executor), 100e6, 0))));
        _hook(_x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, 0, type(uint48).max))));
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.approve, (PERMIT2, 100_000e6))));
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 35_000e6))));
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (feeTo, 20_000e6))));
    }

    // ------------------------------------------------------------------ caller, mode, terms, redeemer
    function test_Deny_NotDelegationManager() public {
        bytes memory x = _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 1e6)));
        vm.expectRevert(ElysiumCustodyEnforcer.NotDelegationManager.selector);
        _hookAs(attacker, T, DelegationFramework.SINGLE_DEFAULT, x, mod);
        vm.expectRevert(ElysiumCustodyEnforcer.NotDelegationManager.selector);
        _hookAs(mod, T, DelegationFramework.SINGLE_DEFAULT, x, mod);
    }

    function test_Deny_Modes() public {
        bytes memory x = _x(address(usdc), 0, abi.encodeCall(IERC20.approve, (PERMIT2, 1)));
        ModeCode[4] memory bad = [
            DelegationFramework.BATCH_DEFAULT,
            ModeCode.wrap(bytes32(uint256(1) << 240)), // single, try
            ModeCode.wrap(bytes32(uint256(0xff) << 248)), // delegatecall
            ModeCode.wrap(bytes32(uint256(1))) // payload
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ElysiumCustodyEnforcer.BadMode.selector);
            _hookAs(DM_ADDR, T, bad[i], x, mod);
        }
    }

    function test_Deny_TermsAndRedeemer() public {
        bytes memory x = _x(address(usdc), 0, abi.encodeCall(IERC20.approve, (PERMIT2, 1)));
        bytes[6] memory bad = [
            bytes(""),
            abi.encode(mod, treasury),
            abi.encode(mod, treasury, feeTo, attacker),
            abi.encode(address(0), treasury, feeTo),
            abi.encode(mod, treasury, treasury),
            abi.encode(mod, address(0), feeTo)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ElysiumCustodyEnforcer.BadTerms.selector);
            _hookAs(DM_ADDR, bad[i], DelegationFramework.SINGLE_DEFAULT, x, mod);
        }
        vm.expectRevert(ElysiumCustodyEnforcer.BadRedeemer.selector);
        _hookAs(DM_ADDR, T, DelegationFramework.SINGLE_DEFAULT, x, attacker);
    }

    // ------------------------------------------------------------------ targets and native value
    function test_Deny_NativeTransfersAndShortCalldata() public {
        _expectHookRevert(_x(attacker, 1 ether, ""), ElysiumCustodyEnforcer.BadExecution.selector);
        _expectHookRevert(_x(treasury, 1, ""), ElysiumCustodyEnforcer.BadExecution.selector);
        _expectHookRevert(_x(attacker, 1, hex"aabbcc"), ElysiumCustodyEnforcer.BadExecution.selector);
        _expectHookRevert(abi.encodePacked(attacker, uint256(1)), ElysiumCustodyEnforcer.BadExecution.selector);
        _expectHookRevert(hex"00", ElysiumCustodyEnforcer.BadExecution.selector);
        // a call with data to any non-allowlisted target, with or without value
        _expectHookRevert(_x(attacker, 1 ether, hex"12345678"), ElysiumCustodyEnforcer.TargetNotAllowed.selector);
    }

    function test_Deny_OtherTargets() public {
        address[9] memory ts = [
            attacker, DM_ADDR, del, mod, PM_ADDR, ENTRYPOINT, address(module), address(enforcer), address(0)
        ];
        bytes memory data = abi.encodeCall(IERC20.transfer, (attacker, 1));
        for (uint256 i; i < ts.length; ++i) {
            _expectHookRevert(_x(ts[i], 0, data), ElysiumCustodyEnforcer.TargetNotAllowed.selector);
        }
        // the account calling itself (execute / upgrade / disable) is not a target either
        _expectHookRevert(
            _x(del, 0, abi.encodeCall(IDeleGatorCore.execute, (DelegationFramework.SINGLE_DEFAULT, ""))),
            ElysiumCustodyEnforcer.TargetNotAllowed.selector
        );
    }

    // ------------------------------------------------------------------ PositionManager
    function test_Deny_PositionManagerOtherSelectors() public {
        bytes[9] memory calls = [
            abi.encodeCall(IPosmExtra.transferFrom, (del, attacker, ownId)),
            abi.encodeCall(IPosmExtra.safeTransferFrom, (del, attacker, ownId)),
            abi.encodeCall(IPosmExtra.approve, (attacker, ownId)),
            abi.encodeCall(IPosmExtra.setApprovalForAll, (attacker, true)),
            abi.encodeCall(IPosmExtra.modifyLiquiditiesWithoutUnlock, (hex"11", new bytes[](1))),
            abi.encodeCall(IPosmExtra.multicall, (new bytes[](0))),
            abi.encodeCall(IPosmExtra.subscribe, (ownId, attacker, "")),
            abi.encodeCall(IPosmExtra.initializePool, (key, 1 << 96)),
            abi.encodeCall(IPosmExtra.permit, (attacker, ownId, block.timestamp, 0, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            _expectHookRevert(_x(POSM_ADDR, 0, calls[i]), ElysiumCustodyEnforcer.SelectorNotAllowed.selector);
        }
    }

    function test_Deny_MintRecipientsPoolHook() public {
        address[3] memory owners = [attacker, address(1), address(2)]; // incl. MSG_SENDER / ADDRESS_THIS sentinels
        for (uint256 i; i < owners.length; ++i) {
            _expectHookRevert(
                _posm(_one(0x02, _mintParams(key, owners[i], "")), 0), ElysiumCustodyEnforcer.BadRecipient.selector
            );
        }
        _expectHookRevert(_posm(_one(0x02, _mintParams(otherKey, del, "")), 0), ElysiumCustodyEnforcer.BadPool.selector);
        PoolKey memory hooked = key;
        hooked.hooks = IHooks(attacker);
        _expectHookRevert(_posm(_one(0x02, _mintParams(hooked, del, "")), 0), ElysiumCustodyEnforcer.BadPool.selector);
        _expectHookRevert(_posm(_one(0x02, _mintParams(key, del, hex"01")), 0), ElysiumCustodyEnforcer.HookDataNotEmpty.selector);
    }

    function test_Deny_TakeSweepSettleCloseRecipientsAndCurrencies() public {
        address c0 = address(0);
        address c1 = address(usdc);
        _expectHookRevert(_posm(_one(0x11, abi.encode(c0, c1, attacker)), 0), ElysiumCustodyEnforcer.BadRecipient.selector);
        _expectHookRevert(_posm(_one(0x11, abi.encode(c0, c1, address(1))), 0), ElysiumCustodyEnforcer.BadRecipient.selector);
        _expectHookRevert(_posm(_one(0x11, abi.encode(c1, c0, del)), 0), ElysiumCustodyEnforcer.BadPool.selector);
        _expectHookRevert(_posm(_one(0x14, abi.encode(c0, attacker)), 0), ElysiumCustodyEnforcer.BadRecipient.selector);
        _expectHookRevert(_posm(_one(0x14, abi.encode(c1, address(1))), 0), ElysiumCustodyEnforcer.BadRecipient.selector);
        _expectHookRevert(_posm(_one(0x14, abi.encode(attacker, del)), 0), ElysiumCustodyEnforcer.BadPool.selector);
        _expectHookRevert(_posm(_one(0x0d, abi.encode(c0, attacker)), 0), ElysiumCustodyEnforcer.BadPool.selector);
        _expectHookRevert(_posm(_one(0x0d, abi.encode(c1, c0)), 0), ElysiumCustodyEnforcer.BadPool.selector);
        _expectHookRevert(_posm(_one(0x12, abi.encode(attacker)), 0), ElysiumCustodyEnforcer.BadPool.selector);
    }

    function test_Deny_TokensNotOwnedOrForeignPool() public {
        bytes memory inc = abi.encode(otherId, uint256(1), uint128(1), uint128(1), bytes(""));
        _expectHookRevert(_posm(_one(0x00, inc), 0), ElysiumCustodyEnforcer.NotOwnedByDelegator.selector);
        _expectHookRevert(_posm(_one(0x01, inc), 0), ElysiumCustodyEnforcer.NotOwnedByDelegator.selector);
        _expectHookRevert(
            _posm(_one(0x03, abi.encode(otherId, uint128(0), uint128(0), bytes(""))), 0),
            ElysiumCustodyEnforcer.NotOwnedByDelegator.selector
        );
        bytes memory foreign = abi.encode(foreignPoolId, uint256(1), uint128(1), uint128(1), bytes(""));
        _expectHookRevert(_posm(_one(0x00, foreign), 0), ElysiumCustodyEnforcer.BadPool.selector);
        _expectHookRevert(_posm(_one(0x01, foreign), 0), ElysiumCustodyEnforcer.BadPool.selector);
        // a token that does not exist (yet): ownerOf reverts, so does the hook
        vm.expectRevert();
        _hook(_posm(_one(0x00, abi.encode(uint256(10 ** 9), uint256(1), uint128(1), uint128(1), bytes(""))), 0));
        // hookData on increase / decrease / burn
        _expectHookRevert(
            _posm(_one(0x01, abi.encode(ownId, uint256(1), uint128(0), uint128(0), hex"00")), 0),
            ElysiumCustodyEnforcer.HookDataNotEmpty.selector
        );
        _expectHookRevert(
            _posm(_one(0x03, abi.encode(ownId, uint128(0), uint128(0), hex"00")), 0),
            ElysiumCustodyEnforcer.HookDataNotEmpty.selector
        );
    }

    function test_Deny_EveryOtherAction() public {
        for (uint256 a; a < 256; ++a) {
            if (a == 0 || a == 1 || a == 2 || a == 3 || a == 0x0d || a == 0x11 || a == 0x12 || a == 0x14) continue;
            vm.expectRevert(abi.encodeWithSelector(ElysiumCustodyEnforcer.ActionNotAllowed.selector, uint8(a)));
            _hook(_posm(_one(uint8(a), abi.encode(address(0), attacker, uint256(1))), 0));
        }
    }

    function test_Deny_ActionCountAndLengths() public {
        _expectHookRevert(_posm(abi.encode(bytes(""), new bytes[](0)), 0), ElysiumCustodyEnforcer.BadExecution.selector);
        bytes[] memory two = new bytes[](2);
        two[0] = abi.encode(address(0));
        two[1] = abi.encode(address(usdc));
        _expectHookRevert(_posm(abi.encode(hex"12", two), 0), ElysiumCustodyEnforcer.BadExecution.selector);
        bytes[] memory many = new bytes[](17);
        bytes memory acts = new bytes(17);
        for (uint256 i; i < 17; ++i) {
            acts[i] = 0x12;
            many[i] = abi.encode(address(0));
        }
        _expectHookRevert(_posm(abi.encode(acts, many), 0), ElysiumCustodyEnforcer.BadExecution.selector);
    }

    function test_Deny_NonCanonicalEncodings() public {
        bytes memory good = V4PositionMath.removeData(true, ownId, 0, 0, 0, address(0), address(usdc), del);
        _hook(_posm(good, 0));
        // trailing bytes after the modifyLiquidities arguments
        _expectHookRevert(_x(POSM_ADDR, 0, abi.encodePacked(_modify(good), uint256(0))), ElysiumCustodyEnforcer.NonCanonical.selector);
        // trailing bytes inside unlockData
        _expectHookRevert(_posm(abi.encodePacked(good, uint256(0)), 0), ElysiumCustodyEnforcer.NonCanonical.selector);
        // trailing bytes inside one action's params (a decoder reading past the canonical end could see another recipient)
        bytes[] memory ps = new bytes[](2);
        ps[0] = abi.encode(ownId, uint128(0), uint128(0), bytes(""));
        ps[1] = abi.encodePacked(abi.encode(address(0), address(usdc), del), abi.encode(attacker));
        _expectHookRevert(_posm(abi.encode(hex"0311", ps), 0), ElysiumCustodyEnforcer.NonCanonical.selector);
        // unlockData whose `actions` offset is not the canonical 0x40 (bytes hidden in between)
        bytes memory odd = abi.encodePacked(uint256(0x60), uint256(0xa0), uint256(0), uint256(2), bytes32(hex"0311"));
        vm.expectRevert(); // decodes into garbage (or reverts) and can never re-encode to itself
        _hook(_posm(odd, 0));
        // dirty high bits in an address word (decoder v2 rejects, canonical check would too)
        bytes memory dirty = abi.encodePacked(
            IPermit2Approve.approve.selector,
            bytes32(uint256(uint160(address(usdc))) | (uint256(1) << 200)),
            abi.encode(POSM_ADDR, uint160(1), uint48(0))
        );
        vm.expectRevert();
        _hook(_x(PERMIT2, 0, dirty));
    }

    function test_Deny_NativeValueWithoutFinalSweep() public {
        bytes memory burn = V4PositionMath.removeData(true, ownId, 0, 0, 0, address(0), address(usdc), del);
        _expectHookRevert(_posm(burn, 1), ElysiumCustodyEnforcer.BadValue.selector);
        // sweep present but not last
        bytes[] memory ps = new bytes[](2);
        ps[0] = abi.encode(address(0), del);
        ps[1] = abi.encode(address(usdc));
        _expectHookRevert(_posm(abi.encode(hex"1412", ps), 1 ether), ElysiumCustodyEnforcer.BadValue.selector);
        // final sweep of the ERC-20 instead of native
        ps[0] = abi.encode(address(0));
        ps[1] = abi.encode(address(usdc), del);
        _expectHookRevert(_posm(abi.encode(hex"1214", ps), 1 ether), ElysiumCustodyEnforcer.BadValue.selector);
    }

    // ------------------------------------------------------------------ SwapExecutor
    function test_Deny_SwapShapes() public {
        address x = address(executor);
        _expectHookRevert(_x(x, 0, abi.encodeCall(SwapExecutor.swap, (false, 100e6, 0, 0))), ElysiumCustodyEnforcer.BadAmount.selector);
        _expectHookRevert(_x(x, 0, abi.encodeCall(SwapExecutor.swap, (false, 0, 1, 0))), ElysiumCustodyEnforcer.BadAmount.selector);
        _expectHookRevert(_x(x, 1, abi.encodeCall(SwapExecutor.swap, (true, 2, 1, 0))), ElysiumCustodyEnforcer.BadValue.selector);
        _expectHookRevert(_x(x, 3, abi.encodeCall(SwapExecutor.swap, (true, 2, 1, 0))), ElysiumCustodyEnforcer.BadValue.selector);
        _expectHookRevert(_x(x, 1, abi.encodeCall(SwapExecutor.swap, (false, 100e6, 1, 0))), ElysiumCustodyEnforcer.BadValue.selector);
        _expectHookRevert(
            _x(x, 0, abi.encodePacked(abi.encodeCall(SwapExecutor.swap, (false, 100e6, 1, 0)), uint256(uint160(attacker)))),
            ElysiumCustodyEnforcer.NonCanonical.selector
        );
        _expectHookRevert(_x(x, 0, abi.encodeCall(SwapExecutor.unlockCallback, (""))), ElysiumCustodyEnforcer.SelectorNotAllowed.selector);
    }

    // ------------------------------------------------------------------ Permit2 and ERC-20
    function test_Deny_Permit2() public {
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Extra.transferFrom, (del, attacker, 1, address(usdc)))),
            ElysiumCustodyEnforcer.SelectorNotAllowed.selector
        );
        _expectHookRevert(_x(PERMIT2, 0, abi.encodeCall(IPermit2Extra.lockdown, (""))), ElysiumCustodyEnforcer.SelectorNotAllowed.selector);
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Extra.invalidateNonces, (address(usdc), POSM_ADDR, 1))),
            ElysiumCustodyEnforcer.SelectorNotAllowed.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), attacker, 1, 0))),
            ElysiumCustodyEnforcer.BadSpender.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), address(module), 1, 0))),
            ElysiumCustodyEnforcer.BadSpender.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(0), POSM_ADDR, 1, 0))),
            ElysiumCustodyEnforcer.BadToken.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (attacker, POSM_ADDR, 1, 0))),
            ElysiumCustodyEnforcer.BadToken.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, 1, uint48(block.timestamp + 1)))),
            ElysiumCustodyEnforcer.BadExpiration.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 0, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, 100_000e6 + 1, 0))),
            ElysiumCustodyEnforcer.BadAmount.selector
        );
        _expectHookRevert(
            _x(PERMIT2, 1, abi.encodeCall(IPermit2Approve.approve, (address(usdc), POSM_ADDR, 1, 0))),
            ElysiumCustodyEnforcer.BadValue.selector
        );
    }

    function test_Deny_Erc20() public {
        address u = address(usdc);
        _expectHookRevert(_x(u, 0, abi.encodeCall(IERC20.approve, (attacker, 1))), ElysiumCustodyEnforcer.BadSpender.selector);
        _expectHookRevert(_x(u, 0, abi.encodeCall(IERC20.approve, (POSM_ADDR, 1))), ElysiumCustodyEnforcer.BadSpender.selector);
        _expectHookRevert(_x(u, 0, abi.encodeCall(IERC20.approve, (PERMIT2, 100_000e6 + 1))), ElysiumCustodyEnforcer.BadAmount.selector);
        _expectHookRevert(_x(u, 0, abi.encodeCall(IERC20.transfer, (attacker, 1))), ElysiumCustodyEnforcer.BadRecipient.selector);
        _expectHookRevert(_x(u, 0, abi.encodeCall(IERC20.transfer, (mod, 1))), ElysiumCustodyEnforcer.BadRecipient.selector);
        _expectHookRevert(_x(u, 0, abi.encodeCall(IERC20.transfer, (treasury, 0))), ElysiumCustodyEnforcer.BadAmount.selector);
        _expectHookRevert(
            _x(u, 0, abi.encodeCall(IERC20.transferFrom, (del, attacker, 1))), ElysiumCustodyEnforcer.SelectorNotAllowed.selector
        );
        _expectHookRevert(
            _x(u, 0, abi.encodeCall(IERC20Permit.permit, (del, attacker, 1, 1, 27, 0, 0))),
            ElysiumCustodyEnforcer.SelectorNotAllowed.selector
        );
        _expectHookRevert(_x(u, 1, abi.encodeCall(IERC20.transfer, (treasury, 1))), ElysiumCustodyEnforcer.BadValue.selector);
        _expectHookRevert(
            _x(u, 0, abi.encodePacked(abi.encodeCall(IERC20.transfer, (treasury, 1)), uint256(0))),
            ElysiumCustodyEnforcer.NonCanonical.selector
        );
    }

    // ------------------------------------------------------------------ hedge and fee budgets
    function test_HedgeBudget_35PercentPerDecayingDay() public {
        bytes memory x20 = _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 20_000e6)));
        _hook(x20); // 20% of 100k
        vm.prank(del);
        usdc.transfer(treasury, 20_000e6); // the execution itself (the hook only checks)
        // 15k of the remaining 80k = 18.75% -> 38.75% > 35%
        _expectHookRevert(
            _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 15_000e6))),
            ElysiumCustodyEnforcer.HedgeBudget.selector
        );
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 12_000e6)))); // 15% -> 35%
        vm.warp(block.timestamp + 12 hours); // half restored
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 13_000e6))));
        vm.warp(block.timestamp + 1 days);
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 28_000e6))));
    }

    function test_FeeBudget_20PercentOncePerWeek() public {
        _expectHookRevert(
            _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (feeTo, 20_000e6 + 1))), ElysiumCustodyEnforcer.FeeTooLarge.selector
        );
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (feeTo, 1_000e6))));
        _expectHookRevert(
            _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (feeTo, 1e6))), ElysiumCustodyEnforcer.FeeTooSoon.selector
        );
        vm.warp(block.timestamp + 7 days - 1);
        _expectHookRevert(
            _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (feeTo, 1e6))), ElysiumCustodyEnforcer.FeeTooSoon.selector
        );
        vm.warp(block.timestamp + 1);
        _hook(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (feeTo, 1e6))));
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_UnknownActionsRejected(uint8 a, bytes memory p) public {
        vm.assume(!(a <= 3 || a == 0x0d || a == 0x11 || a == 0x12 || a == 0x14));
        vm.expectRevert(abi.encodeWithSelector(ElysiumCustodyEnforcer.ActionNotAllowed.selector, a));
        _hook(_posm(_one(a, p), 0));
    }

    function testFuzz_TakePairOnlyToDelegator(address to) public {
        vm.assume(to != del);
        _expectHookRevert(_posm(_one(0x11, abi.encode(address(0), address(usdc), to)), 0), ElysiumCustodyEnforcer.BadRecipient.selector);
    }

    function testFuzz_TransferOnlyToTreasuryOrFee(address to, uint256 amt) public {
        vm.assume(to != treasury && to != feeTo);
        amt = bound(amt, 1, 100_000e6);
        _expectHookRevert(_x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (to, amt))), ElysiumCustodyEnforcer.BadRecipient.selector);
    }

    function testFuzz_AppendedBytesRejected(bytes memory tail) public {
        vm.assume(tail.length != 0);
        bytes memory good = V4PositionMath.removeData(true, ownId, 0, 0, 0, address(0), address(usdc), del);
        vm.expectRevert();
        _hook(_x(POSM_ADDR, 0, abi.encodePacked(_modify(good), tail)));
    }

    // ------------------------------------------------------------------ through the real DelegationManager
    function _rogueSetup() internal returns (RogueDelegate rogue, address a, uint256 pk, bytes memory ctx) {
        rogue = new RogueDelegate(DM);
        pk = uint256(keccak256("victim"));
        a = _deployHybrid(vm.addr(pk));
        _deal(a, 50_000e6);
        vm.deal(a, 10 ether);
        Delegation memory d = _delegation(a, address(rogue), abi.encode(address(rogue), treasury, feeTo), block.timestamp + 30 days, 7);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, pk);
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        ctx = abi.encode(ds);
    }

    function test_Rogue_ThroughDelegationManager() public {
        (RogueDelegate rogue, address a,, bytes memory ctx) = _rogueSetup();
        ModeCode m = DelegationFramework.SINGLE_DEFAULT;
        vm.expectPartialRevert(ElysiumCustodyEnforcer.BadRecipient.selector);
        rogue.run(ctx, m, _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (address(rogue), 1))));
        vm.expectPartialRevert(ElysiumCustodyEnforcer.BadExecution.selector);
        rogue.run(ctx, m, _x(address(rogue), 1 ether, ""));
        vm.expectPartialRevert(ElysiumCustodyEnforcer.BadSpender.selector);
        rogue.run(ctx, m, _x(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(rogue), 1))));
        vm.expectPartialRevert(ElysiumCustodyEnforcer.TargetNotAllowed.selector);
        rogue.run(ctx, m, _x(a, 0, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(rogue), "")));
        vm.expectPartialRevert(ElysiumCustodyEnforcer.BadMode.selector);
        Execution[] memory xs = new Execution[](1);
        xs[0] = Execution(address(usdc), 0, abi.encodeCall(IERC20.transfer, (address(rogue), 1)));
        rogue.run(ctx, DelegationFramework.BATCH_DEFAULT, abi.encode(xs));
        // what it may do still leaves everything with the account: e.g. approve Permit2 for its own balance
        rogue.run(ctx, m, _x(address(usdc), 0, abi.encodeCall(IERC20.approve, (PERMIT2, 50_000e6))));
        assertEq(usdc.balanceOf(a), 50_000e6);
        assertEq(a.balance, 10 ether);
        // hedge transfer within the slice is the one value exit (to the client-signed treasury)
        rogue.run(ctx, m, _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 17_500e6))));
        vm.expectPartialRevert(ElysiumCustodyEnforcer.HedgeBudget.selector);
        rogue.run(ctx, m, _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 1e6))));
    }

    function test_Rogue_RedeemerMustBeTheSignedModule() public {
        RogueDelegate rogue = new RogueDelegate(DM);
        uint256 pk = uint256(keccak256("victim2"));
        address a = _deployHybrid(vm.addr(pk));
        _deal(a, 1_000e6);
        // signed with terms naming the real module, but delegated to the rogue: the caveat refuses the redeemer
        Delegation memory d = _delegation(a, address(rogue), _terms(address(module)), block.timestamp + 30 days, 8);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, pk);
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        vm.expectPartialRevert(ElysiumCustodyEnforcer.BadRedeemer.selector);
        rogue.run(abi.encode(ds), DelegationFramework.SINGLE_DEFAULT, _x(address(usdc), 0, abi.encodeCall(IERC20.transfer, (treasury, 1))));
    }
}
