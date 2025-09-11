#[test_only]
module account_actions::stream_utils_tests;

use std::option;
use account_actions::stream_utils;

// === Linear Vesting Tests ===

#[test]
fun test_linear_vesting_before_start() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 50);
    assert!(vested == 0);
}

#[test]
fun test_linear_vesting_at_start() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 100);
    assert!(vested == 0);
}

#[test]
fun test_linear_vesting_halfway() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 150);
    assert!(vested == 500);
}

#[test]
fun test_linear_vesting_at_end() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 200);
    assert!(vested == 1000);
}

#[test]
fun test_linear_vesting_after_end() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 250);
    assert!(vested == 1000);
}

#[test]
fun test_linear_vesting_quarter_way() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 125);
    assert!(vested == 250);
}

#[test]
fun test_linear_vesting_three_quarters() {
    let vested = stream_utils::calculate_linear_vested(1000, 100, 200, 175);
    assert!(vested == 750);
}

#[test]
fun test_linear_vesting_large_amounts() {
    // Test with large amounts to ensure no overflow
    let vested = stream_utils::calculate_linear_vested(
        1_000_000_000_000, // 1 trillion
        0,
        1000,
        500
    );
    assert!(vested == 500_000_000_000); // 500 billion
}

// === Cliff Vesting Tests ===

#[test]
fun test_cliff_vesting_before_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 120);
    assert!(vested == 0);
}

#[test]
fun test_cliff_vesting_at_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 130);
    assert!(vested == 300); // 30% vested at cliff
}

#[test]
fun test_cliff_vesting_after_cliff_before_end() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 150);
    assert!(vested == 500); // 50% vested
}

#[test]
fun test_cliff_vesting_at_end_with_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 200);
    assert!(vested == 1000);
}

#[test]
fun test_cliff_vesting_after_end_with_cliff() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 130, 250);
    assert!(vested == 1000);
}

#[test]
fun test_cliff_at_start() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 100, 100);
    assert!(vested == 0); // Nothing vested exactly at start/cliff
}

#[test]
fun test_cliff_at_end() {
    let vested = stream_utils::calculate_vested_with_cliff(1000, 100, 200, 200, 200);
    assert!(vested == 1000); // Everything vested when cliff is at end
}

// === Effective Time Tests ===

#[test]
fun test_effective_time_no_pause() {
    let effective = stream_utils::calculate_effective_time(150, 200, 0);
    assert!(effective == 150);
}

#[test]
fun test_effective_time_with_pause_before_adjusted_end() {
    let effective = stream_utils::calculate_effective_time(150, 200, 50);
    assert!(effective == 150); // Current time is before adjusted end
}

#[test]
fun test_effective_time_with_pause_after_adjusted_end() {
    let effective = stream_utils::calculate_effective_time(300, 200, 50);
    assert!(effective == 250); // Capped at adjusted end (200 + 50)
}

#[test]
fun test_effective_time_large_pause() {
    let effective = stream_utils::calculate_effective_time(500, 200, 200);
    assert!(effective == 400); // Capped at adjusted end (200 + 200)
}

// === Parameter Validation Tests ===

#[test]
fun test_validate_valid_parameters() {
    let cliff = option::some(150);
    let valid = stream_utils::validate_time_parameters(100, 200, &cliff, 50);
    assert!(valid);
}

#[test]
fun test_validate_invalid_end_before_start() {
    let cliff = option::none();
    let valid = stream_utils::validate_time_parameters(200, 100, &cliff, 50);
    assert!(!valid);
}

#[test]
fun test_validate_invalid_start_in_past() {
    let cliff = option::none();
    let valid = stream_utils::validate_time_parameters(50, 200, &cliff, 100);
    assert!(!valid);
}

#[test]
fun test_validate_invalid_cliff_before_start() {
    let cliff = option::some(50);
    let valid = stream_utils::validate_time_parameters(100, 200, &cliff, 50);
    assert!(!valid);
}

#[test]
fun test_validate_invalid_cliff_after_end() {
    let cliff = option::some(250);
    let valid = stream_utils::validate_time_parameters(100, 200, &cliff, 50);
    assert!(!valid);
}

#[test]
fun test_validate_no_cliff() {
    let cliff = option::none();
    let valid = stream_utils::validate_time_parameters(100, 200, &cliff, 50);
    assert!(valid);
}

// === Pause Duration Tests ===

#[test]
fun test_pause_duration_normal() {
    let duration = stream_utils::calculate_pause_duration(100, 150);
    assert!(duration == 50);
}

#[test]
fun test_pause_duration_zero() {
    let duration = stream_utils::calculate_pause_duration(100, 100);
    assert!(duration == 0);
}

#[test]
fun test_pause_duration_negative() {
    // Resume time before pause time (shouldn't happen but handle gracefully)
    let duration = stream_utils::calculate_pause_duration(150, 100);
    assert!(duration == 0);
}

// === Rate Limiting Tests ===

#[test]
fun test_rate_limit_no_restriction() {
    let allowed = stream_utils::check_rate_limit(100, 0, 150);
    assert!(allowed); // No interval restriction
}

#[test]
fun test_rate_limit_first_withdrawal() {
    let allowed = stream_utils::check_rate_limit(0, 100, 150);
    assert!(allowed); // First withdrawal always allowed
}

#[test]
fun test_rate_limit_within_interval() {
    let allowed = stream_utils::check_rate_limit(100, 100, 150);
    assert!(!allowed); // Only 50ms passed, need 100ms
}

#[test]
fun test_rate_limit_at_interval() {
    let allowed = stream_utils::check_rate_limit(100, 100, 200);
    assert!(allowed); // Exactly 100ms passed
}

#[test]
fun test_rate_limit_after_interval() {
    let allowed = stream_utils::check_rate_limit(100, 100, 250);
    assert!(allowed); // More than 100ms passed
}

// === Withdrawal Limit Tests ===

#[test]
fun test_withdrawal_limit_no_restriction() {
    let allowed = stream_utils::check_withdrawal_limit(1000, 0);
    assert!(allowed); // No max limit
}

#[test]
fun test_withdrawal_limit_within_limit() {
    let allowed = stream_utils::check_withdrawal_limit(500, 1000);
    assert!(allowed);
}

#[test]
fun test_withdrawal_limit_at_limit() {
    let allowed = stream_utils::check_withdrawal_limit(1000, 1000);
    assert!(allowed);
}

#[test]
fun test_withdrawal_limit_exceeds() {
    let allowed = stream_utils::check_withdrawal_limit(1001, 1000);
    assert!(!allowed);
}

// === Claimable Calculation Tests ===

#[test]
fun test_claimable_before_start() {
    let cliff = option::none();
    let claimable = stream_utils::calculate_claimable(
        1000, 0, 100, 200, 50, 0, &cliff
    );
    assert!(claimable == 0);
}

#[test]
fun test_claimable_halfway_no_claims() {
    let cliff = option::none();
    let claimable = stream_utils::calculate_claimable(
        1000, 0, 100, 200, 150, 0, &cliff
    );
    assert!(claimable == 500);
}

#[test]
fun test_claimable_halfway_with_claims() {
    let cliff = option::none();
    let claimable = stream_utils::calculate_claimable(
        1000, 200, 100, 200, 150, 0, &cliff
    );
    assert!(claimable == 300); // 500 vested - 200 claimed
}

#[test]
fun test_claimable_with_pause() {
    let cliff = option::none();
    let claimable = stream_utils::calculate_claimable(
        1000, 0, 100, 200, 150, 50, &cliff
    );
    // Effective end is 250 (200 + 50 pause)
    // At time 150, elapsed is 50 out of 150 total = 333
    assert!(claimable == 333);
}

#[test]
fun test_claimable_with_cliff_before() {
    let cliff = option::some(130);
    let claimable = stream_utils::calculate_claimable(
        1000, 0, 100, 200, 120, 0, &cliff
    );
    assert!(claimable == 0); // Before cliff
}

#[test]
fun test_claimable_with_cliff_after() {
    let cliff = option::some(130);
    let claimable = stream_utils::calculate_claimable(
        1000, 0, 100, 200, 150, 0, &cliff
    );
    assert!(claimable == 500);
}

#[test]
fun test_claimable_all_claimed() {
    let cliff = option::none();
    let claimable = stream_utils::calculate_claimable(
        1000, 1000, 100, 200, 200, 0, &cliff
    );
    assert!(claimable == 0); // Everything already claimed
}

#[test]
fun test_claimable_over_claimed() {
    let cliff = option::none();
    let claimable = stream_utils::calculate_claimable(
        1000, 1100, 100, 200, 150, 0, &cliff
    );
    assert!(claimable == 0); // Over-claimed (shouldn't happen but handle gracefully)
}

// === Split Vested/Unvested Tests ===

#[test]
fun test_split_before_start() {
    let cliff = option::none();
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 0, 1000, 100, 200, 50, 0, &cliff
    );
    assert!(to_pay == 0);
    assert!(to_refund == 1000);
    assert!(unvested_claimed == 0);
}

#[test]
fun test_split_halfway_no_claims() {
    let cliff = option::none();
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 0, 1000, 100, 200, 150, 0, &cliff
    );
    assert!(to_pay == 500);
    assert!(to_refund == 500);
    assert!(unvested_claimed == 0);
}

#[test]
fun test_split_halfway_with_claims() {
    let cliff = option::none();
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 200, 800, 100, 200, 150, 0, &cliff
    );
    assert!(to_pay == 300); // 500 vested - 200 claimed
    assert!(to_refund == 500);
    assert!(unvested_claimed == 0);
}

#[test]
fun test_split_over_claimed() {
    let cliff = option::none();
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 600, 400, 100, 200, 150, 0, &cliff
    );
    // 500 vested but 600 claimed = 100 over-claimed
    assert!(to_pay == 0);
    assert!(to_refund == 400);
    assert!(unvested_claimed == 100);
}

#[test]
fun test_split_insufficient_balance() {
    let cliff = option::none();
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 200, 200, 100, 200, 150, 0, &cliff
    );
    // 500 vested - 200 claimed = 300 owed, but only 200 balance
    assert!(to_pay == 200); // Limited by balance
    assert!(to_refund == 0);
    assert!(unvested_claimed == 0);
}

#[test]
fun test_split_at_end() {
    let cliff = option::none();
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 800, 200, 100, 200, 200, 0, &cliff
    );
    assert!(to_pay == 200); // 1000 vested - 800 claimed
    assert!(to_refund == 0);
    assert!(unvested_claimed == 0);
}

#[test]
fun test_split_with_cliff() {
    let cliff = option::some(130);
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        1000, 0, 1000, 100, 200, 120, 0, &cliff
    );
    assert!(to_pay == 0); // Before cliff, nothing vested
    assert!(to_refund == 1000);
    assert!(unvested_claimed == 0);
}

// === Max Beneficiaries Test ===

#[test]
fun test_max_beneficiaries_constant() {
    assert!(stream_utils::max_beneficiaries() == 100);
}