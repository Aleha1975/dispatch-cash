// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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

import {V4PositionMath} from "../../src/V4PositionMath.sol";
import {VaultTimelock} from "../../src/VaultTimelock.sol";
import {IPositionManagerMin} from "../../src/interfaces/IExternal.sol";
import {SALib} from "../../src/sa/SALib.sol";
import {SwapExecutor} from "../../src/sa/SwapExecutor.sol";
import {ElysiumCustodyEnforcer} from "../../src/sa/ElysiumCustodyEnforcer.sol";
import {LPManagerModule} from "../../src/sa/LPManagerModule.sol";
import {
    Delegation,
    Caveat,
    Execution,
    ModeCode,
    IDelegationManager,
    IDeleGatorCore,
    IHybridDeleGator,
    ISimpleFactory,
    DelegationFramework
} from "../../src/sa/vendor/DelegationFramework.sol";
import {MockUSDC} from "../mocks/Mocks.sol";

struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

interface IEntryPointV07 {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getNonce(address sender, uint192 key) external view returns (uint256);
}

interface IDeleGatorUserOp {
    function getPackedUserOperationTypedDataHash(PackedUserOperation calldata op) external view returns (bytes32);
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Third-party swapper that moves the pool (volume, manipulation).
contract SATrader is IUnlockCallback {
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
            key, SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), ""
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

/// Environment for the smart-account tests.
/// - replica (default, offline): the exact runtime code of Elysium's PoolManager, PositionManager, Permit2, EntryPoint
///   v0.7 and the Arachnid CREATE2 deployer is etched at the Elysium addresses (test/fixtures/elysium, fetched at
///   block ~6,029,000); MockUSDC (EIP-2612) is the asset; a fresh HYPE/USDC 0.3% pool is initialised and seeded.
/// - fork (ELYSIUM_FORK=true): Elysium mainnet state, the real USDC and the real HYPE/USDC pool.
/// In both, the Delegation Framework v1.3.0 contracts are created from test/fixtures/delegation-framework-v1.3.0 through
/// the CREATE2 deployer with salt "GATOR" and must land on their canonical addresses (already present on the fork for
/// the DelegationManager, EIP7702StatelessDeleGator and TimestampEnforcer).
abstract contract SATestBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant GATOR = bytes32("GATOR");
    address constant DM_ADDR = 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3;
    address constant DM_OWNER = 0xB0403B32f54d0Bd752113f4009e8B534C6669f44;
    address constant EIP7702_IMPL = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B;
    address constant TIMESTAMP_ENFORCER = 0x1046bb45C8d673d4ea75321280DB34899413c069;
    address constant SCL_LIB = 0xCCD3B747F3DBd349fa3af4eBC7d0C31aE6f21dd1;
    address constant HYBRID_IMPL = 0x48dBe696A4D990079e039489bA2053B36E8FFEC4;
    address constant SIMPLE_FACTORY = 0x69Aa2f9fe1572F1B640E1bbc512f5c3a734fc77c;
    address constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    address constant PM_ADDR = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
    address constant POSM_ADDR = 0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ELYSIUM_USDC = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
    bytes32 constant ELYSIUM_POOL_ID = 0xb3032695ffb0a66e6342876dd2386835471466cb2bb70f341947d98a69e265cc;
    bytes32 constant ACCOUNT_SALT = bytes32("ELYSIUM-LP-V1");
    uint256 constant DAY = 1 days;

    IDelegationManager constant DM = IDelegationManager(DM_ADDR);
    IPoolManager constant PM = IPoolManager(PM_ADDR);
    IPositionManagerMin constant POSM = IPositionManagerMin(POSM_ADDR);

    bool internal forked;
    IERC20 internal usdc;
    PoolKey internal key;
    SwapExecutor internal executor;
    ElysiumCustodyEnforcer internal enforcer;
    LPManagerModule internal module;
    VaultTimelock internal timelock;
    SATrader internal trader;

    address internal operator = makeAddr("operator");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("hedgeTreasury");
    address internal feeTo = makeAddr("feeRecipient");
    address internal relayer = makeAddr("relayer");
    address internal lp = makeAddr("lp");

    // ------------------------------------------------------------------ environment
    function _setUpEnv(bool fork) internal {
        forked = fork;
        if (fork) {
            string memory rpc = vm.envOr("ELYSIUM_RPC", string("https://rpc.elysium.kinetiq.xyz"));
            uint256 blk = vm.envOr("ELYSIUM_FORK_BLOCK", uint256(0));
            if (blk == 0) vm.createSelectFork(rpc);
            else vm.createSelectFork(rpc, blk);
            assertEq(block.chainid, 99901);
            usdc = IERC20(ELYSIUM_USDC);
            key = PoolKey(Currency.wrap(address(0)), Currency.wrap(ELYSIUM_USDC), 3000, 60, IHooks(address(0)));
            assertEq(PoolId.unwrap(key.toId()), ELYSIUM_POOL_ID);
        } else {
            vm.chainId(99901);
            vm.warp(1_794_600_000);
            _etch(CREATE2_DEPLOYER, "Create2Deployer");
            _etch(PM_ADDR, "PoolManager");
            _etch(POSM_ADDR, "PositionManager");
            vm.store(POSM_ADDR, bytes32(uint256(8)), bytes32(uint256(1))); // nextTokenId = 1 (constructor-set storage)
            _etch(PERMIT2, "Permit2");
            _etch(ENTRYPOINT, "EntryPointV07");
            _etch(SENDER_CREATOR, "SenderCreatorV07");
            usdc = IERC20(address(new MockUSDC()));
            key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 3000, 60, IHooks(address(0)));
            PM.initialize(key, SALib.sqrtPriceAt(40e6, true)); // HYPE = $40
            _seedLiquidity();
        }
        _deployFramework();
        trader = new SATrader(PM, key);
        _deal(address(trader), 50_000_000e6);
        vm.deal(address(trader), 2_000_000 ether);
        _deployOurs();
        _report();
    }

    function _etch(address a, string memory name) internal {
        vm.etch(a, vm.parseBytes(vm.readFile(string.concat("test/fixtures/elysium/", name, ".runtime.hex"))));
    }

    function _dfCode(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/fixtures/delegation-framework-v1.3.0/", name, ".initcode.hex")));
    }

    function _create2(bytes memory initcode, address expected) internal {
        if (expected.code.length != 0) return;
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(GATOR, initcode));
        require(ok, "create2 failed");
        assertEq(address(bytes20(ret)), expected, "not the canonical address");
        assertGt(expected.code.length, 0);
    }

    function _deployFramework() internal {
        bytes memory dmArgs = abi.encode(DM_OWNER);
        _create2(abi.encodePacked(_dfCode("DelegationManager"), dmArgs), DM_ADDR);
        bytes memory gatorArgs = abi.encode(DM_ADDR, ENTRYPOINT);
        _create2(abi.encodePacked(_dfCode("EIP7702StatelessDeleGator"), gatorArgs), EIP7702_IMPL);
        _create2(_dfCode("TimestampEnforcer"), TIMESTAMP_ENFORCER);
        // SCL is linked into HybridDeleGator; forge scripts deploy linked libraries through CREATE2 with salt 0
        if (SCL_LIB.code.length == 0) {
            (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), _dfCode("SCL_RIP7212")));
            require(ok);
            assertEq(address(bytes20(ret)), SCL_LIB);
        }
        _create2(abi.encodePacked(_dfCode("HybridDeleGator.linked"), gatorArgs), HYBRID_IMPL);
        _create2(_dfCode("SimpleFactory"), SIMPLE_FACTORY);
    }

    function defaultParams() internal pure returns (LPManagerModule.Params memory) {
        return LPManagerModule.Params({
            feeBps: 1500,
            hedgeCapBps: 3500,
            poolBandBps: 150,
            maxSlippageBps: 150,
            hedgeStepBps: 500,
            refDriftBps: 1000,
            swapTurnoverBps: 20000,
            feeInterval: 7 days,
            maxPriceAge: 3600
        });
    }

    function _deployOurs() internal {
        timelock = new VaultTimelock(2 days, operator, guardian);
        executor = new SwapExecutor(PM, PERMIT2, key);
        enforcer = new ElysiumCustodyEnforcer(DM_ADDR, POSM_ADDR, PERMIT2, address(executor), address(usdc), key);
        module = new LPManagerModule(_config(address(timelock), keeper, guardian));
        vm.prank(treasury);
        usdc.approve(address(module), type(uint256).max);
    }

    function _config(address owner_, address keeper_, address guardian_)
        internal
        view
        returns (LPManagerModule.Config memory)
    {
        return LPManagerModule.Config({
            delegationManager: DM,
            enforcer: address(enforcer),
            timestampEnforcer: TIMESTAMP_ENFORCER,
            hybridImpl: HYBRID_IMPL,
            eip7702Impl: EIP7702_IMPL,
            poolManager: PM,
            positionManager: POSM,
            permit2: PERMIT2,
            swapExecutor: address(executor),
            key: key,
            asset: usdc,
            hedgeTreasury: treasury,
            feeRecipient: feeTo,
            owner: owner_,
            keeper: keeper_,
            guardian: guardian_,
            params: defaultParams()
        });
    }

    function _deal(address who, uint256 amount) internal {
        if (forked) deal(address(usdc), who, amount);
        else MockUSDC(address(usdc)).mint(who, amount);
    }

    function _seedLiquidity() internal {
        _deal(lp, 5_000_000e6);
        vm.deal(lp, 200_000 ether);
        vm.startPrank(lp);
        usdc.approve(PERMIT2, type(uint256).max);
        IPermit2Approve(PERMIT2).approve(address(usdc), POSM_ADDR, type(uint160).max, type(uint48).max);
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        int24 tl = -887220;
        int24 tu = 887220;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 100_000 ether, 4_000_000e6
        );
        POSM.modifyLiquidities{value: 100_000 ether}(
            V4PositionMath.mintData(key, tl, tu, liq, 100_000 ether, 4_000_000e6, lp), block.timestamp
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ pool helpers
    function poolPrice() internal view returns (uint256) {
        return V4PositionMath.price(PM, key.toId(), true);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = PM.getSlot0(key.toId());
    }

    function _range(uint256 halfBps) internal view returns (int24 tl, int24 tu) {
        int24 t = _tick();
        int24 w = int24(int256(halfBps)); // ~1 bp per tick
        tl = ((t - w) / 60) * 60 - 60;
        tu = ((t + w) / 60) * 60 + 60;
    }

    /// Liquidity for the account's whole idle balance (minus a margin) in [tl, tu), and the amounts it needs.
    function _liqFor(address a, int24 tl, int24 tu, uint256 hype, uint256 usd)
        internal
        view
        returns (uint128 liq, uint128 m0, uint128 m1)
    {
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        if (hype > a.balance) hype = a.balance;
        uint256 ub = usdc.balanceOf(a);
        if (usd > ub) usd = ub;
        liq = LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), hype * 99 / 100, usd * 99 / 100
        );
        m0 = uint128(hype);
        m1 = uint128(usd);
    }

    /// Swap the pool to within `tol` of `target` price (asset raw per 1e18 base).
    function _moveTo(uint256 target) internal {
        for (uint256 i; i < 60; ++i) {
            uint256 p = poolPrice();
            uint256 d = p > target ? p - target : target - p;
            if (d * 10_000 <= target * 3) return;
            uint256 usd = d * 4_000_000 / p; // depth ~ $4M per 100% in the seeded replica
            if (forked) usd = d * 300_000 / p;
            if (usd < 50) usd = 50;
            if (p < target) trader.swap(false, usd * 1e6);
            else trader.swap(true, usd * 1e18 / (p / 1e6));
        }
    }

    function _volume(uint256 usd, uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            uint256 p = poolPrice();
            trader.swap(false, usd * 1e6);
            trader.swap(true, usd * 1e18 * 1e6 / p);
        }
    }

    function _report() internal {
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.reportPrice(p);
    }

    // ------------------------------------------------------------------ accounts and delegations
    function _proxyInitcode(address owner_) internal view returns (bytes memory) {
        bytes memory init = abi.encodeCall(
            IHybridDeleGator.initialize, (owner_, new string[](0), new uint256[](0), new uint256[](0))
        );
        return abi.encodePacked(_dfCode("ERC1967Proxy"), abi.encode(HYBRID_IMPL, init));
    }

    function _hybridAddress(address owner_) internal view returns (address) {
        return ISimpleFactory(SIMPLE_FACTORY).computeAddress(keccak256(_proxyInitcode(owner_)), ACCOUNT_SALT);
    }

    function _deployHybrid(address owner_) internal returns (address a) {
        a = _hybridAddress(owner_);
        if (a.code.length == 0) {
            vm.prank(relayer);
            assertEq(ISimpleFactory(SIMPLE_FACTORY).deploy(_proxyInitcode(owner_), ACCOUNT_SALT), a);
        }
        assertEq(IHybridDeleGator(a).owner(), owner_);
    }

    function _upgrade7702(uint256 pk) internal returns (address eoa) {
        eoa = vm.addr(pk);
        vm.signAndAttachDelegation(EIP7702_IMPL, pk);
        assertEq(eoa.code.length, 23);
    }

    function _terms(address module_) internal view returns (bytes memory) {
        return abi.encode(module_, treasury, feeTo);
    }

    function _delegation(address account, address delegate, bytes memory terms, uint256 until, uint256 salt)
        internal
        pure
        returns (Delegation memory d)
    {
        Caveat[] memory cs = new Caveat[](2);
        cs[0] = Caveat(address(0), terms, "");
        cs[1] = Caveat(TIMESTAMP_ENFORCER, abi.encodePacked(uint128(0), uint128(until)), "");
        d = Delegation(delegate, account, DelegationFramework.ROOT_AUTHORITY, cs, salt, "");
    }

    function _sign(Delegation memory d, uint256 pk) internal view returns (Delegation memory) {
        bytes32 h = DM.getDelegationHash(d);
        assertEq(h, DelegationFramework.hash(d));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DM.getDomainHash(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        d.signature = abi.encodePacked(r, s, v);
        return d;
    }

    /// Client-signed delegation account -> module with the custody caveat and a 180-day expiry.
    function _moduleDelegation(address account, uint256 pk) internal view returns (Delegation memory d) {
        d = _delegation(account, address(module), _terms(address(module)), block.timestamp + 180 days, 1);
        d.caveats[0].enforcer = address(enforcer);
        d = _sign(d, pk);
    }

    function _permit(uint256 pk, address spender, uint256 amount, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner_ = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner_,
                spender,
                amount,
                IERC20Permit(address(usdc)).nonces(owner_),
                deadline
            )
        );
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", IERC20Permit(address(usdc)).DOMAIN_SEPARATOR(), structHash)));
    }

    /// Full onboarding: the relayer deploys the HybridDeleGator and calls `onboard` with the client's two signatures.
    function _onboardHybrid(uint256 pk, uint256 amount) internal returns (address a, Delegation memory d) {
        address owner_ = vm.addr(pk);
        _deal(owner_, amount);
        a = _deployHybrid(owner_);
        d = _moduleDelegation(a, pk);
        (uint8 v, bytes32 r, bytes32 s) = _permit(pk, address(module), amount, block.timestamp + 1 hours);
        vm.prank(relayer);
        module.onboard(d, amount, block.timestamp + 1 hours, v, r, s);
        assertEq(usdc.balanceOf(a), amount);
    }

    function _onboard7702(uint256 pk, uint256 amount) internal returns (address a, Delegation memory d) {
        a = _upgrade7702(pk);
        _deal(a, amount);
        d = _moduleDelegation(a, pk);
        vm.prank(relayer);
        module.register(d);
    }

    // ------------------------------------------------------------------ client exit
    function _exitExecs(address a, Delegation memory d, address to) internal view returns (Execution[] memory xs) {
        V4PositionMath.Position[] memory ps = module.positionsOf(a);
        xs = new Execution[](1 + ps.length);
        xs[0] = Execution(DM_ADDR, 0, abi.encodeCall(IDelegationManager.disableDelegation, (d)));
        for (uint256 i; i < ps.length; ++i) {
            xs[1 + i] = Execution(
                POSM_ADDR,
                0,
                abi.encodeCall(
                    IPositionManagerMin.modifyLiquidities,
                    (V4PositionMath.removeData(true, ps[i].tokenId, 0, 0, 0, address(0), address(usdc), to), block.timestamp)
                )
            );
        }
    }

    /// Hybrid exit: ONE transaction from the client EOA (EntryPoint.handleOps with a zero-fee userOp the EOA signed as
    /// EIP-712 typed data): revoke the delegation and burn every position into `to`.
    function _exitHybrid(uint256 pk, address a, Delegation memory d, address to) internal {
        bytes memory callData =
            abi.encodeCall(IDeleGatorCore.execute, (DelegationFramework.BATCH_DEFAULT, abi.encode(_exitExecs(a, d, to))));
        PackedUserOperation memory op = PackedUserOperation({
            sender: a,
            nonce: IEntryPointV07(ENTRYPOINT).getNonce(a, 0),
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32((uint256(300_000) << 128) | uint256(2_000_000)),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
        bytes32 digest = IDeleGatorUserOp(a).getPackedUserOperationTypedDataHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        op.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        address eoa = vm.addr(pk);
        vm.prank(eoa, eoa);
        IEntryPointV07(ENTRYPOINT).handleOps(ops, payable(eoa));
    }

    /// 7702 exit: ONE transaction from the EOA to itself (execute is onlyEntryPointOrSelf).
    function _exit7702(address eoa, Delegation memory d, address to) internal {
        vm.prank(eoa, eoa);
        IDeleGatorCore(eoa).execute(DelegationFramework.BATCH_DEFAULT, abi.encode(_exitExecs(eoa, d, to)));
    }

    // ------------------------------------------------------------------ keeper flows
    function _mintAll(address a) internal returns (uint256 id) {
        (int24 tl, int24 tu) = _range(300);
        (uint128 liq, uint128 m0, uint128 m1) = _liqFor(a, tl, tu, a.balance, usdc.balanceOf(a));
        uint256 p = poolPrice();
        vm.prank(keeper);
        id = module.mintPosition(a, tl, tu, liq, m0, m1, p);
    }

    /// Buy HYPE with `usd` of the account's USDC.
    function _buyBase(address a, uint256 usd) internal {
        uint256 p = poolPrice();
        vm.prank(keeper);
        module.swap(a, false, usd, p);
    }
}
