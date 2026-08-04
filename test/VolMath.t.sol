// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/lib/VolMath.sol";

/// @notice Test wrapper to expose internal VolMath functions as external for testing
contract VolMathWrapper {
    function absTickDelta(int24 tickNow, int24 tickPrev) external pure returns (uint256) {
        return VolMath.absTickDelta(tickNow, tickPrev);
    }

    function ewmaUpdate(uint256 prevEwma, uint256 sample, uint16 alphaBps) external pure returns (uint256) {
        return VolMath.ewmaUpdate(prevEwma, sample, alphaBps);
    }

    function feeFromVol(
        uint256 ewmaVol,
        uint24 baseFeePips,
        uint256 kNumerator,
        uint256 kDenominator,
        uint24 minFeePips,
        uint24 maxFeePips
    ) external pure returns (uint24) {
        return VolMath.feeFromVol(ewmaVol, baseFeePips, kNumerator, kDenominator, minFeePips, maxFeePips);
    }
}

contract VolMathTest is Test {
    VolMathWrapper wrapper;

    function setUp() public {
        wrapper = new VolMathWrapper();
    }

    // ==================== absTickDelta Tests ====================

    function test_absTickDelta_positiveDelta() public pure {
        uint256 result = VolMath.absTickDelta(100, 40);
        assertEq(result, 60, "Expected 60 for (100, 40)");
    }

    function test_absTickDelta_negativeDelta() public pure {
        uint256 result = VolMath.absTickDelta(40, 100);
        assertEq(result, 60, "Expected 60 for (40, 100)");
    }

    function test_absTickDelta_sameTick() public pure {
        uint256 result = VolMath.absTickDelta(50, 50);
        assertEq(result, 0, "Expected 0 for same tick");
    }

    function test_absTickDelta_extremeRange() public pure {
        // int24 min = -8388608, max = 8388607
        int24 minTick = -8388608;
        int24 maxTick = 8388607;
        uint256 result = VolMath.absTickDelta(maxTick, minTick);
        // |8388607 - (-8388608)| = 16777215
        assertEq(result, 16777215, "Expected correct magnitude for extreme range");
    }

    function test_absTickDelta_extremeRangeReversed() public pure {
        int24 minTick = -8388608;
        int24 maxTick = 8388607;
        uint256 result = VolMath.absTickDelta(minTick, maxTick);
        assertEq(result, 16777215, "Expected correct magnitude for extreme range reversed");
    }

    // ==================== ewmaUpdate Tests ====================

    function test_ewma_alpha_zero() public pure {
        uint256 prev = 500;
        uint256 sample = 1000;
        uint256 result = VolMath.ewmaUpdate(prev, sample, 0);
        assertEq(result, prev, "alpha=0 should return prev unchanged");
    }

    function test_ewma_alpha_max() public pure {
        uint256 prev = 500;
        uint256 sample = 1000;
        uint256 result = VolMath.ewmaUpdate(prev, sample, 10000);
        assertEq(result, sample, "alpha=10000 should return sample");
    }

    function test_ewma_alpha_exceeds_max() public {
        uint256 prev = 500;
        uint256 sample = 1000;
        vm.expectRevert(VolMath.BadAlpha.selector);
        wrapper.ewmaUpdate(prev, sample, 10001);
    }

    function test_ewma_converges() public pure {
        uint256 prev = 0;
        uint256 sample = 1000;
        uint16 alpha = 2000; // 20%

        // After many iterations, should approach sample
        uint256 current = prev;
        for (uint256 i = 0; i < 100; i++) {
            current = VolMath.ewmaUpdate(current, sample, alpha);
        }

        // Should be very close to sample (within 5 due to integer division)
        assertApproxEqAbs(current, sample, 5, "EWMA should converge to sample");
    }

    function test_ewma_converges_monotonic() public pure {
        uint256 prev = 0;
        uint256 sample = 1000;
        uint16 alpha = 2000;

        uint256 current = prev;
        uint256 previous = 0;
        for (uint256 i = 0; i < 20; i++) {
            previous = current;
            current = VolMath.ewmaUpdate(current, sample, alpha);
            // When prev < sample, EWMA should be non-decreasing
            assertGe(current, previous, "EWMA should be monotonic when approaching from below");
        }
    }

    // ==================== feeFromVol Tests ====================

    function test_fee_vol_zero() public pure {
        uint24 result = VolMath.feeFromVol(0, 3000, 1, 1, 1000, 10000);
        // vol=0, k=1/1, so raw = 3000 + 0 = 3000
        assertEq(result, 3000, "vol=0 should return baseFeePips clamped");
    }

    function test_fee_clamps_to_min() public pure {
        // baseFeePips < minFeePips, vol=0
        uint24 result = VolMath.feeFromVol(0, 500, 1, 1, 1000, 10000);
        assertEq(result, 1000, "Should clamp to minFeePips");
    }

    function test_fee_clamps_to_max() public pure {
        // Huge vol should clamp to max
        uint24 result = VolMath.feeFromVol(type(uint256).max, 3000, 1, 1, 1000, 10000);
        assertEq(result, 10000, "Huge vol should clamp to maxFeePips");
    }

    function test_fee_mid_vol() public pure {
        // vol=100, k=1/1, base=3000 -> raw=3100
        uint24 result = VolMath.feeFromVol(100, 3000, 1, 1, 1000, 10000);
        assertEq(result, 3100, "Mid vol should calculate correctly");
    }

    function test_fee_bad_bounds_min_greater_than_max() public {
        vm.expectRevert(VolMath.BadBounds.selector);
        wrapper.feeFromVol(100, 3000, 1, 1, 5000, 1000);
    }

    function test_fee_bad_bounds_max_exceeds_limit() public {
        vm.expectRevert(VolMath.BadBounds.selector);
        wrapper.feeFromVol(100, 3000, 1, 1, 1000, 1_000_001);
    }

    function test_fee_bad_k_zero_denominator() public {
        vm.expectRevert(VolMath.BadK.selector);
        wrapper.feeFromVol(100, 3000, 1, 0, 1000, 10000);
    }

    function test_fee_max_at_boundary() public pure {
        // maxFeePips exactly at 1_000_000 should work
        uint24 result = VolMath.feeFromVol(100, 3000, 1, 1, 1000, 1_000_000);
        assertEq(result, 3100, "Should work at max boundary");
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_fee_always_in_range(
        uint256 vol,
        uint24 base,
        uint24 mn,
        uint24 mx,
        uint256 kn,
        uint256 kd
    ) public pure {
        // Bound inputs
        mn = uint24(bound(mn, 0, 1_000_000));
        mx = uint24(bound(mx, mn, 1_000_000));
        base = uint24(bound(base, 0, 1_000_000));
        kd = bound(kd, 1, 1e18);
        kn = bound(kn, 0, 1e12);
        vol = bound(vol, 0, 1e12);

        uint24 fee = VolMath.feeFromVol(vol, base, kn, kd, mn, mx);

        assertGe(fee, mn, "Fee should be >= minFeePips");
        assertLe(fee, mx, "Fee should be <= maxFeePips");
    }

    function testFuzz_fee_monotonic(
        uint256 v1,
        uint256 v2,
        uint24 base,
        uint256 kn,
        uint256 kd,
        uint24 mn,
        uint24 mx
    ) public pure {
        // Bound inputs
        mn = uint24(bound(mn, 0, 1_000_000));
        mx = uint24(bound(mx, mn, 1_000_000));
        base = uint24(bound(base, 0, 1_000_000));
        kd = bound(kd, 1, 1e18);
        kn = bound(kn, 0, 1e12);
        v1 = bound(v1, 0, 1e12);
        v2 = bound(v2, v1, 1e12); // v2 >= v1

        uint24 fee1 = VolMath.feeFromVol(v1, base, kn, kd, mn, mx);
        uint24 fee2 = VolMath.feeFromVol(v2, base, kn, kd, mn, mx);

        assertGe(fee2, fee1, "Fee should be monotonic non-decreasing in vol");
    }

    function testFuzz_ewma_bounded(
        uint256 prev,
        uint256 sample,
        uint16 alpha
    ) public pure {
        // Bound inputs
        alpha = uint16(bound(alpha, 0, 10000));
        prev = bound(prev, 0, 1e9);
        sample = bound(sample, 0, 1e9);

        uint256 result = VolMath.ewmaUpdate(prev, sample, alpha);

        uint256 minVal = prev < sample ? prev : sample;
        uint256 maxVal = prev > sample ? prev : sample;

        assertGe(result, minVal, "EWMA result should be >= min(prev, sample)");
        assertLe(result, maxVal, "EWMA result should be <= max(prev, sample)");
    }

    function testFuzz_absTickDelta_symmetric(int24 tick1, int24 tick2) public pure {
        uint256 delta1 = VolMath.absTickDelta(tick1, tick2);
        uint256 delta2 = VolMath.absTickDelta(tick2, tick1);
        assertEq(delta1, delta2, "absTickDelta should be symmetric");
    }

    function testFuzz_ewma_alpha_zero_unchanged(uint256 prev, uint256 sample) public pure {
        prev = bound(prev, 0, 1e18);
        sample = bound(sample, 0, 1e18);
        uint256 result = VolMath.ewmaUpdate(prev, sample, 0);
        assertEq(result, prev, "alpha=0 should always return prev");
    }

    function testFuzz_ewma_alpha_max_returns_sample(uint256 prev, uint256 sample) public pure {
        prev = bound(prev, 0, 1e18);
        sample = bound(sample, 0, 1e18);
        uint256 result = VolMath.ewmaUpdate(prev, sample, 10000);
        assertEq(result, sample, "alpha=10000 should always return sample");
    }
}
