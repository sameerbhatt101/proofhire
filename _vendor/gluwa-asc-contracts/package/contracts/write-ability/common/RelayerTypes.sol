// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title RelayerTypes
/// @notice Shared types for the RelayerContract and off-chain quotation system.
library RelayerTypes {
    /// @notice Minimum window between a tip payment and its expiry. Shared by
    ///         RelayerContract (initial tip) and RelayerFeeVault (tip increase)
    ///         so the two enforcement points cannot drift apart.
    uint256 internal constant MIN_TIP_WINDOW = 600;

    /// @notice Typehash of the Quoter-signed quote struct. Shared by
    ///         RelayerContract and RelayerContractLite so the off-chain Quoter
    ///         Service signs one format; digests stay contract-specific because
    ///         the signed hash includes the verifying contract address.
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "RelayerQuote(uint256 coreFee,uint256 relayPrice,uint256 acknowledgmentPrice,uint256 gasLimit,uint32 destinationChain,bytes32 payloadHash,address targetContract,uint256 expectedCompletion,uint256 expiry,bool payInNative,uint256 sourceChainId,address verifyingContract)"
    );

    /// @notice A signed fee quote produced by the off-chain Quoter EOA.
    ///
    /// @dev What is signed: { coreFee, relayPrice, acknowledgmentPrice, gasLimit,
    ///      destinationChain, payloadHash, targetContract, expectedCompletion,
    ///      expiry } plus the source chain and verifying contract.
    ///      No messageId (doesn't exist at quote time).
    ///      No payee (open relay — first valid delivery proof wins).
    ///      No paymentToken (ATTEST only).
    ///      No canAck flag — a nonzero acknowledgmentPrice IS the
    ///      acknowledgment request (the Outbox derives canAck from it).
    ///      coreFee is the maximum live core fee the payer authorizes.
    struct Quote {
        /// @notice Maximum core fee in ATTEST authorized by the payer's quote. The
        ///         contract charges the live ASCRelayingQuoter value when it is lower,
        ///         and rejects a live value above this cap.
        uint256 coreFee;
        /// @notice Relay fee: covers destination gas cost + overhead buffer.
        uint256 relayPrice;
        /// @notice Acknowledgment fee set by the off-chain Quoter Service, in
        ///         ATTEST wei regardless of payInNative. A nonzero value IS the
        ///         acknowledgment request — the published message's canAck
        ///         flag is derived from it (there is no separate flag); 0 means
        ///         the message needs no acknowledgment and nothing is collected.
        ///         The payer accepts a nonzero fee by approving (or
        ///         EIP-3009-signing) the quote total; it is routed through the
        ///         Outbox to the AcknowledgmentValidator.
        uint256 acknowledgmentPrice;
        /// @notice Gas limit for destination execution; proposed by the caller and validated
        ///         by the Quoter against eth_estimateGas before signing.
        uint256 gasLimit;
        /// @notice Chain ID of the destination chain.
        uint32  destinationChain;
        /// @notice keccak256(payload). Binds the quote to a specific payload; RelayerContract
        ///         uses this together with targetContract to resolve the messageId from the
        ///         MessagePublished event.
        bytes32 payloadHash;
        /// @notice Source-chain dApp address (emitter). Combined with payloadHash to
        ///         uniquely identify the published message.
        address targetContract;
        /// @notice Unix timestamp of estimated delivery (now + estimated_delivery_time).
        uint256 expectedCompletion;
        /// @notice Unix timestamp after which this quote is no longer valid.
        ///         RelayerContract rejects if block.timestamp >= expiry.
        uint256 expiry;
        /// @notice Fee currency the Quoter priced this quote in. When true,
        ///         relayPrice (and any tip) are native-coin wei (ETH/CTC) paid
        ///         via msg.value; when false they are ATTEST wei pulled by
        ///         transferFrom. The core fee and acknowledgmentPrice are
        ///         ALWAYS ATTEST — they fund the attestor system and the
        ///         AcknowledgmentValidator, not the relayer service.
        bool payInNative;
        /// @notice EIP-191 personal-sign signature produced by an authorized
        ///         Quoter EOA over the typehash-prefixed quote struct hash. The
        ///         hash includes every quote field above, `block.chainid`, and
        ///         the validating `RelayerContract` address.
        bytes signature;
    }

    /// @notice All fee and routing data for a funded message in one view shape.
    ///         Served by RelayerContract.getMessageInfo (the fee ledger lives on
    ///         the RelayerContract; the vault holds tokens only).
    struct MessageInfo {
        address payer;
        uint32  destinationChain;
        uint256 gasLimit;
        uint256 relayFee;
        uint256 tip;
        uint256 tipExpiry;
        uint256 deliveryDeadline;
        bool    relaySettled;
        /// @notice Fee currency this route was funded in (from the signed quote):
        ///         native-coin wei when true, ATTEST wei when false. Top-ups and
        ///         tip increases must use the same currency. (The acknowledgment
        ///         fee is Quoter-set, always ATTEST, and held by the
        ///         AcknowledgmentValidator, not this ledger.)
        bool    feesInNative;
    }

    /// @notice A signed mini-quote authorising a gas limit increase for an in-flight message.
    ///         Produced by the off-chain Quoter after the relayer calls requestTopUp.
    ///         Signed fields also include the source chain and verifying vault address.
    struct TopUpQuote {
        bytes32 messageId;       // message being topped up; must match the vault's recorded messageId
        uint256 newGasLimit;     // replacement gasLimit; must be > current FeeData.gasLimit
        uint256 additionalATTEST; // fee delta the user must pay in ATTEST
        uint256 expiry;          // unix timestamp after which this quote is no longer valid
        /// @notice EIP-191 personal-sign signature produced by an authorized
        ///         Quoter EOA over the typehash-prefixed top-up struct hash. The
        ///         hash includes the four fields above, `block.chainid`, and the
        ///         validating `RelayerFeeVault` address.
        bytes signature;
    }
}
