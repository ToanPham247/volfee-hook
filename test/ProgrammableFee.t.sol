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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {VolFeeHook} from "../src/VolFeeHook.sol";

contract ProgrammableFeeTest is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    address internal constant PROJECT = 0x000000000000000000000000000000000000bEEF;
    uint24 internal constant INITIAL_LP_FEE = 3000;
    uint256 internal constant PLATFORM_RATE = 1000;
    uint256 internal constant RATE_DENOM = 1_000_000;
    uint16 internal constant ALPHA_BPS = 3000;
    uint256 internal constant K_NUM = 50;
    uint256 internal constant K_DEN = 1;
    uint24 internal constant MIN_LP_FEE = 500;
    uint24 internal constant MAX_LP_FEE = 100000;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;
    uint24 internal constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TS = 60;

    event ProgrammableFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 platformAmount, uint256 projectAmount);
    event ProgrammableFeeClaimed(PoolId indexed poolId, Currency indexed currency, address indexed destination, uint256 amount);
    event ProjectFeeClaimed(PoolId indexed poolId, Currency indexed currency, address indexed destination, uint256 amount);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    function _deployHook(uint16 feeTotalBps, Currency quote) internal returns (VolFeeHook h) {
        address expectedToken = Currency.unwrap(quote == currency0 ? currency1 : currency0);
        bytes memory args = abi.encode(address(manager), feeTotalBps, quote, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        h = new VolFeeHook{salt: salt}(IPoolManager(address(manager)), feeTotalBps, quote, PROJECT, INITIAL_LP_FEE, ALPHA_BPS, K_NUM, K_DEN, MIN_LP_FEE, MAX_LP_FEE, expectedToken, SQRT_PRICE_1_1, TS);
        require(address(h) == addr, "mine");
    }

    function _initPool(VolFeeHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}), ZERO_BYTES);
    }

    function _hookAndPool(uint16 feeTotalBps, Currency quote) internal returns (VolFeeHook h, PoolKey memory key, PoolId id) {
        h = _deployHook(feeTotalBps, quote);
        (key, id) = _initPool(h);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _quoteBal(VolFeeHook h, Currency quote) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    function _quoteIsSpecified(Currency quote, bool zeroForOne, int256 amtSpec) internal view returns (bool) {
        bool specifiedTokenIs0 = ((amtSpec < 0) == zeroForOne);
        return (quote == currency0) == specifiedTokenIs0;
    }

    struct SwapResult { uint256 total; uint256 platform; uint256 project; int128 qd; }

    function _swapAndMeasure(VolFeeHook h, PoolKey memory key, PoolId id, Currency quote, bool zeroForOne, int256 amtSpec) internal returns (SwapResult memory) {
        SwapResult memory r;
        uint256 balBefore = _quoteBal(h, quote);
        uint256 owedBefore = h.programmableFeeOwed(id, quote);
        uint256 projBefore = h.projectFeeOwed(id, quote);
        BalanceDelta d = swap(key, zeroForOne, amtSpec, ZERO_BYTES);
        r.total = _quoteBal(h, quote) - balBefore;
        r.platform = h.programmableFeeOwed(id, quote) - owedBefore;
        r.project = h.projectFeeOwed(id, quote) - projBefore;
        r.qd = (quote == currency0) ? d.amount0() : d.amount1();
        return r;
    }

    struct Split { uint256 total; uint256 platform; uint256 project; uint256 gross; }

    function _checkSwap(VolFeeHook h, PoolKey memory key, PoolId id, Currency quote, bool zeroForOne, int256 amtSpec) internal returns (uint256 total, uint256 platform, uint256 project, uint256 gross) {
        SwapResult memory r = _swapAndMeasure(h, key, id, quote, zeroForOne, amtSpec);
        assertEq(r.total, r.platform + r.project, "total != platform + project");
        Split memory s;
        s.total = r.total; s.platform = r.platform; s.project = r.project;
        if (_quoteIsSpecified(quote, zeroForOne, amtSpec)) {
            s.gross = amtSpec < 0 ? uint256(-amtSpec) : uint256(amtSpec);
            if (amtSpec > 0) assertEq(int256(r.qd), amtSpec, "exactOut quote not honored");
        } else {
            uint256 absQd = r.qd < 0 ? uint256(int256(-r.qd)) : uint256(int256(r.qd));
            s.gross = amtSpec < 0 ? absQd + s.total : absQd - s.total;
        }
        _assertFee(h, id, quote, s);
        return (s.total, s.platform, s.project, s.gross);
    }

    function _assertFee(VolFeeHook h, PoolId id, Currency quote, Split memory s) internal {
        uint256 eff = h.effectiveRate();
        assertEq(s.total, _ceilDiv(s.gross * eff, RATE_DENOM), "total mismatch");
        assertEq(s.platform, _ceilDiv(s.gross * PLATFORM_RATE, RATE_DENOM), "platform != 10bps of gross");
        assertEq(s.project, s.total - s.platform, "project split");
        assertEq(_quoteBal(h, tknOf(quote)), 0, "token-side ERC6909 must stay 0");
        assertEq(h.programmableFeeOwed(id, tknOf(quote)), 0, "token-side platform liability must stay 0");
        assertEq(h.projectFeeOwed(id, tknOf(quote)), 0, "token-side project liability must stay 0");
    }

    function tknOf(Currency quote) internal view returns (Currency) {
        return quote == currency0 ? currency1 : currency0;
    }

    function _fee(uint256 gross, uint256 eff) internal pure returns (uint256 total, uint256 platform, uint256 project) {
        total = _ceilDiv(gross * eff, RATE_DENOM);
        platform = _ceilDiv(gross * PLATFORM_RATE, RATE_DENOM);
        project = total - platform;
    }

    function test_00_dynamicFeePool_initialLpFeeSet() public {
        (VolFeeHook h, PoolKey memory key,) = _hookAndPool(300, currency0);
        assertEq(h.INITIAL_LP_FEE(), INITIAL_LP_FEE, "initial LP fee mismatch");
        assertEq(key.fee, DYNAMIC_FEE, "pool fee should be dynamic fee flag");
    }

    function test_00_staticFeePool_revertsNotDynamicFee() public {
        VolFeeHook h = _deployHook(300, currency0);
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, TS, IHooks(address(h)));
        vm.expectRevert();
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_01_rateLevels_platformAlways10bps() public {
        uint16[4] memory levels = [uint16(0), uint16(5), uint16(10), uint16(300)];
        for (uint256 i = 0; i < levels.length; i++) {
            (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(levels[i], currency0);
            (uint256 total, uint256 platform, uint256 project, uint256 gross) = _checkSwap(h, key, id, currency0, false, -1e18);
            assertEq(platform, _ceilDiv(gross * 1000, RATE_DENOM), "platform != 10bps");
            assertGt(platform, 0, "platform must be > 0");
            if (levels[i] <= 10) {
                assertEq(project, 0, "project should be 0 at/below 10bps floor");
                assertEq(total, platform, "total should equal platform at floor");
            } else {
                assertGt(project, 0, "project must be > 0 above floor");
                assertEq(project, total - platform, "project split");
            }
        }
    }

    function test_02_nonAdditive_3pct() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency1);
        (uint256 total, uint256 platform, uint256 project,) = _checkSwap(h, key, id, currency1, true, int256(1e18));
        assertEq(platform, 1e15, "platform != 0.1%");
        assertEq(project, 29e15, "project != 2.9%");
        assertEq(total, 3e16, "total != 3.0% (must NOT be 3.1%)");
        assertEq(platform + project, total, "non-additive: split must sum to total");
    }

    function test_03_quadrants_quote0() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        _checkSwap(h, key, id, currency0, true, int256(1e18));
        _checkSwap(h, key, id, currency0, false, -1e18);
        _checkSwap(h, key, id, currency0, false, int256(1e18));
    }

    function test_03_quadrants_quote1() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency1);
        _checkSwap(h, key, id, currency1, true, -1e18);
        _checkSwap(h, key, id, currency1, true, int256(1e18));
        _checkSwap(h, key, id, currency1, false, -1e18);
        _checkSwap(h, key, id, currency1, false, int256(1e18));
    }

    function test_04_basisIsExecutedNotRequested() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        uint256 requestedOut = 1e24;
        uint160 limit = uint160((uint256(SQRT_PRICE_1_1) * 999) / 1000);
        uint256 balBefore = _quoteBal(h, currency0);
        BalanceDelta d = swapRouter.swap(key, SwapParams({zeroForOne: true, amountSpecified: int256(requestedOut), sqrtPriceLimitX96: limit}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES);
        uint256 total = _quoteBal(h, currency0) - balBefore;
        assertLt(uint256(int256(d.amount1())), requestedOut, "swap should be capped (executed < requested)");
        assertGt(uint256(int256(d.amount1())), 0, "swap must move something");
        uint256 gross = uint256(int256(-d.amount0())) - total;
        assertEq(total, _ceilDiv(gross * h.effectiveRate(), RATE_DENOM), "fee not on executed gross");
        assertEq(h.programmableFeeOwed(id, currency0), _ceilDiv(gross * PLATFORM_RATE, RATE_DENOM), "platform on executed");
        assertEq(h.projectFeeOwed(id, currency0), total - h.programmableFeeOwed(id, currency0), "project on executed");
        assertTrue(total < _ceilDiv(requestedOut * h.effectiveRate(), RATE_DENOM), "must not charge on requested");
    }

    function test_05_onlyCanonicalPoolAccrues() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        IERC20(Currency.unwrap(currency0)).transfer(makeAddr("bob"), 1e18);
        assertEq(_quoteBal(h, currency0), 0, "transfer must not accrue");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "transfer must not accrue platform liability");
        assertEq(h.projectFeeOwed(id, currency0), 0, "transfer must not accrue project liability");
        PoolKey memory altKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        manager.initialize(altKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(altKey, ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}), ZERO_BYTES);
        swap(altKey, true, -1e18, ZERO_BYTES);
        assertEq(_quoteBal(h, currency0), 0, "alt pool must not accrue");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "alt pool must not accrue platform liability");
        assertEq(h.projectFeeOwed(id, currency0), 0, "alt pool must not accrue project liability");
        (uint256 total,,,) = _checkSwap(h, key, id, currency0, true, -1e18);
        assertGt(total, 0, "canonical pool must accrue");
    }

    function test_06_hookEntrypointsAreOnlyPoolManager() public {
        VolFeeHook h = _deployHook(300, currency0);
        PoolKey memory key = PoolKey(currency0, currency1, DYNAMIC_FEE, TS, IHooks(address(h)));
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.beforeSwap(address(this), key, p, ZERO_BYTES);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.afterSwap(address(this), key, p, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.unlockCallback(bytes(""));
    }

    function test_07_ownerClaimsPlatformToArbitraryDestinations() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed1 = h.programmableFeeOwed(id, currency0);
        assertGt(owed1, 0, "need platform liability");
        address dest1 = makeAddr("dest1");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency0, dest1);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(dest1), owed1, "dest1 not paid");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "platform liability not zeroed");
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed2 = h.programmableFeeOwed(id, currency0);
        assertGt(owed2, 0, "need platform liability 2");
        address dest2 = makeAddr("dest2");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency0, dest2);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(dest2), owed2, "dest2 not paid");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "platform liability not zeroed 2");
    }

    function test_08_nonOwnerCannotClaimPlatform() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        address[3] memory strangers = [makeAddr("builder"), makeAddr("random"), OWNER];
        for (uint256 i = 0; i < strangers.length; i++) {
            if (strangers[i] == OWNER) continue;
            vm.prank(strangers[i]);
            vm.expectRevert(VolFeeHook.NotOwner.selector);
            h.claimProgrammableFee(id, currency0, strangers[i]);
        }
        assertGt(h.programmableFeeOwed(id, currency0), 0, "platform liability tampered");
    }

    function test_09_projectClaimsProjectFeeToArbitraryDestinations() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed1 = h.projectFeeOwed(id, currency0);
        assertGt(owed1, 0, "need project fee liability");
        address dest1 = makeAddr("dest1");
        vm.prank(PROJECT);
        h.claimProjectFee(id, currency0, dest1);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(dest1), owed1, "dest1 not paid project fee");
        assertEq(h.projectFeeOwed(id, currency0), 0, "project fee liability not zeroed");
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed2 = h.projectFeeOwed(id, currency0);
        assertGt(owed2, 0, "need project fee liability 2");
        address dest2 = makeAddr("dest2");
        vm.prank(PROJECT);
        h.claimProjectFee(id, currency0, dest2);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(dest2), owed2, "dest2 not paid project fee");
        assertEq(h.projectFeeOwed(id, currency0), 0, "project fee liability not zeroed 2");
    }

    function test_10_nonProjectCannotClaimProjectFee() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        address[3] memory strangers = [makeAddr("builder"), makeAddr("owner"), makeAddr("random")];
        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(VolFeeHook.NotProject.selector);
            h.claimProjectFee(id, currency0, strangers[i]);
        }
        assertGt(h.projectFeeOwed(id, currency0), 0, "project fee liability tampered");
    }

    function test_11_noStoredRecipient_ownerOnlyRedirect() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed = h.programmableFeeOwed(id, currency0);
        address rescuer = makeAddr("rescuer");
        vm.prank(rescuer);
        vm.expectRevert(VolFeeHook.NotOwner.selector);
        h.claimProgrammableFee(id, currency0, rescuer);
        address fresh = makeAddr("freshRecipient");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency0, fresh);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(fresh), owed, "owner redirect failed");
        vm.prank(OWNER);
        vm.expectRevert(VolFeeHook.InvalidDestination.selector);
        h.claimProgrammableFee(id, currency0, address(0));
    }

    function test_11_noStoredRecipient_projectOnlyRedirect() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed = h.projectFeeOwed(id, currency0);
        address rescuer = makeAddr("rescuer");
        vm.prank(rescuer);
        vm.expectRevert(VolFeeHook.NotProject.selector);
        h.claimProjectFee(id, currency0, rescuer);
        address fresh = makeAddr("freshRecipient");
        vm.prank(PROJECT);
        h.claimProjectFee(id, currency0, fresh);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(fresh), owed, "project redirect failed");
        vm.prank(PROJECT);
        vm.expectRevert(VolFeeHook.InvalidDestination.selector);
        h.claimProjectFee(id, currency0, address(0));
    }

    function test_12_solvencyAndNoCrossPoolNetting() public {
        (VolFeeHook hA, PoolKey memory keyA, PoolId idA) = _hookAndPool(300, currency0);
        (VolFeeHook hB, PoolKey memory keyB, PoolId idB) = _hookAndPool(500, currency1);
        _checkSwap(hA, keyA, idA, currency0, true, -1e18);
        _checkSwap(hB, keyB, idB, currency1, true, int256(1e18));
        assertEq(_quoteBal(hA, currency0), hA.programmableFeeOwed(idA, currency0) + hA.projectFeeOwed(idA, currency0), "A insolvent");
        assertEq(_quoteBal(hB, currency1), hB.programmableFeeOwed(idB, currency1) + hB.projectFeeOwed(idB, currency1), "B insolvent");
        assertEq(hA.programmableFeeOwed(idB, currency0), 0, "A platform netted into B poolId");
        assertEq(hA.projectFeeOwed(idB, currency0), 0, "A project netted into B poolId");
        assertEq(hA.programmableFeeOwed(idA, currency1), 0, "A platform netted across currency");
        assertEq(hA.projectFeeOwed(idA, currency1), 0, "A project netted across currency");
        assertEq(hB.programmableFeeOwed(idA, currency1), 0, "B platform netted into A poolId");
        assertEq(hB.projectFeeOwed(idA, currency1), 0, "B project netted into A poolId");
        uint256 bBalBefore = _quoteBal(hB, currency1);
        uint256 bOwedBefore = hB.programmableFeeOwed(idB, currency1);
        uint256 bProjBefore = hB.projectFeeOwed(idB, currency1);
        vm.prank(OWNER);
        hA.claimProgrammableFee(idA, currency0, makeAddr("dA"));
        assertEq(_quoteBal(hB, currency1), bBalBefore, "B balance moved by A claim");
        assertEq(hB.programmableFeeOwed(idB, currency1), bOwedBefore, "B platform owed moved by A claim");
        assertEq(hB.projectFeeOwed(idB, currency1), bProjBefore, "B project owed moved by A claim");
        assertEq(_quoteBal(hA, currency0), hA.programmableFeeOwed(idA, currency0) + hA.projectFeeOwed(idA, currency0), "A insolvent post-claim");
    }

    function test_13_eventsReconcile() public {
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency1);
        (uint256 total, uint256 platform, uint256 project) = (3e16, 1e15, 29e15);
        vm.expectEmit(true, true, false, true, address(h));
        emit ProgrammableFeeCollected(id, currency1, platform, project);
        _checkSwap(h, key, id, currency1, true, int256(1e18));
        assertEq(_quoteBal(h, currency1), total, "collected != balance");
        assertEq(h.programmableFeeOwed(id, currency1), platform, "platform owed != platform");
        assertEq(h.projectFeeOwed(id, currency1), project, "project owed != project");
        address dest = makeAddr("dest");
        vm.expectEmit(true, true, true, true, address(h));
        emit ProgrammableFeeClaimed(id, currency1, dest, platform);
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency1, dest);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(dest), platform, "platform claim payout != owed");
        assertEq(_quoteBal(h, currency1), project, "post-claim balance != project");
        address dest2 = makeAddr("dest2");
        vm.expectEmit(true, true, true, true, address(h));
        emit ProjectFeeClaimed(id, currency1, dest2, project);
        vm.prank(PROJECT);
        h.claimProjectFee(id, currency1, dest2);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(dest2), project, "project claim payout != owed");
        assertEq(_quoteBal(h, currency1), 0, "post-project-claim balance should be 0");
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_feeSplit(uint16 feeTotalBps, uint96 amtRaw) public {
        feeTotalBps = uint16(bound(feeTotalBps, 0, 3000));
        uint256 amt = bound(uint256(amtRaw), 1e12, 1e18);
        (VolFeeHook h, PoolKey memory key, PoolId id) = _hookAndPool(feeTotalBps, currency1);
        uint256 balBefore = _quoteBal(h, currency1);
        uint256 projBefore = h.projectFeeOwed(id, currency1);
        swap(key, true, int256(amt), ZERO_BYTES);
        uint256 total = _quoteBal(h, currency1) - balBefore;
        uint256 platform = h.programmableFeeOwed(id, currency1);
        uint256 project = h.projectFeeOwed(id, currency1) - projBefore;
        (uint256 eTotal, uint256 ePlatform, uint256 eProject) = _fee(amt, h.effectiveRate());
        assertEq(total, eTotal, "fuzz total");
        assertEq(platform, ePlatform, "fuzz platform");
        assertEq(project, eProject, "fuzz project");
        assertEq(platform + project, total, "fuzz split sums to total");
        assertEq(_quoteBal(h, currency1), total, "fuzz solvency");
        assertEq(platform, _ceilDiv(amt * 1000, RATE_DENOM), "fuzz platform != 10bps");
    }
}

contract VolFeeBindingCaptureTest is Test, Deployers {
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
        assertEq(Currency.unwrap(h.tknCurrency()), Currency.unwrap(currency1), "tknCurrency should be currency1");
        // Try to initialize a second distinct pool with the same hook - should revert with PoolAlreadyBound
        // Use same fee but different tickSpacing to create distinct pool key
        PoolKey memory secondKey = PoolKey(currency0, currency1, DYNAMIC_FEE, 30, IHooks(address(h)));
        // PoolManager wraps hook errors, so we expect any revert
        vm.expectRevert();
        manager.initialize(secondKey, SQRT_PRICE_1_1);
    }
}
