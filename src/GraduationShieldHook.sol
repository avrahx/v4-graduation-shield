// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title GraduationShieldHook
/// @notice Uniswap v4 Hook implementing dynamic time-decay exit fees on sells with excess fee donation to active LPs.
/// @dev Defends newly graduated bonding-curve pools against immediate liquidation dumps ("Graduation Cliff").
contract GraduationShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // --- Errors ---
    error ExactOutputSellNotAllowedDuringCliff();
    error InvalidFeeConfiguration();
    error Unauthorized();

    // --- Events ---
    event PoolShieldConfigured(
        PoolId indexed poolId,
        Currency indexed graduatedToken,
        uint32 graduationTimestamp,
        uint32 decayDuration,
        uint24 initialFee,
        uint24 baseFee
    );
    event ExcessFeeDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    // --- Configuration Struct ---
    struct PoolConfig {
        Currency graduatedToken;
        uint32 graduationTimestamp;
        uint32 decayDuration;
        uint24 initialFee; // fee in hundredths of a bip (1,000,000 = 100%, 150,000 = 15%)
        uint24 baseFee;    // fee in hundredths of a bip (3,000 = 0.3%)
        bool isConfigured;
    }

    // --- Default Constants ---
    uint24 public constant DEFAULT_INITIAL_FEE = 150_000; // 15.00%
    uint24 public constant DEFAULT_BASE_FEE = 3_000;       // 0.30%
    uint32 public constant DEFAULT_DECAY_DURATION = 7 days;
    uint24 public constant FEE_DENOMINATOR = 1_000_000;

    // Transient storage slot for excess donation across beforeSwap -> afterSwap
    bytes32 private constant EXCESS_DONATE_SLOT = keccak256("graduation.shield.excess.donate");

    // Mapping of PoolId => PoolConfig
    mapping(PoolId => PoolConfig) public poolConfigs;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Pool Initialization Callback ---

    /// @notice Called after pool initialization to set up graduation shield configuration
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) external override onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        if (!poolConfigs[id].isConfigured) {
            // Default configuration: currency0 is assumed to be the graduated token if not pre-configured
            _configurePool(
                key,
                key.currency0,
                uint32(block.timestamp),
                DEFAULT_DECAY_DURATION,
                DEFAULT_INITIAL_FEE,
                DEFAULT_BASE_FEE
            );
        }
        return IHooks.afterInitialize.selector;
    }

    // --- Configuration Functions ---

    /// @notice Configures graduation parameters for a specific pool
    function configurePool(
        PoolKey calldata key,
        Currency graduatedToken,
        uint32 graduationTimestamp,
        uint32 decayDuration,
        uint24 initialFee,
        uint24 baseFee
    ) external {
        PoolId id = key.toId();
        // Allow configuring if not configured yet, or called prior to graduation
        // forge-lint: disable-next-line(block-timestamp)
        if (poolConfigs[id].isConfigured && poolConfigs[id].graduationTimestamp <= block.timestamp) {
            revert Unauthorized();
        }
        _configurePool(key, graduatedToken, graduationTimestamp, decayDuration, initialFee, baseFee);
    }

    function _configurePool(
        PoolKey calldata key,
        Currency graduatedToken,
        uint32 graduationTimestamp,
        uint32 decayDuration,
        uint24 initialFee,
        uint24 baseFee
    ) internal {
        if (baseFee > initialFee || initialFee > LPFeeLibrary.MAX_LP_FEE || decayDuration == 0) {
            revert InvalidFeeConfiguration();
        }

        PoolId id = key.toId();
        poolConfigs[id] = PoolConfig({
            graduatedToken: graduatedToken,
            graduationTimestamp: graduationTimestamp,
            decayDuration: decayDuration,
            initialFee: initialFee,
            baseFee: baseFee,
            isConfigured: true
        });

        emit PoolShieldConfigured(id, graduatedToken, graduationTimestamp, decayDuration, initialFee, baseFee);
    }

    // --- Fee Inspection / Quoting ---

    /// @notice Calculates the current sell fee on the graduated token
    /// @dev Linearly decays from initialFee down to baseFee over decayDuration
    function getSellFee(PoolKey calldata key) public view returns (uint24) {
        PoolConfig memory config = poolConfigs[key.toId()];
        if (!config.isConfigured) return DEFAULT_BASE_FEE;

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= config.graduationTimestamp) {
            return config.initialFee;
        }

        uint32 elapsed = uint32(block.timestamp) - config.graduationTimestamp;
        if (elapsed >= config.decayDuration) {
            return config.baseFee;
        }

        uint256 feeDelta = config.initialFee - config.baseFee;
        uint256 excess = (feeDelta * (config.decayDuration - elapsed)) / config.decayDuration;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(config.baseFee + excess);
    }

    /// @notice Returns the buy fee for the graduated token (standard base fee)
    function getBuyFee(PoolKey calldata key) public view returns (uint24) {
        PoolConfig memory config = poolConfigs[key.toId()];
        return config.isConfigured ? config.baseFee : DEFAULT_BASE_FEE;
    }

    /// @notice General fee view for external integrators
    function getFee(PoolKey calldata key, bool isSell) external view returns (uint24) {
        return isSell ? getSellFee(key) : getBuyFee(key);
    }

    // --- Swap Callbacks ---

    /// @notice Called before a swap to apply the time-decay exit fee and extract excess fee delta
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        PoolConfig memory config = poolConfigs[id];

        if (!config.isConfigured) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Determine trade direction relative to graduatedToken
        // zeroForOne = true means currency0 is sent in, currency1 is received
        bool isSell = (params.zeroForOne == (key.currency0 == config.graduatedToken));

        if (!isSell) {
            // BUY: Standard base fee, zero excess fee
            uint24 lpFeeOverride = key.fee.isDynamicFee()
                ? (config.baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG)
                : 0;
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
        }

        // SELL: Apply dynamic time-decay exit fee
        uint24 currentFee = getSellFee(key);
        uint24 excessFee = currentFee > config.baseFee ? (currentFee - config.baseFee) : 0;

        if (excessFee == 0) {
            // Post-decay: standard base fee
            uint24 lpFeeOverride = key.fee.isDynamicFee()
                ? (config.baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG)
                : 0;
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
        }

        // Active cliff period with excess exit fee:
        // Disallow exact output sells to prevent fee evasion attacks
        if (params.amountSpecified > 0) {
            revert ExactOutputSellNotAllowedDuringCliff();
        }

        // Exact input sell: amountSpecified is negative
        uint256 inputAmount = uint256(-params.amountSpecified);
        uint256 excessAmount = (inputAmount * excessFee) / FEE_DENOMINATOR;

        // Store excessAmount in transient storage for afterSwap donation
        bytes32 slot = EXCESS_DONATE_SLOT;
        assembly {
            tstore(slot, excessAmount)
        }

        // Deduct excessAmount from the specified input swap amount using BeforeSwapDelta
        // Positive specified delta credits the hook and reduces the amount going into the pool
        // forge-lint: disable-next-line(unsafe-typecast)
        BeforeSwapDelta returnDelta = toBeforeSwapDelta(int128(uint128(excessAmount)), 0);

        uint24 feeOverride = key.fee.isDynamicFee()
            ? (config.baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG)
            : 0;

        return (IHooks.beforeSwap.selector, returnDelta, feeOverride);
    }

    /// @notice Called after a swap to donate the intercepted excess fee to active in-range LPs
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        bytes32 slot = EXCESS_DONATE_SLOT;
        uint256 excessAmount;
        assembly {
            excessAmount := tload(slot)
            tstore(slot, 0)
        }

        if (excessAmount > 0) {
            PoolConfig memory config = poolConfigs[key.toId()];
            uint256 donate0 = (key.currency0 == config.graduatedToken) ? excessAmount : 0;
            uint256 donate1 = (key.currency1 == config.graduatedToken) ? excessAmount : 0;

            // Donate intercepted tokens to in-range liquidity providers
            // This strengthens pool reserves, directly increasing LP feeGrowthGlobal
            poolManager.donate(key, donate0, donate1, "");

            emit ExcessFeeDonated(key.toId(), donate0, donate1);
        }

        return (IHooks.afterSwap.selector, 0);
    }
}
