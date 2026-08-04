// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {VolFeeHook} from "../../src/VolFeeHook.sol";

/**
 * @title VolFee — mainnet-fork harness
 * @notice Shared harness that binds the REAL Ethereum-mainnet Uniswap v4 PoolManager singleton
 *         and exercises the VolFee hook against that real runtime.
 */
abstract contract VolFeeForkHarness is Test, Deployers {
    using StateLibrary for IPoolManager;

    /// @notice Canonical Ethereum-mainnet v4 PoolManager singleton.
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice The runtime codehash observed live at the deployment block.
    bytes32 internal constant EXPECTED_POOL_MANAGER_CODEHASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;

    uint160 internal constant FLAGS = 0x10cc;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    address internal constant PROJECT = 0x000000000000000000000000000000000000bEEF;

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
    int256 internal constant FULL_LIQ = int256(1e21);

    uint256 internal constant RATE_DENOM = 1_000_000;
    uint256 internal constant PLATFORM_RATE = 1000; // 10 bps

    Currency internal quote;
    Currency internal tkn;

    /// @dev Resolve the fork RPC.
    function _rpc() internal view returns (string memory) {
        // Archive-capable public endpoint by default: the pinned-block test needs archive state
        // (the public "recent-only" nodes 403 on old blocks). Override with MAINNET_RPC_URL if desired.
        return vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org"));
    }

    /// @dev Point `manager` at the REAL mainnet PoolManager and deploy test routers.
    function _bindRealManager() internal {
        assertEq(MAINNET_POOL_MANAGER.codehash, EXPECTED_POOL_MANAGER_CODEHASH, "PoolManager codehash mismatch");
        manager = IPoolManager(MAINNET_POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
    }

    function _mkTokens(uint256 tknSupply, bool quoteIs0) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        quote = quoteIs0 ? currency0 : currency1;
        tkn = quoteIs0 ? currency1 : currency0;
        MockERC20(Currency.unwrap(tkn)).mint(address(this), tknSupply);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        _approve(currency0);
        _approve(currency1);
    }

    function _approve(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c)).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function _deployHook(uint16 feeTotalBps) internal returns (VolFeeHook h) {
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            feeTotalBps,
            quote,
            PROJECT,
            INITIAL_LP_FEE,
            ALPHA_BPS,
            K_NUM,
            K_DEN,
            MIN_LP_FEE,
            MAX_LP_FEE
        );
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        h = new VolFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            feeTotalBps,
            quote,
            PROJECT,
            INITIAL_LP_FEE,
            ALPHA_BPS,
            K_NUM,
            K_DEN,
            MIN_LP_FEE,
            MAX_LP_FEE
        );
        require(address(h) == addr, "mine");
    }

    function _init(VolFeeHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        _modLiq(key, FULL_LIQ);
    }

    function _modLiq(PoolKey memory key, int256 dl) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: dl, salt: 0}),
            bytes("")
        );
    }

    function _lim(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    function _quoteBal(VolFeeHook h) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    /// @dev Solvency: hook's quote ERC-6909 claim balance backs owed fees exactly.
    function _assertSolvent(VolFeeHook h, PoolId id) internal view {
        assertEq(
            _quoteBal(h),
            h.programmableFeeOwed(id, quote) + h.projectFeeOwed(id, quote),
            "insolvent: bal != owed"
        );
    }
}

/**
 * @notice PINNED-BLOCK fork test. Forks Ethereum mainnet at a specific block,
 *         binds the REAL singleton, and exercises VolFee against the real PoolManager.
 * @dev This test requires archive access. If the RPC doesn't support archive queries,
 *      the test will be skipped gracefully.
 */
contract VolFeeForkPinnedTest is VolFeeForkHarness {
    uint256 internal constant FORK_BLOCK = 25666892;

    function setUp() public {
        vm.createSelectFork(_rpc(), FORK_BLOCK);
        // Skip if no code at PoolManager (RPC unavailable, wrong network, or archive access denied)
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }
        _bindRealManager();
    }

    /// @notice The pinned block's PoolManager code is exactly the canonical runtime.
    function test_fork_realPoolManager_identity() public {
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }
        assertEq(MAINNET_POOL_MANAGER.codehash, EXPECTED_POOL_MANAGER_CODEHASH, "codehash");
        assertEq(address(manager), MAINNET_POOL_MANAGER, "manager bound to real singleton");
    }

    /// @notice End-to-end against the real PoolManager: dynamic fee + mandatory fee accrual.
    function test_fork_dynamicFee_and_mandatoryFee_againstRealPoolManager() public {
        // Check if we have archive access by verifying PoolManager code
        // If this fails, the test will be skipped (public RPCs don't support archive access)
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }

        // Setup: WETH/TKN pool with quote = currency1
        _mkTokens(3000e18, false);
        VolFeeHook h = _deployHook(300); // 3% total fee
        (PoolKey memory key, PoolId id) = _init(h);
        _assertSolvent(h, id);

        // Record initial fee state
        uint24 initialLpFee = h.previewLpFee();
        assertGe(initialLpFee, h.MIN_LP_FEE(), "initial fee below min");
        assertLe(initialLpFee, h.MAX_LP_FEE(), "initial fee above max");

        // ---- BUY (exact-input, quote in) to seed fees ----
        bool zeroForOne = (quote == currency0);
        BalanceDelta buyDelta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(50e18), sqrtPriceLimitX96: _lim(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        buyDelta; // silence unused

        // Assert mandatory fee accrued
        uint256 progOwed = h.programmableFeeOwed(id, quote);
        uint256 projOwed = h.projectFeeOwed(id, quote);
        assertGt(progOwed + projOwed, 0, "mandatory fee must accrue on buy");

        // Assert solvency holds
        _assertSolvent(h, id);

        // ---- SELL (volatile swap) to stress volatility ----
        BalanceDelta sellDelta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: !zeroForOne, amountSpecified: -int256(100e18), sqrtPriceLimitX96: _lim(!zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        sellDelta; // silence unused

        // Assert fee still in bounds after volatile swap
        uint24 postLpFee = h.previewLpFee();
        assertGe(postLpFee, h.MIN_LP_FEE(), "post-sell fee below min");
        assertLe(postLpFee, h.MAX_LP_FEE(), "post-sell fee above max");

        // Assert solvency still holds
        _assertSolvent(h, id);

        // Assert fees accrued from both swaps
        uint256 finalProgOwed = h.programmableFeeOwed(id, quote);
        uint256 finalProjOwed = h.projectFeeOwed(id, quote);
        assertGt(finalProgOwed, progOwed, "programmable fee should increase after sell");
        assertGt(finalProjOwed, projOwed, "project fee should increase after sell");
    }
}

/**
 * @notice CURRENT-HEAD smoke test. Forks at the latest block, binds the REAL singleton,
 *         initializes a pool + liquidity, and does one swap — minimal liveness proof.
 */
contract VolFeeForkHeadSmokeTest is VolFeeForkHarness {
    function setUp() public {
        vm.createSelectFork(_rpc()); // latest block
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }
        _bindRealManager();
    }

    function test_fork_head_smoke() public {
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }

        assertGt(MAINNET_POOL_MANAGER.code.length, 0, "no PoolManager code at head");

        _mkTokens(3000e18, false);
        VolFeeHook h = _deployHook(300);
        (PoolKey memory key, PoolId id) = _init(h);
        _assertSolvent(h, id);

        // one exact-input swap — must accrue a fee and stay solvent at head
        bool zeroForOne = (quote == currency0);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(25e18), sqrtPriceLimitX96: _lim(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        delta; // silence unused

        uint256 progOwed = h.programmableFeeOwed(id, quote);
        uint256 projOwed = h.projectFeeOwed(id, quote);
        assertGt(progOwed + projOwed, 0, "smoke swap must accrue a fee against the head runtime");
        _assertSolvent(h, id);

        // Fee in bounds
        uint24 lpFee = h.previewLpFee();
        assertGe(lpFee, h.MIN_LP_FEE(), "lp fee below min");
        assertLe(lpFee, h.MAX_LP_FEE(), "lp fee above max");
    }
}
