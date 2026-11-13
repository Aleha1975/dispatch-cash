// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPVaultBase} from "../src/LPVaultBase.sol";
import {UniV4LPVault} from "../src/UniV4LPVault.sol";
import {VaultTimelock} from "../src/VaultTimelock.sol";
import {IPositionManagerMin, IPermit2Min} from "../src/interfaces/IExternal.sol";

/// One vault per strategy. NOT EXECUTED YET. Hedged: HEDGE_TREASURY=<addr> HEDGE_CAP_BPS=3500.
/// Growth (unhedged): HEDGE_TREASURY=0x0 HEDGE_CAP_BPS=0 (hedge step is then forced to 0).
/// Forge links V4PositionMath and RiskBudgets automatically.
/// The vault owner is a VaultTimelock (TIMELOCK_DELAY, default 96 h: longer than the 72 h no-progress exit, so
/// holders can always leave before a change lands; floor 24 h, cap 30 d): OWNER (multisig) proposes and executes,
/// OWNER and GUARDIAN can cancel. Pass TIMELOCK=<addr> to reuse one timelock for several vaults; it is then checked
/// for code, delay, and the OWNER/GUARDIAN roles.
contract Deploy is Script {
    uint256 constant CHAIN_ID = 99901; // Elysium
    address constant USDC = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
    address constant WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;
    address constant PM = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
    address constant POSM = 0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant SETTLE_TIMEOUT = 72 hours;

    function run() external returns (UniV4LPVault vault, VaultTimelock timelock) {
        require(block.chainid == CHAIN_ID, "wrong chain");
        address owner = vm.envAddress("OWNER");
        address guardian = vm.envAddress("GUARDIAN");
        address keeper = vm.envAddress("KEEPER");
        address treasury = vm.envAddress("HEDGE_TREASURY");
        // L-13: one key must not hold two roles (keeper == guardian would self-approve hedge equity)
        require(
            owner != guardian && owner != keeper && guardian != keeper && owner != address(0) && guardian != address(0)
                && keeper != address(0),
            "roles must be distinct and non-zero"
        );
        // L-14: validate before narrowing
        uint256 cap = vm.envUint("HEDGE_CAP_BPS");
        require(cap <= 5000, "HEDGE_CAP_BPS > 5000");
        require((treasury == address(0)) == (cap == 0), "hedge cap iff treasury");
        // I-3: token assumptions the params and NAV math rely on
        require(IERC20Metadata(USDC).decimals() == 6, "USDC decimals");
        require(IERC20Metadata(WHYPE).decimals() == 18, "WHYPE decimals");
        require(PM.code.length != 0 && POSM.code.length != 0 && PERMIT2.code.length != 0, "missing v4 contracts");

        timelock = VaultTimelock(payable(vm.envOr("TIMELOCK", address(0))));
        if (address(timelock) != address(0)) {
            require(address(timelock).code.length != 0, "TIMELOCK has no code");
            require(timelock.getMinDelay() > SETTLE_TIMEOUT, "TIMELOCK delay <= 72h");
            require(timelock.hasRole(timelock.PROPOSER_ROLE(), owner), "OWNER not proposer");
            require(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian), "GUARDIAN not canceller");
        }
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(96 hours));
        require(delay > SETTLE_TIMEOUT, "TIMELOCK_DELAY <= 72h");

        vm.startBroadcast();
        if (address(timelock) == address(0)) timelock = new VaultTimelock(delay, owner, guardian);
        LPVaultBase.BaseConfig memory c = LPVaultBase.BaseConfig({
            asset: IERC20(USDC),
            baseToken: address(0),
            wrappedBase: WHYPE,
            hedgeTreasury: treasury,
            owner: address(timelock),
            keeper: keeper,
            guardian: guardian,
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            params: LPVaultBase.Params({
                feeBps: 1500,
                // forge-lint: disable-next-line(unsafe-typecast)
                hedgeCapBps: uint16(cap),
                poolBandBps: 150,
                maxSlippageBps: 100,
                hedgeStepBps: treasury == address(0) ? 0 : 500,
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
        require(vault.owner() == address(timelock), "owner wiring");
    }
}
