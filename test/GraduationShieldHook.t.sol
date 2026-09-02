// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {GraduationShieldHook} from "../src/GraduationShieldHook.sol";

contract GraduationShieldHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    GraduationShieldHook hook;
    PoolKey poolKey;
    PoolId poolId;

    Currency tokenGraduated;
    Currency tokenReserve;

    uint256 constant INITIAL_LIQUIDITY = 10_000 ether;

    function setUp() public {
        // 1. Deploy manager and routers
        deployFreshManagerAndRouters();

        // 2. Deploy test currencies
        deployMintAndApprove2Currencies();

        // Designate currency0 as the graduated token and currency1 as reserve
        tokenGraduated = currency0;
        tokenReserve = currency1;

        // 3. Deploy GraduationShieldHook at valid bitmask address:
        // AFTER_INITIALIZE_FLAG (1 << 12) = 0x1000
        // BEFORE_SWAP_FLAG (1 << 7)       = 0x0080
        // AFTER_SWAP_FLAG (1 << 6)        = 0x0040
        // BEFORE_SWAP_RETURNS_DELTA (1 << 3) = 0x0008
        // Total bitmask = 0x10C8
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        deployCodeTo(
            "GraduationShieldHook.sol:GraduationShieldHook",
            abi.encode(manager),
            hookAddress
        );
        hook = GraduationShieldHook(hookAddress);

        // 4. Initialize pool with dynamic fee
        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // 5. Add full-range liquidity so in-range liquidity is always available for donation
        int24 minTick = TickMath.minUsableTick(60);
        int24 maxTick = TickMath.maxUsableTick(60);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(INITIAL_LIQUIDITY),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // --- Test 1: Permissions & Bitmask ---

    function test_Permissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize, "afterInitialize should be true");
        assertTrue(permissions.beforeSwap, "beforeSwap should be true");
        assertTrue(permissions.afterSwap, "afterSwap should be true");
        assertTrue(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be true");

        assertFalse(permissions.beforeInitialize, "beforeInitialize should be false");
        assertFalse(permissions.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(permissions.beforeDonate, "beforeDonate should be false");
        assertFalse(permissions.afterDonate, "afterDonate should be false");

        // Verify address satisfies ALL_HOOK_MASK strictly
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            0x10C8,
            "Hook address bitmask mismatch"
        );
    }

    // --- Test 2: Initial Pool Configuration ---

    function test_InitialPoolConfiguration() public view {
        (
            Currency gradToken,
            uint32 gradTimestamp,
            uint32 decayDuration,
            uint24 initialFee,
            uint24 baseFee,
            bool isConfigured
        ) = hook.poolConfigs(poolId);

        assertTrue(isConfigured, "Pool should be configured");
        assertEq(Currency.unwrap(gradToken), Currency.unwrap(tokenGraduated), "Graduated token mismatch");
        assertEq(gradTimestamp, uint32(block.timestamp), "Graduation timestamp mismatch");
        assertEq(decayDuration, 7 days, "Decay duration should default to 7 days");
        assertEq(initialFee, 150_000, "Initial fee should be 15%");
        assertEq(baseFee, 3_000, "Base fee should be 0.3%");
    }

    // --- Test 3: Buy Swaps Have Standard 0.3% Fee & No Excess Fee ---

    function test_BuySwapStandardFee() public {
        // Buy: swapper provides currency1 (reserve) to receive currency0 (graduated token)
        // zeroForOne = false
        uint24 buyFee = hook.getBuyFee(poolKey);
        assertEq(buyFee, 3_000, "Buy fee must be 3,000 (0.3%)");

        // Execute buy swap
        int256 amountToBuy = -1 ether;
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: amountToBuy,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Buyer spent 1 ether of currency1 and received currency0
        assertEq(delta.amount1(), -1 ether, "Buyer must have spent 1 ether");
        assertTrue(delta.amount0() > 0, "Buyer must have received token0");
    }

    // --- Test 4: Immediate Cliff Sell (t = 0) Incurs 15% Fee & Donates Excess ---

    function test_SellImmediateCliffMaxFee() public {
        // At t = 0, sell fee should be max 15% (150,000 pips)
        uint24 sellFee = hook.getSellFee(poolKey);
        assertEq(sellFee, 150_000, "Immediate sell fee must be 15%");

        (uint256 feeGrowth0Before,) = manager.getFeeGrowthGlobals(poolId);

        // 14.7% of 1 ether = 0.147 ether
        uint256 expectedExcess = (1 ether * (150_000 - 3_000)) / 1_000_000;
        assertEq(expectedExcess, 0.147 ether, "Excess fee should be 0.147 ether");

        // Sell: swapper dumps currency0 for currency1 (zeroForOne = true)
        int256 sellAmount = -1 ether;
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: sellAmount,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(delta.amount0(), -1 ether, "Seller must have paid 1 ether total");
        assertTrue(delta.amount1() > 0, "Seller received output");

        // Verify fee growth increased from donation
        (uint256 feeGrowth0After,) = manager.getFeeGrowthGlobals(poolId);
        assertTrue(
            feeGrowth0After > feeGrowth0Before,
            "LP fee growth must increase from excess fee donation"
        );
    }

    // --- Test 5: Linear Time-Decay Trajectory Milestones ---

    function test_SellFee_At_Graduation_T0() public view {
        // t = 0: 15% (150,000 pips)
        assertEq(hook.getSellFee(poolKey), 150_000, "Fee at graduation cliff must be 15%");
    }

    function test_SellFee_At_QuarterDuration_T1_4() public {
        // t = 1.75 days (1/4 duration): 15% - 25% * 14.7% = 11.325% = 113,250
        vm.warp(block.timestamp + 1 days + 18 hours);
        assertEq(hook.getSellFee(poolKey), 113_250, "Fee at 1/4 duration should be 11.325%");
    }

    function test_SellFee_At_HalfDuration_T1_2() public {
        // t = 3.5 days (half duration): 15% - 50% * 14.7% = 7.65% = 76,500
        vm.warp(block.timestamp + 3 days + 12 hours);
        assertEq(hook.getSellFee(poolKey), 76_500, "Fee at 1/2 duration should be 7.65%");
    }

    function test_SellFee_At_ThreeQuartersDuration_T3_4() public {
        // t = 5.25 days (3/4 duration): 15% - 75% * 14.7% = 3.975% = 39,750
        vm.warp(block.timestamp + 5 days + 6 hours);
        assertEq(hook.getSellFee(poolKey), 39_750, "Fee at 3/4 duration should be 3.975%");
    }

    function test_SellFee_At_FullDuration_T1() public {
        // t = 7 days (fully decayed): 0.3% = 3,000
        vm.warp(block.timestamp + 7 days);
        assertEq(hook.getSellFee(poolKey), 3_000, "Fee at end of window must be base fee (0.3%)");
    }

    function test_SellFee_Past_DecayWindow() public {
        // t = 10 days (past decay window): still 0.3% = 3,000
        vm.warp(block.timestamp + 10 days);
        assertEq(hook.getSellFee(poolKey), 3_000, "Fee after decay must remain base fee (0.3%)");
    }

    // --- Test 6: Sell Post-Decay Charges Standard Fee & Zero Donation ---

    function test_SellPostDecayDuration() public {
        // Warp 10 days into the future (past 7 days decay)
        vm.warp(block.timestamp + 10 days);
        assertEq(hook.getSellFee(poolKey), 3_000);

        // Execute sell swap
        int256 sellAmount = -1 ether;
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: sellAmount,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(delta.amount0(), -1 ether);
        assertTrue(delta.amount1() > 0);
    }

    // --- Test 7: ExactOutput Sell Reverts During Cliff Period ---

    function test_ExactOutputSellRevertsDuringCliff() public {
        // In cliff period (t = 0), exact output sell is forbidden
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(GraduationShieldHook.ExactOutputSellNotAllowedDuringCliff.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 0.5 ether, // ExactOutput (> 0)
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // --- Test 8: ExactOutput Sell Allowed After Decay Duration ---

    function test_ExactOutputSellAllowedPostDecay() public {
        // Warp past decay duration
        vm.warp(block.timestamp + 8 days);

        // ExactOutput sell should succeed post decay
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 0.1 ether, // ExactOutput (> 0)
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(delta.amount1(), 0.1 ether, "Receiver must have received exactly 0.1 ether");
        assertTrue(delta.amount0() < 0, "Seller gave currency0");
    }

    // --- Test 9: Price Floor Defense & LP Fee Growth Comparison ---

    function test_PriceFloorDefenseFeeGrowth() public {
        // Record starting fee growth
        (uint256 feeGrowthBefore,) = manager.getFeeGrowthGlobals(poolId);

        // Large dump of 5 tokens during cliff
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        (uint256 feeGrowthAfter,) = manager.getFeeGrowthGlobals(poolId);
        uint256 feeGrowthDelta = feeGrowthAfter - feeGrowthBefore;

        assertTrue(feeGrowthDelta > 0, "Fee growth must increase significantly from 14.7% donation");
        console2.log("Fee Growth Delta for in-range LPs (defense yield):", feeGrowthDelta);
    }
}
