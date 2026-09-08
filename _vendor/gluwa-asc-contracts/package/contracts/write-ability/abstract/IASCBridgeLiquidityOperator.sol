// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IASCBridgeOutbound} from "./IASCBridgeOutbound.sol";
import {IASCBridgeInbound} from "./IASCBridgeInbound.sol";

/// @notice Combined ASC bridge liquidity operator interface.
///         Inherit IASCBridgeOutbound or IASCBridgeInbound directly if only one direction is needed.
interface IASCBridgeLiquidityOperator is IASCBridgeOutbound, IASCBridgeInbound {}
