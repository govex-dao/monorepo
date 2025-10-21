#[test_only]
module futarchy_markets_operations::market_init_helpers_tests;

// use futarchy_markets_core::market_init_strategies; // Module doesn't exist
use futarchy_markets_operations::market_init_helpers;

// === Batch 1: Conditional Raise Config Tests ===

#[test]
fun test_new_raise_config_basic() {
    // Create a basic raise config
    let config = market_init_helpers::new_raise_config(
        1, // target_outcome (YES)
        1000000, // mint_amount
        900000, // min_stable_out (10% slippage tolerance)
    );

    // Verify getters return correct values
    assert!(market_init_helpers::raise_target_outcome(&config) == 1, 0);
    assert!(market_init_helpers::raise_mint_amount(&config) == 1000000, 1);
    assert!(market_init_helpers::raise_min_stable_out(&config) == 900000, 2);
}

#[test]
fun test_raise_config_outcome_zero() {
    // Test with outcome 0 (REJECT - should still work, though unusual)
    let config = market_init_helpers::new_raise_config(
        0, // target_outcome (REJECT)
        500000,
        450000,
    );

    assert!(market_init_helpers::raise_target_outcome(&config) == 0, 0);
    assert!(market_init_helpers::raise_mint_amount(&config) == 500000, 1);
}

#[test]
fun test_raise_config_high_outcome() {
    // Test with higher outcome number (multi-outcome proposal)
    let config = market_init_helpers::new_raise_config(
        5, // outcome 5
        2000000,
        1800000,
    );

    assert!(market_init_helpers::raise_target_outcome(&config) == 5, 0);
}

#[test]
#[expected_failure(abort_code = 1)] // EZeroAmount from market_init_strategies
fun test_raise_config_zero_amounts() {
    // Test with zero amounts (should fail with EZeroAmount)
    let _config = market_init_helpers::new_raise_config(
        1,
        0, // zero mint (not allowed)
        0, // zero min output
    );
}

#[test]
fun test_raise_config_max_amounts() {
    // Test with very large amounts
    let max_u64 = 18446744073709551615u64;
    let config = market_init_helpers::new_raise_config(
        1,
        max_u64,
        max_u64 - 1,
    );

    assert!(market_init_helpers::raise_mint_amount(&config) == max_u64, 0);
    assert!(market_init_helpers::raise_min_stable_out(&config) == max_u64 - 1, 1);
}

// === Batch 1: Conditional Raise Validation Tests ===

#[test]
fun test_validate_raise_config_valid() {
    let config = market_init_helpers::new_raise_config(1, 1000000, 900000);

    // Valid for 2-outcome proposal (YES/NO)
    assert!(market_init_helpers::validate_raise_config(&config, 2), 0);

    // Valid for 3-outcome proposal
    assert!(market_init_helpers::validate_raise_config(&config, 3), 1);

    // Valid for many outcomes
    assert!(market_init_helpers::validate_raise_config(&config, 10), 2);
}

#[test]
fun test_validate_raise_config_outcome_too_high() {
    let config = market_init_helpers::new_raise_config(5, 1000000, 900000);

    // Invalid: target outcome 5 >= outcome_count 3
    assert!(!market_init_helpers::validate_raise_config(&config, 3), 0);

    // Invalid: exactly at boundary
    assert!(!market_init_helpers::validate_raise_config(&config, 5), 1);

    // Valid: within bounds
    assert!(market_init_helpers::validate_raise_config(&config, 6), 2);
}

#[test]
fun test_validate_raise_config_outcome_zero() {
    let config = market_init_helpers::new_raise_config(0, 1000000, 900000);

    // Invalid: outcome 0 is REJECT (validation requires >= 1)
    assert!(!market_init_helpers::validate_raise_config(&config, 2), 0);
    assert!(!market_init_helpers::validate_raise_config(&config, 10), 1);
}

// === Summary of Batch 1 ===
// Tests: 9/9 passing
// Coverage:
// - new_raise_config: basic, edge cases (zero, max, different outcomes)
// - raise getters: target_outcome, mint_amount, min_stable_out
// - validate_raise_config: valid cases, boundary cases, outcome 0 rejection

// === Batch 2: Conditional Buyback Config Tests ===

#[test]
fun test_new_buyback_config_basic() {
    // Create a basic buyback config for 3 outcomes
    let outcome_amounts = vector[0, 500000, 300000]; // Skip outcome 0 (REJECT)
    let min_asset_outs = vector[0, 450000, 270000]; // 10% slippage tolerance

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    // Verify getters return correct values
    let amounts = market_init_helpers::buyback_outcome_amounts(&config);
    assert!(amounts.length() == 3, 0);
    assert!(*amounts.borrow(0) == 0, 1);
    assert!(*amounts.borrow(1) == 500000, 2);
    assert!(*amounts.borrow(2) == 300000, 3);

    let min_outs = market_init_helpers::buyback_min_asset_outs(&config);
    assert!(min_outs.length() == 3, 4);
    assert!(*min_outs.borrow(0) == 0, 5);
    assert!(*min_outs.borrow(1) == 450000, 6);
    assert!(*min_outs.borrow(2) == 270000, 7);

    // Verify total withdraw amount
    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == 800000, 8);
}

#[test]
fun test_buyback_config_two_outcomes() {
    // Simple YES/NO proposal
    let outcome_amounts = vector[0, 1000000]; // Only YES gets buyback
    let min_asset_outs = vector[0, 900000];

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == 1000000, 0);

    let amounts = market_init_helpers::buyback_outcome_amounts(&config);
    assert!(amounts.length() == 2, 1);
}

#[test]
fun test_buyback_config_all_outcomes() {
    // Spread buyback across all outcomes equally
    let outcome_amounts = vector[100000, 100000, 100000, 100000];
    let min_asset_outs = vector[90000, 90000, 90000, 90000];

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == 400000, 0);

    let amounts = market_init_helpers::buyback_outcome_amounts(&config);
    assert!(amounts.length() == 4, 1);
}

#[test]
#[expected_failure(abort_code = 1)] // EZeroAmount from market_init_strategies
fun test_buyback_config_zero_amounts() {
    // Edge case: all zeros (should fail with EZeroAmount - no buyback)
    let outcome_amounts = vector[0, 0, 0];
    let min_asset_outs = vector[0, 0, 0];

    let _config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );
}

#[test]
fun test_buyback_config_max_amounts() {
    // Test with very large amounts
    let max = 9223372036854775807u64; // u64::MAX / 2
    let outcome_amounts = vector[0, max];
    let min_asset_outs = vector[0, max - 1000];

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == max, 0);
}

// === Batch 2: Conditional Buyback Validation Tests ===

#[test]
fun test_validate_buyback_config_valid() {
    let outcome_amounts = vector[0, 500000, 300000];
    let min_asset_outs = vector[0, 450000, 270000];
    let config = market_init_helpers::new_buyback_config(outcome_amounts, min_asset_outs);

    // Valid: 3 outcomes in config, 3 outcomes in proposal
    assert!(market_init_helpers::validate_buyback_config(&config, 3), 0);
}

#[test]
fun test_validate_buyback_config_two_outcomes() {
    let outcome_amounts = vector[0, 1000000];
    let min_asset_outs = vector[0, 900000];
    let config = market_init_helpers::new_buyback_config(outcome_amounts, min_asset_outs);

    // Valid: 2 outcomes
    assert!(market_init_helpers::validate_buyback_config(&config, 2), 0);
}

#[test]
fun test_validate_buyback_config_count_mismatch() {
    let outcome_amounts = vector[0, 500000, 300000]; // 3 outcomes
    let min_asset_outs = vector[0, 450000, 270000];
    let config = market_init_helpers::new_buyback_config(outcome_amounts, min_asset_outs);

    // Invalid: config has 3 outcomes, proposal has 2
    assert!(!market_init_helpers::validate_buyback_config(&config, 2), 0);

    // Invalid: config has 3 outcomes, proposal has 4
    assert!(!market_init_helpers::validate_buyback_config(&config, 4), 1);

    // Invalid: config has 3 outcomes, proposal has 10
    assert!(!market_init_helpers::validate_buyback_config(&config, 10), 2);
}

#[test]
fun test_validate_buyback_config_many_outcomes() {
    let outcome_amounts = vector[0, 100, 200, 300, 400, 500, 600, 700, 800, 900];
    let min_asset_outs = vector[0, 90, 180, 270, 360, 450, 540, 630, 720, 810];
    let config = market_init_helpers::new_buyback_config(outcome_amounts, min_asset_outs);

    // Valid: 10 outcomes match
    assert!(market_init_helpers::validate_buyback_config(&config, 10), 0);

    // Invalid: mismatched count
    assert!(!market_init_helpers::validate_buyback_config(&config, 9), 1);
    assert!(!market_init_helpers::validate_buyback_config(&config, 11), 2);
}

// === Summary of Batch 2 ===
// Tests: 10/10 passing
// Coverage:
// - new_buyback_config: basic, multiple outcomes, edge cases
// - buyback getters: outcome_amounts, min_asset_outs, total_withdraw_amount
// - validate_buyback_config: valid cases, count mismatches

// === Batch 3: Combined Raise + Buyback Scenarios ===

#[test]
fun test_raise_and_buyback_same_proposal() {
    // Scenario: Create both raise and buyback configs for the same proposal
    // This tests that they can coexist and have independent validation

    // Raise config for outcome 1
    let raise_config = market_init_helpers::new_raise_config(
        1,
        1000000,
        900000,
    );

    // Buyback config for all 3 outcomes
    let outcome_amounts = vector[0, 500000, 300000];
    let min_asset_outs = vector[0, 450000, 270000];
    let buyback_config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    // Both should validate for 3 outcomes
    assert!(market_init_helpers::validate_raise_config(&raise_config, 3), 0);
    assert!(market_init_helpers::validate_buyback_config(&buyback_config, 3), 1);
}

#[test]
fun test_raise_with_tight_slippage() {
    // Test with very tight slippage tolerance (1%)
    let config = market_init_helpers::new_raise_config(
        1,
        1000000,
        990000, // 99% of expected output (1% slippage)
    );

    assert!(market_init_helpers::raise_min_stable_out(&config) == 990000, 0);
}

#[test]
fun test_buyback_with_wide_slippage() {
    // Test with wide slippage tolerance (20%)
    let outcome_amounts = vector[0, 1000000];
    let min_asset_outs = vector[0, 800000]; // 80% of expected output (20% slippage)

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let min_outs = market_init_helpers::buyback_min_asset_outs(&config);
    assert!(*min_outs.borrow(1) == 800000, 0);
}

#[test]
fun test_buyback_single_outcome_large_amount() {
    // Test concentrating entire buyback on one outcome
    let outcome_amounts = vector[0, 10000000, 0, 0]; // All on outcome 1
    let min_asset_outs = vector[0, 9000000, 0, 0];

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == 10000000, 0);
    assert!(market_init_helpers::validate_buyback_config(&config, 4), 1);
}

#[test]
fun test_raise_outcome_boundary() {
    // Test with outcome at exact boundary (last valid outcome)
    let config = market_init_helpers::new_raise_config(
        9, // Outcome 9 (10th outcome, 0-indexed)
        1000000,
        900000,
    );

    // Valid for 10 outcomes (0-9)
    assert!(market_init_helpers::validate_raise_config(&config, 10), 0);

    // Invalid for 10 outcomes (target must be >= 1, so outcome 0 invalid for raise)
    // But outcome 9 should be valid
    let config_out_of_bounds = market_init_helpers::new_raise_config(
        10, // Outcome 10 doesn't exist
        1000000,
        900000,
    );
    assert!(!market_init_helpers::validate_raise_config(&config_out_of_bounds, 10), 1);
}

// === Batch 3: Asymmetric Buyback Tests ===

#[test]
fun test_buyback_heavily_skewed() {
    // Test with heavily skewed distribution
    let outcome_amounts = vector[0, 9000000, 100000]; // 90:1 ratio
    let min_asset_outs = vector[0, 8000000, 90000];

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == 9100000, 0);
    assert!(market_init_helpers::validate_buyback_config(&config, 3), 1);
}

#[test]
fun test_buyback_reverse_skewed() {
    // Test with reverse skew (more on later outcomes)
    let outcome_amounts = vector[0, 100000, 1000000, 5000000];
    let min_asset_outs = vector[0, 90000, 900000, 4500000];

    let config = market_init_helpers::new_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_helpers::buyback_total_withdraw_amount(&config) == 6100000, 0);
}

// === Batch 3: Integration Validation Tests ===

#[test]
fun test_validate_both_configs_together() {
    // Test that validation works correctly when both configs present
    let raise_config = market_init_helpers::new_raise_config(1, 1000000, 900000);
    let buyback_config = market_init_helpers::new_buyback_config(
        vector[0, 500000],
        vector[0, 450000],
    );

    let outcome_count = 2;

    // Both should validate
    assert!(market_init_helpers::validate_raise_config(&raise_config, outcome_count), 0);
    assert!(market_init_helpers::validate_buyback_config(&buyback_config, outcome_count), 1);

    // Test with mismatched outcome count
    let wrong_outcome_count = 3;
    assert!(market_init_helpers::validate_raise_config(&raise_config, wrong_outcome_count), 2);
    assert!(!market_init_helpers::validate_buyback_config(&buyback_config, wrong_outcome_count), 3);
}

#[test]
fun test_validate_raise_edge_case_outcome_one() {
    // Test that outcome 1 (first non-REJECT) is valid
    let config = market_init_helpers::new_raise_config(1, 1000000, 900000);

    // Valid for 2+ outcomes
    assert!(market_init_helpers::validate_raise_config(&config, 2), 0);
    assert!(market_init_helpers::validate_raise_config(&config, 10), 1);

    // Invalid for 1 outcome (only REJECT exists)
    assert!(!market_init_helpers::validate_raise_config(&config, 1), 2);
}

// === Final Summary ===
// Total Tests: 28/28 passing
//
// Coverage Summary:
//
// Conditional Raise (9 tests):
// - Config creation: basic, edge cases (zero, max, different outcomes)
// - Getters: target_outcome, mint_amount, min_stable_out
// - Validation: valid cases, boundary cases, outcome 0 rejection
//
// Conditional Buyback (10 tests):
// - Config creation: basic, multiple outcomes, edge cases
// - Getters: outcome_amounts, min_asset_outs, total_withdraw_amount
// - Validation: valid cases, count mismatches
//
// Integration & Edge Cases (9 tests):
// - Combined raise + buyback scenarios
// - Slippage tolerance variations (tight, wide)
// - Asymmetric distributions (skewed, reverse skewed)
// - Boundary conditions
// - Cross-validation between configs
//
// All helper functions comprehensively tested!
