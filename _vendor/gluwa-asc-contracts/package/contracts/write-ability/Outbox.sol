// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutboxTypes} from "./common/OutboxTypes.sol";
import {OutboxErrors} from "./error/OutboxErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {Storage} from "./common/Storage.sol";
import {RateLimitLib} from "./common/RateLimitLib.sol";
import {IOutbox} from "./abstract/IOutbox.sol";
import {IAttestorVault} from "./abstract/IAttestorVault.sol";
import {IFeeRegistry} from "./abstract/IFeeRegistry.sol";

/// @notice Ack-fee custody slice of the AcknowledgmentValidator (this Outbox's
///         configured validator): it receives each message's user-set ackFee and
///         holds it until a proven acknowledgment claims it.
interface IAckFeeSink {
    function depositAckFee(bytes32 messageId, address payer, uint256 amount) external;
}
import {CompatibleERC20} from "./common/CompatibleERC20.sol";

contract Outbox is IOutbox, Storage, Ownable2Step, Pausable {
    using RateLimitLib for RateLimitLib.RateBucket;
    using CompatibleERC20 for IERC20;

    modifier onlyValidator() {
        if (msg.sender != _state().validator) {
            revert OutboxErrors.NotValidator();
        }
        _;
    }

    modifier onlyTrustedForwarder() {
        if (!_state().trustedForwarders[msg.sender]) {
            revert OutboxErrors.NotTrustedForwarder(msg.sender);
        }
        _;
    }

    constructor(
        uint32 initialChainKey,
        address initialOwner,
        address initialValidator,
        uint128 initialRateLimit,
        address initialAttestorVault,
        address initialFeeRegistry,
        address initialAttestToken
    ) Ownable(initialOwner) {
        if (initialChainKey == 0 || initialChainKey > type(uint16).max) {
            revert OutboxErrors.InvalidChainKey(initialChainKey);
        }
        _validateRateLimitPolicy(initialRateLimit);
        if (
            initialValidator     == address(0) ||
            initialAttestorVault == address(0) ||
            initialFeeRegistry   == address(0) ||
            initialAttestToken   == address(0)
        ) revert CommonErrors.ZeroAddress();

        OutboxState storage s = _state();
        s.chainKey = initialChainKey;
        s.evmChainId = block.chainid;
        s.validator = initialValidator;
        s.defaultRateLimit = initialRateLimit;
        s.attestorVault = initialAttestorVault;
        s.feeRegistry = initialFeeRegistry;
        s.attestToken = initialAttestToken;
    }


    function owner() public view override(IOutbox, Ownable) returns (address) {
        return Ownable.owner();
    }

    function validator() external view override returns (address) {
        return _state().validator;
    }

    function attestorVault() external view override returns (address) {
        return _state().attestorVault;
    }

    /// @notice Public view of Outbox `_state` scalar fields.
    function getState()
        external
        view
        override
        returns (OutboxTypes.StateView memory view_)
    {
        OutboxState storage s = _state();
        view_ = OutboxTypes.StateView({
            chainKey: s.chainKey,
            validator: s.validator,
            defaultRateLimit: s.defaultRateLimit,
            evmChainId: s.evmChainId,
            attestorVault: s.attestorVault,
            attestToken: s.attestToken,
            feeRegistry: s.feeRegistry
        });
    }

    function chainKey() external view override returns (uint32) {
        return _state().chainKey;
    }

    function defaultRateLimit() external view override returns (uint128) {
        return _state().defaultRateLimit;
    }

    function coreFee() external view override returns (uint256) {
        OutboxState storage s = _state();
        return IFeeRegistry(s.feeRegistry).coreFee(s.chainKey);
    }

    function feeRegistry() external view override returns (address) {
        return _state().feeRegistry;
    }

    function getSequence(address dApp) external view override returns (uint64) {
        return _state().ucSequences[dApp];
    }

    function getMessage(bytes32 messageId) external view override returns (OutboxTypes.Message memory m) {
        m = _state().messages[messageId];
        if (m.emitter == address(0)) revert OutboxErrors.MessageNotFound(messageId);
    }

    function isAcknowledged(bytes32 messageId) external view override returns (bool) {
        return _state().messages[messageId].acknowledged;
    }

    function messageCanAck(bytes32 messageId) external view override returns (bool) {
        return _state().messages[messageId].canAck;
    }

    function isTrustedForwarder(address forwarder) external view override returns (bool) {
        return _state().trustedForwarders[forwarder];
    }

    function isForwarderApproved(
        address emitter,
        address forwarder
    ) external view override returns (bool) {
        return _state().approvedForwarders[emitter][forwarder];
    }


    /// @dev Takes no ackFee: the acknowledgment fee is priced by the
    ///      Quoter/Relayer pair, never chosen by the publisher, and only enters
    ///      through the relayer routes. canAck is free to set — a publisher
    ///      may request acknowledgment with no incentive attached (e.g. to
    ///      self-submit the ack proof) and fund it later through the relayer
    ///      service (collectRelayerFee → routeAckFee, which also upgrades a
    ///      message published with canAck = false).
    function publishMessage(
        bool canAck,
        bytes calldata payload
    ) external override whenNotPaused returns (bytes32 messageId) {
        OutboxState storage s = _state();
        s.rateBuckets[msg.sender].enforce(s.defaultRateLimit);

        uint256 fee = IFeeRegistry(s.feeRegistry).coreFee(s.chainKey);
        messageId = _publishCore(s, msg.sender, canAck, payload);

      
        if (fee > 0) {
            IERC20(s.attestToken).compatibleTransferFrom(
                msg.sender,
                s.attestorVault,
                fee
            );
            IAttestorVault(s.attestorVault).deposit(messageId, msg.sender, s.chainKey, fee);
        }
    }

    /// @dev Like publishMessage, carries no ack fee (the acknowledgment fee is
    ///      Quoter-priced): canAck may be set fee-free and funded later
    ///      through the relayer service (collectRelayerFee → routeAckFee).
    function publishMessageWithAuthorization(
        bool canAck,
        bytes calldata payload,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 sig_s
    ) external override whenNotPaused returns (bytes32 messageId) {
        OutboxState storage s = _state();
        s.rateBuckets[msg.sender].enforce(s.defaultRateLimit);

        uint256 fee = IFeeRegistry(s.feeRegistry).coreFee(s.chainKey);
        messageId = _publishCore(s, msg.sender, canAck, payload);

        if (fee > 0) {
            IAttestorVault(s.attestorVault).depositWithAuthorization(
                messageId, msg.sender, s.chainKey, fee,
                validAfter, validBefore, nonce, v, r, sig_s
            );
        }
    }

    /// @dev Callable only by registered trusted forwarders (e.g. RelayerContract) that
    ///      `emitter` has approved for itself via approveForwarder — so neither a rogue
    ///      forwarder registration nor a compromised forwarder can attribute messages to
    ///      an emitter that never opted in.
    ///      Does NOT collect coreFee or the ack fee — the trusted caller must deposit
    ///      them (routeCoreFee / routeAckFee) as part of the same atomic workflow;
    ///      `ackFee` here only derives the canAck flag (ackFee > 0). Rate limiting
    ///      is applied against `emitter`, not msg.sender, since the message is
    ///      attributed to `emitter`.
    function publishMessageFrom(
        address emitter,
        uint256 ackFee,
        bytes calldata payload
    ) external override onlyTrustedForwarder whenNotPaused returns (bytes32 messageId) {
        OutboxState storage s = _state();
        if (!s.approvedForwarders[emitter][msg.sender]) {
            revert OutboxErrors.ForwarderNotApprovedByEmitter(emitter, msg.sender);
        }
        s.rateBuckets[emitter].enforce(s.defaultRateLimit);
        messageId = _publishCore(s, emitter, ackFee > 0, payload);
    }

    function approveForwarder(address forwarder, bool approved) external override {
        if (forwarder == address(0)) revert CommonErrors.ZeroAddress();
        _state().approvedForwarders[msg.sender][forwarder] = approved;
        emit ForwarderApprovalSet(msg.sender, forwarder, approved);
    }


    /// @notice Routes a message's core fee to the AttestorVault on behalf of a
    ///         trusted forwarder (e.g. RelayerContract), which must have
    ///         transferred the ATTEST to this Outbox first. Mirrors what the
    ///         direct publishMessage path does for its own caller.
    function routeCoreFee(
        bytes32 messageId,
        address payer,
        uint256 coreFeeAmount
    ) external override onlyTrustedForwarder {
        OutboxState storage s = _state();
        if (coreFeeAmount > 0) {
            IERC20(s.attestToken).compatibleTransfer(s.attestorVault, coreFeeAmount);
            IAttestorVault(s.attestorVault).deposit(messageId, payer, s.chainKey, coreFeeAmount);
        }
    }

    /// @notice Routes a message's acknowledgment fee to this Outbox's validator
    ///         (the AcknowledgmentValidator), which holds it until a proven
    ///         acknowledgment claims it. The trusted forwarder must have
    ///         transferred the ATTEST to this Outbox first. Because ackFee > 0
    ///         IS the acknowledgment request, the first nonzero deposit for a
    ///         message published without one upgrades it to canAck
    ///         (announced via MessageAckEnabled, since MessagePublished carried
    ///         false). A fee deposited after acknowledgment could never be
    ///         claimed — submitAcknowledgment skips acked messages — so that
    ///         reverts and the ATTEST stays with the payer.
    function routeAckFee(
        bytes32 messageId,
        address payer,
        uint256 ackFee
    ) external override onlyTrustedForwarder {
        OutboxState storage s = _state();
        OutboxTypes.Message storage m = s.messages[messageId];
        if (m.emitter == address(0)) revert OutboxErrors.MessageNotFound(messageId);
        if (m.acknowledged) revert OutboxErrors.MessageAlreadyAcknowledged(messageId);

        if (ackFee > 0) {
            if (!m.canAck) {
                m.canAck = true;
                emit MessageAckEnabled(messageId);
            }
            IERC20(s.attestToken).compatibleTransfer(s.validator, ackFee);
            IAckFeeSink(s.validator).depositAckFee(messageId, payer, ackFee);
        }
    }

    function acknowledgeMessage(bytes32 messageId) public override onlyValidator {
        _acknowledge(_state(), messageId);
    }

    function batchAcknowledgeMessages(bytes32[] calldata messageIds) external override onlyValidator {
        OutboxState storage s = _state();
        for (uint256 i = 0; i < messageIds.length; ++i) {
            _acknowledge(s, messageIds[i]);
        }
    }

    function setValidator(address newValidator) external override onlyOwner {
        if (newValidator == address(0)) revert CommonErrors.ZeroAddress();
        OutboxState storage s = _state();
        address old = s.validator;
        s.validator = newValidator;
        emit ValidatorChanged(old, newValidator);
    }

    function setTrustedForwarder(address forwarder, bool trusted) external override onlyOwner {
        if (forwarder == address(0)) revert CommonErrors.ZeroAddress();
        _state().trustedForwarders[forwarder] = trusted;
        emit TrustedForwarderSet(forwarder, trusted);
    }

    function setAttestorVault(address newAttestorVault) external onlyOwner {
        if (newAttestorVault == address(0)) revert CommonErrors.ZeroAddress();
        _state().attestorVault = newAttestorVault;
    }

    /// @notice Emergency stop for message intake. Acknowledgments stay live so
    ///         in-flight messages can still settle while publishing is halted.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setFeeRegistry(address newFeeRegistry) external override onlyOwner {
        if (newFeeRegistry == address(0)) revert CommonErrors.ZeroAddress();
        OutboxState storage s = _state();
        address old = s.feeRegistry;
        s.feeRegistry = newFeeRegistry;
        emit FeeRegistryUpdated(old, newFeeRegistry);
    }


    function _validateRateLimitPolicy(uint128 policy) internal pure {
        if (
            policy != 0 &&
            (RateLimitLib.maxRequests(policy) == 0 ||
                RateLimitLib.windowSeconds(policy) == 0)
        ) {
            revert OutboxErrors.InvalidRateLimitPolicy(policy);
        }
    }

    function _acknowledge(OutboxState storage s, bytes32 messageId) internal {
        OutboxTypes.Message storage m = s.messages[messageId];

        if (m.emitter == address(0)) revert OutboxErrors.MessageNotFound(messageId);
        if (!m.canAck) revert OutboxErrors.MessageCannotBeAcknowledged(messageId);
        if (m.acknowledged) revert OutboxErrors.MessageAlreadyAcknowledged(messageId);

        m.acknowledged = true;
        emit MessageAcknowledged(messageId);
    }

    function _publishCore(
        OutboxState storage s,
        address emitter,
        bool canAck,
        bytes calldata payload
    ) internal returns (bytes32 messageId) {
        uint64 seq = uint64(++s.ucSequences[emitter]);
        bytes32 payloadHash = keccak256(payload);

        messageId = OutboxTypes.computeMessageId(address(this), emitter, seq, payloadHash);

        s.messages[messageId] = OutboxTypes.Message({
            emitter: emitter,
            sequence: seq,
            timestamp: uint64(block.timestamp),
            canAck: canAck,
            acknowledged: false,
            payloadHash: payloadHash
        });

        emit MessagePublished(messageId, bytes32(bytes20(emitter)), canAck, payload);
    }
}
