// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity ^0.8.23;

// Vendored interface subset of MetaMask Delegation Framework v1.3.0
// (github.com/MetaMask/delegation-framework, tag v1.3.0, commit bfbdf97). Only types, interfaces and
// constants; no framework logic is copied. Deployed on Elysium (99901) at the canonical CREATE2 addresses:
//   DelegationManager            0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3
//   EIP7702StatelessDeleGator    0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B
//   TimestampEnforcer            0x1046bb45C8d673d4ea75321280DB34899413c069
// Not deployed on 99901 (deploy at the canonical address with the Arachnid CREATE2 deployer, salt "GATOR"):
//   HybridDeleGatorImpl          0x48dBe696A4D990079e039489bA2053B36E8FFEC4 (links SCL_RIP7212 0xCCD3B747F3DBd349fa3af4eBC7d0C31aE6f21dd1)
//   SimpleFactory                0x69Aa2f9fe1572F1B640E1bbc512f5c3a734fc77c
// The exact init codes are in test/fixtures/delegation-framework-v1.3.0 (built from the tag with its own
// foundry.toml: solc 0.8.23, optimizer 200 runs, evm london); the tests re-derive every address above from them.

/// ERC-7579 mode: callType(1) | execType(1) | unused(4) | selector(4) | payload(22).
type ModeCode is bytes32;

struct Caveat {
    address enforcer;
    bytes terms;
    bytes args;
}

struct Delegation {
    address delegate;
    address delegator;
    bytes32 authority;
    Caveat[] caveats;
    uint256 salt;
    bytes signature;
}

struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

interface ICaveatEnforcer {
    function beforeAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external;
    function beforeHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external;
    function afterHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external;
    function afterAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external;
}

interface IDelegationManager {
    function redeemDelegations(bytes[] calldata permissionContexts, ModeCode[] calldata modes, bytes[] calldata executionCallDatas)
        external;
    function disableDelegation(Delegation calldata delegation) external;
    function disabledDelegations(bytes32 delegationHash) external view returns (bool);
    function getDelegationHash(Delegation calldata delegation) external pure returns (bytes32);
    function getDomainHash() external view returns (bytes32);
    function paused() external view returns (bool);
}

interface IDeleGatorCore {
    function executeFromExecutor(ModeCode mode, bytes calldata executionCalldata) external payable returns (bytes[] memory);
    function execute(ModeCode mode, bytes calldata executionCalldata) external payable;
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
    function getImplementation() external view returns (address);
}

interface IHybridDeleGator {
    function owner() external view returns (address);
    function initialize(address owner, string[] calldata keyIds, uint256[] calldata xValues, uint256[] calldata yValues)
        external;
}

interface ISimpleFactory {
    function deploy(bytes memory bytecode, bytes32 salt) external returns (address);
    function computeAddress(bytes32 bytecodeHash, bytes32 salt) external view returns (address);
}

library DelegationFramework {
    bytes32 internal constant ROOT_AUTHORITY = bytes32(type(uint256).max);
    bytes32 internal constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address delegate,address delegator,bytes32 authority,Caveat[] caveats,uint256 salt)Caveat(address enforcer,bytes terms)"
    );
    bytes32 internal constant CAVEAT_TYPEHASH = keccak256("Caveat(address enforcer,bytes terms)");
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;
    /// callType SINGLE (0x00), execType DEFAULT (0x00), no selector, no payload.
    ModeCode internal constant SINGLE_DEFAULT = ModeCode.wrap(bytes32(0));
    /// callType BATCH (0x01), execType DEFAULT.
    ModeCode internal constant BATCH_DEFAULT = ModeCode.wrap(bytes32(uint256(1) << 248));

    /// Same as the framework's EncoderLib._getDelegationHash (EIP-712 struct hash; `args` and `signature` excluded).
    function hash(Delegation memory d) internal pure returns (bytes32) {
        bytes32[] memory ch = new bytes32[](d.caveats.length);
        for (uint256 i; i < ch.length; ++i) {
            ch[i] = keccak256(abi.encode(CAVEAT_TYPEHASH, d.caveats[i].enforcer, keccak256(d.caveats[i].terms)));
        }
        return keccak256(
            abi.encode(DELEGATION_TYPEHASH, d.delegate, d.delegator, d.authority, keccak256(abi.encodePacked(ch)), d.salt)
        );
    }

    /// ERC-7579 single execution calldata: target(20) | value(32) | callData.
    function single(address target, uint256 value, bytes memory callData) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, callData);
    }
}
