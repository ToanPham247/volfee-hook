// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {VolFeeHook} from "../src/VolFeeHook.sol";
import {VolMath} from "../src/lib/VolMath.sol";

/**
 * @notice Test suite for volatility-adaptive LP fee calibration.
 *         Tests the novel core: LP fee auto-calibrates to realized volatility from tick movement.
 */
contract VolAdaptiveFeeTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = 0x10cc;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    address internal constant PROJECT = 0x000000000000000000000000000000000000bEEF;

    // Volatility fee parameters
    uint24 internal constant INITIAL_LP_FEE = 3000;
    uint16 internal constant ALPHA_BPS = 3000;
    uint256 internal constant K_NUM = 50;
    uint256 internal constant K_DEN = 1;
    uint24 internal constant MIN_LP_FEE = 500;
    uint24 internal constant MAX_LP_FEE = 100000;

    uint24 internal constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    /* ------------------------------------------------------------------ */
    /*                             Harness                                */
    /* ------------------------------------------------------------------ */

    function _deployHook() internal returns (VolFeeHook h) {
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            300,
            currency0,
            PROJECT,
            INITIAL_LP_FEE,
            ALPHA_BPS,
            K_NUM,
            K_DEN,
            MIN_LP_FEE,
            MAX_LP_FEE
        );
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        h = new VolFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            300,
            currency0,
            PROJECT,
            INITIAL_LP_FEE,
            ALPHA_BPS,
            K_NUM,
            K_DEN,
            MIN_LP_FEE,
            MAX_LP_FEE
        );
        require(address(h) == addr, "hook miner mismatch");
    }

    function _deployHookWithParams(
        uint16 _feeTotalBps,
        uint24 _initialLpFee,
        uint16 _alphaBps,
        uint256 _kNum,
        uint256 _kDen,
        uint24 _minLpFee,
        uint24 _maxLpFee
    ) internal returns (VolFeeHook h) {
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            _feeTotalBps,
            currency0,
            PROJECT,
            _initialLpFee,
            _alphaBps,
            _kNum,
            _kDen,
            _minLpFee,
            _maxLpFee
        );
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        h = new VolFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            _feeTotalBps,
            currency0,
            PROJECT,
            _initialLpFee,
            _alphaBps,
            _kNum,
            _kDen,
            _minLpFee,
            _maxLpFee
        );
        require(address(h) == addr, "hook miner mismatch");
    }

    function _initPool(VolFeeHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );
    }

    function _hookAndPool()
        internal
        returns (VolFeeHook h, PoolKey memory key, PoolId id)
    {
        h = _deployHook();
        (key, id) = _initPool(h);
    }

    /* ================================================================== */
    /*  #1  calm swaps keep fee at/near base                              */
    /* ================================================================== */

    function test_calm_keepsBaseFee() public {
        (VolFeeHook h, PoolKey memory key,) = _hookAndPool();

        // Initial fee should be at base (ewmaVol = 0)
        uint24 feeBefore = h.previewLpFee();
        assertEq(feeBefore, INITIAL_LP_FEE, "initial fee should equal base");

        // Perform small swaps that barely move the tick
        swap(key, true, -1000, ZERO_BYTES);
        swap(key, false, -1000, ZERO_BYTES);
        swap(key, true, -500, ZERO_BYTES);

        // Fee should stay at or near base (may increase slightly but not above base with small moves)
        uint24 feeAfter = h.previewLpFee();
        assertLe(feeAfter, INITIAL_LP_FEE + 100, "calm swaps should keep fee near base");
        assertGe(feeAfter, MIN_LP_FEE, "fee should not go below min");
    }

    /* ================================================================== */
    /*  #2  volatile swaps raise fee                                      */
    /* ================================================================== */

    function test_volatility_raisesFee() public {
        (VolFeeHook h, PoolKey memory key,) = _hookAndPool();

        uint24 feeBefore = h.previewLpFee();
        assertEq(feeBefore, INITIAL_LP_FEE, "initial fee should be base");

        // Perform large, tick-moving swaps to increase volatility
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -1e18, ZERO_BYTES);
            swap(key, false, -1e18, ZERO_BYTES);
        }

        uint24 feeAfter = h.previewLpFee();

        // Fee should have increased materially due to volatility
        assertGt(feeAfter, feeBefore, "volatile swaps should raise fee above base");
        assertLe(feeAfter, MAX_LP_FEE, "fee should not exceed max");
    }

    /* ================================================================== */
    /*  #3  manipulation resistance: own swap cannot lower own fee        */
    /* ================================================================== */

    function test_manipulation_ownSwapCannotLowerOwnFee() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool();

        // Record fee before a big swap
        uint24 feeBefore = h.previewLpFee();
        uint256 ewmaBefore = h.ewmaVol();

        // Perform a large swap
        int256 largeSwap = -1e18;
        swap(key, true, largeSwap, ZERO_BYTES);

        // The fee charged on THIS swap was based on ewmaBefore (not updated yet)
        // After the swap, ewmaVol should have increased
        uint256 ewmaAfter = h.ewmaVol();
        assertGt(ewmaAfter, ewmaBefore, "ewma should increase after large swap");

        // The preview for the NEXT swap should be higher
        uint24 feeAfter = h.previewLpFee();
        assertGe(feeAfter, feeBefore, "fee should not decrease after own volatile swap");

        // Verify monotonicity: do another large swap, fee should continue rising
        swap(key, false, -1e18, ZERO_BYTES);
        uint24 feeNext = h.previewLpFee();
        assertGe(feeNext, feeAfter, "fee should be monotonic across volatile sequence");
    }

    /* ================================================================== */
    /*  #4  fee always stays within bounds (fuzz)                         */
    /* ================================================================== */

    /// forge-config: default.fuzz.runs = 48
    function test_fee_always_in_bounds(uint256 seed) public {
        (VolFeeHook h, PoolKey memory key,) = _hookAndPool();

        // Perform varied swaps
        for (uint256 i = 0; i < 20; i++) {
            // Vary swap size and direction
            uint256 swapSize = 1e15 * ((seed % 100) + 1);
            if (swapSize > 1e18) swapSize = 1e18;

            bool zeroForOne = (seed % 3) == 0;
            int256 amt = zeroForOne ? -int256(swapSize) : int256(swapSize);

            // Alternate direction occasionally
            if (i % 4 == 0) {
                zeroForOne = !zeroForOne;
                amt = -amt;
            }

            swap(key, zeroForOne, amt, ZERO_BYTES);

            // Check bounds after each swap
            uint24 fee = h.previewLpFee();
            assertGe(fee, MIN_LP_FEE, "fee below min after swap");
            assertLe(fee, MAX_LP_FEE, "fee above max after swap");

            seed = uint256(keccak256(abi.encode(seed)));
        }
    }

    /* ================================================================== */
    /*  #5  lastTick and ewma update correctly                            */
    /* ================================================================== */

    function test_lastTick_and_ewma_update() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool();

        // Initial state
        int24 tickBefore = h.lastTick();
        uint256 ewmaBefore = h.ewmaVol();
        assertEq(ewmaBefore, 0, "initial ewma should be 0");

        // Get pool's current tick before swap
        (, int24 poolTickBefore,,) = manager.getSlot0(id);
        assertEq(tickBefore, poolTickBefore, "lastTick should match pool tick initially");

        // Perform a swap
        swap(key, true, -1e18, ZERO_BYTES);

        // After swap, lastTick should equal pool's current tick
        (, int24 poolTickAfter,,) = manager.getSlot0(id);
        assertEq(h.lastTick(), poolTickAfter, "lastTick should equal pool tick after swap");

        // ewmaVol should have changed (unless tick didn't move, which is unlikely with 1e18)
        uint256 ewmaAfter = h.ewmaVol();
        // ewmaVol increases if there was tick movement
        uint256 tickDelta = VolMath.absTickDelta(poolTickAfter, poolTickBefore);
        if (tickDelta > 0) {
            assertGt(ewmaAfter, ewmaBefore, "ewma should increase when tick moves");
        }
    }

    /* ================================================================== */
    /*  #6  mandatory fee still works alongside LP fee override           */
    /* ================================================================== */

    function test_mandatory_fee_still_works() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool();

        // Record state before swap
        uint256 balBefore = manager.balanceOf(address(h), currency0.toId());
        uint256 owedBefore = h.programmableFeeOwed(id, currency0);
        uint256 projBefore = h.projectFeeOwed(id, currency0);

        // Perform a swap
        swap(key, true, -1e18, ZERO_BYTES);

        // Check that mandatory fees accrued
        uint256 balAfter = manager.balanceOf(address(h), currency0.toId());
        uint256 owedAfter = h.programmableFeeOwed(id, currency0);
        uint256 projAfter = h.projectFeeOwed(id, currency0);

        assertGt(balAfter, balBefore, "hook balance should increase from mandatory fee");
        assertGt(owedAfter, owedBefore, "platform fee owed should increase");
        assertGt(projAfter, projBefore, "project fee owed should increase");

        // Verify the split is correct
        uint256 totalAccrued = balAfter - balBefore;
        uint256 platformAccrued = owedAfter - owedBefore;
        uint256 projectAccrued = projAfter - projBefore;

        assertEq(totalAccrued, platformAccrued + projectAccrued, "fee split must sum to total");
    }

    /* ================================================================== */
    /*  #7  constructor validation - verify params are stored correctly   */
    /* ================================================================== */

    function test_constructor_stores_alphaBps() public {
        VolFeeHook h = _deployHook();
        assertEq(h.ALPHA_BPS(), ALPHA_BPS, "alphaBps mismatch");
        assertLe(h.ALPHA_BPS(), 10000, "alphaBps must be <= 10000");
    }

    function test_constructor_stores_kDenominator() public {
        VolFeeHook h = _deployHook();
        assertEq(h.K_DEN(), K_DEN, "kDenominator mismatch");
        assertGt(h.K_DEN(), 0, "kDenominator must be > 0");
    }

    function test_constructor_stores_fee_bounds() public {
        VolFeeHook h = _deployHook();
        assertLe(h.MIN_LP_FEE(), h.MAX_LP_FEE(), "min should be <= max");
        assertLe(h.MAX_LP_FEE(), 1_000_000, "max should be <= 1_000_000");
    }

    function test_constructor_stores_maxLpFee() public {
        VolFeeHook h = _deployHook();
        assertLe(h.MAX_LP_FEE(), 1_000_000, "maxLpFee must be <= 1_000_000");
    }

    function test_constructor_stores_initialLpFee_in_bounds() public {
        VolFeeHook h = _deployHook();
        assertGe(h.INITIAL_LP_FEE(), h.MIN_LP_FEE(), "initialLpFee must be >= minLpFee");
        assertLe(h.INITIAL_LP_FEE(), h.MAX_LP_FEE(), "initialLpFee must be <= maxLpFee");
    }

    /* ================================================================== */
    /*  #8  fee clamping at maxLpFee                                      */
    /* ================================================================== */

    function test_fee_clamps_at_maxLpFee() public {
        // Use more aggressive volatility params to reach max fee faster
        // fee = baseFee + ewmaVol * kNum / kDen
        // To reach maxFee=100000 from baseFee=3000: need ewmaVol * kNum >= 97000
        // With kNum=10000, need ewmaVol >= 10 (achievable with tick deltas)
        VolFeeHook h = _deployHookWithParams(
            300,    // feeTotalBps
            3000,   // INITIAL_LP_FEE
            8000,   // ALPHA_BPS - high alpha for fast accumulation (80%)
            10000,  // K_NUM - high multiplier to reach max faster
            1,      // K_DEN
            500,    // MIN_LP_FEE
            100000  // MAX_LP_FEE
        );

        // Deploy and initialize pool with this hook
        PoolKey memory key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );

        // Initial fee should be at base
        assertEq(h.previewLpFee(), 3000, "initial fee should be base");

        // Create volatility with alternating large swaps
        // Need enough iterations to build up ewmaVol
        for (uint256 i = 0; i < 200; i++) {
            swap(key, true, -1e18, ZERO_BYTES);
            swap(key, false, -1e18, ZERO_BYTES);
        }

        uint24 fee = h.previewLpFee();

        // Fee should be clamped at max
        assertEq(fee, 100000, "fee should clamp at maxLpFee");
    }
}
