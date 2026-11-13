// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SATestBase.sol";

contract SmokeTest is SATestBase {
    function setUp() public {
        _setUpEnv(false);
    }

    function test_smoke() public {
        (uint256 pk) = uint256(keccak256("alice"));
        (address a, Delegation memory d) = _onboardHybrid(pk, 10_000e6);
        _buyBase(a, 4_000e6);
        uint256 id = _mintAll(a);
        emit log_named_uint("tokenId", id);
        emit log_named_uint("value", module.accountValue(a, module.lastPrice()));
        _exitHybrid(pk, a, d, a);
        assertTrue(DM.disabledDelegations(DM.getDelegationHash(d)));
    }
}
