// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Vendored, unmodified-logic 512-bit math; assembly is the entire technique (Yul mulmod/carry
// tricks), not an isolated optimization.
// solhint-disable no-inline-assembly

/// @title Contains 512-bit math functions
/// @notice Facilitates multiplication and division that can have overflow of an intermediate
///         value without any loss of precision.
/// @dev Vendored from Uniswap V3 (gluwa/UniswapV3-Base contracts/libraries/FullMath.sol) and
///      ported to ^0.8.28: the body relies on wrapping arithmetic, so it is wrapped in an
///      `unchecked` block to preserve the original 0.7.x semantics.
library FullMath {
    /// @notice Calculates floor(a×b÷denominator) with full precision.
    ///         Throws if result overflows a uint256 or denominator == 0.
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2**256. Also prevents denominator == 0.
            require(denominator > prod1);

            // 512 by 256 division.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
            }
            assembly {
                prod0 := div(prod0, twos)
            }
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            result = prod0 * inv;
            return result;
        }
    }
}
