// SPDX-License-Identifier: MIT
pragma solidity >0.8.0 <0.9.0;

library OutboxErrors {
    error NotValidator();
    error AlreadyInitialized();

    error MessageNotFound(bytes32 messageId);
    error MessageCannotBeAcknowledged(bytes32 messageId);
    error MessageAlreadyAcknowledged(bytes32 messageId);

    error NotTrustedForwarder(address caller);
    error ForwarderNotApprovedByEmitter(address emitter, address forwarder);
    error InvalidChainKey(uint32 chainKey);
    error InvalidRateLimitPolicy(uint128 policy);
}
