// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOutbox} from "./IOutbox.sol";
import {BlockProverTypes} from "../common/BlockProverTypes.sol";

/// @title IRelayerContractLite
/// @notice Minimal fee-collection and quote-validation layer of the cross-chain
///         messaging system.
///
/// @dev Differences from IRelayerContract:
///      - No tips: the delivery reward is exactly the relay fee.
///      - Off-chain Quoter Service only: quotes are validated against a
///        whitelist of Quoter EOAs managed directly on this contract; no
///        on-chain ASCRelayingQuoter is consulted (no relay-fee floor check).
///      - ERC-20 approve paths only: no EIP-3009 variants and no
///        trusted-publisher route.
///
///      The live coreFee is still read from the Outbox, with the signed
///      quote's coreFee acting as the payer-authorized maximum.
interface IRelayerContractLite {
    /// @notice Source Outbox used to publish and validate stored messages.
    function outbox() external view returns (IOutbox);

    /// @notice Whether `quoter` is an EOA whose quote signatures are accepted.
    function authorizedQuoters(address quoter) external view returns (bool);

    /// @notice Owner-managed whitelist of off-chain Quoter Service EOAs.
    function setAuthorizedQuoter(address quoter, bool authorized) external;

    /// @notice Combined route: publish message + collect all fees in one call.
    ///         Requires prior ATTEST.approve(RelayerContractLite,
    ///         coreFee + relayFee + acknowledgmentPrice). The acknowledgment fee
    ///         is the Quoter-signed quote's acknowledgmentPrice — the payer
    ///         accepts it through that approval; there is no caller-chosen
    ///         amount. There is no canAck argument: a nonzero
    ///         acknowledgmentPrice in the signed quote IS the acknowledgment
    ///         request (the Outbox derives the flag). Internally calls
    ///         Outbox.publishMessageFrom(msg.sender, ackFee, payload) so
    ///         the message is attributed to the original caller. coreFee is
    ///         forwarded to AttestorVault; the ack fee is routed to the
    ///         AcknowledgmentValidator; the relay reward goes to RelayerFeeVault.
    function publishAndCollectRelayerFee(
        bytes calldata payload,
        bytes calldata signedQuote
    ) external payable returns (bytes32 messageId);

    /// @notice Separate path: verify the Quoter EOA signature, pull the relay
    ///         reward into RelayerFeeVault, and route the quoted
    ///         acknowledgmentPrice through the Outbox. Requires prior
    ///         ATTEST.approve(RelayerContractLite, relayFee + acknowledgmentPrice).
    ///         Outbox.publishMessage MUST be called before this — messageId is
    ///         the value returned by that call (coreFee was paid there; the
    ///         canAck flag is fee-free). A nonzero acknowledgmentPrice here
    ///         is the message's first ack funding, and it also upgrades a
    ///         message published without canAck; reverts if the message is
    ///         already acknowledged.
    function collectRelayerFee(
        bytes32 messageId,
        bytes calldata signedQuote
    ) external payable;

    /// @notice Delivery settlement: verifies the delivery proof, decodes the
    ///         destination event, binds it to the funded route, and instructs the
    ///         backing RelayerFeeVault to settle the fee components (the vault
    ///         holds funds only). Permissionless; every settled fee pays the
    ///         relayer proven by the destination Inbox event, never the caller.
    function claimDelivery(
        bytes32 messageId,
        bytes32 chainKey,
        uint64  blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external;

    /// @notice Relayer signals that the committed gasLimit is insufficient
    ///         (gasLimit < eth_estimateGas on destination). Pure signal — emits
    ///         TopUpRequested with msg.sender as the requesting relayer after
    ///         checking route liveness against the backing vault. Relayer MUST
    ///         NOT submit the tx until the user tops up.
    function requestTopUp(bytes32 messageId, uint256 additionalGasNeeded) external;

    /// @notice Payer reclaims every fee component still unsettled after the
    ///         delivery deadline (relay reward while delivery is unclaimed,
    ///         ack fee while no acknowledgment has been proven).
    function requestRefund(bytes32 messageId) external;

    /// @notice Payer-only: set once where unused top-up refunds are paid
    ///         (defaults to payer).
    function setFeeRefundRecipient(bytes32 messageId, address recipient) external;

    /// @notice Payer increases the committed gasLimit and deposits the fee delta
    ///         (ERC-20 only, matching this variant's scope). Requires a
    ///         Quoter-signed topUpQuote and prior
    ///         ATTEST.approve(RelayerContractLite, additionalATTEST); the delta is
    ///         forwarded into the backing RelayerFeeVault and GasLimitUpdated is
    ///         emitted here.
    function topUpGasLimit(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) external payable;

    /// @notice Emitted when a payer's gas-limit top-up is applied in the backing vault.
    event GasLimitUpdated(bytes32 indexed messageId, uint256 oldGasLimit,
                          uint256 newGasLimit, uint256 additionalFee);

    /// @notice Returns the EVM chain ID configured for a quote/Outbox route key.
    ///         Resolved at deposit time and snapshotted per message in the vault.
    function destinationEvmChainIds(
        uint32 destinationChain
    ) external view returns (uint32 destinationEvmChainId);

    /// @notice Configures the EVM chain ID represented by a quote/Outbox route key.
    function setDestinationEvmChainId(
        uint32 destinationChain,
        uint32 destinationEvmChainId
    ) external;

    /// @notice Activates a RelayerFeeVault for new deposits. Owner-only; the vault
    ///         must be bound back to this contract. Swappable at any time —
    ///         in-flight routes keep settling against the vault recorded for them
    ///         at deposit time (vaultOf).
    function setRelayerFeeVault(address newVault) external;

    /// @notice Emitted when the active vault for new deposits changes.
    event RelayerFeeVaultSet(address indexed oldVault, address indexed newVault);

    event DestinationEvmChainIdSet(
        uint32 indexed destinationChain,
        uint32 indexed destinationEvmChainId
    );

    enum FailureReason { OutOfGas, Reverted }

    /// @param relayer   Proven deliverer decoded from the Inbox event — receives the relay fee.
    /// @param submitter Caller who submitted the claim transaction (often the same account).
    event DeliveryClaimed(bytes32 indexed messageId, address indexed relayer,
                          address indexed submitter, uint256 relayFee, uint256 tip);
    event DeliveryFailed(bytes32 indexed messageId, FailureReason reason);
    event UnusedTopUpRefunded(bytes32 indexed messageId, address indexed user, uint256 amount);
    event RefundIssued(bytes32 indexed messageId, address indexed user, uint256 amount);
    event TopUpRequested(bytes32 indexed messageId, address indexed relayer,
                         uint256 additionalGasNeeded);

    event FeeCollected(
        bytes32 indexed messageId,
        address indexed payer,
        uint256 relayFee,
        uint256 ackFee,
        uint256 gasLimit,
        uint32  destinationChain
    );

    event AuthorizedQuoterSet(address indexed quoter, bool authorized);
    event FeeRefundRecipientSet(bytes32 indexed messageId, address indexed recipient);
}
