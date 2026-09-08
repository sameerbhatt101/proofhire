// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Attestor registry interface
/// @notice Single source of truth for attestor-set membership. Any contract that
///         needs attestor validation (AttestorVault settlement, validators, future
///         components) calls `isAttestor` here instead of keeping its own copy of
///         the set. `EOAValidator.isAttestor` is call-compatible with the membership
///         check, so a deployment can also point consumers directly at it.
interface IAttestorRegistry {
    /// @notice Whether `attestor` is a member of the current attestor set.
    function isAttestor(address attestor) external view returns (bool);

    /// @notice The current attestor set. Read off-chain and by batch consumers.
    function attestors() external view returns (address[] memory);

    /// @notice Number of attestors in the current set.
    function getAttestorCount() external view returns (uint256);

    /// @notice Whether `updater` may mutate the set alongside the owner.
    function isUpdater(address updater) external view returns (bool);

    /// @notice Authorize or revoke a contract (e.g. the EOAValidator, for its
    ///         attestor-voted set updates) to mutate the set. Owner only.
    function setUpdater(address updater, bool authorized) external;

    /// @notice Add a single attestor. Owner or authorized updater only.
    function addAttestor(address attestor) external;

    /// @notice Remove a single attestor. Owner or authorized updater only.
    function removeAttestor(address attestor) external;

    /// @notice Replace the entire attestor set. Owner or authorized updater only.
    function updateAttestorSet(address[] calldata newAttestors) external;

    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);
    event AttestorSetReplaced(address[] newAttestors);
    event UpdaterSet(address indexed updater, bool authorized);

    /// @notice Address is already a member of the attestor set.
    error AttestorAlreadyRegistered(address attestor);

    /// @notice Address is not a member of the attestor set.
    error AttestorNotFound(address attestor);

    /// @notice Caller is neither the owner nor an authorized updater.
    error NotRegistryUpdater(address caller);
}
