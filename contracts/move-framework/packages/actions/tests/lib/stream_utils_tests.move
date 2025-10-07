#[test_only]
module account_actions::stream_utils_tests;

// === Imports ===

use account_actions::stream_utils;

// === Linear Vesting Tests ===

#[test]
fun test_linear_vesting_before_start() {
    let vested = stream_utils::calculate_linear_vested(
        1000,  // total_amount
        100,   // start_time
        200,   // end_time
        50     // current_time (before start)
    );
    assert!(vested == 0, 0);
}

#[test]
fun test_linear_vesting_at_start() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 100);
    assert!(vested == 0, 0);
}

#[test]
fun test_linear_vesting_halfway() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 150);
    assert!(vested == 500, 0);
}

#[test]
fun test_linear_vesting_at_end() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 200);
    assert!(vested == 1000, 0);
}

#[test]
fun test_linear_vesting_after_end() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 250);
    assert!(vested == 1000, 0);
}

// === Cliff Vesting Tests ===

#[test]
fun test_cliff_vesting_before_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(
        1000,  // total_amount
        100,   // start_time
        200,   // end_time
        130,   // cliff_time
        120    // current_time (before cliff)
    );
    assert!(vested == 0, 0);
}

#[test]
fun test_cliff_vesting_at_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 130);
    assert!(vested == 300, 0); // 30% of way through
}

#[test]
fun test_cliff_vesting_after_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 150);
    assert!(vested == 500, 0); // 50% of way through
}

// === Effective Time Tests ===

#[test]
fun test_effective_time_no_pause() {
    let eff_time = stream_utils::calculate_effective_time(
        150,  // current_time
        200,  // end_time
        0     // paused_duration
    );
    assert!(eff_time == 150, 0);
}

#[test]
fun test_effective_time_with_pause_before_adjusted_end() {
    let eff_time = stream_utils::calculate_effective_time(150, 200, 50);
    assert!(eff_time == 150, 0);
}

#[test]
fun test_effective_time_with_pause_after_adjusted_end() {
    let eff_time = stream_utils::calculate_effective_time(300, 200, 50);
    assert!(eff_time == 250, 0); // Capped at end_time + paused_duration
}

// === Time Parameter Validation Tests ===

#[test]
fun test_validate_time_parameters_valid() {
    let is_valid = stream_utils::validate_time_parameters(
        100,   // start_time
        200,   // end_time
        &std::option::some(130),  // cliff_time between start and end
        50     // current_time (start is in future)
    );
    assert!(is_valid, 0);
}

#[test]
fun test_validate_time_parameters_end_before_start() {
    let is_valid = stream_utils::validate_time_parameters(
        200,   // start_time
        100,   // end_time (invalid: before start)
        &std::option::none(),
        50
    );
    assert!(!is_valid, 0);
}

#[test]
fun test_validate_time_parameters_start_in_past() {
    let is_valid = stream_utils::validate_time_parameters(
        50,    // start_time (invalid: in past)
        200,   // end_time
        &std::option::none(),
        100    // current_time
    );
    assert!(!is_valid, 0);
}

#[test]
fun test_validate_time_parameters_cliff_before_start() {
    let is_valid = stream_utils::validate_time_parameters(
        100,
        200,
        &std::option::some(50),  // cliff before start (invalid)
        0
    );
    assert!(!is_valid, 0);
}

#[test]
fun test_validate_time_parameters_cliff_after_end() {
    let is_valid = stream_utils::validate_time_parameters(
        100,
        200,
        &std::option::some(250),  // cliff after end (invalid)
        0
    );
    assert!(!is_valid, 0);
}

// === Rate Limit Tests ===

#[test]
fun test_check_rate_limit_no_limit() {
    let allowed = stream_utils::check_rate_limit(
        100,  // last_withdrawal_time
        0,    // min_interval_ms (no limit)
        150   // current_time
    );
    assert!(allowed, 0);
}

#[test]
fun test_check_rate_limit_first_withdrawal() {
    let allowed = stream_utils::check_rate_limit(
        0,     // last_withdrawal_time (never withdrawn)
        1000,  // min_interval_ms
        150    // current_time
    );
    assert!(allowed, 0);
}

#[test]
fun test_check_rate_limit_too_soon() {
    let allowed = stream_utils::check_rate_limit(
        100,   // last_withdrawal_time
        1000,  // min_interval_ms
        500    // current_time (only 400ms elapsed)
    );
    assert!(!allowed, 0);
}

#[test]
fun test_check_rate_limit_after_interval() {
    let allowed = stream_utils::check_rate_limit(
        100,   // last_withdrawal_time
        1000,  // min_interval_ms
        1100   // current_time (1000ms+ elapsed)
    );
    assert!(allowed, 0);
}

// === Withdrawal Limit Tests ===

#[test]
fun test_check_withdrawal_limit_no_limit() {
    let allowed = stream_utils::check_withdrawal_limit(
        500,  // amount
        0     // max_per_withdrawal (no limit)
    );
    assert!(allowed, 0);
}

#[test]
fun test_check_withdrawal_limit_within_limit() {
    let allowed = stream_utils::check_withdrawal_limit(500, 1000);
    assert!(allowed, 0);
}

#[test]
fun test_check_withdrawal_limit_exceeds_limit() {
    let allowed = stream_utils::check_withdrawal_limit(1500, 1000);
    assert!(!allowed, 0);
}

// === Claimable Amount Tests ===

#[test]
fun test_calculate_claimable_nothing_vested() {
    let claimable = stream_utils::calculate_claimable(
        1000,  // total_amount
        0,     // claimed_amount
        100,   // start_time
        200,   // end_time
        50,    // current_time (before start)
        0,     // paused_duration
        &std::option::none()
    );
    assert!(claimable == 0, 0);
}

#[test]
fun test_calculate_claimable_partial_vested() {
    let claimable = stream_utils::calculate_claimable(
        1000,  // total_amount
        200,   // claimed_amount
        100,   // start_time
        200,   // end_time
        150,   // current_time (50% vested = 500)
        0,     // paused_duration
        &std::option::none()
    );
    assert!(claimable == 300, 0); // 500 vested - 200 claimed
}

#[test]
fun test_calculate_claimable_all_vested() {
    let claimable = stream_utils::calculate_claimable(
        1000,
        0,
        100,
        200,
        250,   // current_time (after end)
        0,
        &std::option::none()
    );
    assert!(claimable == 1000, 0);
}

#[test]
fun test_calculate_claimable_with_pause() {
    let claimable = stream_utils::calculate_claimable(
        1000,
        0,
        100,
        200,
        150,   // current_time
        50,    // paused_duration extends end to 250
        &std::option::none()
    );
    // At time 150 with pause, only 33.3% vested
    assert!(claimable == 333, 0);
}

// === Split Vested/Unvested Tests ===

#[test]
fun test_split_vested_unvested_all_vested() {
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000,  // total_amount
        0,     // claimed_amount
        1000,  // balance_remaining
        100,   // start_time
        200,   // end_time
        250,   // current_time (after end, all vested)
        0,     // paused_duration
        &std::option::none()
    );

    assert!(to_pay == 1000, 0);      // All goes to beneficiary
    assert!(to_refund == 0, 0);      // Nothing to refund
    assert!(unvested_claimed == 0, 0); // Nothing unvested was claimed
}

#[test]
fun test_split_vested_unvested_partial() {
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000,  // total_amount
        0,     // claimed_amount
        1000,  // balance_remaining
        100,   // start_time
        200,   // end_time
        150,   // current_time (50% vested = 500)
        0,     // paused_duration
        &std::option::none()
    );

    assert!(to_pay == 500, 0);    // 500 vested goes to beneficiary
    assert!(to_refund == 500, 0); // 500 unvested refunded
    assert!(unvested_claimed == 0, 0);
}

#[test]
fun test_split_vested_unvested_overclaimed() {
    // Beneficiary withdrew 700 but only 500 had vested
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000,  // total_amount
        700,   // claimed_amount (overclaimed!)
        300,   // balance_remaining
        100,   // start_time
        200,   // end_time
        150,   // current_time (50% vested = 500)
        0,     // paused_duration
        &std::option::none()
    );

    assert!(to_pay == 0, 0);          // Nothing more to pay (already overclaimed)
    assert!(to_refund == 300, 0);     // All remaining refunded
    assert!(unvested_claimed == 200, 0); // 200 was claimed before vesting
}

// === Pause Control Tests ===

#[test]
fun test_calculate_pause_until_indefinite() {
    let pause_until = stream_utils::calculate_pause_until(
        100,  // current_time
        0     // pause_duration_ms (0 = indefinite)
    );
    assert!(pause_until.is_none(), 0);
}

#[test]
fun test_calculate_pause_until_timed() {
    let pause_until = stream_utils::calculate_pause_until(100, 500);
    assert!(pause_until.is_some(), 0);
    assert!(*pause_until.borrow() == 600, 0);
}

#[test]
fun test_is_pause_expired_indefinite() {
    let expired = stream_utils::is_pause_expired(
        &std::option::none(),  // Indefinite pause
        1000  // current_time
    );
    assert!(!expired, 0); // Never expires
}

#[test]
fun test_is_pause_expired_not_yet() {
    let expired = stream_utils::is_pause_expired(
        &std::option::some(500),  // Pause until 500
        400   // current_time (before expiry)
    );
    assert!(!expired, 0);
}

#[test]
fun test_is_pause_expired_yes() {
    let expired = stream_utils::is_pause_expired(
        &std::option::some(500),
        600   // current_time (after expiry)
    );
    assert!(expired, 0);
}

// === State Check Tests ===

#[test]
fun test_can_claim_all_clear() {
    let can = stream_utils::can_claim(
        false,  // is_paused
        false,  // is_frozen
        &std::option::some(1000),  // expiry
        500     // current_time (before expiry)
    );
    assert!(can, 0);
}

#[test]
fun test_can_claim_paused() {
    let can = stream_utils::can_claim(
        true,   // is_paused
        false,
        &std::option::some(1000),
        500
    );
    assert!(!can, 0);
}

#[test]
fun test_can_claim_frozen() {
    let can = stream_utils::can_claim(
        false,
        true,   // is_frozen
        &std::option::some(1000),
        500
    );
    assert!(!can, 0);
}

#[test]
fun test_can_claim_expired() {
    let can = stream_utils::can_claim(
        false,
        false,
        &std::option::some(500),  // expiry
        1000   // current_time (after expiry)
    );
    assert!(!can, 0);
}

// === Edge Cases ===

#[test]
fun test_large_amounts_no_overflow() {
    // Test with large amounts that could overflow without u128
    let vested = stream_utils::calculate_linear_vested(
        18_446_744_073_709_551_615,  // Max u64
        0,
        1000,
        500  // 50%
    );
    // Should be approximately half without overflow
    assert!(vested > 0, 0);
}

#[test]
fun test_pause_duration_calculation() {
    let duration = stream_utils::calculate_pause_duration(100, 500);
    assert!(duration == 400, 0);
}

#[test]
fun test_pause_duration_invalid_order() {
    let duration = stream_utils::calculate_pause_duration(500, 100);
    assert!(duration == 0, 0); // Returns 0 if resumed_at < paused_at
}
