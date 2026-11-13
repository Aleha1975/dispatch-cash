// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPVaultBase} from "../src/LPVaultBase.sol";
import {UniV4LPVault} from "../src/UniV4LPVault.sol";
import {VaultTimelock} from "../src/VaultTimelock.sol";
import {IPositionManagerMin, IPermit2Min} from "../src/interfaces/IExternal.sol";

/// One vault per strategy. NOT EXECUTED YET. Hedged: HEDGE_TREASURY=<addr> HEDGE_CAP_BPS=3500.
/// Growth (unhedged): HEDGE_TREASURY=0x0 HEDGE_CAP_BPS=0. Forge links V4PositionMath automatically.
/// The vault owner is a VaultTimelock (TIMELOCK_DELAY, default 48 h, floor 24 h): OWNER (multisig) proposes and
/// executes, OWNER and GUARDIAN can cancel. Pass TIMELOCK=<addr> to reuse one timelock for several vaults.
contract Deploy is Script {
    address constant USDC = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
    address constant WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;
    address constant PM = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
    address constant POSM = 0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (UniV4LPVault vault, VaultTimelock timelock) {
        address owner = vm.envAddress("OWNER");
        address guardian = vm.envAddress("GUARDIAN");
        timelock = VaultTimelock(payable(vm.envOr("TIMELOCK", address(0))));
        vm.startBroadcast();
        if (address(timelock) == address(0)) {
            timelock = new VaultTimelock(vm.envOr("TIMELOCK_DELAY", uint256(48 hours)), owner, guardian);
        }
        LPVaultBase.BaseConfig memory c = LPVaultBase.BaseConfig({
            asset: IERC20(USDC),
            baseToken: address(0),
            wrappedBase: WHYPE,
            hedgeTreasury: vm.envAddress("HEDGE_TREASURY"),
            owner: address(timelock),
            keeper: vm.envAddress("KEEPER"),
            guardian: guardian,
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            params: LPVaultBase.Params({
                feeBps: 1500,
                hedgeCapBps: uint16(vm.envUint("HEDGE_CAP_BPS")),
                poolBandBps: 150,
                maxSlippageBps: 100,
                hedgeStepBps: 500,
                refDriftBps: 1000,
                swapTurnoverBps: 20000,
                minDeposit: 1e6
            })
        });
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        vault = new UniV4LPVault(
            c, UniV4LPVault.V4Config(IPoolManager(PM), IPositionManagerMin(POSM), IPermit2Min(PERMIT2), key)
        );
        vm.stopBroadcast();
    }
}
