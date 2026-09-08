// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IASCRelayingQuoter} from "./abstract/IASCRelayingQuoter.sol";
import {ITWAPReader} from "./abstract/ITWAPReader.sol";
import {IPenguinSwapV3Pool} from "./abstract/IPenguinSwapV3Pool.sol";
import {V3OracleLibrary} from "./common/v3/V3OracleLibrary.sol";
import {RelayerErrors} from "./error/RelayerErrors.sol";
import {CommonErrors} from "./error/CommonErrors.sol";
import {FullMath} from "./common/v3/FullMath.sol";

/// @title ASCRelayingQuoter
/// @notice On-chain relay fee computation engine.
///
/// @dev Two distinct roles:
///      - QuoterContract (this contract): deterministically computes relay fee in CTC from
///        PricingData set by the oracleService. Also exposes getCoreFee() in ATTEST for
///        Outbox (a fixed, governance-controlled ATTEST amount; see getCoreFee).
///      - Quoter EOA (off-chain): an address in authorizedQuoters that signs the computed
///        fee amounts. RelayerContract verifies the signature and checks the signer against
///        this contract's authorizedQuoters mapping.
///
/// @dev Fee formula (implemented in _quote):
///      fee_in_CTC = (baseFee + gasLimit × dstGasPrice × dstPrice / srcPrice)
///                   × (BPS_DENOMINATOR + priceBuffer) / BPS_DENOMINATOR
///
///      All prices are set by the oracleService with a consistent scale so the units cancel.
///      dstPrice and PricingData.srcPrice use the same scale factor; baseFee is in CTC wei.
///      _quote uses the per-chain PricingData.srcPrice (CTC/USD) — NOT the shared `sourcePrice`
///      anchor below — so its CTC output is mode-independent.
///
/// @dev ATTEST pricing modes (SMC-1681). getAttestPerNative(dstChain) = ATTEST wei per native
///      wei is derived differently per mode:
///        - TWAP mode:         oracle-driven. attestUsd = sourcePrice(CTC/USD) × twapReader.read()
///                             (time-weighted ctcPerAttest) / 1e18; rate = dstPrice(native/USD) ×
///                             1e18 / attestUsd. The off-chain oracle pushes sourcePrice and the
///                             per-chain dstPrice, and accumulates ctcPerAttest into the TWAPReader.
///        - PENGUIN_SWAP mode: pool-driven, no oracle. rate = ctcPerNative × 1e18 / ctcPerAttest,
///                             where both legs are read live on-chain from PenguinSwap (Uniswap-V3)
///                             pools — a global ATTEST→…→CTC path and a PER-DESTINATION-CHAIN
///                             native→…→CTC path. Each leg falls back when its pool is absent:
///                             the ATTEST/CTC leg → twapReader.read(); the native leg → the oracle
///                             USD prices (dstPrice/sourcePrice). The CTC/ATTEST pool always exists.
///      `sourcePrice` (CTC/USD ×1e10) is mode-independent. The legacy _quote() CTC preview uses
///      PricingData.srcPrice and is also mode-independent.
contract ASCRelayingQuoter is IASCRelayingQuoter, Ownable2Step {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    ITWAPReader public twapReader;
    address     public oracleService;

    /// @notice Shared anchor price = CTC/USD, scaled by 1e10. Mode-independent.
    uint64 public sourcePrice;

    /// @notice Active ATTEST pricing mode. Defaults to TWAP.
    PricingMode public pricingMode;

    /// @notice PenguinSwap (Uniswap-V3) pool path converting ATTEST → … → CTC (global; the
    ///         CTC/ATTEST pool always exists). Empty ⇒ ATTEST/CTC leg falls back to the TWAPReader.
    address[] public attestCtcPath;
    /// @notice ATTEST/CTC path endpoints, used to orient hops and validate the route.
    address public attestToken;
    address public ctcToken;

    /// @notice Per-destination-chain PenguinSwap pool path converting that chain's native token
    ///         → … → CTC. Empty ⇒ native leg falls back to oracle USD prices (dstPrice/sourcePrice).
    mapping(uint16 => address[]) public nativeCtcPath;
    /// @notice Per-destination-chain native token address (start of nativeCtcPath).
    mapping(uint16 => address) public nativeToken;

    /// @notice Per-pool observe() window (seconds) for the PenguinSwap short TWAP. Default 5 min.
    uint32 public poolTwapWindow = 300;

    mapping(uint16 => PricingData) public pricingData;

    /// @notice Fixed, governance-controlled core fee per destination chain, denominated in ATTEST.
    mapping(uint16 => uint256)     public coreFeeInAttest;

    /// @notice Acknowledgment fee per destination chain, denominated in ATTEST. Regularly
    ///         updated by the oracleService (it tracks the cost of submitting the ack proof
    ///         back to Creditcoin); the floor for a signed Quote.acknowledgmentPrice.
    mapping(uint16 => uint256)     public acknowledgmentFeeInAttest;

    mapping(address => bool) public authorizedQuoters;
    address[] private _quoterList;

    event OracleServiceChanged(address indexed oldOracle, address indexed newOracle);
    event TWAPReaderChanged(address indexed oldReader, address indexed newReader);
    event QuoterAdded(address indexed quoter);
    event QuoterRemoved(address indexed quoter);
    event PriceUpdated(uint64 indexed newSourcePrice, uint16 indexed chainId);
    event CoreFeeUpdated(uint16 indexed chainId, uint256 indexed newCoreFeeInAttest);
    event AcknowledgmentFeeUpdated(uint16 indexed chainId, uint256 indexed newAcknowledgmentFeeInAttest);
    event AttestCtcPoolPathUpdated(address attestToken, address ctcToken, address[] path, uint32 poolTwapWindow);
    event NativeCtcPoolPathUpdated(uint16 indexed dstChain, address nativeToken, address[] path);

    modifier onlyOracle() {
        if (msg.sender != oracleService) revert RelayerErrors.UnauthorizedOracle(msg.sender);
        _;
    }

    constructor(
        address initialOwner,
        address twapReader_,
        address oracleService_
    ) Ownable(initialOwner) {
        if (twapReader_ == address(0) || oracleService_ == address(0))
            revert CommonErrors.ZeroAddress();
        twapReader    = ITWAPReader(twapReader_);
        oracleService = oracleService_;
    }

    /// @dev targetContract and payloadHash are not used in the formula but are present
    ///      in the call so the Quoter EOA can sign them alongside the computed fee,
    ///      binding the signature to this exact payload and destination.
    function requestQuote(
        uint16  dstChain,
        address /* targetContract */,
        bytes32 /* payloadHash */,
        uint256 gasLimit
    ) external view override returns (uint256 requiredPaymentInCTC) {
        return _quote(dstChain, gasLimit);
    }

    function requestQuoteInAttest(
        uint16 dstChain,
        address,
        bytes32,
        uint256 gasLimit
    ) external view override returns (uint256 requiredPaymentInATTEST) {
        uint256 ctcPerAttest = _ctcPerAttest();
        if (ctcPerAttest == 0) revert RelayerErrors.InvalidPoolPrice();

        uint256 requiredPaymentInCTC = _quote(dstChain, gasLimit);
        requiredPaymentInATTEST = FullMath.mulDiv(
            requiredPaymentInCTC,
            1e18,
            ctcPerAttest
        );
        if (mulmod(requiredPaymentInCTC, 1e18, ctcPerAttest) != 0) {
            ++requiredPaymentInATTEST;
        }
    }

    function requestExecutionQuote(
        uint16  dstChain,
        address targetContract,
        bytes32 payloadHash,
        uint256 gasLimit
    ) external override returns (uint256 requiredPaymentInCTC) {
        requiredPaymentInCTC = _quote(dstChain, gasLimit);
        emit ExecutionQuoteRequested(dstChain, targetContract, payloadHash, gasLimit, requiredPaymentInCTC);
    }

    /// @dev The core fee is stored directly in ATTEST and is mode-independent (it does not
    ///      depend on the active PricingMode or the TWAP reader).
    function getCoreFee(uint16 dstChain) external view override returns (uint256 coreFeeATTEST) {
        return coreFeeInAttest[dstChain];
    }

    function setPricingMode(PricingMode newMode, uint64 newSourcePrice) external override onlyOracle {
        if (newSourcePrice == 0) revert RelayerErrors.SourcePriceNotSet();
        pricingMode = newMode;
        sourcePrice = newSourcePrice;
        emit PricingModeUpdated(newMode, newSourcePrice);
    }

    /// @dev ATTEST/USD reference price = CTC/USD (oracle `sourcePrice`) × ctcPerAttest / 1e18,
    ///      where ctcPerAttest is the mode-sourced ATTEST/CTC price. This is a USD-denominated
    ///      reference view; the fee-critical conversion is getAttestPerNative.
    function getAttestUsdPrice() public view override returns (uint256 attestUsd) {
        uint64 anchor = sourcePrice; // CTC/USD ×1e10
        if (anchor == 0) revert RelayerErrors.SourcePriceNotSet();

        uint256 ctcPerAttest = _ctcPerAttest();
        if (ctcPerAttest == 0) revert RelayerErrors.InvalidPoolPrice();

        attestUsd = uint256(anchor) * ctcPerAttest / 1e18;
        if (attestUsd == 0) revert RelayerErrors.InvalidPoolPrice();
    }

    function getAttestPerNative(uint16 dstChain) external view override returns (uint256 attestPerNative) {
        uint256 ctcPerAttest = _ctcPerAttest();
        if (ctcPerAttest == 0) revert RelayerErrors.InvalidPoolPrice();

        // CTC wei per native wei (1e18 fp): from the per-chain pool path, or oracle USD fallback.
        uint256 ctcPerNative = _ctcPerNative(dstChain);

        // ATTEST per native = (CTC per native) / (CTC per ATTEST).
        attestPerNative = ctcPerNative * 1e18 / ctcPerAttest;
    }

    /// @dev ATTEST/CTC (CTC wei per ATTEST wei, 1e18 fp). PENGUIN_SWAP mode reads the global
    ///      ATTEST→…→CTC pool path when configured; otherwise (and in TWAP mode) it uses the
    ///      time-weighted TWAPReader.
    function _ctcPerAttest() internal view returns (uint256) {
        if (pricingMode == PricingMode.PENGUIN_SWAP && attestCtcPath.length != 0) {
            return _composePoolPath(attestCtcPath, attestToken, ctcToken);
        }
        return twapReader.read();
    }

    /// @dev CTC wei per native wei (1e18 fp) for `dstChain`. PENGUIN_SWAP mode reads the per-chain
    ///      native→…→CTC pool path when configured; otherwise falls back to the oracle USD prices
    ///      (CTC per native = dstPrice / sourcePrice, both USD-denominated so the scale cancels).
    function _ctcPerNative(uint16 dstChain) internal view returns (uint256) {
        address[] storage path = nativeCtcPath[dstChain];
        if (pricingMode == PricingMode.PENGUIN_SWAP && path.length != 0) {
            return _composePoolPath(path, nativeToken[dstChain], ctcToken);
        }
        // Oracle fallback.
        uint256 nativeUsd = pricingData[dstChain].dstPrice;
        if (nativeUsd == 0) revert RelayerErrors.DestinationPriceNotSet(dstChain);
        uint64 ctcUsd = sourcePrice;
        if (ctcUsd == 0) revert RelayerErrors.SourcePriceNotSet();
        return nativeUsd * 1e18 / ctcUsd;
    }

    /// @dev Composes a PenguinSwap V3 pool path from `tokenIn` to `expectedOut`, returning the
    ///      price of tokenIn denominated in expectedOut as an 18-decimal fixed-point value.
    ///      Assumes 18-decimal tokens along the path. Reverts if the path is empty, non-contiguous,
    ///      or does not end at `expectedOut`.
    function _composePoolPath(
        address[] memory path,
        address tokenIn,
        address expectedOut
    ) internal view returns (uint256 priceWad) {
        uint256 len = path.length;
        if (len == 0) revert RelayerErrors.InvalidPoolPath();

        priceWad = 1e18;
        for (uint256 i = 0; i < len; ++i) {
            address pool = path[i];
            address t0 = IPenguinSwapV3Pool(pool).token0();
            address t1 = IPenguinSwapV3Pool(pool).token1();
            address tokenOut;
            if (tokenIn == t0) tokenOut = t1;
            else if (tokenIn == t1) tokenOut = t0;
            else revert RelayerErrors.InvalidPoolPath();

            uint32 secondsAgo = _poolSecondsAgo(pool);
            int24 meanTick = V3OracleLibrary.consult(pool, secondsAgo);
            // tokenOut amount per 1e18 (1.0) tokenIn = WAD price of tokenIn in tokenOut.
            uint256 hopWad = V3OracleLibrary.getQuoteAtTick(meanTick, 1e18, tokenIn, tokenOut);
            priceWad = priceWad * hopWad / 1e18;
            tokenIn = tokenOut;
        }
        if (tokenIn != expectedOut) revert RelayerErrors.InvalidPoolPath();
    }

    /// @dev Requires the full configured window; a fresh pool cannot silently become a spot oracle.
    function _poolSecondsAgo(address pool) internal view returns (uint32 secondsAgo) {
        uint32 oldest = V3OracleLibrary.getOldestObservationSecondsAgo(pool);
        uint32 w = poolTwapWindow;
        if (oldest < w) {
            revert RelayerErrors.InsufficientPoolHistory(oldest, w);
        }
        secondsAgo = w;
    }

    function priceUpdate(
        uint64 newSourcePrice,
        uint16 chainId,
        PricingData calldata price
    ) external override onlyOracle {
        if (newSourcePrice == 0) revert RelayerErrors.SourcePriceNotSet();
        sourcePrice          = newSourcePrice;
        pricingData[chainId] = price;
        emit PriceUpdated(newSourcePrice, chainId);
    }

    function batchPriceUpdate(
        uint64 newSourcePrice,
        uint16[] calldata chainIds,
        PricingData[] calldata prices
    ) external override onlyOracle {
        if (newSourcePrice == 0) revert RelayerErrors.SourcePriceNotSet();
        uint256 length = chainIds.length;
        if (length != prices.length)
            revert RelayerErrors.ArrayLengthMismatch(length, prices.length);
        sourcePrice = newSourcePrice;
        for (uint256 i = 0; i < length; ++i) {
            pricingData[chainIds[i]] = prices[i];
            emit PriceUpdated(newSourcePrice, chainIds[i]);
        }
    }

    /// @notice Set the governance-controlled core fee for a destination chain.
    /// @param dstChain  Destination chain ID.
    /// @param newCoreFeeInAttest  Core fee in ATTEST wei; returned as-is by getCoreFee.
    function setCoreFee(uint16 dstChain, uint256 newCoreFeeInAttest) external onlyOwner {
        coreFeeInAttest[dstChain] = newCoreFeeInAttest;
        emit CoreFeeUpdated(dstChain, newCoreFeeInAttest);
    }

    /// @dev The acknowledgment fee is stored directly in ATTEST and is mode-independent.
    function getAcknowledgmentFee(
        uint16 dstChain
    ) external view override returns (uint256 acknowledgmentFeeATTEST) {
        return acknowledgmentFeeInAttest[dstChain];
    }

    /// @notice Set the acknowledgment fee for a destination chain. Callable only by
    ///         oracleService so it can be refreshed regularly alongside price updates.
    /// @param dstChain  Destination chain ID.
    /// @param newAcknowledgmentFeeInAttest  Ack fee in ATTEST wei; returned as-is by
    ///        getAcknowledgmentFee and enforced by RelayerContract as the floor for a
    ///        signed Quote.acknowledgmentPrice.
    function setAcknowledgmentFee(
        uint16 dstChain,
        uint256 newAcknowledgmentFeeInAttest
    ) external override onlyOracle {
        acknowledgmentFeeInAttest[dstChain] = newAcknowledgmentFeeInAttest;
        emit AcknowledgmentFeeUpdated(dstChain, newAcknowledgmentFeeInAttest);
    }

    /// @notice Authorize a Quoter EOA to sign relay fee quotes.
    function addQuoter(address quoter) external onlyOwner {
        if (quoter == address(0)) revert CommonErrors.ZeroAddress();
        if (authorizedQuoters[quoter]) revert RelayerErrors.QuoterAlreadyAuthorized(quoter);
        authorizedQuoters[quoter] = true;
        _quoterList.push(quoter);
        emit QuoterAdded(quoter);
    }

    /// @notice Remove a Quoter EOA from the authorized set.
    function removeQuoter(address quoter) external onlyOwner {
        if (!authorizedQuoters[quoter]) revert RelayerErrors.QuoterNotAuthorized(quoter);
        authorizedQuoters[quoter] = false;
        uint256 len = _quoterList.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_quoterList[i] == quoter) {
                _quoterList[i] = _quoterList[len - 1];
                _quoterList.pop();
                break;
            }
        }
        emit QuoterRemoved(quoter);
    }

    function getAuthorizedQuoters() external view override returns (address[] memory) {
        return _quoterList;
    }

    function isAuthorizedQuoter(address quoter) external view override returns (bool) {
        return authorizedQuoters[quoter];
    }

    function setOracleService(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert CommonErrors.ZeroAddress();
        emit OracleServiceChanged(oracleService, newOracle);
        oracleService = newOracle;
    }

    function setTWAPReader(address newReader) external onlyOwner {
        if (newReader == address(0)) revert CommonErrors.ZeroAddress();
        emit TWAPReaderChanged(address(twapReader), newReader);
        twapReader = ITWAPReader(newReader);
    }

    /// @notice Configure the global ATTEST→…→CTC PenguinSwap V3 pool path. Owner only.
    /// @param attestToken_     ATTEST token address (path start).
    /// @param ctcToken_        CTC token address (path end).
    /// @param path             Ordered V3 pool addresses converting ATTEST → … → CTC (length ≥ 1).
    /// @param poolTwapWindow_  Per-pool observe() window in seconds (must be > 0).
    /// @dev Validates the path is contiguous and ends at CTC, so misconfiguration fails at set
    ///      time. The CTC/ATTEST pool always exists, so this is normally a single-pool path.
    function setAttestCtcPool(
        address attestToken_,
        address ctcToken_,
        address[] calldata path,
        uint32 poolTwapWindow_
    ) external onlyOwner {
        if (attestToken_ == address(0) || ctcToken_ == address(0)) revert CommonErrors.ZeroAddress();
        if (poolTwapWindow_ == 0) revert RelayerErrors.InvalidPoolPath();
        _validatePath(path, attestToken_, ctcToken_);

        attestToken    = attestToken_;
        ctcToken       = ctcToken_;
        attestCtcPath  = path;
        poolTwapWindow = poolTwapWindow_;
        emit AttestCtcPoolPathUpdated(attestToken_, ctcToken_, path, poolTwapWindow_);
    }

    /// @notice Configure the per-destination-chain native→…→CTC PenguinSwap V3 pool path. Owner only.
    /// @param dstChain      Destination chain ID.
    /// @param nativeToken_  That chain's native (wrapped) token address (path start).
    /// @param path          Ordered V3 pool addresses converting native → … → CTC (length ≥ 1).
    /// @dev When unset for a chain, PENGUIN_SWAP mode falls back to the oracle USD prices for the
    ///      native leg. `ctcToken` must already be configured via setAttestCtcPool.
    function setNativeCtcPool(
        uint16 dstChain,
        address nativeToken_,
        address[] calldata path
    ) external onlyOwner {
        if (nativeToken_ == address(0)) revert CommonErrors.ZeroAddress();
        if (ctcToken == address(0)) revert RelayerErrors.InvalidPoolPath();
        _validatePath(path, nativeToken_, ctcToken);

        nativeToken[dstChain]  = nativeToken_;
        nativeCtcPath[dstChain] = path;
        emit NativeCtcPoolPathUpdated(dstChain, nativeToken_, path);
    }

    /// @dev Reverts unless `path` is a non-empty, contiguous V3 pool route from `tokenIn` to `out`.
    function _validatePath(address[] calldata path, address tokenIn, address out) internal view {
        uint256 length = path.length;
        if (length == 0) revert RelayerErrors.InvalidPoolPath();
        for (uint256 i = 0; i < length; ++i) {
            if (path[i] == address(0)) revert CommonErrors.ZeroAddress();
            address t0 = IPenguinSwapV3Pool(path[i]).token0();
            address t1 = IPenguinSwapV3Pool(path[i]).token1();
            if (tokenIn == t0) tokenIn = t1;
            else if (tokenIn == t1) tokenIn = t0;
            else revert RelayerErrors.InvalidPoolPath();
        }
        if (tokenIn != out) revert RelayerErrors.InvalidPoolPath();
    }

    /// @dev fee = (baseFee + gasLimit × dstGasPrice × dstPrice / srcPrice)
    ///            × (BPS_DENOMINATOR + priceBuffer) / BPS_DENOMINATOR
    ///      Uses the per-chain PricingData.srcPrice (CTC/USD), NOT the shared `sourcePrice`
    ///      anchor, so the CTC output is independent of the active PricingMode. dstPrice and
    ///      srcPrice share the same USD scale, so the units cancel to CTC.
    function _quote(uint16 dstChain, uint256 gasLimit)
        internal view
        returns (uint256 feeInCTC)
    {
        PricingData storage p = pricingData[dstChain];
        if (p.srcPrice == 0) revert RelayerErrors.SourcePriceNotSet();
        if (p.dstPrice == 0) revert RelayerErrors.DestinationPriceNotSet(dstChain);
        uint256 gasCostInCTC  = gasLimit * p.dstGasPrice * p.dstPrice / p.srcPrice;
        feeInCTC = (p.baseFee + gasCostInCTC)
                   * (BPS_DENOMINATOR + p.priceBuffer)
                   / BPS_DENOMINATOR;
    }
}
