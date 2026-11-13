// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
///         - The delay has a hard cap of 30 days (a unit mistake must not brick ownership).
///         - A canceller that is not a proposer (the guardian) cannot cancel operations that target the timelock
///           itself (role changes, delay changes). Otherwise a compromised guardian could veto its own removal forever.
///           A batch must target either only the timelock or no timelock call at all (mixed batches revert), so a
///           vault change can never borrow the "self-operation" status and escape the guardian's veto.
///           Guardian rotation = two operations: (1) a timelock-only batch `revokeRole/grantRole(CANCELLER)`,
///           (2) `vault.setGuardian(new)` (the old guardian no longer holds CANCELLER when it becomes ready).
///         - A ready operation expires `GRACE_PERIOD` (7 days) after it became executable: levers cannot be
///           stockpiled and fired later.
///
///         The guardian's `setPaused(true)` on the vault stays instant (the guardian calls the vault directly).
contract VaultTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 24 hours;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 7 days;

    uint256 private _delay;
    /// Operation ids whose calls all target the timelock itself (only proposers may cancel them).
    mapping(bytes32 => bool) public isSelfOperation;

    error DelayBelowFloor();
    error DelayAboveCap();
    error MixedBatch();
    error OperationExpired(bytes32 id);
    error ZeroAddress();
    error ProposerOnlyCancel();

    constructor(uint256 minDelay, address operator, address guardian)
        TimelockController(minDelay, _one(operator), _one(operator), address(0))
    {
        if (operator == address(0) || guardian == address(0)) revert ZeroAddress();
        _checkDelay(minDelay);
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

    function _checkDelay(uint256 d) private pure {
        if (d < MIN_DELAY_FLOOR) revert DelayBelowFloor();
        if (d > MAX_DELAY) revert DelayAboveCap();
    }

    /// @notice Only through the timelock itself; never below 24 h, never above 30 days.
    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        _checkDelay(newDelay);
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
        uint256 self;
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == address(this)) ++self;
        }
        if (self != 0) {
            if (self != targets.length) revert MixedBatch();
            isSelfOperation[hashOperationBatch(targets, values, payloads, predecessor, salt)] = true;
        }
    }

    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
    {
        _checkNotExpired(hashOperation(target, value, payload, predecessor, salt));
        super.execute(target, value, payload, predecessor, salt);
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override {
        _checkNotExpired(hashOperationBatch(targets, values, payloads, predecessor, salt));
        super.executeBatch(targets, values, payloads, predecessor, salt);
    }

    /// @dev Pending/done/unset operations fall through to the stock checks.
    function _checkNotExpired(bytes32 id) private view {
        uint256 ts = getTimestamp(id);
        if (ts > 1 && block.timestamp > ts + GRACE_PERIOD) revert OperationExpired(id);
    }

    function cancel(bytes32 id) public override {
        if (isSelfOperation[id] && !hasRole(PROPOSER_ROLE, msg.sender)) revert ProposerOnlyCancel();
        super.cancel(id);
    }
}
