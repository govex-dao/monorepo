// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Fee scheduling module for dynamic AMM fees
/// Supports linear decay from high launch fees (99%) to standard spot fees (0.3%)
/// After decay period ends, pool uses the final_fee_bps as the permanent spot fee
/// Simplified linear decay for gas efficiency and predictability
module futarchy_markets_primitives::fee_scheduler;

// === Errors ===
const EInitialFeeTooHigh: u64 = 0;
const EDurationTooLong: u64 = 1;
const EDecayOverflow: u64 = 2;

// === Constants ===
const MAX_INITIAL_FEE_BPS: u64 = 9900; // 99% maximum (DAO policy)
const MAX_DURATION_MS: u64 = 86_400_000; // 24 hours maximum
const FEE_SCALE: u64 = 10000; // 100% in basis points
const PRECISION_SCALE: u128 = 10000; // Scaling factor to avoid precision loss in division

// === Structs ===

/// Fee schedule configuration for linear decay from high launch fee to spot fee
/// Simplified API: just specify initial MEV fee and duration
/// Final fee comes from the pool's base spot_amm_fee_bps (set in pool, not here)
/// Fee decays linearly: fee(t) = initial_fee - (initial_fee - final_fee) * (t / duration)
public struct FeeSchedule has store, copy, drop {
    /// Initial MEV protection fee in basis points (0-9900, e.g., 9900 = 99%)
    initial_fee_bps: u64,

    /// Total duration of fee decay in milliseconds (0-86400000 = 0-24 hours)
    /// If 0, MEV protection is skipped (use base pool fee immediately)
    duration_ms: u64,
}

// === Public Functions ===

/// Create a new fee schedule with linear decay
///
/// Schedules linear decay from high initial MEV fee (0-99%) to the pool's base spot fee.
/// After the decay period ends, the pool permanently uses its base spot_amm_fee_bps.
///
/// # Parameters
/// - initial_fee_bps: Initial MEV protection fee (0-9900 bps = 0%-99%)
/// - duration_ms: Duration of decay period (0-86400000 ms = 0-24 hours)
///
/// # Constraints
/// - initial_fee_bps must be <= 9900 (99% maximum - DAO policy)
/// - duration_ms must be <= 86_400_000 (24 hours maximum)
/// - If duration_ms is 0, MEV protection is skipped entirely
/// - If initial_fee_bps is 0, effectively no MEV protection
///
/// # Decay Formula
/// fee(t) = initial_fee_bps - (initial_fee_bps - final_fee_bps) * (t / duration_ms)
/// where final_fee_bps comes from pool's base spot_amm_fee_bps
public fun new_schedule(
    initial_fee_bps: u64,
    duration_ms: u64,
): FeeSchedule {
    // Validate parameters
    assert!(initial_fee_bps <= FEE_SCALE, EInitialFeeTooHigh); // Can't exceed 100%
    assert!(initial_fee_bps <= MAX_INITIAL_FEE_BPS, EInitialFeeTooHigh); // DAO policy: max 99%
    assert!(duration_ms <= MAX_DURATION_MS, EDurationTooLong);

    FeeSchedule {
        initial_fee_bps,
        duration_ms,
    }
}

/// Calculate current fee based on elapsed time and pool's base fee
/// Uses LINEAR decay (simple, fast, predictable)
///
/// # Edge cases (hard-coded):
/// - t = 0: return initial_fee_bps (max MEV protection)
/// - t >= duration: return final_fee_bps (spot fee)
/// - duration = 0: skip MEV, always return final_fee_bps
///
/// # Linear decay (0 < t < duration):
/// - Formula: fee(t) = initial - (initial - final) * (t / duration)
/// - Smooth decay every millisecond
/// - Guaranteed to reach final_fee exactly at duration end
/// - Fast: just 2 multiplications, 2 divisions
public fun get_current_fee(
    schedule: &FeeSchedule,
    final_fee_bps: u64,
    start_time: u64,
    current_time: u64,
): u64 {
    // Edge case: duration = 0, skip MEV protection
    if (schedule.duration_ms == 0) {
        return final_fee_bps
    };

    // Edge case: if final fee >= initial fee, no decay needed
    if (final_fee_bps >= schedule.initial_fee_bps) {
        return final_fee_bps
    };

    // Edge case: before start, return initial fee (max protection)
    if (current_time <= start_time) {
        return schedule.initial_fee_bps
    };

    let elapsed = current_time - start_time;

    // Edge case: after duration ends, return final fee (spot fee)
    if (elapsed >= schedule.duration_ms) {
        return final_fee_bps
    };

    // Linear interpolation: fee(t) = initial - (initial - final) * (t / duration)
    let fee_drop = schedule.initial_fee_bps - final_fee_bps;

    // Scale elapsed by PRECISION_SCALE to avoid precision loss in division
    let progress = ((elapsed as u128) * PRECISION_SCALE) / (schedule.duration_ms as u128);
    let decay_amount = ((fee_drop as u128) * progress) / PRECISION_SCALE;

    // Safety: ensure decay_amount doesn't overflow u64 before subtraction
    // Given constraints: fee_drop <= 9900, progress <= 10000, result <= 9900 (always fits in u64)
    assert!(decay_amount <= (schedule.initial_fee_bps as u128), EDecayOverflow);

    let current_fee = schedule.initial_fee_bps - (decay_amount as u64);

    // Clamp to final_fee_bps (safety for rounding)
    if (current_fee < final_fee_bps) {
        final_fee_bps
    } else {
        current_fee
    }
}

/// Create default launch protection schedule: 99% → spot fee over 2 hours
/// Uses linear decay (simple and gas-efficient)
public fun default_launch_schedule(): FeeSchedule {
    FeeSchedule {
        initial_fee_bps: 9900,        // 99% MEV protection fee
        duration_ms: 7_200_000,       // 2 hours
    }
}

// === Getters ===

public fun initial_fee_bps(schedule: &FeeSchedule): u64 {
    schedule.initial_fee_bps
}

public fun duration_ms(schedule: &FeeSchedule): u64 {
    schedule.duration_ms
}

/// Get maximum allowed initial fee (DAO policy)
public fun max_initial_fee_bps(): u64 {
    MAX_INITIAL_FEE_BPS
}

/// Get maximum allowed duration
public fun max_duration_ms(): u64 {
    MAX_DURATION_MS
}

/// Get fee scale (100% in basis points)
public fun fee_scale(): u64 {
    FEE_SCALE
}

// === Test Helpers ===

#[test_only]
public fun new_schedule_for_testing(
    initial: u64,
    duration: u64,
): FeeSchedule {
    new_schedule(initial, duration)
}
