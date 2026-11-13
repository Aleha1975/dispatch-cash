// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPVaultBase} from "../../src/LPVaultBase.sol";
import {MockUSDC, MockLPVault} from "../mocks/Mocks.sol";

abstract contract VaultTestBase is Test {
    MockUSDC usdc;
    MockLPVault vault;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeTo = makeAddr("feeTo");
    address treasury = makeAddr("hedgeTreasury");
    address alice;
    uint256 aliceKey;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant P0 = 40e6; // $40 per HYPE: USDC raw per 1e18 wei

    function defaultParams() internal pure returns (LPVaultBase.Params memory) {
        return LPVaultBase.Params({
            feeBps: 1500,
            hedgeCapBps: 3500,
            poolBandBps: 150,
            maxSlippageBps: 100,
            hedgeStepBps: 500,
            refDriftBps: 1000,
            swapTurnoverBps: 20000,
            minDeposit: 1e6
        });
    }

    function config(address hedgeTreasury_) internal view returns (LPVaultBase.BaseConfig memory) {
        LPVaultBase.Params memory p = defaultParams();
        if (hedgeTreasury_ == address(0)) (p.hedgeCapBps, p.hedgeStepBps) = (0, 0);
        return LPVaultBase.BaseConfig({
            asset: IERC20(address(usdc)),
            baseToken: address(0),
            wrappedBase: address(0),
            hedgeTreasury: hedgeTreasury_,
            owner: owner,
            keeper: keeper,
            guardian: guardian,
            feeRecipient: feeTo,
            name: "Hedged HYPE/USDC LP",
            symbol: "hvHYPE",
            params: p
        });
    }

    function setUp() public virtual {
        (alice, aliceKey) = makeAddrAndKey("alice");
        usdc = new MockUSDC();
        vault = new MockLPVault(config(treasury), P0);
        // swap inventory for the mock pool
        usdc.mint(address(vault.pool()), 10_000_000e6);
        vm.deal(address(vault.pool()), 1_000_000 ether);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
        vm.prank(treasury);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---- helpers
    function report(uint256 price, uint256 hedge) internal view returns (LPVaultBase.Report memory) {
        return LPVaultBase.Report({epoch: vault.epoch(), price: price, hedgeEquity: hedge, maxDeposits: 100, maxRedeems: 100});
    }

    function settle(uint256 price) internal {
        settle(price, vault.hedgeEquity());
    }

    function settle(uint256 price, uint256 hedge) internal {
        vault.setPoolPrice(price);
        LPVaultBase.Report memory r = report(price, hedge);
        vm.prank(keeper);
        vault.settle(r);
    }

    function deposit(address who, uint256 a) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestDeposit(a);
    }

    function redeem(address who, uint256 sh) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(sh);
    }

    /// Keeper gone: wait out the 72 h no-progress timeout, arm, wait the notice, execute.
    function forceEmergency() internal {
        vm.warp(vault.lastProgressTime() + 72 hours + 1);
        vault.emergencyUnwind(); // arm
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vault.emergencyUnwind();
        assertTrue(vault.emergency());
    }

    function valueOf(address who) internal view returns (uint256) {
        return vault.previewRedeemLast(vault.balanceOf(who));
    }
}
