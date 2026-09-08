// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITWAPReader
/// @notice On-chain interface for reading the CTC/ATTEST time-weighted average price.
interface ITWAPReader {
    /// @notice Returns the 10-minute TWAP: how many CTC units equal 1 ATTEST (18-decimal fixed point).
    /// @dev Used by the RelayerContract to verify the core fee floor:
    ///      coreFee >= feeInCTC / twap()
    function read() external view returns (uint256 ctcPerAttest);
}
