// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockProverTypes} from "../common/BlockProverTypes.sol";
import {CrossChainOrderTypes} from "../common/CrossChainOrderTypes.sol";
import {ASCBridgeTypes} from "../common/ASCBridgeTypes.sol";

/// @notice Inbound bridge interface: client chain → Creditcoin, using ASC's
///         legacy ERC-7683-inspired order schema.
interface IASCBridgeInbound {
    /// @notice Emitted when an inbound ASC cross-chain order from a client chain is successfully processed on Creditcoin.
    /// @param intentId Identifier derived from the configured source chain key,
    ///        order nonce, and user.
    /// @param chainKey Chain key of the source client chain.
    /// @param order    The original ASC order decoded from the client-chain transaction.
    event CrossChainOrderProcessed(
        bytes32 indexed intentId,
        bytes32 indexed chainKey,
        CrossChainOrderTypes.CrossChainOrder order
    );

    /// @notice Processes all CrossChainOrderTypes.CrossChainOrder events in a client-chain transaction.
    ///         The encoded transaction is extracted from inclusionProof by the proof verifier internally.
    ///         Reverts if any matching order was already processed.
    /// @param chainKey        Chain key of the source client chain.
    /// @param blockHeight     Block height containing the transaction.
    /// @param inclusionProof  Self-describing proof that the transaction is in the block.
    ///                        The raw transaction bytes are extracted from this proof by IASCProofVerifier.
    /// @param continuityProof Chain-continuity proof preventing re-org attacks.
    function bridgeFromIntent(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    )
        external
        returns (bool isValid, bytes[] memory extractedTransactionData);
}
