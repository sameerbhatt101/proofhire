// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRelayerFeeVault
/// @notice Pure fee custody in ATTEST or native coin (ETH/CTC). The vault keeps
///         no per-message state — the RelayerContract owns the fee ledger
///         (including each message's fee currency) and all business logic, funds
///         the vault by plain ERC-20 or native transfer at deposit time, and
///         instructs payouts through `pay`.
interface IRelayerFeeVault {
    /// @notice Emitted when a native push to `to` failed and the amount was
    ///         credited to pendingNativeWithdrawals instead. The recipient
    ///         collects with withdrawNative.
    event NativePayoutDeferred(address indexed to, uint256 amount);

    /// @notice Emitted when a deferred native payout is collected: `owed` is the
    ///         credited account, `to` the destination it chose.
    event NativeWithdrawn(address indexed owed, address indexed to, uint256 amount);

    /// @notice The RelayerContract this vault is bound to (fixed at deployment) —
    ///         the only caller `pay` accepts. The RelayerContract checks this
    ///         binding before activating a vault.
    function relayerContract() external view returns (address);

    /// @notice Pays out `amount` held by this vault to `to`, as instructed by the
    ///         bound RelayerContract: native-coin wei when `native` is true,
    ///         ATTEST wei otherwise. A zero amount is a no-op. A native push that
    ///         fails (recipient has no payable receive path, reverts, or exceeds
    ///         the push gas cap) NEVER reverts the settlement — the amount is
    ///         credited to pendingNativeWithdrawals[to] for the recipient to
    ///         pull, so a non-receiving (or malicious) payer or relayer cannot
    ///         block claimDelivery/requestRefund for the other party.
    function pay(address to, uint256 amount, bool native) external;

    /// @notice Native amount owed to `to` from failed pushes, collectable via
    ///         withdrawNative.
    function pendingNativeWithdrawals(address to) external view returns (uint256);

    /// @notice Collects the caller's deferred native payouts in full, sent to
    ///         `to` — so an account whose own address cannot receive native coin
    ///         can still recover by directing its credit elsewhere. Only the
    ///         owed account can redirect its own credit. A no-op when nothing is
    ///         pending.
    function withdrawNative(address to) external;
}
