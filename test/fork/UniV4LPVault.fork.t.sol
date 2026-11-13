// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {LPVaultBase} from "../../src/LPVaultBase.sol";
import {UniV4LPVault} from "../../src/UniV4LPVault.sol";
import {V4PositionMath} from "../../src/V4PositionMath.sol";
import {IPositionManagerMin, IPermit2Min} from "../../src/interfaces/IExternal.sol";

/// Third-party swapper used to move the pool (fees / manipulation) on the fork.
contract Trader is IUnlockCallback {
    IPoolManager immutable pm;
    PoolKey key;

    constructor(IPoolManager pm_, PoolKey memory k) {
        pm = pm_;
        key = k;
    }

    receive() external payable {}

    function swap(bool zeroForOne, uint256 amountIn) external {
        pm.unlock(abi.encode(zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (bool z, uint256 amt) = abi.decode(data, (bool, uint256));
        BalanceDelta d = pm.swap(
            key,
            SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            ""
        );
        int128 dIn = z ? d.amount0() : d.amount1();
        int128 dOut = z ? d.amount1() : d.amount0();
        Currency cIn = z ? key.currency0 : key.currency1;
        Currency cOut = z ? key.currency1 : key.currency0;
        uint256 pay = uint256(uint128(-dIn));
        if (cIn.isAddressZero()) {
            pm.settle{value: pay}();
        } else {
            pm.sync(cIn);
            IERC20(Currency.unwrap(cIn)).transfer(address(pm), pay);
            pm.settle();
        }
        pm.take(cOut, address(this), uint256(uint128(dOut)));
        return "";
    }
}

/// Fork tests against Elysium mainnet (chain 99901). Enable with ELYSIUM_FORK=true (and optionally ELYSIUM_RPC,
/// ELYSIUM_FORK_BLOCK). Nothing is broadcast: all state lives in the local fork.
contract UniV4LPVaultForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant USDC = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
    address constant WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;
    IPoolManager constant PM = IPoolManager(0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1);
    address constant POSM = 0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 constant POOL_ID = 0xb3032695ffb0a66e6342876dd2386835471466cb2bb70f341947d98a69e265cc;

    UniV4LPVault vault;
    Trader trader;
    PoolKey key;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeTo = makeAddr("feeTo");
    address treasury = makeAddr("hedgeTreasury");
    address alice;
    uint256 aliceKey;
    address bob = makeAddr("bob");

    function setUp() public {
        if (!vm.envOr("ELYSIUM_FORK", false)) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envOr("ELYSIUM_RPC", string("https://rpc.elysium.kinetiq.xyz"));
        uint256 blk = vm.envOr("ELYSIUM_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        assertEq(block.chainid, 99901);

        (alice, aliceKey) = makeAddrAndKey("alice");
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        assertEq(PoolId.unwrap(key.toId()), POOL_ID);

        LPVaultBase.BaseConfig memory c = LPVaultBase.BaseConfig({
            asset: IERC20(USDC),
            baseToken: address(0),
            wrappedBase: WHYPE,
            hedgeTreasury: treasury,
            owner: owner,
            keeper: keeper,
            guardian: guardian,
            feeRecipient: feeTo,
            name: "Hedged HYPE/USDC v4 LP",
            symbol: "hvHYPE-v4",
            params: LPVaultBase.Params({
                feeBps: 1500,
                hedgeCapBps: 3500,
                poolBandBps: 150,
                maxSlippageBps: 150,
                hedgeStepBps: 500,
                refDriftBps: 1000,
                swapTurnoverBps: 20000,
                minDeposit: 1e6
            })
        });
        vault = new UniV4LPVault(
            c, UniV4LPVault.V4Config(PM, IPositionManagerMin(POSM), IPermit2Min(PERMIT2), key)
        );
        trader = new Trader(PM, key);

        deal(USDC, alice, 50_000e6);
        deal(USDC, bob, 50_000e6);
        vm.prank(alice);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers
    function _price() internal view returns (uint256) {
        return vault.poolPrice();
    }

    function _settle() internal {
        LPVaultBase.Report memory r = LPVaultBase.Report(vault.epoch(), _price(), vault.hedgeEquity(), 50, 50);
        vm.prank(keeper);
        vault.settle(r);
    }

    function _bobPermitDeposit(uint256 amount) internal {
        uint256 bobKey = uint256(keccak256("bob-key"));
        address b = vm.addr(bobKey);
        deal(USDC, b, amount);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                b,
                address(vault),
                amount,
                IERC20Permit(USDC).nonces(b),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(USDC).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        vm.prank(b);
        vault.requestDepositWithPermit(amount, deadline, v, r, s);
        bob = b;
    }

    function _range() internal view returns (int24 tl, int24 tu) {
        (, int24 tick,,) = PM.getSlot0(key.toId());
        int24 c = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) c -= 60;
        tl = c - 1020; // ~ -10%
        tu = c + 1080; // ~ +10%
    }

    function _mintAll() internal returns (uint256 id) {
        (int24 tl, int24 tu) = _range();
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        uint256 hype = address(vault).balance;
        uint256 usdc = vault.idleAsset();
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), hype * 99 / 100, usdc * 99 / 100
        );
        uint256 px = _price();
        vm.prank(keeper);
        id = vault.mintPosition(tl, tu, liq, uint128(hype), uint128(usdc), px);
    }

    function _swapIn(bool sellBase, uint256 amt) internal returns (uint256 out) {
        uint256 px = _price();
        vm.prank(keeper);
        out = vault.swap(sellBase, amt, px);
    }

    // ------------------------------------------------------------------ tests
    function test_fork_FullLifecycle_MintCollectIncreaseBurnSwapRedeem() public {
        uint256 p0 = _price();
        console2.log("pool price (USDC raw per HYPE)", p0);

        // 1. clients enter: alice approve+request, bob permit (1 signature + 1 tx)
        vm.prank(alice);
        vault.requestDeposit(20_000e6);
        _bobPermitDeposit(10_000e6);
        _settle();
        assertEq(vault.lastNav(), 30_000e6);

        // 2. keeper buys the HYPE leg through the configured pool and mints a +-10% position owned by the vault
        uint256 out = _swapIn(false, 1_500e6);
        assertGt(out, 0);
        assertEq(address(vault).balance, out);
        uint256 id = _mintAll();
        assertEq(IPositionManagerMin(POSM).ownerOf(id), address(vault));
        assertGt(IPositionManagerMin(POSM).getPositionLiquidity(id), 0);
        (uint256 lpBase, uint256 lpUsdc) = vault.positionAmounts();
        console2.log("LP HYPE wei", lpBase);
        console2.log("LP USDC raw", lpUsdc);
        uint256 nav = vault.grossAssets(_price());
        console2.log("NAV after mint", nav);
        assertApproxEqRel(nav, 30_000e6, 0.01e18); // only swap fee + impact lost

        // 3. third-party volume generates fees
        deal(USDC, address(trader), 200_000e6);
        vm.deal(address(trader), 5_000 ether);
        for (uint256 i; i < 5; ++i) {
            trader.swap(false, 5_000e6);
            trader.swap(true, 5_000e6 * 1e18 / p0);
        }
        (uint256 b1, uint256 a1) = vault.positionAmounts();
        // 4. collect fees (DECREASE 0 + TAKE_PAIR) into the vault
        uint256 hypeBefore = address(vault).balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        vm.prank(keeper);
        vault.decreasePosition(id, 0, 0, 0);
        uint256 feesHype = address(vault).balance - hypeBefore;
        uint256 feesUsdc = IERC20(USDC).balanceOf(address(vault)) - usdcBefore;
        console2.log("collected fees HYPE wei", feesHype);
        console2.log("collected fees USDC raw", feesUsdc);
        assertGt(feesHype + feesUsdc, 0);
        (uint256 b2, uint256 a2) = vault.positionAmounts();
        assertLe(b2, b1);
        assertLe(a2, a1);

        // 5. increase with the collected fees (CLOSE_CURRENCY + SWEEP path)
        uint128 liqBefore = IPositionManagerMin(POSM).getPositionLiquidity(id);
        {
            uint256 hype = address(vault).balance;
            uint256 usdc = vault.idleAsset();
            V4PositionMath.Position[] memory ps = _positions();
            (uint160 sp,,,) = PM.getSlot0(key.toId());
            uint128 add = LiquidityAmounts.getLiquidityForAmounts(
                sp, TickMath.getSqrtPriceAtTick(ps[0].tickLower), TickMath.getSqrtPriceAtTick(ps[0].tickUpper), hype / 2, usdc / 2
            );
            uint256 px = _price();
            vm.prank(keeper);
            vault.increasePosition(id, add, uint128(hype), uint128(usdc), px);
        }
        assertGt(IPositionManagerMin(POSM).getPositionLiquidity(id), liqBefore);

        // 6. settle: fees above HWM are charged
        _settle();
        console2.log("NAV", vault.lastNav());
        console2.log("fee shares", vault.balanceOf(feeTo));

        // 7. everybody exits: request, keeper burns the position and sells HYPE, settlement pushes USDC
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobShares);

        vm.prank(keeper);
        vault.burnPosition(id, 0, 0);
        assertEq(vault.positions().length, 0);
        vm.expectRevert();
        IPositionManagerMin(POSM).ownerOf(id);
        _swapIn(true, address(vault).balance);

        uint256 aliceUsdc0 = IERC20(USDC).balanceOf(alice);
        uint256 bobUsdc0 = IERC20(USDC).balanceOf(bob);
        _settle();
        uint256 aliceGot = IERC20(USDC).balanceOf(alice) - aliceUsdc0;
        uint256 bobGot = IERC20(USDC).balanceOf(bob) - bobUsdc0;
        console2.log("alice got back", aliceGot);
        console2.log("bob got back", bobGot);
        assertApproxEqRel(aliceGot, 20_000e6, 0.01e18);
        assertApproxEqRel(bobGot, 10_000e6, 0.01e18);
        assertEq(vault.pendingRedeems(), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_fork_EmergencyUnwindBurnsAndPaysInKind() public {
        vm.prank(alice);
        vault.requestDeposit(10_000e6);
        _settle();
        _swapIn(false, 500e6);
        uint256 id = _mintAll();
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(makeAddr("anyone"));
        vault.emergencyUnwind();
        assertTrue(vault.emergency());
        assertEq(vault.positions().length, 0);
        vm.expectRevert();
        IPositionManagerMin(POSM).ownerOf(id);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyRedeem(sh, alice);
        uint256 value = IERC20(USDC).balanceOf(alice) - 40_000e6 + alice.balance * _price() / 1e18;
        console2.log("alice in-kind value", value);
        assertApproxEqRel(value, 10_000e6, 0.01e18);
        assertEq(address(vault).balance, 0);
    }

    function test_fork_MintRevertsWhenPoolManipulated() public {
        vm.prank(alice);
        vault.requestDeposit(10_000e6);
        _settle();
        _swapIn(false, 500e6);
        uint256 honest = _price();
        // attacker pushes the pool price up by dumping USDC
        deal(USDC, address(trader), 500_000e6);
        trader.swap(false, 300_000e6);
        assertGt(_price(), honest * 1015 / 1000);
        (int24 tl, int24 tu) = _range();
        vm.prank(keeper);
        vm.expectRevert();
        vault.mintPosition(tl, tu, 1e12, uint128(address(vault).balance), 1_000e6, honest);
        // and settlement at the honest price is refused too
        LPVaultBase.Report memory r = LPVaultBase.Report(vault.epoch(), honest, 0, 50, 50);
        vm.prank(keeper);
        vm.expectRevert();
        vault.settle(r);
    }

    function test_fork_OnlyKeeperAndNoForeignPositions() public {
        vm.prank(alice);
        vault.requestDeposit(5_000e6);
        _settle();
        (int24 tl, int24 tu) = _range();
        uint256 px = _price();
        vm.prank(alice);
        vm.expectRevert(LPVaultBase.NotKeeper.selector);
        vault.mintPosition(tl, tu, 1e12, 0, 1_000e6, px);
        // a position the vault does not own/track cannot be touched
        vm.prank(keeper);
        vm.expectRevert(UniV4LPVault.UnknownPosition.selector);
        vault.decreasePosition(11805, 0, 0, 0);
        // unlockCallback cannot be invoked outside a vault swap
        vm.prank(address(PM));
        vm.expectRevert(UniV4LPVault.NotPoolManager.selector);
        vault.unlockCallback(abi.encode(true, uint256(1)));
    }

    function _positions() internal view returns (V4PositionMath.Position[] memory) {
        return vault.positions();
    }
}
