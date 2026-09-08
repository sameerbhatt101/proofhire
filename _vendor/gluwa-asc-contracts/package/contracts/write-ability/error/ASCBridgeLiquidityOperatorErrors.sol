// SPDX-License-Identifier: MIT
pragma solidity >0.8.0 <0.9.0;

library ASCBridgeLiquidityOperatorErrors {
    error EmptyReceiver();
    error InvalidEvmReceiverLength(uint256 length);
    error InvalidEvmReceiverEncoding();
    error EmptyBridgeMessage();
    error InvalidGasLimit();
    error InvalidTokenDecimals();
    error SourceDecimalsMismatch(uint8 expected, uint8 actual);
    error DestinationDecimalsMismatch(uint8 expected, uint8 actual);
    error OutboundTokenRouteNotConfigured(bytes32 chainKey);
    error OutboundTokenRouteImmutable(bytes32 chainKey);
    error InboundTokenRouteImmutable(bytes32 chainKey);
    error OutboundAmountNotRepresentable(
        uint256 amount,
        uint8 sourceDecimals,
        uint8 destinationDecimals
    );
    error BridgeGasLimitBelowMinimum(uint256 provided, uint256 minimum);
    error InvalidOutboundTokenCallData();
    error InvalidTokenAmount();
    error InvalidTokenAddress(address token);
    error ChainKeyNotConfigured(bytes32 chainKey);
    error ChainKeyDisabled(bytes32 chainKey);
    error ChainRelayerNotConfigured(bytes32 chainKey);
    error RelayerOutboxMismatch(address expected, address actual);
    error InvalidChainKeyEncoding(bytes32 chainKey);
    error OutboxChainKeyMismatch(uint32 expected, uint32 actual);
    error RelayerDestinationNotConfigured(uint32 destinationChain);
    error QuoteDestinationMismatch(uint32 expected, uint32 actual);
    error QuoteGasLimitTooLow(uint256 quoteGasLimit, uint256 messageGasLimit);
    error NativeValueUnsupported(uint256 value);
    error NativeQuoteUnsupported();
    error UnknownOutboundMessage(bytes32 messageId);
    error NotOutboundFeePayer(address caller, address payer);
    error OutboundFeeComponentAlreadyRefunded(bytes32 messageId);
    error InvalidRelayerFeeAmount();
    error SourceEvmChainIdNotConfigured(bytes32 chainKey);
    error InvalidSourceEvmChainId();
    error QuoteValidationFailed();
    error ProofValidationFailed();
    error MissingAdapterConfig();
    error MintDestinationNotConfigured();
    error InvalidMintDestination(address destination);
    error MintDestinationOperatorMismatch(address expected, address actual);
    error MintDestinationTokenUnsupported(address token);
    error IntentAlreadyProcessed(bytes32 intentId);
    error InvalidIntentOrderData();
    error UnsupportedIntentAction(uint8 action);
    error IntentProofRequirementMismatch();
    error AttestedUserMismatch(address expected, address actual);
    error AttestedNonceMismatch(uint256 expected, uint256 actual);
    error AttestedSourceChainMismatch(uint256 expected, uint256 actual);
    error AttestedSourceTokenMismatch(address expected, address actual);
    error AttestedSourceAmountMismatch(uint256 expected, uint256 actual);
    error MaxGasCostExceeded(uint256 maxGasCost, uint256 actualGasCost);
    error InvalidBlockHeight();
    error EmptyEncodedTransaction();
}
