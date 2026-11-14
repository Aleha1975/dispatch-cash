// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModeCode} from "../../src/sa/vendor/DelegationFramework.sol";
import {V4PositionMath} from "../../src/V4PositionMath.sol";

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IModifyLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

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
///   SA-2:
///   mode 4: PositionManager and SwapExecutor calls are SKIPPED; the native value and half the idle USDC go to
///           `sink` instead (M-1: an increase that never happens, its funds taken out);
///   mode 5: after a PositionManager removal (decrease / burn), the proceeds are added to another tracked position
///           `aux` (liquidity `auxLiq`) inside the bracket (M-2);
///   mode 6: after a SwapExecutor call, 1% of the idle USDC goes to `sink` (L-14: output kept above min-out).
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
    address internal immutable executor;
    address internal immutable permit2;
    uint256 internal immutable aux;
    uint128 internal immutable auxLiq;

    constructor(
        address claimedOwner_,
        address sink_,
        address usdc_,
        address treasury_,
        address feeTo_,
        address posm_,
        uint8 mode_,
        address claimedImpl_,
        address executor_,
        address permit2_,
        uint256 aux_,
        uint128 auxLiq_
    ) {
        executor = executor_;
        permit2 = permit2_;
        aux = aux_;
        auxLiq = auxLiq_;
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
        if (mode == 4 && (target == posm || target == executor)) {
            if (value != 0) payable(sink).transfer(value);
            IERC20(usdc).transfer(sink, IERC20(usdc).balanceOf(address(this)) / 2);
            return r;
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
        if (mode == 5 && target == posm && _isRemoval(cd)) {
            IERC20(usdc).approve(permit2, type(uint256).max);
            IPermit2Like(permit2).approve(usdc, posm, type(uint160).max, type(uint48).max);
            uint256 nat = address(this).balance;
            uint256 u = IERC20(usdc).balanceOf(address(this));
            IModifyLike(posm).modifyLiquidities{value: nat}(
                V4PositionMath.increaseData(aux, auxLiq, uint128(nat), uint128(u), address(0), usdc, address(this)),
                block.timestamp
            );
        }
        if (mode == 6 && target == executor) {
            IERC20(usdc).transfer(sink, IERC20(usdc).balanceOf(address(this)) / 100);
        }
    }

    function _isRemoval(bytes calldata cd) internal pure returns (bool) {
        (bytes memory unlockData,) = abi.decode(cd[4:], (bytes, uint256));
        (bytes memory actions,) = abi.decode(unlockData, (bytes, bytes[]));
        return actions.length != 0 && (uint8(actions[0]) == 0x01 || uint8(actions[0]) == 0x03);
    }
}
