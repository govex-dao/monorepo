#[test_only]
module futarchy_markets_operations::proposal_with_market_init_tests;

use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_operations::market_init_helpers;
use futarchy_markets_operations::proposal_with_market_init;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario as test;
use sui::test_utils;

// === Test Constants ===
const ALICE: address = @0xA11CE;

// === Helper Functions ===

/// Create a test clock
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Create a test proposal in PREMARKET state with specified outcome count
fun create_test_proposal(
    outcome_count: u8,
    ctx: &mut TxContext,
): Proposal<TEST_COIN_A, TEST_COIN_B> {
    proposal::create_test_proposal<TEST_COIN_A, TEST_COIN_B>(
        outcome_count,
        0, // winning_outcome (doesn't matter for PREMARKET)
        false, // NOT finalized
        ctx,
    )
}

/// Create a test escrow with market state
fun create_test_escrow(
    outcome_count: u64,
    ctx: &mut TxContext,
): TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let clock = create_test_clock(0, ctx);
    let market_state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        outcome_count,
        vector[b"Yes".to_string(), b"No".to_string()],
        &clock,
        ctx,
    );

    clock::destroy_for_testing(clock);
    coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx)
}

// === Batch 1: merge_asset_coins Tests ===

#[test]
fun test_merge_asset_coins_empty_vector() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Empty vector should return zero coin
    let empty_vec = vector::empty<Coin<TEST_COIN_A>>();
    let merged = proposal_with_market_init::merge_asset_coins(empty_vec, ctx);

    assert!(merged.value() == 0, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

#[test]
fun test_merge_asset_coins_single_coin() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Single coin should be returned as-is
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let mut vec = vector::empty();
    vec.push_back(coin1);

    let merged = proposal_with_market_init::merge_asset_coins(vec, ctx);

    assert!(merged.value() == 1000, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

#[test]
fun test_merge_asset_coins_two_coins() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Merge two coins
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let coin2 = coin::mint_for_testing<TEST_COIN_A>(2000, ctx);
    let mut vec = vector::empty();
    vec.push_back(coin1);
    vec.push_back(coin2);

    let merged = proposal_with_market_init::merge_asset_coins(vec, ctx);

    assert!(merged.value() == 3000, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

#[test]
fun test_merge_asset_coins_multiple_coins() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Merge many coins
    let mut vec = vector::empty();
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(100, ctx));
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(200, ctx));
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(300, ctx));
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(400, ctx));
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(500, ctx));

    let merged = proposal_with_market_init::merge_asset_coins(vec, ctx);

    assert!(merged.value() == 1500, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

#[test]
fun test_merge_asset_coins_with_zero_values() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Include zero-value coins
    let mut vec = vector::empty();
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(1000, ctx));
    vec.push_back(coin::zero<TEST_COIN_A>(ctx));
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(2000, ctx));
    vec.push_back(coin::zero<TEST_COIN_A>(ctx));

    let merged = proposal_with_market_init::merge_asset_coins(vec, ctx);

    assert!(merged.value() == 3000, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

#[test]
fun test_merge_asset_coins_all_zeros() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // All zero coins
    let mut vec = vector::empty();
    vec.push_back(coin::zero<TEST_COIN_A>(ctx));
    vec.push_back(coin::zero<TEST_COIN_A>(ctx));
    vec.push_back(coin::zero<TEST_COIN_A>(ctx));

    let merged = proposal_with_market_init::merge_asset_coins(vec, ctx);

    assert!(merged.value() == 0, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

#[test]
fun test_merge_asset_coins_large_amounts() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Large values
    let max_half = 9223372036854775807u64; // u64::MAX / 2
    let mut vec = vector::empty();
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(max_half, ctx));
    vec.push_back(coin::mint_for_testing<TEST_COIN_A>(1000, ctx));

    let merged = proposal_with_market_init::merge_asset_coins(vec, ctx);

    assert!(merged.value() == max_half + 1000, 0);

    // Cleanup
    coin::burn_for_testing(merged);
    test::end(scenario);
}

// === Summary of Batch 1 ===
// Tests: 7/7 passing
// Coverage:
// - merge_asset_coins: empty, single, two, multiple, with zeros, all zeros, large amounts

// === Batch 2: Conditional Raise Validation Tests ===

#[test]
#[expected_failure(abort_code = proposal_with_market_init::EInvalidRaiseConfig)]
fun test_execute_raise_invalid_outcome_too_high() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Create proposal with 2 outcomes
    let mut proposal = create_test_proposal(2, ctx);
    let mut escrow = create_test_escrow(2, ctx);
    let clock = create_test_clock(1000, ctx);

    // Create config for outcome 5 (doesn't exist)
    let config = market_init_helpers::new_raise_config(
        5, // outcome too high
        1000000,
        900000,
    );

    // Create minted coins (will fail before using them)
    let minted_coins = coin::mint_for_testing<TEST_COIN_A>(1000000, ctx);

    // Should abort with EInvalidRaiseConfig
    let stable_coins = proposal_with_market_init::execute_raise_on_proposal<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_COIN_A, // AssetConditionalCoin (simplified)
        TEST_COIN_B, // StableConditionalCoin (simplified)
    >(&mut proposal, &mut escrow, minted_coins, config, &clock, ctx);

    // Cleanup (won't reach here)
    coin::burn_for_testing(stable_coins);
    clock::destroy_for_testing(clock);
    proposal::destroy_for_testing(proposal);
    test_utils::destroy(escrow);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_with_market_init::EInvalidRaiseConfig)]
fun test_execute_raise_invalid_outcome_zero() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Create proposal with 2 outcomes
    let mut proposal = create_test_proposal(2, ctx);
    let mut escrow = create_test_escrow(2, ctx);
    let clock = create_test_clock(1000, ctx);

    // Create config for outcome 0 (REJECT - invalid for raise)
    let config = market_init_helpers::new_raise_config(
        0, // outcome 0 is REJECT
        1000000,
        900000,
    );

    let minted_coins = coin::mint_for_testing<TEST_COIN_A>(1000000, ctx);

    // Should abort with EInvalidRaiseConfig
    let stable_coins = proposal_with_market_init::execute_raise_on_proposal<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_COIN_A,
        TEST_COIN_B,
    >(&mut proposal, &mut escrow, minted_coins, config, &clock, ctx);

    // Cleanup (won't reach here)
    coin::burn_for_testing(stable_coins);
    clock::destroy_for_testing(clock);
    proposal::destroy_for_testing(proposal);
    test_utils::destroy(escrow);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_with_market_init::EInvalidRaiseConfig)]
fun test_execute_raise_invalid_outcome_at_boundary() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Create proposal with 3 outcomes (0, 1, 2)
    let mut proposal = create_test_proposal(3, ctx);
    let mut escrow = create_test_escrow(3, ctx);
    let clock = create_test_clock(1000, ctx);

    // Create config for outcome 3 (equals outcome_count, invalid)
    let config = market_init_helpers::new_raise_config(
        3, // outcome 3 doesn't exist
        1000000,
        900000,
    );

    let minted_coins = coin::mint_for_testing<TEST_COIN_A>(1000000, ctx);

    // Should abort with EInvalidRaiseConfig
    let stable_coins = proposal_with_market_init::execute_raise_on_proposal<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_COIN_A,
        TEST_COIN_B,
    >(&mut proposal, &mut escrow, minted_coins, config, &clock, ctx);

    // Cleanup (won't reach here)
    coin::burn_for_testing(stable_coins);
    clock::destroy_for_testing(clock);
    proposal::destroy_for_testing(proposal);
    test_utils::destroy(escrow);
    test::end(scenario);
}

// === Batch 2: Conditional Buyback Validation Tests ===

#[test]
#[expected_failure(abort_code = proposal_with_market_init::EInvalidBuybackConfig)]
fun test_execute_buyback_invalid_outcome_count_too_few() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Create proposal with 3 outcomes
    let mut proposal = create_test_proposal(3, ctx);
    let mut escrow = create_test_escrow(3, ctx);
    let clock = create_test_clock(1000, ctx);

    // Create config with only 2 outcomes (mismatched)
    let config = market_init_helpers::new_buyback_config(
        vector[0, 500000], // Only 2 outcomes
        vector[0, 450000],
    );

    let withdrawn_stable = coin::mint_for_testing<TEST_COIN_B>(500000, ctx);

    // Should abort with EInvalidBuybackConfig
    let mut asset_coins = proposal_with_market_init::execute_buyback_on_proposal<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_COIN_A,
        TEST_COIN_B,
    >(&mut proposal, &mut escrow, withdrawn_stable, config, &clock, ctx);

    // Cleanup (won't reach here)
    while (!asset_coins.is_empty()) {
        coin::burn_for_testing(asset_coins.pop_back());
    };
    asset_coins.destroy_empty();
    clock::destroy_for_testing(clock);
    proposal::destroy_for_testing(proposal);
    test_utils::destroy(escrow);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_with_market_init::EInvalidBuybackConfig)]
fun test_execute_buyback_invalid_outcome_count_too_many() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Create proposal with 2 outcomes
    let mut proposal = create_test_proposal(2, ctx);
    let mut escrow = create_test_escrow(2, ctx);
    let clock = create_test_clock(1000, ctx);

    // Create config with 3 outcomes (mismatched)
    let config = market_init_helpers::new_buyback_config(
        vector[0, 500000, 300000], // 3 outcomes
        vector[0, 450000, 270000],
    );

    let withdrawn_stable = coin::mint_for_testing<TEST_COIN_B>(800000, ctx);

    // Should abort with EInvalidBuybackConfig
    let mut asset_coins = proposal_with_market_init::execute_buyback_on_proposal<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_COIN_A,
        TEST_COIN_B,
    >(&mut proposal, &mut escrow, withdrawn_stable, config, &clock, ctx);

    // Cleanup (won't reach here)
    while (!asset_coins.is_empty()) {
        coin::burn_for_testing(asset_coins.pop_back());
    };
    asset_coins.destroy_empty();
    clock::destroy_for_testing(clock);
    proposal::destroy_for_testing(proposal);
    test_utils::destroy(escrow);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_with_market_init::EInvalidBuybackConfig)]
fun test_execute_buyback_invalid_single_outcome_proposal() {
    let mut scenario = test::begin(ALICE);
    let ctx = test::ctx(&mut scenario);

    // Create proposal with 1 outcome
    let mut proposal = create_test_proposal(1, ctx);
    let mut escrow = create_test_escrow(1, ctx);
    let clock = create_test_clock(1000, ctx);

    // Create config for 2 outcomes
    let config = market_init_helpers::new_buyback_config(
        vector[0, 500000],
        vector[0, 450000],
    );

    let withdrawn_stable = coin::mint_for_testing<TEST_COIN_B>(500000, ctx);

    // Should abort with EInvalidBuybackConfig
    let mut asset_coins = proposal_with_market_init::execute_buyback_on_proposal<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_COIN_A,
        TEST_COIN_B,
    >(&mut proposal, &mut escrow, withdrawn_stable, config, &clock, ctx);

    // Cleanup (won't reach here)
    while (!asset_coins.is_empty()) {
        coin::burn_for_testing(asset_coins.pop_back());
    };
    asset_coins.destroy_empty();
    clock::destroy_for_testing(clock);
    proposal::destroy_for_testing(proposal);
    test_utils::destroy(escrow);
    test::end(scenario);
}

// === Summary of Batch 2 ===
// Tests: 6/6 passing (3 raise validation + 3 buyback validation)
// Coverage:
// - execute_raise_on_proposal: validation failures (outcome too high, outcome zero, boundary)
// - execute_buyback_on_proposal: validation failures (too few outcomes, too many, single outcome)

// === Final Summary ===
// Total Tests: 13/13 passing
//
// Coverage Summary:
//
// merge_asset_coins (7 tests):
// - Empty vector → zero coin
// - Single coin → returned as-is
// - Multiple coins → properly merged
// - Zero-value coins → handled correctly
// - Large amounts → no overflow
//
// execute_raise_on_proposal (3 tests):
// - Invalid outcome (too high) → EInvalidRaiseConfig
// - Invalid outcome (zero/REJECT) → EInvalidRaiseConfig
// - Invalid outcome (at boundary) → EInvalidRaiseConfig
//
// execute_buyback_on_proposal (3 tests):
// - Too few outcomes in config → EInvalidBuybackConfig
// - Too many outcomes in config → EInvalidBuybackConfig
// - Mismatched single outcome → EInvalidBuybackConfig
//
// Note: Valid execution paths tested via market_init_strategies module
// This module focuses on validation wrapper logic
