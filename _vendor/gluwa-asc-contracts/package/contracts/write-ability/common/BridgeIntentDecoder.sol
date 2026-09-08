// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBridgeIntentDecoder} from "../abstract/IBridgeIntentDecoder.sol";
import {CrossChainOrderTypes} from "./CrossChainOrderTypes.sol";
import {ASCBridgeTypes} from "./ASCBridgeTypes.sol";
import {ASCSdkV1TxBytesLib} from "./ASCSdkV1TxBytesLib.sol";
import {EvmV1Decoder} from "../../common/EvmV1Decoder.sol";
import {BridgeIntentTemplateRegistry} from "./templates/BridgeIntentTemplateRegistry.sol";
import {IntentTemplateBase} from "./templates/IntentTemplateBase.sol";

/// @notice Combined template registry and bridge intent decoder for inbound ASC processing.
contract BridgeIntentDecoder is BridgeIntentTemplateRegistry, IBridgeIntentDecoder {
    struct SourceSettlementPolicy {
        address sourceToken;
        address settlementRecipient;
        bool trusted;
    }

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        keccak256("Transfer(address,address,uint256)");

    string[] private _settlerTemplateNames;
    string[] private _orderDataTemplateNames;

    /// @notice Source settlement contracts whose proved calls may be decoded as bridge intents.
    /// @dev A selector/template alone is not a trust boundary: an attacker can deploy a
    ///      contract with matching calldata. Each production source chain must explicitly
    ///      configure its authoritative settler before inbound minting is enabled.
    mapping(uint64 => mapping(address => bool)) public trustedSourceSettlers;
    mapping(uint64 => mapping(address => SourceSettlementPolicy))
        public sourceSettlementPolicies;

    event TrustedSourceSettlerSet(
        uint64 indexed sourceChainId,
        address indexed settler,
        bool trusted
    );
    event SourceSettlementPolicySet(
        uint64 indexed sourceChainId,
        address indexed settler,
        address indexed sourceToken,
        address settlementRecipient,
        bool trusted
    );

    error UntrustedSourceSettler(uint64 sourceChainId, address settler);
    error InvalidSourceChainId(uint64 sourceChainId);
    error UnsupportedSourceTransaction(address settler);
    error OriginSettlerMismatch(address expected, address actual);
    error OriginChainMismatch(uint256 expected, uint256 actual);
    error SourceAmountNotResolved();
    error SourceSettlementFailed(uint8 receiptStatus);
    error MissingSourceSettlementPolicy(uint64 sourceChainId, address settler);
    error SourceTokenMismatch(address expected, address actual);
    /// @notice Escrow recipient must be the trusted settler (or address(0) for burns).
    ///         An arbitrary Transfer recipient does not prove the settler escrowed funds.
    error SettlementRecipientNotTrustedSettler(
        address settler,
        address settlementRecipient
    );
    error SettlementTransferNotProved(
        address token,
        address from,
        address to,
        uint256 amount
    );

    constructor(address initialOwner) BridgeIntentTemplateRegistry(initialOwner) {}

    /// @notice Configures which registered template names the decoder tries at runtime.
    function setTemplateNameLists(
        string[] calldata settlerTemplateNames,
        string[] calldata orderDataTemplateNames
    ) external onlyOwner {
        _settlerTemplateNames = settlerTemplateNames;
        _orderDataTemplateNames = orderDataTemplateNames;
    }

    /// @notice Trusts or revokes a source-chain settlement contract.
    /// @dev This is deliberately separate from template registration. Templates describe
    ///      calldata; this allowlist establishes which proved contract calls may authorize
    ///      an inbound bridge operation.
    function setTrustedSourceSettler(
        uint64 sourceChainId,
        address settler,
        bool trusted
    ) external onlyOwner {
        _requireSourceChainId(sourceChainId);
        if (settler == address(0)) revert UntrustedSourceSettler(sourceChainId, settler);
        trustedSourceSettlers[sourceChainId][settler] = trusted;
        emit TrustedSourceSettlerSet(sourceChainId, settler, trusted);
    }

    /// @notice Binds an authoritative settler to the source token and the address
    ///         that must receive (or burn) the exact source amount in the proved receipt.
    /// @dev Escrow: `settlementRecipient` must equal `settler` so the proved
    ///      Transfer is into the trusted settler. Burn: `address(0)`.
    function setSourceSettlementPolicy(
        uint64 sourceChainId,
        address settler,
        address sourceToken,
        address settlementRecipient,
        bool trusted
    ) external onlyOwner {
        _requireSourceChainId(sourceChainId);
        if (settler == address(0) || sourceToken == address(0)) {
            revert MissingSourceSettlementPolicy(sourceChainId, settler);
        }
        _requireTrustedSettlementRecipient(settler, settlementRecipient);

        sourceSettlementPolicies[sourceChainId][settler] =
            SourceSettlementPolicy({
                sourceToken: sourceToken,
                settlementRecipient: settlementRecipient,
                trusted: trusted
            });
        trustedSourceSettlers[sourceChainId][settler] = trusted;

        emit SourceSettlementPolicySet(
            sourceChainId,
            settler,
            sourceToken,
            settlementRecipient,
            trusted
        );
        emit TrustedSourceSettlerSet(sourceChainId, settler, trusted);
    }

    /// @inheritdoc IBridgeIntentDecoder
    function decodeBridgeIntent(
        bytes calldata encodedTransaction
    ) external view returns (DecodedBridgeIntent memory) {
        return _decodeTxBytes(encodedTransaction, true);
    }

    /// @notice Decodes raw proof bytes for inspection tooling.
    /// @dev This intentionally does not establish that the transaction is an authorized
    ///      bridge settlement. Production mint paths must call `decodeBridgeIntent`.
    function decodeFromTxBytes(
        bytes calldata txBytes
    ) external view returns (DecodedBridgeIntent memory) {
        return _decodeTxBytes(txBytes, false);
    }

    /// @notice Legacy pure helper retained for interface compatibility.
    /// @dev Decodes only the source token amount from canonical CrossChainIntent
    ///      order data; it is not an authorization path.
    function decodeCrossChainIntentSourceAmount(
        bytes calldata orderData
    ) external pure returns (ASCBridgeTypes.EVMTokenAmount memory) {
        return IntentTemplateBase.crossChainIntentSourceAmount(orderData);
    }

    function _decodeTxBytes(
        bytes calldata txBytes,
        bool requireAuthorizedSettlement
    ) internal view returns (DecodedBridgeIntent memory decoded) {
        ASCSdkV1TxBytesLib.ProofTx memory proofTx = ASCSdkV1TxBytesLib.decode(txBytes);

        if (requireAuthorizedSettlement) {
            _requireSourceChainId(proofTx.chainId);
        }

        SourceSettlementPolicy memory policy =
            sourceSettlementPolicies[proofTx.chainId][proofTx.to];
        if (
            requireAuthorizedSettlement &&
            (proofTx.toIsNull ||
                !trustedSourceSettlers[proofTx.chainId][proofTx.to] ||
                !policy.trusted)
        ) {
            revert UntrustedSourceSettler(proofTx.chainId, proofTx.to);
        }
        if (requireAuthorizedSettlement && policy.sourceToken == address(0)) {
            revert MissingSourceSettlementPolicy(proofTx.chainId, proofTx.to);
        }
        EvmV1Decoder.ReceiptFields memory receipt;
        if (requireAuthorizedSettlement) {
            receipt = EvmV1Decoder.decodeReceiptFields(txBytes);
            if (receipt.receiptStatus != 1) {
                revert SourceSettlementFailed(receipt.receiptStatus);
            }
        }

        CrossChainOrderTypes.CrossChainOrder memory order;
        CrossChainOrderTypes.CrossChainIntent memory intent;
        (, ExtractionResult memory orderExtract) =
            this.tryExtractFirst(_settlerTemplateNames, proofTx.data);

        if (orderExtract.ok) {
            order = abi.decode(orderExtract.encodedBody, (CrossChainOrderTypes.CrossChainOrder));
            if (orderExtract.encodedIntent.length != 0) {
                intent = abi.decode(
                    orderExtract.encodedIntent,
                    (CrossChainOrderTypes.CrossChainIntent)
                );
                // Normalize selector-prefixed source calldata to the canonical
                // intent bytes established by the matched settler template.
                order.orderData = orderExtract.encodedIntent;
            }
            if (requireAuthorizedSettlement) {
                if (orderExtract.encodedIntent.length == 0) {
                    revert UnsupportedSourceTransaction(proofTx.to);
                }
                if (order.originSettler != proofTx.to) {
                    revert OriginSettlerMismatch(proofTx.to, order.originSettler);
                }
                if (order.originChainId != proofTx.chainId) {
                    revert OriginChainMismatch(proofTx.chainId, order.originChainId);
                }
            }
        } else {
            if (requireAuthorizedSettlement) {
                revert UnsupportedSourceTransaction(proofTx.to);
            }
            order.user = proofTx.from;
            order.nonce = proofTx.nonce;
            order.originChainId = proofTx.chainId;
            order.originSettler = proofTx.toIsNull ? address(0) : proofTx.to;
            order.orderData = proofTx.data;
        }

        ASCBridgeTypes.EVMTokenAmount memory sourceAmount;
        if (requireAuthorizedSettlement) {
            sourceAmount = intent.sourceAmount;
            if (sourceAmount.token == address(0) || sourceAmount.amount == 0) {
                revert SourceAmountNotResolved();
            }
            if (sourceAmount.token != policy.sourceToken) {
                revert SourceTokenMismatch(policy.sourceToken, sourceAmount.token);
            }

            // Mint only when the proved Transfer escrowed into this trusted
            // settler (or burned). Arbitrary recipients do not prove settlement.
            _requireTrustedSettlementRecipient(
                proofTx.to,
                policy.settlementRecipient
            );
            _requireSettlementTransfer(
                receipt,
                sourceAmount.token,
                order.user,
                policy.settlementRecipient,
                sourceAmount.amount
            );

            return DecodedBridgeIntent({
                order: order,
                intent: intent,
                attestedTxData: _attestedFromOrder(
                    txBytes,
                    order,
                    sourceAmount
                ),
                sourceAmountBurned: policy.settlementRecipient == address(0)
            });
        }

        sourceAmount = _sourceAmountFromOrderData(proofTx, order.orderData);
        return DecodedBridgeIntent({
            order: order,
            intent: intent,
            attestedTxData: _attested(txBytes, proofTx, sourceAmount),
            sourceAmountBurned: false
        });
    }

    function _sourceAmountFromOrderData(
        ASCSdkV1TxBytesLib.ProofTx memory proofTx,
        bytes memory orderData
    ) internal view returns (ASCBridgeTypes.EVMTokenAmount memory sourceAmount) {
        return this.resolveSourceAmountFromOrderData(proofTx, orderData);
    }

    function resolveSourceAmountFromOrderData(
        ASCSdkV1TxBytesLib.ProofTx calldata proofTx,
        bytes calldata orderData
    ) external view returns (ASCBridgeTypes.EVMTokenAmount memory sourceAmount) {
        (bool templateOk, ASCBridgeTypes.EVMTokenAmount memory templateAmount) =
            IntentTemplateBase.tryResolveSourceAmountFromOrderData(
                BridgeIntentTemplateRegistry(address(this)),
                _orderDataTemplateNames,
                proofTx,
                orderData
            );
        if (templateOk) {
            return templateAmount;
        }
    }

    function _attested(
        bytes calldata txBytes,
        ASCSdkV1TxBytesLib.ProofTx memory proofTx,
        ASCBridgeTypes.EVMTokenAmount memory sourceAmount
    ) internal pure returns (ASCBridgeTypes.AttestedTxData memory attestedTxData) {
        attestedTxData = ASCBridgeTypes.AttestedTxData({
            user: proofTx.from,
            nonce: proofTx.nonce,
            sourceChainId: proofTx.chainId,
            sourceAmount: sourceAmount,
            proofContextHash: keccak256(txBytes)
        });
    }

    function _attestedFromOrder(
        bytes calldata txBytes,
        CrossChainOrderTypes.CrossChainOrder memory order,
        ASCBridgeTypes.EVMTokenAmount memory sourceAmount
    ) internal pure returns (ASCBridgeTypes.AttestedTxData memory attestedTxData) {
        attestedTxData = ASCBridgeTypes.AttestedTxData({
            user: order.user,
            nonce: order.nonce,
            sourceChainId: order.originChainId,
            sourceAmount: sourceAmount,
            proofContextHash: keccak256(txBytes)
        });
    }

    function _requireTrustedSettlementRecipient(
        address settler,
        address settlementRecipient
    ) internal pure {
        if (
            settlementRecipient != address(0) &&
            settlementRecipient != settler
        ) {
            revert SettlementRecipientNotTrustedSettler(
                settler,
                settlementRecipient
            );
        }
    }

    function _requireSettlementTransfer(
        EvmV1Decoder.ReceiptFields memory receipt,
        address sourceToken,
        address user,
        address settlementRecipient,
        uint256 amount
    ) internal pure {
        for (uint256 i; i < receipt.receiptLogs.length; ++i) {
            EvmV1Decoder.LogEntry memory logEntry = receipt.receiptLogs[i];
            if (
                logEntry.address_ == sourceToken &&
                logEntry.topics.length == 3 &&
                logEntry.topics[0] == _TRANSFER_EVENT_SIGNATURE &&
                address(uint160(uint256(logEntry.topics[1]))) == user &&
                address(uint160(uint256(logEntry.topics[2]))) ==
                    settlementRecipient &&
                logEntry.data.length == 32 &&
                abi.decode(logEntry.data, (uint256)) == amount
            ) {
                return;
            }
        }

        revert SettlementTransferNotProved(
            sourceToken,
            user,
            settlementRecipient,
            amount
        );
    }

    function _requireSourceChainId(uint64 sourceChainId) internal pure {
        if (sourceChainId == 0) {
            revert InvalidSourceChainId(sourceChainId);
        }
    }
}
