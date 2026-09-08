// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAttestorVault {
    struct AttestorRecord {
        address payer;
        uint32  targetChainId;
        uint256 coreFee;
        bool    settled;
        /// @notice Deposit timestamp — start of the refund clock.
        uint64  depositedAt;
    }

    /// @notice Lock core fee for one message (ERC-20 path).
    ///         Callable only by the configured Outbox or RelayerContract address.
    ///         Caller must have already pulled coreFee from the payer before calling.
    ///         Reverts if messageId is already registered (duplicate deposit).
    function deposit(
        bytes32 messageId,
        address payer,
        uint32  targetChainId,
        uint256 coreFee
    ) external;

    /// @notice EIP-3009 variant of deposit. Vault calls receiveWithAuthorization on
    ///         the ATTEST token to pull coreFee directly from payer.
    ///         Callable only by the configured Outbox or RelayerContract address.
    ///         Reverts if messageId is already registered (duplicate deposit).
    function depositWithAuthorization(
        bytes32 messageId,
        address payer,
        uint32  targetChainId,
        uint256 coreFee,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;

    /// @notice Distribute core fee to valid Attestors and burn the configured portion.
    ///         Callable only by the configured ASC validation contract.
    ///         (1 − burnRate / BPS_DENOMINATOR) of coreFee is split equally among validAttestors.
    ///         burnRate / BPS_DENOMINATOR is sent to burnAddress.
    ///         chainId must match the stored record's targetChainId.
    ///         Reverts if messageId is unknown, already settled, or validAttestors is empty,
    ///         contains address(0), or contains duplicates.
    function settle(
        bytes32 messageId,
        uint32  chainId,
        address[] calldata validAttestors
    ) external;

    /// @notice Refund an unsettled core fee to its original payer once refundDelay
    ///         has elapsed since deposit — so fees for messages that are never
    ///         validated are not locked in the vault forever. Payer-only. Marks the
    ///         record settled, so refund and settle race for the single settlement.
    function refund(bytes32 messageId) external;

    /// @notice Update the burn rate. Owner only; production ownership should be
    ///         assigned to the governance timelock.
    ///         newBurnRate must be <= MAX_BURN_RATE (2_000 = 20%).
    function setBurnRate(uint256 newBurnRate) external;

    /// @notice Rotate the attestor registry (an AttestorRegistry deployment, or any
    ///         contract with a compatible isAttestor view such as the EOAValidator).
    ///         The registry is fixed at construction and always enforced: settle
    ///         rejects any attestor it does not recognize, so the validation contract
    ///         cannot direct fees to arbitrary addresses. Cannot be unset. Owner only.
    function setAttestorRegistry(address newRegistry) external;

    /// @notice Update the refund delay. Owner only; must be non-zero.
    function setRefundDelay(uint256 newRefundDelay) external;

    function getRecord(bytes32 messageId) external view returns (AttestorRecord memory);

    event CoreFeeDeposited(bytes32 indexed messageId, address indexed payer, uint256 coreFee);
    event CoreFeeSettled(bytes32 indexed messageId, uint256 distributed, uint256 burned);
    event CoreFeeRefunded(bytes32 indexed messageId, address indexed payer, uint256 coreFee);
    event BurnRateUpdated(uint256 oldRate, uint256 newRate);
    event AttestorRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event RefundDelayUpdated(uint256 oldDelay, uint256 newDelay);

    /// @notice Core fee for this operation has already been settled.
    error CoreAlreadySettled(bytes32 messageId);

    /// @notice Caller is not the authorized ASC validation contract.
    error NotValidationContract(address caller);

    /// @notice No valid Attestors provided for core fee distribution.
    error NoValidAttestors();

    /// @notice A validation result contained the zero address.
    error InvalidAttestor(address attestor);

    /// @notice A validation result listed the same Attestor more than once.
    error DuplicateAttestor(address attestor);

    /// @notice A validation result listed an address the attestor registry does not recognize.
    error AttestorNotRegistered(address attestor);

    /// @notice Refund delay must be non-zero.
    error InvalidRefundDelay();

    /// @notice targetChainId in the AttestorRecord does not match the chainId passed to settle.
    error ChainIdMismatch(bytes32 messageId, uint32 expected, uint32 got);

    /// @notice Proposed burn rate exceeds the maximum allowed value.
    error BurnRateTooHigh(uint256 provided, uint256 max);
}
