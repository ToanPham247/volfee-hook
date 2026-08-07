// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
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

/// @notice Executed-basis fee: a quote-SPECIFIED (before-quadrant) swap charges the fee in beforeSwap on the
///         requested amount, which is only correct on a full fill. A price-limited PARTIAL fill or a DUST swap
///         (fee consumes the whole input) reverts, so the fee can never overcharge the executed quote. The
///         after-quadrant (quote unspecified) charges on the executed BalanceDelta and handles partial fills.
contract VolFeePartialFillTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = 0x10cc;
    address constant PROJECT = 0x000000000000000000000000000000000000bEEF;
    uint24 constant DF = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 constant TS = 60;
    VolFeeHook hook;
    PoolKey pk;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address expectedToken = Currency.unwrap(currency1); // quote = currency0
        bytes memory args = abi.encode(address(manager), uint16(300), currency0, PROJECT, uint24(3000), uint16(3000), uint256(50), uint256(1), uint24(500), uint24(100000), expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        hook = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), 300, currency0, PROJECT, 3000, 3000, 50, 1, 500, 100000, expectedToken, SQRT_PRICE_1_1, TS);
        require(address(hook) == addr, "mine");
        pk = PoolKey(currency0, currency1, DF, TS, IHooks(address(hook)));
        manager.initialize(pk, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(pk, ModifyLiquidityParams(-887220, 887220, int256(1e21), 0), bytes(""));
    }

    function _swap(bool zeroForOne, int256 amt, uint160 lim) internal returns (BalanceDelta) {
        return swapRouter.swap(pk, SwapParams(zeroForOne, amt, lim), PoolSwapTest.TestSettings(false, false), bytes(""));
    }

    // ---- REVERTS: the fee cannot cleanly (executed-basis) charge these, so the whole swap reverts ----

    /// A quote-specified exact-OUTPUT swap that hits a tight price limit partial-fills; charging on `requested`
    /// would overcharge, so it reverts (v4 wraps the hook error, so we expect any revert).
    function test_beforeQuadrant_exactOutput_partialFill_reverts() public {
        uint160 tight = uint160((uint256(SQRT_PRICE_1_1) * 1001) / 1000); // ~0.1% above spot
        vm.expectRevert();
        _swap(false, int256(1e18), tight); // zeroForOne=false, amt>0 => currency0(quote) is the specified OUTPUT
    }

    /// A one-wei quote-specified exact-INPUT swap: the mandatory fee consumes the entire input, leaving no
    /// positive AMM leg (the reviewed dust defect) => reverts DustNoAmmLeg (wrapped).
    function test_beforeQuadrant_dust_exactInput_reverts() public {
        vm.expectRevert();
        _swap(true, -int256(1), MIN_PRICE_LIMIT); // zeroForOne=true exact-input => currency0(quote) specified
    }

    // ---- POSITIVE CONTROLS: normal swaps still work; the fee is on the executed quote ----

    /// A normal (full-fill) quote-specified exact-input swap succeeds and accrues the mandatory fee on the
    /// executed quote (== requested for a full fill).
    function test_beforeQuadrant_fullFill_ok_feeOnExecuted() public {
        uint256 before = hook.programmableFeeOwed(pk.toId(), currency0) + hook.projectFeeOwed(pk.toId(), currency0);
        _swap(true, -int256(1e18), MIN_PRICE_LIMIT);
        uint256 accrued = (hook.programmableFeeOwed(pk.toId(), currency0) + hook.projectFeeOwed(pk.toId(), currency0)) - before;
        // effective 3% of 1e18, ceil.
        assertEq(accrued, 30000000000000000, "full-fill fee = 3% of executed");
    }

    /// An after-quadrant (quote UNSPECIFIED) partial fill does NOT revert — the fee is read from the executed
    /// BalanceDelta, so it is executed-basis and partial-fill-safe.
    function test_afterQuadrant_partialFill_ok() public {
        // quote=currency0 UNSPECIFIED iff the token (currency1) is specified: a token-specified swap.
        // zeroForOne=false exact-INPUT (amt<0) => currency1(token) is specified, currency0(quote) unspecified.
        uint160 tight = uint160((uint256(SQRT_PRICE_1_1) * 1001) / 1000);
        _swap(false, -int256(5e17), tight); // must NOT revert
        // fee accrued on the executed quote output (> 0), no overcharge revert.
        uint256 accrued = hook.programmableFeeOwed(pk.toId(), currency0) + hook.projectFeeOwed(pk.toId(), currency0);
        assertGt(accrued, 0, "after-quadrant fee accrues on executed quote");
    }
}
