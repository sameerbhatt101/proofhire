// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IASCProofVerifier} from "./abstract/IASCProofVerifier.sol";
import {BlockProverTypes} from "./common/BlockProverTypes.sol";
import {
    QueryProofVerificationLib
} from "./common/QueryProofVerificationLib.sol";
import {EvmV1Decoder} from "../common/EvmV1Decoder.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";

/// @notice The slice of the Outbox this validator drives. `acknowledgeMessage` is `onlyValidator`,
/// so this contract must be the Outbox's configured `validator`.
interface IAckOutbox {
    function acknowledgeMessage(bytes32 messageId) external;
}

/// @notice Trust-minimized acknowledgment for the ASC write-ability layer (research §05 / §10).
///
/// Delivery infrastructure via the ASC proof system (`IASCProofVerifier` over `BlockProverTypes` inclusion +
/// continuity proofs) — that a `MessageDelivered(bytes32 indexed messageId)` event was emitted in
/// a finalized block on the destination chain. This contract verifies that proof, decodes the
/// `MessageDelivered` logs from the proven transaction, and acknowledges each message on the
/// source Outbox. No attester votes are involved (the attestation chain finalizing the
/// destination block is what makes the proof possible). Because the proof envelope is identical
/// to `claimDelivery`'s, a relayer can drive both settlement paths from the same proof material.
///
/// Deploy/wiring: deploy this with the destination `chainKey` and the shared `ASCProofVerifier`,
/// create the Outbox with this contract as its `validator` (so only it can acknowledge), call
/// `setOutbox` to point it at that Outbox, and `updateTrustedInbox` to allowlist the
/// destination-chain Inbox(es) whose `MessageDelivered` logs are authoritative.
contract AcknowledgmentValidator is Ownable2Step {
    using CompatibleERC20 for IERC20;

    /// `keccak256("MessageDelivered(bytes32,address,address)")` — topic0 of the destination Inbox's
    /// event. `messageId` remains the first indexed arg (topics[1]).
    // Exact event signature text, required for the topic hash.
    bytes32 public constant MESSAGE_DELIVERED_SIG =
        // solhint-disable-next-line gas-small-strings
        keccak256("MessageDelivered(bytes32,address,address)");

    /// Upper bound on the proved transaction bytes (the `txBytes` embedded in
    /// `inclusionProof.data`) accepted by `submitAcknowledgment`, to bound the cost/work of proof
    /// verification and decoding. Submissions above this are rejected.
    uint256 public constant MAX_ENCODED_TRANSACTION_BYTES = 500_000;

    /// Destination chain key whose `MessageDelivered` events this validator proves (the chain the
    /// attestation network attests, and where the Inbox lives).
    uint64 public immutable destinationChainKey;

    /// The source Outbox this validator acknowledges on. Set once after the Outbox is created.
    IAckOutbox public outbox;
    /// Shared ASC proof verifier — the same contract `RelayerFeeVault` uses for claimDelivery.
    IASCProofVerifier public proofVerifier;
    /// Destination-chain Inboxes whose `MessageDelivered` logs are trusted. Logs emitted by any
    /// other contract are ignored — event signatures are not exclusive, so without this check any
    /// destination contract could emit a matching event and forge acknowledgments.
    mapping(address => bool) public trustedInboxes;
    /// @notice Payer refund window for unclaimed ack fees, mirroring the
    ///         AttestorVault refund pattern: after this delay the original payer
    ///         may reclaim a fee no acknowledgment proof has collected. A late
    ///         proof and the refund race for the single settlement.
    uint256 public constant ACK_FEE_REFUND_DELAY = 7 days;

    /// @notice ATTEST token the ack fees are denominated in (user-set fees are
    ///         always ATTEST, routed here by the Outbox).
    IERC20 public immutable attestToken;

    struct AckFeeDeposit {
        address payer;       // original payer, for the refund path
        uint256 amount;      // open ack-fee bounty; zeroed on claim or refund
        uint256 depositedAt; // start of the refund delay
    }

    /// @notice Ack-fee custody: this validator holds each message's user-set
    ///         ackFee (deposited by the Outbox) until whoever proves the
    ///         acknowledgment claims it. It needs no knowledge of the
    ///         RelayerContract or RelayerFeeVault — its only fee peer is the
    ///         Outbox.
    mapping(bytes32 => AckFeeDeposit) public ackFeeDeposits;

    event Acknowledged(bytes32 indexed messageId);
    event OutboxSet(address indexed outbox);
    event ProofVerifierSet(address indexed proofVerifier);
    event TrustedInboxUpdated(address indexed inbox, bool trusted);
    event AckFeeDeposited(bytes32 indexed messageId, address indexed payer, uint256 amount);
    event AckFeeClaimed(bytes32 indexed messageId, address indexed claimant, uint256 amount);
    event AckFeeRefunded(bytes32 indexed messageId, address indexed payer, uint256 amount);

    error NotOutbox();
    error NoAckFee(bytes32 messageId);
    error NotAckFeePayer(address caller, address payer);
    error AckFeeRefundNotAvailable(bytes32 messageId, uint256 availableAt);
    error OutboxAlreadySet();
    error OutboxNotSet();
    error EncodedTransactionTooLarge(uint256 size, uint256 maxSize);
    error UnsupportedTxType(uint8 txType);
    error NoMessageDeliveredLogs();
    error MalformedMessageDeliveredLog();
    error ZeroAddress();

    constructor(
        uint64 _destinationChainKey,
        address _owner,
        address _proofVerifier,
        address _attestToken
    ) Ownable(_owner) {
        if (_proofVerifier == address(0) || _attestToken == address(0)) revert ZeroAddress();
        destinationChainKey = _destinationChainKey;
        proofVerifier = IASCProofVerifier(_proofVerifier);
        attestToken = IERC20(_attestToken);
        emit ProofVerifierSet(_proofVerifier);
    }

    /// @notice Point this validator at the Outbox it acknowledges (one-time; the Outbox must have
    /// been created with this contract as its `validator`).
    function setOutbox(address _outbox) external onlyOwner {
        if (address(outbox) != address(0)) revert OutboxAlreadySet();
        if (_outbox == address(0)) revert ZeroAddress();
        outbox = IAckOutbox(_outbox);
        emit OutboxSet(_outbox);
    }

    /// @notice Swap the proof verifier (mirrors `RelayerFeeVault.setProofVerifier`).
    function setProofVerifier(address _proofVerifier) external onlyOwner {
        if (_proofVerifier == address(0)) revert ZeroAddress();
        proofVerifier = IASCProofVerifier(_proofVerifier);
        emit ProofVerifierSet(_proofVerifier);
    }

    /// @notice Add or remove a destination-chain Inbox whose delivery logs are trusted
    /// (mirrors `Outbox.setTrustedForwarder`). An allowlist rather than a single address so an
    /// Inbox redeployment can be rolled over without a trust gap.
    function updateTrustedInbox(
        address _inbox,
        bool _trusted
    ) external onlyOwner {
        if (_inbox == address(0)) revert ZeroAddress();
        trustedInboxes[_inbox] = _trusted;
        emit TrustedInboxUpdated(_inbox, _trusted);
    }

    /// @notice Records a user-set ack fee for `messageId`. Callable only by the
    /// Outbox, which transferred the ATTEST here first (both for direct
    /// publishes and for fees forwarded by trusted forwarders such as
    /// RelayerContract — this validator never needs to know either). Repeated
    /// deposits accumulate; the first depositor's payer is kept for refunds.
    function depositAckFee(bytes32 messageId, address payer, uint256 amount) external {
        if (msg.sender != address(outbox) || address(outbox) == address(0)) {
            revert NotOutbox();
        }
        AckFeeDeposit storage d = ackFeeDeposits[messageId];
        if (d.payer == address(0)) {
            d.payer = payer;
        }
        d.amount += amount;
        d.depositedAt = block.timestamp;
        emit AckFeeDeposited(messageId, payer, amount);
    }

    /// @notice Original payer reclaims an ack fee that no acknowledgment proof
    /// has collected, once ACK_FEE_REFUND_DELAY has passed since the last
    /// deposit. A late proof and the refund race for the single settlement.
    function refundAckFee(bytes32 messageId) external {
        AckFeeDeposit storage d = ackFeeDeposits[messageId];
        if (d.amount == 0) revert NoAckFee(messageId);
        if (msg.sender != d.payer) revert NotAckFeePayer(msg.sender, d.payer);
        uint256 availableAt = d.depositedAt + ACK_FEE_REFUND_DELAY;
        if (block.timestamp < availableAt) {
            revert AckFeeRefundNotAvailable(messageId, availableAt);
        }

        uint256 amount = d.amount;
        d.amount = 0; // CEI: settle before transfer
        attestToken.compatibleTransfer(d.payer, amount);
        emit AckFeeRefunded(messageId, d.payer, amount);
    }

    /// @notice Prove a destination transaction containing `MessageDelivered` event(s) and acknowledge
    /// each message on the source Outbox. Permissionless — the proof is self-validating.
    /// Takes the same proof envelope as `RelayerFeeVault.claimDelivery`: the encoded transaction
    /// is embedded in `inclusionProof.data` and extracted by the verifier.
    /// @param height Destination block height containing the transaction.
    /// @param inclusionProof BinaryMerkle proof envelope for the tx in the block
    ///        (`data = abi.encode(bytes txBytes, MerkleProofEntry[] siblings)`).
    /// @param continuityProof Continuity proof that the attestation chain finalized the block.
    function submitAcknowledgment(
        uint64 height,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external {
        if (address(outbox) == address(0)) revert OutboxNotSet();

        // Reject oversized submissions up front (cheap check before proof verification/decoding).
        uint256 txSize = QueryProofVerificationLib
            .txBytesFromInclusion(inclusionProof)
            .length;
        if (txSize > MAX_ENCODED_TRANSACTION_BYTES) {
            revert EncodedTransactionTooLarge(
                txSize,
                MAX_ENCODED_TRANSACTION_BYTES
            );
        }

        // 1. Verify the transaction was included in a finalized block of the destination chain.
        //    Reverts inside the verifier on an invalid proof; returns the proved txBytes.
        bytes memory encodedTransaction = proofVerifier.verifyProofs(
            bytes32(uint256(destinationChainKey)),
            height,
            inclusionProof,
            continuityProof
        );

        // 2. Decode the proven transaction's receipt and pull out the MessageDelivered logs.
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        if (!EvmV1Decoder.isValidTransactionType(txType))
            revert UnsupportedTxType(txType);
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder
            .decodeReceiptFields(encodedTransaction);
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder
            .getLogsByEventSignature(receipt, MESSAGE_DELIVERED_SIG);

        // 3. Acknowledge each delivered message on the source Outbox. Only logs emitted by the
        //    trusted Inbox count — a matching signature from any other contract is ignored, since
        //    event signatures are not exclusive. messageId is the first indexed arg (topics[1]) of
        //    MessageDelivered(bytes32 indexed messageId, address indexed processor,
        //    address indexed relayer) — 3 indexed args ⇒ exactly 4 topics. Require the full shape so
        //    the ack path is no weaker than EVMDeliveryDecoder, which also requires all 4.
        uint256 acknowledged;
        for (uint256 i; i < logs.length; ++i) {
            if (!trustedInboxes[logs[i].address_]) continue;
            if (logs[i].topics.length < 4)
                revert MalformedMessageDeliveredLog();
            bytes32 messageId = logs[i].topics[1];
            // Acknowledge per-log, skipping on failure instead of reverting the whole batch. One
            // Inbox serves many Outboxes, so a single proven tx (e.g. a multicall delivery) can
            // carry MessageDelivered logs for messages belonging to different Outboxes, plus
            // already-acked or no-ack-required ones. A bare call would revert the entire
            // submission on the first MessageAlreadyAcknowledged / MessageNotFound /
            // MessageCannotBeAcknowledged, making a victim message's ack permanently unreachable
            // (the bundled claimDelivery path can't ack a multicall-delivered message either).
            // The ack-fee claim and the counter only advance on a genuine ack, so nothing is
            // paid or counted for a skipped log.
            try outbox.acknowledgeMessage(messageId) {
                emit Acknowledged(messageId);
                // Open claim: the submitter (anyone with a valid proof) earns the
                // ack fee held here. Zero-fee messages simply pay nothing.
                AckFeeDeposit storage d = ackFeeDeposits[messageId];
                uint256 fee = d.amount;
                if (fee > 0) {
                    d.amount = 0; // CEI: settle before transfer
                    attestToken.compatibleTransfer(msg.sender, fee);
                    emit AckFeeClaimed(messageId, msg.sender, fee);
                }
                unchecked {
                    acknowledged++;
                }
            } catch {
                continue;
            }
        }
        if (acknowledged == 0) revert NoMessageDeliveredLogs();
    }
}
