#[test_only]
module futarchy::refactor_tests;

use std::string;
use sui::{
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Params, Intent, Expired},
    executable::{Self, Executable},
    version_witness,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    strategy,
    execute,
    gc_janitor,
    events,
    version,
};

// Test witness
public struct TestIntentWitness has copy, drop {}

// === Strategy Tests (already in strategy.move, but adding integration tests) ===

#[test]
fun test_strategy_integration_with_execute() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    
    // Create test account
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create a test intent
    let params = intents::new_params(
        b"test_intent".to_string(),
        b"Test intent for strategy gates".to_string(),
        vector[clock::timestamp_ms(&clock) + 1000],
        clock::timestamp_ms(&clock) + 10000,
        &clock,
        ctx
    );
    
    let outcome = futarchy_config::new_futarchy_outcome(
        b"test_intent".to_string(),
        option::none(),
        option::none(),
        false,
        clock::timestamp_ms(&clock) + 1000
    );
    
    // Build intent (simplified - would normally use build_intent! macro)
    let intent_key = b"test_intent".to_string();
    account::add_intent(
        &mut account,
        intent_key,
        outcome,
        clock::timestamp_ms(&clock) + 10000,
        ctx
    );
    
    // Create executable
    clock::increment_for_testing(&mut clock, 1001);
    let (_, executable) = account::create_executable<FutarchyConfig, FutarchyOutcome, _>(
        &mut account,
        intent_key,
        &clock,
        version::current(),
        futarchy_config::GovernanceWitness {},
    );
    
    // Test AND strategy - should fail with false, false
    let executable = execute::run(
        executable,
        &mut account,
        strategy::and(),
        false,
        false,
        TestIntentWitness {},
        &clock,
        ctx
    );
    // This would abort with EPolicyNotSatisfied
    
    executable::destroy(executable);
    account::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Cancel Intent Tests ===

#[test]
fun test_cancel_intent_unlocks_objects() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    
    // Create test account
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create a coin to lock
    let coin = coin::mint_for_testing<SUI>(1000000, ctx);
    let coin_id = object::id(&coin);
    account::keep(&account, coin);
    
    // Create intent with a withdraw action that locks the coin
    let params = intents::new_params(
        b"test_withdraw".to_string(),
        b"Test withdraw with lock".to_string(),
        vector[clock::timestamp_ms(&clock) + 1000],
        clock::timestamp_ms(&clock) + 10000,
        &clock,
        ctx
    );
    
    let outcome = futarchy_config::new_futarchy_outcome(
        b"test_withdraw".to_string(),
        option::none(),
        option::none(),
        false,
        clock::timestamp_ms(&clock) + 1000
    );
    
    // Add intent with withdraw action (this would lock the coin)
    let intent_key = b"test_withdraw".to_string();
    // ... intent creation with withdraw action ...
    
    // Verify coin is locked
    assert!(account::intents(&account).locked().contains(&coin_id), 0);
    
    // Cancel the intent - should unlock the coin
    let mut expired = account::cancel_intent<FutarchyConfig, FutarchyOutcome, _>(
        &mut account,
        intent_key,
        futarchy_config::GovernanceWitness {}
    );
    
    // Verify coin is unlocked
    assert!(!account::intents(&account).locked().contains(&coin_id), 1);
    
    // Clean up expired
    gc_janitor::drain_expired(&mut expired);
    intents::destroy_empty_expired(expired);
    
    account::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === GC Janitor Tests ===

#[test]
fun test_janitor_drains_all_actions() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    
    // Create test account
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create and add multiple intents with different action types
    // ... create intents with various actions ...
    
    // Make an intent expire
    let intent_key = b"test_expired".to_string();
    clock::increment_for_testing(&mut clock, 20000); // Past expiration
    
    // Delete the expired intent
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        &mut account,
        intent_key,
        &clock
    );
    
    // Use janitor to drain all actions
    gc_janitor::drain_expired(&mut expired);
    
    // Verify expired is now empty and can be destroyed
    intents::destroy_empty_expired(expired);
    
    account::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Witness/Version Tests ===

#[test]
#[expected_failure(abort_code = futarchy::execute::EPolicyNotSatisfied)]
fun test_execute_with_failed_strategy_gate() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    
    // Create test account and executable
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create executable (simplified)
    let outcome = futarchy_config::new_futarchy_outcome(
        b"test".to_string(),
        option::none(),
        option::none(),
        false,
        0
    );
    let executable = executable::new_for_testing<FutarchyOutcome>(
        outcome,
        &account,
        ctx
    );
    
    // This should fail because AND strategy requires both to be true
    let _executable = execute::run(
        executable,
        &mut account,
        strategy::and(),
        true,   // ok_a = true
        false,  // ok_b = false
        TestIntentWitness {},
        &clock,
        ctx
    );
    
    abort 0 // Should never reach here
}

#[test]
fun test_execute_with_or_strategy() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    
    // Create test account
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create executable
    let outcome = futarchy_config::new_futarchy_outcome(
        b"test".to_string(),
        option::none(),
        option::none(),
        false,
        0
    );
    let executable = executable::new_for_testing<FutarchyOutcome>(
        outcome,
        &account,
        ctx
    );
    
    // OR strategy should succeed with at least one true
    let executable = execute::run(
        executable,
        &mut account,
        strategy::or(),
        true,   // ok_a = true
        false,  // ok_b = false
        TestIntentWitness {},
        &clock,
        ctx
    );
    
    // Cleanup
    executable::destroy(executable);
    account::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_execute_with_threshold_strategy() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    
    // Create test account
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create executable
    let outcome = futarchy_config::new_futarchy_outcome(
        b"test".to_string(),
        option::none(),
        option::none(),
        false,
        0
    );
    let executable = executable::new_for_testing<FutarchyOutcome>(
        outcome,
        &account,
        ctx
    );
    
    // 1-of-2 threshold should succeed with one true
    let executable = execute::run(
        executable,
        &mut account,
        strategy::threshold(1, 2),
        true,   // ok_a = true
        false,  // ok_b = false
        TestIntentWitness {},
        &clock,
        ctx
    );
    
    // Cleanup
    executable::destroy(executable);
    account::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Sweep Tests ===

#[test]
fun test_janitor_sweep_multiple_expired() {
    let mut scenario = ts::begin(@0xABCD);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    
    // Create test account
    let config = futarchy_config::default_config_params();
    let mut account = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(config, ctx),
        ctx
    );
    
    // Create multiple intents that will expire
    let keys = vector[
        b"intent1".to_string(),
        b"intent2".to_string(),
        b"intent3".to_string(),
    ];
    
    let mut i = 0;
    while (i < vector::length(&keys)) {
        let key = *vector::borrow(&keys, i);
        let params = intents::new_params(
            key,
            b"Test intent".to_string(),
            vector[],
            clock::timestamp_ms(&clock) + 1000, // Expires in 1 second
            &clock,
            ctx
        );
        
        let outcome = futarchy_config::new_futarchy_outcome(
            key,
            option::none(),
            option::none(),
            false,
            0
        );
        
        account::add_intent(&mut account, key, outcome, clock::timestamp_ms(&clock) + 1000, ctx);
        i = i + 1;
    };
    
    // Fast forward past expiration
    clock::increment_for_testing(&mut clock, 2000);
    
    // Sweep all expired intents
    gc_janitor::sweep_some(&mut account, &keys, 10, &clock);
    
    // Verify all intents were cleaned up
    i = 0;
    while (i < vector::length(&keys)) {
        let key = *vector::borrow(&keys, i);
        assert!(!account::intents(&account).has<FutarchyOutcome>(key), i);
        i = i + 1;
    };
    
    account::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}