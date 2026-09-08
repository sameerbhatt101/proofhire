// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IDeliveryDecoder} from "../abstract/IDeliveryDecoder.sol";
import {CommonErrors} from "../error/CommonErrors.sol";
import {EvmV1Decoder} from "../../common/EvmV1Decoder.sol";
import {ASCSdkV1TxBytesLib} from "./ASCSdkV1TxBytesLib.sol";

/// @notice Decodes proved EVM Inbox transactions into fee-claim facts.
contract EVMDeliveryDecoder is IDeliveryDecoder, Ownable2Step {
    // Exact function signature text, required for the selector hash.
    bytes4 private constant _DELIVER_MESSAGE_SELECTOR = bytes4(
        // solhint-disable-next-line gas-small-strings
        keccak256("deliverMessage(bytes32,address,bytes,bytes)")
    );
    uint256 private constant _DELIVER_MESSAGE_MIN_CALLDATA_LENGTH =
        4 + 4 * 32;
    // Exact event signature text, required for the topic hash.
    // solhint-disable-next-line gas-small-strings
    bytes32 private constant _DELIVERED_EVENT_SIGNATURE = keccak256(
        "MessageDelivered(bytes32,address,address)"
    );
    bytes32 private constant _PENDING_EVENT_SIGNATURE = keccak256(
        "MessagePending(bytes32,address,address)"
    );

    mapping(uint32 => address) public trustedInboxes;

    event TrustedInboxSet(
        uint32 indexed destinationChainId,
        address indexed inbox
    );

    error UnsupportedDestinationTransaction();
    error UnsupportedDestinationChain(uint64 chainId);
    error UntrustedInbox(uint32 destinationChainId, address inbox);
    error DeliveryEventNotFound(bytes32 messageId);
    error InvalidDestinationChain(uint32 destinationChainId);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setTrustedInbox(
        uint32 destinationChainId,
        address inbox
    ) external onlyOwner {
        if (destinationChainId == 0) {
            revert InvalidDestinationChain(destinationChainId);
        }
        if (inbox == address(0)) revert CommonErrors.ZeroAddress();
        trustedInboxes[destinationChainId] = inbox;
        emit TrustedInboxSet(destinationChainId, inbox);
    }

    function removeTrustedInbox(uint32 destinationChainId) external onlyOwner {
        if (destinationChainId == 0) {
            revert InvalidDestinationChain(destinationChainId);
        }
        delete trustedInboxes[destinationChainId];
        emit TrustedInboxSet(destinationChainId, address(0));
    }

    function decodeDelivery(
        bytes calldata encodedTransaction
    ) external view override returns (AttestedDeliveryData memory decoded) {
        ASCSdkV1TxBytesLib.ProofTx memory proofTx =
            ASCSdkV1TxBytesLib.decode(encodedTransaction);
        if (
            proofTx.chainId == 0 || proofTx.chainId > type(uint32).max
        ) {
            revert UnsupportedDestinationChain(proofTx.chainId);
        }

        uint32 destinationChainId = uint32(proofTx.chainId);
        address trustedInbox = trustedInboxes[destinationChainId];
        if (
            proofTx.toIsNull ||
            trustedInbox == address(0) ||
            trustedInbox != proofTx.to
        ) {
            revert UntrustedInbox(destinationChainId, proofTx.to);
        }

        bytes32 messageId = _decodeMessageId(proofTx.data);
        EvmV1Decoder.ReceiptFields memory receipt =
            EvmV1Decoder.decodeReceiptFields(encodedTransaction);

        if (receipt.receiptStatus != 1) {
            revert UnsupportedDestinationTransaction();
        }

        // A successful outer transaction is payable only if Inbox accepted the
        // attestation and either delivered or stored the destination call.
        for (uint256 i; i < receipt.receiptLogs.length; ++i) {
            EvmV1Decoder.LogEntry memory logEntry = receipt.receiptLogs[i];
            if (
                logEntry.address_ != proofTx.to ||
                logEntry.topics.length < 2 ||
                logEntry.topics[1] != messageId
            ) {
                continue;
            }

            ExecutionStatus status;
            if (
                logEntry.topics[0] == _DELIVERED_EVENT_SIGNATURE &&
                logEntry.topics.length == 4
            ) {
                status = ExecutionStatus.Success;
            } else if (
                logEntry.topics[0] == _PENDING_EVENT_SIGNATURE &&
                logEntry.topics.length == 4
            ) {
                // Inbox records destination reverts and inner out-of-gas calls
                // identically as MessagePending, so the production EVM path
                // normalizes both application failures to Reverted.
                status = ExecutionStatus.Reverted;
            } else {
                continue;
            }

            return AttestedDeliveryData({
                messageId: messageId,
                destinationChainId: destinationChainId,
                gasLimit: proofTx.gasLimit,
                gasUsed: receipt.receiptGasUsed,
                executionStatus: status,
                // Both Inbox events carry the delivering caller as the third
                // indexed arg. Proven, so it cannot be spoofed by the claimer.
                relayer: address(uint160(uint256(logEntry.topics[3])))
            });
        }

        revert DeliveryEventNotFound(messageId);
    }

    /// @dev Only the selector and complete static ABI head are needed here.
    ///      A payable claim separately requires a successful trusted-Inbox
    ///      outcome, so malformed dynamic tails cannot authorize payment.
    function _decodeMessageId(
        bytes memory transactionData
    ) internal pure returns (bytes32 messageId) {
        if (
            transactionData.length <
            _DELIVER_MESSAGE_MIN_CALLDATA_LENGTH
        ) {
            revert UnsupportedDestinationTransaction();
        }

        bytes4 selector;
        // Extracts the call selector + first arg word; no non-assembly equivalent.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            selector := mload(add(transactionData, 0x20))
            messageId := mload(add(transactionData, 0x24))
        }
        if (selector != _DELIVER_MESSAGE_SELECTOR) {
            revert UnsupportedDestinationTransaction();
        }
    }
}
