// Copyright 2024 FutarchyDAO
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module futarchy_markets_operations::market_init_strategies_tests;

use futarchy_markets_operations::market_init_strategies::{
    Self,
    ConditionalRaiseConfig,
    ConditionalBuybackConfig
};
use sui::test_utils;

// === ConditionalRaiseConfig Constructor Tests ===

#[test]
fun test_new_conditional_raise_config_basic() {
    let config = market_init_strategies::new_conditional_raise_config(
        1u8, // target_outcome (YES)
        1000000u64, // mint_amount
        950000u64, // min_stable_out (5% slippage tolerance)
    );

    assert!(market_init_strategies::raise_target_outcome(&config) == 1, 0);
    assert!(market_init_strategies::raise_mint_amount(&config) == 1000000, 1);
    assert!(market_init_strategies::raise_min_stable_out(&config) == 950000, 2);

    test_utils::destroy(config);
}

#[test]
fun test_new_conditional_raise_config_outcome_zero() {
    // Outcome 0 is REJECT - should fail validation (target_outcome must be >= 1)
    let config = market_init_strategies::new_conditional_raise_config(
        0u8,
        1000000u64,
        950000u64,
    );

    // Config creation succeeds but execution would fail
    test_utils::destroy(config);
}

#[test]
fun test_new_conditional_raise_config_high_outcome() {
    let config = market_init_strategies::new_conditional_raise_config(
        5u8, // Higher outcome number
        2000000u64,
        1900000u64,
    );

    assert!(market_init_strategies::raise_target_outcome(&config) == 5, 0);
    test_utils::destroy(config);
}

#[test]
#[expected_failure(abort_code = market_init_strategies::EZeroAmount)]
fun test_new_conditional_raise_config_zero_mint() {
    let config = market_init_strategies::new_conditional_raise_config(
        1u8,
        0u64, // Zero mint amount - should fail
        950000u64,
    );
    test_utils::destroy(config);
}

#[test]
#[expected_failure(abort_code = market_init_strategies::EZeroAmount)]
fun test_new_conditional_raise_config_zero_min_out() {
    let config = market_init_strategies::new_conditional_raise_config(
        1u8,
        1000000u64,
        0u64, // Zero min_stable_out - should fail
    );
    test_utils::destroy(config);
}

// === ConditionalBuybackConfig Constructor Tests ===

#[test]
fun test_new_conditional_buyback_config_basic() {
    let outcome_amounts = vector[0u64, 1000u64, 500u64]; // 3 outcomes
    let min_asset_outs = vector[0u64, 950u64, 475u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let amounts = market_init_strategies::buyback_outcome_amounts(&config);
    let mins = market_init_strategies::buyback_min_asset_outs(&config);

    assert!(amounts.length() == 3, 0);
    assert!(*amounts.borrow(0) == 0, 1);
    assert!(*amounts.borrow(1) == 1000, 2);
    assert!(*amounts.borrow(2) == 500, 3);

    assert!(mins.length() == 3, 4);
    assert!(*mins.borrow(0) == 0, 5);
    assert!(*mins.borrow(1) == 950, 6);
    assert!(*mins.borrow(2) == 475, 7);

    test_utils::destroy(config);
}

#[test]
fun test_new_conditional_buyback_config_single_outcome() {
    let outcome_amounts = vector[1000u64];
    let min_asset_outs = vector[950u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let amounts = market_init_strategies::buyback_outcome_amounts(&config);
    assert!(amounts.length() == 1, 0);
    assert!(*amounts.borrow(0) == 1000, 1);

    test_utils::destroy(config);
}

#[test]
fun test_new_conditional_buyback_config_many_outcomes() {
    let outcome_amounts = vector[0u64, 1000u64, 500u64, 750u64, 250u64];
    let min_asset_outs = vector[0u64, 950u64, 475u64, 700u64, 240u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let amounts = market_init_strategies::buyback_outcome_amounts(&config);
    assert!(amounts.length() == 5, 0);
    assert!(*amounts.borrow(3) == 750, 1);
    assert!(*amounts.borrow(4) == 250, 2);

    test_utils::destroy(config);
}

#[test]
#[expected_failure(abort_code = market_init_strategies::EZeroAmount)]
fun test_new_conditional_buyback_config_empty_vector() {
    let outcome_amounts = vector::empty<u64>();
    let min_asset_outs = vector::empty<u64>();

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );
    test_utils::destroy(config);
}

#[test]
#[expected_failure(abort_code = market_init_strategies::EAmountMismatch)]
fun test_new_conditional_buyback_config_length_mismatch() {
    let outcome_amounts = vector[1000u64, 500u64, 750u64];
    let min_asset_outs = vector[950u64, 475u64]; // Different length

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );
    test_utils::destroy(config);
}

#[test]
#[expected_failure(abort_code = market_init_strategies::EZeroAmount)]
fun test_new_conditional_buyback_config_all_zero_amounts() {
    let outcome_amounts = vector[0u64, 0u64, 0u64]; // All zero
    let min_asset_outs = vector[0u64, 0u64, 0u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );
    test_utils::destroy(config);
}

// === ConditionalRaiseConfig Getter Tests ===

#[test]
fun test_raise_getters_comprehensive() {
    let config = market_init_strategies::new_conditional_raise_config(
        2u8,
        5000000u64,
        4750000u64,
    );

    assert!(market_init_strategies::raise_target_outcome(&config) == 2, 0);
    assert!(market_init_strategies::raise_mint_amount(&config) == 5000000, 1);
    assert!(market_init_strategies::raise_min_stable_out(&config) == 4750000, 2);

    test_utils::destroy(config);
}

#[test]
fun test_raise_getters_max_u8_outcome() {
    let config = market_init_strategies::new_conditional_raise_config(
        255u8, // Max u8 value
        1000u64,
        900u64,
    );

    assert!(market_init_strategies::raise_target_outcome(&config) == 255, 0);
    test_utils::destroy(config);
}

// === ConditionalBuybackConfig Getter Tests ===

#[test]
fun test_buyback_getters_comprehensive() {
    let outcome_amounts = vector[100u64, 200u64, 300u64];
    let min_asset_outs = vector[95u64, 190u64, 285u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let amounts = market_init_strategies::buyback_outcome_amounts(&config);
    let mins = market_init_strategies::buyback_min_asset_outs(&config);

    assert!(amounts.length() == 3, 0);
    assert!(mins.length() == 3, 1);

    // Check all values
    assert!(*amounts.borrow(0) == 100, 2);
    assert!(*amounts.borrow(1) == 200, 3);
    assert!(*amounts.borrow(2) == 300, 4);

    assert!(*mins.borrow(0) == 95, 5);
    assert!(*mins.borrow(1) == 190, 6);
    assert!(*mins.borrow(2) == 285, 7);

    test_utils::destroy(config);
}

// === Buyback Total Withdraw Amount Tests ===

#[test]
fun test_buyback_total_withdraw_amount_basic() {
    let outcome_amounts = vector[0u64, 1000u64, 500u64];
    let min_asset_outs = vector[0u64, 950u64, 475u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let total = market_init_strategies::buyback_total_withdraw_amount(&config);
    assert!(total == 1500, 0); // 0 + 1000 + 500

    test_utils::destroy(config);
}

#[test]
fun test_buyback_total_withdraw_amount_all_outcomes() {
    let outcome_amounts = vector[100u64, 200u64, 300u64, 400u64];
    let min_asset_outs = vector[95u64, 190u64, 285u64, 380u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let total = market_init_strategies::buyback_total_withdraw_amount(&config);
    assert!(total == 1000, 0); // 100 + 200 + 300 + 400

    test_utils::destroy(config);
}

#[test]
fun test_buyback_total_withdraw_amount_single_outcome() {
    let outcome_amounts = vector[5000u64];
    let min_asset_outs = vector[4750u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let total = market_init_strategies::buyback_total_withdraw_amount(&config);
    assert!(total == 5000, 0);

    test_utils::destroy(config);
}

#[test]
fun test_buyback_total_withdraw_amount_with_zeros() {
    let outcome_amounts = vector[0u64, 0u64, 1000u64, 0u64];
    let min_asset_outs = vector[0u64, 0u64, 950u64, 0u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let total = market_init_strategies::buyback_total_withdraw_amount(&config);
    assert!(total == 1000, 0); // Only outcome 2 has buyback

    test_utils::destroy(config);
}

// === Edge Case Tests ===

#[test]
fun test_raise_config_tight_slippage() {
    // 0.1% slippage tolerance
    let config = market_init_strategies::new_conditional_raise_config(
        1u8,
        1000000u64,
        999000u64, // 99.9% of mint amount
    );

    assert!(market_init_strategies::raise_min_stable_out(&config) == 999000, 0);
    test_utils::destroy(config);
}

#[test]
fun test_raise_config_loose_slippage() {
    // 20% slippage tolerance
    let config = market_init_strategies::new_conditional_raise_config(
        1u8,
        1000000u64,
        800000u64, // 80% of mint amount
    );

    assert!(market_init_strategies::raise_min_stable_out(&config) == 800000, 0);
    test_utils::destroy(config);
}

#[test]
fun test_buyback_config_asymmetric_outcomes() {
    // Heavy bias toward outcome 1, light on outcome 2, none on outcome 0
    let outcome_amounts = vector[0u64, 10000u64, 1000u64];
    let min_asset_outs = vector[0u64, 9500u64, 950u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let total = market_init_strategies::buyback_total_withdraw_amount(&config);
    assert!(total == 11000, 0);

    test_utils::destroy(config);
}

#[test]
fun test_buyback_config_equal_outcomes() {
    // Equal buyback across all outcomes
    let outcome_amounts = vector[1000u64, 1000u64, 1000u64];
    let min_asset_outs = vector[950u64, 950u64, 950u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let amounts = market_init_strategies::buyback_outcome_amounts(&config);
    assert!(*amounts.borrow(0) == *amounts.borrow(1), 0);
    assert!(*amounts.borrow(1) == *amounts.borrow(2), 1);

    test_utils::destroy(config);
}

#[test]
fun test_buyback_config_large_numbers() {
    // Test with large amounts (billions)
    let outcome_amounts = vector[1_000_000_000u64, 2_000_000_000u64];
    let min_asset_outs = vector[950_000_000u64, 1_900_000_000u64];

    let config = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    let total = market_init_strategies::buyback_total_withdraw_amount(&config);
    assert!(total == 3_000_000_000, 0);

    test_utils::destroy(config);
}

// === Config Copy/Drop Tests ===

#[test]
fun test_raise_config_copy_drop() {
    let config1 = market_init_strategies::new_conditional_raise_config(
        1u8,
        1000000u64,
        950000u64,
    );

    // Copy the config
    let config2 = config1;

    // Both should have same values
    assert!(
        market_init_strategies::raise_target_outcome(&config1) ==
            market_init_strategies::raise_target_outcome(&config2),
        0,
    );
    assert!(
        market_init_strategies::raise_mint_amount(&config1) ==
            market_init_strategies::raise_mint_amount(&config2),
        1,
    );

    test_utils::destroy(config1);
    test_utils::destroy(config2);
}

#[test]
fun test_buyback_config_copy_drop() {
    let outcome_amounts = vector[1000u64, 500u64];
    let min_asset_outs = vector[950u64, 475u64];

    let config1 = market_init_strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    );

    // Copy the config
    let config2 = config1;

    // Both should have same values
    let amounts1 = market_init_strategies::buyback_outcome_amounts(&config1);
    let amounts2 = market_init_strategies::buyback_outcome_amounts(&config2);

    assert!(amounts1.length() == amounts2.length(), 0);
    assert!(*amounts1.borrow(0) == *amounts2.borrow(0), 1);

    test_utils::destroy(config1);
    test_utils::destroy(config2);
}
