// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFeeRegistry
/// @notice Read-side abstraction the Outbox depends on for coreFee pricing.
///         The Outbox never manages fee values itself — it is injected with a
///         registry address and pulls the fee for its chainKey at publish time.
interface IFeeRegistry {
    /// @notice Core fee in ATTEST wei charged when publishing a message to `chainKey`.
    /// @param chainKey The ASC client-chain key of the querying Outbox.
    function coreFee(uint32 chainKey) external view returns (uint256);
}
