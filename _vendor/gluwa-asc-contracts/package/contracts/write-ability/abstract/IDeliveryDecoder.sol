// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Decodes a proved destination-chain transaction into delivery facts.
interface IDeliveryDecoder {
    enum ExecutionStatus { Success, OutOfGas, Reverted }

    struct AttestedDeliveryData {
        bytes32 messageId;
        uint32 destinationChainId;
        uint256 gasLimit;
        uint256 gasUsed;
        ExecutionStatus executionStatus;
        /// @notice The account that submitted the delivery on the destination chain,
        ///         decoded from the trusted Inbox's event (MessageDelivered /
        ///         MessagePending third indexed topic). This is the delivery-fee payee.
        address relayer;
    }

    function decodeDelivery(
        bytes calldata encodedTransaction
    ) external view returns (AttestedDeliveryData memory);
}
