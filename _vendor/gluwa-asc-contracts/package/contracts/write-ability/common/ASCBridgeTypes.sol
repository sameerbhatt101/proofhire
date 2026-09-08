// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library ASCBridgeTypes {
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    /// @notice Payload-only call or route-bound token operation.
    struct BridgeMessage {
        /// @dev abi.encode(address) for EVM destinations; chain-specific otherwise.
        bytes receiver;
        /// @dev Arbitrary payload-only call data. Token callers provide empty
        ///      data or the exact canonical call assertion; the published
        ///      payload replaces it with a token execution commitment.
        bytes data;
        /// @dev Source token facts for a token operation; both fields are zero
        ///      for payload-only calls.
        EVMTokenAmount tokenAmount;
        /// @dev Exact upper bound forwarded to the destination execution call.
        uint256 gasLimit;
    }

    /// @notice Normalized attested source-transaction facts used for matching.
    struct AttestedTxData {
        address user;
        uint256 nonce;
        uint256 sourceChainId;
        EVMTokenAmount sourceAmount;
        /// @dev Hash of the proved transaction for correlation/inspection. It
        ///      is not a satisfiable embedded sourceProofRequirement domain.
        bytes32 proofContextHash;
    }
}
