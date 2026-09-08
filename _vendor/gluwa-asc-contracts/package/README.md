# ASC Contracts

This repository is responsible for housing the core smart contracts necessary to support
Attestcoin Smart Contracts (ASC) on the Gluwa Creditcoin Network.

For a deeper explanation of how the contracts below relate to each other — including sequence
diagrams for the publish → attest → deliver → acknowledge flow and the relayer-assisted fee-payment
flow — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Repository layout

```
contracts/
├── common/           # shared libraries used by write-ability and readability (e.g. EvmV1Decoder)
├── mocks/            # test-only helpers; excluded from the published npm package
├── readability/      # ASCBase and other readability ASC primitives
└── write-ability/
    ├── *.sol          # core messaging + fee/relaying contracts (see below)
    ├── deployer/      # OutboxDeployer (versioned factory registry/access control) +
    │                  # OutboxFactory (CREATE2 deployer for Outbox)
    ├── abstract/      # interfaces implemented by the contracts above
    ├── common/        # shared libraries: storage layout, decoding, proof verification, oracle
    │                  # math, the relayer fee ledger, token-bridge helper types
    └── error/         # custom-error libraries shared across contracts
```

## Readability base

1. `ASCBase` (`contracts/readability/ASCBase.sol`) — abstract base for readability ASCs. Verifies
   foreign-chain transaction proofs via the native block-prover precompile (`0xFD2`), dedupes by
   query id, then delegates to `_processAndEmitEvent`. Bridge and loan examples inherit this.

## Shared decoding libraries

1. `EvmV1Decoder` (`contracts/common/EvmV1Decoder.sol`) - decodes the tx/receipt data
   of an EVM transaction (fields, logs, log filtering by event signature). Shared by write-ability
   contracts (acknowledgment / delivery decoding) and readability ASCs that parse proven transactions.

## Readability-adjacent decoding libraries

1. `ASCSdkV1TxBytesLib` (`contracts/write-ability/common/ASCSdkV1TxBytesLib.sol`) - decodes the
   prover's chunked `(txType, bytes[] chunks)` transaction encoding into a flat, typed struct, handling
   legacy and EIP-1559-style transactions.

## Writability Contracts

The write-ability layer lets a dApp on Creditcoin publish a message that is attested by the
validator/attestor set, relayed to a destination chain, and (optionally) acknowledged back on
Creditcoin via a trust-minimized native proof. It splits into a core messaging path and an optional
fee/relaying layer built on top of it — see the class and sequence diagrams in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how the two interact.

### Core messaging

1. `Outbox` (`Outbox.sol`) / `OutboxFactory` (`deployer/OutboxFactory.sol`) / `OutboxDeployer`
   (`deployer/OutboxDeployer.sol`) - source-side message publishing. `OutboxDeployer` registers and
   enables versioned `OutboxFactory` implementations and is the intended (owner-gated) caller of
   `deployOutbox`; the factory's own `deployOutbox` is permissionless but CREATE2-salts on
   `msg.sender`, so a stray direct call can't collide with a deployment made through the deployer.
   Each `Outbox` gets its own owner/validator/rate-limit/`AttestorVault`/`FeeRegistry`/ATTEST-token
   configuration. `publishMessage(canAck, payload)` derives a per-emitter sequenced `messageId` and
   pulls `coreFee` from the configured `FeeRegistry`; `publishMessageFrom` lets a registered trusted
   forwarder (e.g. `RelayerContract`/`RelayerContractLite`) publish on a dApp's behalf, but only for
   emitters that separately opted in via `approveForwarder`; `routeCoreFee`/`routeAckFee` let a
   trusted forwarder deposit the core fee and an acknowledgment-fee bounty after the fact (the
   latter upgrading a message published with `canAck = false`); `acknowledgeMessage`/
   `batchAcknowledgeMessages` are gated on the configured `validator`.
2. `Inbox` (`Inbox.sol`, formerly `SimpleInbox.sol`) - destination-side delivery contract. Delivers
   to a single fixed `messageDispatcher` (an `IMessageReceiver`, typically built on the
   `MessageReceiverBase` abstract helper) configured at construction, rather than a destination
   decoded from the payload. Delegates vote checking to a pluggable `IVoteValidator`, supports
   pending/retry delivery, is `Ownable2Step` + `Pausable` (owner can `pause()`/`unpause()` message
   delivery), and reverts with custom errors (`error/InboxErrors.sol`) instead of strings.
3. `EOAValidator` (`EOAValidator.sol`) - the production `IVoteValidator`: ECDSA recover against an
   attestor set with a configurable quorum (`numerator/denominator + addition`, commonly set up as a
   `2N/3 + 1` threshold), EIP-2 malleability hardening, and replay-protected, permissionless
   attestor-set updates signed by the current attestor set. Attestor membership itself now lives in
   the shared `AttestorRegistry` rather than a local mapping on this contract.
4. `AttestorRegistry` (`AttestorRegistry.sol`) - standalone, owner-managed attestor set shared by
   every consumer that needs attestor membership (`EOAValidator`, `AttestorVault.settle`), so the set
   is maintained and audited in one place instead of duplicated per-consumer. An owner-authorized
   updater (typically `EOAValidator`, for its attestor-voted `submitAttestorSetUpdate`) may also
   add/remove/replace attestors.
5. `AcknowledgmentValidator` (`AcknowledgementValidator.sol`) - proof-based acknowledgment, run on
   the source chain. It verifies a proof via the shared `ASCProofVerifier` (the same verifier
   `RelayerContract.claimDelivery` uses) that a `MessageDelivered` event was emitted by a trusted
   destination `Inbox`, decodes the log with `EvmV1Decoder`, and calls `Outbox.acknowledgeMessage`.
   Submission is permissionless - the proof is self-validating. It also custodies each message's
   user-set acknowledgment-fee bounty (deposited by `Outbox.routeAckFee`) and pays it to whoever
   submits the winning proof, with a 7-day payer refund path (`refundAckFee`) if no proof arrives.

### Fee & relaying layer

6. `RelayerContract` (`RelayerContract.sol`) / `RelayerContractLite` (`RelayerContractLite.sol`) -
   `Outbox` trusted forwarders that let a relayer front the publish call for a dApp. Both validate an
   off-chain-signed `RelayerTypes.Quote` (`common/RelayerTypes.sol`), pull `coreFee + relayPrice +
acknowledgmentPrice` (`+ tip`, full variant only) from the payer (ERC-20 transfer, EIP-3009
   authorization, or native coin for `payInNative` quotes), forward the core/ack fees through
   `Outbox.routeCoreFee`/`routeAckFee`, and deposit the relay reward (+ tip) into the active
   `RelayerFeeVault`. A quote's `acknowledgmentPrice > 0` is the acknowledgment request - there is
   no separate `canAck`/`requiresAck` argument any more. `RelayerContractLite` drops tips and
   on-chain quote-floor checking (no `ASCRelayingQuoter` dependency; quotes are checked against an
   owner-managed whitelist of off-chain Quoter EOAs instead) for a cheaper, minimal deployment. Both
   mix in `RelayerFeeLedger` (`common/RelayerFeeLedger.sol`) for their per-message fee bookkeeping and
   activate a vault post-construction via owner-only `setRelayerFeeVault` (the vault's immutable
   `relayerContract()` must already point back at the caller).
7. `AttestorVault` (`AttestorVault.sol`) - holds attestation (`coreFee`) payments per message and
   settles them to the attestor set once attestation is confirmed by the configured validation
   contract, burning a configurable share (capped at 20%). `settle` now also takes the list of
   settling attestors and rejects any payee the configured `AttestorRegistry` (or compatible
   `isAttestor` source) does not recognize. Unsettled deposits are refundable to their payer after a
   configurable delay (7 days by default).
8. `RelayerFeeVault` (`RelayerFeeVault.sol`) - pure fee custody, drastically simplified: it holds
   ATTEST or native coin and pays out only when instructed by its bound `RelayerContract`/
   `RelayerContractLite` via `pay(to, amount, native)`. It keeps no per-message ledger of its own -
   routes, amounts, settlement flags, and gas-limit/tip bookkeeping all moved to the relayer
   contracts' `RelayerFeeLedger` mixin; the vault only executes payouts (with a push-then-pull
   fallback via `pendingNativeWithdrawals`/`withdrawNative` if a native push fails).
9. `FeeRegistry` (`FeeRegistry.sol`) / `ICoreFeeProvider` (`abstract/ICoreFeeProvider.sol`) - the
   registry `Outbox.coreFee()`/`publishMessage` now read `coreFee` from, replacing the previous
   direct dependency on `ASCRelayingQuoter`. `FeeRegistry` is a thin, swappable
   (`Outbox.setFeeRegistry`) wrapper around a pluggable `ICoreFeeProvider.get_core_fee(chainKey)` -
   in production the Creditcoin core-fee precompile; `contracts/mocks/MockCoreFeeProvider.sol` is
   the settable test stand-in.
10. `ASCRelayingQuoter` (`ASCRelayingQuoter.sol`) - live relay-fee quoting in either TWAP or
    Uniswap-v3-pool pricing mode, an acknowledgment-fee floor (`getAcknowledgmentFee`, refreshed
    alongside prices) that `RelayerContract`/`RelayerContractLite` enforce against a quote's
    `acknowledgmentPrice`, and the authorized-quoter allowlist the full `RelayerContract` checks
    signed quotes against. Its own `coreFeeInAttest`/`getCoreFee`/`setCoreFee` are no longer read by
    `Outbox` (that now comes from `FeeRegistry`) - treat that pair as a legacy/unused view, not part
    of the live pricing path.
11. `TWAPReader` (`TWAPReader.sol`) - an on-chain, oracle-fed cumulative-price TWAP for the
    ATTEST/CTC exchange rate, consumed by `ASCRelayingQuoter`.

### Proof & decoding libraries

12. `ASCProofVerifier` (`common/ASCProofVerifier.sol`) - the shared entry point for verifying a
    binary-Merkle inclusion + continuity proof via the native block-prover precompile, returning the
    proven raw transaction bytes. Used by both `AcknowledgmentValidator` and the
    `RelayerContract`/`RelayerContractLite` `claimDelivery` path.
13. `EVMDeliveryDecoder` (`common/EVMDeliveryDecoder.sol`) - decodes a proven delivery transaction
    against a per-destination-chain-ID trusted `Inbox` address, and reports whether it emitted
    `MessageDelivered` (success) or `MessagePending` (reverted/out-of-gas) for the given `messageId`.
14. `QueryProofVerificationLib` / `BlockProverTypes` (`common/`) - shared Merkle/continuity proof
    types and helpers used by `ASCProofVerifier`.

### Token bridge

15. `ASCBridgeLiquidityOperator` (`ASCBridgeLiquidityOperator.sol`) - Creditcoin-hub-side bridge
    operator. Publishes outbound bridge intents through a configured `Outbox` trusted forwarder
    (`RelayerContract`), escrows or burns source tokens, and coordinates inbound mint/release via
    proved settlement transactions. Payload encoding uses `BridgeMessageCodecV1` /
    `ASCBridgeTypes.BridgeMessage`.
16. `ASCBridgeMintDestination` (`ASCBridgeMintDestination.sol`) - durable mint executor for the
    **inbound** bridge path. The hub operator calls `executeMint` after validating a proved source-chain
    settlement transaction via `BridgeIntentDecoder`. This is **not** an `IMessageReceiver` and must
    not be wired as an `Inbox` `messageDispatcher` for outbound `bridgeTo` payloads.
17. `BridgeIntentDecoder` (`common/BridgeIntentDecoder.sol`) - decodes proved source-chain
    settlement transactions into inbound bridge intents.
18. `BridgeMessageCodecV1` (`common/BridgeMessageCodecV1.sol`) - canonical ABI codec for V1 bridge
    payloads.

### Interfaces, errors & helpers

19. Interfaces (`abstract/`) - the pluggable seams implemented above: `IOutbox`, `IOutboxFactory`,
    `IVoteValidator`, `IAttestorVault`, `IAttestorRegistry`, `IFeeRegistry`, `ICoreFeeProvider`,
    `IRelayerContract`, `IRelayerContractLite`, `IRelayerFeeVault`, `IASCRelayingQuoter`,
    `ITWAPReader`, `IASCProofVerifier`, `IDeliveryDecoder`, `IInbox`, `IMessageReceiver` (+
    `MessageReceiverBase`, the abstract base a dApp inherits from to receive ASC messages),
    `IERC3009`, `IERC20MintBurn`, `IPenguinSwapV3Pool`, `IASCBridgeLiquidityOperator`,
    `IASCBridgeTokenDestination`, `IBridgeIntentDecoder`.
20. Custom-error libraries (`error/`) - `CommonErrors`, `OutboxErrors`, `RelayerErrors`,
    `InboxErrors`, `ASCBridgeLiquidityOperatorErrors`.
21. `common/CanonicalTokenCall.sol`, `TokenAmountNormalization.sol`, `TokenExecutionCommitment.sol`,
    `ASCBridgeTypes.sol` - helper libraries and shared bridge message structs consumed by
    `ASCBridgeLiquidityOperator` and `BridgeMessageCodecV1`.

> **Note:** two distinct `INativeQueryVerifier` interfaces exist at different paths
> (`write-ability/INativeQueryVerifier.sol` and `write-ability/common/INativeQueryVerifier.sol`) —
> they are not interchangeable, and only the `common/` copy is currently wired into any contract
> (via `ASCProofVerifier`). See the "Known naming quirks" section of
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#9-known-naming-quirks-intentional-documented-so-they-dont-read-as-bugs)
> before assuming they're the same type, or that the top-level one is still in use.

## Building and Running the Smart Contract Tests

The contracts are a Hardhat project. Tests are written in TypeScript (Mocha/Chai + ethers v6) and
live in `test/`; test-only helper contracts (mocks/stand-ins) live in `contracts/mocks/` and are not
part of the published npm package.

Prerequisites: Node.js 20+. Install dependencies once with:

```
npm install
```

Compile (build) the contracts. Hardhat downloads the pinned solc `0.8.28` on first run:

```
npx hardhat compile
```

Run the full test suite:

```
npm test
# or: npx hardhat test
```

Run the tests with a Solidity coverage report (written to `./coverage/` and `./coverage.json`). This
is what CI runs:

```
npm run coverage
# or: npx hardhat coverage
```

CI then enforces a coverage floor (currently 70% statements / 50% branches / 70% functions / 65%
lines, set a little below the actual numbers so incidental fluctuation doesn't fail a PR) against
`./coverage.json` via [Istanbul](https://istanbul.js.org/)'s `check-coverage`, which ships as a
transitive dependency of `solidity-coverage` - no separate install needed. Run it locally after
`npm run coverage`:

```
npm run coverage:check
```

Raise the thresholds in the `coverage:check` script in `package.json` as real coverage improves;
don't lower them to make a PR pass.

## Hardhat deployment scripts

Scripts live under `scripts/hardhat/`. See `.env.example` for variables.

| Script | Deploys | Use when |
|--------|---------|----------|
| `deployWriteAbility.ts` | Outbox, Relayer, vaults, quoter, optional Inbox | Bootstrap the **messaging stack only**. Does not deploy token-bridge operators. |
| `deployBridge.ts` | `ASCBridgeLiquidityOperator`, `ASCBridgeMintDestination`, `BridgeIntentDecoder` | **Token bridge** on top of an existing hub (`OUTBOX`, `RELAYER`, `PROOF_VERIFIER`). |
| `bridgeTo.ts` | (smoke test) | Publish one `bridgeTo` transaction; fails closed on stale TWAP, zero `coreFee`, or missing forwarder approval. |

**Fresh devnet token bridge (hub publish + inbound mint wiring):**

1. `deployWriteAbility.ts` with `DEPLOY_FRESH_HUB=true` (or `DEPLOY_FULL_STACK=true`, same hub path)
2. `deployBridge.ts` — hub `ASCBridgeLiquidityOperator` + `ASCBridgeMintDestination` (inbound mint)

**End-to-end outbound delivery** (hub `bridgeTo` → destination Inbox) additionally requires a
destination `IMessageReceiver` that decodes `BridgeMessageCodecV1` payloads and mints/releases
tokens. That receiver is **not** `ASCBridgeMintDestination` (which only exposes `executeMint` for
the inbound `bridgeFromIntent` path). Deploy it separately, then:

3. `deployWriteAbility.ts` with `DEPLOY_INBOX=true` and
   `MESSAGE_DISPATCHER=<destination IMessageReceiver>`
4. `deployBridge.ts` with `REMOTE_CLIENT_OPERATOR=<same destination IMessageReceiver>` to pair the
   hub route (optional metadata on the hub operator)

```
npm run deploy:write-ability
npx hardhat run scripts/hardhat/deployBridge.ts --network usc_devnet
```

## Continuous Integration

Every pull request runs:

- **`hardhat`** (`.github/workflows/hardhat.yml`) - compiles the contracts, runs `npx hardhat
coverage`, fails the build if coverage drops below the floor in `npm run coverage:check` (see
  above), and uploads the coverage report as a build artifact regardless of that outcome.
- **`solhint`** (`.github/workflows/solhint.yml`) - lints `contracts/**/*.sol` with
  [Solhint](https://protofire.github.io/solhint/) (`npm run lint:solidity`); the ruleset lives in
  `.solhint.json`.
- **`slither`** (`.github/workflows/slither.yml`) - runs [Slither](https://github.com/crytic/slither)
  static analysis over `contracts/write-ability` and uploads findings to GitHub code scanning as
  SARIF (informational — it does not fail the build).

## Published packages

Pushing a tag of the form `vX.Y.Z` publishes two npm packages (see "Releasing New Contract
Versions" below):

- **[`@gluwa/asc-contracts`](https://www.npmjs.com/package/@gluwa/asc-contracts)** - the Solidity
  source itself (`contracts/write-ability/**/*.sol`, `contracts/common/**/*.sol`, and
  `contracts/readability/**/*.sol`), for
  consumption by Foundry/forge or Hardhat.
- **`@gluwa/asc-contracts-abi`** - just the compiled ABI JSON for the same contracts, for
  consumers (relayers, indexers, frontends) that only need to encode/decode calls or parse events
  without pulling in Solidity source. Built by `.github/workflows/abi-publish.yml`. To generate it
  locally:

  ```
  npm run build:abi-package
  ```

  This compiles the contracts and writes the package to `dist/abi-package/` (gitignored). Each
  contract's ABI is available as a named export (e.g. `require('@gluwa/asc-contracts-abi').Outbox`)
  and as an individual `abi/<ContractName>.json` file.

## Releasing New Contract Versions

1. Bump the `version` field in `package.json` to match the tag you're about to push.
2. Push a new tag of the format `vX.Y.Z`. This triggers the `npm-publish` workflow (publishes
   `@gluwa/asc-contracts` and creates a GitHub release) and the `abi-publish` workflow (publishes
   `@gluwa/asc-contracts-abi`) in parallel. Both compare the tag against `package.json`'s version and
   fail if they don't match.
3. Update the contract version used in the `attestcoin-protocol-examples` and `Creditcoin3` repositories.
   This usually just involves updating the imported versions in `package.json`s.
4. If there's a major interface change, consider re-verifying the contracts on services such as Blockscout.
