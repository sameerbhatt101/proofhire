// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RelayerErrors {
    /// @notice Quote signature was not produced by a whitelisted quoter EOA.
    error UnauthorizedQuoter(address recovered);

    /// @notice Quote has passed its expiry timestamp.
    error QuoteExpired(uint256 expiry, uint256 blockTimestamp);

    /// @notice Signed quote payload does not match the message being funded.
    error QuotePayloadHashMismatch(bytes32 expected, bytes32 actual);

    /// @notice Signed quote target/payer binding does not match the caller or stored message.
    error QuoteTargetMismatch(address expected, address actual);

    /// @notice Quote is for a different destination chain than this RelayerContract's Outbox.
    error QuoteDestinationChainMismatch(uint32 expected, uint32 actual);

    /// @notice Quote destination cannot be represented by the configured uint16 quoter.
    error UnsupportedDestinationChain(uint32 destinationChain);

    /// @notice A signed quote can fund only one message.
    error QuoteAlreadyUsed(bytes32 quoteDigest);

    /// @notice Core fee in quote is below the required floor.
    error CoreFeeBelowFloor(uint256 provided, uint256 floor);

    /// @notice Live core fee exceeds the maximum authorized by the signed quote.
    error CoreFeeAboveQuote(uint256 quotedMaximum, uint256 liveCoreFee);

    /// @notice Signed relay fee is below the current on-chain ATTEST floor.
    error RelayFeeBelowFloor(uint256 provided, uint256 floor);

    /// @notice Signed acknowledgment fee is below the Quoter contract's current ATTEST floor.
    error AcknowledgmentFeeBelowFloor(uint256 provided, uint256 floor);

    /// @notice Quote delivery deadline is not in the future.
    error InvalidDeliveryDeadline(uint256 deadline, uint256 blockTimestamp);

    /// @notice Quote gas limit must be non-zero.
    error InvalidGasLimit();

    /// @notice Tip increases must transfer a positive amount.
    error ZeroTipIncrease();

    /// @notice messageId is already registered (duplicate deposit).
    error OperationAlreadyRegistered(bytes32 messageId);

    /// @notice messageId is already registered in a vault (duplicate deposit).
    error AlreadyDeposited(bytes32 messageId);

    /// @notice Caller is not an authorized depositor for this vault.
    error UnauthorizedDepositor(address caller);

    /// @notice Caller is not the RelayerContract this vault is bound to. Every
    ///         state-changing vault operation except claimAcknowledgment is
    ///         driven by the RelayerContract, which owns the business logic.
    error NotRelayerContract(address caller);

    /// @notice No active RelayerFeeVault has been configured on the RelayerContract.
    error VaultNotSet();

    /// @notice The vault being wired is bound to a different RelayerContract, so
    ///         every call this contract made to it would revert.
    error VaultNotBoundToRelayer(address vault);

    /// @notice A native-coin transfer failed (recipient reverted or has no
    ///         payable receive path).
    error NativeTransferFailed(address to, uint256 amount);

    /// @notice msg.value does not match the amount due in native coin (0 expected
    ///         on ATTEST-denominated operations).
    error InvalidNativeAmount(uint256 expected, uint256 provided);

    /// @notice EIP-3009 payment paths move ATTEST only and cannot serve a
    ///         native-denominated quote or route.
    error NativePaymentNotSupported();

    /// @notice A route with an acknowledgment fee cannot be funded until an
    ///         AcknowledgmentValidator (the ack-fee custodian) is configured.
    error AcknowledgmentValidatorNotSet();

    /// @notice Caller is not the configured AcknowledgmentValidator.
    error UnauthorizedAcknowledgmentClaimer(address caller);

    /// @notice Caller is not trusted to publish and collect fees for another payer.
    error UnauthorizedPublisher(address caller);

    /// @notice EIP-3009 nonce is not scoped to this publisher, payer, and quote.
    error PublisherAuthorizationNonceMismatch(bytes32 expected, bytes32 actual);

    /// @notice tipExpiry is less than block.timestamp + minimum tip window (600 s).
    error TipExpiryTooSoon(uint256 tipExpiry);

    /// @notice newTipExpiry does not extend the current tipExpiry.
    error TipExpiryNotExtended(bytes32 messageId, uint256 current, uint256 provided);

    /// @notice A tip could expire before the quoted delivery window has elapsed.
    error TipExpiryNotAfterDeliveryDeadline(
        bytes32 messageId,
        uint256 deliveryDeadline,
        uint256 tipExpiry
    );

    /// @notice Decoded messageId from the delivery proof does not match the claimed messageId.
    error MessageIdMismatch(bytes32 expected, bytes32 decoded);

    /// @notice Decoded destination chain does not match the chain recorded at deposit time.
    error DestinationChainMismatch(bytes32 messageId, uint32 expected, uint32 decoded);

    /// @notice No EVM chain ID has been configured for the funded route key.
    error DestinationEvmChainIdNotConfigured(uint32 destinationChain);

    /// @notice A route cannot be configured with EVM chain ID zero.
    error InvalidDestinationEvmChainId();

    /// @notice Proof route key does not match the route funded at deposit time.
    error RouteChainKeyMismatch(bytes32 expected, bytes32 provided);

    /// @notice Proved delivery used a different transaction gas limit.
    error DeliveryGasLimitMismatch(uint256 expected, uint256 decoded);

    /// @notice Proved delivery used a gas limit that was never funded for this message.
    error UnfundedDeliveryGasLimit(bytes32 messageId, uint256 decoded);

    /// @notice Relay fee for this operation has already been settled.
    error RelayAlreadySettled(bytes32 messageId);

    /// @notice feeRefundTo was already set for this message.
    error FeeRefundRecipientAlreadySet(bytes32 messageId);

    /// @notice Delivery deadline has not yet passed; refund not yet available.
    error DeadlineNotReached(bytes32 messageId, uint256 deadline, uint256 blockTimestamp);

    /// @notice Gas-limit changes are closed once the delivery deadline is reached.
    error DeliveryDeadlineReached(bytes32 messageId, uint256 deadline, uint256 blockTimestamp);

    /// @notice Top-up amount is zero.
    error ZeroTopUpAmount();

    /// @notice Caller-provided top-up amount does not equal the quoter-signed amount.
    error TopUpAmountMismatch(uint256 provided, uint256 quoted);

    /// @notice Only the original payer may settle a refund after the delivery deadline.
    error NotPayer(address caller, address payer);

    /// @notice newGasLimit in the top-up quote is not greater than the current committed gasLimit.
    error GasLimitNotIncreased(bytes32 messageId, uint256 current, uint256 provided);

    /// @notice The operation is not known (no deposit recorded for this messageId).
    error UnknownOperation(bytes32 messageId);

    /// @notice Address is already in the quoter whitelist.
    error QuoterAlreadyAuthorized(address quoter);

    /// @notice Address is not in the quoter whitelist.
    error QuoterNotAuthorized(address quoter);

    /// @notice Caller is not the authorized oracle service.
    error UnauthorizedOracle(address caller);

    /// @notice chainIds and prices arrays must have the same length.
    error ArrayLengthMismatch(uint256 chainIdCount, uint256 priceCount);

    /// @notice Outbox contract has not been configured on the RelayerContract.
    error OutboxNotSet();

    /// @notice The shared anchor price (sourcePrice) has not been set yet.
    error SourcePriceNotSet();

    /// @notice The destination chain native/USD price has not been set yet.
    error DestinationPriceNotSet(uint16 dstChain);

    /// @notice The PenguinSwap pool returned a zero ATTEST/CTC price (read() == 0).
    error InvalidPoolPrice();

    /// @notice The configured PenguinSwap pool path is empty, non-contiguous, or does not
    ///         convert ATTEST → … → CTC.
    error InvalidPoolPath();

    /// @notice Latest pushed TWAP observation is too old for fee-critical use.
    error StalePrice(uint256 lastUpdatedAt, uint256 currentTimestamp);

    /// @notice A configured pool has not accumulated the full requested TWAP window.
    error InsufficientPoolHistory(uint32 availableSeconds, uint32 requiredSeconds);

}
