#[test_only]
module account_protocol::account_object_tracking_tests;

use std::type_name;
use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_utils;

use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::version;
use account_extensions::extensions::{Self, Extensions};

// Test objects
public struct TestObject has key, store {
    id: UID
}

public struct TestObject2 has key, store {
    id: UID
}

public struct TestConfig has store, drop {
    dummy: u64
}

// Test witness for config
public struct TestWitness has drop {}

const OWNER: address = @0xCAFE;

// Helper to create a test account
fun create_test_account(scenario: &mut Scenario): Account<TestConfig> {
    scenario.next_tx(OWNER);
    
    // Initialize extensions
    extensions::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    
    let exts = scenario.take_shared<Extensions>();
    
    // Create account with new API
    let config = TestConfig { dummy: 1 };
    let deps_struct = deps::new_for_testing();
    let account = account::new(
        config,
        deps_struct,
        version::current(),
        TestWitness {},
        scenario.ctx()
    );
    
    test_utils::destroy(exts);
    account
}

// ============================================================================
// Happy Path Tests
// ============================================================================

#[test]
fun test_initialize_object_tracker_with_defaults() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Check default object tracking state
    let (count, deposits_open, max_objects) = account.object_stats();
    assert!(count == 0);
    assert!(deposits_open == true);
    assert!(max_objects > 0); // Should have a reasonable default
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_track_adding_non_coin_objects() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Create and add test objects
    let obj1 = TestObject { id: object::new(scenario.ctx()) };
    let obj1_id = object::id(&obj1);
    account.keep(obj1, scenario.ctx());
    
    let obj2 = TestObject { id: object::new(scenario.ctx()) };
    let obj2_id = object::id(&obj2);
    account.keep(obj2, scenario.ctx());
    
    // Check object count increased
    let (count, _, _) = account.object_stats();
    assert!(count == 2);
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_coin_deposits_not_counted() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Create and add coins
    let coin1 = coin::mint_for_testing<SUI>(100, scenario.ctx());
    account.keep(coin1, scenario.ctx());
    
    let coin2 = coin::mint_for_testing<SUI>(200, scenario.ctx());
    account.keep(coin2, scenario.ctx());
    
    // Check that coins are not counted
    let (count, _, _) = account.object_stats();
    assert!(count == 0); // Coins should not increment the count
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_whitelist_specific_types() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Whitelist TestObject type
    let auth = account.new_auth(version::current(), TestWitness {});
    let type_to_add = type_name::with_defining_ids<TestObject>();
    account::manage_type_whitelist(auth, &mut account, vector[type_to_add], vector[]);
    
    // Check if type is whitelisted
    assert!(account.is_type_whitelisted<TestConfig, TestObject>());
    assert!(!account.is_type_whitelisted<TestConfig, TestObject2>());
    
    // Get all whitelisted types
    let whitelisted = account.get_whitelisted_types();
    assert!(whitelisted.length() == 1);
    assert!(whitelisted[0] == type_name::with_defining_ids<TestObject>());
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_close_and_open_deposits() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Initially deposits should be open
    assert!(account.is_accepting_objects());
    
    // Close deposits
    account.close_deposits_for_testing();
    assert!(!account.is_accepting_objects());
    
    // Open deposits again
    // To open deposits, use configure_object_deposits with Auth
    let auth2 = account.new_auth(version::current(), TestWitness {});
    account::configure_object_deposits(auth2, &mut account, true, option::none(), false);
    assert!(account.is_accepting_objects());
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_set_custom_max_object_limits() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Set custom max objects limit
    account.set_max_objects_for_testing(10);
    
    let (_, _, max_objects) = account.object_stats();
    assert!(max_objects == 10);
    
    // Update to a different limit
    account.set_max_objects_for_testing(20);
    
    let (_, _, max_objects) = account.object_stats();
    assert!(max_objects == 20);
    
    account.destroy_for_testing();
    scenario.end();
}

// ============================================================================
// Error Cases
// ============================================================================

#[test]
#[expected_failure(abort_code = account::EDepositsDisabled)]
fun test_deposit_when_closed_fails() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Close deposits
    account.close_deposits_for_testing();
    
    // Try to deposit object - should fail
    let obj = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj, scenario.ctx());
    
    account.destroy_for_testing();
    scenario.end();
}

// #[test]
// #[expected_failure(abort_code = account::ETypeNotWhitelisted)]
// TODO: This test needs to be reimplemented with the new API
// fun test_deposit_non_whitelisted_type_when_enforced_fails() {
//     let mut scenario = ts::begin(OWNER);
//     let mut account = create_test_account(&mut scenario);
//     
//     // Whitelist only TestObject (not TestObject2)
//     let auth = account.new_auth(version::current(), TestWitness {});
//     let type_to_add = type_name::with_defining_ids<TestObject>();
//     account::manage_type_whitelist(auth, &mut account, vector[type_to_add], vector[]);
//     // Note: enforce_whitelist doesn't exist, whitelist is always enforced when types are added
//     
//     // Try to deposit TestObject2 - should fail
//     let obj = TestObject2 { id: object::new(scenario.ctx()) };
//     account.keep(obj, scenario.ctx());
//     
//     account.destroy_for_testing();
//     scenario.end();
// }

// TODO: This test needs to be reimplemented with the new API
// The take_data function no longer exists
// #[test]
// #[expected_failure(abort_code = account::EObjectNotFound)]
// fun test_remove_non_existent_object_fails() {
//     let mut scenario = ts::begin(OWNER);
//     let mut account = create_test_account(&mut scenario);
//     
//     // Try to remove object that doesn't exist
//     let fake_id = object::id_from_address(@0xDEAD);
//     // Need new API for this test
//     
//     account.destroy_for_testing();
//     scenario.end();
// }

// ============================================================================
// Edge Cases
// ============================================================================

#[test]
fun test_exactly_at_max_objects_limit() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Set max to 3
    account.set_max_objects_for_testing(3);
    
    // Add exactly 3 objects
    let obj1 = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj1, scenario.ctx());
    
    let obj2 = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj2, scenario.ctx());
    
    let obj3 = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj3, scenario.ctx());
    
    // Should be at limit but still accepting if one is removed
    let (count, _, max) = account.object_stats();
    assert!(count == 3);
    assert!(max == 3);
    assert!(!account.is_accepting_objects()); // At limit
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_max_objects_zero_no_objects_allowed() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Set max to 0
    account.set_max_objects_for_testing(0);
    
    // Should not be accepting objects
    assert!(!account.is_accepting_objects());
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_max_objects_very_large_number() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Set max to u128::MAX (effectively unlimited)
    let max_u128 = 340282366920938463463374607431768211455u128;
    account.set_max_objects_for_testing(max_u128);
    
    // Should always be accepting
    assert!(account.is_accepting_objects());
    
    // Add many objects
    let mut i = 0;
    while (i < 100) {
        let obj = TestObject { id: object::new(scenario.ctx()) };
        account.keep(obj, scenario.ctx());
        i = i + 1;
    };
    
    // Still accepting
    assert!(account.is_accepting_objects());
    
    account.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_whitelist_maximum_types() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Whitelist many different types (using type parameters)
    let auth2 = account.new_auth(version::current(), TestWitness {});
    let types_to_add = vector[
        type_name::with_defining_ids<TestObject>(),
        type_name::with_defining_ids<TestObject2>(),
        type_name::with_defining_ids<Coin<SUI>>()
    ];
    account::manage_type_whitelist(auth2, &mut account, types_to_add, vector[]);
    
    let whitelisted = account.get_whitelisted_types();
    assert!(whitelisted.length() == 3);
    
    // All should be whitelisted
    assert!(account.is_type_whitelisted<TestConfig, TestObject>());
    assert!(account.is_type_whitelisted<TestConfig, TestObject2>());
    assert!(account.is_type_whitelisted<TestConfig, Coin<SUI>>());
    
    account.destroy_for_testing();
    scenario.end();
}


#[test]
fun test_mixed_coin_and_object_tracking() {
    let mut scenario = ts::begin(OWNER);
    let mut account = create_test_account(&mut scenario);
    
    // Set limit to 3 for objects
    account.set_max_objects_for_testing(3);
    
    // Add mix of coins and objects
    let coin1 = coin::mint_for_testing<SUI>(100, scenario.ctx());
    account.keep(coin1, scenario.ctx());
    
    let obj1 = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj1, scenario.ctx());
    
    let coin2 = coin::mint_for_testing<SUI>(200, scenario.ctx());
    account.keep(coin2, scenario.ctx());
    
    let obj2 = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj2, scenario.ctx());
    
    let coin3 = coin::mint_for_testing<SUI>(300, scenario.ctx());
    account.keep(coin3, scenario.ctx());
    
    // Only objects should count
    let (count, _, _) = account.object_stats();
    assert!(count == 2); // Only 2 objects, coins don't count
    
    // Can still add one more object
    let obj3 = TestObject { id: object::new(scenario.ctx()) };
    account.keep(obj3, scenario.ctx());
    
    let (count, _, _) = account.object_stats();
    assert!(count == 3);
    
    // But can add unlimited coins
    let coin4 = coin::mint_for_testing<SUI>(400, scenario.ctx());
    account.keep(coin4, scenario.ctx());
    
    let coin5 = coin::mint_for_testing<SUI>(500, scenario.ctx());
    account.keep(coin5, scenario.ctx());
    
    // Count still 3 (only objects)
    let (count, _, _) = account.object_stats();
    assert!(count == 3);
    
    account.destroy_for_testing();
    scenario.end();
}
}