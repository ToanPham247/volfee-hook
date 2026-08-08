// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VolFeeHook} from "../src/VolFeeHook.sol";
import {VolFeeToken} from "../src/VolFeeToken.sol";
import {VolFeeLauncher} from "../src/VolFeeLauncher.sol";

/// @notice EXECUTABLE launch graph proof for the v1 launch specification (submissions/volfee/launch.json).
///         Deploys the atomic {VolFeeLauncher}, mines the token + hook salts, launches the whole pool in ONE
///         transaction (token -> hook -> initialize -> seed liquidity -> settle) and proves the coin is
///         directly tradable, the hook is bound to exactly the launched token, and the launch is single-use.
contract VolFeeLauncherTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = 0x10cc;
    int24 constant TS = 60;

    // Mirror of VolFeeLauncher's canonical configuration constants (used to reconstruct the hook ctor args
    // for salt mining; kept in sync with the launcher).
    uint16 constant FEE_TOTAL_BPS = 300;
    uint24 constant INITIAL_LP_FEE = 3000;
    uint16 constant ALPHA_BPS = 3000;
    uint256 constant K_NUM = 50;
    uint256 constant K_DEN = 1;
    uint24 constant MIN_LP_FEE = 500;
    uint24 constant MAX_LP_FEE = 100000;

    MockERC20 quote;
    VolFeeLauncher launcher;

    function setUp() public {
        deployFreshManagerAndRouters();
        quote = new MockERC20("Wrapped Ether", "WETH", 18);
        launcher = new VolFeeLauncher(IPoolManager(address(manager)), IERC20(address(quote)), address(this));
    }

    function _mineAndLaunch(uint256 supply, uint128 liquidity)
        internal
        returns (VolFeeToken token, VolFeeHook hook, PoolKey memory key)
    {
        bytes32 tokenSalt = keccak256("volfee-token");
        // Predict the token address the launcher will CREATE2, so the hook's EXPECTED_TOKEN can be mined in.
        bytes32 tokenInitHash = keccak256(
            abi.encodePacked(
                type(VolFeeToken).creationCode, abi.encode("VolCoin", "VOL", supply, address(launcher))
            )
        );
        address predictedToken = vm.computeCreate2Address(tokenSalt, tokenInitHash, address(launcher));

        bytes memory hookArgs = abi.encode(
            address(manager),
            FEE_TOTAL_BPS,
            Currency.wrap(address(quote)),
            address(this), // project == launchWallet
            INITIAL_LP_FEE,
            ALPHA_BPS,
            K_NUM,
            K_DEN,
            MIN_LP_FEE,
            MAX_LP_FEE,
            predictedToken,
            SQRT_PRICE_1_1,
            TS
        );
        // The launcher is the CREATE2 deployer of the hook, so mine against the launcher address.
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(address(launcher), FLAGS, type(VolFeeHook).creationCode, hookArgs);

        // Fund + approve the launch wallet (this test) for the quote-side liquidity.
        quote.mint(address(this), 1e24);
        quote.approve(address(launcher), type(uint256).max);

        VolFeeLauncher.LaunchParams memory params = VolFeeLauncher.LaunchParams({
            name: "VolCoin",
            symbol: "VOL",
            totalSupply: supply,
            tokenSalt: tokenSalt,
            hookSalt: hookSalt,
            tickSpacing: TS,
            sqrtPriceX96: SQRT_PRICE_1_1,
            liquidity: liquidity,
            maxToken: type(uint256).max,
            maxQuote: 1e24
        });

        (token, hook) = launcher.deployAndLaunch(params);
        assertEq(address(hook), hookAddr, "hook deployed at mined address");
        assertEq(address(token), predictedToken, "token deployed at predicted address");

        (Currency c0, Currency c1) = address(token) < address(quote)
            ? (Currency.wrap(address(token)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TS, IHooks(address(hook)));
    }

    /// Full atomic launch: one transaction deploys token + hook, initialises the canonical dynamic-fee pool,
    /// seeds full-range liquidity; then the coin is directly tradable and the mandatory fee accrues solvently.
    function test_launch_atomic_tradable() public {
        (VolFeeToken token, VolFeeHook hook, PoolKey memory key) = _mineAndLaunch(1e24, 1e21);
        PoolId id = key.toId();

        // Hook bound to exactly the launched token + this pool.
        assertEq(Currency.unwrap(hook.tknCurrency()), address(token), "hook bound the launched token");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(id), "hook bound the launched pool");
        (,,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, INITIAL_LP_FEE, "base LP fee set at launch");
        assertGt(manager.getLiquidity(id), 0, "pool seeded with liquidity");

        // The coin is directly tradable: buy the token with quote, mandatory fee accrues, hook stays solvent.
        Currency quoteCurrency = Currency.wrap(address(quote));
        bool quoteIs0 = key.currency0 == quoteCurrency;
        // exact-input sell of the token (token specified) so the quote is unspecified (after-quadrant) -> no
        // precommit-partial-fill guard, plain executed-basis fee. The launch returned all unspent token supply
        // to this launch wallet, so we trade with that (the token is fixed-supply and cannot be minted).
        assertGt(token.balanceOf(address(this)), 1e18, "launch returned unspent token to the launch wallet");
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = !quoteIs0; // sell token (the non-quote side) for quote
        swapRouter.swap(
            key,
            SwapParams(zeroForOne, -int256(1e18), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 owed = hook.programmableFeeOwed(id, quoteCurrency) + hook.projectFeeOwed(id, quoteCurrency);
        assertGt(owed, 0, "mandatory fee accrued on the first trade");
        assertEq(manager.balanceOf(address(hook), quoteCurrency.toId()), owed, "hook 6909 solvency == owed");
    }

    /// The launch is single-use: a second deployAndLaunch reverts.
    function test_launch_single_use() public {
        _mineAndLaunch(1e24, 1e21);
        VolFeeLauncher.LaunchParams memory params;
        params.name = "X";
        params.symbol = "X";
        params.totalSupply = 1;
        params.tickSpacing = TS;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        vm.expectRevert(VolFeeLauncher.AlreadyLaunched.selector);
        launcher.deployAndLaunch(params);
    }

    /// Only the launch wallet can launch.
    function test_launch_only_wallet() public {
        VolFeeLauncher.LaunchParams memory params;
        params.tickSpacing = TS;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        vm.prank(address(0xBEEF));
        vm.expectRevert(VolFeeLauncher.NotLaunchWallet.selector);
        launcher.deployAndLaunch(params);
    }
}
