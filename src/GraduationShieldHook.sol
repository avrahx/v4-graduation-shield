// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

/// @title GraduationShieldHook
/// @notice Uniswap v4 Hook that protects graduated launchpad tokens from post-migration liquidity drains
/// and recaptures value for active LPs via afterSwap donations.
contract GraduationShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    // --- Custom Errors ---
    error PoolNotDynamicFee();
    error PoolAlreadyInitialized();
    error PoolNotShielded();
    error TokenOrderMismatch();

    // --- Events ---
    event PenaltyDonated(PoolId indexed poolId, uint256 amount);

    // --- State & Constants ---
    uint24 public constant BASE_FEE = 3000; // 0.30%
    uint24 public constant MAX_PENALTY_FEE = 150000; // 15.00%
    uint256 public constant DECAY_WINDOW = 7200; // 2 Hours in seconds

    struct ShieldParams {
        uint256 graduationTimestamp;
        Currency launchpadToken; // The volatile token subject to sell penalties
        bool active;
    }

    /// @notice Tracks configuration per PoolId
    mapping(PoolId => ShieldParams) public poolShields;

    /// @notice Tracks pending penalty delta during swap execution for afterSwap donation
    mapping(PoolId => uint24) public pendingPenaltyDelta;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    receive() external payable {}

    /// @notice Specifies permissions required by this hook.
    /// Bit flags: BEFORE_INITIALIZE (1 << 13) | BEFORE_SWAP (1 << 7) | AFTER_SWAP (1 << 6) = 0x20C0
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Pool must be initialized with LPFeeLibrary.DYNAMIC_FEE_FLAG
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert PoolNotDynamicFee();

        PoolId poolId = key.toId();
        if (poolShields[poolId].active) revert PoolAlreadyInitialized();

        // Designate currency0 as launchpad token by convention, or set dynamically
        poolShields[poolId] =
            ShieldParams({graduationTimestamp: block.timestamp, launchpadToken: key.currency0, active: true});

        return this.beforeInitialize.selector;
    }

    /// @notice Intercepts swaps, computes direction, sets LP fee override, and tracks PenaltyDelta
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        ShieldParams memory shield = poolShields[poolId];
        if (!shield.active) revert PoolNotShielded();

        // Determine trade direction:
        // zeroForOne = true  -> Selling currency0 for currency1
        // zeroForOne = false -> Selling currency1 for currency0
        bool isSellingLaunchpadToken = (shield.launchpadToken == key.currency0) ? params.zeroForOne : !params.zeroForOne;

        uint24 fee = calculateDynamicFee(shield.graduationTimestamp, isSellingLaunchpadToken);

        // Calculate penalty delta: PenaltyDelta = CurrentDynamicFee - BASE_FEE
        uint24 penaltyDelta = (isSellingLaunchpadToken && fee > BASE_FEE) ? (fee - BASE_FEE) : 0;
        pendingPenaltyDelta[poolId] = penaltyDelta;

        // Uniswap v4 requires OVERRIDE_FEE_FLAG to replace the pool fee
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /// @notice In afterSwap, routes token proceeds collected from PenaltyDelta back to active LPs via poolManager.donate()
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint24 penaltyDelta = pendingPenaltyDelta[poolId];

        if (penaltyDelta > 0) {
            delete pendingPenaltyDelta[poolId];

            ShieldParams memory shield = poolShields[poolId];
            Currency donateCurrency = shield.launchpadToken;

            // Calculate input token amount swapped
            uint256 inputAmount = params.amountSpecified < 0
                ? uint256(int256(-params.amountSpecified))
                : (params.zeroForOne ? uint256(int256(-delta.amount0())) : uint256(int256(-delta.amount1())));

            // Token proceeds corresponding to the penalty delta
            uint256 penaltyProceeds = (inputAmount * penaltyDelta) / 1_000_000;

            // Check available hook balance for donation
            uint256 hookBalance = donateCurrency.balanceOfSelf();
            uint256 amountToDonate = penaltyProceeds > hookBalance ? hookBalance : penaltyProceeds;

            if (amountToDonate > 0) {
                uint256 donate0 = (donateCurrency == key.currency0) ? amountToDonate : 0;
                uint256 donate1 = (donateCurrency == key.currency1) ? amountToDonate : 0;

                // Donate to in-range liquidity providers, inflating feeGrowthGlobal
                poolManager.donate(key, donate0, donate1, "");

                // Settle open debt with PoolManager
                poolManager.sync(donateCurrency);
                donateCurrency.transfer(address(poolManager), amountToDonate);
                poolManager.settle();

                emit PenaltyDonated(poolId, amountToDonate);
            }
        }

        return (this.afterSwap.selector, 0);
    }

    /// @notice Computes linear decay fee for sells; returns base fee for buys or post-window trades
    function calculateDynamicFee(uint256 graduationTime, bool isSell) public view returns (uint24) {
        if (!isSell) {
            return BASE_FEE;
        }

        uint256 timeElapsed = block.timestamp - graduationTime;
        if (timeElapsed >= DECAY_WINDOW) {
            return BASE_FEE;
        }

        // Linear interpolation formula:
        // Fee(t) = MAX_FEE - (elapsed * (MAX_FEE - BASE_FEE)) / DECAY_WINDOW
        uint256 decayAmount = (timeElapsed * (MAX_PENALTY_FEE - BASE_FEE)) / DECAY_WINDOW;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(MAX_PENALTY_FEE - decayAmount);
    }
}
