// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IInbox} from "./abstract/IInbox.sol";
import {IMessageReceiver} from "./abstract/IMessageReceiver.sol";
import {IVoteValidator} from "./abstract/IVoteValidator.sol";
import {InboxErrors} from "./error/InboxErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";

contract Inbox is IInbox, Ownable2Step, Pausable {
    bytes32 public immutable override localChainKey;
    uint256 public immutable override creditcoinChainId;
    
    IVoteValidator public override defaultVoteValidator;
    address public override messageDispatcher;

    mapping(bytes32 => uint256) private _processedAt;
    mapping(bytes32 => bool) private _validatedMessages;
    mapping(bytes32 => bool) private _isPending;

    struct PendingMessage {
        address emitterAddress;
        bytes payloadData;
    }

    mapping(bytes32 => PendingMessage) private _pendingMessages;

    constructor(
        bytes32 chainKey,
        uint256 creditcoinChainId_,
        IVoteValidator initialValidator,
        address messageDispatcher_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (chainKey == bytes32(0)) {
            revert InboxErrors.InvalidChainKey();
        }
        if (creditcoinChainId_ == 0) {
            revert InboxErrors.InvalidChainId();
        }
        if (address(initialValidator) == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        if (initialOwner == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        if (messageDispatcher_ == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        _requireMessageDispatcher(messageDispatcher_);

        localChainKey = chainKey;
        creditcoinChainId = creditcoinChainId_;
        defaultVoteValidator = initialValidator;
        messageDispatcher = messageDispatcher_;
    }

    function processedAt(
        bytes32 messageId
    ) external view override returns (uint256) {
        return _processedAt[messageId];
    }

    function isPending(
        bytes32 messageId
    ) external view override returns (bool) {
        return _isPending[messageId];
    }

    function validatedMessages(
        bytes32 messageId
    ) external view returns (bool) {
        return _validatedMessages[messageId];
    }

    function validationFailed(
        bytes32
    ) external pure returns (bool) {
        // Legacy getter retained for ABI compatibility. Invalid vote attempts
        // emit ValidationFailed but do not consume the permissionless messageId.
        return false;
    }

    function deliverMessage(
        bytes32 messageId,
        address emitterAddress,
        bytes calldata payload,
        bytes calldata votes
    ) external override whenNotPaused returns (bool success) {
        if (_processedAt[messageId] != 0) {
            revert InboxErrors.MessageAlreadyProcessed(messageId);
        }
        if (_validatedMessages[messageId]) {
            revert InboxErrors.MessageAlreadyValidated(messageId);
        }
        bytes32 messageHash = keccak256(
            abi.encode(
                messageId,
                emitterAddress,
                localChainKey,
                creditcoinChainId,
                payload
            )
        );

        bool ok = defaultVoteValidator.validateVotes(messageHash, votes);
        if (!ok) {
            emit ValidationFailed(messageId);
            return false;
        }

        emit ValidationSucceeded(messageId);

        _validatedMessages[messageId] = true;

        if (_deliver(messageId, emitterAddress, payload)) {
            _processedAt[messageId] = block.number;
            emit MessageDelivered(messageId, address(defaultVoteValidator), msg.sender);
        } else {
            _storePending(messageId, emitterAddress, payload);
            emit MessagePending(messageId, messageDispatcher, msg.sender);
        }

        return true;
    }

    function retryPendingMessage(bytes32 messageId) external override whenNotPaused {
        if (!_isPending[messageId]) {
            revert InboxErrors.MessageNotPending(messageId);
        }

        PendingMessage memory pending = _pendingMessages[messageId];

        // Clear pending state before the external call. If delivery fails, the
        // revert below restores it; if the dispatcher re-enters, it cannot
        // execute the same pending message twice.
        delete _pendingMessages[messageId];
        _isPending[messageId] = false;

        bool delivered = _deliver(
            messageId,
            pending.emitterAddress,
            pending.payloadData
        );

        if (!delivered) {
            revert InboxErrors.RetryFailed(messageId);
        }

        _processedAt[messageId] = block.number;
        emit MessageDelivered(messageId, address(defaultVoteValidator), msg.sender);
    }

    /// @notice Emergency stop for message delivery (deliverMessage + retryPendingMessage).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setDefaultVoteValidator(
        IVoteValidator newValidator
    ) external onlyOwner {
        if (address(newValidator) == address(0)) {
            revert CommonErrors.ZeroAddress();
        }

        address old = address(defaultVoteValidator);
        defaultVoteValidator = newValidator;
        emit DefaultVoteValidatorSet(old, address(newValidator));
    }

    function setMessageDispatcher(address receiver) external override onlyOwner {
        if (receiver == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        _requireMessageDispatcher(receiver);
        messageDispatcher = receiver;
    }

    function _deliver(
        bytes32 messageId,
        address emitterAddress,
        bytes memory payloadData
    ) private returns (bool) {
        bytes memory callData = abi.encodeWithSelector(
            IMessageReceiver.receiveMessage.selector,
            messageId,
            creditcoinChainId,
            emitterAddress,
            payloadData
        );

        address dispatcher = messageDispatcher;
        if (dispatcher.code.length == 0) {
            return false;
        }

        (bool success, ) = dispatcher.call(callData);
        return success;
    }

    function _requireMessageDispatcher(address dispatcher) private view {
        if (dispatcher.code.length == 0) {
            revert InboxErrors.InvalidMessageDispatcher(dispatcher);
        }
    }

    function _storePending(
        bytes32 messageId,
        address emitterAddress,
        bytes memory payload
    ) private {
        _isPending[messageId] = true;
        _pendingMessages[messageId] = PendingMessage({
            emitterAddress: emitterAddress,
            payloadData: payload
        });
    }
}
