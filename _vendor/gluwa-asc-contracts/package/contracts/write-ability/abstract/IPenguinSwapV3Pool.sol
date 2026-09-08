// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPenguinSwapV3Pool
/// @notice Minimal Uniswap-V3-style pool interface for the PenguinSwap ATTEST/CTC pool(s).
///         Only the views needed to read a short time-weighted price on-chain are included.
interface IPenguinSwapV3Pool {
    /// @notice The first of the two tokens of the pool, sorted by address.
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address.
    function token1() external view returns (address);

    /// @notice The pool's current state.
    /// @return sqrtPriceX96 The current price as a sqrt(token1/token0) Q64.96 value.
    /// @return tick The current tick.
    /// @return observationIndex The index of the last written oracle observation.
    /// @return observationCardinality The current number of populated observation slots.
    /// @return observationCardinalityNext The next observation cardinality (during growth).
    /// @return feeProtocol The protocol fee for both tokens of the pool.
    /// @return unlocked Whether the pool is currently locked to reentrancy.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from now.
    /// @param secondsAgos From how long ago each cumulative value should be returned.
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos`.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds-per-liquidity values.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Returns a stored oracle observation by index.
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}
