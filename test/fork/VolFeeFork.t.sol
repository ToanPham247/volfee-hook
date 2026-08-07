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

abstract contract VolFeeForkHarness is Test, Deployers {
    using StateLibrary for IPoolManager;

    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant EXPECTED_POOL_MANAGER_CODEHASH = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
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
    uint256 internal constant PLATFORM_RATE = 1000;

    Currency internal quote;
    Currency internal tkn;

    function _rpc() internal view returns (string memory) {
        return vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org"));
    }

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
        address expectedToken = Currency.unwrap(quote == currency0 ? currency1 : currency0);
        bytes memory args = abi.encode(address(manager), feeTotalBps, quote, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        h = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), feeTotalBps, quote, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        require(address(h) == addr, "mine");
    }

    function _init(VolFeeHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        _modLiq(key, FULL_LIQ);
    }

    function _modLiq(PoolKey memory key, int256 dl) internal {
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: dl, salt: 0}), bytes(""));
    }

    function _lim(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    function _quoteBal(VolFeeHook h) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    function _assertSolvent(VolFeeHook h, PoolId id) internal view {
        assertEq(_quoteBal(h), h.programmableFeeOwed(id, quote) + h.projectFeeOwed(id, quote), "insolvent: bal != owed");
    }
}

contract VolFeeForkPinnedTest is VolFeeForkHarness {
    uint256 internal constant FORK_BLOCK = 25666892;

    function setUp() public {
        vm.createSelectFork(_rpc(), FORK_BLOCK);
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }
        _bindRealManager();
    }

    function test_fork_realPoolManager_identity() public {
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }
        assertEq(MAINNET_POOL_MANAGER.codehash, EXPECTED_POOL_MANAGER_CODEHASH, "codehash");
        assertEq(address(manager), MAINNET_POOL_MANAGER, "manager bound to real singleton");
    }

    function test_fork_dynamicFee_and_mandatoryFee_againstRealPoolManager() public {
        if (MAINNET_POOL_MANAGER.code.length == 0) {
            vm.skip(true);
        }
        _mkTokens(3000e18, false);
        VolFeeHook h = _deployHook(300);
        (PoolKey memory key, PoolId id) = _init(h);
        _assertSolvent(h, id);
        uint24 initialLpFee = h.previewLpFee();
        assertGe(initialLpFee, h.MIN_LP_FEE(), "initial fee below min");
        assertLe(initialLpFee, h.MAX_LP_FEE(), "initial fee above max");
        bool zeroForOne = (quote == currency0);
        BalanceDelta buyDelta = swapRouter.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(50e18), sqrtPriceLimitX96: _lim(zeroForOne)}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));
        buyDelta;
        uint256 progOwed = h.programmableFeeOwed(id, quote);
        uint256 projOwed = h.projectFeeOwed(id, quote);
        assertGt(progOwed + projOwed, 0, "mandatory fee must accrue on buy");
        _assertSolvent(h, id);
        BalanceDelta sellDelta = swapRouter.swap(key, SwapParams({zeroForOne: !zeroForOne, amountSpecified: -int256(100e18), sqrtPriceLimitX96: _lim(!zeroForOne)}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));
        sellDelta;
        uint24 postLpFee = h.previewLpFee();
        assertGe(postLpFee, h.MIN_LP_FEE(), "post-sell fee below min");
        assertLe(postLpFee, h.MAX_LP_FEE(), "post-sell fee above max");
        _assertSolvent(h, id);
        uint256 finalProgOwed = h.programmableFeeOwed(id, quote);
        uint256 finalProjOwed = h.projectFeeOwed(id, quote);
        assertGt(finalProgOwed, progOwed, "programmable fee should increase after sell");
        assertGt(finalProjOwed, projOwed, "project fee should increase after sell");
    }
}

contract VolFeeForkHeadSmokeTest is VolFeeForkHarness {
    function setUp() public {
        vm.createSelectFork(_rpc());
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
        bool zeroForOne = (quote == currency0);
        BalanceDelta delta = swapRouter.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(25e18), sqrtPriceLimitX96: _lim(zeroForOne)}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));
        delta;
        uint256 progOwed = h.programmableFeeOwed(id, quote);
        uint256 projOwed = h.projectFeeOwed(id, quote);
        assertGt(progOwed + projOwed, 0, "smoke swap must accrue a fee against the head runtime");
        _assertSolvent(h, id);
        uint24 lpFee = h.previewLpFee();
        assertGe(lpFee, h.MIN_LP_FEE(), "lp fee below min");
        assertLe(lpFee, h.MAX_LP_FEE(), "lp fee above max");
    }
}
