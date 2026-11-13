// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title VaultTimelock
/// @notice Owner of the vault(s). Every owner-only call (parameters, keeper, guardian, fee recipient, unpause,
///         ownership transfer) is queued by the operator (`schedule`) and executable by the operator only after the
///         delay (48 h by default). Pending operations can be cancelled by the operator or by the guardian.
///
///         Differences from the stock OpenZeppelin TimelockController:
///         - The delay has a hard floor of 24 h (constructor and `updateDelay`, which itself can only be called through
///           the timelock).
///         - No admin: roles are managed only through timelocked operations on the timelock itself.
///         - A canceller that is not a proposer (the guardian) cannot cancel operations that target the timelock
///           itself (role changes, delay changes). Otherwise a compromised guardian could veto its own removal forever.
///           Guardian rotation = one `scheduleBatch` with `vault.setGuardian(new)` + `revokeRole/grantRole(CANCELLER)`.
///
///         The guardian's `setPaused(true)` on the vault stays instant (the guardian calls the vault directly).
contract VaultTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 24 hours;

    uint256 private _delay;
    /// Operation ids that include a call to the timelock itself (only proposers may cancel them).
    mapping(bytes32 => bool) public isSelfOperation;

    error DelayBelowFloor();
    error ZeroAddress();
    error ProposerOnlyCancel();

    constructor(uint256 minDelay, address operator, address guardian)
        TimelockController(minDelay, _one(operator), _one(operator), address(0))
    {
        if (operator == address(0) || guardian == address(0)) revert ZeroAddress();
        if (minDelay < MIN_DELAY_FLOOR) revert DelayBelowFloor();
        _delay = minDelay;
        _grantRole(CANCELLER_ROLE, guardian);
    }

    function _one(address a) private pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function getMinDelay() public view override returns (uint256) {
        return _delay;
    }

    /// @notice Only through the timelock itself; never below 24 h.
    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        if (newDelay < MIN_DELAY_FLOOR) revert DelayBelowFloor();
        emit MinDelayChange(_delay, newDelay);
        _delay = newDelay;
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        super.schedule(target, value, data, predecessor, salt, delay);
        if (target == address(this)) isSelfOperation[hashOperation(target, value, data, predecessor, salt)] = true;
    }

    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == address(this)) {
                isSelfOperation[hashOperationBatch(targets, values, payloads, predecessor, salt)] = true;
                break;
            }
        }
    }

    function cancel(bytes32 id) public override {
        if (isSelfOperation[id] && !hasRole(PROPOSER_ROLE, msg.sender)) revert ProposerOnlyCancel();
        super.cancel(id);
    }
}
