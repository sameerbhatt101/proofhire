// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFeeRegistry} from "./abstract/IFeeRegistry.sol";
import {ICoreFeeProvider} from "./abstract/ICoreFeeProvider.sol";
import {CommonErrors} from "./error/CommonErrors.sol";

/// @title FeeRegistry
/// @notice IFeeRegistry implementation backed by a core-fee provider — in this
///         version the Creditcoin precompile: every read is forwarded to the
///         runtime's `get_core_fee`, so fee policy is managed natively in the
///         runtime rather than in contract storage. The Outbox only depends on
///         IFeeRegistry, so future versions (e.g. a storage-based registry) can
///         be swapped in via `Outbox.setFeeRegistry` without touching the Outbox.
contract FeeRegistry is IFeeRegistry {
    /// @notice The core-fee provider this registry reads from.
    ICoreFeeProvider public immutable coreFeeProvider;

    constructor(address provider) {
        if (provider == address(0)) revert CommonErrors.ZeroAddress();
        coreFeeProvider = ICoreFeeProvider(provider);
    }

    /// @inheritdoc IFeeRegistry
    function coreFee(uint32 chainKey) external view override returns (uint256) {
        return coreFeeProvider.get_core_fee(chainKey);
    }
}
