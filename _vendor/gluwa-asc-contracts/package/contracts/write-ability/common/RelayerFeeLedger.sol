// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IRelayerFeeVault} from "../abstract/IRelayerFeeVault.sol";
import {RelayerTypes} from "./RelayerTypes.sol";
import {RelayerErrors} from "../error/RelayerErrors.sol";
import {CommonErrors} from "../error/CommonErrors.sol";

/// @title RelayerFeeLedger
/// @notice Per-message fee accounting shared by the RelayerContract variants.
///         All fee state lives here — routes, fee components, settlement flags,
///         funded gas-limit versions, and which vault holds each message's
///         funds. The RelayerFeeVault stores nothing per message: it only holds
///         ATTEST and pays on this ledger's instruction. Internal settle/apply
///         functions mutate the ledger and return amounts; the inheriting
///         contract moves the tokens (vault.pay) and emits the events.
abstract contract RelayerFeeLedger {
    struct FeeData {
        address payer;
        uint32  destinationChain;
        bool    relaySettled;
        /// @notice Fee currency this route was funded in (from the signed quote):
        ///         native-coin wei when true, ATTEST wei when false.
        bool    feesInNative;
        uint256 gasLimit;
        uint256 tipExpiry;
        uint256 deliveryDeadline;
    }

    /// @notice Relay reward and tip only — the acknowledgment fee is NOT part of
    ///         this ledger: the RelayerContract forwards it (with the core fee)
    ///         to the Outbox, which routes it to the AcknowledgmentValidator for
    ///         custody until a proven acknowledgment claims it.
    struct MessageFees {
        uint256 relayFee;
        uint256 tip;
    }

    /// @notice Active vault receiving new deposits. Swappable at any time via the
    ///         inheriting contract's owner-gated setter; message-scoped operations
    ///         route via vaultOf, not this.
    IRelayerFeeVault public relayerFeeVault;
    /// @notice Vault holding each funded message's relay fee and tip, recorded at
    ///         deposit time so a later vault swap cannot strand in-flight routes.
    mapping(bytes32 => IRelayerFeeVault) public vaultOf;

    mapping(bytes32 => FeeData)     private _routes;
    mapping(bytes32 => MessageFees) public messageFees;
    /// @notice EVM destination chain ID snapshotted when each route is funded.
    mapping(bytes32 => uint32) public routeEvmChainIds;
    /// @dev The current route exposes the latest commitment. These snapshots
    ///      retain every funded gas-limit version so a later top-up cannot
    ///      invalidate a delivery already mined with an earlier commitment.
    mapping(bytes32 => uint256) private _initialGasLimit;
    mapping(bytes32 => mapping(uint256 => uint256)) private _relayFeeAtGasLimit;

    /// @notice Optional override for where unused top-up / tip refunds are paid.
    ///         Defaults to `payer` when unset. Lets a publisher contract (e.g. ASC
    ///         bridge) redirect claimDelivery / deadline refunds to the end user.
    mapping(bytes32 => address) private _feeRefundTo;

    /// @notice Returns all fee and routing data for a message in a single call.
    ///         Relayers MUST consult this before accepting a message.
    function getMessageInfo(
        bytes32 messageId
    ) public view returns (RelayerTypes.MessageInfo memory) {
        FeeData storage fd      = _routes[messageId];
        MessageFees storage f   = messageFees[messageId];
        return RelayerTypes.MessageInfo({
            payer:            fd.payer,
            destinationChain: fd.destinationChain,
            gasLimit:         fd.gasLimit,
            relayFee:         f.relayFee,
            tip:              f.tip,
            tipExpiry:        fd.tipExpiry,
            deliveryDeadline: fd.deliveryDeadline,
            relaySettled:     fd.relaySettled,
            feesInNative:     fd.feesInNative
        });
    }

    /// @notice Address that receives unused top-up / tip refunds for `messageId`.
    function feeRefundTo(bytes32 messageId) public view returns (address) {
        address override_ = _feeRefundTo[messageId];
        if (override_ != address(0)) return override_;
        return _routes[messageId].payer;
    }

    /// @dev Fee currency of a funded route.
    function _feesInNative(bytes32 messageId) internal view returns (bool) {
        return _routes[messageId].feesInNative;
    }

    /// @dev Sends native coin, reverting on failure (used to fund the vault and
    ///      by nothing else — payouts flow through vault.pay).
    function _forwardNative(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert RelayerErrors.NativeTransferFailed(to, amount);
    }

    /// @dev Activates a vault for new deposits after checking it is bound back to
    ///      this contract. Swapping never affects in-flight routes (vaultOf).
    function _setVault(address newVault) internal {
        if (newVault == address(0)) revert CommonErrors.ZeroAddress();
        if (IRelayerFeeVault(newVault).relayerContract() != address(this)) {
            revert RelayerErrors.VaultNotBoundToRelayer(newVault);
        }
        relayerFeeVault = IRelayerFeeVault(newVault);
    }

    /// @dev Vault for new deposits; reverts until a vault has been activated.
    function _activeVault() internal view returns (IRelayerFeeVault vault) {
        vault = relayerFeeVault;
        if (address(vault) == address(0)) revert RelayerErrors.VaultNotSet();
    }

    /// @dev Vault holding an already-funded message; unknown messages resolve to
    ///      the active vault, whose empty ledger entry here then surfaces as
    ///      UnknownOperation in the calling flow.
    function _vaultFor(bytes32 messageId) internal view returns (IRelayerFeeVault vault) {
        vault = vaultOf[messageId];
        if (address(vault) == address(0)) vault = _activeVault();
    }

    /// @dev Payer-only: redirect unused top-up / tip refunds away from `payer`
    ///      (e.g. bridge operator → end user). May be set once while unsettled.
    function _setFeeRefundTo(bytes32 messageId, address recipient) internal {
        FeeData storage fd = _routes[messageId];
        if (fd.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (msg.sender != fd.payer) {
            revert RelayerErrors.NotPayer(msg.sender, fd.payer);
        }
        if (fd.relaySettled) revert RelayerErrors.RelayAlreadySettled(messageId);
        if (recipient == address(0)) revert CommonErrors.ZeroAddress();
        if (_feeRefundTo[messageId] != address(0)) {
            revert RelayerErrors.FeeRefundRecipientAlreadySet(messageId);
        }
        _feeRefundTo[messageId] = recipient;
    }

    /// @dev Records a funded route (relay fee + tip, held in `vault`; the ackFee
    ///      never enters this ledger — it is forwarded through the Outbox to the
    ///      AcknowledgmentValidator). The caller transfers the funds, in native
    ///      coin when feesInNative is true, else ATTEST.
    function _recordDeposit(
        IRelayerFeeVault vault,
        bytes32 messageId,
        address payer,
        uint256 relayFee,
        uint256 tip,
        uint256 gasLimit,
        uint32  destinationChain,
        uint32  destinationEvmChainId,
        uint256 tipExpiry,
        uint256 deliveryDeadline,
        bool    feesInNative
    ) internal {
        if (_routes[messageId].payer != address(0))
            revert RelayerErrors.AlreadyDeposited(messageId);
        if (gasLimit == 0 || gasLimit > type(uint64).max) {
            revert RelayerErrors.InvalidGasLimit();
        }
        if (tip > 0 && tipExpiry <= deliveryDeadline) {
            revert RelayerErrors.TipExpiryNotAfterDeliveryDeadline(
                messageId,
                deliveryDeadline,
                tipExpiry
            );
        }
        if (destinationEvmChainId == 0) {
            revert RelayerErrors.InvalidDestinationEvmChainId();
        }

        _routes[messageId] = FeeData({
            payer:            payer,
            destinationChain: destinationChain,
            relaySettled:     false,
            feesInNative:     feesInNative,
            gasLimit:         gasLimit,
            tipExpiry:        tipExpiry,
            deliveryDeadline: deliveryDeadline
        });
        messageFees[messageId] = MessageFees({
            relayFee: relayFee,
            tip:      tip
        });
        _initialGasLimit[messageId] = gasLimit;
        _relayFeeAtGasLimit[messageId][gasLimit] = relayFee;
        routeEvmChainIds[messageId] = destinationEvmChainId;
        vaultOf[messageId] = vault;
    }

    /// @dev Settles the relay-fee side of a proven delivery: the fee funded at
    ///      deliveredGasLimit goes to the relayer, unused top-up headroom back to
    ///      the payer, and the tip is paid or refunded by its expiry. Mutates the
    ///      ledger only — the caller transfers the returned amounts.
    function _settleDelivery(
        bytes32 messageId,
        uint256 deliveredGasLimit
    ) internal returns (
        address payer,
        uint256 relayFeePaid,
        uint256 unusedRefunded,
        uint256 tipPaid,
        uint256 tipRefunded
    ) {
        FeeData storage fd = _routes[messageId];
        if (fd.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (fd.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);

        relayFeePaid = _relayFeeAtGasLimit[messageId][deliveredGasLimit];
        if (
            deliveredGasLimit != _initialGasLimit[messageId] &&
            relayFeePaid == 0
        ) revert RelayerErrors.UnfundedDeliveryGasLimit(messageId, deliveredGasLimit);
        fd.relaySettled = true;

        payer          = fd.payer;
        unusedRefunded = messageFees[messageId].relayFee - relayFeePaid;
        uint256 tip    = messageFees[messageId].tip;
        if (tip > 0 && block.timestamp < fd.tipExpiry) {
            tipPaid = tip;
        } else {
            tipRefunded = tip;
        }
    }

    /// @dev Applies a validated gas-limit top-up (route must exist and be unsettled).
    function _applyTopUp(
        bytes32 messageId,
        uint256 newGasLimit,
        uint256 additionalATTEST
    ) internal returns (uint256 oldGasLimit) {
        FeeData storage fd = _routes[messageId];
        if (fd.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (fd.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);

        oldGasLimit = fd.gasLimit;
        uint256 newRelayFee = messageFees[messageId].relayFee + additionalATTEST;
        fd.gasLimit = newGasLimit;
        messageFees[messageId].relayFee = newRelayFee;
        _relayFeeAtGasLimit[messageId][newGasLimit] = newRelayFee;
    }

    /// @dev Applies a validated tip increase (route must exist and be unsettled).
    function _applyTipIncrease(
        bytes32 messageId,
        uint256 additionalTip,
        uint256 newTipExpiry
    ) internal {
        FeeData storage fd = _routes[messageId];
        if (fd.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (fd.relaySettled)         revert RelayerErrors.RelayAlreadySettled(messageId);

        messageFees[messageId].tip += additionalTip;
        fd.tipExpiry = newTipExpiry;
    }

    /// @dev Settles the relay reward and tip in the payer's favour after the
    ///      delivery deadline. A late proof and the refund race for the single
    ///      settlement. (The ack fee is not held here — the payer reclaims it on
    ///      the AcknowledgmentValidator.)
    function _settleRefund(
        bytes32 messageId,
        address payer
    ) internal returns (uint256 total) {
        FeeData storage fd = _routes[messageId];
        if (fd.payer == address(0)) revert RelayerErrors.UnknownOperation(messageId);
        if (payer != fd.payer)
            revert RelayerErrors.NotPayer(payer, fd.payer);
        if (block.timestamp <= fd.deliveryDeadline)
            revert RelayerErrors.DeadlineNotReached(
                messageId,
                fd.deliveryDeadline,
                block.timestamp
            );
        if (fd.relaySettled)
            revert RelayerErrors.RelayAlreadySettled(messageId);

        fd.relaySettled = true;
        total = messageFees[messageId].relayFee + messageFees[messageId].tip;
    }
}
