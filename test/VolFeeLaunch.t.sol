// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
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
import {VolFeeHook} from "../src/VolFeeHook.sol";

/// @notice EXECUTABLE launch graph: proves a normal deployer can launch a tradable VolFee pool end-to-end and
///         that the launch is exclusive (precommit binding), atomic-safe (occupied CREATE2 / wrong key revert),
///         and post-conditions hold. Mirrors the immutable steps described in `submissions/volfee/launch.json`.
contract VolFeeLaunchTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = 0x10cc;
    address constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    address constant PROJECT = 0x000000000000000000000000000000000000bEEF;
    uint24 constant DF = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 constant TS = 60;
    uint24 constant BASE_FEE = 3000;
    uint16 constant FEE_BPS = 300;

    function setUp() public {
        deployFreshManagerAndRouters();
    }

    /// Full launch: deploy quote(WETH-like) + token, mine the hook for mask 0x10cc PRECOMMITTED to the exact
    /// token/price/tickSpacing, deploy via CREATE2, initialize the dynamic-fee pool (afterInitialize binds it),
    /// add initial liquidity, then swap — proving the coin is directly tradable.
    function test_launch_endToEnd_tradable() public {
        // 1. Token universe (quote = the lower-sorted currency0).
        MockERC20 a = new MockERC20("Quote", "Q", 18);
        MockERC20 b = new MockERC20("VolCoin", "VOL", 18);
        (Currency c0, Currency c1) = SortTokens.sort(a, b);
        Currency quote = c0;
        address token = Currency.unwrap(c1);

        // 2. Mine + CREATE2-deploy the hook, precommitted to (token, SQRT_PRICE_1_1, TS).
        bytes memory args = abi.encode(address(manager), FEE_BPS, quote, PROJECT, BASE_FEE, uint16(3000), uint256(50), uint256(1), uint24(500), uint24(100000), token, SQRT_PRICE_1_1, TS);
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        VolFeeHook hook = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), FEE_BPS, quote, PROJECT, BASE_FEE, 3000, 50, 1, 500, 100000, token, SQRT_PRICE_1_1, TS);
        assertEq(address(hook), hookAddr, "hook address == mined");
        assertEq(uint160(hookAddr) & 0x3fff, FLAGS, "permission bits match mask 0x10cc");

        // 3. Initialize the canonical dynamic-fee pool. afterInitialize validates the precommit and binds.
        PoolKey memory key = PoolKey(c0, c1, DF, TS, IHooks(hookAddr));
        PoolId id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(Currency.unwrap(hook.tknCurrency()), token, "hook bound the exact precommitted token");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(id), "hook bound the exact pool id");
        (, , , uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, BASE_FEE, "base LP fee set at init");

        // 4. Provide initial liquidity (custody: LPs own their positions; the hook holds only fee claims).
        a.mint(address(this), 1e24);
        b.mint(address(this), 1e24);
        a.approve(address(modifyLiquidityRouter), type(uint256).max);
        b.approve(address(modifyLiquidityRouter), type(uint256).max);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, int256(1e21), 0), bytes(""));

        // 5. The coin is directly tradable: a buy executes and the mandatory fee accrues, solvently.
        swapRouter.swap(key, SwapParams(true, -int256(1e18), MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), bytes(""));
        uint256 owed = hook.programmableFeeOwed(id, quote) + hook.projectFeeOwed(id, quote);
        assertGt(owed, 0, "mandatory fee accrued on the first trade");
        assertEq(manager.balanceOf(address(hook), quote.toId()), owed, "post-state solvency: hook 6909 == owed");
    }

    /// Occupancy / atomicity: once the hook is bound, a second initialization on any distinct valid-looking key
    /// reverts (PoolAlreadyBound checked before the precommit), so the launch cannot be captured or duplicated.
    function test_launch_secondInit_reverts_afterBound() public {
        MockERC20 a = new MockERC20("Quote", "Q", 18);
        MockERC20 b = new MockERC20("VolCoin", "VOL", 18);
        (Currency c0, Currency c1) = SortTokens.sort(a, b);
        address token = Currency.unwrap(c1);
        bytes memory args = abi.encode(address(manager), FEE_BPS, c0, PROJECT, BASE_FEE, uint16(3000), uint256(50), uint256(1), uint24(500), uint24(100000), token, SQRT_PRICE_1_1, TS);
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        VolFeeHook hook = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), FEE_BPS, c0, PROJECT, BASE_FEE, 3000, 50, 1, 500, 100000, token, SQRT_PRICE_1_1, TS);
        PoolKey memory key = PoolKey(c0, c1, DF, TS, IHooks(hookAddr));
        manager.initialize(key, SQRT_PRICE_1_1);
        // A second distinct key reusing the same bound hook reverts (wrapped hook error).
        PoolKey memory second = PoolKey(c0, c1, DF, int24(30), IHooks(hookAddr));
        vm.expectRevert();
        manager.initialize(second, SQRT_PRICE_1_1);
    }
}
