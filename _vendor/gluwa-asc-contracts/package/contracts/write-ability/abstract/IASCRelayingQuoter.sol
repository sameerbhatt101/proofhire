// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IASCRelayingQuoter
/// @notice On-chain computation engine for relay fees. Authoritative fee floor used
///         by RelayerContract to verify that signed quote amounts are not under-priced.
///         Also queried directly by Outbox.publishMessage for the live core fee.
interface IASCRelayingQuoter {
    /// @notice ATTEST pricing modes. Both modes derive the ATTEST↔native rate from CTC/USD
    ///         (`sourcePrice`), dstNative/USD (`pricingData.dstPrice`) and ATTEST/CTC
    ///         (ctcPerAttest); they differ only in the SOURCE of ctcPerAttest.
    /// @dev    TWAP         — ctcPerAttest is the time-weighted average the off-chain oracle
    ///                        accumulates into the on-chain TWAPReader (read via twapReader.read()).
    ///         PENGUIN_SWAP — ctcPerAttest is read live on-chain from the PenguinSwap (Uniswap-V3)
    ///                        ATTEST→…→CTC pool path.
    enum PricingMode {
        TWAP,
        PENGUIN_SWAP
    }

    /// @notice Per-destination-chain pricing parameters, updated by oracleService.
    struct PricingData {
        uint256 baseFee;      // base overhead fee in CTC
        uint256 dstGasPrice;  // destination chain gas price in dst native token
        uint256 dstPrice;     // destination chain native token USD price (scaled by 1e10)
        uint256 srcPrice;     // CTC/USD price (scaled) — needed for USD→CTC conversion
        uint16  priceBuffer;  // basis-point buffer; absorbs gas price drift between quote and execution
    }

    /// @notice Pure fee preview — does not emit an event.
    ///         targetContract and payloadHash are required so the Quoter EOA can bind its
    ///         signature to the exact payload and destination that were priced. The fee
    ///         formula does not depend on them, but they must be present so the signed
    ///         quote is unambiguously tied to a specific on-chain requestQuote invocation.
    function requestQuote(
        uint16  dstChain,
        address targetContract,
        bytes32 payloadHash,
        uint256 gasLimit
    ) external view returns (uint256 requiredPaymentInCTC);

    /// @notice Authoritative relay-fe floor denominated in ATTEST.
    function requestQuoteInAttest(
        uint16 dstChain,
        address targetContract,
        bytes32 payloadHash,
        uint256 gasLimit
    ) external view returns (uint256 requiredPaymentInATTEST);

    /// @notice Stateful quote — emits ExecutionQuoteRequested.
    ///         Same params as requestQuote; the emitted event creates an on-chain record
    ///         that the Quoter EOA signs against off-chain after this call.
    function requestExecutionQuote(
        uint16  dstChain,
        address targetContract,
        bytes32 payloadHash,
        uint256 gasLimit
    ) external returns (uint256 requiredPaymentInCTC);

    /// @notice Push new prices for a single chain. Callable only by oracleService.
    function priceUpdate(
        uint64 newSourcePrice,
        uint16 chainId,
        PricingData calldata price
    ) external;

    /// @notice Push new prices for multiple chains atomically. Callable only by oracleService.
    function batchPriceUpdate(
        uint64 newSourcePrice,
        uint16[] calldata chainIds,
        PricingData[] calldata prices
    ) external;

    /// @notice Returns the live core fee in ATTEST for the given destination chain.
    ///         Used by Outbox.publishMessage to determine how much ATTEST to pull from the caller.
    ///         The core fee is a fixed, governance-controlled ATTEST amount (stored directly in
    ///         ATTEST, mode-independent). No Quoter signature is required to accept this value.
    function getCoreFee(uint16 dstChain) external view returns (uint256 coreFeeATTEST);

    /// @notice Returns the live acknowledgment fee in ATTEST for the given destination chain.
    ///         Enforced by RelayerContract as the floor for a signed Quote.acknowledgmentPrice
    ///         when the quote requests acknowledgment. Stored directly in ATTEST,
    ///         mode-independent, and refreshed regularly by the oracleService.
    function getAcknowledgmentFee(
        uint16 dstChain
    ) external view returns (uint256 acknowledgmentFeeATTEST);

    /// @notice Update the acknowledgment fee for a destination chain. Callable only by
    ///         oracleService so it can be refreshed regularly alongside price updates.
    function setAcknowledgmentFee(
        uint16 dstChain,
        uint256 newAcknowledgmentFeeInAttest
    ) external;

    /// @notice Switch the active ATTEST pricing mode and (re)set the shared CTC/USD anchor price.
    /// @dev    Callable only by oracleService. `sourcePrice` (CTC/USD) is mode-independent; the
    ///         price is accepted here so a mode switch can be paired with a fresh anchor in one
    ///         transaction. `newSourcePrice` must be non-zero.
    /// @param  newMode        The pricing mode to activate.
    /// @param  newSourcePrice CTC/USD price, scaled by 1e10.
    function setPricingMode(PricingMode newMode, uint64 newSourcePrice) external;

    /// @notice ATTEST/USD reference price, scaled by 1e10.
    /// @dev    `sourcePrice (CTC/USD) × ctcPerAttest / 1e18`, where ctcPerAttest comes from the
    ///         PenguinSwap ATTEST/CTC pool path (PENGUIN_SWAP mode, when configured) or the
    ///         TWAPReader. USD-denominated reference; the fee conversion is getAttestPerNative.
    function getAttestUsdPrice() external view returns (uint256 attestUsd);

    /// @notice ATTEST↔native conversion rate for `dstChain`: ATTEST wei per 1 native wei,
    ///         as an 18-decimal fixed-point value. Tokens are assumed to be 18-decimal.
    /// @dev    rate = ctcPerNative × 1e18 / ctcPerAttest. In PENGUIN_SWAP mode both legs are read
    ///         from PenguinSwap V3 pools (global ATTEST/CTC path; per-chain native/CTC path), each
    ///         falling back when its pool is absent (ATTEST/CTC → TWAPReader; native → oracle USD).
    ///         In TWAP mode both legs are oracle-derived (TWAPReader ctcPerAttest; dstPrice/sourcePrice).
    function getAttestPerNative(uint16 dstChain) external view returns (uint256 attestPerNative);

    /// @notice Returns all Quoter EOA addresses currently authorized to sign quotes.
    function getAuthorizedQuoters() external view returns (address[] memory);

    /// @notice Returns whether an address is an authorized Quoter EOA.
    function isAuthorizedQuoter(address quoter) external view returns (bool);

    event ExecutionQuoteRequested(
        uint16  indexed dstChain,
        address indexed targetContract,
        bytes32 payloadHash,
        uint256 gasLimit,
        uint256 requiredPaymentInCTC
    );

    /// @notice Emitted when oracleService switches the active pricing mode (with fresh price).
    event PricingModeUpdated(PricingMode indexed newMode, uint64 newSourcePrice);
}
