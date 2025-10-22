// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_markets_primitives::fee_scheduler_tests;

use futarchy_markets_primitives::fee_scheduler;

// === Constants for Testing ===

const FEE_SCALE: u64 = 10000; // 100% = 10000 bps

// Time constants
const ONE_MINUTE_MS: u64 = 60_000;
const TEN_MINUTES_MS: u64 = 600_000;
const ONE_HOUR_MS: u64 = 3_600_000;
const TWO_HOURS_MS: u64 = 7_200_000;
const TWENTY_FOUR_HOURS_MS: u64 = 86_400_000;

// === Basic Validation Tests ===

#[test]
#[expected_failure(abort_code = fee_scheduler::EInitialFeeTooHigh)]
fun test_new_schedule_fails_initial_fee_exceeds_99_percent() {
    fee_scheduler::new_schedule(
        10000,   // INVALID: 100% (max is 9900 = 99%)
        TWO_HOURS_MS,
    );
}

#[test]
#[expected_failure(abort_code = fee_scheduler::EDurationTooLong)]
fun test_new_schedule_fails_duration_exceeds_24_hours() {
    fee_scheduler::new_schedule(
        9900,
        86_400_001,  // INVALID: > 24 hours
    );
}

#[test]
fun test_new_schedule_valid() {
    let schedule = fee_scheduler::new_schedule(
        9900,        // 99%
        TWO_HOURS_MS,
    );

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 9900, 0);
    assert!(fee_scheduler::duration_ms(&schedule) == TWO_HOURS_MS, 1);
}

#[test]
fun test_new_schedule_zero_duration_allowed() {
    // 0 duration is allowed (skips MEV protection)
    let schedule = fee_scheduler::new_schedule(
        9900,
        0,  // 0 duration = skip MEV
    );

    assert!(fee_scheduler::duration_ms(&schedule) == 0, 0);
}

#[test]
fun test_new_schedule_zero_initial_fee_allowed() {
    // 0 initial fee is allowed (effectively no MEV protection)
    let schedule = fee_scheduler::new_schedule(
        0,  // 0 initial fee
        TWO_HOURS_MS,
    );

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 0, 0);
}

#[test]
fun test_new_schedule_max_values() {
    let schedule = fee_scheduler::new_schedule(
        9900,              // Max: 99%
        TWENTY_FOUR_HOURS_MS,  // Max: 24 hours
    );

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 9900, 0);
    assert!(fee_scheduler::duration_ms(&schedule) == TWENTY_FOUR_HOURS_MS, 1);
}

// === Edge Case Tests ===

#[test]
fun test_get_current_fee_before_start() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 1000;
    let current_time = 999;  // Before start

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 9900, 0); // Should return initial_fee_bps
}

#[test]
fun test_get_current_fee_at_exact_start() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 1000;
    let current_time = 1000;  // Exactly at start

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 9900, 0); // Should return initial_fee_bps
}

#[test]
fun test_get_current_fee_after_duration_ends() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = TWO_HOURS_MS;  // Exactly at end

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 30, 0); // Should return final_fee_bps
}

#[test]
fun test_get_current_fee_way_after_duration_ends() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = TWENTY_FOUR_HOURS_MS;  // Way after end

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 30, 0); // Should return final_fee_bps
}

#[test]
fun test_get_current_fee_zero_duration() {
    let schedule = fee_scheduler::new_schedule(9900, 0);  // 0 duration
    let final_fee = 30;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 1000);
    assert!(fee == 30, 0); // Should skip MEV, return final_fee immediately
}

// === Linear Decay Tests ===

#[test]
fun test_linear_decay_at_halfway() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = ONE_HOUR_MS;  // 50% through duration

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // Linear: fee(50%) = 9900 - (9900 - 30) * 0.5 = 9900 - 4935 = 4965
    // Allow small rounding error
    assert!(fee >= 4960 && fee <= 4970, 0);
}

#[test]
fun test_linear_decay_at_quarter() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = ONE_HOUR_MS / 2;  // 25% through duration

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // Linear: fee(25%) = 9900 - (9900 - 30) * 0.25 = 9900 - 2467.5 = 7432.5
    assert!(fee >= 7430 && fee <= 7435, 0);
}

#[test]
fun test_linear_decay_at_three_quarters() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = (ONE_HOUR_MS * 3) / 2;  // 75% through duration

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // Linear: fee(75%) = 9900 - (9900 - 30) * 0.75 = 9900 - 7402.5 = 2497.5
    assert!(fee >= 2495 && fee <= 2500, 0);
}

#[test]
fun test_linear_decay_continuous() {
    // Test that decay updates smoothly every millisecond
    // Use 1000ms for clean 1 bps/ms math
    let schedule = fee_scheduler::new_schedule(1000, 1000);  // 10% → 0% over 1 second
    let final_fee = 0;

    let fee_0 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0);
    let fee_1 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 1);
    let fee_2 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 2);
    let fee_500 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 500);
    let fee_1000 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 1000);

    // Should decrease by 1 bps per ms (1000 bps over 1000 ms)
    assert!(fee_0 == 1000, 0);
    assert!(fee_1 == 999, 1);
    assert!(fee_2 == 998, 2);
    assert!(fee_500 == 500, 3);
    assert!(fee_1000 == 0, 4);
}

#[test]
fun test_default_schedule() {
    let schedule = fee_scheduler::default_launch_schedule();

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 9900, 0);  // 99%
    assert!(fee_scheduler::duration_ms(&schedule) == TWO_HOURS_MS, 1);  // 2 hours
}

// === Different Final Fee Tests ===

#[test]
fun test_different_final_fees() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);

    // Test with different final fees (pool's base spot fee)
    let fee_10 = fee_scheduler::get_current_fee(&schedule, 10, 0, ONE_HOUR_MS);
    let fee_30 = fee_scheduler::get_current_fee(&schedule, 30, 0, ONE_HOUR_MS);
    let fee_100 = fee_scheduler::get_current_fee(&schedule, 100, 0, ONE_HOUR_MS);

    // At 50%:
    // fee_10:  9900 - (9900-10)*0.5 = 9900 - 4945 = 4955
    // fee_30:  9900 - (9900-30)*0.5 = 9900 - 4935 = 4965
    // fee_100: 9900 - (9900-100)*0.5 = 9900 - 4900 = 5000

    assert!(fee_10 >= 4950 && fee_10 <= 4960, 0);
    assert!(fee_30 >= 4960 && fee_30 <= 4970, 1);
    assert!(fee_100 >= 4995 && fee_100 <= 5005, 2);
}

// === Precision Tests ===

#[test]
fun test_precision_very_small_duration() {
    let schedule = fee_scheduler::new_schedule(1000, 100);  // 100ms duration
    let final_fee = 0;

    let fee_50 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 50);  // 50% through

    // Should be close to 500 (1000 * 0.5)
    assert!(fee_50 >= 490 && fee_50 <= 510, 0);
}

#[test]
fun test_precision_very_large_range() {
    let schedule = fee_scheduler::new_schedule(9900, TWENTY_FOUR_HOURS_MS);
    let final_fee = 1;

    let fee_12h = fee_scheduler::get_current_fee(&schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS / 2);

    // At 50%: 9900 - (9900-1)*0.5 = 9900 - 4949.5 = 4950.5
    assert!(fee_12h >= 4945 && fee_12h <= 4955, 0);
}

// === Monotonicity Test ===

#[test]
fun test_monotonicity_fee_never_increases() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let mut prev_fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0);

    // Test at 1-minute increments
    let mut time = 0;
    while (time <= TWO_HOURS_MS) {
        let current_fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, time);

        // Fee should never increase (monotonically decreasing)
        assert!(current_fee <= prev_fee, 0);

        prev_fee = current_fee;
        time = time + ONE_MINUTE_MS;
    };
}

// === Edge Cases with Different Ranges ===

#[test]
fun test_small_fee_drop() {
    // Small difference between initial and final
    let schedule = fee_scheduler::new_schedule(100, TWO_HOURS_MS);
    let final_fee = 90;

    let fee_half = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    // At 50%: 100 - (100-90)*0.5 = 100 - 5 = 95
    assert!(fee_half == 95, 0);
}

#[test]
fun test_equal_initial_and_final() {
    let schedule = fee_scheduler::new_schedule(300, TWO_HOURS_MS);
    let final_fee = 300;  // Same as initial

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    // No decay, should stay at 300
    assert!(fee == 300, 0);
}

#[test]
fun test_zero_to_zero() {
    let schedule = fee_scheduler::new_schedule(0, TWO_HOURS_MS);
    let final_fee = 0;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    assert!(fee == 0, 0);
}

// === Edge Case: Final Fee Greater Than Initial ===

#[test]
fun test_final_fee_greater_than_initial() {
    // Edge case: final_fee_bps > initial_fee_bps (no decay needed)
    let schedule = fee_scheduler::new_schedule(100, TWO_HOURS_MS);
    let final_fee = 500; // Higher than initial

    let fee_start = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0);
    let fee_mid = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);
    let fee_end = fee_scheduler::get_current_fee(&schedule, final_fee, 0, TWO_HOURS_MS);

    // Should always return final_fee (no decay)
    assert!(fee_start == 500, 0);
    assert!(fee_mid == 500, 1);
    assert!(fee_end == 500, 2);
}

#[test]
fun test_final_fee_equals_initial() {
    // Edge case: final_fee_bps == initial_fee_bps (no decay)
    let schedule = fee_scheduler::new_schedule(300, TWO_HOURS_MS);
    let final_fee = 300;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    // Should return final_fee (no decay happens)
    assert!(fee == 300, 0);
}

// === New Validation Tests ===

#[test]
#[expected_failure(abort_code = fee_scheduler::EInitialFeeTooHigh)]
fun test_new_schedule_fails_initial_exceeds_100_percent() {
    fee_scheduler::new_schedule(
        10001,   // INVALID: > 100%
        TWO_HOURS_MS,
    );
}

#[test]
fun test_max_getters() {
    // Test that limit getters work
    assert!(fee_scheduler::max_initial_fee_bps() == 9900, 0);
    assert!(fee_scheduler::max_duration_ms() == TWENTY_FOUR_HOURS_MS, 1);
    assert!(fee_scheduler::fee_scale() == 10000, 2);
}

// === Time Near Boundaries ===

#[test]
fun test_time_near_u64_max() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let start_time = 18_446_744_073_709_551_615u64 - 10_000_000; // Near u64::MAX
    let current_time = start_time + ONE_HOUR_MS;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // Should handle without overflow - at 50% through
    assert!(fee >= 4960 && fee <= 4970, 0);
}

#[test]
fun test_one_millisecond_before_end() {
    let schedule = fee_scheduler::new_schedule(9900, TWO_HOURS_MS);
    let final_fee = 30;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, TWO_HOURS_MS - 1);

    // Should be very close to final_fee but not quite there
    assert!(fee > 30 && fee < 40, 0);
}
