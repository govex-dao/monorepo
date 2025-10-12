#[test_only]
module futarchy_markets::conditional_balance_tests;

use futarchy_markets::conditional_balance;
use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self};

// Test types
public struct ASSET has drop {}
public struct STABLE has drop {}

// === Test Helpers ===

fun setup_test(): Scenario {
    let mut scenario = ts::begin(@0xCAFE);
    scenario
}

fun create_test_proposal_id(): sui::object::ID {
    sui::object::id_from_address(@0xABCD)
}

// === Creation Tests ===

#[test]
fun test_new_balance_empty() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // Create balance for 3 outcomes
    let balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // Verify structure
    assert!(conditional_balance::outcome_count(&balance) == 3, 0);
    assert!(conditional_balance::proposal_id(&balance) == proposal_id, 1);

    // Verify all balances are zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 2);   // out0 asset
    assert!(conditional_balance::get_balance(&balance, 0, false) == 0, 3);  // out0 stable
    assert!(conditional_balance::get_balance(&balance, 1, true) == 0, 4);   // out1 asset
    assert!(conditional_balance::get_balance(&balance, 1, false) == 0, 5);  // out1 stable
    assert!(conditional_balance::get_balance(&balance, 2, true) == 0, 6);   // out2 asset
    assert!(conditional_balance::get_balance(&balance, 2, false) == 0, 7);  // out2 stable

    // Should be empty
    assert!(conditional_balance::is_empty(&balance), 8);

    // Clean up
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
fun test_new_balance_different_outcome_counts() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // Test 2 outcomes
    let balance_2 = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);
    assert!(conditional_balance::outcome_count(&balance_2) == 2, 0);
    conditional_balance::destroy_empty(balance_2);

    // Test 5 outcomes
    let balance_5 = conditional_balance::new<ASSET, STABLE>(proposal_id, 5, ctx);
    assert!(conditional_balance::outcome_count(&balance_5) == 5, 1);
    conditional_balance::destroy_empty(balance_5);

    ts::end(scenario);
}

// === Balance Access Tests ===

#[test]
fun test_set_and_get_balance() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Set balances
    conditional_balance::set_balance(&mut balance, 0, true, 100);   // out0 asset = 100
    conditional_balance::set_balance(&mut balance, 0, false, 50);   // out0 stable = 50
    conditional_balance::set_balance(&mut balance, 1, true, 75);    // out1 asset = 75
    conditional_balance::set_balance(&mut balance, 1, false, 80);   // out1 stable = 80

    // Verify balances
    assert!(conditional_balance::get_balance(&balance, 0, true) == 100, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 50, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 75, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 80, 3);

    // Should not be empty
    assert!(!conditional_balance::is_empty(&balance), 4);

    // Clear balances for cleanup
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
fun test_add_to_balance() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Add multiple times to same balance
    conditional_balance::add_to_balance(&mut balance, 0, true, 100);
    conditional_balance::add_to_balance(&mut balance, 0, true, 50);
    conditional_balance::add_to_balance(&mut balance, 0, true, 25);

    // Should sum correctly
    assert!(conditional_balance::get_balance(&balance, 0, true) == 175, 0);

    // Add to different outcomes
    conditional_balance::add_to_balance(&mut balance, 1, false, 200);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 200, 1);

    // Clean up
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
fun test_sub_from_balance() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Set initial balance
    conditional_balance::set_balance(&mut balance, 0, true, 1000);

    // Subtract multiple times
    conditional_balance::sub_from_balance(&mut balance, 0, true, 100);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 900, 0);

    conditional_balance::sub_from_balance(&mut balance, 0, true, 400);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 500, 1);

    conditional_balance::sub_from_balance(&mut balance, 0, true, 500);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 2);

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInsufficientBalance)]
fun test_sub_from_balance_insufficient() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Set balance to 100
    conditional_balance::set_balance(&mut balance, 0, true, 100);

    // Try to subtract 200 (should fail)
    conditional_balance::sub_from_balance(&mut balance, 0, true, 200);

    // Cleanup (won't reach here)
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeIndex)]
fun test_invalid_outcome_index() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Try to access outcome 3 when only 2 outcomes exist (should fail)
    conditional_balance::get_balance(&balance, 3, true);

    // Cleanup (won't reach here)
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Utility Function Tests ===

#[test]
fun test_find_min_balance() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // Set different asset balances for each outcome
    conditional_balance::set_balance(&mut balance, 0, true, 100);
    conditional_balance::set_balance(&mut balance, 1, true, 75);   // Minimum
    conditional_balance::set_balance(&mut balance, 2, true, 150);

    // Find minimum asset balance
    let min_asset = conditional_balance::find_min_balance(&balance, true);
    assert!(min_asset == 75, 0);

    // Set different stable balances
    conditional_balance::set_balance(&mut balance, 0, false, 200);
    conditional_balance::set_balance(&mut balance, 1, false, 50);  // Minimum
    conditional_balance::set_balance(&mut balance, 2, false, 100);

    // Find minimum stable balance
    let min_stable = conditional_balance::find_min_balance(&balance, false);
    assert!(min_stable == 50, 1);

    // Clean up
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::set_balance(&mut balance, 2, false, 0);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
fun test_find_min_balance_all_equal() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 4, ctx);

    // Set all asset balances to same value
    conditional_balance::set_balance(&mut balance, 0, true, 100);
    conditional_balance::set_balance(&mut balance, 1, true, 100);
    conditional_balance::set_balance(&mut balance, 2, true, 100);
    conditional_balance::set_balance(&mut balance, 3, true, 100);

    let min = conditional_balance::find_min_balance(&balance, true);
    assert!(min == 100, 0);

    // Clean up
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);
    conditional_balance::set_balance(&mut balance, 3, true, 0);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
fun test_is_empty() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Should be empty initially
    assert!(conditional_balance::is_empty(&balance), 0);

    // Add balance
    conditional_balance::set_balance(&mut balance, 0, true, 100);

    // Should not be empty
    assert!(!conditional_balance::is_empty(&balance), 1);

    // Clear balance
    conditional_balance::set_balance(&mut balance, 0, true, 0);

    // Should be empty again
    assert!(conditional_balance::is_empty(&balance), 2);

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::ENotEmpty)]
fun test_destroy_non_empty() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Set non-zero balance
    conditional_balance::set_balance(&mut balance, 0, true, 100);

    // Try to destroy (should fail)
    conditional_balance::destroy_empty(balance);

    ts::end(scenario);
}

// === Index Calculation Tests ===

#[test]
fun test_balance_indexing() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // Verify index calculation by setting and getting
    // Index formula: idx = (outcome_idx * 2) + (is_asset ? 0 : 1)

    // Outcome 0: asset=idx0, stable=idx1
    conditional_balance::set_balance(&mut balance, 0, true, 10);
    conditional_balance::set_balance(&mut balance, 0, false, 11);

    // Outcome 1: asset=idx2, stable=idx3
    conditional_balance::set_balance(&mut balance, 1, true, 20);
    conditional_balance::set_balance(&mut balance, 1, false, 21);

    // Outcome 2: asset=idx4, stable=idx5
    conditional_balance::set_balance(&mut balance, 2, true, 30);
    conditional_balance::set_balance(&mut balance, 2, false, 31);

    // Verify correct indexing
    assert!(conditional_balance::get_balance(&balance, 0, true) == 10, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 11, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 20, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 21, 3);
    assert!(conditional_balance::get_balance(&balance, 2, true) == 30, 4);
    assert!(conditional_balance::get_balance(&balance, 2, false) == 31, 5);

    // Clean up
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);
    conditional_balance::set_balance(&mut balance, 2, false, 0);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Quantum Liquidity Pattern Test ===

#[test]
fun test_quantum_liquidity_pattern() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // Simulate quantum mint: same amount added to ALL outcomes
    let quantum_amount = 1000u64;

    let mut i = 0u8;
    while (i < 3) {
        conditional_balance::add_to_balance(&mut balance, i, true, quantum_amount);
        conditional_balance::add_to_balance(&mut balance, i, false, quantum_amount);
        i = i + 1;
    };

    // Verify all outcomes have same amount
    assert!(conditional_balance::get_balance(&balance, 0, true) == quantum_amount, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == quantum_amount, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == quantum_amount, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == quantum_amount, 3);
    assert!(conditional_balance::get_balance(&balance, 2, true) == quantum_amount, 4);
    assert!(conditional_balance::get_balance(&balance, 2, false) == quantum_amount, 5);

    // Simulate swaps (different outcomes end up with different amounts)
    conditional_balance::sub_from_balance(&mut balance, 0, true, 100);  // 1000 - 100 = 900
    conditional_balance::sub_from_balance(&mut balance, 1, true, 200);  // 1000 - 200 = 800
    conditional_balance::sub_from_balance(&mut balance, 2, true, 50);   // 1000 - 50 = 950

    // Find minimum (complete set size)
    let min = conditional_balance::find_min_balance(&balance, true);
    assert!(min == 800, 6);  // outcome 0 = 900, outcome 1 = 800, outcome 2 = 950 -> min is 800

    // Clean up - zero out all balances
    i = 0u8;
    while (i < 3) {
        conditional_balance::set_balance(&mut balance, i, true, 0);
        conditional_balance::set_balance(&mut balance, i, false, 0);
        i = i + 1;
    };

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Getters Test ===

#[test]
fun test_getters() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 4, ctx);

    // Test getters
    assert!(conditional_balance::proposal_id(&balance) == proposal_id, 0);
    assert!(conditional_balance::outcome_count(&balance) == 4, 1);
    assert!(conditional_balance::version(&balance) == 1, 2);

    // ID should be non-zero
    let id = conditional_balance::id(&balance);
    assert!(sui::object::id_to_address(&id) != @0x0, 3);

    // Borrow balances vector
    let balances_vec = conditional_balance::borrow_balances(&balance);
    assert!(vector::length(balances_vec) == 8, 4);  // 4 outcomes * 2 types

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Boundary Tests ===

#[test]
fun test_min_outcomes() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // 2 outcomes is minimum (binary market)
    let balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);
    assert!(conditional_balance::outcome_count(&balance) == 2, 0);
    conditional_balance::destroy_empty(balance);

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeCount)]
fun test_outcome_count_zero() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // 0 outcomes should fail
    conditional_balance::new<ASSET, STABLE>(proposal_id, 0, ctx);

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeCount)]
fun test_outcome_count_one() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // 1 outcome should fail (need at least 2 for market)
    conditional_balance::new<ASSET, STABLE>(proposal_id, 1, ctx);

    ts::end(scenario);
}

#[test]
fun test_max_outcomes() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // 200 outcomes is maximum (protocol limit)
    let balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 200, ctx);
    assert!(conditional_balance::outcome_count(&balance) == 200, 0);

    // Should have 400 balance slots (200 outcomes * 2 types)
    let balances_vec = conditional_balance::borrow_balances(&balance);
    assert!(vector::length(balances_vec) == 400, 1);

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EOutcomeCountExceedsMax)]
fun test_outcome_count_exceeds_max() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    // 201 outcomes should fail (exceeds MAX_OUTCOMES)
    conditional_balance::new<ASSET, STABLE>(proposal_id, 201, ctx);

    ts::end(scenario);
}

#[test]
fun test_u64_max_balance() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 2, ctx);

    // Set to u64 max value
    let max_u64 = 18446744073709551615u64;
    conditional_balance::set_balance(&mut balance, 0, true, max_u64);

    // Should be able to read it back
    assert!(conditional_balance::get_balance(&balance, 0, true) == max_u64, 0);

    // Clean up
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

// === Batch Operations Tests ===

#[test]
fun test_add_to_all_outcomes() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // Add same amount to all outcomes at once
    conditional_balance::add_to_all_outcomes(&mut balance, 1000, 2000);

    // Verify all outcomes have same amounts
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1000, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 1000, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 2000, 3);
    assert!(conditional_balance::get_balance(&balance, 2, true) == 1000, 4);
    assert!(conditional_balance::get_balance(&balance, 2, false) == 2000, 5);

    // Clean up
    conditional_balance::sub_from_all_outcomes(&mut balance, 1000, 2000);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
fun test_sub_from_all_outcomes() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // First add to all outcomes
    conditional_balance::add_to_all_outcomes(&mut balance, 1000, 2000);

    // Then subtract from all
    conditional_balance::sub_from_all_outcomes(&mut balance, 500, 1000);

    // Verify remaining balances
    assert!(conditional_balance::get_balance(&balance, 0, true) == 500, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 1000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 500, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 1000, 3);
    assert!(conditional_balance::get_balance(&balance, 2, true) == 500, 4);
    assert!(conditional_balance::get_balance(&balance, 2, false) == 1000, 5);

    // Clean up
    conditional_balance::sub_from_all_outcomes(&mut balance, 500, 1000);
    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInsufficientBalance)]
fun test_sub_from_all_outcomes_insufficient() {
    let mut scenario = setup_test();
    let ctx = ts::ctx(&mut scenario);
    let proposal_id = create_test_proposal_id();

    let mut balance = conditional_balance::new<ASSET, STABLE>(proposal_id, 3, ctx);

    // Set uneven balances
    conditional_balance::set_balance(&mut balance, 0, true, 1000);
    conditional_balance::set_balance(&mut balance, 1, true, 500);   // This will fail
    conditional_balance::set_balance(&mut balance, 2, true, 1000);

    // Try to subtract 600 from all (should fail because outcome 1 only has 500)
    conditional_balance::sub_from_all_outcomes(&mut balance, 600, 0);

    conditional_balance::destroy_empty(balance);
    ts::end(scenario);
}
