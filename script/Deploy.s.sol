// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AcceptanceRegistry} from "../contracts/sepolia/AcceptanceRegistry.sol";
import {ProofHireVault} from "../contracts/creditcoin/ProofHireVault.sol";

contract DeploySepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);
        AcceptanceRegistry reg = new AcceptanceRegistry();
        console2.log("AcceptanceRegistry", address(reg));
        vm.stopBroadcast();
    }
}

contract DeployCreditcoin is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address sourceEmitter = vm.envAddress("ACCEPTANCE_REGISTRY_ADDRESS");
        uint64 expectedChainKey = uint64(vm.envUint("SOURCE_CHAIN_KEY"));
        require(sourceEmitter != address(0), "ACCEPTANCE_REGISTRY_ADDRESS unset");
        vm.startBroadcast(pk);
        ProofHireVault vault = new ProofHireVault(sourceEmitter, expectedChainKey);
        console2.log("ProofHireVault", address(vault));
        console2.log("sourceEmitter", sourceEmitter);
        console2.log("expectedChainKey", expectedChainKey);
        vm.stopBroadcast();
    }
}
