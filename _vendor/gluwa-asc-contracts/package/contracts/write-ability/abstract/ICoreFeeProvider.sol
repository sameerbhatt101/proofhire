// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICoreFeeProvider
/// @notice Source the FeeRegistry reads the core fee from. In this version the
///         provider is the Creditcoin native precompile, so fee policy lives in
///         the runtime — contracts only read it through this call.
/// @dev The runtime must match the exact signature `get_core_fee(uint32)`
///      (selector 0x5b023376); the precompile has no contract bytecode
///      (`extcodesize == 0`) but still answers static calls.
interface ICoreFeeProvider {
    /// @notice Core fee in ATTEST wei for publishing a message to `chainKey`.
    function get_core_fee(uint32 chainKey) external view returns (uint256);
}
