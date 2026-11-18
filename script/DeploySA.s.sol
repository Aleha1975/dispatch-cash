// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHybridDeleGator, ISimpleFactory} from "../src/sa/vendor/DelegationFramework.sol";
import {SALib} from "../src/sa/SALib.sol";
import {VaultTimelock} from "../src/VaultTimelock.sol";
import {IPositionManagerMin} from "../src/interfaces/IExternal.sol";
import {IDelegationManager} from "../src/sa/vendor/DelegationFramework.sol";
import {SwapExecutor} from "../src/sa/SwapExecutor.sol";
import {ElysiumCustodyEnforcer} from "../src/sa/ElysiumCustodyEnforcer.sol";
import {LPManagerModule} from "../src/sa/LPManagerModule.sol";

/// Smart-account deployment on Elysium. NOT EXECUTED on a live chain (fork / anvil only so far).
///
/// 1. Delegation Framework v1.3.0 pieces missing on Elysium (HybridDeleGatorImpl + its SCL library, SimpleFactory)
///    are created from test/fixtures/delegation-framework-v1.3.0 through the deterministic CREATE2 deployer, so they
///    land on the canonical addresses used on every other chain. Already-present contracts are skipped.
/// 2. SwapExecutor, ElysiumCustodyEnforcer and LPManagerModule (owner = VaultTimelock; OWNER proposes/executes, OWNER
///    and GUARDIAN cancel). Forge links SALib / SABook / V4PositionMath automatically.
/// Env: OWNER, KEEPER, GUARDIAN, HEDGE_TREASURY, FEE_RECIPIENT, optional TIMELOCK_DELAY (default 48 h, >= 24 h),
/// optional ALLOW_EOA_OWNER (default false: the timelock operator must be a Safe-style multisig with threshold >= 2,
/// not an EOA and not an EIP-7702-delegated EOA; SA-3 L-13, SA-4 L-13).
/// Params: the PILOT values are the script's (SA-4 L-12: swapTurnoverBps 5000, exitTurnoverBps 10000) and are read
/// back from the deployed module; onboard nobody before `params()` equals them.
/// After deploying: the keeper calls reportPrice once (anchor; SA-5 M-2: also the first guardian-confirmed level, so
/// report the checked market price), the treasury approves the module for USDC.
interface IPausable {
    function paused() external view returns (bool);
}

interface ISafeThreshold {
    function getThreshold() external view returns (uint256);
}

interface IPosmWiring {
    function poolManager() external view returns (address);
}

contract DeploySA is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant CHAIN_ID = 99901;
    address constant USDC = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
    address constant PM = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
    address constant POSM = 0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant DM = 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3;
    address constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant EIP7702_IMPL = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B;
    address constant TIMESTAMP_ENFORCER = 0x1046bb45C8d673d4ea75321280DB34899413c069;
    address constant SCL_LIB = 0xCCD3B747F3DBd349fa3af4eBC7d0C31aE6f21dd1;
    address constant HYBRID_IMPL = 0x48dBe696A4D990079e039489bA2053B36E8FFEC4;
    address constant SIMPLE_FACTORY = 0x69Aa2f9fe1572F1B640E1bbc512f5c3a734fc77c;

    function _fixture(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/fixtures/delegation-framework-v1.3.0/", name, ".initcode.hex")));
    }

    function _create2(bytes32 salt, bytes memory initcode, address expected) internal {
        if (expected.code.length != 0) return;
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
        require(ok && address(bytes20(ret)) == expected, "CREATE2 did not land on the canonical address");
    }

    /// SA-2 L-8: a contract already at a canonical CREATE2 address is accepted only if that address is the
    /// deterministic deployer's derivation of the fixture initcode (the address commits to the initcode).
    function _canonical(bytes32 salt, bytes memory initcode, address expected) internal pure {
        address got = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initcode)))))
        );
        require(got == expected, "fixture does not derive the canonical address");
    }

    /// SA-3 L-13 / L-16: a venue contract is accepted only if its runtime code equals the fixture the tests run on.
    function _sameCode(address a, string memory name) internal view {
        require(
            keccak256(a.code) == keccak256(vm.parseBytes(vm.readFile(string.concat("test/fixtures/elysium/", name, ".runtime.hex")))),
            string.concat(name, ": code differs from the fixture")
        );
    }

    /// SA-4 L-12: the pilot parameters (docs/audit/sa_round4_response.md).
    function pilotParams() public pure returns (LPManagerModule.Params memory) {
        return LPManagerModule.Params({
            feeBps: 1500,
            hedgeCapBps: 3500,
            poolBandBps: 150,
            maxSlippageBps: 150,
            hedgeStepBps: 500,
            refDriftBps: 1000,
            swapTurnoverBps: 5000,
            feeInterval: 7 days,
            maxPriceAge: 3600,
            minPriceStable: 300,
            exitTurnoverBps: 10000
        });
    }

    /// SA-4 L-13: a multisig owner, not a (7702-delegated) EOA: no 0xef0100 designator, Safe threshold >= 2.
    function _checkOwner(address owner) internal view {
        if (vm.envOr("ALLOW_EOA_OWNER", false)) return;
        bytes memory code = owner.code;
        require(code.length != 0, "OWNER must be a multisig");
        require(
            !(code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00),
            "OWNER is a 7702-delegated EOA, not a multisig"
        );
        uint256 t;
        try ISafeThreshold(owner).getThreshold() returns (uint256 x) {
            t = x;
        } catch {}
        require(t >= 2, "OWNER must be a Safe with threshold >= 2");
    }

    function run() external returns (LPManagerModule module, ElysiumCustodyEnforcer enforcer, SwapExecutor executor) {
        require(block.chainid == CHAIN_ID, "wrong chain");
        address owner = vm.envAddress("OWNER");
        address guardian = vm.envAddress("GUARDIAN");
        address keeper = vm.envAddress("KEEPER");
        address treasury = vm.envAddress("HEDGE_TREASURY");
        address feeTo = vm.envAddress("FEE_RECIPIENT");
        require(
            owner != guardian && owner != keeper && guardian != keeper && owner != address(0) && guardian != address(0)
                && keeper != address(0) && treasury != address(0) && feeTo != address(0) && treasury != feeTo,
            "roles must be distinct and non-zero"
        );
        // SA-1 L-8: the hot keys never hold the treasury / fee roles (the module constructor enforces the same)
        require(
            keeper != treasury && keeper != feeTo && guardian != treasury && guardian != feeTo && owner != treasury
                && owner != feeTo,
            "keeper / guardian / owner must not be the treasury or the fee recipient"
        );
        require(IERC20Metadata(USDC).decimals() == 6, "USDC decimals");
        require(
            PM.code.length != 0 && POSM.code.length != 0 && PERMIT2.code.length != 0 && DM.code.length != 0
                && EIP7702_IMPL.code.length != 0 && TIMESTAMP_ENFORCER.code.length != 0 && ENTRYPOINT.code.length != 0
                && CREATE2_DEPLOYER.code.length != 0,
            "missing v4 / Delegation Framework / EntryPoint contracts"
        );
        _checkOwner(owner);
        _sameCode(PM, "PoolManager");
        _sameCode(POSM, "PositionManager");
        _sameCode(PERMIT2, "Permit2");
        _sameCode(ENTRYPOINT, "EntryPointV07");
        require(IPosmWiring(POSM).poolManager() == PM, "PositionManager is not bound to this PoolManager");
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        require(delay >= 24 hours && delay <= 30 days, "TIMELOCK_DELAY outside [24h, 30d]");
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        // SA-2 L-8: the first reportPrice is free and bounded only by the pool, so the pool must be live and deep
        (uint160 sp,,,) = IPoolManager(PM).getSlot0(key.toId());
        require(sp != 0 && IPoolManager(PM).getLiquidity(key.toId()) != 0, "pool not initialised / no liquidity");
        require(!IPausable(DM).paused(), "DelegationManager paused");
        require(
            keccak256(CREATE2_DEPLOYER.code)
                == keccak256(vm.parseBytes(vm.readFile("test/fixtures/elysium/Create2Deployer.runtime.hex"))),
            "not the deterministic CREATE2 deployer"
        );
        bytes memory gatorArgs0 = abi.encode(DM, ENTRYPOINT);
        _canonical(bytes32("GATOR"), abi.encodePacked(_fixture("DelegationManager"), abi.encode(0xB0403B32f54d0Bd752113f4009e8B534C6669f44)), DM);
        _canonical(bytes32("GATOR"), abi.encodePacked(_fixture("EIP7702StatelessDeleGator"), gatorArgs0), EIP7702_IMPL);
        _canonical(bytes32("GATOR"), _fixture("TimestampEnforcer"), TIMESTAMP_ENFORCER);
        _canonical(bytes32(0), _fixture("SCL_RIP7212"), SCL_LIB);
        _canonical(bytes32("GATOR"), abi.encodePacked(_fixture("HybridDeleGator.linked"), gatorArgs0), HYBRID_IMPL);
        _canonical(bytes32("GATOR"), _fixture("SimpleFactory"), SIMPLE_FACTORY);

        vm.startBroadcast();
        bytes memory gatorArgs = abi.encode(DM, ENTRYPOINT);
        _create2(bytes32(0), _fixture("SCL_RIP7212"), SCL_LIB);
        _create2(bytes32("GATOR"), abi.encodePacked(_fixture("HybridDeleGator.linked"), gatorArgs), HYBRID_IMPL);
        _create2(bytes32("GATOR"), _fixture("SimpleFactory"), SIMPLE_FACTORY);

        require(HYBRID_IMPL.code.length != 0 && SIMPLE_FACTORY.code.length != 0, "canonical gator contracts missing");

        VaultTimelock timelock = new VaultTimelock(delay, owner, guardian);
        executor = new SwapExecutor(IPoolManager(PM), PERMIT2, key);
        enforcer = new ElysiumCustodyEnforcer(DM, POSM, PERMIT2, address(executor), USDC, key);
        module = new LPManagerModule(
            LPManagerModule.Config({
                delegationManager: IDelegationManager(DM),
                enforcer: address(enforcer),
                timestampEnforcer: TIMESTAMP_ENFORCER,
                hybridImpl: HYBRID_IMPL,
                eip7702Impl: EIP7702_IMPL,
                factory: SIMPLE_FACTORY,
                accountSalt: bytes32("ELYSIUM-LP-V1"),
                poolManager: IPoolManager(PM),
                positionManager: IPositionManagerMin(POSM),
                permit2: PERMIT2,
                swapExecutor: address(executor),
                key: key,
                asset: IERC20(USDC),
                hedgeTreasury: treasury,
                feeRecipient: feeTo,
                owner: address(timelock),
                keeper: keeper,
                guardian: guardian,
                params: pilotParams()
            })
        );
        vm.stopBroadcast();
        // SA-2 L-8: the module's CREATE2 derivation must equal the factory's, or every hybrid registration reverts
        address probe = address(0xBEEF);
        bytes memory init = abi.encodeCall(
            IHybridDeleGator.initialize, (probe, new string[](0), new uint256[](0), new uint256[](0))
        );
        bytes memory proxyInit = abi.encodePacked(_fixture("ERC1967Proxy"), abi.encode(HYBRID_IMPL, init));
        SALib.Expect memory e;
        e.hybridImpl = module.hybridImpl(); // SA-3 L-13: the probe reads the deployed module, not local constants
        e.factory = module.factory();
        e.accountSalt = module.accountSalt();
        require(
            SALib.hybridAddress(e, probe)
                == ISimpleFactory(SIMPLE_FACTORY).computeAddress(keccak256(proxyInit), bytes32("ELYSIUM-LP-V1")),
            "module and factory derive different account addresses"
        );
        // SA-3 L-13 / L-16: read the wiring back from the deployed contracts
        require(module.owner() == address(timelock) && module.keeper() == keeper && module.guardian() == guardian, "module roles");
        require(
            module.positionManager() == IPositionManagerMin(POSM) && address(module.poolManager()) == PM
                && module.swapExecutor() == address(executor) && module.enforcer() == address(enforcer),
            "module wiring"
        );
        require(
            timelock.hasRole(timelock.PROPOSER_ROLE(), owner) && timelock.hasRole(timelock.EXECUTOR_ROLE(), owner)
                && timelock.hasRole(timelock.CANCELLER_ROLE(), guardian) && timelock.hasRole(timelock.CANCELLER_ROLE(), owner)
                && timelock.getMinDelay() == delay,
            "timelock roles"
        );
        // SA-4 L-12: the immutables and the full params tuple, read back from the deployed module
        require(
            address(module.asset()) == USDC && module.hedgeTreasury() == treasury && module.feeRecipient() == feeTo
                && module.permit2() == PERMIT2 && address(module.delegationManager()) == DM
                && module.timestampEnforcer() == TIMESTAMP_ENFORCER && module.eip7702Impl() == EIP7702_IMPL
                && !module.paused(),
            "module immutables"
        );
        _checkParams(module);
        // operator step left: the treasury approves the module for USDC (returnHedgeMargin), sized per return
    }

    function _checkParams(LPManagerModule module) internal view {
        LPManagerModule.Params memory w = pilotParams();
        (uint16 a, uint16 b, uint16 c, uint16 d, uint16 e, uint16 f, uint32 g, uint32 h, uint32 i, uint32 j, uint16 k) =
            module.params();
        require(
            a == w.feeBps && b == w.hedgeCapBps && c == w.poolBandBps && d == w.maxSlippageBps && e == w.hedgeStepBps
                && f == w.refDriftBps && g == w.swapTurnoverBps && h == w.feeInterval && i == w.maxPriceAge
                && j == w.minPriceStable && k == w.exitTurnoverBps,
            "module params differ from the pilot values"
        );
    }
}
