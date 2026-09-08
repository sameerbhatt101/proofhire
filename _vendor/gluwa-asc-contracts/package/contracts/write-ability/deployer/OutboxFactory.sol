// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOutboxFactory} from "../abstract/IOutboxFactory.sol";
import {Outbox} from "../Outbox.sol";

/// @title OutboxFactory
/// @notice Versioned factory for deploying Outbox contracts via CREATE2.
/// @dev One factory = one Outbox implementation version.
contract OutboxFactory is IOutboxFactory {
    function version() public pure override returns (string memory) {
        return "1.2";
    }

    /// @notice Intentionally permissionless — no onlyOwner by design. Access
    ///         control lives on OutboxDeployer (the intended caller), and the
    ///         CREATE2 salt binds msg.sender, so deployments from different
    ///         accounts can never collide; an unauthorized caller only spends
    ///         its own gas on an Outbox the protocol never registers.
    function deployOutbox(
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) external override returns (address outbox) {
        outbox = address(
            new Outbox{salt: _salt(chainKey, msg.sender)}(
                chainKey,
                outboxOwner,
                validator,
                defaultRateLimit,
                attestorVault,
                feeRegistry,
                attestToken
            )
        );

        emit OutboxCreated(outbox, chainKey, outboxOwner, validator, version());
    }

    function computeOutboxAddress(
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) external view override returns (address predicted) {
        return _computeOutboxAddress(
            msg.sender,
            chainKey,
            outboxOwner,
            validator,
            defaultRateLimit,
            attestorVault,
            feeRegistry,
            attestToken
        );
    }

    function computeOutboxAddressFor(
        address deployer,
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) external view override returns (address predicted) {
        return _computeOutboxAddress(
            deployer,
            chainKey,
            outboxOwner,
            validator,
            defaultRateLimit,
            attestorVault,
            feeRegistry,
            attestToken
        );
    }

    function _computeOutboxAddress(
        address deployer,
        uint32 chainKey,
        address outboxOwner,
        address validator,
        uint128 defaultRateLimit,
        address attestorVault,
        address feeRegistry,
        address attestToken
    ) internal view returns (address predicted) {
        bytes32 salt = _salt(chainKey, deployer);

        bytes memory initCode = abi.encodePacked(
            type(Outbox).creationCode,
            abi.encode(
                chainKey,
                outboxOwner,
                validator,
                defaultRateLimit,
                attestorVault,
                feeRegistry,
                attestToken
            )
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(initCode)
            )
        );

        predicted = address(uint160(uint256(hash)));
    }

    function _salt(uint32 chainKey, address outboxOwner) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainKey, outboxOwner));
    }
}
