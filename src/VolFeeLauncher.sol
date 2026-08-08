// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VolFeeHook} from "./VolFeeHook.sol";
import {VolFeeToken} from "./VolFeeToken.sol";

/// @title VolFeeLauncher
/// @notice Deploys the token and the VolFee hook, initialises the canonical dynamic-fee pool and seeds its
///         initial full-range liquidity in one transaction. Any mismatch reverts the whole launch.
/// @dev The hook is deployed with the token address, start price and tick spacing PRECOMMITTED into its
///      immutables, so {VolFeeHook._afterInitialize} binds only this exact pool (first-pool capture is
///      impossible). The launcher permanently owns the seeded full-range position: it exposes no decrease,
///      collect, rescue, arbitrary-call, owner or upgrade path, so the seeded liquidity can never be removed
///      through project code. It is single-use and holds no funds after the launch returns. The mandatory
///      Programmable volume fee, the LP-fee owner and the volatility curve are fixed constants below — the
///      launcher cannot deploy a hook that charges more, mutates its owner, or bypasses the volume fee.
contract VolFeeLauncher is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @dev Canonical VolFee configuration. Fixed so every pool this launcher creates is identical and the
    ///      hook deployment is fully deterministic from the launch parameters below.
    uint16 internal constant FEE_TOTAL_BPS = 300; // 3% total volume fee (10 bps platform + remainder project)
    uint24 internal constant INITIAL_LP_FEE = 3000; // 0.30% starting LP fee
    uint16 internal constant ALPHA_BPS = 3000; // EWMA smoothing factor
    uint256 internal constant K_NUM = 50; // volatility -> fee slope numerator
    uint256 internal constant K_DEN = 1; // volatility -> fee slope denominator
    uint24 internal constant MIN_LP_FEE = 500; // 0.05% floor
    uint24 internal constant MAX_LP_FEE = 100000; // 10% cap

    struct LaunchParams {
        string name;
        string symbol;
        uint256 totalSupply;
        bytes32 tokenSalt;
        bytes32 hookSalt;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 maxToken;
        uint256 maxQuote;
    }

    IPoolManager public immutable poolManager;
    IERC20 public immutable quote;

    /// @notice The wallet that authorises the launch, pays the quote-side liquidity, and receives the
    ///         project fee liability (it is passed as the hook's immutable project beneficiary).
    address public immutable launchWallet;

    VolFeeToken public token;
    VolFeeHook public hook;
    bool public launched;

    event Launched(address indexed token, address indexed hook, bytes32 poolId, uint128 liquidity);

    error NotLaunchWallet();
    error AlreadyLaunched();
    error NotPoolManager();
    error QuoteExceeded();
    error TokenExceeded();
    error UnexpectedDelta();
    error ZeroLaunchWallet();
    error SettlementMismatch();

    constructor(IPoolManager _poolManager, IERC20 _quote, address _launchWallet) {
        if (_launchWallet == address(0)) revert ZeroLaunchWallet();
        poolManager = _poolManager;
        quote = _quote;
        launchWallet = _launchWallet;
    }

    /// @notice Runs the complete launch. Callable once, by the launch wallet only.
    function deployAndLaunch(LaunchParams calldata params) external returns (VolFeeToken, VolFeeHook) {
        if (msg.sender != launchWallet) revert NotLaunchWallet();
        if (launched) revert AlreadyLaunched();
        launched = true;

        VolFeeToken newToken =
            new VolFeeToken{salt: params.tokenSalt}(params.name, params.symbol, params.totalSupply, address(this));

        (Currency currency0, Currency currency1) = address(newToken) < address(quote)
            ? (Currency.wrap(address(newToken)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(newToken)));

        // The hook's constructor validates that its own mined address carries exactly the declared permission
        // bits (BaseHook) AND precommits the exact (token, start price, tick spacing), so a wrong salt or a
        // mismatched pool reverts here instead of producing a mis-permissioned or capturable pool.
        VolFeeHook newHook = new VolFeeHook{salt: params.hookSalt}(
            poolManager,
            FEE_TOTAL_BPS,
            Currency.wrap(address(quote)),
            launchWallet,
            INITIAL_LP_FEE,
            ALPHA_BPS,
            K_NUM,
            K_DEN,
            MIN_LP_FEE,
            MAX_LP_FEE,
            address(newToken),
            params.sqrtPriceX96,
            params.tickSpacing
        );

        token = newToken;
        hook = newHook;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: params.tickSpacing,
            hooks: newHook
        });

        // afterInitialize binds the hook to exactly this pool and reverts on any token/price/spacing mismatch.
        poolManager.initialize(key, params.sqrtPriceX96);

        // msg.sender is the launch wallet: the check at the top of this function is the only way in.
        quote.safeTransferFrom(msg.sender, address(this), params.maxQuote);

        poolManager.unlock(abi.encode(key, params));

        // Return every unspent unit; the launcher deliberately keeps no balance of its own.
        uint256 quoteLeft = quote.balanceOf(address(this));
        if (quoteLeft != 0) quote.safeTransfer(launchWallet, quoteLeft);
        uint256 tokenLeft = newToken.balanceOf(address(this));
        if (tokenLeft != 0) IERC20(address(newToken)).safeTransfer(launchWallet, tokenLeft);

        emit Launched(address(newToken), address(newHook), PoolId.unwrap(key.toId()), params.liquidity);
        return (newToken, newHook);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (PoolKey memory key, LaunchParams memory params) = abi.decode(data, (PoolKey, LaunchParams));

        int24 lower = TickMath.minUsableTick(params.tickSpacing);
        int24 upper = TickMath.maxUsableTick(params.tickSpacing);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(params.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Seeding liquidity only ever OWES currency to the pool; a positive delta would mean the pool paid the
        // launcher, which must never happen on an initial add.
        if (delta.amount0() > 0 || delta.amount1() > 0) revert UnexpectedDelta();

        uint256 owed0 = uint256(uint128(-delta.amount0()));
        uint256 owed1 = uint256(uint128(-delta.amount1()));

        bool quoteIsCurrency1 = Currency.unwrap(key.currency1) == address(quote);
        (uint256 owedQuote, uint256 owedToken) = quoteIsCurrency1 ? (owed1, owed0) : (owed0, owed1);
        if (owedQuote > params.maxQuote) revert QuoteExceeded();
        if (owedToken > params.maxToken) revert TokenExceeded();

        if (owed0 != 0) _settle(key.currency0, owed0);
        if (owed1 != 0) _settle(key.currency1, owed1);

        return "";
    }

    function _settle(Currency currency, uint256 amount) private {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount) revert SettlementMismatch();
    }
}
