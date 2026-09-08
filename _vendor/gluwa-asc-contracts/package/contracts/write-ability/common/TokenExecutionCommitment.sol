// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Binds a token message to the exact cross-chain execution semantics.
library TokenExecutionCommitment {
    bytes32 private constant _DOMAIN =
        keccak256("ASC.TokenExecutionCommitment.v1");

    function compute(
        uint256 sourceChainId,
        address sourceToken,
        address destinationToken,
        uint8 sourceDecimals,
        uint8 destinationDecimals,
        bool mintOnReceive,
        address receiver,
        uint256 sourceAmount,
        uint256 destinationAmount
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _DOMAIN,
                    sourceChainId,
                    sourceToken,
                    destinationToken,
                    sourceDecimals,
                    destinationDecimals,
                    mintOnReceive,
                    receiver,
                    sourceAmount,
                    destinationAmount
                )
            );
    }
}
