// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IPenguinSwapV3Pool} from "../../abstract/IPenguinSwapV3Pool.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

/// @title V3OracleLibrary
/// @notice Reads a short time-weighted price from a Uniswap-V3-style pool.
/// @dev Vendored/trimmed from Uniswap V3 periphery OracleLibrary (gluwa/DEX-Tools) and ported
///      to ^0.8.28. `consult` returns only the arithmetic-mean tick; tick-cumulative deltas use
///      wrapping arithmetic (V3 lets cumulatives overflow by design), so they are `unchecked`.
library V3OracleLibrary {
    /// @notice Time-weighted arithmetic-mean tick for `pool` over the last `secondsAgo` seconds.
    function consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
        require(secondsAgo != 0, "BP");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IPenguinSwapV3Pool(pool).observe(secondsAgos);

        unchecked {
            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
            // Always round to negative infinity.
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) {
                --arithmeticMeanTick;
            }
        }
    }

    /// @notice Amount of `quoteToken` received for `baseAmount` of `baseToken` at `tick`.
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice Number of seconds ago of the oldest stored observation for `pool`.
    /// @dev Used to clamp `secondsAgo` so `observe` never reverts with "OLD" when the pool has
    ///      not yet accumulated a full window of observations.
    function getOldestObservationSecondsAgo(address pool) internal view returns (uint32 secondsAgo) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = IPenguinSwapV3Pool(pool).slot0();
        require(observationCardinality > 0, "NI");

        (uint32 observationTimestamp, , , bool initialized) =
            IPenguinSwapV3Pool(pool).observations((observationIndex + 1) % observationCardinality);

        if (!initialized) {
            (observationTimestamp, , , ) = IPenguinSwapV3Pool(pool).observations(0);
        }

        unchecked {
            secondsAgo = uint32(block.timestamp) - observationTimestamp;
        }
    }
}
