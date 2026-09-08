// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRelayerContract} from "./abstract/IRelayerContract.sol";
import {IRelayerFeeVault} from "./abstract/IRelayerFeeVault.sol";
import {IOutbox} from "./abstract/IOutbox.sol";
import {IERC3009} from "./abstract/IERC3009.sol";
import {IASCRelayingQuoter} from "./abstract/IASCRelayingQuoter.sol";
import {IASCProofVerifier} from "./abstract/IASCProofVerifier.sol";
import {IDeliveryDecoder} from "./abstract/IDeliveryDecoder.sol";
import {RelayerTypes} from "./common/RelayerTypes.sol";
import {RelayerFeeLedger} from "./common/RelayerFeeLedger.sol";
import {OutboxTypes} from "./common/OutboxTypes.sol";
import {BlockProverTypes} from "./common/BlockProverTypes.sol";
import {RelayerErrors} from "./error/RelayerErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";

/// @title RelayerContract
/// @notice Fee-collection and quote-validation layer of the cross-chain messaging system.
///
/// @dev Deployment note: deploy this contract first, deploy the RelayerFeeVault with
///      this contract's address (the vault stores it as an immutable), then activate
///      the vault with setRelayerFeeVault. The vault is swappable at any time; each
///      funded message remembers the vault holding its fees (vaultOf), so in-flight
///      routes keep settling against their original vault after a swap.
///
/// @dev Main route (publishAndCollectRelayerFee):
///      1. Validate Quoter-signed quote.
///      2. Pull coreFee + relayFee + ackFee + tip from caller via transferFrom (or EIP-3009).
///      3. Publish message via outbox.publishMessageFrom — attributed to original caller.
///      4. Forward coreFee → AttestorVault; combined relay/ack reward and tip → RelayerFeeVault.
///
/// @dev Trusted-publisher route (publishAndCollectRelayerFeeFor):
///      The publisher remains the Outbox emitter, while the named payer supplies
///      an exact-value EIP-3009 authorization scoped to publisher + quote digest.
///      Quoted core-fee headroom is refunded after the live fee is deposited.
///
/// @dev Separate path (collectRelayerFee):
///      Caller first calls Outbox.publishMessage (coreFee handled there;
///      canAck may be set fee-free), then calls collectRelayerFee to lock
///      relayFee + tip into RelayerFeeVault and route the quoted
///      acknowledgmentPrice — the first ack funding for the message, which also
///      upgrades one published with canAck = false.
contract RelayerContract is IRelayerContract, RelayerFeeLedger, Ownable2Step {
    using ECDSA for bytes32;
    using CompatibleERC20 for IERC20;

    uint256 public constant MIN_TIP_WINDOW = RelayerTypes.MIN_TIP_WINDOW;
    bytes32 private constant _PUBLISHER_AUTHORIZATION_DOMAIN = keccak256(
        "RelayerContract.publisherFeeAuthorization.v1"
    );
    bytes32 private constant _TOP_UP_QUOTE_TYPEHASH = keccak256(
        "RelayerTopUpQuote(bytes32 messageId,uint256 newGasLimit,uint256 additionalATTEST,uint256 expiry,uint256 sourceChainId,address verifyingContract)"
    );

    IERC20             public immutable attestToken;
    IOutbox            public immutable override outbox;
    IASCRelayingQuoter public immutable quoterContract;

    IASCProofVerifier public proofVerifier;
    IDeliveryDecoder  public deliveryDecoder;

    /// @notice Prevents a Quoter authorization from being used to fund more than one message.
    mapping(bytes32 => bool) public usedQuoteDigests;
    /// @notice Contracts allowed to publish as themselves for a payer who has
    ///         signed the exact scoped EIP-3009 authorization.
    mapping(address => bool) public override trustedPublishers;
    /// @notice Maps the quote/Outbox route key to the EVM chain ID encoded in
    ///         destination transactions. These identifiers are not always equal.
    ///         Resolved here at deposit time and passed to the vault, which
    ///         snapshots it per message for claim-time validation.
    mapping(uint32 => uint32) public override destinationEvmChainIds;

    modifier onlyTrustedPublisher() {
        if (!trustedPublishers[msg.sender]) {
            revert RelayerErrors.UnauthorizedPublisher(msg.sender);
        }
        _;
    }

    constructor(
        address initialOwner,
        address attestToken_,
        address outbox_,
        address quoterContract_,
        address proofVerifier_,
        address deliveryDecoder_
    ) Ownable(initialOwner) {
        if (
            attestToken_      == address(0) ||
            outbox_           == address(0) ||
            quoterContract_   == address(0) ||
            proofVerifier_    == address(0) ||
            deliveryDecoder_  == address(0)
        ) revert CommonErrors.ZeroAddress();

        attestToken     = IERC20(attestToken_);
        outbox          = IOutbox(outbox_);
        quoterContract  = IASCRelayingQuoter(quoterContract_);
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

    function setTrustedPublisher(
        address publisher,
        bool trusted
    ) external override onlyOwner {
        if (publisher == address(0)) revert CommonErrors.ZeroAddress();
        trustedPublishers[publisher] = trusted;
        emit TrustedPublisherSet(publisher, trusted);
    }

    function publisherAuthorizationNonce(
        address payer,
        address publisher,
        bytes32 quoteDigest
    ) public view override returns (bytes32) {
        return keccak256(
            abi.encode(
                _PUBLISHER_AUTHORIZATION_DOMAIN,
                block.chainid,
                address(this),
                payer,
                publisher,
                quoteDigest
            )
        );
    }

    /// @dev Payable for native-denominated quotes: relay fee + tip arrive as
    ///      msg.value (exact amount enforced) while the core fee and the quoted
    ///      acknowledgmentPrice are always pulled in ATTEST — both are forwarded
    ///      to the Outbox, which routes coreFee to the AttestorVault and the ack
    ///      fee to the AcknowledgmentValidator. ATTEST-denominated quotes must
    ///      send no value.
    function publishAndCollectRelayerFee(
        bytes calldata payload,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry
    ) external payable override returns (bytes32 messageId) {
        (
            RelayerTypes.Quote memory q,
            uint256 coreFee,
            bytes32 quoteDigest
        ) = _validateQuote(signedQuote, true);
        _validatePayloadQuote(q, payload, msg.sender);
        _consumeQuote(quoteDigest);

        uint256 relayTotal = q.relayPrice + tip;
        if (q.payInNative) {
            if (msg.value != relayTotal)
                revert RelayerErrors.InvalidNativeAmount(relayTotal, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender, address(this), coreFee + q.acknowledgmentPrice
            );
        } else {
            if (msg.value != 0)
                revert RelayerErrors.InvalidNativeAmount(0, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender, address(this), coreFee + q.acknowledgmentPrice + relayTotal
            );
        }

        messageId = outbox.publishMessageFrom(msg.sender, q.acknowledgmentPrice, payload);

        _forwardPublishFees(messageId, msg.sender, coreFee, q.acknowledgmentPrice);
        _depositRelay(messageId, msg.sender, q, tip, tipExpiry);

        emit FeeCollected(
            messageId, msg.sender,
            q.relayPrice, q.acknowledgmentPrice, tip, tipExpiry,
            q.gasLimit, q.destinationChain
        );
    }

    /// @dev authorization must abi-encode (validAfter, validBefore, nonce, v, r, s)
    ///      signing (from=msg.sender, to=address(this), value=quoted maximum total, ...).
    function publishAndCollectRelayerFeeWithAuthorization(
        bytes calldata payload,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry,
        bytes calldata authorization
    ) external override returns (bytes32 messageId) {
        (
            RelayerTypes.Quote memory q,
            uint256 coreFee,
            bytes32 quoteDigest
        ) = _validateQuote(signedQuote, true);
        if (q.payInNative) revert RelayerErrors.NativePaymentNotSupported();
        _validatePayloadQuote(q, payload, msg.sender);
        _consumeQuote(quoteDigest);

        // EIP-3009 authorizations commit to an exact value. Pull the maximum
        // authorized by the signed quote plus the caller-chosen tip, then
        // return any core-fee headroom after depositing the lower live fee.
        uint256 total = q.coreFee + q.relayPrice + q.acknowledgmentPrice + tip;

        (
            uint256 validAfter,
            uint256 validBefore,
            bytes32 nonce,
            uint8   v,
            bytes32 r,
            bytes32 s
        ) = abi.decode(authorization, (uint256, uint256, bytes32, uint8, bytes32, bytes32));

        IERC3009(address(attestToken)).receiveWithAuthorization(
            msg.sender, address(this), total,
            validAfter, validBefore, nonce, v, r, s
        );

        messageId = outbox.publishMessageFrom(msg.sender, q.acknowledgmentPrice, payload);

        _forwardPublishFees(messageId, msg.sender, coreFee, q.acknowledgmentPrice);
        _depositRelay(messageId, msg.sender, q, tip, tipExpiry);

        uint256 excessCoreFee = q.coreFee - coreFee;
        if (excessCoreFee > 0) {
            attestToken.compatibleTransfer(msg.sender, excessCoreFee);
            emit ExcessCoreFeeRefunded(messageId, msg.sender, excessCoreFee);
        }

        emit FeeCollected(
            messageId, msg.sender,
            q.relayPrice, q.acknowledgmentPrice, tip, tipExpiry,
            q.gasLimit, q.destinationChain
        );
    }

    /// @dev The trusted publisher is the Outbox emitter and quote target; payer
    ///      is recorded in both vaults. The payer signs an exact-value EIP-3009
    ///      authorization whose nonce is scoped to the publisher and quote.
    ///      No tip argument is exposed because a publisher must not be able to
    ///      add a discretionary charge to somebody else's authorization.
    function publishAndCollectRelayerFeeFor(
        address payer,
        bytes calldata payload,
        bytes calldata feeAuthorization
    ) external override onlyTrustedPublisher returns (bytes32 messageId) {
        if (payer == address(0)) revert CommonErrors.ZeroAddress();

        (bytes memory signedQuote, bytes memory authorization) = abi.decode(
            feeAuthorization,
            (bytes, bytes)
        );

        (
            RelayerTypes.Quote memory q,
            uint256 coreFee,
            bytes32 quoteDigest
        ) = _validateQuote(signedQuote, true);
        if (q.payInNative) revert RelayerErrors.NativePaymentNotSupported();
        _validatePayloadQuote(q, payload, msg.sender);
        _consumeQuote(quoteDigest);

        uint256 quotedTotal = q.coreFee + q.relayPrice + q.acknowledgmentPrice;
        (
            uint256 validAfter,
            uint256 validBefore,
            bytes32 nonce,
            uint8 v,
            bytes32 r,
            bytes32 s
        ) = abi.decode(
            authorization,
            (uint256, uint256, bytes32, uint8, bytes32, bytes32)
        );
        bytes32 expectedNonce = publisherAuthorizationNonce(
            payer,
            msg.sender,
            quoteDigest
        );
        if (nonce != expectedNonce) {
            revert RelayerErrors.PublisherAuthorizationNonceMismatch(
                expectedNonce,
                nonce
            );
        }

        IERC3009(address(attestToken)).receiveWithAuthorization(
            payer,
            address(this),
            quotedTotal,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        messageId = outbox.publishMessageFrom(msg.sender, q.acknowledgmentPrice, payload);

        // The quoted acknowledgmentPrice is charged on this route because it is
        // Quoter-signed and inside the quote digest the payer's authorization is
        // scoped to — unlike a tip, it is not a publisher-discretionary charge
        // (which is why no tip argument is exposed).
        _forwardPublishFees(messageId, payer, coreFee, q.acknowledgmentPrice);
        _depositRelay(messageId, payer, q, 0, 0);

        uint256 excessCoreFee = q.coreFee - coreFee;
        if (excessCoreFee > 0) {
            attestToken.compatibleTransfer(payer, excessCoreFee);
            emit ExcessCoreFeeRefunded(messageId, payer, excessCoreFee);
        }

        emit FeeCollected(
            messageId,
            payer,
            q.relayPrice,
            q.acknowledgmentPrice,
            0,
            0,
            q.gasLimit,
            q.destinationChain
        );
    }

    /// @dev Payable for native-denominated quotes (msg.value must equal
    ///      relayPrice + tip); ATTEST quotes must send no value. The quoted
    ///      acknowledgmentPrice is always pulled in ATTEST and routed through
    ///      the Outbox to the AcknowledgmentValidator. Direct publishes carry no
    ///      ack fee (Outbox.publishMessage takes only a fee-free canAck
    ///      flag — the fee is Quoter-priced), so a nonzero price here is the
    ///      message's first ack funding, and it also upgrades a message
    ///      published with canAck = false. Reverts if the message is
    ///      already acknowledged.
    function collectRelayerFee(
        bytes32 messageId,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry
    ) external payable override {
        (RelayerTypes.Quote memory q, , bytes32 quoteDigest) = _validateQuote(signedQuote, false);
        _validateStoredMessageQuote(q, messageId, msg.sender);
        _consumeQuote(quoteDigest);

        uint256 relayTotal = q.relayPrice + tip;
        if (q.payInNative) {
            if (msg.value != relayTotal)
                revert RelayerErrors.InvalidNativeAmount(relayTotal, msg.value);
            if (q.acknowledgmentPrice > 0) {
                attestToken.compatibleTransferFrom(
                    msg.sender, address(this), q.acknowledgmentPrice
                );
            }
        } else {
            if (msg.value != 0)
                revert RelayerErrors.InvalidNativeAmount(0, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender, address(this), relayTotal + q.acknowledgmentPrice
            );
        }

        _routeAckFee(messageId, q.acknowledgmentPrice);
        _depositRelay(messageId, msg.sender, q, tip, tipExpiry);

        emit FeeCollected(
            messageId, msg.sender,
            q.relayPrice, q.acknowledgmentPrice, tip, tipExpiry,
            q.gasLimit, q.destinationChain
        );
    }

    function collectRelayerFeeWithAuthorization(
        bytes32 messageId,
        bytes calldata signedQuote,
        uint256 tip,
        uint256 tipExpiry,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external override {
        (RelayerTypes.Quote memory q, , bytes32 quoteDigest) = _validateQuote(signedQuote, false);
        if (q.payInNative) revert RelayerErrors.NativePaymentNotSupported();
        _validateStoredMessageQuote(q, messageId, msg.sender);
        _consumeQuote(quoteDigest);

        uint256 total = q.relayPrice + q.acknowledgmentPrice + tip;
        IERC3009(address(attestToken)).receiveWithAuthorization(
            msg.sender, address(this), total,
            validAfter, validBefore, nonce, v, r, s
        );

        _routeAckFee(messageId, q.acknowledgmentPrice);
        _depositRelay(messageId, msg.sender, q, tip, tipExpiry);

        emit FeeCollected(
            messageId, msg.sender,
            q.relayPrice, q.acknowledgmentPrice, tip, tipExpiry,
            q.gasLimit, q.destinationChain
        );
    }

    /// @dev Forwards a quoted acknowledgment fee (ATTEST) to the Outbox, which
    ///      routes it to the AcknowledgmentValidator and upgrades the message to
    ///      canAck when it was published without one. No-op when zero.
    function _routeAckFee(bytes32 messageId, uint256 ackFee) internal {
        if (ackFee > 0) {
            attestToken.compatibleTransfer(address(outbox), ackFee);
            outbox.routeAckFee(messageId, msg.sender, ackFee);
        }
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
        // funds pays the relayer proven by the destination event — never the caller.
        (
            ,
            uint256 relayFeePaid,
            uint256 unusedRefunded,
            uint256 tipPaid,
            uint256 tipRefunded
        ) = _settleDelivery(messageId, decoded.gasLimit);

        IRelayerFeeVault vault = _vaultFor(messageId);
        if (relayFeePaid + tipPaid > 0) {
            vault.pay(decoded.relayer, relayFeePaid + tipPaid, info.feesInNative);
        }
        address refundTo = feeRefundTo(messageId);
        if (unusedRefunded + tipRefunded > 0) {
            vault.pay(refundTo, unusedRefunded + tipRefunded, info.feesInNative);
        }

        emit DeliveryClaimed(messageId, decoded.relayer, msg.sender, relayFeePaid, tipPaid);
        if (unusedRefunded > 0) emit UnusedTopUpRefunded(messageId, refundTo, unusedRefunded);
        if (tipRefunded > 0)    emit TipRefunded(messageId, refundTo, tipRefunded);

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
    ///      ATTEST.approve(RelayerContract, additionalATTEST) and no value.
    ///      Quote validation and ledger accounting happen here; the delta lands
    ///      in the vault holding this message's funds.
    function topUpGasLimit(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) external payable override {
        RelayerTypes.TopUpQuote memory q =
            _checkTopUp(messageId, signedTopUpQuote, additionalATTEST);
        _collectDelta(messageId, additionalATTEST);
        uint256 oldGasLimit =
            _applyTopUp(messageId, q.newGasLimit, additionalATTEST);
        emit GasLimitUpdated(messageId, oldGasLimit, q.newGasLimit, additionalATTEST);
    }

    /// @dev EIP-3009 variant (ATTEST-denominated routes only): the authorization
    ///      is signed by the payer to THIS contract (to = RelayerContract), which
    ///      receives the delta and forwards it to the vault — same shape as
    ///      collectRelayerFeeWithAuthorization.
    function topUpGasLimitWithAuthorization(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external override {
        if (_feesInNative(messageId)) revert RelayerErrors.NativePaymentNotSupported();
        RelayerTypes.TopUpQuote memory q =
            _checkTopUp(messageId, signedTopUpQuote, additionalATTEST);
        IERC3009(address(attestToken)).receiveWithAuthorization(
            msg.sender, address(this), additionalATTEST,
            validAfter, validBefore, nonce, v, r, s
        );
        attestToken.compatibleTransfer(address(_vaultFor(messageId)), additionalATTEST);
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

    /// @notice Redirect unused top-up / tip refunds to `recipient` (payer only, once).
    ///         Used by publisher contracts (e.g. ASC bridge) so claimDelivery does
    ///         not leave ATTEST stranded on the publisher.
    function setFeeRefundRecipient(
        bytes32 messageId,
        address recipient
    ) external override {
        _setFeeRefundTo(messageId, recipient);
        emit FeeRefundRecipientSet(messageId, recipient);
    }

    /// @dev Collects an in-flight fee delta (top-up, tip) in the route's fee
    ///      currency: native routes take the exact msg.value and forward it to
    ///      the message's vault; ATTEST routes require no value and pull the
    ///      delta straight into that vault.
    function _collectDelta(bytes32 messageId, uint256 amount) internal {
        if (_feesInNative(messageId)) {
            if (msg.value != amount)
                revert RelayerErrors.InvalidNativeAmount(amount, msg.value);
            _forwardNative(address(_vaultFor(messageId)), amount);
        } else {
            if (msg.value != 0)
                revert RelayerErrors.InvalidNativeAmount(0, msg.value);
            attestToken.compatibleTransferFrom(
                msg.sender,
                address(_vaultFor(messageId)),
                amount
            );
        }
    }

    /// @dev Payer adds tip to an in-flight message, in the route's fee currency:
    ///      native routes send it as msg.value, ATTEST routes require prior
    ///      ATTEST.approve(RelayerContract, additionalTip) and no value.
    function increaseTip(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry
    ) external payable override {
        _validateTipIncrease(messageId, additionalTip, newTipExpiry);
        _collectDelta(messageId, additionalTip);
        _applyTipIncrease(messageId, additionalTip, newTipExpiry);
        emit TipIncreased(messageId, msg.sender, additionalTip, newTipExpiry);
    }

    /// @dev EIP-3009 variant of increaseTip (ATTEST-denominated routes only);
    ///      authorization signed to THIS contract.
    function increaseTipWithAuthorization(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external override {
        if (_feesInNative(messageId)) revert RelayerErrors.NativePaymentNotSupported();
        _validateTipIncrease(messageId, additionalTip, newTipExpiry);
        IERC3009(address(attestToken)).receiveWithAuthorization(
            msg.sender, address(this), additionalTip,
            validAfter, validBefore, nonce, v, r, s
        );
        attestToken.compatibleTransfer(address(_vaultFor(messageId)), additionalTip);
        _applyTipIncrease(messageId, additionalTip, newTipExpiry);
        emit TipIncreased(messageId, msg.sender, additionalTip, newTipExpiry);
    }

    /// @dev Full top-up validation: amount, quote binding, payer, route liveness,
    ///      gas-limit increase, and the Quoter signature over the digest that
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
        if (!quoterContract.isAuthorizedQuoter(signer))
            revert RelayerErrors.UnauthorizedQuoter(signer);
    }

    function _validateTipIncrease(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry
    ) internal view {
        RelayerTypes.MessageInfo memory info = getMessageInfo(messageId);
        if (info.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (info.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);
        if (msg.sender != info.payer) {
            revert RelayerErrors.NotPayer(msg.sender, info.payer);
        }
        if (additionalTip == 0) revert RelayerErrors.ZeroTipIncrease();
        if (newTipExpiry <= info.tipExpiry)
            revert RelayerErrors.TipExpiryNotExtended(messageId, info.tipExpiry, newTipExpiry);
        if (newTipExpiry < block.timestamp + MIN_TIP_WINDOW)
            revert RelayerErrors.TipExpiryTooSoon(newTipExpiry);
        if (newTipExpiry <= info.deliveryDeadline) {
            revert RelayerErrors.TipExpiryNotAfterDeliveryDeadline(
                messageId,
                info.deliveryDeadline,
                newTipExpiry
            );
        }
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
        if (!quoterContract.isAuthorizedQuoter(signer))
            revert RelayerErrors.UnauthorizedQuoter(signer);

        if (usedQuoteDigests[digest]) {
            revert RelayerErrors.QuoteAlreadyUsed(digest);
        }

        if (q.destinationChain > type(uint16).max) {
            revert RelayerErrors.UnsupportedDestinationChain(q.destinationChain);
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

        // Floor in the quote's own currency: native (CTC) quotes against the
        // Quoter's CTC view, ATTEST quotes against its ATTEST view. Assumes
        // source-native is CTC (Creditcoin L1)
        uint256 relayFeeFloor = q.payInNative
            ? quoterContract.requestQuote(
                uint16(q.destinationChain),
                q.targetContract,
                q.payloadHash,
                q.gasLimit
            )
            : quoterContract.requestQuoteInAttest(
                uint16(q.destinationChain),
                q.targetContract,
                q.payloadHash,
                q.gasLimit
            );
        if (q.relayPrice < relayFeeFloor) {
            revert RelayerErrors.RelayFeeBelowFloor(
                q.relayPrice,
                relayFeeFloor
            );
        }

        // A nonzero acknowledgmentPrice IS the acknowledgment request (the
        // Outbox derives canAck from it) and, like the relay fee, must
        // cover the live oracle-updated floor on the Quoter contract. Zero
        // simply means the message requires no acknowledgment — nothing is
        // collected and no floor applies.
        if (q.acknowledgmentPrice != 0) {
            uint256 ackFeeFloor = quoterContract.getAcknowledgmentFee(
                uint16(q.destinationChain)
            );
            if (q.acknowledgmentPrice < ackFeeFloor) {
                revert RelayerErrors.AcknowledgmentFeeBelowFloor(
                    q.acknowledgmentPrice,
                    ackFeeFloor
                );
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

    /// @dev Transfer the relay reward and tip to the active RelayerFeeVault and
    ///      register the deposit. The delivery proof claims relayPrice.
    ///      deliveryDeadline is taken from quote.expectedCompletion.
    function _depositRelay(
        bytes32 messageId,
        address payer,
        RelayerTypes.Quote memory q,
        uint256 tip,
        uint256 tipExpiry
    ) internal {
        if (tip > 0 && tipExpiry < block.timestamp + MIN_TIP_WINDOW) {
            revert RelayerErrors.TipExpiryTooSoon(tipExpiry);
        }
        if (tip > 0 && tipExpiry <= q.expectedCompletion) {
            revert RelayerErrors.TipExpiryNotAfterDeliveryDeadline(
                messageId,
                q.expectedCompletion,
                tipExpiry
            );
        }
        uint32 destinationEvmChainId = destinationEvmChainIds[q.destinationChain];
        if (destinationEvmChainId == 0) {
            revert RelayerErrors.DestinationEvmChainIdNotConfigured(
                q.destinationChain
            );
        }
        uint256 vaultTotal = q.relayPrice + tip;

        IRelayerFeeVault vault = _activeVault();
        _recordDeposit(
            vault,
            messageId,
            payer,
            q.relayPrice,
            tip,
            q.gasLimit,
            q.destinationChain,
            destinationEvmChainId,
            tipExpiry,
            q.expectedCompletion,
            q.payInNative
        );
        if (q.payInNative) {
            _forwardNative(address(vault), vaultTotal);
        } else {
            attestToken.compatibleTransfer(address(vault), vaultTotal);
        }
    }
}
