// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OutboxTypes} from "../common/OutboxTypes.sol";

/// @title Outbox interface (per client chain)
/// @notice Deployed on Creditcoin L1, one instance per client chain
interface IOutbox {
    /// @notice Emitted when a message is published
    event MessagePublished(
        bytes32 indexed messageId,
        bytes32 indexed emitterAddress, // Universal Contract address as bytes32 to ensure consistency across chains
        bool canAck,
        bytes payload
    );

    /// @notice Emitted when a message is acknowledged by the validator
    event MessageAcknowledged(bytes32 indexed messageId);

    /// @notice Emitted when a late ack-fee deposit (routeAckFee) upgrades a
    ///         message published without an acknowledgment request to
    ///         canAck = true — its MessagePublished event carried false.
    event MessageAckEnabled(bytes32 indexed messageId);

    /// @notice Emitted when validator is updated
    event ValidatorChanged(
        address indexed oldValidator,
        address indexed newValidator
    );

    /// @notice Emitted when a trusted forwarder is added or removed.
    /// @dev Trusted forwarders may call publishMessageFrom on behalf of users.
    event TrustedForwarderSet(address indexed forwarder, bool indexed trusted);

    /// @notice Emitted when an emitter approves or revokes a forwarder for itself.
    event ForwarderApprovalSet(
        address indexed emitter,
        address indexed forwarder,
        bool approved
    );

    /// @notice Emitted when the owner swaps the FeeRegistry the Outbox pulls
    ///         coreFee from.
    event FeeRegistryUpdated(address indexed oldFeeRegistry, address indexed newFeeRegistry);

    /// @notice Returns the ASC client-chain key configured for this Outbox.
    function chainKey() external view returns (uint32);

    /// @notice Core fee in ATTEST wei charged when publishing a message.
    /// @dev Pulled from the injected FeeRegistry for this Outbox's chainKey;
    ///      fee values are managed on the registry, not on the Outbox.
    function coreFee() external view returns (uint256);

    /// @notice The FeeRegistry this Outbox pulls coreFee from.
    function feeRegistry() external view returns (address);

    /// @notice Swaps the FeeRegistry. Owner-only.
    function setFeeRegistry(address newFeeRegistry) external;

    function defaultRateLimit() external view returns (uint128);

    function getSequence(address dApp) external view returns (uint64);

    /// @notice Returns the validator contract trusted to call acknowledge functions
    function validator() external view returns (address);

    /// @notice Returns the AttestorVault that custodies core fees for this Outbox.
    function attestorVault() external view returns (address);

    /// @notice Returns the scalar / config slice of Outbox `_state`.
    /// @dev Mappings (messages, sequences, forwarders, rate buckets) are not
    ///      included; use the dedicated per-key getters for those.
    function getState() external view returns (OutboxTypes.StateView memory);

    /// @notice Returns the administrative owner of this outbox
    function owner() external view returns (address);

    /// @notice Returns stored metadata for a published message
    /// @dev Only messages that are stored (e.g. canAck = true)
    /// @param messageId The message identifier
    function getMessage(
        bytes32 messageId
    ) external view returns (OutboxTypes.Message memory);

    /// @notice ERC-20 path: requires prior ATTEST.approve(Outbox, coreFee).
    ///         Charges the registry coreFee — no signed quote required. Takes no
    ///         ackFee: the acknowledgment fee is priced by the Quoter/Relayer
    ///         pair and only enters through the relayer routes. canAck may
    ///         be set fee-free — the publisher can self-submit the ack proof or
    ///         fund the incentive later via collectRelayerFee (whose routeAckFee
    ///         deposit also upgrades a message published with false).
    /// @param canAck Whether this message requests acknowledgment (no fee
    ///        attached at publish)
    /// @param payload The message payload (chain-specific format)
    /// @return messageId The unique identifier for this message
    function publishMessage(
        bool canAck,
        bytes calldata payload
    ) external returns (bytes32 messageId);

    /// @notice Routes a message's core fee to the AttestorVault on behalf of a
    ///         trusted forwarder (e.g. RelayerContract), which transfers the
    ///         ATTEST to the Outbox first.
    function routeCoreFee(bytes32 messageId, address payer, uint256 coreFeeAmount) external;

    /// @notice Routes a message's acknowledgment fee to this Outbox's validator
    ///         for custody until a proven acknowledgment claims it.
    ///         Trusted-forwarder only; ATTEST transferred to the Outbox first.
    ///         A nonzero fee for a message published without an acknowledgment
    ///         request upgrades it to canAck = true (MessageAckEnabled);
    ///         deposits for already-acknowledged messages revert.
    function routeAckFee(bytes32 messageId, address payer, uint256 ackFee) external;

    /// @notice EIP-3009 path: no prior approve needed.
    ///         Vault calls receiveWithAuthorization on ATTEST to pull coreFee from payer.
    ///         authorization encodes { validAfter, validBefore, nonce, v, r, s } signed
    ///         by the payer over (from=payer, to=attestorVault, value=coreFee, ...).
    ///         Like publishMessage, carries no ack fee (the acknowledgment fee is
    ///         Quoter-priced): canAck may be set fee-free and funded later
    ///         through the relayer service.
    /// @param canAck Whether this message requests acknowledgment (no fee
    ///        attached at publish)
    /// @param payload The message payload (chain-specific format)
    /// @return messageId The unique identifier for this message
    function publishMessageWithAuthorization(
        bool canAck,
        bytes calldata payload,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external returns (bytes32 messageId);

    /// @notice Trusted-forwarder publish: emits a message attributed to `emitter`
    ///         rather than msg.sender. Only callable by a registered trusted forwarder
    ///         (e.g. RelayerContract during publishAndCollectRelayerFee) that `emitter`
    ///         has additionally approved for itself via approveForwarder — a trusted
    ///         forwarder alone cannot attribute messages to emitters that never opted in.
    /// @param emitter The original user the message should be attributed to
    /// @param ackFee Acknowledgment incentive in ATTEST wei — derives the message's
    ///        canAck flag (ackFee > 0). Custody happens separately via
    ///        routeAckFee in the same atomic workflow; no tokens move here
    /// @param payload The message payload (chain-specific format)
    /// @return messageId The unique identifier for this message
    function publishMessageFrom(
        address emitter,
        uint256 ackFee,
        bytes calldata payload
    ) external returns (bytes32 messageId);

    /// @notice Whether `forwarder` is allowed to call publishMessageFrom.
    function isTrustedForwarder(address forwarder) external view returns (bool);

    /// @notice Add or remove a trusted forwarder. Owner-only.
    function setTrustedForwarder(address forwarder, bool trusted) external;

    /// @notice Approve or revoke `forwarder` to publish messages attributed to the
    ///         caller. Required in addition to the owner-managed trusted-forwarder
    ///         registration before publishMessageFrom(msg.sender-as-emitter) succeeds.
    function approveForwarder(address forwarder, bool approved) external;

    /// @notice Whether `emitter` has approved `forwarder` to publish on its behalf.
    function isForwarderApproved(
        address emitter,
        address forwarder
    ) external view returns (bool);

    /// @notice Acknowledges a message (only callable by validator)
    /// @param messageId The message identifier
    function acknowledgeMessage(bytes32 messageId) external;

    /// @notice Batch version of acknowledgeMessage (only callable by validator)
    /// @param messageIds Array of message identifiers
    function batchAcknowledgeMessages(bytes32[] calldata messageIds) external;

    /// @notice Returns whether a message has been acknowledged
    /// @param messageId The message identifier
    /// @return acknowledged True if message has been acknowledged
    function isAcknowledged(
        bytes32 messageId
    ) external view returns (bool acknowledged);

    /// @notice Returns whether a message was published with canAck = true
    /// @param messageId The message identifier
    /// @return canAck True if this message is tracked in storage
    function messageCanAck(
        bytes32 messageId
    ) external view returns (bool canAck);

    /// @notice Sets the validator contract that can acknowledge messages
    /// @param newValidator The new validator contract address
    /// @dev Expected to be owner-only in implementation
    function setValidator(address newValidator) external;
}
