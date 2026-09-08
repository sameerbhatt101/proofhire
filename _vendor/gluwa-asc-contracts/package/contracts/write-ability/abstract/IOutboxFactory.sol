// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IOutboxFactory
/// @notice Minimal interface for OutboxFactory contracts. All future versions must implement this.
interface IOutboxFactory {
    /// @notice The factory version (e.g. "1.0")
    function version() external view returns (string memory);

    /// @notice Emitted when a new Outbox contract is deployed
    event OutboxCreated(
        address indexed outbox,
        uint32 indexed chainKey,
        address indexed owner,
        address validator,
        string version
    );

    /// @notice Deploys an Outbox instance for a client chain via CREATE2.
    function deployOutbox(
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) external returns (address outbox);

    function computeOutboxAddress(
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) external view returns (address predicted);

    /// @notice Predicts deployment when `deployer` is the caller of deployOutbox.
    function computeOutboxAddressFor(
        address deployer,
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) external view returns (address predicted);
}
