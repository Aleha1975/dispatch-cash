// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModeCode} from "../../src/sa/vendor/DelegationFramework.sol";

interface IPosmSubscribe {
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) external payable;
    function nextTokenId() external view returns (uint256);
}

/// Accepts every PositionManager notification (a client-chosen subscriber).
contract AnySubscriber {
    fallback() external payable {}
}

/// Client-controlled account code (audit SA-1 H-2 / C-1 / M-5 / L-13): what a HybridDeleGator becomes after its owner
/// upgrades it (UUPS, owner-signed), or what a non-canonical "account" is from the start. It answers `owner()` with
/// whatever it likes and runs the DelegationManager's executions its own way.
///   mode 1: a USDC transfer to the hedge treasury / fee recipient goes to `sink` instead (the account's balance still
///           drops by the amount, which is all the round-1 module checked);
///   mode 2: every PositionManager call is executed, then half the idle USDC leaves to `sink` inside
///           the module's bracket (the M-5 shape without a subscriber);
///   mode 3: every PositionManager call is executed, then the newest position is subscribed (L-13: the tracked
///           position is not what the module asked for).
contract HostileAccount {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal immutable claimedOwner;
    address internal immutable sink;
    address internal immutable usdc;
    address internal immutable treasury;
    address internal immutable feeTo;
    address internal immutable posm;
    address internal immutable subscriber;
    uint8 internal immutable mode;
    address internal immutable claimedImpl;

    constructor(
        address claimedOwner_,
        address sink_,
        address usdc_,
        address treasury_,
        address feeTo_,
        address posm_,
        uint8 mode_,
        address claimedImpl_
    ) {
        claimedOwner = claimedOwner_;
        sink = sink_;
        usdc = usdc_;
        treasury = treasury_;
        feeTo = feeTo_;
        posm = posm_;
        mode = mode_;
        claimedImpl = claimedImpl_;
        subscriber = address(new AnySubscriber());
    }

    receive() external payable {}

    function proxiableUUID() external pure returns (bytes32) {
        return IMPL_SLOT;
    }

    function owner() external view returns (address) {
        return claimedOwner;
    }

    function getImplementation() external view returns (address) {
        return claimedImpl;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function executeFromExecutor(ModeCode, bytes calldata x) external payable returns (bytes[] memory r) {
        address target = address(bytes20(x[0:20]));
        uint256 value = uint256(bytes32(x[20:52]));
        bytes calldata cd = x[52:];
        r = new bytes[](1);
        if (mode == 1 && target == usdc && bytes4(cd[0:4]) == IERC20.transfer.selector) {
            (address to, uint256 amt) = abi.decode(cd[4:], (address, uint256));
            if (to == treasury || to == feeTo) {
                IERC20(usdc).transfer(sink, amt);
                return r;
            }
        }
        (bool ok, bytes memory ret) = target.call{value: value}(cd);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        r[0] = ret;
        if (mode == 2 && target == posm) {
            IERC20(usdc).transfer(sink, IERC20(usdc).balanceOf(address(this)) / 2);
        }
        if (mode == 3 && target == posm) {
            IPosmSubscribe(posm).subscribe(IPosmSubscribe(posm).nextTokenId() - 1, subscriber, "");
        }
    }
}
