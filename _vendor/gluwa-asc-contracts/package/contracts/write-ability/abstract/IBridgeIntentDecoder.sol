// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CrossChainOrderTypes} from "../common/CrossChainOrderTypes.sol";
import {ASCBridgeTypes} from "../common/ASCBridgeTypes.sol";

interface IBridgeIntentDecoder {

    /// @notice Decoder output used by ASC bridge inbound processing.
    struct DecodedBridgeIntent {
        CrossChainOrderTypes.CrossChainOrder order;
        /// @dev Canonical intent established by the decoder's registered calldata
        ///      template. Consumers must not independently decode untrusted
        ///      `order.orderData` bytes.
        CrossChainOrderTypes.CrossChainIntent intent;
        ASCBridgeTypes.AttestedTxData attestedTxData;
        /// @dev True only when the proved source settlement transferred the
        ///      exact source amount to address(0). Creditcoin-hub release routes
        ///      require this burn evidence before unlocking escrow.
        bool sourceAmountBurned;
    }

    /// @notice Decodes source-chain tx/receipt bytes into one inbound ASC
    ///         legacy ERC-7683-inspired order.
    function decodeBridgeIntent(
        bytes calldata encodedTransaction
    ) external view returns (DecodedBridgeIntent memory);
}
