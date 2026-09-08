// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRelayerFeeVault} from "./abstract/IRelayerFeeVault.sol";
import {RelayerErrors} from "./error/RelayerErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";

/// @title RelayerFeeVault
/// @notice Pure fee custody for the relayer service — nothing else. Holds fees
///         in ATTEST or native coin (ETH/CTC); it keeps no per-message state and
///         makes no decisions: the RelayerContract owns the fee ledger (routes,
///         amounts, settlement flags, and each message's fee currency) and all
///         business logic, funds it by plain ERC-20 or native transfer, and
///         instructs payouts through `pay`. Binding this vault to exactly one
///         RelayerContract (immutable) is its entire trust model; swapping to a
///         new vault is a RelayerContract-side operation (setRelayerFeeVault),
///         with in-flight messages tracked back to the vault holding their funds
///         via the RelayerContract's vaultOf ledger.
///         Core fees are NOT held here — those live in AttestorVault.
contract RelayerFeeVault is IRelayerFeeVault {
    using CompatibleERC20 for IERC20;

    IERC20  public immutable attestToken;
    address public immutable override relayerContract;

    constructor(address attestToken_, address relayerContract_) {
        if (
            attestToken_     == address(0) ||
            relayerContract_ == address(0)
        ) revert CommonErrors.ZeroAddress();

        attestToken     = IERC20(attestToken_);
        relayerContract = relayerContract_;
    }

    /// @notice Gas forwarded with a native push. Generous enough for contract
    ///         wallets with receive logic, but bounded so a hostile recipient
    ///         cannot grief the settlement transaction with unbounded gas
    ///         consumption — on any failure the amount is deferred to pull.
    uint256 public constant NATIVE_PUSH_GAS_LIMIT = 100_000;

    /// @notice Native amounts owed from failed pushes, collectable via
    ///         withdrawNative. The only per-recipient state this vault keeps.
    mapping(address => uint256) public override pendingNativeWithdrawals;

    /// @notice Accepts native-coin deposits (the RelayerContract forwards
    ///         msg.value here when a route's fees are native-denominated).
    receive() external payable {}

    /// @inheritdoc IRelayerFeeVault
    /// @dev Native payouts are push-then-pull: a failed push credits
    ///      pendingNativeWithdrawals instead of reverting, so settlement flows
    ///      on the RelayerContract (claimDelivery bundles the relayer payout
    ///      with the payer refund) can never be blocked by a recipient that
    ///      cannot — or deliberately refuses to — receive native coin.
    function pay(address to, uint256 amount, bool native) external override {
        if (msg.sender != relayerContract)
            revert RelayerErrors.NotRelayerContract(msg.sender);
        if (amount == 0) return;

        if (native) {
            (bool ok, ) = to.call{value: amount, gas: NATIVE_PUSH_GAS_LIMIT}("");
            if (!ok) {
                pendingNativeWithdrawals[to] += amount;
                emit NativePayoutDeferred(to, amount);
            }
        } else {
            attestToken.compatibleTransfer(to, amount);
        }
    }

    /// @inheritdoc IRelayerFeeVault
    /// @dev Pays the caller's credit to a caller-chosen `to`: a recipient with no
    ///      payable path at all (whose own address can never receive the push OR
    ///      the pull) can still recover by directing its funds to an address it
    ///      controls. This is the one transaction where a destination argument
    ///      is safe for every party — msg.sender is, by construction, the owner
    ///      of the credit being moved.
    function withdrawNative(address to) external override {
        uint256 amount = pendingNativeWithdrawals[msg.sender];
        if (amount == 0) return; // nothing deferred — no-op, mirroring pay
        if (to == address(0)) revert CommonErrors.ZeroAddress();

        pendingNativeWithdrawals[msg.sender] = 0; // CEI: settle before transfer
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert RelayerErrors.NativeTransferFailed(to, amount);
        emit NativeWithdrawn(msg.sender, to, amount);
    }
}
