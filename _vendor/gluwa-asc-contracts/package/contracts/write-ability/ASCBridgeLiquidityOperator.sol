// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IASCBridgeLiquidityOperator} from "./abstract/IASCBridgeLiquidityOperator.sol";
import {IERC20Burnable} from "./abstract/IERC20MintBurn.sol";
import {IOutbox} from "./abstract/IOutbox.sol";
import {IRelayerContract} from "./abstract/IRelayerContract.sol";
import {IAttestorVault} from "./abstract/IAttestorVault.sol";
import {IASCProofVerifier} from "./abstract/IASCProofVerifier.sol";
import {IBridgeIntentDecoder} from "./abstract/IBridgeIntentDecoder.sol";
import {IASCBridgeTokenDestination} from "./abstract/IASCBridgeTokenDestination.sol";
import {BridgeMessageCodecV1} from "./common/BridgeMessageCodecV1.sol";
import {BlockProverTypes} from "./common/BlockProverTypes.sol";
import {CrossChainOrderTypes} from "./common/CrossChainOrderTypes.sol";
import {RelayerTypes} from "./common/RelayerTypes.sol";
import {ASCBridgeTypes} from "./common/ASCBridgeTypes.sol";
import {ASCBridgeLiquidityOperatorErrors} from "./error/ASCBridgeLiquidityOperatorErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";
import {CanonicalTokenCall} from "./common/CanonicalTokenCall.sol";
import {TokenAmountNormalization} from "./common/TokenAmountNormalization.sol";
import {TokenExecutionCommitment} from "./common/TokenExecutionCommitment.sol";

interface IRelayerAttestToken {
    function attestToken() external view returns (address);
}

/// @dev Ack-fee refund surface on AcknowledgmentValidator (and test mocks).
interface IAckFeeRefund {
    function refundAckFee(bytes32 messageId) external;
}

contract ASCBridgeLiquidityOperator is
    IASCBridgeLiquidityOperator,
    Ownable2Step
{
    using CompatibleERC20 for IERC20;

    /// @dev Per-chain outbound transport configuration on Creditcoin.
    struct ChainConfig {
        IOutbox outbox;
        bool enabled;
        IRelayerContract relayerContract;
    }

    /// @dev Decimal-domain binding for a token arriving from a configured
    ///      source route. Destination amounts are denominated in the local ASC
    ///      token's precision and must not exceed the normalized source amount.
    struct InboundTokenRoute {
        address sourceToken;
        uint8 sourceDecimals;
        uint8 destinationDecimals;
        bool enabled;
    }

    /// @dev Decimal-domain binding for the immutable Creditcoin token sent to
    ///      one client route. Outbound amounts must be exactly representable in
    ///      the destination precision before any token is escrowed or burned.
    struct OutboundTokenRoute {
        address destinationToken;
        uint8 sourceDecimals;
        uint8 destinationDecimals;
        bool enabled;
        uint64 minimumGasLimit;
    }

    uint8 private constant _INTENT_NONE = 0;
    uint8 private constant _INTENT_IN_FLIGHT = 1;
    uint8 private constant _INTENT_PROCESSED = 2;

    event ChainConfigSet(
        bytes32 indexed chainKey,
        address indexed outbox,
        bool enabled
    );
    event BridgeMessagePublished(
        bytes32 indexed intentId,
        bytes32 indexed messageId,
        bytes32 indexed chainKey
    );
    /// @notice Records the user who funded Relayer fees for `messageId`.
    ///         Relayer still sees this bridge as on-chain payer; the user
    ///         recovers fees through the wrappers below.
    event OutboundFeePayerRecorded(
        bytes32 indexed messageId,
        address indexed payer,
        address indexed relayer
    );
    event RelayerRefundForwarded(
        bytes32 indexed messageId,
        address indexed payer,
        uint256 amount
    );
    event CoreFeeRefundForwarded(
        bytes32 indexed messageId,
        address indexed payer,
        uint256 amount
    );
    event AckFeeRefundForwarded(
        bytes32 indexed messageId,
        address indexed payer,
        uint256 amount
    );
    event ChainConfigRemoved(bytes32 indexed chainKey);
    event ChainRelayerSet(
        bytes32 indexed chainKey,
        address indexed relayerContract
    );
    event SourceEvmChainIdSet(
        bytes32 indexed chainKey,
        uint256 indexed sourceEvmChainId
    );
    event InboundTokenRouteSet(
        bytes32 indexed chainKey,
        address indexed sourceToken,
        uint8 sourceDecimals,
        uint8 destinationDecimals,
        bool enabled
    );
    event OutboundTokenRouteSet(
        bytes32 indexed chainKey,
        address indexed destinationToken,
        uint8 sourceDecimals,
        uint8 destinationDecimals,
        uint256 minimumGasLimit,
        bool enabled
    );
    event ProofVerifierSet(address indexed verifier);
    event BridgeIntentDecoderSet(address indexed decoder);
    event MintDestinationSet(address indexed destination);
    event RemoteClientOperatorSet(
        bytes32 indexed chainKey,
        address indexed clientOperator
    );
    event BridgeIntentExecutionTracked(
        bytes32 indexed intentId,
        bool success,
        uint256 gasUsed,
        bytes32 returnedDataHash
    );

    IERC20 public immutable token;
    uint8 public immutable tokenDecimals;
    bool public immutable isHubAndSpoke;
    bool public immutable isCreditcoinHub;

    /// @notice Per-sender outbound nonce used for intentId / payloadHash quoting.
    ///         Avoids cross-user quote races from a single global counter.
    mapping(address => uint256) public intentNonces;

    /// @dev Relayer records this bridge as fee payer. Map messageId → the user
    ///      who actually funded ATTEST so they can refund / top-up / tip.
    ///      Per-component flags keep the record alive across staggered refund
    ///      deadlines (relay vs 7-day core/ack).
    ///      `attestorVault` / `ackFeeSink` are snapshotted at publish so later
    ///      Outbox.setAttestorVault / setValidator rotations cannot strand fees.
    struct OutboundFeeRecord {
        address payer;
        address relayer;
        address attestorVault;
        address ackFeeSink;
        bool relayerRefunded;
        bool coreRefunded;
        bool ackRefunded;
    }
    mapping(bytes32 => OutboundFeeRecord) public outboundFeeRecords;

    mapping(bytes32 => ChainConfig) private _chainConfigs;
    /// @notice Maps a native-prover/Outbox chain key to the EVM chain ID encoded
    ///         in transactions proved for that route (for example, 1 => 11155111).
    mapping(bytes32 => uint256) public sourceEvmChainIds;
    /// @notice Paired destination `IMessageReceiver` on the route identified by `chainKey`
    ///         (outbound hub `bridgeTo` receive side — not `ASCBridgeMintDestination`).
    mapping(bytes32 => address) public remoteClientOperators;
    mapping(bytes32 => InboundTokenRoute) public inboundTokenRoutes;
    mapping(bytes32 => OutboundTokenRoute) private _outboundTokenRoutes;
    mapping(bytes32 => uint8) private _intentStatus;

    IASCProofVerifier public proofVerifier;
    IBridgeIntentDecoder public bridgeIntentDecoder;
    address public mintDestination;
    /// @notice Used when the wired Outbox has no `attestorVault()` getter (older hubs).
    address public fallbackAttestorVault;

    /// @dev Token-bearing messages carry a route/execution commitment.
    enum OutboundMessageKind { PayloadOnly, TokenOperation }

    /// @param tokenAddress_ ERC20 token managed by this bridge operator.
    /// @param isHubAndSpoke_ True for lock/unlock model, false for burn/mint model.
    /// @param isCreditcoinHub_ True if Creditcoin is the lock/unlock hub.
    /// @param initialOwner_ Contract owner with admin permissions.
    constructor(
        address tokenAddress_,
        bool isHubAndSpoke_,
        bool isCreditcoinHub_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (tokenAddress_ == address(0) || initialOwner_ == address(0)) {
            revert CommonErrors.ZeroAddress();
        }

        token = IERC20(tokenAddress_);
        tokenDecimals = IERC20Metadata(tokenAddress_).decimals();
        isHubAndSpoke = isHubAndSpoke_;
        isCreditcoinHub = isCreditcoinHub_;
    }

    /// @notice True when the intent has completed successfully.
    function processedIntentIds(bytes32 intentId) external view returns (bool) {
        return _intentStatus[intentId] == _INTENT_PROCESSED;
    }

    /// @notice True while the intent's destination call is in progress.
    function inFlightIntentIds(bytes32 intentId) external view returns (bool) {
        return _intentStatus[intentId] == _INTENT_IN_FLIGHT;
    }

    /// @notice Outbound route view with `minimumGasLimit` widened to uint256.
    function outboundTokenRoutes(
        bytes32 chainKey
    )
        external
        view
        returns (
            address destinationToken,
            uint8 sourceDecimals,
            uint8 destinationDecimals,
            bool enabled,
            uint256 minimumGasLimit
        )
    {
        OutboundTokenRoute storage route = _outboundTokenRoutes[chainKey];
        return (
            route.destinationToken,
            route.sourceDecimals,
            route.destinationDecimals,
            route.enabled,
            route.minimumGasLimit
        );
    }

    /// @notice Sets outbound chain configuration used by `bridgeTo`.
    /// @dev `chainKey` must encode the same uint32 as `IOutbox(outbox).chainKey()`.
    ///      Changing the Outbox revokes any previous Relayer forwarder approval on
    ///      the old Outbox so a rotated/compromised Relayer cannot keep publishing.
    function setChainConfig(
        bytes32 chainKey,
        address outbox,
        bool enabled
    ) external onlyOwner {
        if (outbox == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        _requireOutboxChainKey(chainKey, IOutbox(outbox));

        ChainConfig memory existing = _chainConfigs[chainKey];
        if (
            address(existing.outbox) != address(0) &&
            address(existing.outbox) != outbox &&
            address(existing.relayerContract) != address(0)
        ) {
            existing.outbox.approveForwarder(
                address(existing.relayerContract),
                false
            );
        }
        IRelayerContract configuredRelayer = address(existing.outbox) == outbox
            ? existing.relayerContract
            : IRelayerContract(address(0));
        _chainConfigs[chainKey] = ChainConfig({
            outbox: IOutbox(outbox),
            enabled: enabled,
            relayerContract: configuredRelayer
        });
        emit ChainConfigSet(chainKey, outbox, enabled);
    }

    /// @notice Configures the fee-escrow/publish path for an outbound route.
    /// @dev The RelayerContract is immutable-bound to an Outbox. Check that
    ///      binding here and again during bridgeTo so a bad route fails closed.
    ///      Also approves the Relayer as this contract's Outbox forwarder so
    ///      publishMessageFrom(emitter=this) succeeds. Relayer must have a
    ///      non-zero `destinationEvmChainIds(outbox.chainKey())`.
    ///      A previous Relayer is revoked so it cannot keep publishing as this
    ///      bridge after rotation.
    function setChainRelayer(
        bytes32 chainKey,
        address relayerContract_
    ) external onlyOwner {
        ChainConfig storage config = _chainConfigs[chainKey];
        if (address(config.outbox) == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyNotConfigured(
                chainKey
            );
        }
        if (relayerContract_ == address(0)) {
            revert CommonErrors.ZeroAddress();
        }

        IRelayerContract candidate = IRelayerContract(relayerContract_);
        address actualOutbox = address(candidate.outbox());
        if (actualOutbox != address(config.outbox)) {
            revert ASCBridgeLiquidityOperatorErrors.RelayerOutboxMismatch(
                address(config.outbox),
                actualOutbox
            );
        }
        _requireRelayerDestination(candidate, config.outbox.chainKey());

        address previous = address(config.relayerContract);
        if (previous != address(0) && previous != relayerContract_) {
            config.outbox.approveForwarder(previous, false);
        }
        config.relayerContract = candidate;
        config.outbox.approveForwarder(relayerContract_, true);
        emit ChainRelayerSet(chainKey, relayerContract_);
    }

    /// @notice Records the paired client-chain bridge / Inbox dispatcher for a route.
    function setRemoteClientOperator(
        bytes32 chainKey,
        address clientOperator
    ) external onlyOwner {
        if (address(_chainConfigs[chainKey].outbox) == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyNotConfigured(
                chainKey
            );
        }
        if (clientOperator == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        remoteClientOperators[chainKey] = clientOperator;
        emit RemoteClientOperatorSet(chainKey, clientOperator);
    }

    function removeChainConfig(bytes32 chainKey) external onlyOwner {
        ChainConfig memory config = _chainConfigs[chainKey];
        if (
            address(config.outbox) != address(0) &&
            address(config.relayerContract) != address(0)
        ) {
            config.outbox.approveForwarder(
                address(config.relayerContract),
                false
            );
        }
        delete _chainConfigs[chainKey];
        delete remoteClientOperators[chainKey];
        emit ChainConfigRemoved(chainKey);
    }

    /// @notice Binds a prover/Outbox chain key to the EVM transaction chain ID
    ///         expected in inbound proofs. Set this before enabling inbound minting.
    function setSourceEvmChainId(
        bytes32 chainKey,
        uint256 sourceEvmChainId
    ) external onlyOwner {
        if (sourceEvmChainId == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidSourceEvmChainId();
        }
        sourceEvmChainIds[chainKey] = sourceEvmChainId;
        emit SourceEvmChainIdSet(chainKey, sourceEvmChainId);
    }

    /// @notice Binds a source route to its token and decimal domains.
    /// @dev Source token and decimal fields are immutable after the first
    ///      configuration so delayed proofs cannot be remapped to a different
    ///      scale or token. Only `enabled` remains adjustable.
    function setInboundTokenRoute(
        bytes32 chainKey,
        address sourceToken,
        uint8 sourceDecimals,
        uint8 destinationDecimals,
        bool enabled
    ) external onlyOwner {
        if (sourceToken == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        if (sourceDecimals > 77 || destinationDecimals > 77) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidTokenDecimals();
        }
        uint8 actualDestinationDecimals = tokenDecimals;
        if (destinationDecimals != actualDestinationDecimals) {
            revert ASCBridgeLiquidityOperatorErrors.DestinationDecimalsMismatch(
                actualDestinationDecimals,
                destinationDecimals
            );
        }

        InboundTokenRoute storage route = inboundTokenRoutes[chainKey];
        if (route.sourceToken != address(0)) {
            if (
                route.sourceToken != sourceToken ||
                route.sourceDecimals != sourceDecimals ||
                route.destinationDecimals != destinationDecimals
            ) {
                revert ASCBridgeLiquidityOperatorErrors.InboundTokenRouteImmutable(
                    chainKey
                );
            }
            route.enabled = enabled;
        } else {
            inboundTokenRoutes[chainKey] = InboundTokenRoute({
                sourceToken: sourceToken,
                sourceDecimals: sourceDecimals,
                destinationDecimals: destinationDecimals,
                enabled: enabled
            });
        }
        emit InboundTokenRouteSet(
            chainKey,
            sourceToken,
            sourceDecimals,
            destinationDecimals,
            enabled
        );
    }

    /// @notice Binds one outbound route to the paired destination token and
    ///         decimal domains used by the client operator.
    /// @dev Destination token and decimal fields are immutable after the first
    ///      configuration. Minimum gas and enabled status remain adjustable.
    function setOutboundTokenRoute(
        bytes32 chainKey,
        address destinationToken,
        uint8 sourceDecimals,
        uint8 destinationDecimals,
        uint256 minimumGasLimit,
        bool enabled
    ) external onlyOwner {
        if (address(_chainConfigs[chainKey].outbox) == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyNotConfigured(
                chainKey
            );
        }
        if (destinationToken == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        if (sourceDecimals > 77 || destinationDecimals > 77) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidTokenDecimals();
        }
        if (minimumGasLimit == 0 || minimumGasLimit > type(uint64).max) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidGasLimit();
        }

        OutboundTokenRoute storage route = _outboundTokenRoutes[chainKey];
        if (route.minimumGasLimit != 0) {
            if (
                route.destinationToken != destinationToken ||
                route.sourceDecimals != sourceDecimals ||
                route.destinationDecimals != destinationDecimals
            ) {
                revert ASCBridgeLiquidityOperatorErrors.OutboundTokenRouteImmutable(
                    chainKey
                );
            }
            route.enabled = enabled;
            route.minimumGasLimit = uint64(minimumGasLimit);
        } else {
            uint8 actualSourceDecimals = tokenDecimals;
            if (sourceDecimals != actualSourceDecimals) {
                revert ASCBridgeLiquidityOperatorErrors.SourceDecimalsMismatch(
                    actualSourceDecimals,
                    sourceDecimals
                );
            }
            _outboundTokenRoutes[chainKey] = OutboundTokenRoute({
                destinationToken: destinationToken,
                sourceDecimals: sourceDecimals,
                destinationDecimals: destinationDecimals,
                enabled: enabled,
                minimumGasLimit: uint64(minimumGasLimit)
            });
        }
        emit OutboundTokenRouteSet(
            chainKey,
            destinationToken,
            sourceDecimals,
            destinationDecimals,
            minimumGasLimit,
            enabled
        );
    }

    function getChainConfig(
        bytes32 chainKey
    ) external view returns (address outbox, bool enabled) {
        ChainConfig memory config = _chainConfigs[chainKey];
        return (address(config.outbox), config.enabled);
    }

    function getChainRelayer(
        bytes32 chainKey
    ) external view returns (address relayerContract_) {
        return address(_chainConfigs[chainKey].relayerContract);
    }

    function setProofVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        proofVerifier = IASCProofVerifier(verifier);
        emit ProofVerifierSet(verifier);
    }

    function setBridgeIntentDecoder(address decoder) external onlyOwner {
        if (decoder == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        bridgeIntentDecoder = IBridgeIntentDecoder(decoder);
        emit BridgeIntentDecoderSet(decoder);
    }

    /// @notice Binds (or rebinds) the durable destination used for inbound mint execution.
    /// @dev Mutable to stay aligned with `ASCBridgeMintDestination.setBridgeOperator`.
    ///      Replay protection lives on the destination (`processedIntentIds`), so
    ///      rebinding here does not clear that domain. Destination must still
    ///      point `bridgeOperator` back at this contract and allow `token`.
    function setMintDestination(address destination) external onlyOwner {
        if (destination == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        if (destination == mintDestination) {
            return;
        }
        _requireCompatibleMintDestination(destination);
        mintDestination = destination;
        emit MintDestinationSet(destination);
    }

    /// @notice Initiates Creditcoin -> client-chain bridge by publishing through Outbox.
    /// @dev The outbound payload uses canonical V1 codec format.
    function bridgeTo(
        bytes32 chainKey,
        ASCBridgeTypes.BridgeMessage calldata message,
        bytes calldata quote
    ) external payable override {
        if (msg.value != 0) {
            revert ASCBridgeLiquidityOperatorErrors.NativeValueUnsupported(
                msg.value
            );
        }
        ChainConfig memory config = _chainConfigs[chainKey];
        uint32 outboxChainKey = _requireOutboundPublishReady(chainKey, config);
        (
            bool hasTokenTransfer,
            ASCBridgeTypes.BridgeMessage memory outboundMessage
        ) = _validatedOutboundMessage(chainKey, message);

        (
            bytes memory signedQuote,
            uint256 tip,
            uint256 tipExpiry
        ) = abi.decode(quote, (bytes, uint256, uint256));
        RelayerTypes.Quote memory q = abi.decode(
            signedQuote,
            (RelayerTypes.Quote)
        );
        if (q.payInNative) {
            revert ASCBridgeLiquidityOperatorErrors.NativeQuoteUnsupported();
        }
        if (q.destinationChain != outboxChainKey) {
            revert ASCBridgeLiquidityOperatorErrors.QuoteDestinationMismatch(
                outboxChainKey,
                q.destinationChain
            );
        }
        if (q.gasLimit < outboundMessage.gasLimit) {
            revert ASCBridgeLiquidityOperatorErrors.QuoteGasLimitTooLow(
                q.gasLimit,
                outboundMessage.gasLimit
            );
        }

        uint256 nonce = intentNonces[msg.sender];
        (bytes32 intentId, bytes memory encodedPayload) = _outboundPayload(
            msg.sender,
            chainKey,
            outboundMessage,
            nonce,
            hasTokenTransfer
        );

        // Effects precede external calls. A downstream revert rolls the nonce
        // and token movement back atomically.
        intentNonces[msg.sender] = nonce + 1;
        if (hasTokenTransfer) {
            token.compatibleTransferFrom(
                msg.sender,
                address(this),
                outboundMessage.tokenAmount.amount
            );
            if (!_usesCreditcoinEscrow()) {
                IERC20Burnable(address(token)).burn(
                    outboundMessage.tokenAmount.amount
                );
            }
        }

        // Devnet ATTEST is approve/transferFrom only (no EIP-3009). Quoted
        // coreFee is a ceiling; unused ATTEST from this call is refunded below.
        // Tip is forwarded only when the configured Relayer supports tips
        // (RelayerContract); RelayerContractLite has no tip path and will revert.
        uint256 total = q.coreFee + q.relayPrice + q.acknowledgmentPrice + tip;
        IERC20 attest = IERC20(
            IRelayerAttestToken(address(config.relayerContract)).attestToken()
        );
        uint256 attestBalanceBefore = attest.balanceOf(address(this));
        attest.compatibleTransferFrom(msg.sender, address(this), total);
        address relayerAddr = address(config.relayerContract);
        if (attest.allowance(address(this), relayerAddr) != 0) {
            _compatibleApprove(attest, relayerAddr, 0);
        }
        _compatibleApprove(attest, relayerAddr, total);

        bytes32 messageId = config.relayerContract.publishAndCollectRelayerFee(
            encodedPayload,
            signedQuote,
            tip,
            tipExpiry
        );
        // Redirect claimDelivery / deadline tip+top-up refunds to the user.
        // Older Relayers without this API are skipped (try/catch).
        try config.relayerContract.setFeeRefundRecipient(messageId, msg.sender) {
        } catch {}

        if (attest.allowance(address(this), relayerAddr) != 0) {
            _compatibleApprove(attest, relayerAddr, 0);
        }
        uint256 leftover = attest.balanceOf(address(this)) - attestBalanceBefore;
        if (leftover > 0) {
            attest.compatibleTransfer(msg.sender, leftover);
        }

        // Relayer stores this contract as payer; remember the user and the
        // fee custodians used for this publish so later Outbox rotations cannot
        // redirect refunds away from the escrows that hold the ATTEST.
        IOutbox publishedOutbox = config.outbox;
        outboundFeeRecords[messageId] = OutboundFeeRecord({
            payer: msg.sender,
            relayer: relayerAddr,
            attestorVault: _snapshotAttestorVault(publishedOutbox),
            ackFeeSink: publishedOutbox.validator(),
            relayerRefunded: false,
            coreRefunded: false,
            ackRefunded: false
        });
        emit OutboundFeePayerRecorded(messageId, msg.sender, relayerAddr);
        emit BridgeIntent(intentId, chainKey, outboundMessage);
        emit BridgeMessagePublished(intentId, messageId, chainKey);
    }

    /// @notice Sets the vault used when Outbox.attestorVault() is missing/reverts.
    function setFallbackAttestorVault(address vault) external onlyOwner {
        if (vault == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        fallbackAttestorVault = vault;
    }

    function _snapshotAttestorVault(
        IOutbox publishedOutbox
    ) internal view returns (address vault) {
        try publishedOutbox.attestorVault() returns (address fromOutbox) {
            if (fromOutbox != address(0)) {
                return fromOutbox;
            }
        } catch {}
        vault = fallbackAttestorVault;
        if (vault == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
    }

    /// @notice User-facing Relayer refund; forwards ATTEST to the fee payer when
    ///         the Relayer still pays this operator. If `setFeeRefundRecipient`
    ///         pointed refunds at the user, the Relayer pays them directly and
    ///         `received` here is zero.
    function requestRelayerRefund(bytes32 messageId) external override {
        (
            IRelayerContract relayer,
            address payer,
            IERC20 attest
        ) = _requireOutboundFeePayer(messageId);
        if (msg.sender != payer) {
            revert ASCBridgeLiquidityOperatorErrors.NotOutboundFeePayer(
                msg.sender,
                payer
            );
        }
        OutboundFeeRecord storage record = outboundFeeRecords[messageId];
        if (record.relayerRefunded) {
            revert ASCBridgeLiquidityOperatorErrors
                .OutboundFeeComponentAlreadyRefunded(messageId);
        }

        uint256 balanceBefore = attest.balanceOf(address(this));
        relayer.requestRefund(messageId);
        uint256 received = attest.balanceOf(address(this)) - balanceBefore;
        record.relayerRefunded = true;
        if (received > 0) {
            attest.compatibleTransfer(payer, received);
        }
        emit RelayerRefundForwarded(messageId, payer, received);
    }

    /// @notice User-facing AttestorVault core-fee refund; forwards ATTEST to payer.
    /// @dev Uses the vault address snapshotted at publish, not the live Outbox
    ///      attestorVault, so setAttestorVault after publish cannot strand funds.
    function requestCoreFeeRefund(bytes32 messageId) external override {
        (, address payer, IERC20 attest) = _requireOutboundFeePayer(messageId);
        if (msg.sender != payer) {
            revert ASCBridgeLiquidityOperatorErrors.NotOutboundFeePayer(
                msg.sender,
                payer
            );
        }
        OutboundFeeRecord storage record = outboundFeeRecords[messageId];
        if (record.coreRefunded) {
            revert ASCBridgeLiquidityOperatorErrors
                .OutboundFeeComponentAlreadyRefunded(messageId);
        }
        if (record.attestorVault == address(0)) {
            revert CommonErrors.ZeroAddress();
        }

        IAttestorVault vault = IAttestorVault(record.attestorVault);
        uint256 balanceBefore = attest.balanceOf(address(this));
        vault.refund(messageId);
        uint256 received = attest.balanceOf(address(this)) - balanceBefore;
        record.coreRefunded = true;
        if (received > 0) {
            attest.compatibleTransfer(payer, received);
        }
        emit CoreFeeRefundForwarded(messageId, payer, received);
    }

    /// @notice User-facing ack-fee refund; forwards ATTEST to the fee payer.
    /// @dev Uses the ack sink snapshotted at publish, not the live Outbox
    ///      validator, so setValidator after publish cannot strand funds.
    function requestAckFeeRefund(bytes32 messageId) external override {
        (, address payer, IERC20 attest) = _requireOutboundFeePayer(messageId);
        if (msg.sender != payer) {
            revert ASCBridgeLiquidityOperatorErrors.NotOutboundFeePayer(
                msg.sender,
                payer
            );
        }
        OutboundFeeRecord storage record = outboundFeeRecords[messageId];
        if (record.ackRefunded) {
            revert ASCBridgeLiquidityOperatorErrors
                .OutboundFeeComponentAlreadyRefunded(messageId);
        }
        if (record.ackFeeSink == address(0)) {
            revert CommonErrors.ZeroAddress();
        }

        IAckFeeRefund ackSink = IAckFeeRefund(record.ackFeeSink);
        uint256 balanceBefore = attest.balanceOf(address(this));
        ackSink.refundAckFee(messageId);
        uint256 received = attest.balanceOf(address(this)) - balanceBefore;
        record.ackRefunded = true;
        if (received > 0) {
            attest.compatibleTransfer(payer, received);
        }
        emit AckFeeRefundForwarded(messageId, payer, received);
    }

    /// @notice User-facing gas top-up for a stuck outbound message.
    function topUpRelayerGasLimit(
        bytes32 messageId,
        bytes calldata signedTopUpQuote,
        uint256 additionalATTEST
    ) external override {
        if (additionalATTEST == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidRelayerFeeAmount();
        }
        (
            IRelayerContract relayer,
            address payer,
            IERC20 attest
        ) = _requireOutboundFeePayer(messageId);
        if (msg.sender != payer) {
            revert ASCBridgeLiquidityOperatorErrors.NotOutboundFeePayer(
                msg.sender,
                payer
            );
        }

        attest.compatibleTransferFrom(msg.sender, address(this), additionalATTEST);
        address relayerAddr = address(relayer);
        if (attest.allowance(address(this), relayerAddr) != 0) {
            _compatibleApprove(attest, relayerAddr, 0);
        }
        _compatibleApprove(attest, relayerAddr, additionalATTEST);
        relayer.topUpGasLimit(messageId, signedTopUpQuote, additionalATTEST);
        if (attest.allowance(address(this), relayerAddr) != 0) {
            _compatibleApprove(attest, relayerAddr, 0);
        }
    }

    /// @notice User-facing tip increase. Requires a tip-capable Relayer.
    function increaseRelayerTip(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry
    ) external override {
        if (additionalTip == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidRelayerFeeAmount();
        }
        (
            IRelayerContract relayer,
            address payer,
            IERC20 attest
        ) = _requireOutboundFeePayer(messageId);
        if (msg.sender != payer) {
            revert ASCBridgeLiquidityOperatorErrors.NotOutboundFeePayer(
                msg.sender,
                payer
            );
        }

        attest.compatibleTransferFrom(msg.sender, address(this), additionalTip);
        address relayerAddr = address(relayer);
        if (attest.allowance(address(this), relayerAddr) != 0) {
            _compatibleApprove(attest, relayerAddr, 0);
        }
        _compatibleApprove(attest, relayerAddr, additionalTip);
        relayer.increaseTip(messageId, additionalTip, newTipExpiry);
        if (attest.allowance(address(this), relayerAddr) != 0) {
            _compatibleApprove(attest, relayerAddr, 0);
        }
    }

    /// @notice Returns the next outbound payload and hash for quote construction.
    /// @dev Uses `intentNonces[sender]` so concurrent users do not invalidate
    ///      each other's quotes. Only that sender's later `bridgeTo` advances it.
    function previewBridgePayload(
        address sender,
        bytes32 chainKey,
        ASCBridgeTypes.BridgeMessage calldata message
    ) external view override returns (
        uint256 nonce,
        bytes32 intentId,
        bytes memory payload,
        bytes32 payloadHash
    ) {
        if (sender == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        (
            bool hasTokenTransfer,
            ASCBridgeTypes.BridgeMessage memory outboundMessage
        ) = _validatedOutboundMessage(chainKey, message);
        nonce = intentNonces[sender];
        (intentId, payload) = _outboundPayload(
            sender,
            chainKey,
            outboundMessage,
            nonce,
            hasTokenTransfer
        );
        payloadHash = keccak256(payload);
    }

    function _validatedOutboundMessage(
        bytes32 chainKey,
        ASCBridgeTypes.BridgeMessage calldata message
    ) internal view returns (
        bool hasTokenTransfer,
        ASCBridgeTypes.BridgeMessage memory outboundMessage
    ) {
        address receiver = _validateOutboundReceiver(message.receiver);
        hasTokenTransfer = _hasTokenTransfer(message.tokenAmount);
        bool hasExecutionPayload = message.data.length != 0;
        if (!hasTokenTransfer && !hasExecutionPayload) {
            revert ASCBridgeLiquidityOperatorErrors.EmptyBridgeMessage();
        }
        if (message.gasLimit == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidGasLimit();
        }
        if (!hasTokenTransfer) {
            outboundMessage = message;
            return (false, outboundMessage);
        }

        OutboundTokenRoute memory route = _outboundTokenRoutes[chainKey];
        uint256 destinationAmount = _normalizedOutboundAmount(
            chainKey,
            message.tokenAmount.amount,
            route
        );
        _validateOutboundTokenCallData(
            message.data,
            receiver,
            destinationAmount
        );
        bytes memory executionCommitment = abi.encode(
            _outboundTokenExecutionCommitment(
                message,
                receiver,
                destinationAmount,
                route
            )
        );
        outboundMessage = ASCBridgeTypes.BridgeMessage({
            receiver: message.receiver,
            data: executionCommitment,
            tokenAmount: message.tokenAmount,
            gasLimit: message.gasLimit
        });
        _validateOutboundGasLimit(message.gasLimit, route.minimumGasLimit);
        return (true, outboundMessage);
    }

    function _outboundPayload(
        address sender,
        bytes32 chainKey,
        ASCBridgeTypes.BridgeMessage memory message,
        uint256 nonce,
        bool hasTokenTransfer
    ) internal pure returns (bytes32 intentId, bytes memory encodedPayload) {
        uint8 msgType = _deriveOutboundMsgType(
            hasTokenTransfer
        );
        intentId = keccak256(
            abi.encodePacked(msgType, nonce, chainKey, sender)
        );
        BridgeMessageCodecV1.BridgePayloadV1 memory payload = BridgeMessageCodecV1
            .BridgePayloadV1({intentId: intentId, message: message});
        encodedPayload = BridgeMessageCodecV1.encode(payload);
    }

    function _requireOutboundFeePayer(
        bytes32 messageId
    )
        internal
        view
        returns (IRelayerContract relayer, address payer, IERC20 attest)
    {
        OutboundFeeRecord memory record = outboundFeeRecords[messageId];
        if (record.payer == address(0) || record.relayer == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.UnknownOutboundMessage(
                messageId
            );
        }
        relayer = IRelayerContract(record.relayer);
        payer = record.payer;
        attest = IERC20(IRelayerAttestToken(record.relayer).attestToken());
    }

    function _requireOutboundPublishReady(
        bytes32 chainKey,
        ChainConfig memory config
    ) internal view returns (uint32 outboxChainKey) {
        if (address(config.outbox) == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyNotConfigured(
                chainKey
            );
        }
        if (!config.enabled) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyDisabled(chainKey);
        }
        if (address(config.relayerContract) == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.ChainRelayerNotConfigured(
                chainKey
            );
        }
        address actualOutbox = address(config.relayerContract.outbox());
        if (actualOutbox != address(config.outbox)) {
            revert ASCBridgeLiquidityOperatorErrors.RelayerOutboxMismatch(
                address(config.outbox),
                actualOutbox
            );
        }
        outboxChainKey = _requireOutboxChainKey(chainKey, config.outbox);
        _requireRelayerDestination(config.relayerContract, outboxChainKey);
    }

    function _requireOutboxChainKey(
        bytes32 chainKey,
        IOutbox outbox
    ) internal view returns (uint32 expected) {
        if (uint256(chainKey) > type(uint32).max) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidChainKeyEncoding(
                chainKey
            );
        }
        expected = uint32(uint256(chainKey));
        uint32 actual = outbox.chainKey();
        if (actual != expected) {
            revert ASCBridgeLiquidityOperatorErrors.OutboxChainKeyMismatch(
                expected,
                actual
            );
        }
    }

    function _requireRelayerDestination(
        IRelayerContract relayer,
        uint32 destinationChain
    ) internal view {
        if (relayer.destinationEvmChainIds(destinationChain) == 0) {
            revert ASCBridgeLiquidityOperatorErrors.RelayerDestinationNotConfigured(
                destinationChain
            );
        }
    }

    /// @notice Processes one inbound intent decoded from a proved source transaction.
    function bridgeFromIntent(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    )
        external
        override
        returns (bool isValid, bytes[] memory extractedTransactionData)
    {
        _validateInboundInputs(chainKey, blockHeight);
        bytes memory encodedTransaction = _verifyProofs(
            chainKey,
            blockHeight,
            inclusionProof,
            continuityProof
        );

        IBridgeIntentDecoder.DecodedBridgeIntent memory decoded = bridgeIntentDecoder
            .decodeBridgeIntent(encodedTransaction);
        CrossChainOrderTypes.CrossChainOrder memory order = decoded.order;
        ASCBridgeTypes.AttestedTxData memory decodedAttestedTxData = decoded
            .attestedTxData;

        bytes32 intentId = keccak256(
            abi.encodePacked(
                chainKey,
                order.nonce,
                order.user
            )
        );
        if (order.orderData.length == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidIntentOrderData();
        }
        CrossChainOrderTypes.CrossChainIntent memory intent = decoded.intent;
        if (keccak256(order.orderData) != keccak256(abi.encode(intent))) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidIntentOrderData();
        }
        (bool amountConvertible, uint256 destinationAmount) =
            _normalizedInboundAmount(chainKey, decodedAttestedTxData);
        bytes memory destinationCallData = _destinationCallData(
            intentId,
            intent.recipient,
            destinationAmount
        );
        extractedTransactionData = _buildExtractedTransactionData(
            decodedAttestedTxData,
            intent,
            intentId
        );
        uint8 status = _intentStatus[intentId];
        if (status == _INTENT_PROCESSED || status == _INTENT_IN_FLIGHT) {
            return (false, extractedTransactionData);
        }
        if (
            !_validateInboundIntentAndMatchAttestation(
                chainKey,
                order,
                intent,
                decodedAttestedTxData,
                decoded.sourceAmountBurned,
                amountConvertible,
                destinationAmount,
                destinationCallData
            )
        ) {
            return (false, extractedTransactionData);
        }
        isValid = _processValidatedIntent(
            chainKey,
            intentId,
            order,
            intent,
            destinationCallData
        );
        return (isValid, extractedTransactionData);
    }

    function _hasTokenTransfer(
        ASCBridgeTypes.EVMTokenAmount calldata evmTokenAmount
    ) internal view returns (bool) {
        if (evmTokenAmount.token == address(0)) {
            if (evmTokenAmount.amount != 0) {
                revert ASCBridgeLiquidityOperatorErrors.InvalidTokenAmount();
            }
            return false;
        }
        if (evmTokenAmount.token != address(token)) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidTokenAddress(
                evmTokenAmount.token
            );
        }
        if (evmTokenAmount.amount == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidTokenAmount();
        }
        return true;
    }

    function _validateInboundInputs(
        bytes32 chainKey,
        uint64 blockHeight
    ) internal view {
        ChainConfig memory config = _chainConfigs[chainKey];
        if (address(config.outbox) == address(0)) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyNotConfigured(
                chainKey
            );
        }
        if (!config.enabled) {
            revert ASCBridgeLiquidityOperatorErrors.ChainKeyDisabled(chainKey);
        }
        if (sourceEvmChainIds[chainKey] == 0) {
            revert ASCBridgeLiquidityOperatorErrors.SourceEvmChainIdNotConfigured(
                chainKey
            );
        }
        if (blockHeight == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidBlockHeight();
        }
        if (
            address(proofVerifier) == address(0) ||
            address(bridgeIntentDecoder) == address(0)
        ) {
            revert ASCBridgeLiquidityOperatorErrors.MissingAdapterConfig();
        }
        if (!_usesCreditcoinEscrow()) {
            if (mintDestination == address(0)) {
                revert ASCBridgeLiquidityOperatorErrors.MintDestinationNotConfigured();
            }
            _requireCompatibleMintDestination(mintDestination);
        }
    }

    function _verifyProofs(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) internal returns (bytes memory encodedTransaction) {
        return proofVerifier.verifyProofs(
            chainKey,
            blockHeight,
            inclusionProof,
            continuityProof
        );
    }

    function _callDestination(
        address receiver,
        bytes memory callData
    ) internal returns (bool success, bytes memory retData, uint256 gasUsed) {
        uint256 gasBefore = gasleft();
        (success, retData) = receiver.call(callData);
        gasUsed = gasBefore - gasleft();
    }

    function _validateInboundIntentAndMatchAttestation(
        bytes32 chainKey,
        CrossChainOrderTypes.CrossChainOrder memory order,
        CrossChainOrderTypes.CrossChainIntent memory intent,
        ASCBridgeTypes.AttestedTxData memory attestedTxData,
        bool sourceAmountBurned,
        bool amountConvertible,
        uint256 destinationAmount,
        bytes memory destinationCallData
    ) internal view returns (bool) {
        // Native prover keys and EVM chain IDs are separate namespaces (for
        // example, prover key 1 can identify Sepolia chain ID 11155111).
        if (
            attestedTxData.sourceChainId == 0 ||
            attestedTxData.sourceChainId != sourceEvmChainIds[chainKey]
        ) {
            return false;
        }
        if (order.user == address(0) || order.originSettler == address(0)) {
            return false;
        }
        if (order.fillDeadline != 0 && block.timestamp > order.fillDeadline) {
            return false;
        }
        if (
            order.openDeadline != 0 &&
            order.fillDeadline != 0 &&
            order.openDeadline > order.fillDeadline
        ) {
            return false;
        }
        CrossChainOrderTypes.OrderAction expectedAction = _usesCreditcoinEscrow()
            ? CrossChainOrderTypes.OrderAction.TRANSFER
            : CrossChainOrderTypes.OrderAction.MINT;
        if (intent.action != expectedAction) {
            return false;
        }
        if (sourceAmountBurned != _expectsSourceBurn()) {
            return false;
        }
        if (intent.minDestinationAmount.token != address(token)) {
            return false;
        }
        if (intent.minDestinationAmount.amount == 0) {
            return false;
        }
        if (
            intent.destinationChainId != block.chainid
        ) {
            return false;
        }
        if (intent.sourceChainId != order.originChainId) {
            return false;
        }
        // A transaction hash cannot safely satisfy a requirement embedded in
        // that same transaction without an infeasible hash fixed point. Keep
        // this reserved field fail-closed until a separately configured proof
        // policy/domain identifier is defined.
        if (intent.sourceProofRequirement != bytes32(0)) {
            return false;
        }
        if (order.user != attestedTxData.user) {
            return false;
        }
        if (order.nonce != attestedTxData.nonce) {
            return false;
        }
        if (order.originChainId != attestedTxData.sourceChainId) {
            return false;
        }
        if (intent.sourceAmount.token != attestedTxData.sourceAmount.token) {
            return false;
        }
        if (intent.sourceAmount.amount != attestedTxData.sourceAmount.amount) {
            return false;
        }
        if (
            !amountConvertible ||
            destinationAmount == 0 ||
            intent.minDestinationAmount.amount > destinationAmount
        ) {
            return false;
        }
        address expectedDestination = _usesCreditcoinEscrow()
            ? address(token)
            : mintDestination;
        if (
            intent.recipient == address(0) ||
            intent.destinationContract != expectedDestination
        ) {
            return false;
        }
        if (
            keccak256(intent.destinationCallData) !=
            keccak256(destinationCallData)
        ) {
            return false;
        }
        return true;
    }

    function _normalizedInboundAmount(
        bytes32 chainKey,
        ASCBridgeTypes.AttestedTxData memory attestedTxData
    ) internal view returns (bool ok, uint256 destinationAmount) {
        InboundTokenRoute memory route = inboundTokenRoutes[chainKey];
        if (
            !route.enabled ||
            route.sourceToken == address(0) ||
            attestedTxData.sourceAmount.token != route.sourceToken
        ) {
            return (false, 0);
        }
        return
            TokenAmountNormalization.tryNormalize(
                attestedTxData.sourceAmount.amount,
                route.sourceDecimals,
                route.destinationDecimals
            );
    }

    function _normalizedOutboundAmount(
        bytes32 chainKey,
        uint256 amount,
        OutboundTokenRoute memory route
    ) internal pure returns (uint256 destinationAmount) {
        if (!route.enabled) {
            revert ASCBridgeLiquidityOperatorErrors.OutboundTokenRouteNotConfigured(
                chainKey
            );
        }
        if (amount == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidTokenAmount();
        }

        (bool ok, uint256 normalizedAmount) = TokenAmountNormalization
            .tryNormalize(
                amount,
                route.sourceDecimals,
                route.destinationDecimals
            );
        if (!ok) {
            revert ASCBridgeLiquidityOperatorErrors.OutboundAmountNotRepresentable(
                amount,
                route.sourceDecimals,
                route.destinationDecimals
            );
        }
        return normalizedAmount;
    }

    function _validateOutboundTokenCallData(
        bytes calldata callData,
        address receiver,
        uint256 destinationAmount
    ) internal view {
        if (callData.length == 0) {
            return;
        }

        bytes memory expectedCallData = CanonicalTokenCall.encode(
            _destinationUsesMint(),
            receiver,
            destinationAmount
        );
        if (
            callData.length != expectedCallData.length ||
            keccak256(callData) != keccak256(expectedCallData)
        ) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidOutboundTokenCallData();
        }
    }

    function _outboundTokenExecutionCommitment(
        ASCBridgeTypes.BridgeMessage calldata message,
        address receiver,
        uint256 destinationAmount,
        OutboundTokenRoute memory route
    ) internal view returns (bytes32) {
        return
            TokenExecutionCommitment.compute(
                block.chainid,
                message.tokenAmount.token,
                route.destinationToken,
                route.sourceDecimals,
                route.destinationDecimals,
                _destinationUsesMint(),
                receiver,
                message.tokenAmount.amount,
                destinationAmount
            );
    }

    function _validateOutboundGasLimit(
        uint256 gasLimit,
        uint256 minimumGasLimit
    ) internal pure {
        if (gasLimit < minimumGasLimit) {
            revert ASCBridgeLiquidityOperatorErrors.BridgeGasLimitBelowMinimum(
                gasLimit,
                minimumGasLimit
            );
        }
    }

    function _validateOutboundReceiver(
        bytes calldata encodedReceiver
    ) internal pure returns (address receiver) {
        if (encodedReceiver.length == 0) {
            revert ASCBridgeLiquidityOperatorErrors.EmptyReceiver();
        }
        if (encodedReceiver.length != 32) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidEvmReceiverLength(
                encodedReceiver.length
            );
        }

        uint256 encodedAddress;
        assembly ("memory-safe") {
            encodedAddress := calldataload(encodedReceiver.offset)
        }
        if (encodedAddress > type(uint160).max) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidEvmReceiverEncoding();
        }
        if (encodedAddress == 0) {
            revert ASCBridgeLiquidityOperatorErrors.EmptyReceiver();
        }
        return address(uint160(encodedAddress));
    }

    function _buildExtractedTransactionData(
        ASCBridgeTypes.AttestedTxData memory attestedTxData,
        CrossChainOrderTypes.CrossChainIntent memory intent,
        bytes32 intentId
    ) internal pure returns (bytes[] memory extractedTransactionData) {
        // Extracted transaction data schema:
        // [0] abi.encode(uint8 version)
        // [1] abi.encode(ASCBridgeTypes.AttestedTxData)
        // [2] abi.encode(CrossChainOrderTypes.CrossChainIntent)
        // [3] abi.encode(bytes32 intentId)
        extractedTransactionData = new bytes[](4);
        uint8 version = 1;
        extractedTransactionData[0] = abi.encode(version);
        extractedTransactionData[1] = abi.encode(attestedTxData);
        extractedTransactionData[2] = abi.encode(intent);
        extractedTransactionData[3] = abi.encode(intentId);
    }

    function _processValidatedIntent(
        bytes32 chainKey,
        bytes32 intentId,
        CrossChainOrderTypes.CrossChainOrder memory order,
        CrossChainOrderTypes.CrossChainIntent memory intent,
        bytes memory destinationCallData
    ) internal returns (bool) {
        _intentStatus[intentId] = _INTENT_IN_FLIGHT;
        address destination = _usesCreditcoinEscrow()
            ? address(token)
            : mintDestination;
        (bool success, bytes memory retData, uint256 gasUsed) = _callDestination(
            destination,
            destinationCallData
        );
        if (
            success &&
            _usesCreditcoinEscrow() &&
            !CompatibleERC20.isSuccessfulReturn(retData)
        ) {
            revert CompatibleERC20.ERC20CallFailed(
                address(token),
                IERC20.transfer.selector
            );
        }
        _intentStatus[intentId] = _INTENT_NONE;
        emit BridgeIntentExecutionTracked(
            intentId,
            success,
            gasUsed,
            keccak256(retData)
        );
        if (!success) {
            return false;
        }
        uint256 actualGasCost = gasUsed * tx.gasprice;
        if (
            intent.maxGasCost != 0 &&
            actualGasCost > intent.maxGasCost
        ) {
            revert ASCBridgeLiquidityOperatorErrors.MaxGasCostExceeded(
                intent.maxGasCost,
                actualGasCost
            );
        }

        _intentStatus[intentId] = _INTENT_PROCESSED;
        emit CrossChainOrderProcessed(intentId, chainKey, order);
        return true;
    }

    function _destinationCallData(
        bytes32 intentId,
        address recipient,
        uint256 amount
    ) internal view returns (bytes memory) {
        if (_usesCreditcoinEscrow()) {
            return abi.encodeCall(IERC20.transfer, (recipient, amount));
        }
        return abi.encodeCall(
            IASCBridgeTokenDestination.executeMint,
            (intentId, address(token), recipient, amount)
        );
    }

    function _deriveOutboundMsgType(
        bool hasTokenTransfer
    ) internal pure returns (uint8 msgType) {
        if (hasTokenTransfer) {
            return uint8(OutboundMessageKind.TokenOperation);
        }
        return uint8(OutboundMessageKind.PayloadOnly);
    }

    function _usesCreditcoinEscrow() internal view returns (bool) {
        return isHubAndSpoke && isCreditcoinHub;
    }

    function _expectsSourceBurn() internal view returns (bool) {
        return _destinationUsesMint();
    }

    function _destinationUsesMint() internal view returns (bool) {
        return !isHubAndSpoke || isCreditcoinHub;
    }

    function _requireCompatibleMintDestination(
        address destination
    ) internal view {
        if (destination.code.length == 0) {
            revert ASCBridgeLiquidityOperatorErrors.InvalidMintDestination(
                destination
            );
        }

        address configuredOperator;
        try IASCBridgeTokenDestination(destination).bridgeOperator() returns (
            address operator
        ) {
            configuredOperator = operator;
        } catch {
            revert ASCBridgeLiquidityOperatorErrors.InvalidMintDestination(
                destination
            );
        }
        if (configuredOperator != address(this)) {
            revert ASCBridgeLiquidityOperatorErrors.MintDestinationOperatorMismatch(
                address(this),
                configuredOperator
            );
        }

        bool tokenSupported;
        try
            IASCBridgeTokenDestination(destination).mintTokenAllowed(
                address(token)
            )
        returns (bool supported) {
            tokenSupported = supported;
        } catch {
            revert ASCBridgeLiquidityOperatorErrors.InvalidMintDestination(
                destination
            );
        }
        if (!tokenSupported) {
            revert ASCBridgeLiquidityOperatorErrors.MintDestinationTokenUnsupported(
                address(token)
            );
        }
    }

    function _compatibleApprove(
        IERC20 token_,
        address spender,
        uint256 amount
    ) private {
        (bool success, bytes memory returnData) = address(token_).call(
            abi.encodeCall(IERC20.approve, (spender, amount))
        );
        if (!success || !CompatibleERC20.isSuccessfulReturn(returnData)) {
            revert CompatibleERC20.ERC20CallFailed(
                address(token_),
                IERC20.approve.selector
            );
        }
    }
}
