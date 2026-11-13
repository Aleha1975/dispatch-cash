// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LPVaultBase} from "../src/LPVaultBase.sol";
import {VaultTimelock} from "../src/VaultTimelock.sol";
import {MockLPVault} from "./mocks/Mocks.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

/// Vault owned by VaultTimelock (48 h): every owner-only change is queue -> wait -> execute; the guardian
/// (and the operator) can cancel; guardian pause stays instant; client flows never touch the timelock.
contract VaultTimelockTest is VaultTestBase {
    VaultTimelock tl;
    uint256 constant DELAY = 48 hours;
    bytes32 constant SALT = bytes32(0);

    function setUp() public override {
        super.setUp();
        tl = new VaultTimelock(DELAY, owner, guardian);
        LPVaultBase.BaseConfig memory c = config(treasury);
        c.owner = address(tl);
        vault = new MockLPVault(c, P0);
        usdc.mint(address(vault.pool()), 10_000_000e6);
        vm.deal(address(vault.pool()), 1_000_000 ether);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
        vm.prank(treasury);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---- helpers
    function _schedule(address target, bytes memory data) internal returns (bytes32 id) {
        vm.prank(owner);
        tl.schedule(target, 0, data, bytes32(0), SALT, DELAY);
        id = tl.hashOperation(target, 0, data, bytes32(0), SALT);
    }

    function _execute(address target, bytes memory data) internal {
        vm.prank(owner);
        tl.execute(target, 0, data, bytes32(0), SALT);
    }

    function _ownerCalls() internal view returns (bytes[] memory cs) {
        LPVaultBase.Params memory p = defaultParams();
        p.feeBps = 2000;
        p.poolBandBps = 500;
        cs = new bytes[](7);
        cs[0] = abi.encodeCall(LPVaultBase.setParams, (p));
        cs[1] = abi.encodeCall(LPVaultBase.setKeeper, (bob));
        cs[2] = abi.encodeCall(LPVaultBase.setGuardian, (carol)); // keeper and guardian must differ
        cs[3] = abi.encodeCall(LPVaultBase.setFeeRecipient, (bob));
        cs[4] = abi.encodeCall(LPVaultBase.setPaused, (false));
        cs[5] = abi.encodeCall(Ownable.transferOwnership, (bob));
        cs[6] = abi.encodeCall(Ownable.renounceOwnership, ());
    }

    // ---- tests
    function test_DeployWiring() public view {
        assertEq(vault.owner(), address(tl));
        assertEq(tl.getMinDelay(), DELAY);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), owner));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), owner));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), owner));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), guardian));
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), guardian));
        assertFalse(tl.hasRole(tl.EXECUTOR_ROLE(), guardian));
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), owner)); // no admin bypass
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)));
    }

    function test_ConstructorRejectsShortDelay() public {
        vm.expectRevert(VaultTimelock.DelayBelowFloor.selector);
        new VaultTimelock(24 hours - 1, owner, guardian);
        new VaultTimelock(24 hours, owner, guardian);
    }

    function test_EveryOwnerCallRevertsDirectly() public {
        bytes[] memory cs = _ownerCalls();
        address[3] memory callers = [owner, guardian, keeper];
        for (uint256 i; i < cs.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok, bytes memory ret) = address(vault).call(cs[i]);
                assertFalse(ok);
                // renounceOwnership is disabled for everybody (L-12)
                bytes4 want = i == 6 ? LPVaultBase.BadParam.selector : Ownable.OwnableUnauthorizedAccount.selector;
                assertEq(bytes4(ret), want);
            }
        }
    }

    function test_ScheduleBelowDelayReverts() public {
        bytes memory data = abi.encodeCall(LPVaultBase.setKeeper, (bob));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, DELAY - 1, DELAY));
        tl.schedule(address(vault), 0, data, bytes32(0), SALT, DELAY - 1);
    }

    function test_EveryOwnerCallNeedsDelayThenSucceeds() public {
        bytes[] memory cs = _ownerCalls();
        for (uint256 i; i < cs.length - 2; ++i) {
            // the ownership calls are covered separately
            bytes32 id = _schedule(address(vault), cs[i]);
            skip(DELAY - 1);
            vm.prank(owner);
            vm.expectRevert(); // not ready
            tl.execute(address(vault), 0, cs[i], bytes32(0), SALT);
            skip(1);
            _execute(address(vault), cs[i]);
            assertTrue(tl.isOperationDone(id));
        }
        (uint16 feeBps,, uint16 band,,,,,) = vault.params();
        assertEq(feeBps, 2000);
        assertEq(band, 500);
        assertEq(vault.keeper(), bob);
        assertEq(vault.guardian(), carol);
        assertEq(vault.feeRecipient(), bob);
    }

    function test_OnlyOperatorProposesAndExecutes() public {
        bytes memory data = abi.encodeCall(LPVaultBase.setKeeper, (bob));
        vm.prank(guardian);
        vm.expectRevert();
        tl.schedule(address(vault), 0, data, bytes32(0), SALT, DELAY);
        _schedule(address(vault), data);
        skip(DELAY);
        vm.prank(guardian);
        vm.expectRevert();
        tl.execute(address(vault), 0, data, bytes32(0), SALT);
        _execute(address(vault), data);
    }

    function test_GuardianCancels() public {
        bytes memory data = abi.encodeCall(LPVaultBase.setKeeper, (alice));
        bytes32 id = _schedule(address(vault), data);
        vm.prank(alice);
        vm.expectRevert();
        tl.cancel(id);
        vm.prank(guardian);
        tl.cancel(id);
        skip(DELAY);
        vm.prank(owner);
        vm.expectRevert();
        tl.execute(address(vault), 0, data, bytes32(0), SALT);
        assertEq(vault.keeper(), keeper);
    }

    function test_OperatorCancels() public {
        bytes memory data = abi.encodeCall(LPVaultBase.setFeeRecipient, (alice));
        bytes32 id = _schedule(address(vault), data);
        vm.prank(owner);
        tl.cancel(id);
        assertFalse(tl.isOperation(id));
    }

    function test_DelayChangeOnlyThroughTimelockWithFloor() public {
        vm.prank(owner);
        vm.expectRevert();
        tl.updateDelay(24 hours);
        // below the floor: queues fine, execution reverts
        bytes memory low = abi.encodeCall(TimelockController.updateDelay, (24 hours - 1));
        _schedule(address(tl), low);
        skip(DELAY);
        vm.prank(owner);
        vm.expectRevert(VaultTimelock.DelayBelowFloor.selector);
        tl.execute(address(tl), 0, low, bytes32(0), SALT);
        // 24 h: ok
        bytes memory ok = abi.encodeCall(TimelockController.updateDelay, (24 hours));
        _schedule(address(tl), ok);
        skip(DELAY);
        _execute(address(tl), ok);
        assertEq(tl.getMinDelay(), 24 hours);
    }

    function test_GuardianCannotVetoTimelockSelfOps() public {
        // a compromised guardian must not be able to block its own removal (role change on the timelock).
        // Rotation = (1) timelock-only batch moving CANCELLER, (2) vault.setGuardian once (1) is done.
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        targets[0] = address(tl);
        payloads[0] = abi.encodeCall(IAccessControl.revokeRole, (tl.CANCELLER_ROLE(), guardian));
        targets[1] = address(tl);
        payloads[1] = abi.encodeCall(IAccessControl.grantRole, (tl.CANCELLER_ROLE(), carol));
        vm.prank(owner);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), SALT, DELAY);
        bytes32 id = tl.hashOperationBatch(targets, values, payloads, bytes32(0), SALT);
        assertTrue(tl.isSelfOperation(id));
        vm.prank(guardian);
        vm.expectRevert(VaultTimelock.ProposerOnlyCancel.selector);
        tl.cancel(id);
        bytes memory setG = abi.encodeCall(LPVaultBase.setGuardian, (carol));
        _schedule(address(vault), setG);
        skip(DELAY);
        vm.prank(owner);
        tl.executeBatch(targets, values, payloads, bytes32(0), SALT);
        _execute(address(vault), setG);
        assertEq(vault.guardian(), carol);
        assertFalse(tl.hasRole(tl.CANCELLER_ROLE(), guardian));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), carol));
        // the delay change is a self-op too: operator may still cancel it
        bytes memory d = abi.encodeCall(TimelockController.updateDelay, (30 hours));
        bytes32 id2 = _schedule(address(tl), d);
        vm.prank(carol);
        vm.expectRevert(VaultTimelock.ProposerOnlyCancel.selector);
        tl.cancel(id2);
        vm.prank(owner);
        tl.cancel(id2);
    }

    function test_GuardianPauseInstant_UnpauseViaTimelock() public {
        vm.prank(guardian);
        vault.setPaused(true);
        assertTrue(vault.paused());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setPaused(false);
        bytes memory data = abi.encodeCall(LPVaultBase.setPaused, (false));
        _schedule(address(vault), data);
        skip(DELAY);
        _execute(address(vault), data);
        assertFalse(vault.paused());
    }

    function test_OwnershipTransferIsTwoStepThroughTimelock() public {
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (bob));
        _schedule(address(vault), data);
        skip(DELAY);
        _execute(address(vault), data);
        assertEq(vault.owner(), address(tl)); // pending until accepted
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }

    function test_RedemptionsUnaffectedByPendingOpsAndPause() public {
        deposit(alice, 100_000e6);
        deposit(bob, 50_000e6);
        settle(P0);
        // a pending (malicious-looking) change and an active pause do not touch client exits
        LPVaultBase.Params memory p = defaultParams();
        p.feeBps = 2000;
        _schedule(address(vault), abi.encodeCall(LPVaultBase.setParams, (p)));
        vm.prank(guardian);
        vault.setPaused(true);
        uint256 sh = vault.balanceOf(alice);
        redeem(alice, sh);
        uint256 before = usdc.balanceOf(alice);
        settle(P0);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 100_000e6, 1);
        // bob exits too while the change is still pending; nothing waits on the timelock
        redeem(bob, vault.balanceOf(bob));
        before = usdc.balanceOf(bob);
        settle(P0);
        assertApproxEqAbs(usdc.balanceOf(bob) - before, 50_000e6, 1);
        assertEq(vault.totalSupply(), 0);
    }
}
