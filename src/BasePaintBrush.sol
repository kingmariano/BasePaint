// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title IBasePaintBrush
/// @notice Minimal interface for the BasePaint Brush NFT (ERC-721).
///         A Brush is the "access pass" required to paint on the BasePaint canvas.
///         Deployed at: 0xD68fe5b53e7E1AbeB5A4d0A6660667791f39263d (Base Mainnet)
interface IBasePaintBrush {
    /// @notice Returns the owner address of a given Brush token.
    /// @param tokenId  The ERC-721 token ID of the Brush.
    /// @return owner   Address currently holding this Brush.
    function ownerOf(uint256 tokenId) external view returns (address owner);
}
