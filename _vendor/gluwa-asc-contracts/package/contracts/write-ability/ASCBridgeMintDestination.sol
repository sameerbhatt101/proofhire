// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Mintable} from "./abstract/IERC20MintBurn.sol";
import {CompatibleERC20} from "./common/CompatibleERC20.sol";
import {CommonErrors} from "./error/CommonErrors.sol";

/// @title ASC Bridge Token Destination
/// @notice Durable mint destination called by
///         `ASCBridgeLiquidityOperator.bridgeFromIntent`.
/// @dev Burn/mint deployments grant this contract the token's mint role.
contract ASCBridgeMintDestination is Ownable2Step {
    using CompatibleERC20 for IERC20Mintable;

    error UnauthorizedCaller(address caller);
    error UnsupportedMintToken(address token);
    error InvalidRecipient();
    error InvalidAmount();
    error IntentAlreadyProcessed(bytes32 intentId);
    error IntentAlreadyProcessing(bytes32 intentId);

    /// @notice Emitted when the ASC bridge operator is updated.
    event BridgeOperatorSet(address indexed operator);

    /// @notice Emitted when a mintable token is allowed/blocked.
    event MintTokenSet(address indexed token, bool allowed);

    /// @notice Emitted after successful mint execution.
    event MintExecuted(
        bytes32 indexed intentId,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        address caller
    );

    /// @notice ASC bridge operator allowed to invoke canonical token execution.
    address public bridgeOperator;

    /// @notice Owner-managed allowlist of token contracts accepted for minting.
    mapping(address => bool) public mintTokenAllowed;

    /// @notice Durable replay protection that survives bridge-operator rotation.
    mapping(bytes32 => bool) public processedIntentIds;

    /// @notice In-flight guard set before an external token operation.
    mapping(bytes32 => bool) public inFlightIntentIds;

    /// @param initialBridgeOperator Initial authorized ASC bridge operator.
    /// @param initialMintToken Initial mint token/bridge contract allowed for mint execution.
    /// @param initialOwner Initial contract owner.
    constructor(
        address initialBridgeOperator,
        address initialMintToken,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            initialBridgeOperator == address(0) ||
            initialMintToken == address(0) ||
            initialOwner == address(0)
        ) {
            revert CommonErrors.ZeroAddress();
        }

        bridgeOperator = initialBridgeOperator;
        mintTokenAllowed[initialMintToken] = true;

        emit BridgeOperatorSet(initialBridgeOperator);
        emit MintTokenSet(initialMintToken, true);
    }

    /// @notice Updates the authorized ASC bridge operator caller.
    /// @param operator New operator address.
    function setBridgeOperator(address operator) external onlyOwner {
        if (operator == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        bridgeOperator = operator;
        emit BridgeOperatorSet(operator);
    }

    /// @notice Allows or blocks a token/bridge contract for mint execution.
    /// @param token Token/bridge address exposing `mint(address,uint256)`.
    /// @param allowed True to allow, false to block.
    function setMintToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) {
            revert CommonErrors.ZeroAddress();
        }
        mintTokenAllowed[token] = allowed;
        emit MintTokenSet(token, allowed);
    }

    /// @notice Executes minting for a validated inbound intent.
    /// @dev The operator constructs this exact calldata after validating the intent;
    ///      users cannot select an arbitrary destination call on the MINT route.
    /// @param intentId Inbound intent identifier for traceability.
    /// @param token Token/bridge contract to mint from (must be allowed by owner).
    /// @param recipient Recipient address to receive minted tokens.
    /// @param amount Amount to mint.
    function executeMint(
        bytes32 intentId,
        address token,
        address recipient,
        uint256 amount
    ) external {
        if (msg.sender != bridgeOperator) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (!mintTokenAllowed[token]) {
            revert UnsupportedMintToken(token);
        }
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        _beginIntent(intentId);
        IERC20Mintable(token).compatibleMint(recipient, amount);
        _completeIntent(intentId);
        emit MintExecuted(intentId, token, recipient, amount, msg.sender);
    }

    function _beginIntent(bytes32 intentId) private {
        if (inFlightIntentIds[intentId]) {
            revert IntentAlreadyProcessing(intentId);
        }
        if (processedIntentIds[intentId]) {
            revert IntentAlreadyProcessed(intentId);
        }

        // Persist replay state before the external call. A revert rolls both
        // writes back, while a successful operation remains protected after an
        // authorized bridge-operator rotation.
        inFlightIntentIds[intentId] = true;
        processedIntentIds[intentId] = true;
    }

    function _completeIntent(bytes32 intentId) private {
        inFlightIntentIds[intentId] = false;
    }
}
