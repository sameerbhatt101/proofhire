// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "../write-ability/common/INativeQueryVerifier.sol";

/// @title ASCBase
/// @notice Base contract for readability ASCs: verify a foreign-chain transaction via the native
///         block-prover precompile, dedupe by query id, then delegate to app-specific logic.
/// @dev    Inherit and implement `_processAndEmitEvent`. Intended as the whitepaper base layer for
///         teams building their own Application Smart Contracts on Creditcoin.
abstract contract ASCBase {
    /// @notice The Native Query Verifier precompile instance (`0xFD2` / 4050).
    INativeQueryVerifier public immutable VERIFIER;

    mapping(bytes32 => bool) public processedQueries;

    constructor() {
        VERIFIER = NativeQueryVerifierLib.getVerifier();
    }

    /// @notice App-specific handler invoked after proof verification and deduplication.
    /// @param action Caller-supplied action discriminator (e.g. mint, loan funded).
    /// @param queryId Stable id for this proved transaction.
    /// @param encodedTransaction Raw proved transaction bytes from the block prover.
    function _processAndEmitEvent(
        uint8 action,
        bytes32 queryId,
        bytes memory encodedTransaction
    ) internal virtual;

    /// @notice Verify inclusion + continuity, enforce one-time processing, then run app logic.
    function execute(
        uint8 action,
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots
    ) external returns (bool success) {
        bytes32 queryId = _computeQueryId(chainKey, blockHeight, merkleRoot, siblings);

        require(!processedQueries[queryId], "Query already processed");

        bool verified = _verifyProof(
            chainKey,
            blockHeight,
            encodedTransaction,
            merkleRoot,
            siblings,
            lowerEndpointDigest,
            continuityRoots
        );
        require(verified, "Proof of inclusion verification failed");

        processedQueries[queryId] = true;

        _processAndEmitEvent(action, queryId, encodedTransaction);

        return true;
    }

    function _verifyProof(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots
    ) internal returns (bool verified) {
        INativeQueryVerifier.MerkleProof memory merkleProof =
            INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});

        INativeQueryVerifier.ContinuityProof memory continuityProof =
            INativeQueryVerifier.ContinuityProof({
                lowerEndpointDigest: lowerEndpointDigest,
                roots: continuityRoots
            });

        verified = VERIFIER.verifyAndEmit(
            chainKey,
            blockHeight,
            encodedTransaction,
            merkleProof,
            continuityProof
        );
    }

    function _computeQueryId(
        uint64 chainKey,
        uint64 blockHeight,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings
    ) internal view returns (bytes32 queryId) {
        INativeQueryVerifier.MerkleProof memory merkleProof =
            INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});

        uint256 txIndex = VERIFIER.calculateTxIndex(merkleProof);

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, chainKey)
            mstore(add(ptr, 32), shl(192, blockHeight))
            mstore(add(ptr, 40), txIndex)
            queryId := keccak256(ptr, 72)
        }
    }
}
