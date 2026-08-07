// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VolFeeHook} from "../src/VolFeeHook.sol";

contract VolFeeCaptureTest is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
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

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    function _deployHookPrecommit(address expectedToken) internal returns (VolFeeHook) {
        bytes memory args = abi.encode(address(manager), uint16(300), currency0, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        VolFeeHook h = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), uint16(300), currency0, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        require(address(h) == addr, "mine");
        return h;
    }

    function test_capture_foreignToken_reverts() public {
        address expectedToken = Currency.unwrap(currency1);
        VolFeeHook h = _deployHookPrecommit(expectedToken);
        MockERC20 foreignToken = new MockERC20("Foreign", "FOR", 18);
        foreignToken.mint(address(this), 1e30);
        foreignToken.approve(address(swapRouter), type(uint256).max);
        foreignToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        Currency foreignCurrency = Currency.wrap(address(foreignToken));
        PoolKey memory attackerKey;
        if (Currency.unwrap(foreignCurrency) < Currency.unwrap(currency0)) {
            attackerKey = PoolKey(foreignCurrency, currency0, DYNAMIC_FEE, TS, IHooks(address(h)));
        } else {
            attackerKey = PoolKey(currency0, foreignCurrency, DYNAMIC_FEE, TS, IHooks(address(h)));
        }
        // PoolManager wraps hook errors, so we expect any revert
        vm.expectRevert();
        manager.initialize(attackerKey, SQRT_PRICE_1_1);
    }

    function test_capture_wrongStartPrice_reverts() public {
        address expectedToken = Currency.unwrap(currency1);
        VolFeeHook h = _deployHookPrecommit(expectedToken);
        uint160 wrongPrice = 79226673515401279992447579055;
        PoolKey memory key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        // PoolManager wraps hook errors, so we expect any revert
        vm.expectRevert();
        manager.initialize(key, wrongPrice);
    }

    function test_capture_wrongTickSpacing_reverts() public {
        address expectedToken = Currency.unwrap(currency1);
        VolFeeHook h = _deployHookPrecommit(expectedToken);
        PoolKey memory key = PoolKey(currency0, currency1, DYNAMIC_FEE, 10, IHooks(address(h)));
        // PoolManager wraps hook errors, so we expect any revert
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_capture_reinit_reverts() public {
        address expectedToken = Currency.unwrap(currency1);
        VolFeeHook h = _deployHookPrecommit(expectedToken);
        PoolKey memory key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}), ZERO_BYTES);
        
        // Verify the pool is bound
        assertEq(Currency.unwrap(h.tknCurrency()), Currency.unwrap(currency1), "tknCurrency should be currency1");
        
        // Attempt a second initialization with a different valid dynamic fee
        // This should hit the PoolAlreadyBound check in the hook
        // Note: PoolManager may wrap this error, so we just check for any revert
        uint24 otherDynamicFee = 0x800000 | uint24(1); // Another dynamic fee marker
        PoolKey memory secondKey = PoolKey(currency0, currency1, otherDynamicFee, TS, IHooks(address(h)));
        
        // The hook's _bound guard should catch this and revert with PoolAlreadyBound
        // PoolManager wraps hook errors, so we expect any revert
        vm.expectRevert();
        manager.initialize(secondKey, SQRT_PRICE_1_1);
    }
}
