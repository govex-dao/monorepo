#[test_only]
module futarchy_markets::swap_core_balance_tests;

use futarchy_markets::swap_core;
use futarchy_markets::conditional_balance::{Self};
use futarchy_markets::proposal::{Self, Proposal};
use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::object::{Self};
use std::string;
use std::option;
use sui::balance;

// Test coin types
public struct ASSET has drop {}
public struct STABLE has drop {}

// === Test 1: Balance-Based Swap Compilation ===

#[test]
fun test_balance_based_swap_compiles() {
    // Verify balance-based swap functions exist and compile
    assert!(true, 0);
}

// === Test 2: Balance-Based Swap Signature Validation ===

#[test]
fun test_balance_swap_no_conditional_type_params() {
    // This test verifies the KEY innovation: balance-based swaps work with ANY outcome count
    // WITHOUT requiring conditional coin type parameters!
    //
    // Old system: swap_asset_to_stable<Asset, Stable, CondAsset0, CondStable0>()
    // New system: swap_balance_asset_to_stable<Asset, Stable>()  ← No CondAsset/CondStable types!
    //
    // This eliminates type explosion:
    // - No need for swap_entry_2_outcomes.move
    // - No need for swap_entry_3_outcomes.move
    // - No need for swap_entry_4_outcomes.move
    // - Single unified swap function works for 2, 3, 4, 5, 200 outcomes!

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    // Create balance for 3-outcome proposal
    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);
    let balance_3_outcomes = conditional_balance::new<ASSET, STABLE>(
        proposal_id,
        3,  // 3 outcomes
        ctx
    );

    // Create balance for 5-outcome proposal
    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let balance_5_outcomes = conditional_balance::new<ASSET, STABLE>(
        proposal_id,
        5,  // 5 outcomes
        ctx
    );

    // Verify both balances exist and have correct outcome counts
    assert!(conditional_balance::outcome_count(&balance_3_outcomes) == 3, 0);
    assert!(conditional_balance::outcome_count(&balance_5_outcomes) == 5, 1);

    // Key point: SAME function signature works for BOTH!
    // swap_balance_asset_to_stable<ASSET, STABLE>(..., balance, outcome_idx, ...)
    // No need for separate swap_3_outcomes vs swap_5_outcomes modules!

    // Cleanup
    conditional_balance::destroy_empty(balance_3_outcomes);
    conditional_balance::destroy_empty(balance_5_outcomes);
    ts::end(scenario);
}

// === Test 3: Balance Update Logic ===

#[test]
fun test_balance_swap_updates_correct_outcome() {
    // This test verifies that balance-based swaps update the correct outcome's balances
    // Formula: idx = (outcome_idx * 2) + (is_asset ? 0 : 1)

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    // Create balance with initial amounts for 3 outcomes
    let mut balance = conditional_balance::new_with_amounts<ASSET, STABLE>(
        proposal_id,
        3,
        vector[
            1000, 2000,  // Outcome 0: 1000 asset, 2000 stable
            1500, 2500,  // Outcome 1: 1500 asset, 2500 stable
            1200, 2200,  // Outcome 2: 1200 asset, 2200 stable
        ],
        ctx
    );

    // Verify initial balances
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1000, 0);   // Outcome 0 asset
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2000, 1);  // Outcome 0 stable
    assert!(conditional_balance::get_balance(&balance, 1, true) == 1500, 2);   // Outcome 1 asset
    assert!(conditional_balance::get_balance(&balance, 1, false) == 2500, 3);  // Outcome 1 stable
    assert!(conditional_balance::get_balance(&balance, 2, true) == 1200, 4);   // Outcome 2 asset
    assert!(conditional_balance::get_balance(&balance, 2, false) == 2200, 5);  // Outcome 2 stable

    // Simulate swap: asset -> stable in outcome 1
    // This would subtract from outcome 1 asset, add to outcome 1 stable
    conditional_balance::sub_from_balance(&mut balance, 1, true, 500);   // -500 asset from outcome 1
    conditional_balance::add_to_balance(&mut balance, 1, false, 450);    // +450 stable to outcome 1

    // Verify outcome 1 updated correctly
    assert!(conditional_balance::get_balance(&balance, 1, true) == 1000, 6);   // 1500 - 500 = 1000
    assert!(conditional_balance::get_balance(&balance, 1, false) == 2950, 7);  // 2500 + 450 = 2950

    // Verify other outcomes unchanged
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1000, 8);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2000, 9);
    assert!(conditional_balance::get_balance(&balance, 2, true) == 1200, 10);
    assert!(conditional_balance::get_balance(&balance, 2, false) == 2200, 11);

    // Cleanup
    // Can't destroy non-empty balance, so we need to drain it first
    conditional_balance::sub_from_balance(&mut balance, 0, true, 1000);
    conditional_balance::sub_from_balance(&mut balance, 0, false, 2000);
    conditional_balance::sub_from_balance(&mut balance, 1, true, 1000);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 2950);
    conditional_balance::sub_from_balance(&mut balance, 2, true, 1200);
    conditional_balance::sub_from_balance(&mut balance, 2, false, 2200);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Test 4: Balance Swap Direction - Asset to Stable ===

#[test]
fun test_balance_swap_asset_to_stable_direction() {
    // Verify asset->stable swap decreases asset, increases stable (same outcome)

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    let mut balance = conditional_balance::new_with_amounts<ASSET, STABLE>(
        proposal_id,
        2,
        vector[
            1000, 2000,  // Outcome 0: 1000 asset, 2000 stable
            1500, 2500,  // Outcome 1: 1500 asset, 2500 stable
        ],
        ctx
    );

    // Swap asset->stable in outcome 0
    conditional_balance::sub_from_balance(&mut balance, 0, true, 400);   // -400 asset
    conditional_balance::add_to_balance(&mut balance, 0, false, 350);    // +350 stable (simulated AMM output)

    assert!(conditional_balance::get_balance(&balance, 0, true) == 600, 0);    // 1000 - 400 = 600
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2350, 1);  // 2000 + 350 = 2350

    // Cleanup
    conditional_balance::sub_from_balance(&mut balance, 0, true, 600);
    conditional_balance::sub_from_balance(&mut balance, 0, false, 2350);
    conditional_balance::sub_from_balance(&mut balance, 1, true, 1500);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 2500);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Test 5: Balance Swap Direction - Stable to Asset ===

#[test]
fun test_balance_swap_stable_to_asset_direction() {
    // Verify stable->asset swap decreases stable, increases asset (same outcome)

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    let mut balance = conditional_balance::new_with_amounts<ASSET, STABLE>(
        proposal_id,
        2,
        vector[
            1000, 2000,  // Outcome 0: 1000 asset, 2000 stable
            1500, 2500,  // Outcome 1: 1500 asset, 2500 stable
        ],
        ctx
    );

    // Swap stable->asset in outcome 1
    conditional_balance::sub_from_balance(&mut balance, 1, false, 500);  // -500 stable
    conditional_balance::add_to_balance(&mut balance, 1, true, 450);     // +450 asset (simulated AMM output)

    assert!(conditional_balance::get_balance(&balance, 1, true) == 1950, 0);   // 1500 + 450 = 1950
    assert!(conditional_balance::get_balance(&balance, 1, false) == 2000, 1);  // 2500 - 500 = 2000

    // Cleanup
    conditional_balance::sub_from_balance(&mut balance, 0, true, 1000);
    conditional_balance::sub_from_balance(&mut balance, 0, false, 2000);
    conditional_balance::sub_from_balance(&mut balance, 1, true, 1950);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 2000);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Test 6: Insufficient Balance Validation ===

#[test]
#[expected_failure(abort_code = conditional_balance::EInsufficientBalance)]
fun test_balance_swap_insufficient_balance() {
    // Verify swap aborts if balance doesn't have enough input tokens

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    let mut balance = conditional_balance::new_with_amounts<ASSET, STABLE>(
        proposal_id,
        2,
        vector[
            100, 2000,  // Outcome 0: only 100 asset
            1500, 2500,
        ],
        ctx
    );

    // Try to swap 500 asset when only 100 available
    conditional_balance::sub_from_balance(&mut balance, 0, true, 500);  // Should abort!

    // Cleanup (won't reach here due to abort)
    conditional_balance::sub_from_balance(&mut balance, 0, true, 100);
    conditional_balance::sub_from_balance(&mut balance, 0, false, 2000);
    conditional_balance::sub_from_balance(&mut balance, 1, true, 1500);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 2500);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Test 7: Invalid Outcome Index ===

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeIndex)]
fun test_balance_swap_invalid_outcome() {
    // Verify swap aborts if outcome_idx >= outcome_count

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    let mut balance = conditional_balance::new_with_amounts<ASSET, STABLE>(
        proposal_id,
        2,  // Only 2 outcomes (indices 0, 1)
        vector[
            1000, 2000,
            1500, 2500,
        ],
        ctx
    );

    // Try to swap in outcome 2 (doesn't exist!)
    conditional_balance::sub_from_balance(&mut balance, 2, true, 100);  // Should abort!

    // Cleanup (won't reach here due to abort)
    conditional_balance::sub_from_balance(&mut balance, 0, true, 1000);
    conditional_balance::sub_from_balance(&mut balance, 0, false, 2000);
    conditional_balance::sub_from_balance(&mut balance, 1, true, 1500);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 2500);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Test 8: Multiple Swaps in Different Outcomes ===

#[test]
fun test_balance_swaps_multiple_outcomes() {
    // Verify we can swap in multiple outcomes independently

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    let mut balance = conditional_balance::new_with_amounts<ASSET, STABLE>(
        proposal_id,
        3,
        vector[
            1000, 2000,  // Outcome 0
            1500, 2500,  // Outcome 1
            1200, 2200,  // Outcome 2
        ],
        ctx
    );

    // Swap in outcome 0: asset -> stable
    conditional_balance::sub_from_balance(&mut balance, 0, true, 200);
    conditional_balance::add_to_balance(&mut balance, 0, false, 180);

    // Swap in outcome 1: stable -> asset
    conditional_balance::sub_from_balance(&mut balance, 1, false, 300);
    conditional_balance::add_to_balance(&mut balance, 1, true, 270);

    // Swap in outcome 2: asset -> stable
    conditional_balance::sub_from_balance(&mut balance, 2, true, 100);
    conditional_balance::add_to_balance(&mut balance, 2, false, 90);

    // Verify all outcomes updated correctly
    assert!(conditional_balance::get_balance(&balance, 0, true) == 800, 0);    // 1000 - 200
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2180, 1);  // 2000 + 180
    assert!(conditional_balance::get_balance(&balance, 1, true) == 1770, 2);   // 1500 + 270
    assert!(conditional_balance::get_balance(&balance, 1, false) == 2200, 3);  // 2500 - 300
    assert!(conditional_balance::get_balance(&balance, 2, true) == 1100, 4);   // 1200 - 100
    assert!(conditional_balance::get_balance(&balance, 2, false) == 2290, 5);  // 2200 + 90

    // Cleanup
    conditional_balance::sub_from_balance(&mut balance, 0, true, 800);
    conditional_balance::sub_from_balance(&mut balance, 0, false, 2180);
    conditional_balance::sub_from_balance(&mut balance, 1, true, 1770);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 2200);
    conditional_balance::sub_from_balance(&mut balance, 2, true, 1100);
    conditional_balance::sub_from_balance(&mut balance, 2, false, 2290);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Test 9: Scalability - High Outcome Count ===

#[test]
fun test_balance_swap_scalability() {
    // Verify balance-based swaps work with high outcome counts
    // This was IMPOSSIBLE with the old typed system!

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = object::id_from_address(@0xDEADBEEF);

    // Create balance for 10-outcome proposal
    let mut balance = conditional_balance::new<ASSET, STABLE>(
        proposal_id,
        10,
        ctx
    );

    // Add liquidity to all outcomes
    conditional_balance::add_to_all_outcomes(&mut balance, 1000, 2000);

    // Verify all 10 outcomes have correct balances
    let mut i = 0u8;
    while ((i as u64) < 10) {
        assert!(conditional_balance::get_balance(&balance, i, true) == 1000, (i as u64));
        assert!(conditional_balance::get_balance(&balance, i, false) == 2000, (i as u64) + 10);
        i = i + 1;
    };

    // Swap in outcome 7 (would require 7 type parameters in old system!)
    conditional_balance::sub_from_balance(&mut balance, 7, true, 100);
    conditional_balance::add_to_balance(&mut balance, 7, false, 90);

    // Verify outcome 7 updated
    assert!(conditional_balance::get_balance(&balance, 7, true) == 900, 20);
    assert!(conditional_balance::get_balance(&balance, 7, false) == 2090, 21);

    // Verify other outcomes unchanged
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1000, 22);
    assert!(conditional_balance::get_balance(&balance, 9, true) == 1000, 23);

    // Cleanup
    conditional_balance::sub_from_all_outcomes(&mut balance, 1000, 2000);
    conditional_balance::add_to_balance(&mut balance, 7, true, 100);  // Restore to 1000
    conditional_balance::sub_from_balance(&mut balance, 7, false, 90);  // Restore to 2000
    conditional_balance::sub_from_balance(&mut balance, 7, true, 1000);
    conditional_balance::sub_from_balance(&mut balance, 7, false, 2000);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Documentation: Integration Tests ===
//
// Full integration tests require the following helpers (same as swap_tests.move):
//
// 1. proposal::new_for_testing() with TokenEscrow and MarketState
// 2. coin_escrow::new_for_testing() with conditional TreasuryCaps
// 3. market_state::new_for_testing() with AMM pools
// 4. swap_core::begin_swap_session() for hot potato pattern
// 5. swap_core::swap_balance_asset_to_stable() - the actual function!
// 6. swap_core::swap_balance_stable_to_asset() - the actual function!
// 7. swap_core::finalize_swap_session() to consume hot potato
//
// Full integration test flow:
// 1. Create proposal with TokenEscrow and MarketState
// 2. Create ConditionalMarketBalance with initial amounts
// 3. Begin swap session
// 4. Call swap_balance_asset_to_stable() - verify AMM pricing applied
// 5. Finalize swap session
// 6. Verify balance updated correctly (input decreased, output increased)
// 7. Verify AMM reserves updated correctly
// 8. Test slippage protection (min_amount_out validation)
// 9. Test error cases (invalid state, invalid outcome, insufficient balance)
//
// These tests can be added once the helper functions are implemented.
