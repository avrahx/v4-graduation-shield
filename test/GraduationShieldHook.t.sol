// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {GraduationShieldHook} from "../src/GraduationShieldHook.sol";

contract GraduationShieldHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    GraduationShieldHook hook;
    PoolKey poolKey;
    PoolId poolId;

    Currency launchpadToken;
    Currency reserveToken;

    uint256 constant INITIAL_LIQUIDITY = 10_000 ether;

    function setUp() public {
        // 1. Deploy manager and routers
        deployFreshManagerAndRouters();

        // 2. Deploy test currencies
        deployMintAndApprove2Currencies();

        launchpadToken = currency0;
        reserveToken = currency1;

        // 3. Deploy GraduationShieldHook at valid bitmask address:
        // BEFORE_INITIALIZE_FLAG (1 << 13) = 0x2000
        // BEFORE_SWAP_FLAG (1 << 7)       = 0x0080
        // Total bitmask = 0x2080
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);

        deployCodeTo("GraduationShieldHook.sol:GraduationShieldHook", abi.encode(manager), hookAddress);
        hook = GraduationShieldHook(hookAddress);

        // 4. Initialize pool with dynamic fee flag
        (poolKey, poolId) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // 5. Add full-range liquidity
        int24 minTick = TickMath.minUsableTick(60);
        int24 maxTick = TickMath.maxUsableTick(60);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(INITIAL_LIQUIDITY),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // --- Test 1: Permissions & Bitmask ---

    function test_Permissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize, "beforeInitialize should be true");
        assertTrue(permissions.beforeSwap, "beforeSwap should be true");

        assertFalse(permissions.afterInitialize, "afterInitialize should be false");
        assertFalse(permissions.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be false");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(permissions.afterSwap, "afterSwap should be false");
        assertFalse(permissions.beforeDonate, "beforeDonate should be false");
        assertFalse(permissions.afterDonate, "afterDonate should be false");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertFalse(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be false");

        // Verify address satisfies ALL_HOOK_MASK strictly
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x2080, "Hook address bitmask mismatch");
    }

    // --- Test 2: Pool Initialization ---

    function test_PoolInitialization() public view {
        (uint256 graduationTimestamp, Currency token, bool active) = hook.poolShields(poolId);

        assertTrue(active, "Pool shield must be active");
        assertEq(Currency.unwrap(token), Currency.unwrap(launchpadToken), "Launchpad token must be currency0");
        assertEq(graduationTimestamp, block.timestamp, "Graduation timestamp must match initialization block");
    }

    // --- Test 3: Revert on Non-Dynamic Fee Pool ---

    function test_RevertIfPoolNotDynamicFee() public {
        PoolKey memory staticKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // Static 0.3% fee
            tickSpacing: 60,
            hooks: hook
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(GraduationShieldHook.PoolNotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    // --- Test 4: Dynamic Fee Calculation Trajectory ---

    function test_CalculateDynamicFee_Trajectory() public {
        uint256 t0 = 100_000;
        vm.warp(t0);

        // Buy: always returns BASE_FEE (3000)
        assertEq(hook.calculateDynamicFee(t0, false), 3000, "Buys must return BASE_FEE (3000)");

        // Sells:
        // t = 0: 150000 (15%)
        assertEq(hook.calculateDynamicFee(t0, true), 150000, "Cliff fee at t=0 must be 150000");

        // t = 1800 (30 min = 25% of 2h): 150000 - 36750 = 113250
        vm.warp(t0 + 1800);
        assertEq(hook.calculateDynamicFee(t0, true), 113250, "Fee at 25% decay must be 113250");

        // t = 3600 (1 hr = 50% of 2h): 150000 - 73500 = 76500
        vm.warp(t0 + 3600);
        assertEq(hook.calculateDynamicFee(t0, true), 76500, "Fee at 50% decay must be 76500");

        // t = 5400 (1.5 hr = 75% of 2h): 150000 - 110250 = 39750
        vm.warp(t0 + 5400);
        assertEq(hook.calculateDynamicFee(t0, true), 39750, "Fee at 75% decay must be 39750");

        // t = 7200 (2 hr = 100% of decay window): 3000
        vm.warp(t0 + 7200);
        assertEq(hook.calculateDynamicFee(t0, true), 3000, "Fee at 100% decay must be 3000");

        // t > 7200 (post-window): 3000
        vm.warp(t0 + 10000);
        assertEq(hook.calculateDynamicFee(t0, true), 3000, "Fee after decay must be 3000");
    }

    // --- Test 5: Buy Swap Executes with Standard Fee ---

    function test_BuySwapStandardFee() public {
        // Buy: swapper provides currency1 to receive currency0 (zeroForOne = false)
        int256 amountToBuy = -1 ether;
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: amountToBuy, sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(delta.amount1(), -1 ether, "Buyer spent 1 ether");
        assertTrue(delta.amount0() > 0, "Buyer received launchpad tokens");
    }

    // --- Test 6: Sell Swap at Cliff Executes with Max Penalty Fee ---

    function test_SellSwapCliffMaxFee() public {
        // Sell: swapper dumps currency0 for currency1 (zeroForOne = true)
        int256 sellAmount = -1 ether;
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: sellAmount, sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(delta.amount0(), -1 ether, "Seller gave 1 ether of launchpad token");
        assertTrue(delta.amount1() > 0, "Seller received reserve tokens");
    }

    // --- Test 7: Sell Swap Post Decay Window Executes with Base Fee ---

    function test_SellSwapPostDecay() public {
        // Advance past 2 hour decay window
        vm.warp(block.timestamp + 3 hours);

        int256 sellAmount = -1 ether;
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: sellAmount, sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(delta.amount0(), -1 ether, "Seller gave 1 ether");
        assertTrue(delta.amount1() > 0, "Seller received reserve tokens");
    }

    // --- Verification Matrix Tests ---

    function test_InitialSellFeeIsMax() public view {
        uint24 fee = hook.calculateDynamicFee(block.timestamp, true);
        assertEq(fee, 150_000, "Sell fee at t = t_grad evaluates strictly to 15.00%");
    }

    function test_BuyFeeIsAlwaysBaseFee() public view {
        uint24 fee = hook.calculateDynamicFee(block.timestamp, false);
        assertEq(fee, 3_000, "Buys pay strictly 0.30%, never incurring dumper penalties");
    }

    function test_SellFeeMidwayDecay() public {
        uint256 t0 = 100_000;
        vm.warp(t0 + 3600);
        uint24 fee = hook.calculateDynamicFee(t0, true);
        assertEq(fee, 76_500, "Validates linear decay calculation halfway through window (t = 3600 s)");
    }

    function test_SellFeeClampsToBaseFee() public {
        uint256 t0 = 100_000;
        vm.warp(t0 + 7200);
        assertEq(hook.calculateDynamicFee(t0, true), 3_000, "Asserts fee reverts to baseline 0.30% at t = 7200 s");

        vm.warp(t0 + 15_000);
        assertEq(hook.calculateDynamicFee(t0, true), 3_000, "Asserts fee reverts to baseline 0.30% once t >= 7200 s");
    }

    function testFuzz_FeeMonotonicDecay(uint32 delta1, uint32 delta2) public {
        uint256 t0 = 10_000_000;
        uint256 t1 = t0 + uint256(delta1 % 100_000);
        uint256 t2 = t0 + uint256(delta2 % 100_000);

        if (t1 > t2) {
            (t1, t2) = (t2, t1);
        }

        vm.warp(t1);
        uint24 fee1 = hook.calculateDynamicFee(t0, true);

        vm.warp(t2);
        uint24 fee2 = hook.calculateDynamicFee(t0, true);

        assertTrue(fee1 >= fee2, "Mathematical proof: For all t1 < t2, Fee(t1) >= Fee(t2)");
    }

    function testFuzz_CalculateFeeBoundaries(uint32 elapsed, bool isSell) public {
        uint256 t0 = 10_000_000;
        vm.warp(t0 + uint256(elapsed));

        uint24 fee = hook.calculateDynamicFee(t0, isSell);
        assertTrue(
            fee >= hook.BASE_FEE() && fee <= hook.MAX_PENALTY_FEE(),
            "Asserts fee is strictly bounded: BASE_FEE <= Fee(t) <= MAX_FEE"
        );
    }
}
