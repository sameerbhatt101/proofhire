// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./IMessageReceiver.sol";
import "./IVoteValidator.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MessageReceiverBase
/// @notice Abstract base contract for cross-chain message receivers
/// @dev Handles inbox authorization, replay protection, and dispatch
abstract contract MessageReceiverBase is IMessageReceiver, Ownable2Step {

    event TrustedInboxUpdated(address indexed inbox, bool trusted);

    error InvalidInbox(address inbox);
    error MessageAlreadyProcessed(bytes32 messageId);

    /// @notice Trusted inbox contracts
    mapping(address => bool) internal trustedInboxes;

    /// @notice Replay protection mapping
    mapping(bytes32 => bool) internal processedMessages;

    /// @notice Emitted when a message is successfully processed
    event MessageReceived(
        bytes32 indexed messageId,
        uint256 indexed sourceChainId,
        address indexed emitterAddress,
        bytes payload
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address initialInbox,
        address initialOwner
    ) Ownable(initialOwner) {
        if (initialInbox == address(0)) revert InvalidInbox(address(0));

        trustedInboxes[initialInbox] = true;
        emit TrustedInboxUpdated(initialInbox, true);
    }

    function receiveMessage(
        bytes32 messageId,
        uint256 sourceChainId,
        address emitterAddress,
        bytes calldata payload
    ) external virtual override {
        if (!trustedInboxes[msg.sender]) {
            revert UnauthorizedInbox(msg.sender);
        }

        if (processedMessages[messageId]) {
            revert MessageAlreadyProcessed(messageId);
        }

        // Mark as processed BEFORE dispatching to prevent reentrancy attacks on receivers
        processedMessages[messageId] = true;

        // Process message to destination contract
        _processMessage(messageId, sourceChainId, emitterAddress, payload);

        emit MessageReceived(messageId, sourceChainId, emitterAddress, payload);
    }

    function setTrustedInbox(
        address inbox,
        bool trusted
    ) external virtual override onlyOwner {
        if (inbox == address(0)) revert InvalidInbox(address(0));

        trustedInboxes[inbox] = trusted;
        emit TrustedInboxUpdated(inbox, trusted);
    }

    function isTrustedInbox(
        address inbox
    ) external view virtual override returns (bool) {
        return trustedInboxes[inbox];
    }

    /// @notice Application-specific message handler
    /// @dev A revert propagates to the Inbox, which may retain the message for retry.
    /// @dev No revert = message processed successfully
    function _processMessage(
        bytes32 messageId,
        uint256 sourceChainId,
        address emitterAddress,
        bytes calldata payload
    ) internal virtual;
}
