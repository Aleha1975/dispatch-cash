// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


/// @notice Minimal Uniswap v4 PositionManager surface used by the vault (matches the deployed periphery ABI).
interface IPositionManagerMin {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

/// @notice Minimal Permit2 AllowanceTransfer surface.
interface IPermit2Min {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice WHYPE / WETH9 style wrapper.
interface IWrappedNative {
    function withdraw(uint256) external;
    function deposit() external payable;
}
