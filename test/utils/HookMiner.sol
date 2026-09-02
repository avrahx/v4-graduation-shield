// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Utility library to mine CREATE2 salts for Uniswap v4 Hooks with specific flag bitmasks
library HookMiner {
    uint256 internal constant MAX_LOOP = 500_000;

    /// @notice Mines a salt that produces a hook address matching the target flags
    /// @param deployer The address that will deploy the contract via CREATE2
    /// @param flags The required hook flag bitmask (e.g. Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
    /// @param creationCode The creation bytecode of the hook contract
    /// @param constructorArgs The ABI-encoded constructor arguments
    /// @return hookAddress The mined hook address matching the required flags
    /// @return salt The salt that produces hookAddress
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        // The flags bitmask cleanly isolates the required 14-bit mask (Hooks.ALL_HOOK_MASK)
        uint160 mask = Hooks.ALL_HOOK_MASK;

        for (uint256 i = 0; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            if (uint160(hookAddress) & mask == flags) {
                return (hookAddress, salt);
            }
        }

        revert("HookMiner: could not find salt");
    }

    /// @notice Computes a CREATE2 address using standard EVM address derivation
    /// @param deployer The deployer address
    /// @param salt The 32-byte salt
    /// @param initCodeHash The keccak256 hash of the contract creation code and constructor arguments
    /// @return The calculated CREATE2 address
    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
}
