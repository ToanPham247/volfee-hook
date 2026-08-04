// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {VolMath} from "./lib/VolMath.sol";

/**
 * @title VolFeeHook
 * @notice Uniswap v4 hook implementing the mandatory Programmable volume-fee policy
 *         `programmable-volume-fee-v1` for the VolFee dynamic-fee pool.
 *
 * @dev FEE SUMMARY (see docs/ for the full spec):
 *
 *      RATES are in hundredths-of-a-bip: `1000 = 10 bps = 0.10%`.
 *        - `selected`  = total hook-owned swap charge = `feeTotalBps * 100`.
 *        - `effective` = `max(selected, 1000)`  (a 10 bps floor).
 *        - `platform`  = 1000 (exactly 10 bps) — accrued as an owner-only CLAIMABLE LIABILITY.
 *        - `project`   = `effective - 1000`     — accrued as a project-only CLAIMABLE LIABILITY.
 *      The split is NON-ADDITIVE: 3% never becomes 3.1%; the 10 bps platform is carved OUT of the
 *      total, so `platform + project == total` exactly.
 *
 *      BASIS is the executed GROSS quote-side swap volume, in the pool's quote asset, measured on
 *      the ACTUAL executed amount (post partial-fill), BEFORE deducting portions.
 *
 *      QUADRANT-DEPENDENT RETURN-DELTA COLLECTION (quote can be currency0 or currency1):
 *
 *        | quote asset | zeroForOne exactIn | zeroForOne exactOut | oneForZero exactIn | oneForZero exactOut |
 *        | currency0   | before             | after               | after              | before              |
 *        | currency1   | after              | before              | before             | after               |
 *
 *      "before" = collect via `beforeSwapReturnDelta` — quote is the SPECIFIED currency, its amount
 *                 is known pre-swap (`|amountSpecified|`).
 *      "after"  = collect via `afterSwap` return delta — quote is the UNSPECIFIED currency, its
 *                 executed amount is known post-swap (from the swap `BalanceDelta`).
 *      This whole table reduces to a single predicate: collect BEFORE iff the quote currency is the
 *      swap's specified currency, else collect AFTER. See {_beforeSwap}/{_afterSwap}.
 *
 *      OWNER + CUSTODY: the owner is the immutable constant {OWNER}. Both the platform liability and
 *      the project liability are held as this hook's ERC-6909 claim balances of the quote currency.
 *      Each liability is keyed by `(poolId, currency)` and is paid out only by their respective
 *      claim functions — owner-only for platform, project-only for project fee, to a selected
 *      destination per claim. There is no stored mutable recipient, and no cross-pool netting.
 *
 *      DYNAMIC-FEE POOL: This hook MUST be bound to a DYNAMIC-FEE pool (fee = 0x800000). The hook
 *      sets the initial LP fee via `poolManager.updateDynamicLPFee(key, INITIAL_LP_FEE)` in
 *      {_afterInitialize}. The LP fee auto-calibrates to realized volatility measured on-chain from
 *      tick movement between swaps (read-before/update-after manipulation resistance).
 *
 *      selfCallPolicy = same-pool-swap-forbidden: this hook NEVER initiates a swap on its own pool
 *      (it contains no `poolManager.swap` call). v4 additionally no-ops hook callbacks on self-calls
 *      (see `Hooks.beforeSwap`/`afterSwap`), and all hook entry points are `onlyPoolManager`.
 *
 *      ROUNDING is in the protocol's favor — fee amounts round UP (ceil). The swap is charged at
 *      least the nominal rate, never less, so the protocol (owner liability + project liability) is never
 *      under-collected. The 10 bps platform slice and the total both ceil with the SAME denominator,
 *      and `project = total - platform`, so `platform + project ≡ total`; the hook's realized
 *      ERC-6909 claim balance therefore always equals the recorded liabilities (solvent by
 *      construction), and `project == 0` exactly when `effective == 1000`.
 *
 *      Enabled callbacks (permission mask = 0x10cc): afterInitialize, beforeSwap, afterSwap,
 *      beforeSwapReturnDelta, afterSwapReturnDelta.
 */
contract VolFeeHook is BaseHook {
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /* ------------------------------------------------------------------ */
    /*                          Immutable config                          */
    /* ------------------------------------------------------------------ */

    /// @notice Immutable owner. Only this address may claim the platform liability. No setter exists.
    address public constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    /// @notice Immutable project address. Only this address may claim the project fee liability.
    address public immutable PROJECT;

    /// @dev Platform rate in hundredths-of-a-bip (1000 = 10 bps). The owner's fixed slice.
    uint256 internal constant PLATFORM_RATE = 1000;

    /// @dev Denominator for hundredths-of-a-bip rates: `amount * rate / 1_000_000`.
    uint256 internal constant RATE_DENOM = 1_000_000;

    /// @notice Total fee, in basis points, the hook is configured with (immutable ctor arg).
    uint16 public immutable feeTotalBps;

    /// @notice Effective total rate in hundredths-of-a-bip = max(feeTotalBps*100, 1000).
    uint256 public immutable effectiveRate;

    /// @notice The pool's quote asset. Fees are always measured and collected in this currency.
    Currency public immutable quoteCurrency;

    /// @notice Initial LP fee for the dynamic-fee pool (immutable ctor arg, must be <= 1_000_000).
    uint24 public immutable INITIAL_LP_FEE;

    /// @notice EWMA smoothing factor in basis points (0-10000).
    uint16 public immutable ALPHA_BPS;

    /// @notice Numerator of volatility multiplier for LP fee calculation.
    uint256 public immutable K_NUM;

    /// @notice Denominator of volatility multiplier for LP fee calculation.
    uint256 public immutable K_DEN;

    /// @notice Minimum LP fee in pips.
    uint24 public immutable MIN_LP_FEE;

    /// @notice Maximum LP fee in pips.
    uint24 public immutable MAX_LP_FEE;

    /* ------------------------------------------------------------------ */
    /*                          Bound-pool state                          */
    /* ------------------------------------------------------------------ */

    /// @notice The non-quote ("token") side of the bound canonical pool. Set in {_afterInitialize}.
    Currency public tknCurrency;

    /// @notice The bound canonical pool id. Set once in {_afterInitialize}.
    PoolId public poolId;

    /// @dev True once a canonical pool has been bound.
    bool private _bound;

    /// @notice Last observed tick from the pool. Updated in {_afterSwap}.
    int24 public lastTick;

    /// @notice EWMA of realized volatility (tick delta). Updated in {_afterSwap}.
    uint256 public ewmaVol;

    /* ------------------------------------------------------------------ */
    /*                        Liability mappings                          */
    /* ------------------------------------------------------------------ */

    /// @notice Owner-claimable platform liability (10 bps), pool- and currency-scoped. No netting.
    mapping(PoolId => mapping(Currency => uint256)) public programmableFeeOwed;

    /// @notice Project-claimable project fee liability (effective-1000), pool- and currency-scoped.
    mapping(PoolId => mapping(Currency => uint256)) public projectFeeOwed;

    /* ------------------------------------------------------------------ */
    /*                              Events                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Emitted whenever the mandatory fee is collected on a swap.
    event ProgrammableFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 platformAmount, uint256 projectAmount
    );

    /// @notice Emitted when the owner claims the platform liability to a chosen destination.
    event ProgrammableFeeClaimed(
        PoolId indexed poolId, Currency indexed currency, address indexed destination, uint256 amount
    );

    /// @notice Emitted when the project claims the project fee liability to a chosen destination.
    event ProjectFeeClaimed(
        PoolId indexed poolId, Currency indexed currency, address indexed destination, uint256 amount
    );

    /* ------------------------------------------------------------------ */
    /*                              Errors                                 */
    /* ------------------------------------------------------------------ */

    /// @dev The initialized pool does not contain {quoteCurrency}.
    error NotQuotePool();
    /// @dev A canonical pool is already bound to this hook.
    error PoolAlreadyBound();
    /// @dev Caller is not the immutable {OWNER}.
    error NotOwner();
    /// @dev Caller is not the immutable {PROJECT}.
    error NotProject();
    /// @dev Claim destination is the zero address.
    error InvalidDestination();
    /// @dev Project address is zero in constructor.
    error InvalidProject();
    /// @dev Initial LP fee is invalid (> 1_000_000 or outside [minLpFee, maxLpFee]).
    error BadInitialFee();
    /// @dev Pool is not a dynamic-fee pool.
    error NotDynamicFee();
    /// @dev Volatility parameters are invalid.
    error BadVolParams();

    /**
     * @param _pm The Uniswap v4 PoolManager singleton.
     * @param _feeTotalBps The configured total fee in basis points.
     * @param _quote The pool's quote currency (the asset fees are measured/collected in).
     * @param _project The project address that can claim the project fee portion.
     * @param _initialLpFee The initial LP fee to set on the dynamic-fee pool (must be in [minLpFee, maxLpFee]).
     * @param _alphaBps EWMA smoothing factor in basis points (0-10000).
     * @param _kNumerator Numerator of volatility multiplier.
     * @param _kDenominator Denominator of volatility multiplier (must be > 0).
     * @param _minLpFee Minimum LP fee in pips.
     * @param _maxLpFee Maximum LP fee in pips.
     */
    constructor(
        IPoolManager _pm,
        uint16 _feeTotalBps,
        Currency _quote,
        address _project,
        uint24 _initialLpFee,
        uint16 _alphaBps,
        uint256 _kNumerator,
        uint256 _kDenominator,
        uint24 _minLpFee,
        uint24 _maxLpFee
    ) BaseHook(_pm) {
        if (_project == address(0)) revert InvalidProject();
        if (_kDenominator == 0) revert BadVolParams();
        if (_alphaBps > 10000) revert BadVolParams();
        if (_minLpFee > _maxLpFee || _maxLpFee > 1_000_000) revert BadVolParams();
        if (_initialLpFee < _minLpFee || _initialLpFee > _maxLpFee) revert BadInitialFee();

        feeTotalBps = _feeTotalBps;
        uint256 selected = uint256(_feeTotalBps) * 100;
        effectiveRate = selected < PLATFORM_RATE ? PLATFORM_RATE : selected;
        quoteCurrency = _quote;
        PROJECT = _project;
        INITIAL_LP_FEE = _initialLpFee;
        ALPHA_BPS = _alphaBps;
        K_NUM = _kNumerator;
        K_DEN = _kDenominator;
        MIN_LP_FEE = _minLpFee;
        MAX_LP_FEE = _maxLpFee;
    }

    /* ------------------------------------------------------------------ */
    /*                            Permissions                             */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* ------------------------------------------------------------------ */
    /*                           Initialize                               */
    /* ------------------------------------------------------------------ */

    /**
     * @dev Binds the hook to its canonical pool. The pool MUST contain {quoteCurrency}; the other
     *      side is stored as {tknCurrency}. Binding happens exactly once — the `_bound` guard reverts
     *      {PoolAlreadyBound} on any second init.
     *
     *      REQUIRES: the pool must be a DYNAMIC-FEE pool (fee = 0x800000). Sets the initial LP fee
     *      via `poolManager.updateDynamicLPFee(key, INITIAL_LP_FEE)`. Initializes lastTick and ewmaVol.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        Currency q = quoteCurrency;
        if (!(key.currency0 == q) && !(key.currency1 == q)) revert NotQuotePool();
        if (_bound) revert PoolAlreadyBound();
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFee();

        _bound = true;
        Currency t = key.currency0 == q ? key.currency1 : key.currency0;
        tknCurrency = t;
        poolId = key.toId();

        // Set the initial LP fee on the dynamic-fee pool.
        poolManager.updateDynamicLPFee(key, INITIAL_LP_FEE);

        // Initialize volatility tracking state.
        lastTick = tick;
        ewmaVol = 0;

        return IHooks.afterInitialize.selector;
    }

    /* ------------------------------------------------------------------ */
    /*                        Swap fee collection                         */
    /* ------------------------------------------------------------------ */

    /**
     * @dev BEFORE-quadrant collection: when the quote currency is the swap's SPECIFIED currency, its
     *      amount is known pre-swap (`|amountSpecified|`). We mint the total charge as quote ERC-6909
     *      claims and return it as a positive `beforeSwapReturnDelta` on the specified currency; v4
     *      then carves it out of the swap (exact-input: less is swapped; exact-output: extra is
     *      produced for the hook). AFTER-quadrant swaps are handled in {_afterSwap}.
     *
     *      LP FEE OVERRIDE: Returns the computed LP fee from current ewmaVol (before this swap's update)
     *      with OVERRIDE_FEE_FLAG. This ensures the swap's own tick movement cannot affect its own fee.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Compute LP fee from CURRENT ewmaVol (reflects only prior swaps) - manipulation resistant
        uint24 lpFee = VolMath.feeFromVol(ewmaVol, INITIAL_LP_FEE, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE);

        // collect BEFORE iff the quote currency is the specified currency of this swap
        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool quoteIsSpecified = (key.currency0 == quoteCurrency) == specifiedTokenIs0;
        if (!quoteIsSpecified) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        uint256 grossQuote =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 total = _collect(key.toId(), grossQuote);

        // Positive specified delta => hook is credited `total` of the (quote) specified currency.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(total.toInt128(), int128(0)), lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /**
     * @dev AFTER-quadrant fee collection. When the quote currency is the swap's UNSPECIFIED currency
     *      its executed amount is only known post-swap. We read the ACTUAL executed quote from the swap
     *      `BalanceDelta`, mint the total charge as quote ERC-6909 claims, and hold it as a positive
     *      `afterSwap` delta (`feeDelta`) on the unspecified (quote) currency. BEFORE-quadrant swaps
     *      were already collected in {_beforeSwap} (`feeDelta == 0` here). The fee basis is ALWAYS the
     *      executed quote volume.
     *
     *      VOLATILITY UPDATE: After fee collection, update ewmaVol and lastTick from THIS swap's tick move.
     *      This update only affects FUTURE swaps (manipulation resistance).
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Quote is the UNSPECIFIED (after-quadrant) currency iff isQuote0 != specifiedTokenIs0.
        // Scoped so the intermediate booleans don't stay live across the rest of the frame.
        bool quoteIsUnspecified;
        {
            bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
            quoteIsUnspecified = (key.currency0 == quoteCurrency) != specifiedTokenIs0;
        }

        // ---- Fee (after-quadrant only; before-quadrant already collected in _beforeSwap) ----
        int128 feeDelta = 0;
        if (quoteIsUnspecified) {
            int128 quoteDelta = (key.currency0 == quoteCurrency) ? delta.amount0() : delta.amount1();
            uint256 grossQuote = quoteDelta < 0 ? uint256(int256(-quoteDelta)) : uint256(int256(quoteDelta));
            feeDelta = _collect(poolId, grossQuote).toInt128();
        }

        // ---- Volatility state update (after fee collection, affects only FUTURE swaps) ----
        (, int24 curTick,,) = poolManager.getSlot0(poolId);
        uint256 sample = VolMath.absTickDelta(curTick, lastTick);
        ewmaVol = VolMath.ewmaUpdate(ewmaVol, sample, ALPHA_BPS);
        lastTick = curTick;

        return (IHooks.afterSwap.selector, feeDelta);
    }

    /**
     * @dev Takes the whole hook-owned charge as quote ERC-6909 claims and records the split:
     *      the fixed 10 bps platform slice into the owner-claimable liability, the remainder into the
     *      project-claimable liability. Returns `total` for the caller to return as its (before/after) swap delta.
     */
    function _collect(PoolId id, uint256 grossQuote) internal returns (uint256 total) {
        uint256 platform;
        uint256 project;
        (total, platform, project) = _quoteFee(grossQuote);
        if (total == 0) return 0;

        // Mint `total` of the quote currency to this hook as ERC-6909 claims (offsets the swap delta).
        quoteCurrency.take(poolManager, address(this), total, true);

        programmableFeeOwed[id][quoteCurrency] += platform;
        projectFeeOwed[id][quoteCurrency] += project;
        emit ProgrammableFeeCollected(id, quoteCurrency, platform, project);
    }

    /* ------------------------------------------------------------------ */
    /*                          Owner claim                               */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Owner-only. Pays `destination` the platform liability owed for `(poolId, currency)`
     *         from this hook's ERC-6909 quote claims, and zeroes the liability.
     * @dev The destination is chosen per call; there is no stored mutable recipient. Only {OWNER}
     *      may call. The project liability is never touched here.
     */
    function claimProgrammableFee(PoolId _poolId, Currency currency, address destination) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (destination == address(0)) revert InvalidDestination();

        uint256 amount = programmableFeeOwed[_poolId][currency];
        programmableFeeOwed[_poolId][currency] = 0;

        if (amount > 0) {
            // Unlock the PoolManager so we can burn the hook's ERC-6909 claims and pay out the underlying.
            poolManager.unlock(abi.encode(currency, destination, amount));
        }
        emit ProgrammableFeeClaimed(_poolId, currency, destination, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                         Project claim                              */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Project-only. Pays `destination` the project fee liability owed for `(poolId, currency)`
     *         from this hook's ERC-6909 quote claims, and zeroes the liability.
     * @dev The destination is chosen per call; there is no stored mutable recipient. Only {PROJECT}
     *      may call. The platform liability is never touched here.
     */
    function claimProjectFee(PoolId _poolId, Currency currency, address destination) external {
        if (msg.sender != PROJECT) revert NotProject();
        if (destination == address(0)) revert InvalidDestination();

        uint256 amount = projectFeeOwed[_poolId][currency];
        projectFeeOwed[_poolId][currency] = 0;

        if (amount > 0) {
            // Unlock the PoolManager so we can burn the hook's ERC-6909 claims and pay out the underlying.
            poolManager.unlock(abi.encode(currency, destination, amount));
        }
        emit ProjectFeeClaimed(_poolId, currency, destination, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                      PoolManager callback                          */
    /* ------------------------------------------------------------------ */

    /**
     * @dev PoolManager unlock callback used by {claimProgrammableFee} and {claimProjectFee} to burn
     *      the hook's ERC-6909 claims and pay out the underlying tokens to the destination.
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address destination, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        currency.settle(poolManager, address(this), amount, true); // burn ERC-6909 -> +amount hook delta
        currency.take(poolManager, destination, amount, false); //     ERC-20 out -> -amount hook delta (nets to 0)
        return bytes("");
    }

    /* ------------------------------------------------------------------ */
    /*                          Fee math                                  */
    /* ------------------------------------------------------------------ */

    /**
     * @dev Splits a gross quote amount into the total hook charge and its platform/project portions.
     *      All amounts ceil (protocol favor). `project = total - platform` keeps the split exact.
     */
    function _quoteFee(uint256 grossQuote)
        internal
        view
        returns (uint256 total, uint256 platform, uint256 project)
    {
        total = _ceilDiv(grossQuote * effectiveRate, RATE_DENOM);
        platform = _ceilDiv(grossQuote * PLATFORM_RATE, RATE_DENOM);
        project = total - platform; // effective >= PLATFORM_RATE => total >= platform (ceil is monotonic)
    }

    /// @dev Ceil division: ceil(a / b). Returns 0 when a == 0.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /* ------------------------------------------------------------------ */
    /*                      View functions                                */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Preview the current LP fee based on accumulated volatility.
     * @return The LP fee in pips that would be charged on the next swap.
     */
    function previewLpFee() external view returns (uint24) {
        return VolMath.feeFromVol(ewmaVol, INITIAL_LP_FEE, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE);
    }
}
