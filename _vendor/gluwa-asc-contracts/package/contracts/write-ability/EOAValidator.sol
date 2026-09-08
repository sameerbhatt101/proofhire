// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IVoteValidator} from "./abstract/IVoteValidator.sol";
import {IAttestorRegistry} from "./abstract/IAttestorRegistry.sol";

/// @notice EOA (ECDSA / `ecrecover`) vote validator — the production replacement for
/// `DummyVoteValidator`. Validates that a threshold of authorized attestors signed the message
/// hash. Suitable for a low attestor count; can be swapped for a BLS/TSS validator later by
/// pointing the Inbox at a different `IVoteValidator` (research §12).
///
/// Attestor membership lives in the shared `AttestorRegistry` — this contract holds no set of
/// its own. All reads go through the registry, and set mutations (owner-driven or attestor-voted
/// via `submitAttestorSetUpdate`) are written through it, so every consumer of the registry sees
/// one consistent set. The registry must authorize this contract as an updater
/// (`registry.setUpdater(validator, true)`) for mutations to succeed. Note: the registry owner
/// can also mutate the set directly, which bypasses this contract's quorum-config validation —
/// prefer mutating through the validator.
///
/// Votes are `abi.encode(bytes[] signatures)`, each a 65-byte `(r, s, v)` ECDSA signature over the
/// raw `messageHash` (no EIP-191 / personal_sign prefix) — byte-identical to what the Rust attestor
/// produces and the relayer assembles.
contract EOAValidator is IVoteValidator, Ownable2Step {
    /// Shared attestor-set registry — the single source of truth for membership.
    IAttestorRegistry public immutable attestorRegistry;

    /// Minimum required signatures, regardless of the threshold fraction (security floor).
    /// Must always be greater than `MIN_ATTESTOR_COUNT_FLOOR - 1` (i.e. at least 3).
    uint256 public minAttestorCount;

    /// Hard lower bound on `minAttestorCount`: it must always be greater than 2.
    uint256 public constant MIN_ATTESTOR_COUNT_FLOOR = 3;

    /// Threshold fraction denominator — fixed at 30, giving fine-grained fractions in steps of
    /// 1/30: e.g. numerator 20 ⇒ 20/30 (= 2/3), numerator 15 ⇒ 15/30 (= 1/2), numerator 25 ⇒ 25/30.
    uint256 public constant THRESHOLD_DENOMINATOR = 30;

    /// Threshold fraction numerator + addition over `THRESHOLD_DENOMINATOR`,
    /// e.g. numerator 20, addition 1 ⇒ 20/30 + 1 (the classic 2/3 + 1 quorum).
    uint256 public thresholdNumerator;
    uint256 public thresholdAddition;

    /// Monotonic nonce bound into every `submitAttestorSetUpdate` signed payload. Incremented on
    /// each successful update so a previously-signed (and applied) set change cannot be replayed to
    /// roll the attestor set back. Signers must sign against the *current* value.
    uint256 public attestorSetUpdateNonce;

    event AttestorSetUpdated(address[] newAttestors);
    event ThresholdUpdated(uint256 numerator, uint256 addition);
    event MinAttestorCountUpdated(uint256 newMin);

    /// secp256k1 group order ÷ 2 — the EIP-2 upper bound on a non-malleable `s`.
    uint256 internal constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error InvalidArgument(string reason);
    error InvalidSignatureLength();
    error InvalidAttestor();
    error DoubleSigning();
    error ThresholdNotMet(uint256 got, uint256 required);
    error MalleableSignature();

    /// @param attestorRegistry_ The shared AttestorRegistry, already seeded with the
    ///        initial attestor set (it deploys before this contract).
    constructor(
        address initialOwner,
        address attestorRegistry_,
        uint256 _minAttestorCount,
        uint256 _thresholdNumerator,
        uint256 _thresholdAddition
    ) Ownable(initialOwner) {
        if (attestorRegistry_ == address(0)) revert InvalidArgument("registry");
        attestorRegistry = IAttestorRegistry(attestorRegistry_);

        _validateThresholdFraction(_thresholdNumerator);
        _validateQuorumConfig(
            IAttestorRegistry(attestorRegistry_).getAttestorCount(),
            _minAttestorCount,
            _thresholdNumerator,
            _thresholdAddition
        );

        minAttestorCount = _minAttestorCount;
        thresholdNumerator = _thresholdNumerator;
        thresholdAddition = _thresholdAddition;
    }

    /// @dev Decodes `votes` as `bytes[]`, `ecrecover`s each 65-byte signature against `messageHash`,
    /// requires each signer to be an attestor, rejects a signer appearing twice in this call, and
    /// requires at least `threshold()` unique signers. Returns `true` on success; on any failure it
    /// reverts with a specific error rather than returning `false`, so an Inbox call with invalid
    /// votes reverts (surfacing the reason) instead of emitting `ValidationFailed`.
    function validateVotes(
        bytes32 messageHash,
        bytes calldata votes
    ) external view override returns (bool) {
        bytes[] memory signatures = abi.decode(votes, (bytes[]));

        // Bail out before any ecrecover work when the bundle cannot possibly meet quorum, and
        // bound the O(n^2) dedup loop by the attestor count.
        uint256 totalAttestors = attestorRegistry.getAttestorCount();
        uint256 required = calculateRequiredVotes(totalAttestors);
        uint256 length = signatures.length;
        if (length < required) {
            revert ThresholdNotMet(length, required);
        }
        if (length > totalAttestors) revert InvalidArgument("too many votes");

        address[] memory seen = new address[](length);
        uint256 unique = 0;

        for (uint256 i = 0; i < length; ++i) {
            // Direct hash signing — no EIP-191 prefix (matches the attestor signer).
            address signer = _recoverChecked(messageHash, signatures[i]);
            if (!attestorRegistry.isAttestor(signer)) revert InvalidAttestor();

            for (uint256 j = 0; j < unique; ++j) {
                if (seen[j] == signer) revert DoubleSigning();
            }
            seen[unique] = signer;
            unchecked {
                ++unique;
            }
        }

        if (unique < required) revert ThresholdNotMet(unique, required);

        return true;
    }

    function validatorType() external pure override returns (string memory) {
        return "eoa";
    }

    /// @notice Whether `attestor` is in the current set (delegates to the registry).
    ///         Kept as a function so consumers of the former public mapping keep working.
    function isAttestor(address attestor) public view returns (bool) {
        return attestorRegistry.isAttestor(attestor);
    }

    /// @notice The current authorized attestor EVM addresses. Read off-chain by attestors/relayers
    function attestors() external view returns (address[] memory) {
        return attestorRegistry.attestors();
    }

    /// @notice Quorum threshold (number of unique signatures) required for the current attestor set.
    function threshold() external view returns (uint256) {
        return calculateRequiredVotes(attestorRegistry.getAttestorCount());
    }

    /// @notice Required unique signatures for `totalAttestors`: `max(floor(N*num/den)+add, minimum)`.
    function calculateRequiredVotes(
        uint256 totalAttestors
    ) public view returns (uint256) {
        uint256 t = ((totalAttestors * thresholdNumerator) /
            THRESHOLD_DENOMINATOR) + thresholdAddition;
        return t > minAttestorCount ? t : minAttestorCount;
    }

    function addAttestor(address attestor) external onlyOwner {
        _validateQuorumConfig(
            attestorRegistry.getAttestorCount() + 1,
            minAttestorCount,
            thresholdNumerator,
            thresholdAddition
        );
        attestorRegistry.addAttestor(attestor);
        emit AttestorSetUpdated(attestorRegistry.attestors());
    }

    function removeAttestor(address attestor) external onlyOwner {
        if (!attestorRegistry.isAttestor(attestor)) revert InvalidAttestor();
        _validateQuorumConfig(
            attestorRegistry.getAttestorCount() - 1,
            minAttestorCount,
            thresholdNumerator,
            thresholdAddition
        );
        attestorRegistry.removeAttestor(attestor);
        emit AttestorSetUpdated(attestorRegistry.attestors());
    }

    /// @notice Replace the entire attestor set.
    function updateAttestorSet(
        address[] calldata newAttestors
    ) external onlyOwner {
        _validateQuorumConfig(
            newAttestors.length,
            minAttestorCount,
            thresholdNumerator,
            thresholdAddition
        );
        attestorRegistry.updateAttestorSet(newAttestors);
        emit AttestorSetUpdated(newAttestors);
    }

    /// @notice Adjust the threshold numerator and addition. The denominator is the
    ///         `THRESHOLD_DENOMINATOR` constant.
    function updateThreshold(
        uint256 _numerator,
        uint256 _addition
    ) external onlyOwner {
        _validateThresholdFraction(_numerator);
        _validateQuorumConfig(
            attestorRegistry.getAttestorCount(),
            minAttestorCount,
            _numerator,
            _addition
        );
        thresholdNumerator = _numerator;
        thresholdAddition = _addition;
        emit ThresholdUpdated(_numerator, _addition);
    }

    function updateMinAttestorCount(
        uint256 _minAttestorCount
    ) external onlyOwner {
        _validateQuorumConfig(
            attestorRegistry.getAttestorCount(),
            _minAttestorCount,
            thresholdNumerator,
            thresholdAddition
        );
        minAttestorCount = _minAttestorCount;
        emit MinAttestorCountUpdated(_minAttestorCount);
    }

    /// @notice Replace the attestor set with one signed by a threshold of the *current* attestors
    /// (more decentralized than `updateAttestorSet`; anyone may submit, signatures must clear the
    /// current threshold). Sign `keccak256(abi.encode(newAttestors, block.chainid, nonce))` directly,
    /// where `nonce` is the current `attestorSetUpdateNonce`. The nonce is chain-id bound (no
    /// cross-chain replay) and monotonic (no rollback replay: once applied, the signed payload is
    /// spent).
    function submitAttestorSetUpdate(
        address[] calldata newAttestors,
        bytes calldata signatures
    ) external {
        _validateQuorumConfig(
            newAttestors.length,
            minAttestorCount,
            thresholdNumerator,
            thresholdAddition
        );

        // Bind `address(this)` into the signed payload so a set-update signed for one validator
        // instance cannot be replayed against another instance on the same chain that shares
        // signers and is at the same nonce (the shared AttestorRegistry makes overlapping signer
        // sets the norm). Off-chain signers must sign over this same preimage.
        bytes32 updateHash = keccak256(
            abi.encode(address(this), newAttestors, block.chainid, attestorSetUpdateNonce)
        );
        bytes[] memory sigs = abi.decode(signatures, (bytes[]));
        uint256 length = sigs.length;
        address[] memory seen = new address[](length);
        uint256 unique = 0;
        for (uint256 i = 0; i < length; ++i) {
            address signer = _recoverChecked(updateHash, sigs[i]);
            if (!attestorRegistry.isAttestor(signer)) revert InvalidAttestor();
            for (uint256 j = 0; j < unique; ++j) {
                if (seen[j] == signer) revert DoubleSigning();
            }
            seen[unique] = signer;
            unchecked {
                ++unique;
            }
        }

        uint256 required = calculateRequiredVotes(
            attestorRegistry.getAttestorCount()
        );
        if (unique < required) revert ThresholdNotMet(unique, required);

        // Spend the nonce before applying so a replay of this exact payload reverts on InvalidAttestor
        // (recovers against a stale hash) on any later call.
        unchecked {
            ++attestorSetUpdateNonce;
        }
        attestorRegistry.updateAttestorSet(newAttestors);
        emit AttestorSetUpdated(newAttestors);
    }

    function getAttestorCount() external view returns (uint256) {
        return attestorRegistry.getAttestorCount();
    }

    /// @dev Recover a signer from a 65-byte `(r, s, v)` signature with EIP-2 hardening: reject a
    /// high-`s` (malleable) value and any `v` outside {27, 28}, plus a zero-address recovery. Shared
    /// by both signature-checking loops so they can't drift. Not a threshold bypass even without it
    /// (both this contract and the relayer dedup by the *recovered* address, so a malleated copy
    /// recovers to the same signer and can't inflate the unique count) — this is defense-in-depth so
    /// the guarantee survives any future refactor of the dedup logic.
    function _recoverChecked(
        bytes32 hash,
        bytes memory sig
    ) internal pure returns (address) {
        if (sig.length != 65) revert InvalidSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        // Extracts the (r, s, v) signature triple; no non-assembly equivalent.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (uint256(s) > SECP256K1_HALF_N) revert MalleableSignature();
        if (v != 27 && v != 28) revert MalleableSignature();
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert InvalidAttestor();
        return signer;
    }

    /// @dev The threshold fraction must not exceed 1: `numerator <= THRESHOLD_DENOMINATOR`.
    /// Checked at the two points where the numerator is set (constructor, `updateThreshold`)
    /// rather than in `_validateQuorumConfig`, which also runs on set mutations that cannot
    /// change it.
    function _validateThresholdFraction(uint256 numerator) internal pure {
        if (numerator > THRESHOLD_DENOMINATOR)
            revert InvalidArgument("numerator above denominator");
    }

    /// @dev Reject attestor-set/threshold configurations that would brick validation: the security
    /// floor must be at least `MIN_ATTESTOR_COUNT_FLOOR` (> 2), and the required vote count for
    /// `totalAttestors` must be reachable (<= totalAttestors) and non-zero (a zero threshold would
    /// accept an empty vote bundle).
    function _validateQuorumConfig(
        uint256 totalAttestors,
        uint256 minimum,
        uint256 numerator,
        uint256 addition
    ) internal pure {
        if (minimum < MIN_ATTESTOR_COUNT_FLOOR)
            revert InvalidArgument("min attestor count too low");
        if (totalAttestors < minimum) revert InvalidArgument("below minimum");

        unchecked {
            uint256 required = ((totalAttestors * numerator) /
                THRESHOLD_DENOMINATOR) + addition;
            if (required == 0) revert InvalidArgument("zero threshold");
            if (required > totalAttestors)
                revert InvalidArgument("threshold unreachable");
            if (required < minimum) required = minimum;
        }
    }
}
