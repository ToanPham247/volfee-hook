// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VolMath
/// @notice Pure math library for realized-volatility based dynamic LP fee calculation
/// @dev Fee unit = v4 LP-fee "pips" = hundredths of a bip; 1_000_000 = 100%
library VolMath {
    /// @notice Reverted when alphaBps > 10000 in ewmaUpdate
    error BadAlpha();

    /// @notice Reverted when fee bounds are invalid in feeFromVol
    error BadBounds();

    /// @notice Reverted when kDenominator is zero in feeFromVol
    error BadK();

    /// @notice Computes absolute tick delta between two ticks
    /// @param tickNow Current tick
    /// @param tickPrev Previous tick
    /// @return Absolute difference |tickNow - tickPrev| as uint256
    function absTickDelta(int24 tickNow, int24 tickPrev) internal pure returns (uint256) {
        // Cast to int256 first to handle full int24 range without overflow
        int256 diff = int256(tickNow) - int256(tickPrev);
        return diff < 0 ? uint256(-diff) : uint256(diff);
    }

    /// @notice Updates EWMA with new sample in integer fixed-point over 10_000
    /// @param prevEwma Previous EWMA value
    /// @param sample New sample value
    /// @param alphaBps Alpha in basis points (0-10000)
    /// @return New EWMA value
    function ewmaUpdate(uint256 prevEwma, uint256 sample, uint16 alphaBps) internal pure returns (uint256) {
        if (alphaBps > 10000) {
            revert BadAlpha();
        }
        // new = (alphaBps * sample + (10000 - alphaBps) * prevEwma) / 10000
        uint256 alpha = uint256(alphaBps);
        uint256 result = (alpha * sample + (10000 - alpha) * prevEwma) / 10000;
        return result;
    }

    /// @notice Calculates dynamic LP fee from volatility
    /// @param ewmaVol EWMA of realized volatility (tick delta)
    /// @param baseFeePips Base fee in pips
    /// @param kNumerator Numerator of volatility multiplier
    /// @param kDenominator Denominator of volatility multiplier (must be > 0)
    /// @param minFeePips Minimum fee in pips
    /// @param maxFeePips Maximum fee in pips
    /// @return Dynamic fee in pips, clamped to [minFeePips, maxFeePips]
    function feeFromVol(
        uint256 ewmaVol,
        uint24 baseFeePips,
        uint256 kNumerator,
        uint256 kDenominator,
        uint24 minFeePips,
        uint24 maxFeePips
    ) internal pure returns (uint24) {
        // Validate bounds
        if (minFeePips > maxFeePips || maxFeePips > 1_000_000) {
            revert BadBounds();
        }
        // Validate kDenominator
        if (kDenominator == 0) {
            revert BadK();
        }

        // Calculate volatility adjustment with overflow guard
        uint256 volAdjustment;
        if (kNumerator == 0) {
            volAdjustment = 0;
        } else if (ewmaVol > type(uint256).max / kNumerator) {
            // Overflow would occur in multiplication, return maxFeePips directly
            return maxFeePips;
        } else {
            uint256 product = ewmaVol * kNumerator;
            volAdjustment = product / kDenominator;
        }

        // Calculate raw fee with overflow guard for addition
        uint256 raw;
        if (volAdjustment > type(uint256).max - uint256(baseFeePips)) {
            // Addition would overflow, return maxFeePips
            return maxFeePips;
        } else {
            raw = uint256(baseFeePips) + volAdjustment;
        }

        // Clamp to [minFeePips, maxFeePips]
        if (raw < minFeePips) {
            return minFeePips;
        }
        if (raw > maxFeePips) {
            return maxFeePips;
        }
        return uint24(raw);
    }
}
