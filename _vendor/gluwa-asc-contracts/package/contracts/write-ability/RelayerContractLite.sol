// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRelayerContractLite} from "./abstract/IRelayerContractLite.sol";
import {IRelayerFeeVault} from "./abstract/IRelayerFeeVault.sol";
import {IOutbox} from "./abstract/IOutbox.sol";
import {IASCProofVerifier} from "./abstract/IASCProofVerifier.sol";
import {IDeliveryDecoder} from "./abstract/IDeliveryDecoder.sol";
import {RelayerTypes} from "./common/RelayerTypes.sol";
import {RelayerFeeLedger} from "./common/RelayerFeeLedger.sol";
import {OutboxTypes} from "./common/OutboxTypes.sol";
import {BlockProverTypes} from "./common/BlockProverTypes.sol";
import {RelayerErrors} from "./error/RelayerErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";

/// @title RelayerContractLite
/// @notice Minimal fee-collection and quote-validation layer: no tips, and quote
///         validation against off-chain Quoter Service EOAs only.
///
/// @dev Quotes use the same RelayerTypes.Quote struct and typehash as the full
///      RelayerContract, so the off-chain Quoter Service signs identically. The
///      digest binds `address(this)`, keeping signatures unusable across the
///      full and Lite deployments. Authorized quoter EOAs are whitelisted
///      directly on this contract by the owner; no on-chain ASCRelayingQuoter
///      is consulted, so there is no on-chain relay-fee floor — the signed
///      relayPrice is taken as-is.
///
/// @dev Deployment note: deploy this contract first, deploy the RelayerFeeVault
///      with this contract's address (the vault stores it as an immutable), then
///      activate the vault with setRelayerFeeVault. The vault is swappable at any
///      time; each funded message remembers the vault holding its fees (vaultOf),
///      so in-flight routes keep settling against their original vault after a
///      swap. This contract must also be registered as a trusted forwarder on
///      the Outbox.
///
/// @dev Main route (publishAndCollectRelayerFee):
///      1. Validate Quoter-EOA-signed quote.
///      2. Pull coreFee + quoted acknowledgmentPrice + relayFee from the caller.
///      3. Publish message via outbox.publishMessageFrom — attributed to original caller.
///      4. Forward coreFee + ackFee → Outbox (which routes coreFee to AttestorVault
///         and ackFee to the AcknowledgmentValidator); relay reward → RelayerFeeVault.
///
/// @dev Separate path (collectRelayerFee):
///      Caller first calls Outbox.publishMessage (coreFee handled there;
///      canAck may be set fee-free), then calls collectRelayerFee to lock
///      the relay reward into RelayerFeeVault and route the quoted
///      acknowledgmentPrice — the first ack funding for the message, which also
///      upgrades one published with canAck = false.
contract RelayerContractLite is IRelayerContractLite, RelayerFeeLedger, Ownable2Step {
    using ECDSA for bytes32;
    using CompatibleERC20 for IERC20;

    bytes32 private constant _TOP_UP_QUOTE_TYPEHASH = keccak256(
        "RelayerTopUpQuote(bytes32 messageId,uint256 newGasLimit,uint256 additionalATTEST,uint256 expiry,uint256 sourceChainId,address verifyingContract)"
    );

    IERC20  public immutable attestToken;
    IOutbox public immutable override outbox;

    IASCProofVerifier public proofVerifier;
    IDeliveryDecoder  public deliveryDecoder;

    /// @notice Off-chain Quoter Service EOAs whose quote signatures are accepted.
    mapping(address => bool) public override authorizedQuoters;
    /// @notice Prevents a Quoter authorization from being used to fund more than one message.
    mapping(bytes32 => bool) public usedQuoteDigests;
    /// @notice Maps the quote/Outbox route key to the EVM chain ID encoded in
    ///         destination transactions. These identifiers are not always equal.
    ///         Resolved here at deposit time and passed to the vault, which
    ///         snapshots it per message for claim-time validation.
    mapping(uint32 => uint32) public override destinationEvmChainIds;

    constructor(
        address initialOwner,
        address attestToken_,
        address outbox_,
        address proofVerifier_,
        address deliveryDecoder_
    ) Ownable(initialOwner) {
        if (
            attestToken_      == address(0) ||
            outbox_           == address(0) ||
            proofVerifier_    == address(0) ||
            deliveryDecoder_  == address(0)
        ) revert CommonErrors.ZeroAddress();

        attestToken     = IERC20(attestToken_);
        outbox          = IOutbox(outbox_);
        proofVerifier   = IASCProofVerifier(proofVerifier_);
        deliveryDecoder = IDeliveryDecoder(deliveryDecoder_);
    }

    /// @notice Activates a vault for new deposits. The vault must be bound back to
    ///         this contract (its immutable relayerContract), else every payout it
    ///         was instructed to make would revert. Swapping never affects
    ///         in-flight routes — their funds stay in the vault recorded in vaultOf.
    function setRelayerFeeVault(address newVault) external onlyOwner {
        address old = address(relayerFeeVault);
        _setVault(newVault);
        emit RelayerFeeVaultSet(old, newVault);
    }

    function setProofVerifier(address newProofVerifier) external onlyOwner {
        if (newProofVerifier == address(0)) revert CommonErrors.ZeroAddress();
        proofVerifier = IASCProofVerifier(newProofVerifier);
    }

    function setDeliveryDecoder(address newDeliveryDecoder) external onlyOwner {
        if (newDeliveryDecoder == address(0)) revert CommonErrors.ZeroAddress();
        deliveryDecoder = IDeliveryDecoder(newDeliveryDecoder);
    }


    function setAuthorizedQuoter(
        address quoter,
        bool authorized
    ) external override onlyOwner {
        if (quoter == address(0)) revert CommonErrors.ZeroAddress();
        authorizedQuoters[quoter] = authorized;
        emit AuthorizedQuoterSet(quoter, authorized);
    }

    /// @notice Configures the EVM chain ID represented by a quote/Outbox route key.
    /// @dev Each deposit passes the current value to the vault, which snapshots it,
    ///      so correcting this setting does not change the validation rule for
    ///      already-funded messages.
    function setDestinationEvmChainId(
        uint32 destinationChain,
        uint32 destinationEvmChainId
    ) external override onlyOwner {
        if (destinationEvmChainId == 0) {
            revert RelayerErrors.InvalidDestinationEvmChainId();
        }
        destinationEvmChainIds[destinationChain] = destinationEvmChainId;
        emit DestinationEvmChainIdSet(destinationChain, destinationEvmChainId);
    }

    /// @dev Payable for native-denominated quotes: the relay fee arrives as
    ///      msg.value (exact amount enforced) while the core fee and the quoted
    ///      acknowledgmentPrice are always pulled in ATTEST — both are forwarded
    ///      to the Outbox, which routes coreFee to the AttestorVault and the ack
    ///      fee to the AcknowledgmentValidator. ATTEST-denominated quotes must
    ///      send no value.
    function publishAndCollectRelayerFee(
        bytes calldata payload,
        bytes calldata signedQuote
    ) external payable override returns (bytes32 messageId) {
        (
            RelayerTypes.Quote memory q,
            uint256 coreFee,
            bytes32 quoteDigest
        ) = _validateQuote(signedQuote, true);
        _validatePayloadQuote(q, payload, msg.sender);
        _consumeQuote(quoteDigest);

        if (q.payInNative) {
            if (msg.value != q.relayPrice)
                revert RelayerErrors.InvalidNativeAmount(q.relayPrice, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender, address(this), coreFee + q.acknowledgmentPrice
            );
        } else {
            if (msg.value != 0)
                revert RelayerErrors.InvalidNativeAmount(0, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender, address(this), coreFee + q.acknowledgmentPrice + q.relayPrice
            );
        }

        messageId = outbox.publishMessageFrom(msg.sender, q.acknowledgmentPrice, payload);

        _forwardPublishFees(messageId, msg.sender, coreFee, q.acknowledgmentPrice);
        _depositRelay(messageId, msg.sender, q);

        emit FeeCollected(
            messageId, msg.sender,
            q.relayPrice, q.acknowledgmentPrice,
            q.gasLimit, q.destinationChain
        );
    }

    /// @dev Payable for native-denominated quotes (msg.value must equal
    ///      relayPrice); ATTEST quotes must send no value. The quoted
    ///      acknowledgmentPrice is always pulled in ATTEST and routed through
    ///      the Outbox to the AcknowledgmentValidator. Direct publishes carry no
    ///      ack fee (Outbox.publishMessage takes only a fee-free canAck
    ///      flag — the fee is Quoter-priced), so a nonzero price here is the
    ///      message's first ack funding, and it also upgrades a message
    ///      published with canAck = false. Reverts if the message is
    ///      already acknowledged.
    function collectRelayerFee(
        bytes32 messageId,
        bytes calldata signedQuote
    ) external payable override {
        (RelayerTypes.Quote memory q, , bytes32 quoteDigest) = _validateQuote(signedQuote, false);
        _validateStoredMessageQuote(q, messageId, msg.sender);
        _consumeQuote(quoteDigest);

        if (q.payInNative) {
            if (msg.value != q.relayPrice)
                revert RelayerErrors.InvalidNativeAmount(q.relayPrice, msg.value);
            if (q.acknowledgmentPrice > 0) {
                attestToken.compatibleTransferFrom(
                    msg.sender, address(this), q.acknowledgmentPrice
                );
            }
        } else {
            if (msg.value != 0)
                revert RelayerErrors.InvalidNativeAmount(0, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender, address(this), q.relayPrice + q.acknowledgmentPrice
            );
        }

        if (q.acknowledgmentPrice > 0) {
            attestToken.compatibleTransfer(address(outbox), q.acknowledgmentPrice);
            outbox.routeAckFee(messageId, msg.sender, q.acknowledgmentPrice);
        }
        _depositRelay(messageId, msg.sender, q);

        emit FeeCollected(
            messageId, msg.sender,
            q.relayPrice, q.acknowledgmentPrice,
            q.gasLimit, q.destinationChain
        );
    }

    /// @dev All delivery business logic lives here: route checks against the
    ///      vault's ledger, proof verification, decoding, and identity/chain
    ///      binding. The vault only settles the fee components and this contract
    ///      emits the events from the returned amounts. Permissionless, but every
    ///      settled fee pays the relayer proven by the destination event — the
    ///      caller (and this contract) never receives or routes funds.
    function claimDelivery(
        bytes32 messageId,
        bytes32 chainKey,
        uint64  blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external override {
        RelayerTypes.MessageInfo memory info = getMessageInfo(messageId);
        if (info.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (info.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);

        bytes32 expectedChainKey = bytes32(uint256(info.destinationChain));
        if (chainKey != expectedChainKey) {
            revert RelayerErrors.RouteChainKeyMismatch(expectedChainKey, chainKey);
        }

        bytes memory encodedTx = proofVerifier.verifyProofs(
            chainKey, blockHeight, inclusionProof, continuityProof
        );
        IDeliveryDecoder.AttestedDeliveryData memory decoded =
            deliveryDecoder.decodeDelivery(encodedTx);

        if (decoded.messageId != messageId)
            revert RelayerErrors.MessageIdMismatch(messageId, decoded.messageId);
        uint32 expectedEvmChainId = routeEvmChainIds[messageId];
        if (decoded.destinationChainId != expectedEvmChainId)
            revert RelayerErrors.DestinationChainMismatch(
                messageId, expectedEvmChainId, decoded.destinationChainId
            );

        // Ledger settles first (CEI), then the vault holding this message's
        // funds pays the relayer proven by the destination event — never the
        // caller. No tips in the Lite variant, so tipPaid/tipRefunded are 0.
        ( , uint256 relayFeePaid, uint256 unusedRefunded,,) =
            _settleDelivery(messageId, decoded.gasLimit);

        IRelayerFeeVault vault = _vaultFor(messageId);
        if (relayFeePaid > 0)   vault.pay(decoded.relayer, relayFeePaid, info.feesInNative);
        address refundTo = feeRefundTo(messageId);
        if (unusedRefunded > 0) vault.pay(refundTo, unusedRefunded, info.feesInNative);

        emit DeliveryClaimed(messageId, decoded.relayer, msg.sender, relayFeePaid, 0);
        if (unusedRefunded > 0) emit UnusedTopUpRefunded(messageId, refundTo, unusedRefunded);

        // Acknowledgment settlement is fully out of the relayer service: the
        // quoted ack fee sits in the AcknowledgmentValidator (routed there by
        // the Outbox) and pays whoever proves the acknowledgment via
        // submitAcknowledgment — typically the same relayer, using the same
        // proof envelope as this claim.
        if (decoded.executionStatus != IDeliveryDecoder.ExecutionStatus.Success) {
            emit DeliveryFailed(
                messageId,
                decoded.executionStatus == IDeliveryDecoder.ExecutionStatus.OutOfGas
                    ? FailureReason.OutOfGas
                    : FailureReason.Reverted
            );
        }
    }

    /// @dev Relayer signals that the committed gasLimit is insufficient. Pure
    ///      signal — no state changes; route liveness is checked against the
    ///      ledger and the event is emitted here.
    function requestTopUp(bytes32 messageId, uint256 additionalGasNeeded) external override {
        RelayerTypes.MessageInfo memory info = getMessageInfo(messageId);
        if (info.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (info.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);
        if (block.timestamp >= info.deliveryDeadline) {
            revert RelayerErrors.DeliveryDeadlineReached(
                messageId,
                info.deliveryDeadline,
                block.timestamp
            );
        }
        emit TopUpRequested(messageId, msg.sender, additionalGasNeeded);
    }

    /// @dev Payer-facing entry. The delta is due in the route's fee currency:
    ///      native routes send it as msg.value, ATTEST routes require prior
    ///      ATTEST.approve(RelayerContractLite, additionalATTEST) and no value.
    ///      Quote validation happens here against this contract's own Quoter-EOA
    ///      whitelist (the TopUpQuote digest binds THIS contract as
    ///      verifyingContract).
    function topUpGasLimit(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) external payable override {
        RelayerTypes.TopUpQuote memory q =
            _checkTopUp(messageId, signedTopUpQuote, additionalATTEST);
        if (_feesInNative(messageId)) {
            if (msg.value != additionalATTEST)
                revert RelayerErrors.InvalidNativeAmount(additionalATTEST, msg.value);
            _forwardNative(address(_vaultFor(messageId)), additionalATTEST);
        } else {
            if (msg.value != 0)
                revert RelayerErrors.InvalidNativeAmount(0, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender,
                address(_vaultFor(messageId)),
                additionalATTEST
            );
        }
        uint256 oldGasLimit =
            _applyTopUp(messageId, q.newGasLimit, additionalATTEST);
        emit GasLimitUpdated(messageId, oldGasLimit, q.newGasLimit, additionalATTEST);
    }

    /// @dev Payer reclaims every fee component still unsettled after the delivery
    ///      deadline. Ledger rules (payer match, deadline, unsettled) are enforced
    ///      in _settleRefund; the message's vault pays out.
    function requestRefund(bytes32 messageId) external override {
        uint256 total = _settleRefund(messageId, msg.sender);
        address refundTo = feeRefundTo(messageId);
        _vaultFor(messageId).pay(refundTo, total, _feesInNative(messageId));
        emit RefundIssued(messageId, refundTo, total);
    }

    /// @notice Redirect unused top-up refunds to `recipient` (payer only, once).
    function setFeeRefundRecipient(
        bytes32 messageId,
        address recipient
    ) external override {
        _setFeeRefundTo(messageId, recipient);
        emit FeeRefundRecipientSet(messageId, recipient);
    }

    /// @dev Full top-up validation: amount, quote binding, payer, route liveness,
    ///      gas-limit increase, and the Quoter-EOA signature over the digest that
    ///      binds this chain and this contract.
    function _checkTopUp(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) internal view returns (RelayerTypes.TopUpQuote memory q) {
        if (additionalATTEST == 0) revert RelayerErrors.ZeroTopUpAmount();

        q = abi.decode(signedTopUpQuote, (RelayerTypes.TopUpQuote));
        if (block.timestamp >= q.expiry)
            revert RelayerErrors.QuoteExpired(q.expiry, block.timestamp);
        if (q.messageId != messageId)
            revert RelayerErrors.MessageIdMismatch(messageId, q.messageId);
        if (additionalATTEST != q.additionalATTEST) {
            revert RelayerErrors.TopUpAmountMismatch(additionalATTEST, q.additionalATTEST);
        }

        RelayerTypes.MessageInfo memory info = getMessageInfo(messageId);
        if (info.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (info.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);
        if (msg.sender != info.payer)
            revert RelayerErrors.NotPayer(msg.sender, info.payer);
        if (block.timestamp >= info.deliveryDeadline) {
            revert RelayerErrors.DeliveryDeadlineReached(
                messageId,
                info.deliveryDeadline,
                block.timestamp
            );
        }
        if (q.newGasLimit <= info.gasLimit)
            revert RelayerErrors.GasLimitNotIncreased(messageId, info.gasLimit, q.newGasLimit);
        if (q.newGasLimit > type(uint64).max) {
            revert RelayerErrors.InvalidGasLimit();
        }

        bytes32 structHash = keccak256(
            abi.encode(
                _TOP_UP_QUOTE_TYPEHASH,
                q.messageId,
                q.newGasLimit,
                q.additionalATTEST,
                q.expiry,
                block.chainid,
                address(this)
            )
        );
        address signer = MessageHashUtils.toEthSignedMessageHash(structHash).recover(q.signature);
        if (!authorizedQuoters[signer])
            revert RelayerErrors.UnauthorizedQuoter(signer);
    }

    /// @dev Validates quote expiry and Quoter EOA signature; for the combined publish
    ///      path, also returns the live coreFee read from the Outbox.
    ///      The signed coreFee is a payer-authorized maximum, not the amount charged:
    ///      a lower live fee is passed through, while an increase requires a new quote.
    ///      The split collection path has already paid its core fee through Outbox, so
    ///      it skips both this read and the cap check.
    function _validateQuote(bytes memory signedQuote, bool enforceCoreFeeCap)
        internal view
        returns (RelayerTypes.Quote memory q, uint256 coreFee, bytes32 digest)
    {
        q = abi.decode(signedQuote, (RelayerTypes.Quote));

        if (block.timestamp >= q.expiry)
            revert RelayerErrors.QuoteExpired(q.expiry, block.timestamp);

        if (q.gasLimit == 0 || q.gasLimit > type(uint64).max) {
            revert RelayerErrors.InvalidGasLimit();
        }
        if (q.expectedCompletion <= block.timestamp) {
            revert RelayerErrors.InvalidDeliveryDeadline(
                q.expectedCompletion,
                block.timestamp
            );
        }
        digest = keccak256(abi.encode(
            RelayerTypes.QUOTE_TYPEHASH,
            q.coreFee,
            q.relayPrice,
            q.acknowledgmentPrice,
            q.gasLimit,
            q.destinationChain,
            q.payloadHash,
            q.targetContract,
            q.expectedCompletion,
            q.expiry,
            q.payInNative,
            block.chainid,
            address(this)
        ));
        address signer = MessageHashUtils.toEthSignedMessageHash(digest).recover(q.signature);
        if (!authorizedQuoters[signer])
            revert RelayerErrors.UnauthorizedQuoter(signer);

        if (usedQuoteDigests[digest]) {
            revert RelayerErrors.QuoteAlreadyUsed(digest);
        }

        uint32 outboxChain = outbox.chainKey();
        if (q.destinationChain != outboxChain) {
            revert RelayerErrors.QuoteDestinationChainMismatch(
                outboxChain,
                q.destinationChain
            );
        }

        if (enforceCoreFeeCap) {
            coreFee = outbox.coreFee();
            if (coreFee > q.coreFee) {
                revert RelayerErrors.CoreFeeAboveQuote(q.coreFee, coreFee);
            }
        }
    }

    function _validatePayloadQuote(
        RelayerTypes.Quote memory q,
        bytes calldata payload,
        address payer
    ) internal pure {
        bytes32 payloadHash = keccak256(payload);
        if (q.payloadHash != payloadHash) {
            revert RelayerErrors.QuotePayloadHashMismatch(q.payloadHash, payloadHash);
        }
        if (q.targetContract != payer) {
            revert RelayerErrors.QuoteTargetMismatch(q.targetContract, payer);
        }
    }

    function _validateStoredMessageQuote(
        RelayerTypes.Quote memory q,
        bytes32 messageId,
        address payer
    ) internal view {
        if (q.targetContract != payer) {
            revert RelayerErrors.QuoteTargetMismatch(q.targetContract, payer);
        }

        OutboxTypes.Message memory message = outbox.getMessage(messageId);
        if (message.emitter != payer) {
            revert RelayerErrors.QuoteTargetMismatch(payer, message.emitter);
        }
        if (message.payloadHash != q.payloadHash) {
            revert RelayerErrors.QuotePayloadHashMismatch(
                q.payloadHash,
                message.payloadHash
            );
        }
        // No ack-status check: a nonzero quote acknowledgmentPrice legitimately
        // upgrades a message published without an acknowledgment request
        // (routeAckFee flips canAck), and a zero price on an ack-required
        // message is fine — the incentive was already deposited at publish.
    }

    function _consumeQuote(bytes32 quoteDigest) internal {
        usedQuoteDigests[quoteDigest] = true;
    }

    /// @dev Forwards the publish-side fees (coreFee + quoted ackFee, ATTEST) to
    ///      the Outbox, which routes the coreFee to the AttestorVault and the
    ///      ackFee to the AcknowledgmentValidator — this contract never needs to
    ///      know either destination.
    function _forwardPublishFees(
        bytes32 messageId,
        address payer,
        uint256 coreFeeAmount,
        uint256 ackFee
    ) internal {
        if (coreFeeAmount + ackFee > 0) {
            attestToken.compatibleTransfer(address(outbox), coreFeeAmount + ackFee);
        }
        outbox.routeCoreFee(messageId, payer, coreFeeAmount);
        if (ackFee > 0) {
            outbox.routeAckFee(messageId, payer, ackFee);
        }
    }

    /// @dev Transfer the relay reward to the active RelayerFeeVault and register
    ///      the deposit with no tip. The delivery proof claims relayPrice.
    ///      deliveryDeadline is taken from quote.expectedCompletion.
    function _depositRelay(
        bytes32 messageId,
        address payer,
        RelayerTypes.Quote memory q
    ) internal {
        uint32 destinationEvmChainId = destinationEvmChainIds[q.destinationChain];
        if (destinationEvmChainId == 0) {
            revert RelayerErrors.DestinationEvmChainIdNotConfigured(
                q.destinationChain
            );
        }

        IRelayerFeeVault vault = _activeVault();
        _recordDeposit(
            vault,
            messageId,
            payer,
            q.relayPrice,
            0 /* tip */,
            q.gasLimit,
            q.destinationChain,
            destinationEvmChainId,
            0 /* tipExpiry */,
            q.expectedCompletion,
            q.payInNative
        );
        if (q.payInNative) {
            _forwardNative(address(vault), q.relayPrice);
        } else {
            attestToken.compatibleTransfer(address(vault), q.relayPrice);
        }
    }
}
