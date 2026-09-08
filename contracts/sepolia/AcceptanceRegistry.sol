// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title AcceptanceRegistry
/// @notice Sepolia source-chain emitter for ProofHire milestone acceptances.
/// @dev Minimal per Attestcoin source-chain guidance: emit data Creditcoin needs.
contract AcceptanceRegistry {
    event MilestoneAccepted(
        bytes32 indexed jobId,
        address indexed client,
        address indexed worker,
        uint256 amountHint,
        bytes32 metadataHash
    );

    mapping(bytes32 => uint256) public acceptanceCount;

    function acceptMilestone(
        bytes32 jobId,
        address worker,
        uint256 amountHint,
        bytes32 metadataHash
    ) external {
        require(jobId != bytes32(0), "bad jobId");
        require(worker != address(0), "bad worker");
        unchecked { acceptanceCount[jobId] += 1; }
        emit MilestoneAccepted(jobId, msg.sender, worker, amountHint, metadataHash);
    }
}
