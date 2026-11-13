// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LPVaultBase} from "../../src/LPVaultBase.sol";

/// 6-decimal USDC with EIP-2612 and a blacklist (to test failed push transfers).
contract MockUSDC is ERC20Permit {
    mapping(address => bool) public blocked;

    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blocked[to] && !blocked[from], "blocked");
        super._update(from, to, v);
    }
}

/// Holds the "LP" inventory of MockLPVault; only the vault moves it.
contract MockPool {
    address public immutable vault;
    IERC20 public immutable usdc;

    constructor(IERC20 u) {
        vault = msg.sender;
        usdc = u;
    }

    receive() external payable {}

    function give(uint256 nativeAmt, uint256 usdcAmt) external {
        require(msg.sender == vault, "only vault");
        if (usdcAmt != 0) usdc.transfer(vault, usdcAmt);
        if (nativeAmt != 0) {
            (bool ok,) = vault.call{value: nativeAmt}("");
            require(ok);
        }
    }
}

/// LPVaultBase with a fake venue: positions are balances parked in MockPool, the pool price is set by the test.
contract MockLPVault is LPVaultBase {
    MockPool public pool;
    uint256 public mockPrice;
    uint256 public lpBase;
    uint256 public lpAsset;

    constructor(BaseConfig memory c, uint256 price0) LPVaultBase(c) {
        pool = new MockPool(c.asset);
        mockPrice = price0;
    }

    // ---- test controls (not keeper powers)
    function setPoolPrice(uint256 p) external {
        mockPrice = p;
    }

    /// Simulate LP PnL already sitting in the pool (fees or IL), funded by the test.
    function simulateLp(uint256 newBase, uint256 newAsset) external {
        lpBase = newBase;
        lpAsset = newAsset;
    }

    // ---- venue
    function _poolPrice() internal view override returns (uint256) {
        return mockPrice;
    }

    function _positionAmounts() internal view override returns (uint256, uint256) {
        return (lpBase, lpAsset);
    }

    function _positionCount() internal view override returns (uint256) {
        return lpBase + lpAsset == 0 ? 0 : 1;
    }

    function _unwindAll() internal override {
        (uint256 b, uint256 a) = (lpBase, lpAsset);
        lpBase = 0;
        lpAsset = 0;
        pool.give(b, a);
    }

    // ---- keeper actions mirroring the v4 vault's guards
    function addLiquidity(uint256 baseAmt, uint256 assetAmt, uint256 keeperPrice)
        external
        nonReentrant
        onlyKeeper
        whenNotPaused
        notEmergency
    {
        _checkKeeperPrice(keeperPrice);
        lpBase += baseAmt;
        lpAsset += assetAmt;
        if (assetAmt != 0) asset.transfer(address(pool), assetAmt);
        if (baseAmt != 0) {
            (bool ok,) = address(pool).call{value: baseAmt}("");
            require(ok);
        }
        _checkReserve();
    }

    function removeLiquidity(uint256 baseAmt, uint256 assetAmt) external nonReentrant onlyKeeper notEmergency {
        lpBase -= baseAmt;
        lpAsset -= assetAmt;
        pool.give(baseAmt, assetAmt);
    }

    /// Swap against MockPool inventory at the pool price minus 0.3%.
    function swap(bool sellBase, uint256 amountIn, uint256 keeperPrice)
        external
        nonReentrant
        onlyKeeper
        whenNotPaused
        notEmergency
        returns (uint256 out)
    {
        if (amountIn == 0) revert ZeroAmount();
        _checkKeeperPrice(keeperPrice);
        uint256 fair = sellBase ? Math.mulDiv(amountIn, keeperPrice, WAD) : Math.mulDiv(amountIn, WAD, keeperPrice);
        _useTurnover(sellBase ? fair : amountIn);
        uint256 minOut = Math.mulDiv(fair, BPS - params.maxSlippageBps, BPS);
        uint256 poolOut = sellBase ? Math.mulDiv(amountIn, mockPrice, WAD) : Math.mulDiv(amountIn, WAD, mockPrice);
        out = poolOut * 997 / 1000;
        require(out >= minOut, "min out");
        if (sellBase) {
            (bool ok,) = address(pool).call{value: amountIn}("");
            require(ok);
            pool.give(0, out);
        } else {
            asset.transfer(address(pool), amountIn);
            pool.give(out, 0);
        }
        _checkReserve();
    }
}
