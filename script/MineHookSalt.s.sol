// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {GraduationShieldHook} from "../src/GraduationShieldHook.sol";

/// @title MineHookSalt
/// @notice Mines CREATE2 salt for deploying GraduationShieldHook with BEFORE_INITIALIZE | BEFORE_SWAP
contract MineHookSalt is Script {
    // Required flag combination:
    // BEFORE_INITIALIZE_FLAG (1 << 13) = 0x2000
    // BEFORE_SWAP_FLAG (1 << 7)       = 0x0080
    // Total bitmask = 0x2080
    uint160 public constant REQUIRED_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG;

    function run() external view returns (bytes32 salt, address predictedAddress) {
        address deployer = msg.sender;
        address manager = vm.envOr("POOL_MANAGER", address(0x0000000000000000000000000000000000000001));

        return mineSalt(deployer, manager);
    }

    /// @notice Mines a CREATE2 salt matching the REQUIRED_FLAGS bitmask
    function mineSalt(address deployer, address manager) public pure returns (bytes32 salt, address predictedAddress) {
        bytes memory creationCode = type(GraduationShieldHook).creationCode;
        bytes memory constructorArgs = abi.encode(IPoolManager(manager));
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        console2.log("Mining salt for deployer:", deployer);
        console2.log("Required hook flags bitmask: 0x2080");

        for (uint256 i = 0; i < 300_000; i++) {
            bytes32 testSalt = bytes32(i);
            address predicted = vm.computeCreate2Address(testSalt, initCodeHash, deployer);

            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS) {
                console2.log("Success! Found valid salt at iteration:", i);
                console2.log("Salt:");
                console2.logBytes32(testSalt);
                console2.log("Predicted Hook Address:", predicted);
                return (testSalt, predicted);
            }
        }

        revert("Could not find salt within search limit");
    }
}
