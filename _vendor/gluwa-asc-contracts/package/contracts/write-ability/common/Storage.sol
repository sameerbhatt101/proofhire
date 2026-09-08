// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OutboxTypes} from "./OutboxTypes.sol";
import {RateLimitLib} from "./RateLimitLib.sol";

/// @title Outbox Storage Layout
/// @notice Persistent state for Outbox Core, upgrade-safe.
/// @dev DO NOT REORDER STORAGE. Append new fields only.
contract Storage {
    /// @dev Primary storage bucket for Outbox.
    struct OutboxState {
        uint32 chainKey;
        address validator;
        /**
         * @notice Rate-limit policy encoding and semantics
         *
         * The rate-limit policy is encoded into a single `uint128` value:
         *
         *   ┌────────────────────────────────────────────┐
         *   │ high 64 bits        │ low 64 bits           │
         *   │ maxRequests         │ windowSeconds         │
         *   └────────────────────────────────────────────┘
         *
         * Semantics:
         * - `windowSeconds` defines the duration of a sliding time window
         * - `maxRequests` defines the total number of allowed requests within that window
         * - The window resets when `windowSeconds` elapses since the first request in the window
         * - If either value is zero, rate limiting is disabled
         *
         * Example:
         * - policy = encode(10_000, 86_400)
         *   → allows 10,000 requests per 24-hour sliding window
         */
        uint128 defaultRateLimit;
        uint256 evmChainId;
        /// @notice Sequence numbers per Universal Contract
        mapping(address => uint64) ucSequences;
        mapping(bytes32 => OutboxTypes.Message) messages;
        mapping(address => RateLimitLib.RateBucket) rateBuckets;
        // Fee integration — added after initial fields to preserve layout
        address attestorVault;      // receives coreFee on publishMessage
        address attestToken;        // ATTEST ERC-20 / EIP-3009 token
        /// @notice FeeRegistry the Outbox pulls coreFee from at publish time (owner-set)
        address feeRegistry;
        // Trusted forwarders (e.g. RelayerContract) may call publishMessageFrom
        mapping(address => bool) trustedForwarders;
        // Per-emitter forwarder opt-in: emitter => forwarder => approved. A forwarder
        // may only attribute a message to an emitter that has approved it, so a
        // (self-)registered forwarder cannot forge messages for arbitrary emitters.
        mapping(address => mapping(address => bool)) approvedForwarders;
        uint256[50] __reserved;
    }

    /// @dev ERC-7201 namespaced storage slot:
    ///      keccak256(abi.encode(keccak256("ASC.outbox.storage") - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTBOX_STORAGE_LOCATION =
        0xab96e70160de0dc083b7f7505d7192c8db5b16070df1d645513a7957430b9700;

    /// @dev Accessor for OutboxState stored at the ERC-7201 namespaced slot.
    ///      Avoids collisions with Ownable._owner (slot 0) and Ownable2Step._pendingOwner (slot 1).
    function _state() internal pure returns (OutboxState storage s) {
        // ERC-7201 namespaced slot access has no non-assembly form.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := OUTBOX_STORAGE_LOCATION
        }
    }
}
