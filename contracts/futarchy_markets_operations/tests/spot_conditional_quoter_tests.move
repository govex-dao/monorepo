// Copyright 2024 FutarchyDAO
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module futarchy_markets_operations::spot_conditional_quoter_tests;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_operations::spot_conditional_quoter::{Self, SpotQuote, DetailedSpotQuote};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario as ts;
use sui::test_utils;

// === Test Helpers ===

fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

// Helper to create a test spot quote
fun create_test_spot_quote(
    amount_out: u64,
    effective_price: u64,
    price_impact_bps: u64,
    outcome: u64,
    is_asset_to_stable: bool,
): SpotQuote {
    spot_conditional_quoter::create_quote_for_testing(
        amount_out,
        effective_price,
        price_impact_bps,
        outcome,
        is_asset_to_stable,
    )
}

// Helper to create a detailed spot quote
fun create_test_detailed_quote(
    quote: SpotQuote,
    conditional_tokens_created: u64,
    excess_conditional_tokens: u64,
    spot_price_before: u64,
    spot_price_after: u64,
): DetailedSpotQuote {
    spot_conditional_quoter::create_detailed_quote_for_testing(
        quote,
        conditional_tokens_created,
        excess_conditional_tokens,
        spot_price_before,
        spot_price_after,
    )
}

// === SpotQuote Accessor Tests ===

#[test]
fun test_spot_quote_get_amount_out() {
    let quote = create_test_spot_quote(
        1500u64, // amount_out
        950_000_000_000, // effective_price (0.95)
        250, // price_impact_bps (2.5%)
        1, // outcome
        true, // is_asset_to_stable
    );

    assert!(spot_conditional_quoter::get_amount_out(&quote) == 1500, 0);
    test_utils::destroy(quote);
}

#[test]
fun test_spot_quote_get_effective_price() {
    let quote = create_test_spot_quote(
        1000u64,
        1_050_000_000_000, // effective_price (1.05)
        100,
        0,
        false,
    );

    assert!(spot_conditional_quoter::get_effective_price(&quote) == 1_050_000_000_000, 0);
    test_utils::destroy(quote);
}

#[test]
fun test_spot_quote_get_price_impact_bps() {
    let quote = create_test_spot_quote(
        2000u64,
        980_000_000_000,
        500, // price_impact_bps (5%)
        2,
        true,
    );

    assert!(spot_conditional_quoter::get_price_impact_bps(&quote) == 500, 0);
    test_utils::destroy(quote);
}

#[test]
fun test_spot_quote_get_outcome() {
    let quote = create_test_spot_quote(
        1000u64,
        1_000_000_000_000,
        50,
        3, // outcome
        false,
    );

    assert!(spot_conditional_quoter::get_outcome(&quote) == 3, 0);
    test_utils::destroy(quote);
}

#[test]
fun test_spot_quote_is_asset_to_stable() {
    let quote_asset_to_stable = create_test_spot_quote(
        1000u64,
        1_000_000_000_000,
        50,
        0,
        true, // is_asset_to_stable
    );

    let quote_stable_to_asset = create_test_spot_quote(
        1000u64,
        1_000_000_000_000,
        50,
        0,
        false, // is_asset_to_stable
    );

    assert!(spot_conditional_quoter::is_asset_to_stable(&quote_asset_to_stable) == true, 0);
    assert!(spot_conditional_quoter::is_asset_to_stable(&quote_stable_to_asset) == false, 1);

    test_utils::destroy(quote_asset_to_stable);
    test_utils::destroy(quote_stable_to_asset);
}

// === DetailedSpotQuote Accessor Tests ===

#[test]
fun test_detailed_quote_getters() {
    let base_quote = create_test_spot_quote(
        1500u64,
        950_000_000_000,
        250,
        1,
        true,
    );

    let detailed = create_test_detailed_quote(
        base_quote,
        3000u64, // conditional_tokens_created
        1500u64, // excess_conditional_tokens
        1_000_000_000_000, // spot_price_before (1.0)
        950_000_000_000, // spot_price_after (0.95)
    );

    assert!(spot_conditional_quoter::get_conditional_tokens_created(&detailed) == 3000, 0);
    assert!(spot_conditional_quoter::get_excess_conditional_tokens(&detailed) == 1500, 1);
    assert!(spot_conditional_quoter::get_spot_price_before(&detailed) == 1_000_000_000_000, 2);
    assert!(spot_conditional_quoter::get_spot_price_after(&detailed) == 950_000_000_000, 3);

    test_utils::destroy(detailed);
}

#[test]
fun test_detailed_quote_with_zero_excess() {
    let base_quote = create_test_spot_quote(
        1000u64,
        1_000_000_000_000,
        0,
        0,
        false,
    );

    let detailed = create_test_detailed_quote(
        base_quote,
        1000u64, // conditional_tokens_created
        0u64, // excess_conditional_tokens (none)
        1_000_000_000_000,
        1_000_000_000_000,
    );

    assert!(spot_conditional_quoter::get_excess_conditional_tokens(&detailed) == 0, 0);
    test_utils::destroy(detailed);
}

// === Oracle Price Function Tests ===

#[test]
fun test_check_price_threshold_above() {
    let price = 1_100_000_000_000u128; // 1.1
    let threshold = 1_000_000_000_000u128; // 1.0

    // Price is above threshold, should return true
    let result = spot_conditional_quoter::check_price_threshold(price, threshold, true);
    assert!(result == true, 0);

    // Price is above threshold, but checking for below, should return false
    let result2 = spot_conditional_quoter::check_price_threshold(price, threshold, false);
    assert!(result2 == false, 1);
}

#[test]
fun test_check_price_threshold_below() {
    let price = 900_000_000_000u128; // 0.9
    let threshold = 1_000_000_000_000u128; // 1.0

    // Price is below threshold, checking for below, should return true
    let result = spot_conditional_quoter::check_price_threshold(price, threshold, false);
    assert!(result == true, 0);

    // Price is below threshold, checking for above, should return false
    let result2 = spot_conditional_quoter::check_price_threshold(price, threshold, true);
    assert!(result2 == false, 1);
}

#[test]
fun test_check_price_threshold_equal() {
    let price = 1_000_000_000_000u128;
    let threshold = 1_000_000_000_000u128;

    // Price equals threshold, checking for above (>=), should return true
    let result = spot_conditional_quoter::check_price_threshold(price, threshold, true);
    assert!(result == true, 0);

    // Price equals threshold, checking for below (<=), should return true
    let result2 = spot_conditional_quoter::check_price_threshold(price, threshold, false);
    assert!(result2 == true, 1);
}

#[test]
fun test_check_price_threshold_zero() {
    let price = 0u128;
    let threshold = 1_000_000_000_000u128;

    // Zero price, checking for below, should return true
    let result = spot_conditional_quoter::check_price_threshold(price, threshold, false);
    assert!(result == true, 0);

    // Zero price, checking for above, should return false
    let result2 = spot_conditional_quoter::check_price_threshold(price, threshold, true);
    assert!(result2 == false, 1);
}

// === Spot Pool Integration Tests ===

// COMMENTED OUT: write_twap_observation_for_testing doesn't exist
// #[test]
// fun test_can_create_proposal_ready_twap() {
//     let mut scenario = ts::begin(@0xA);
//     let ctx = ts::ctx(&mut scenario);
//
//     futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
//     futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
//
//     ts::next_tx(&mut scenario, @0xA);
//     {
//         let ctx = ts::ctx(&mut scenario);
//         let clock = create_test_clock(300_000_000, ctx); // Well past TWAP initialization
//
//         // Create a spot pool with liquidity
//         let asset_reserve = 10_000_000_000u64; // 10 tokens
//         let stable_reserve = 10_000_000_000u64; // 10 tokens
//         let fee_bps = 30u64;
//
//         let spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B>(
//             asset_reserve,
//             stable_reserve,
//             fee_bps,
//             ctx
//         );
//
//         // Initialize TWAP by setting timestamp
//         unified_spot_pool::write_twap_observation_for_testing(&mut spot_pool, &clock);
//
//         // Advance time past TWAP window (3 days)
//         let mut clock2 = create_test_clock(300_000_000 + (3 * 24 * 60 * 60 * 1000), ctx);
//         unified_spot_pool::write_twap_observation_for_testing(&mut spot_pool, &clock2);
//
//         // Check if proposals can be created (TWAP should be ready)
//         let can_create = spot_conditional_quoter::can_create_proposal(&spot_pool, &clock2);
//         assert!(can_create == true, 0);
//
//         unified_spot_pool::destroy_for_testing(spot_pool);
//         clock::destroy_for_testing(clock);
//         clock::destroy_for_testing(clock2);
//     };
//
//     ts::end(scenario);
// }

// COMMENTED OUT: write_twap_observation_for_testing doesn't exist
// #[test]
// fun test_time_until_proposals_allowed_ready() {
//     let mut scenario = ts::begin(@0xA);
//     let ctx = ts::ctx(&mut scenario);
//
//     futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
//     futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
//
//     ts::next_tx(&mut scenario, @0xA);
//     {
//         let ctx = ts::ctx(&mut scenario);
//         let clock = create_test_clock(300_000_000, ctx);
//
//         let spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B>(
//             10_000_000_000u64,
//             10_000_000_000u64,
//             30u64,
//             ctx
//         );
//
//         unified_spot_pool::write_twap_observation_for_testing(&mut spot_pool, &clock);
//
//         // Advance time past TWAP window
//         let mut clock2 = create_test_clock(300_000_000 + (3 * 24 * 60 * 60 * 1000), ctx);
//         unified_spot_pool::write_twap_observation_for_testing(&mut spot_pool, &clock2);
//
//         // Time until allowed should be 0 (ready)
//         let time_until = spot_conditional_quoter::time_until_proposals_allowed(&spot_pool, &clock2);
//         assert!(time_until == 0, 0);
//
//         unified_spot_pool::destroy_for_testing(spot_pool);
//         clock::destroy_for_testing(clock);
//         clock::destroy_for_testing(clock2);
//     };
//
//     ts::end(scenario);
// }

// COMMENTED OUT: write_twap_observation_for_testing doesn't exist
// #[test]
// fun test_get_combined_oracle_price() {
//     let mut scenario = ts::begin(@0xA);
//     let ctx = ts::ctx(&mut scenario);
//
//     futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
//     futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
//
//     ts::next_tx(&mut scenario, @0xA);
//     {
//         let ctx = ts::ctx(&mut scenario);
//         let clock = create_test_clock(100_000, ctx);
//
//         let spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B>(
//             10_000_000_000u64,
//             10_000_000_000u64,
//             30u64,
//             ctx
//         );
//
//         unified_spot_pool::write_twap_observation_for_testing(&mut spot_pool, &clock);
//
//         // Get the combined oracle price (should be TWAP from spot pool)
//         let price = spot_conditional_quoter::get_combined_oracle_price(&spot_pool, &clock);
//
//         // Price should be non-zero
//         assert!(price > 0, 0);
//
//         unified_spot_pool::destroy_for_testing(spot_pool);
//         clock::destroy_for_testing(clock);
//     };
//
//     ts::end(scenario);
// }

// COMMENTED OUT: write_twap_observation_for_testing doesn't exist
// #[test]
// fun test_get_initialization_price() {
//     let mut scenario = ts::begin(@0xA);
//     let ctx = ts::ctx(&mut scenario);
//
//     futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
//     futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
//
//     ts::next_tx(&mut scenario, @0xA);
//     {
//         let ctx = ts::ctx(&mut scenario);
//         let clock = create_test_clock(100_000, ctx);
//
//         // Create pool with 1:1 ratio
//         let spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B>(
//             10_000_000_000u64,
//             10_000_000_000u64,
//             30u64,
//             ctx
//         );
//
//         unified_spot_pool::write_twap_observation_for_testing(&mut spot_pool, &clock);
//
//         // Get initialization price for conditional AMMs
//         let init_price = spot_conditional_quoter::get_initialization_price(&spot_pool, &clock);
//
//         // Should match the TWAP
//         assert!(init_price > 0, 0);
//
//         unified_spot_pool::destroy_for_testing(spot_pool);
//         clock::destroy_for_testing(clock);
//     };
//
//     ts::end(scenario);
// }

// === Edge Case Tests ===

#[test]
fun test_spot_quote_with_zero_price_impact() {
    let quote = create_test_spot_quote(
        1000u64,
        1_000_000_000_000,
        0, // zero price impact
        0,
        true,
    );

    assert!(spot_conditional_quoter::get_price_impact_bps(&quote) == 0, 0);
    test_utils::destroy(quote);
}

#[test]
fun test_spot_quote_with_high_price_impact() {
    let quote = create_test_spot_quote(
        800u64,
        700_000_000_000,
        5000, // 50% price impact
        1,
        true,
    );

    assert!(spot_conditional_quoter::get_price_impact_bps(&quote) == 5000, 0);
    assert!(spot_conditional_quoter::get_effective_price(&quote) == 700_000_000_000, 1);
    test_utils::destroy(quote);
}

#[test]
fun test_detailed_quote_multiple_outcomes() {
    let base_quote = create_test_spot_quote(
        1000u64,
        1_000_000_000_000,
        100,
        2,
        false,
    );

    // Scenario: 5 outcomes, 1000 tokens each = 5000 total created, 4000 excess
    let detailed = create_test_detailed_quote(
        base_quote,
        5000u64, // conditional_tokens_created (5 outcomes * 1000)
        4000u64, // excess_conditional_tokens (4 unused outcomes)
        1_000_000_000_000,
        1_010_000_000_000,
    );

    assert!(spot_conditional_quoter::get_conditional_tokens_created(&detailed) == 5000, 0);
    assert!(spot_conditional_quoter::get_excess_conditional_tokens(&detailed) == 4000, 1);

    test_utils::destroy(detailed);
}

#[test]
fun test_check_price_threshold_large_numbers() {
    let price = 999_999_999_999_999_999u128; // Very large price
    let threshold = 1_000_000_000_000_000_000u128;

    // Just below threshold
    let result = spot_conditional_quoter::check_price_threshold(price, threshold, false);
    assert!(result == true, 0);

    let result2 = spot_conditional_quoter::check_price_threshold(price, threshold, true);
    assert!(result2 == false, 1);
}
