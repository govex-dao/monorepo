#[test_only]
module futarchy_core::subsidy_config_tests;

use futarchy_core::subsidy_config;

// === Constructor Tests ===

#[test]
fun test_new_protocol_config_defaults() {
    let config = subsidy_config::new_protocol_config();

    assert!(subsidy_config::protocol_enabled(&config) == true, 0);
    assert!(subsidy_config::subsidy_per_outcome_per_crank(&config) == 100_000_000, 1); // 0.1 SUI
    assert!(subsidy_config::crank_steps(&config) == 100, 2);
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 100_000_000, 3); // 0.1 SUI
    assert!(subsidy_config::min_crank_interval_ms(&config) == 300_000, 4); // 5 minutes
}

#[test]
fun test_new_protocol_config_custom_valid() {
    let config = subsidy_config::new_protocol_config_custom(
        true,        // enabled
        200_000_000, // 0.2 SUI per outcome per crank
        50,          // 50 cranks
        150_000_000, // 0.15 SUI keeper fee
        600_000,     // 10 minutes
    );

    assert!(subsidy_config::protocol_enabled(&config) == true, 0);
    assert!(subsidy_config::subsidy_per_outcome_per_crank(&config) == 200_000_000, 1);
    assert!(subsidy_config::crank_steps(&config) == 50, 2);
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 150_000_000, 3);
    assert!(subsidy_config::min_crank_interval_ms(&config) == 600_000, 4);
}

#[test]
fun test_new_protocol_config_custom_disabled() {
    let config = subsidy_config::new_protocol_config_custom(
        false,       // disabled
        100_000_000,
        10,
        100_000_000,
        300_000,
    );

    assert!(subsidy_config::protocol_enabled(&config) == false, 0);
}

#[test]
#[expected_failure(abort_code = subsidy_config::EInvalidConfig)]
fun test_new_protocol_config_zero_crank_steps_fails() {
    subsidy_config::new_protocol_config_custom(
        true,
        100_000_000,
        0,           // Invalid: zero crank steps
        100_000_000,
        300_000,
    );
}

// === Calculation Tests ===

#[test]
fun test_calculate_total_subsidy_single_outcome() {
    let config = subsidy_config::new_protocol_config();

    let total = subsidy_config::calculate_total_subsidy(&config, 1);

    // 100_000_000 (per outcome per crank) × 1 (outcome) × 100 (crank steps) = 10_000_000_000
    assert!(total == 10_000_000_000, 0);
}

#[test]
fun test_calculate_total_subsidy_multiple_outcomes() {
    let config = subsidy_config::new_protocol_config();

    let total = subsidy_config::calculate_total_subsidy(&config, 5);

    // 100_000_000 × 5 × 100 = 50_000_000_000
    assert!(total == 50_000_000_000, 0);
}

#[test]
fun test_calculate_total_subsidy_zero_outcomes() {
    let config = subsidy_config::new_protocol_config();

    let total = subsidy_config::calculate_total_subsidy(&config, 0);

    assert!(total == 0, 0);
}

#[test]
fun test_calculate_total_subsidy_custom_amounts() {
    let config = subsidy_config::new_protocol_config_custom(
        true,
        500_000_000, // 0.5 SUI per outcome per crank
        20,          // 20 cranks
        100_000_000,
        300_000,
    );

    let total = subsidy_config::calculate_total_subsidy(&config, 3);

    // 500_000_000 × 3 × 20 = 30_000_000_000
    assert!(total == 30_000_000_000, 0);
}

#[test]
fun test_calculate_total_subsidy_max_outcomes() {
    let config = subsidy_config::new_protocol_config();

    // Test with max reasonable outcomes (e.g., 100)
    let total = subsidy_config::calculate_total_subsidy(&config, 100);

    // 100_000_000 × 100 × 100 = 1_000_000_000_000 (1000 SUI)
    assert!(total == 1_000_000_000_000, 0);
}

// === Getter Tests ===

#[test]
fun test_getters_return_correct_values() {
    let config = subsidy_config::new_protocol_config_custom(
        false,
        250_000_000,
        75,
        125_000_000,
        450_000,
    );

    assert!(subsidy_config::protocol_enabled(&config) == false, 0);
    assert!(subsidy_config::subsidy_per_outcome_per_crank(&config) == 250_000_000, 1);
    assert!(subsidy_config::crank_steps(&config) == 75, 2);
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 125_000_000, 3);
    assert!(subsidy_config::min_crank_interval_ms(&config) == 450_000, 4);
}

// === Setter Tests ===

#[test]
fun test_set_enabled() {
    let mut config = subsidy_config::new_protocol_config();

    assert!(subsidy_config::protocol_enabled(&config) == true, 0);

    subsidy_config::set_enabled(&mut config, false);
    assert!(subsidy_config::protocol_enabled(&config) == false, 1);

    subsidy_config::set_enabled(&mut config, true);
    assert!(subsidy_config::protocol_enabled(&config) == true, 2);
}

#[test]
fun test_set_subsidy_per_outcome_per_crank() {
    let mut config = subsidy_config::new_protocol_config();

    subsidy_config::set_subsidy_per_outcome_per_crank(&mut config, 300_000_000);
    assert!(subsidy_config::subsidy_per_outcome_per_crank(&config) == 300_000_000, 0);
}

#[test]
fun test_set_crank_steps_valid() {
    let mut config = subsidy_config::new_protocol_config();

    subsidy_config::set_crank_steps(&mut config, 200);
    assert!(subsidy_config::crank_steps(&config) == 200, 0);

    subsidy_config::set_crank_steps(&mut config, 1);
    assert!(subsidy_config::crank_steps(&config) == 1, 1);
}

#[test]
#[expected_failure(abort_code = subsidy_config::EInvalidConfig)]
fun test_set_crank_steps_zero_fails() {
    let mut config = subsidy_config::new_protocol_config();

    subsidy_config::set_crank_steps(&mut config, 0);
}

#[test]
fun test_set_keeper_fee_per_crank() {
    let mut config = subsidy_config::new_protocol_config();

    subsidy_config::set_keeper_fee_per_crank(&mut config, 50_000_000);
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 50_000_000, 0);

    // Zero should be allowed (no keeper fee)
    subsidy_config::set_keeper_fee_per_crank(&mut config, 0);
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 0, 1);
}

#[test]
fun test_set_min_crank_interval_ms() {
    let mut config = subsidy_config::new_protocol_config();

    subsidy_config::set_min_crank_interval_ms(&mut config, 1_000_000);
    assert!(subsidy_config::min_crank_interval_ms(&config) == 1_000_000, 0);

    // Zero should be allowed (no minimum interval)
    subsidy_config::set_min_crank_interval_ms(&mut config, 0);
    assert!(subsidy_config::min_crank_interval_ms(&config) == 0, 1);
}

// === State Transition Tests ===

#[test]
fun test_multiple_updates() {
    let mut config = subsidy_config::new_protocol_config();

    // Initial state
    assert!(subsidy_config::protocol_enabled(&config) == true, 0);
    assert!(subsidy_config::crank_steps(&config) == 100, 1);

    // Update multiple fields
    subsidy_config::set_enabled(&mut config, false);
    subsidy_config::set_crank_steps(&mut config, 50);
    subsidy_config::set_subsidy_per_outcome_per_crank(&mut config, 200_000_000);

    // Verify all updates
    assert!(subsidy_config::protocol_enabled(&config) == false, 2);
    assert!(subsidy_config::crank_steps(&config) == 50, 3);
    assert!(subsidy_config::subsidy_per_outcome_per_crank(&config) == 200_000_000, 4);

    // Original unchanged fields still correct
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 100_000_000, 5);
    assert!(subsidy_config::min_crank_interval_ms(&config) == 300_000, 6);
}

// === Edge Case Tests ===

#[test]
fun test_disabled_config_still_calculates() {
    let config = subsidy_config::new_protocol_config_custom(
        false,       // disabled
        100_000_000,
        100,
        100_000_000,
        300_000,
    );

    // Should still calculate correctly even when disabled
    let total = subsidy_config::calculate_total_subsidy(&config, 5);
    assert!(total == 50_000_000_000, 0);
}

#[test]
fun test_very_large_subsidy_calculation() {
    let config = subsidy_config::new_protocol_config_custom(
        true,
        1_000_000_000, // 1 SUI per outcome per crank
        1000,          // 1000 cranks
        100_000_000,
        300_000,
    );

    let total = subsidy_config::calculate_total_subsidy(&config, 10);

    // 1_000_000_000 × 10 × 1000 = 10_000_000_000_000 (10,000 SUI)
    assert!(total == 10_000_000_000_000, 0);
}

#[test]
fun test_minimal_config() {
    let config = subsidy_config::new_protocol_config_custom(
        true,
        1,           // Minimal subsidy
        1,           // Minimal cranks
        1,           // Minimal keeper fee
        0,           // No interval
    );

    assert!(subsidy_config::subsidy_per_outcome_per_crank(&config) == 1, 0);
    assert!(subsidy_config::crank_steps(&config) == 1, 1);
    assert!(subsidy_config::keeper_fee_per_crank(&config) == 1, 2);
    assert!(subsidy_config::min_crank_interval_ms(&config) == 0, 3);

    let total = subsidy_config::calculate_total_subsidy(&config, 1);
    assert!(total == 1, 4);
}

// === Copy Semantics Tests ===

#[test]
fun test_config_has_copy() {
    let config1 = subsidy_config::new_protocol_config();
    let config2 = config1; // Copy

    // Both should be valid
    assert!(subsidy_config::protocol_enabled(&config1) == true, 0);
    assert!(subsidy_config::protocol_enabled(&config2) == true, 1);

    // Same values
    assert!(
        subsidy_config::crank_steps(&config1) ==
        subsidy_config::crank_steps(&config2),
        2
    );
}

#[test]
fun test_config_copy_independence() {
    let config1 = subsidy_config::new_protocol_config();
    let mut config2 = config1; // Copy

    // Modify copy
    subsidy_config::set_crank_steps(&mut config2, 50);

    // Original unchanged (configs are independent after copy)
    assert!(subsidy_config::crank_steps(&config1) == 100, 0);
    assert!(subsidy_config::crank_steps(&config2) == 50, 1);
}
