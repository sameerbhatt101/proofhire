// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Exact decimal conversion shared by both sides of the token route.
library TokenAmountNormalization {
    function tryNormalize(
        uint256 amount,
        uint8 sourceDecimals,
        uint8 destinationDecimals
    ) internal pure returns (bool ok, uint256 normalizedAmount) {
        if (sourceDecimals == destinationDecimals) {
            return (true, amount);
        }
        if (sourceDecimals > destinationDecimals) {
            uint256 divisor = 10 ** (sourceDecimals - destinationDecimals);
            if (amount % divisor != 0) {
                return (false, 0);
            }
            return (true, amount / divisor);
        }

        uint256 multiplier = 10 ** (destinationDecimals - sourceDecimals);
        if (amount > type(uint256).max / multiplier) {
            return (false, 0);
        }
        return (true, amount * multiplier);
    }
}
