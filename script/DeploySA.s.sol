// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
///    and GUARDIAN cancel). Forge links SALib / V4PositionMath / RiskBudgets automatically.
/// Env: OWNER, KEEPER, GUARDIAN, HEDGE_TREASURY, FEE_RECIPIENT, optional TIMELOCK_DELAY (default 48 h, >= 24 h).
/// After deploying: the keeper calls reportPrice once (anchor), the treasury approves the module for USDC.
contract DeploySA is Script {
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
        require(IERC20Metadata(USDC).decimals() == 6, "USDC decimals");
        require(
            PM.code.length != 0 && POSM.code.length != 0 && PERMIT2.code.length != 0 && DM.code.length != 0
                && EIP7702_IMPL.code.length != 0 && TIMESTAMP_ENFORCER.code.length != 0 && ENTRYPOINT.code.length != 0
                && CREATE2_DEPLOYER.code.length != 0,
            "missing v4 / Delegation Framework / EntryPoint contracts"
        );
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        require(delay >= 24 hours, "TIMELOCK_DELAY < 24h");
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 60, IHooks(address(0)));

        vm.startBroadcast();
        bytes memory gatorArgs = abi.encode(DM, ENTRYPOINT);
        _create2(bytes32(0), _fixture("SCL_RIP7212"), SCL_LIB);
        _create2(bytes32("GATOR"), abi.encodePacked(_fixture("HybridDeleGator.linked"), gatorArgs), HYBRID_IMPL);
        _create2(bytes32("GATOR"), _fixture("SimpleFactory"), SIMPLE_FACTORY);

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
                params: LPManagerModule.Params({
                    feeBps: 1500,
                    hedgeCapBps: 3500,
                    poolBandBps: 150,
                    maxSlippageBps: 150,
                    hedgeStepBps: 500,
                    refDriftBps: 1000,
                    swapTurnoverBps: 20000,
                    feeInterval: 7 days,
                    maxPriceAge: 3600
                })
            })
        );
        vm.stopBroadcast();
    }
}
