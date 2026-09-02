// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {GraduationShieldHook} from "../src/GraduationShieldHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title DeployShieldHook
/// @notice Script implementing CREATE2 deployment for GraduationShieldHook matching 0x2080 flags
contract DeployShieldHook is Script {
    // Canonical Foundry CREATE2 Deterministic Deployment Proxy
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Target flags: BEFORE_INITIALIZE (1 << 13) | BEFORE_SWAP (1 << 7) = 0x2080
    uint160 public constant TARGET_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG;

    function run() external returns (GraduationShieldHook hook) {
        address manager = vm.envOr("POOL_MANAGER", address(0x0000000000000000000000000000000000000001));

        bytes memory creationCode = type(GraduationShieldHook).creationCode;
        bytes memory constructorArgs = abi.encode(IPoolManager(manager));

        console2.log("Mining CREATE2 salt for deployer:", CREATE2_DEPLOYER);
        console2.log("Target flags bitmask: 0x2080");

        (address expectedAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            TARGET_FLAGS,
            creationCode,
            constructorArgs
        );

        console2.log("Found salt:");
        console2.logBytes32(salt);
        console2.log("Expected hook address:", expectedAddress);

        vm.broadcast();
        hook = new GraduationShieldHook{salt: salt}(IPoolManager(manager));

        require(address(hook) == expectedAddress, "DeployShieldHook: deployed address mismatch");
        console2.log("Successfully deployed GraduationShieldHook at:", address(hook));
    }
}
