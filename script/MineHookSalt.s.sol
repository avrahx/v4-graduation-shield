// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {GraduationShieldHook} from "../src/GraduationShieldHook.sol";

/// @title MineHookSalt
/// @notice Mines CREATE2 salt for deploying GraduationShieldHook with the exact bitmask required by Uniswap v4
contract MineHookSalt is Script {
    // Required flag combination:
    // AFTER_INITIALIZE_FLAG (1 << 12) = 0x1000
    // BEFORE_SWAP_FLAG (1 << 7)       = 0x0080
    // AFTER_SWAP_FLAG (1 << 6)        = 0x0040
    // BEFORE_SWAP_RETURNS_DELTA (1 << 3) = 0x0008
    // Total bitmask = 0x10C8
    uint160 public constant REQUIRED_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_SWAP_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

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
        console2.log("Required hook flags bitmask: 0x10C8");

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
