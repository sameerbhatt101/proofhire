// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Mintable} from "../abstract/IERC20MintBurn.sol";

/// @notice ERC-20 calls compatible with tokens that either return `true` or no data.
/// @dev Creditcoin hosts tokens with both conventions. Explicit `false`, malformed
///      return data, and call reverts are always treated as failures.
library CompatibleERC20 {
    error ERC20CallFailed(address token, bytes4 selector);

    function compatibleTransfer(
        IERC20 token,
        address to,
        uint256 amount
    ) internal {
        _call(address(token), abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function compatibleTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        _call(
            address(token),
            abi.encodeCall(IERC20.transferFrom, (from, to, amount))
        );
    }

    function compatibleMint(
        IERC20Mintable token,
        address to,
        uint256 amount
    ) internal {
        _call(
            address(token),
            abi.encodeCall(IERC20Mintable.mint, (to, amount))
        );
    }

    function isSuccessfulReturn(
        bytes memory returnData
    ) internal pure returns (bool) {
        return isSuccessfulReturn(returnData, returnData.length);
    }

    function isSuccessfulReturn(
        bytes memory returnData,
        uint256 fullReturnDataSize
    ) internal pure returns (bool) {
        if (fullReturnDataSize == 0) {
            return true;
        }
        return
            fullReturnDataSize == 32 &&
            returnData.length == 32 &&
            _returnedTrue(returnData);
    }

    function _call(address token, bytes memory callData) private {
        if (token.code.length == 0) {
            bytes4 selector;
            // Extracts the selector for the revert reason; no non-assembly equivalent.
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                selector := mload(add(callData, 0x20))
            }
            revert ERC20CallFailed(token, selector);
        }
        // token is an arbitrary, not-statically-known ERC-20.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = token.call(callData);
        if (!success || !isSuccessfulReturn(returnData)) {
            bytes4 selector;
            // Extracts the selector for the revert reason; no non-assembly equivalent.
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                selector := mload(add(callData, 0x20))
            }
            revert ERC20CallFailed(token, selector);
        }
    }

    function _returnedTrue(bytes memory returnData) private pure returns (bool) {
        uint256 value;
        // Reads the raw returned word; no non-assembly equivalent.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            value := mload(add(returnData, 0x20))
        }
        return value == 1;
    }
}
