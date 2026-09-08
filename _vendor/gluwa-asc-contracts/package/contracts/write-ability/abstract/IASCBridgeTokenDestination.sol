// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IASCBridgeTokenDestination
/// @notice Durable, replay-protected mint surface used by the bridge operator.
interface IASCBridgeTokenDestination {
    function bridgeOperator() external view returns (address);

    /// @dev Historical getter name retained by ASCBridgeMintDestination.
    function mintTokenAllowed(address token) external view returns (bool);

    function executeMint(
        bytes32 intentId,
        address token,
        address recipient,
        uint256 amount
    ) external;
}
