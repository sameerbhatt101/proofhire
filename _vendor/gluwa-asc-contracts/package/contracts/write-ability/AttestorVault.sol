// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAttestorVault} from "./abstract/IAttestorVault.sol";
import {IAttestorRegistry} from "./abstract/IAttestorRegistry.sol";
import {IERC3009} from "./abstract/IERC3009.sol";
import {RelayerErrors} from "./error/RelayerErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";

/// @title AttestorVault
/// @notice Holds core fees and distributes them to valid Attestors once on-chain
///         validation is complete. A fee whose message is never settled can be
///         reclaimed by its payer after `refundDelay`.
contract AttestorVault is IAttestorVault, Ownable2Step {
    using CompatibleERC20 for IERC20;
    uint256 public constant MAX_BURN_RATE = 2_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20  public immutable attestToken;
    address public immutable outbox;
    address public immutable relayerContract;
    address public immutable validationContract;
    address public immutable burnAddress;

    uint256 public burnRate;

    /// Attestor-membership registry (an AttestorRegistry deployment, or any contract
    /// exposing a compatible `isAttestor(address)` such as the EOAValidator). Set at
    /// construction and rotatable by the owner; settle rejects payees the registry
    /// does not recognize.
    address public attestorRegistry;

    /// How long after deposit an unsettled core fee becomes refundable to its payer.
    uint256 public refundDelay = 7 days;

    mapping(bytes32 => AttestorRecord) private _records;

    modifier onlyDepositor() {
        if (msg.sender != outbox && msg.sender != relayerContract) {
            revert RelayerErrors.UnauthorizedDepositor(msg.sender);
        }
        _;
    }

    modifier onlyValidationContract() {
        if (msg.sender != validationContract) {
            revert NotValidationContract(msg.sender);
        }
        _;
    }

    constructor(
        address initialOwner,
        address attestToken_,
        address outbox_,
        address relayerContract_,
        address validationContract_,
        address attestorRegistry_,
        address burnAddress_,
        uint256 initialBurnRate
    ) Ownable(initialOwner) {
        if (
            attestToken_        == address(0) ||
            outbox_             == address(0) ||
            relayerContract_    == address(0) ||
            validationContract_ == address(0) ||
            attestorRegistry_   == address(0) ||
            burnAddress_        == address(0)
        ) revert CommonErrors.ZeroAddress();
        if (initialBurnRate > MAX_BURN_RATE)
            revert BurnRateTooHigh(initialBurnRate, MAX_BURN_RATE);

        attestToken        = IERC20(attestToken_);
        outbox             = outbox_;
        relayerContract    = relayerContract_;
        validationContract = validationContract_;
        attestorRegistry   = attestorRegistry_;
        burnAddress        = burnAddress_;
        burnRate           = initialBurnRate;

        emit AttestorRegistrySet(address(0), attestorRegistry_);
    }

    /// @dev Caller (Outbox or RelayerContract) must have already transferred
    ///      coreFee into this vault before calling.
    function deposit(
        bytes32 messageId,
        address payer,
        uint32  targetChainId,
        uint256 coreFee
    ) external override onlyDepositor {
        if (_records[messageId].payer != address(0))
            revert RelayerErrors.AlreadyDeposited(messageId);

        _records[messageId] = AttestorRecord({
            payer:         payer,
            targetChainId: targetChainId,
            coreFee:       coreFee,
            settled:       false,
            depositedAt:   uint64(block.timestamp)
        });

        emit CoreFeeDeposited(messageId, payer, coreFee);
    }

    /// @dev Vault calls ATTEST.receiveWithAuthorization to pull coreFee directly
    ///      from payer — no prior approve needed. msg.sender == address(this) satisfies
    ///      the EIP-3009 constraint that msg.sender == to.
    function depositWithAuthorization(
        bytes32 messageId,
        address payer,
        uint32  targetChainId,
        uint256 coreFee,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external override onlyDepositor {
        if (_records[messageId].payer != address(0))
            revert RelayerErrors.AlreadyDeposited(messageId);

        IERC3009(address(attestToken)).receiveWithAuthorization(
            payer, address(this), coreFee,
            validAfter, validBefore, nonce, v, r, s
        );

        _records[messageId] = AttestorRecord({
            payer:         payer,
            targetChainId: targetChainId,
            coreFee:       coreFee,
            settled:       false,
            depositedAt:   uint64(block.timestamp)
        });

        emit CoreFeeDeposited(messageId, payer, coreFee);
    }

    function settle(
        bytes32 messageId,
        uint32  chainId,
        address[] calldata validAttestors
    ) external override onlyValidationContract {
        AttestorRecord storage record = _records[messageId];

        if (record.payer == address(0))     revert RelayerErrors.UnknownOperation(messageId);
        if (record.settled)                 revert CoreAlreadySettled(messageId);
        if (record.targetChainId != chainId)
            revert ChainIdMismatch(messageId, record.targetChainId, chainId);
        uint256 length = validAttestors.length;
        if (length == 0)                    revert NoValidAttestors();
        _validateAttestors(validAttestors);

        record.settled = true; // CEI: mark before transfers to block reentrancy

        uint256 coreFee          = record.coreFee;
        uint256 burned           = (coreFee * burnRate) / BPS_DENOMINATOR;
        uint256 toDistribute     = coreFee - burned;
        uint256 sharePerAttestor = toDistribute / length;

        if (burned > 0) {
            attestToken.compatibleTransfer(burnAddress, burned);
        }
        for (uint256 i = 0; i < length; ++i) {
            attestToken.compatibleTransfer(validAttestors[i], sharePerAttestor);
        }
        // Dust from integer division (< validAttestors.length wei) remains in vault.

        emit CoreFeeSettled(messageId, toDistribute, burned);
    }

    /// @dev Marks the record settled before transferring (CEI), so a late settle
    ///      after a refund — or a refund after settle — reverts CoreAlreadySettled.
    function refund(bytes32 messageId) external override {
        AttestorRecord storage record = _records[messageId];

        if (record.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (msg.sender != record.payer)
            revert RelayerErrors.NotPayer(msg.sender, record.payer);
        if (record.settled) revert CoreAlreadySettled(messageId);
        uint256 deadline = uint256(record.depositedAt) + refundDelay;
        if (block.timestamp <= deadline)
            revert RelayerErrors.DeadlineNotReached(messageId, deadline, block.timestamp);

        record.settled = true;

        uint256 coreFee = record.coreFee;
        if (coreFee > 0) {
            attestToken.compatibleTransfer(record.payer, coreFee);
        }
        emit CoreFeeRefunded(messageId, record.payer, coreFee);
    }

    function setAttestorRegistry(address newRegistry) external override onlyOwner {
        if (newRegistry == address(0)) revert CommonErrors.ZeroAddress();
        address old = attestorRegistry;
        attestorRegistry = newRegistry;
        emit AttestorRegistrySet(old, newRegistry);
    }

    function setRefundDelay(uint256 newRefundDelay) external override onlyOwner {
        if (newRefundDelay == 0) revert InvalidRefundDelay();
        uint256 old = refundDelay;
        refundDelay = newRefundDelay;
        emit RefundDelayUpdated(old, newRefundDelay);
    }

    function setBurnRate(uint256 newBurnRate) external override onlyOwner {
        if (newBurnRate > MAX_BURN_RATE)
            revert BurnRateTooHigh(newBurnRate, MAX_BURN_RATE);
        uint256 old = burnRate;
        burnRate = newBurnRate;
        emit BurnRateUpdated(old, newBurnRate);
    }

    function getRecord(bytes32 messageId) external view override returns (AttestorRecord memory) {
        return _records[messageId];
    }

    function _validateAttestors(address[] calldata validAttestors) internal view {
        address registry = attestorRegistry;
        for (uint256 i; i < validAttestors.length; ++i) {
            address attestor = validAttestors[i];
            if (!IAttestorRegistry(registry).isAttestor(attestor)) {
                revert AttestorNotRegistered(attestor);
            }
            for (uint256 j; j < i; ++j) {
                if (validAttestors[j] == attestor) {
                    revert DuplicateAttestor(attestor);
                }
            }
        }
    }
}
