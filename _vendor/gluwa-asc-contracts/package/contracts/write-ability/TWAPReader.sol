// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ITWAPReader} from "./abstract/ITWAPReader.sol";
import {RelayerErrors} from "./error/RelayerErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {FullMath} from "./common/v3/FullMath.sol";

/// @title TWAPReader
/// @notice On-chain time-weighted average price of ATTEST denominated in CTC (ctcPerAttest,
///         18-decimal fixed point). An off-chain oracle/backend pushes spot observations
///         periodically (e.g. every few minutes); this contract accumulates them and exposes
///         the time-weighted average over a configurable trailing window via read().
///
/// @dev Uses the Uniswap-V2 cumulative-price technique: it tracks a running
///      `cumulative += lastPrice × elapsed` and snapshots `{timestamp, cumulative}` into a ring
///      buffer on every push. read() interpolates the cumulative value at the exact
///      `now − window` boundary and divides by the configured window. Reads revert until the
///      retained observations span the full configured window. This is the concrete implementation
///      of ITWAPReader consumed by ASCRelayingQuoter in TWAP pricing mode.
contract TWAPReader is ITWAPReader, Ownable2Step {
    /// @dev Number of snapshots retained. At a ~5-min push cadence this spans >2.5 h, far beyond
    ///      any reasonable window, so read() can always reach back a full window.
    uint256 private constant BUFFER_SIZE = 32;

    struct Observation {
        uint32  timestamp;
        uint256 cumulative;
    }

    address public oracleService;

    /// @notice Trailing averaging window in seconds (default 10 minutes).
    uint32 public window = 600;

    /// @notice Maximum age of the latest oracle push (default one hour).
    uint32 public maxPriceAge = 3600;

    /// @notice Most recently pushed spot price (ctcPerAttest, 1e18 fixed point).
    uint256 public lastPrice;
    /// @notice Timestamp of the most recent push.
    uint32 public lastTimestamp;
    /// @notice Running price·time accumulator up to lastTimestamp.
    uint256 public cumulative;

    Observation[BUFFER_SIZE] private _observations;
    /// @notice Index of the most recent observation in the ring buffer.
    uint256 public obsIndex;
    /// @notice Number of populated observations (caps at BUFFER_SIZE).
    uint256 public obsCount;

    event OracleServiceChanged(address indexed oldOracle, address indexed newOracle);
    event WindowChanged(uint32 indexed oldWindow, uint32 indexed newWindow);
    event MaxPriceAgeChanged(uint32 indexed oldMaxPriceAge, uint32 indexed newMaxPriceAge);
    event PriceObserved(uint256 indexed spotPrice, uint256 indexed cumulative, uint32 indexed timestamp);

    modifier onlyOracle() {
        if (msg.sender != oracleService) revert RelayerErrors.UnauthorizedOracle(msg.sender);
        _;
    }

    constructor(address initialOwner, address oracleService_) Ownable(initialOwner) {
        if (oracleService_ == address(0)) revert CommonErrors.ZeroAddress();
        oracleService = oracleService_;
    }

    /// @notice Push a new spot ctcPerAttest observation. Callable only by oracleService.
    /// @param spotPrice CTC wei per ATTEST wei (1e18 fixed point); must be non-zero.
    function update(uint256 spotPrice) external onlyOracle {
        if (spotPrice == 0) revert RelayerErrors.InvalidPoolPrice();

        uint32 nowTs = uint32(block.timestamp);
        bool overwriteLatest = obsCount != 0 && nowTs == lastTimestamp;
        if (lastTimestamp != 0) {
            // Accumulate the elapsed segment at the previous price.
            cumulative += lastPrice * (nowTs - lastTimestamp);
        }

        lastPrice = spotPrice;
        lastTimestamp = nowTs;

        // Multiple oracle transactions can be included in one block. They all
        // describe the price active from the same timestamp, so keep only the
        // final value instead of consuming ring-buffer history with zero-time
        // observations.
        uint256 newIndex = overwriteLatest
            ? obsIndex
            : obsCount == 0 ? 0 : (obsIndex + 1) % BUFFER_SIZE;
        _observations[newIndex] = Observation({timestamp: nowTs, cumulative: cumulative});
        obsIndex = newIndex;
        if (!overwriteLatest && obsCount < BUFFER_SIZE) ++obsCount;

        emit PriceObserved(spotPrice, cumulative, nowTs);
    }

    /// @dev Returns the time-weighted ctcPerAttest over the trailing `window`.
    ///      Reverts if the latest observation is stale or the full window is unavailable.
    function read() external view override returns (uint256 ctcPerAttest) {
        if (obsCount == 0) revert RelayerErrors.SourcePriceNotSet();

        uint32 nowTs = uint32(block.timestamp);
        if (nowTs - lastTimestamp > maxPriceAge) {
            revert RelayerErrors.StalePrice(lastTimestamp, nowTs);
        }
        uint256 nowCumulative = cumulative + lastPrice * (nowTs - lastTimestamp);

        uint32 target = window >= nowTs ? 0 : nowTs - window;
        Observation memory oldest = _oldestObservation();
        if (oldest.timestamp > target) {
            revert RelayerErrors.InsufficientPoolHistory(
                nowTs - oldest.timestamp,
                window
            );
        }

        uint256 targetCumulative = _cumulativeAt(target);
        return (nowCumulative - targetCumulative) / window;
    }

    /// @dev Returns the cumulative price at an exact timestamp covered by retained history.
    ///      Between two observations, the active price is constant, so cumulative price is linear.
    function _cumulativeAt(uint32 target) private view returns (uint256) {
        if (target >= lastTimestamp) {
            return cumulative + lastPrice * (target - lastTimestamp);
        }

        uint256 count = obsCount;
        uint256 idx = obsIndex;
        Observation memory afterObservation = _observations[idx];
        for (uint256 i = 0; i < count; ++i) {
            Observation memory obs = _observations[idx];
            if (obs.timestamp == target) {
                return obs.cumulative;
            }
            if (obs.timestamp < target) {
                uint256 segmentCumulative =
                    afterObservation.cumulative - obs.cumulative;
                uint32 segmentSeconds =
                    afterObservation.timestamp - obs.timestamp;
                return obs.cumulative + FullMath.mulDiv(
                    segmentCumulative,
                    target - obs.timestamp,
                    segmentSeconds
                );
            }

            afterObservation = obs;
            idx = idx == 0 ? BUFFER_SIZE - 1 : idx - 1;
        }

        // read() proves that the target is covered before calling this helper.
        assert(false);
        return 0;
    }

    function _oldestObservation() private view returns (Observation memory) {
        uint256 oldestIndex =
            (obsIndex + BUFFER_SIZE + 1 - obsCount) % BUFFER_SIZE;
        return _observations[oldestIndex];
    }

    /// @notice Update the trailing averaging window (seconds). Owner only.
    function setWindow(uint32 newWindow) external onlyOwner {
        if (newWindow == 0) revert RelayerErrors.InvalidPoolPrice();
        emit WindowChanged(window, newWindow);
        window = newWindow;
    }

    /// @notice Update the maximum permitted age of the latest oracle push.
    function setMaxPriceAge(uint32 newMaxPriceAge) external onlyOwner {
        if (newMaxPriceAge == 0) revert RelayerErrors.InvalidPoolPrice();
        emit MaxPriceAgeChanged(maxPriceAge, newMaxPriceAge);
        maxPriceAge = newMaxPriceAge;
    }

    /// @notice Update the authorized oracle service. Owner only.
    function setOracleService(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert CommonErrors.ZeroAddress();
        emit OracleServiceChanged(oracleService, newOracle);
        oracleService = newOracle;
    }
}
