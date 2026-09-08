// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IAttestorRegistry} from "./abstract/IAttestorRegistry.sol";
import {CommonErrors} from "./error/CommonErrors.sol";

/// @title AttestorRegistry
/// @notice Standalone, owner-managed attestor set shared by every contract that
///         needs attestor validation. Consumers (e.g. AttestorVault.settle) call
///         `isAttestor` for O(1) membership checks rather than maintaining their
///         own copies of the set, so membership is managed — and audited — in one
///         place. Production ownership should be assigned to the governance timelock.
contract AttestorRegistry is IAttestorRegistry, Ownable2Step {
    /// O(1) membership, kept in sync with `_attestors`.
    mapping(address => bool) private _isAttestor;
    /// Iterable attestor set. Exposed via `attestors()`.
    address[] private _attestors;
    /// Contracts authorized to mutate the set alongside the owner — e.g. the
    /// EOAValidator, whose attestor-voted `submitAttestorSetUpdate` writes here.
    mapping(address => bool) public override isUpdater;

    modifier onlyOwnerOrUpdater() {
        if (msg.sender != owner() && !isUpdater[msg.sender]) {
            revert NotRegistryUpdater(msg.sender);
        }
        _;
    }

    constructor(
        address initialOwner,
        address[] memory initialAttestors
    ) Ownable(initialOwner) {
        for (uint256 i = 0; i < initialAttestors.length; i++) {
            _add(initialAttestors[i]);
        }
    }

    function isAttestor(address attestor) external view override returns (bool) {
        return _isAttestor[attestor];
    }

    function attestors() external view override returns (address[] memory) {
        return _attestors;
    }

    function getAttestorCount() external view override returns (uint256) {
        return _attestors.length;
    }

    function setUpdater(address updater, bool authorized) external override onlyOwner {
        if (updater == address(0)) revert CommonErrors.ZeroAddress();
        isUpdater[updater] = authorized;
        emit UpdaterSet(updater, authorized);
    }

    function addAttestor(address attestor) external override onlyOwnerOrUpdater {
        _add(attestor);
    }

    function removeAttestor(address attestor) external override onlyOwnerOrUpdater {
        if (!_isAttestor[attestor]) revert AttestorNotFound(attestor);
        _isAttestor[attestor] = false;
        uint256 length = _attestors.length;
        for (uint256 i = 0; i < length; i++) {
            if (_attestors[i] == attestor) {
                _attestors[i] = _attestors[length - 1];
                _attestors.pop();
                break;
            }
        }
        emit AttestorRemoved(attestor);
    }

    function updateAttestorSet(address[] calldata newAttestors) external override onlyOwnerOrUpdater {
        for (uint256 i = 0; i < _attestors.length; i++) {
            _isAttestor[_attestors[i]] = false;
        }
        delete _attestors;
        for (uint256 i = 0; i < newAttestors.length; i++) {
            _add(newAttestors[i]);
        }
        emit AttestorSetReplaced(newAttestors);
    }

    function _add(address attestor) internal {
        if (attestor == address(0)) revert CommonErrors.ZeroAddress();
        if (_isAttestor[attestor]) revert AttestorAlreadyRegistered(attestor);
        _isAttestor[attestor] = true;
        _attestors.push(attestor);
        emit AttestorAdded(attestor);
    }
}
