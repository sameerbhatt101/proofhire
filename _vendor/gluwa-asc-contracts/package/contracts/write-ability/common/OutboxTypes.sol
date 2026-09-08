// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library OutboxTypes {
    struct Message {
        address emitter;        // UC which call publishMessage in Outbox
        uint64  sequence;       // sequence to prevent duplication however, can be used to track ordering
        uint64  timestamp;      // block.timestamp at published time
        bool    canAck;    // requires validator ack
        bool    acknowledged;   // set by validator
        bytes32 payloadHash;    // keccak256(payload)
    }

    /// @notice Scalar / config slice of Outbox `_state` (mappings are not included;
    ///         use per-key getters such as `getMessage` / `isTrustedForwarder`).
    struct StateView {
        uint32 chainKey;
        address validator;
        uint128 defaultRateLimit;
        uint256 evmChainId;
        address attestorVault;
        address attestToken;
        address feeRegistry;
    }

    /// @notice Deterministic messageId derivation
    function computeMessageId(
        address outbox,
        address emitter,
        uint64 sequence,
        bytes32 payloadHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(outbox, emitter, sequence, payloadHash)
        );
    }
}
