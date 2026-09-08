// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BridgeIntentTemplateRegistry} from "./BridgeIntentTemplateRegistry.sol";
import {CrossChainOrderTypes} from "../CrossChainOrderTypes.sol";
import {ASCBridgeTypes} from "../ASCBridgeTypes.sol";
import {ASCSdkV1TxBytesLib} from "../ASCSdkV1TxBytesLib.sol";

/// @notice Shared helpers for intent template extraction.
library IntentTemplateBase {
    function tryExtract(
        BridgeIntentTemplateRegistry registry,
        string memory name,
        bytes calldata data
    ) internal view returns (BridgeIntentTemplateRegistry.ExtractionResult memory) {
        return registry.tryExtract(name, data);
    }

    /// @notice Tries registered orderData templates in order and maps the first match to a source amount.
    function tryResolveSourceAmountFromOrderData(
        BridgeIntentTemplateRegistry registry,
        string[] memory templateNames,
        ASCSdkV1TxBytesLib.ProofTx memory proofTx,
        bytes calldata orderData
    ) internal view returns (bool ok, ASCBridgeTypes.EVMTokenAmount memory sourceAmount) {
        for (uint256 i = 0; i < templateNames.length; i++) {
            BridgeIntentTemplateRegistry.ExtractionResult memory result =
                tryExtract(registry, templateNames[i], orderData);
            (ok, sourceAmount) = sourceAmountFromAddressUintBody(result, proofTx);
            if (ok) {
                return (true, sourceAmount);
            }
        }
        return (false, sourceAmount);
    }

    /// @dev Maps `(address,uint256)`-body template extractions to attested source amounts.
    function sourceAmountFromAddressUintBody(
        BridgeIntentTemplateRegistry.ExtractionResult memory result,
        ASCSdkV1TxBytesLib.ProofTx memory proofTx
    ) internal pure returns (bool ok, ASCBridgeTypes.EVMTokenAmount memory sourceAmount) {
        if (!result.ok || result.uintArg == 0) {
            return (false, sourceAmount);
        }

        sourceAmount = ASCBridgeTypes.EVMTokenAmount({
            token: proofTx.toIsNull ? address(0) : proofTx.to,
            amount: result.uintArg
        });
        return (true, sourceAmount);
    }

    /// @dev Decodes raw `CrossChainOrder.orderData` encoded as `CrossChainIntent`.
    function crossChainIntentSourceAmount(bytes calldata orderData)
        internal
        pure
        returns (ASCBridgeTypes.EVMTokenAmount memory amount)
    {
        CrossChainOrderTypes.CrossChainIntent memory intent =
            abi.decode(orderData, (CrossChainOrderTypes.CrossChainIntent));
        return intent.sourceAmount;
    }
}
