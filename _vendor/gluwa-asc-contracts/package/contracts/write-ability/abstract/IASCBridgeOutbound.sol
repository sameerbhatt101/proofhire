// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ASCBridgeTypes} from "../common/ASCBridgeTypes.sol";

/// @notice Outbound bridge interface: Creditcoin → client chain.
interface IASCBridgeOutbound {
    /// @notice Emitted by bridgeTo when an outbound bridge operation is initiated.
    /// @param intentId Identifier derived from message kind, global nonce, and chain key.
    /// @param chainKey Chain key of the destination client chain.
    /// @param message  Full outbound message.
    event BridgeIntent(
        bytes32 indexed intentId,
        bytes32 indexed chainKey,
        ASCBridgeTypes.BridgeMessage message
    );

    /// @notice Initiates a bridge operation from Creditcoin to a client chain.
    ///         Emits BridgeIntent. Tokens in message.tokenAmount are pulled from msg.sender via transferFrom.
    /// @param chainKey Chain key of the destination client chain (must be whitelisted).
    /// @param message  Payload-only call or route-bound token operation.
    /// @param quote    ABI-encoded `(bytes signedQuote, uint256 tip, uint256 tipExpiry)`.
    ///                 The payer must `approve` this bridge for ATTEST covering
    ///                 `coreFee + relayPrice + acknowledgmentPrice + tip`. The
    ///                 bridge is the Outbox emitter; Relayer pulls fees via
    ///                 transferFrom (compatible with Devnet ATTEST mocks that
    ///                 lack EIP-3009).
    function bridgeTo(
        bytes32 chainKey,
        ASCBridgeTypes.BridgeMessage calldata message,
        bytes calldata quote
    ) external payable;

    /// @notice Computes the exact next payload that the quoter and payer must sign.
    function previewBridgePayload(
        address sender,
        bytes32 chainKey,
        ASCBridgeTypes.BridgeMessage calldata message
    ) external view returns (
        uint256 nonce,
        bytes32 intentId,
        bytes memory payload,
        bytes32 payloadHash
    );

    /// @notice User-facing Relayer refund after the delivery deadline. Relayer
    ///         records this bridge as `payer`; this forwards the ATTEST refund
    ///         to the original `bridgeTo` caller.
    function requestRelayerRefund(bytes32 messageId) external;

    /// @notice User-facing AttestorVault core-fee refund after `refundDelay`.
    ///         Relayer routed the core fee with this bridge as `payer`; this
    ///         forwards the ATTEST refund to the original `bridgeTo` caller.
    function requestCoreFeeRefund(bytes32 messageId) external;

    /// @notice User-facing AcknowledgmentValidator ack-fee refund after the
    ///         ack refund delay. Relayer routed the ack fee with this bridge as
    ///         `payer`; this forwards the ATTEST refund to the original
    ///         `bridgeTo` caller.
    function requestAckFeeRefund(bytes32 messageId) external;

    /// @notice User-facing gas top-up for a stuck outbound message.
    function topUpRelayerGasLimit(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) external;

    /// @notice User-facing tip increase. Only works when the recorded Relayer
    ///         supports tips.
    function increaseRelayerTip(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry
    ) external;
}
