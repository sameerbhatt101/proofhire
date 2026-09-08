// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IERC3009
/// @notice Minimal EIP-3009 interface (Transfer with Authorization).
///         Allows token transfers via off-chain signed authorizations, eliminating
///         the need for a prior ERC-20 approve transaction.
interface IERC3009 {
    /// @notice Submit a signed authorization to transfer tokens from `from` to `to`.
    ///         The caller may be anyone — the authorization is validated by the signature.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Submit a signed authorization to transfer tokens to msg.sender (the caller).
    ///         Requires msg.sender == to — only the designated recipient may execute this.
    ///         Used by vaults (AttestorVault, RelayerFeeVault) to pull funds from payers
    ///         without requiring a prior approve.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external;
}
