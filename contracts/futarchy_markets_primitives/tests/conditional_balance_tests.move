#[test_only]
module futarchy_markets_primitives::conditional_balance_tests;

use futarchy_markets_primitives::conditional_balance;
use sui::{
    test_scenario as ts,
    test_utils::destroy,
    sui::SUI,
};
use std::string;

// Test coin types
public struct USDC has drop {}

const ADMIN: address = @0xAD;

// === Test Helpers ===

fun start(): ts::Scenario {
    ts::begin(ADMIN)
}

fun end(scenario: ts::Scenario) {
    let effects = ts::end(scenario);
    destroy(effects);
}

// === Creation Tests ===

#[test]
fun test_new_balance_minimal_outcomes() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xAAA);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2, // MIN_OUTCOMES
        ts::ctx(&mut scenario)
    );

    // Verify initialization
    assert!(conditional_balance::outcome_count(&balance) == 2, 0);
    assert!(conditional_balance::market_id(&balance) == market_id, 1);
    assert!(conditional_balance::is_empty(&balance), 2);

    // Verify all balances are zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 3);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 0, 4);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 0, 5);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 0, 6);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_new_balance_many_outcomes() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xBBB);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        10,
        ts::ctx(&mut scenario)
    );

    assert!(conditional_balance::outcome_count(&balance) == 10, 0);
    assert!(conditional_balance::is_empty(&balance), 1);

    // Verify vector size is correct (10 outcomes * 2 types = 20 slots)
    let balances_ref = conditional_balance::borrow_balances(&balance);
    assert!(balances_ref.length() == 20, 2);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_new_balance_max_outcomes() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xCCC);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        200, // MAX_OUTCOMES
        ts::ctx(&mut scenario)
    );

    assert!(conditional_balance::outcome_count(&balance) == 200, 0);

    // Verify vector size is correct (200 outcomes * 2 types = 400 slots)
    let balances_ref = conditional_balance::borrow_balances(&balance);
    assert!(balances_ref.length() == 400, 1);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeCount)]
fun test_new_balance_too_few_outcomes_fails() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xDDD);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        1, // Below MIN_OUTCOMES (2)
        ts::ctx(&mut scenario)
    );

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EOutcomeCountExceedsMax)]
fun test_new_balance_too_many_outcomes_fails() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xEEE);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        201, // Above MAX_OUTCOMES (200)
        ts::ctx(&mut scenario)
    );

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === Balance Operation Tests ===

#[test]
fun test_set_and_get_balance() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x111);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // Set various balances
    conditional_balance::set_balance(&mut balance, 0, true, 1000);  // out0 asset
    conditional_balance::set_balance(&mut balance, 0, false, 2000); // out0 stable
    conditional_balance::set_balance(&mut balance, 1, true, 3000);  // out1 asset
    conditional_balance::set_balance(&mut balance, 1, false, 4000); // out1 stable
    conditional_balance::set_balance(&mut balance, 2, true, 5000);  // out2 asset
    conditional_balance::set_balance(&mut balance, 2, false, 6000); // out2 stable

    // Verify all balances
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1000, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 3000, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 4000, 3);
    assert!(conditional_balance::get_balance(&balance, 2, true) == 5000, 4);
    assert!(conditional_balance::get_balance(&balance, 2, false) == 6000, 5);

    // Clear all balances for destruction
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);
    conditional_balance::set_balance(&mut balance, 2, false, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_add_to_balance() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x222);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Add to balance multiple times
    conditional_balance::add_to_balance(&mut balance, 0, true, 100);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 100, 0);

    conditional_balance::add_to_balance(&mut balance, 0, true, 50);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 150, 1);

    conditional_balance::add_to_balance(&mut balance, 0, true, 850);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1000, 2);

    // Clear for destruction
    conditional_balance::set_balance(&mut balance, 0, true, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_sub_from_balance() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x333);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set initial balance
    conditional_balance::set_balance(&mut balance, 0, false, 1000);

    // Subtract multiple times
    conditional_balance::sub_from_balance(&mut balance, 0, false, 300);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 700, 0);

    conditional_balance::sub_from_balance(&mut balance, 0, false, 200);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 500, 1);

    conditional_balance::sub_from_balance(&mut balance, 0, false, 500);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 0, 2);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInsufficientBalance)]
fun test_sub_from_balance_insufficient_fails() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x444);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set balance to 100
    conditional_balance::set_balance(&mut balance, 0, true, 100);

    // Try to subtract 101 - should fail
    conditional_balance::sub_from_balance(&mut balance, 0, true, 101);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeIndex)]
fun test_get_balance_invalid_outcome_fails() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x555);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2, // Only outcomes 0 and 1 valid
        ts::ctx(&mut scenario)
    );

    // Try to access outcome 2 - should fail
    let _ = conditional_balance::get_balance(&balance, 2, true);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidOutcomeIndex)]
fun test_set_balance_invalid_outcome_fails() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x666);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3, // Only outcomes 0, 1, 2 valid
        ts::ctx(&mut scenario)
    );

    // Try to set outcome 3 - should fail
    conditional_balance::set_balance(&mut balance, 3, true, 1000);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === Index Calculation Tests ===

#[test]
fun test_index_layout_2_outcomes() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x777);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set balances: [out0_asset, out0_stable, out1_asset, out1_stable]
    conditional_balance::set_balance(&mut balance, 0, true, 10);   // idx 0
    conditional_balance::set_balance(&mut balance, 0, false, 20);  // idx 1
    conditional_balance::set_balance(&mut balance, 1, true, 30);   // idx 2
    conditional_balance::set_balance(&mut balance, 1, false, 40);  // idx 3

    // Verify layout via direct vector access
    let balances_ref = conditional_balance::borrow_balances(&balance);
    assert!(*balances_ref.borrow(0) == 10, 0); // out0 asset
    assert!(*balances_ref.borrow(1) == 20, 1); // out0 stable
    assert!(*balances_ref.borrow(2) == 30, 2); // out1 asset
    assert!(*balances_ref.borrow(3) == 40, 3); // out1 stable

    // Clear for destruction
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_index_layout_3_outcomes() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x888);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // Set balances with pattern: outcome_idx * 100 + (is_asset ? 10 : 20)
    conditional_balance::set_balance(&mut balance, 0, true, 10);   // idx 0
    conditional_balance::set_balance(&mut balance, 0, false, 20);  // idx 1
    conditional_balance::set_balance(&mut balance, 1, true, 110);  // idx 2
    conditional_balance::set_balance(&mut balance, 1, false, 120); // idx 3
    conditional_balance::set_balance(&mut balance, 2, true, 210);  // idx 4
    conditional_balance::set_balance(&mut balance, 2, false, 220); // idx 5

    // Verify layout
    let balances_ref = conditional_balance::borrow_balances(&balance);
    assert!(*balances_ref.borrow(0) == 10, 0);
    assert!(*balances_ref.borrow(1) == 20, 1);
    assert!(*balances_ref.borrow(2) == 110, 2);
    assert!(*balances_ref.borrow(3) == 120, 3);
    assert!(*balances_ref.borrow(4) == 210, 4);
    assert!(*balances_ref.borrow(5) == 220, 5);

    // Clear all
    let mut i = 0u8;
    while (i < 3) {
        conditional_balance::set_balance(&mut balance, i, true, 0);
        conditional_balance::set_balance(&mut balance, i, false, 0);
        i = i + 1;
    };

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === find_min_balance Tests ===

#[test]
fun test_find_min_balance_empty() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x999);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // All balances are zero
    assert!(conditional_balance::find_min_balance(&balance, true) == 0, 0);
    assert!(conditional_balance::find_min_balance(&balance, false) == 0, 1);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_find_min_balance_all_equal() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xAAA);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // Set all asset balances to 1000
    conditional_balance::set_balance(&mut balance, 0, true, 1000);
    conditional_balance::set_balance(&mut balance, 1, true, 1000);
    conditional_balance::set_balance(&mut balance, 2, true, 1000);

    assert!(conditional_balance::find_min_balance(&balance, true) == 1000, 0);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_find_min_balance_different_values() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xBBB);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        4,
        ts::ctx(&mut scenario)
    );

    // Set different stable balances: [3000, 1000, 5000, 2000]
    conditional_balance::set_balance(&mut balance, 0, false, 3000);
    conditional_balance::set_balance(&mut balance, 1, false, 1000); // Minimum
    conditional_balance::set_balance(&mut balance, 2, false, 5000);
    conditional_balance::set_balance(&mut balance, 3, false, 2000);

    // Should find minimum (1000)
    assert!(conditional_balance::find_min_balance(&balance, false) == 1000, 0);

    // Clear
    let mut i = 0u8;
    while (i < 4) {
        conditional_balance::set_balance(&mut balance, i, false, 0);
        i = i + 1;
    };

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_find_min_balance_first_is_min() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xCCC);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // First outcome has minimum
    conditional_balance::set_balance(&mut balance, 0, true, 100);  // Minimum
    conditional_balance::set_balance(&mut balance, 1, true, 500);
    conditional_balance::set_balance(&mut balance, 2, true, 1000);

    assert!(conditional_balance::find_min_balance(&balance, true) == 100, 0);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_find_min_balance_last_is_min() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xDDD);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // Last outcome has minimum
    conditional_balance::set_balance(&mut balance, 0, true, 5000);
    conditional_balance::set_balance(&mut balance, 1, true, 3000);
    conditional_balance::set_balance(&mut balance, 2, true, 1000);  // Minimum

    assert!(conditional_balance::find_min_balance(&balance, true) == 1000, 0);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 2, true, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_find_min_balance_asset_vs_stable_independent() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xEEE);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set different mins for asset and stable
    conditional_balance::set_balance(&mut balance, 0, true, 1000);  // Asset min = 1000
    conditional_balance::set_balance(&mut balance, 1, true, 2000);
    conditional_balance::set_balance(&mut balance, 0, false, 5000);
    conditional_balance::set_balance(&mut balance, 1, false, 3000); // Stable min = 3000

    // Asset min should be 1000, stable min should be 3000
    assert!(conditional_balance::find_min_balance(&balance, true) == 1000, 0);
    assert!(conditional_balance::find_min_balance(&balance, false) == 3000, 1);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === Empty Check and Destruction Tests ===

#[test]
fun test_is_empty_on_new_balance() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xFFF);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    assert!(conditional_balance::is_empty(&balance), 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_is_empty_after_setting_and_clearing() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x1111);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Initially empty
    assert!(conditional_balance::is_empty(&balance), 0);

    // Set some balances
    conditional_balance::set_balance(&mut balance, 0, true, 100);
    conditional_balance::set_balance(&mut balance, 1, false, 200);

    // No longer empty
    assert!(!conditional_balance::is_empty(&balance), 1);

    // Clear all balances
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);

    // Empty again
    assert!(conditional_balance::is_empty(&balance), 2);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::ENotEmpty)]
fun test_destroy_non_empty_fails() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x2222);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set a balance
    conditional_balance::set_balance(&mut balance, 0, true, 1000);

    // Try to destroy - should fail because not empty
    conditional_balance::destroy_empty(balance);

    end(scenario);
}

// === Test Helper Tests ===

#[test]
fun test_new_with_amounts_helper() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x3333);

    // Create balance with 2 outcomes (4 slots)
    let initial = vector[100, 200, 300, 400];
    let mut balance = conditional_balance::new_with_amounts<SUI, USDC>(
        market_id,
        2,
        initial,
        ts::ctx(&mut scenario)
    );

    // Verify all balances were set correctly
    assert!(conditional_balance::get_balance(&balance, 0, true) == 100, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 200, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 300, 2);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 400, 3);

    // Clear for destruction
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === Getter Tests ===

#[test]
fun test_getters() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x4444);
    let balance = conditional_balance::new<SUI, USDC>(
        market_id,
        5,
        ts::ctx(&mut scenario)
    );

    // Test market_id getter
    assert!(conditional_balance::market_id(&balance) == market_id, 0);

    // Test outcome_count getter
    assert!(conditional_balance::outcome_count(&balance) == 5, 1);

    // Test id getter (just verify it doesn't crash)
    let balance_id = conditional_balance::id(&balance);
    assert!(balance_id != object::id_from_address(@0x0), 2);

    // Test borrow_balances getter
    let balances_ref = conditional_balance::borrow_balances(&balance);
    assert!(balances_ref.length() == 10, 3); // 5 outcomes * 2 types

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === Edge Case Tests ===

#[test]
fun test_add_zero_amount() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x6666);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set initial balance
    conditional_balance::set_balance(&mut balance, 0, true, 100);

    // Add zero - should not change balance
    conditional_balance::add_to_balance(&mut balance, 0, true, 0);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 100, 0);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_sub_zero_amount() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x7777);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set initial balance
    conditional_balance::set_balance(&mut balance, 0, false, 500);

    // Subtract zero - should not change balance
    conditional_balance::sub_from_balance(&mut balance, 0, false, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 500, 0);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, false, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_add_to_max_value_near_overflow() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x8888);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set to value near max
    let near_max = 18_446_744_073_709_551_615u64; // u64::MAX
    conditional_balance::set_balance(&mut balance, 0, true, near_max);

    // Verify we can read it back
    assert!(conditional_balance::get_balance(&balance, 0, true) == near_max, 0);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
#[expected_failure] // Arithmetic error (overflow) - VM level detection
fun test_add_causes_overflow() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x9999);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Set to max value
    let max_u64 = 18_446_744_073_709_551_615u64;
    conditional_balance::set_balance(&mut balance, 0, true, max_u64);

    // Try to add 1 - should overflow and abort with arithmetic error
    conditional_balance::add_to_balance(&mut balance, 0, true, 1);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

#[test]
fun test_borrow_balances_mut_helper() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0xAAAA);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario)
    );

    // Use test helper to get mutable reference
    let balances_mut = conditional_balance::borrow_balances_mut_for_testing(&mut balance);

    // Directly manipulate vector
    *balances_mut.borrow_mut(0) = 123;
    *balances_mut.borrow_mut(1) = 456;

    // Verify changes via normal getters
    assert!(conditional_balance::get_balance(&balance, 0, true) == 123, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 456, 1);

    // Clear
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 0, false, 0);

    conditional_balance::destroy_empty(balance);
    end(scenario);
}

// === Integration Test ===

#[test]
fun test_full_lifecycle() {
    let mut scenario = start();

    let market_id = object::id_from_address(@0x5555);
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario)
    );

    // Simulate quantum liquidity deposit (same amount to all outcomes)
    let deposit_amount = 1000u64;
    let mut i = 0u8;
    while (i < 3) {
        conditional_balance::add_to_balance(&mut balance, i, true, deposit_amount);
        conditional_balance::add_to_balance(&mut balance, i, false, deposit_amount);
        i = i + 1;
    };

    // Verify all balances are equal (quantum liquidity property)
    i = 0;
    while (i < 3) {
        assert!(conditional_balance::get_balance(&balance, i, true) == deposit_amount, 0);
        assert!(conditional_balance::get_balance(&balance, i, false) == deposit_amount, 1);
        i = i + 1;
    };

    // Verify min balance equals deposit amount
    assert!(conditional_balance::find_min_balance(&balance, true) == deposit_amount, 2);
    assert!(conditional_balance::find_min_balance(&balance, false) == deposit_amount, 3);

    // Simulate trading: subtract from outcome 1
    conditional_balance::sub_from_balance(&mut balance, 1, true, 300);
    conditional_balance::sub_from_balance(&mut balance, 1, false, 400);

    // Now outcome 1 has lowest balances
    assert!(conditional_balance::get_balance(&balance, 1, true) == 700, 4);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 600, 5);

    // Min balance should be from outcome 1
    assert!(conditional_balance::find_min_balance(&balance, true) == 700, 6);
    assert!(conditional_balance::find_min_balance(&balance, false) == 600, 7);

    // Complete set burn: subtract min from all outcomes
    let min_asset = conditional_balance::find_min_balance(&balance, true);
    let min_stable = conditional_balance::find_min_balance(&balance, false);

    i = 0;
    while (i < 3) {
        conditional_balance::sub_from_balance(&mut balance, i, true, min_asset);
        conditional_balance::sub_from_balance(&mut balance, i, false, min_stable);
        i = i + 1;
    };

    // After complete set burn, at least one outcome should have zero balance
    assert!(conditional_balance::get_balance(&balance, 1, true) == 0, 8);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 0, 9);

    // Clear remaining balances
    i = 0;
    while (i < 3) {
        conditional_balance::set_balance(&mut balance, i, true, 0);
        conditional_balance::set_balance(&mut balance, i, false, 0);
        i = i + 1;
    };

    conditional_balance::destroy_empty(balance);
    end(scenario);
}
