// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
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

contract VolFeeHandler {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint160 internal constant MIN_PRICE_LIMIT = 4295128739 + 1;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    VolFeeHook internal immutable hook;
    PoolKey internal key;
    PoolId internal immutable id;
    Currency internal immutable quote;
    Currency internal immutable tkn;
    uint256 public okSwapExactIn;
    uint256 public okSwapVolatile;
    uint256 public attempts;

    constructor(IPoolManager _m, PoolSwapTest _r, VolFeeHook _h, PoolKey memory _key, Currency _quote, Currency _tkn) {
        manager = _m;
        swapRouter = _r;
        hook = _h;
        key = _key;
        id = _key.toId();
        quote = _quote;
        tkn = _tkn;
        vm.prank(address(this));
        MockERC20(Currency.unwrap(_quote)).approve(address(_r), type(uint256).max);
        vm.prank(address(this));
        MockERC20(Currency.unwrap(_tkn)).approve(address(_r), type(uint256).max);
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _checkInvariants() internal view {
        uint24 currentFee = hook.previewLpFee();
        uint24 minFee = hook.MIN_LP_FEE();
        uint24 maxFee = hook.MAX_LP_FEE();
        require(currentFee >= minFee && currentFee <= maxFee, "fee out of bounds");
        uint256 hookBalance = manager.balanceOf(address(hook), quote.toId());
        uint256 owed = hook.programmableFeeOwed(id, quote) + hook.projectFeeOwed(id, quote);
        require(hookBalance == owed, "solvency broken");
        (, int24 poolTick,,) = StateLibrary.getSlot0(manager, id);
        int24 hookTick = hook.lastTick();
        require(hookTick == poolTick, "lastTick mismatch");
    }

    function _swap(bool zeroForOne, int256 amtSpec) internal {
        swapRouter.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amtSpec, sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));
    }

    function swapExactIn(uint256 amtSeed, bool zeroForOne) external {
        attempts++;
        uint256 amt = _bound(amtSeed, 1e12, 5e18);
        _swap(zeroForOne, -int256(amt));
        _checkInvariants();
        okSwapExactIn++;
    }

    function swapVolatile(uint256 amtSeed, bool zeroForOne) external {
        attempts++;
        uint256 amt = _bound(amtSeed, 1e17, 5e18);
        _swap(zeroForOne, -int256(amt));
        _checkInvariants();
        okSwapVolatile++;
    }
}

contract VolFeeInvariants is Test, Deployers {
    using StateLibrary for IPoolManager;

    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    address internal constant PROJECT = 0x000000000000000000000000000000000000bEEF;
    uint160 internal constant FLAGS = 0x10cc;
    uint24 internal constant INITIAL_LP_FEE = 3000;
    uint16 internal constant ALPHA_BPS = 3000;
    uint256 internal constant K_NUM = 50;
    uint256 internal constant K_DEN = 1;
    uint24 internal constant MIN_LP_FEE = 500;
    uint24 internal constant MAX_LP_FEE = 100000;
    uint24 internal constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TS = 60;

    VolFeeHook internal hook;
    VolFeeHandler internal handler;
    PoolKey internal poolKey;
    PoolId internal id;
    Currency internal quote;
    Currency internal tkn;

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        quote = currency1;
        tkn = currency0;
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 1e24);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        address expectedToken = Currency.unwrap(currency0);
        bytes memory args = abi.encode(address(manager), uint16(300), quote, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        hook = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), uint16(300), quote, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        require(address(hook) == addr, "mine");

        poolKey = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(hook)));
        id = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1e21), salt: 0}), bytes(""));

        swapRouter.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -int256(100e18), sqrtPriceLimitX96: MAX_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));
        swapRouter.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -int256(100e18), sqrtPriceLimitX96: MIN_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));

        _verifyInvariants();

        handler = new VolFeeHandler(IPoolManager(address(manager)), swapRouter, hook, poolKey, quote, tkn);
        MockERC20(Currency.unwrap(tkn)).mint(address(handler), 1e24);
        MockERC20(Currency.unwrap(quote)).mint(address(handler), 1e30);
        targetContract(address(handler));
    }

    function _verifyInvariants() internal view {
        uint24 currentFee = hook.previewLpFee();
        uint24 minFee = hook.MIN_LP_FEE();
        uint24 maxFee = hook.MAX_LP_FEE();
        assertGe(currentFee, minFee, "fee below MIN_LP_FEE");
        assertLe(currentFee, maxFee, "fee above MAX_LP_FEE");
        uint256 hookBalance = manager.balanceOf(address(hook), quote.toId());
        uint256 owed = hook.programmableFeeOwed(id, quote) + hook.projectFeeOwed(id, quote);
        assertEq(hookBalance, owed, "solvency broken: balance != owed");
        (, int24 poolTick,,) = manager.getSlot0(id);
        int24 hookTick = hook.lastTick();
        assertEq(hookTick, poolTick, "lastTick does not match pool tick");
    }

    function invariant_feeAlwaysInBounds() public view {
        uint24 currentFee = hook.previewLpFee();
        uint24 minFee = hook.MIN_LP_FEE();
        uint24 maxFee = hook.MAX_LP_FEE();
        assertGe(currentFee, minFee, "fee below MIN_LP_FEE");
        assertLe(currentFee, maxFee, "fee above MAX_LP_FEE");
    }

    function invariant_solvency() public view {
        uint256 hookBalance = manager.balanceOf(address(hook), quote.toId());
        uint256 owed = hook.programmableFeeOwed(id, quote) + hook.projectFeeOwed(id, quote);
        assertEq(hookBalance, owed, "solvency broken: balance != owed");
    }

    function invariant_lastTickTracksPool() public view {
        (, int24 poolTick,,) = manager.getSlot0(id);
        int24 hookTick = hook.lastTick();
        assertEq(hookTick, poolTick, "lastTick does not match pool tick");
    }

    function test_coverage_allActionsExecutable() public {
        handler.swapExactIn(1e18, true);
        handler.swapExactIn(1e18, false);
        handler.swapVolatile(1e18, true);
        handler.swapVolatile(1e18, false);
        assertGt(handler.okSwapExactIn(), 0, "swapExactIn not executable");
        assertGt(handler.okSwapVolatile(), 0, "swapVolatile not executable");
        invariant_feeAlwaysInBounds();
        invariant_solvency();
        invariant_lastTickTracksPool();
    }
}
