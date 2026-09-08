// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOutbox} from "./IOutbox.sol";
import {BlockProverTypes} from "../common/BlockProverTypes.sol";

/// @title IRelayerContract
/// @notice Fee-collection and quote-validation layer of the cross-chain messaging system.
///
/// @dev Architecture summary:
///      Main route — publishAndCollectRelayerFee:
///        Single call pulls coreFee + relayFee + ackFee + tip, deposits the core fee
///        into AttestorVault and the combined delivery reward plus tip into
///        RelayerFeeVault, and publishes the message through the Outbox via
///        publishMessageFrom so it is attributed to the caller.
///
///      Optional separate path:
///        Caller first calls Outbox.publishMessage (pays coreFee only;
///        canAck may be set fee-free), then calls collectRelayerFee (pays
///        relayFee + quoted acknowledgmentPrice + tip) passing the returned
///        messageId. A nonzero quoted acknowledgmentPrice is the message's
///        first ack funding and also upgrades one published without canAck.
///
///      No delivery payee is committed at fee-collection time. The combined relay
///      and acknowledgment reward, plus any eligible tip, is released to the
///      relayer identified by a valid delivery proof.
interface IRelayerContract {
    /// @notice Source Outbox used to publish and validate stored messages.
    function outbox() external view returns (IOutbox);

    /// @notice Whether a dApp may publish through this contract for a payer who
    ///         supplied a scoped EIP-3009 authorization.
    function trustedPublishers(address publisher) external view returns (bool);

    /// @notice Owner-managed gate for payer-on-behalf publication.
    function setTrustedPublisher(address publisher, bool trusted) external;

    /// @notice Domain-separated nonce required in a trusted-publisher EIP-3009
    ///         authorization. The quote digest already binds payload, emitter,
    ///         fees, acknowledgment choice, route, deadlines, and this contract.
    function publisherAuthorizationNonce(
        address payer,
        address publisher,
        bytes32 quoteDigest
    ) external view returns (bytes32);

    /// @notice Combined (ERC-20 path, main route): publish message + collect all fees in one call.
    ///         Requires prior ATTEST.approve(RelayerContract,
    ///         coreFee + relayFee + acknowledgmentPrice + tip). The acknowledgment
    ///         fee is the Quoter-signed quote's acknowledgmentPrice — the payer
    ///         accepts it through that approval; there is no caller-chosen amount.
    ///         There is no canAck argument: a nonzero acknowledgmentPrice in the
    ///         signed quote IS the acknowledgment request (the Outbox derives the flag).
    ///         Internally calls Outbox.publishMessageFrom(msg.sender, ackFee, payload)
    ///         so the message is attributed to the original caller, not RelayerContract.
    ///         coreFee is forwarded to AttestorVault; the ack fee is routed to the
    ///         AcknowledgmentValidator; the relay reward plus tip goes to RelayerFeeVault.
    function publishAndCollectRelayerFee(
        bytes calldata payload,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry
    ) external payable returns (bytes32 messageId);

    /// @notice Combined (EIP-3009 path, main route): same as publishAndCollectRelayerFee
    ///         but uses a single EIP-3009 authorization for the maximum total amount.
    ///         No prior approve needed.
    ///         authorization encodes { validAfter, validBefore, nonce, v, r, s } signed
    ///         by the payer over (from=payer, to=relayerContract,
    ///         value=quotedCoreFee+relayFee+acknowledgmentPrice+tip, validAfter,
    ///         validBefore, nonce).
    ///         The contract deposits the live core fee and refunds the difference when
    ///         the quoted core-fee maximum is higher.
    function publishAndCollectRelayerFeeWithAuthorization(
        bytes calldata payload,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry,
        bytes calldata authorization
    ) external returns (bytes32 messageId);

    /// @notice Trusted-dApp path: the caller remains the Outbox emitter while
    ///         `payer` funds the quote through a scoped EIP-3009 authorization.
    ///         `feeAuthorization` ABI-encodes `(bytes signedQuote, bytes
    ///         authorization)`, where authorization encodes
    ///         `(validAfter, validBefore, nonce, v, r, s)`. Its value is the
    ///         quoted maximum core fee + relay fee + acknowledgment fee and its
    ///         nonce must equal publisherAuthorizationNonce(...).
    function publishAndCollectRelayerFeeFor(
        address payer,
        bytes calldata payload,
        bytes calldata feeAuthorization
    ) external returns (bytes32 messageId);

    /// @notice Phase 1b (ERC-20 path, optional separate path): verify the Quoter EOA
    ///         signature, pull relayFee + tip into RelayerFeeVault, and route the
    ///         quoted acknowledgmentPrice through the Outbox. Requires prior
    ///         ATTEST.approve(RelayerContract, relayFee + acknowledgmentPrice + tip).
    ///         Outbox.publishMessage MUST be called before this — messageId is the value
    ///         returned by that call. Direct publishes carry no ack fee (the
    ///         canAck flag is fee-free), so a nonzero acknowledgmentPrice
    ///         here is the message's first ack funding, and it also upgrades a
    ///         message published without canAck; reverts if the message is
    ///         already acknowledged.
    function collectRelayerFee(
        bytes32 messageId,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry
    ) external payable;

    /// @notice Phase 1b (EIP-3009 path, optional separate path): same as collectRelayerFee
    ///         but uses EIP-3009 receiveWithAuthorization instead of transferFrom.
    ///         No prior approve needed.
    function collectRelayerFeeWithAuthorization(
        bytes32 messageId,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;

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
    ///         delivery deadline (relay reward + tip while delivery is unclaimed,
    ///         ack fee while no acknowledgment has been proven).
    function requestRefund(bytes32 messageId) external;

    /// @notice Payer-only: set once where unused top-up / tip refunds are paid
    ///         (defaults to payer). Lets a publisher contract redirect
    ///         claimDelivery refunds to the end user.
    function setFeeRefundRecipient(bytes32 messageId, address recipient) external;

    /// @notice Payer adds more tip to an in-flight message to incentivise earlier
    ///         delivery (ERC-20 path). newTipExpiry must extend the current
    ///         expiry, stay after the delivery deadline, and be at least
    ///         MIN_TIP_WINDOW away.
    function increaseTip(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry
    ) external payable;

    /// @notice EIP-3009 variant of increaseTip; the authorization is signed by
    ///         the payer to this contract.
    function increaseTipWithAuthorization(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;

    /// @notice Payer increases the committed gasLimit and deposits the fee delta
    ///         (ERC-20 path). Requires a Quoter-signed topUpQuote and prior
    ///         ATTEST.approve(RelayerContract, additionalATTEST); the delta is
    ///         forwarded into the backing RelayerFeeVault and GasLimitUpdated is
    ///         emitted here.
    function topUpGasLimit(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) external payable;

    /// @notice EIP-3009 variant of topUpGasLimit. No prior approval needed; the
    ///         authorization is signed by the payer to this contract.
    function topUpGasLimitWithAuthorization(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;

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

    event FeeCollected(
        bytes32 indexed messageId,
        address indexed payer,
        uint256 relayFee,
        uint256 ackFee,
        uint256 priorityTip,
        uint256 tipExpiry,
        uint256 gasLimit,
        uint32 destinationChain
    );

    /// @notice Emitted when a combined EIP-3009 payment pulls the quoted maximum
    ///         and returns unused core-fee headroom to the payer.
    event ExcessCoreFeeRefunded(
        bytes32 indexed messageId,
        address indexed payer,
        uint256 amount
    );

    event TrustedPublisherSet(address indexed publisher, bool trusted);

    /// @notice Emitted when a payer's gas-limit top-up is applied in the backing vault.
    event GasLimitUpdated(bytes32 indexed messageId, uint256 oldGasLimit,
                          uint256 newGasLimit, uint256 additionalFee);

    event DestinationEvmChainIdSet(
        uint32 indexed destinationChain,
        uint32 indexed destinationEvmChainId
    );

    enum FailureReason { OutOfGas, Reverted }

    /// @param relayer   Proven deliverer decoded from the Inbox event — receives relayFee + tip.
    /// @param submitter Caller who submitted the claim transaction (often the same account).
    event DeliveryClaimed(bytes32 indexed messageId, address indexed relayer,
                          address indexed submitter, uint256 relayFee, uint256 tip);
    event DeliveryFailed(bytes32 indexed messageId, FailureReason reason);
    event TipRefunded(bytes32 indexed messageId, address indexed user, uint256 amount);
    event UnusedTopUpRefunded(bytes32 indexed messageId, address indexed user, uint256 amount);
    event RefundIssued(bytes32 indexed messageId, address indexed user, uint256 amount);
    event TopUpRequested(bytes32 indexed messageId, address indexed relayer,
                         uint256 additionalGasNeeded);
    event TipIncreased(bytes32 indexed messageId, address indexed payer,
                       uint256 additionalTip, uint256 newTipExpiry);
    event FeeRefundRecipientSet(bytes32 indexed messageId, address indexed recipient);
}
