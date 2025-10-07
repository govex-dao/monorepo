#[test_only]
module futarchy_dao::gc_tests;

use std::string::{Self, String};
use std::vector;
use sui::{
    test_scenario::{Self, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    object,
    test_utils,
};
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Intent, Expired},
    executable::Executable,
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    version,
};
use futarchy_actions::{
    config_actions,
    memo_actions,
};
use futarchy_lifecycle::stream_actions;
use futarchy_legal_actions::operating_agreement_actions;
use futarchy_dao::{
    gc_janitor,
    gc_registry,
    execute,
};
use futarchy_markets::{
    spot_token::SPOT,
    conditional_token::{YES, NO},
};

// Test witness
struct TestWitness has drop {}

/// Test that expired intents with no actions can be cleaned up
#[test]
fun test_cleanup_empty_expired_intent() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account
    let mut account = create_test_account(&mut scenario);
    
    // Create an intent with no actions
    let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
        &mut account,
        scenario.ctx()
    );
    
    // Set execution time in the past
    intent.add_execution_time(100);
    let key = intent.key();
    
    // Add intent to account
    account::add_intent(&mut account, intent, TestWitness {});
    
    // Fast forward time
    clock::set_for_testing(&mut clock, 1000);
    
    // Delete the expired intent
    gc_janitor::delete_expired_by_key(&mut account, key, &clock);
    
    // Verify intent was removed
    assert!(!account::intents(&account).contains(key), 0);
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

/// Test cleanup of intents with config actions
#[test]
fun test_cleanup_config_actions() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account
    let mut account = create_test_account(&mut scenario);
    
    // Create an intent with config actions
    let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
        &mut account,
        scenario.ctx()
    );
    
    // Add config action
    config_actions::new_config_update(&mut intent, 
        string::utf8(b"test_key"),
        string::utf8(b"test_value"),
        TestWitness {}
    );
    
    // Set execution time in the past
    intent.add_execution_time(100);
    let key = intent.key();
    
    // Add intent to account
    account::add_intent(&mut account, intent, TestWitness {});
    
    // Fast forward time
    clock::set_for_testing(&mut clock, 1000);
    
    // Delete the expired intent - this should clean up the config action
    gc_janitor::delete_expired_by_key(&mut account, key, &clock);
    
    // Verify intent was removed
    assert!(!account::intents(&account).contains(key), 1);
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

/// Test cleanup of intents with stream actions
#[test]
fun test_cleanup_stream_actions() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account  
    let mut account = create_test_account(&mut scenario);
    
    // Create an intent with stream actions
    let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
        &mut account,
        scenario.ctx()
    );
    
    // Add stream action
    let action = stream_actions::new_create_stream_action<SUI>(
        stream_actions::source_direct_treasury(),
        @0x2,
        1000000,
        1000,
        2000,
        option::none(),
        true,
        string::utf8(b"Test stream"),
        &clock,
        scenario.ctx()
    );
    
    intent.add_action(action, TestWitness {});
    
    // Set execution time in the past
    intent.add_execution_time(100);
    let key = intent.key();
    
    // Add intent to account
    account::add_intent(&mut account, intent, TestWitness {});
    
    // Fast forward time
    clock::set_for_testing(&mut clock, 3000);
    
    // Delete the expired intent - this should clean up the stream action
    gc_janitor::delete_expired_by_key(&mut account, key, &clock);
    
    // Verify intent was removed
    assert!(!account::intents(&account).contains(key), 2);
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

/// Test sweep of multiple expired intents
#[test]
fun test_sweep_multiple_intents() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account
    let mut account = create_test_account(&mut scenario);
    
    // Create multiple intents
    let mut keys = vector::empty<String>();
    let mut i = 0;
    while (i < 5) {
        let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
            &mut account,
            scenario.ctx()
        );
        
        // Add a memo action
        memo_actions::new_memo(&mut intent,
            string::utf8(b"Test memo"),
            TestWitness {}
        );
        
        // Set execution time in the past
        intent.add_execution_time(100 + i);
        let key = intent.key();
        vector::push_back(&mut keys, key);
        
        // Add intent to account
        account::add_intent(&mut account, intent, TestWitness {});
        
        i = i + 1;
    };
    
    // Fast forward time
    clock::set_for_testing(&mut clock, 1000);
    
    // Sweep all expired intents
    gc_janitor::sweep_expired_intents(&mut account, keys, 10, &clock);
    
    // Verify all intents were removed
    let mut j = 0;
    while (j < vector::length(&keys)) {
        let key = vector::borrow(&keys, j);
        assert!(!account::intents(&account).contains(*key), 3);
        j = j + 1;
    };
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

/// Test cleanup of intents with generic vault actions
#[test]
fun test_cleanup_generic_vault_actions() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account
    let mut account = create_test_account(&mut scenario);
    
    // Create an intent with vault actions for different coin types
    let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
        &mut account,
        scenario.ctx()
    );
    
    // Add vault spend action for SUI
    account_actions::vault::new_spend<FutarchyConfig, SUI, TestWitness>(
        &mut intent,
        string::utf8(b"treasury"),
        1000000,
        TestWitness {}
    );
    
    // Set execution time in the past
    intent.add_execution_time(100);
    let key = intent.key();
    
    // Add intent to account
    account::add_intent(&mut account, intent, TestWitness {});
    
    // Fast forward time
    clock::set_for_testing(&mut clock, 1000);
    
    // Delete the expired intent - this should clean up generic vault actions
    gc_janitor::delete_expired_by_key(&mut account, key, &clock);
    
    // Verify intent was removed
    assert!(!account::intents(&account).contains(key), 4);
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

/// Test that recurring intents are not deleted when they have future execution times
#[test]
fun test_recurring_intent_not_deleted() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account
    let mut account = create_test_account(&mut scenario);
    
    // Create a recurring intent
    let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
        &mut account,
        scenario.ctx()
    );
    
    // Add a memo action
    memo_actions::new_memo(&mut intent,
        string::utf8(b"Recurring memo"),
        TestWitness {}
    );
    
    // Set multiple execution times - one past, one future
    intent.add_execution_time(100);
    intent.add_execution_time(2000);
    let key = intent.key();
    
    // Add intent to account
    account::add_intent(&mut account, intent, TestWitness {});
    
    // Fast forward time to between the two execution times
    clock::set_for_testing(&mut clock, 1000);
    
    // Try to delete - should not work because there's a future execution time
    assert!(gc_janitor::is_intent_expired(&account, &key, &clock) == false, 5);
    
    // The intent should still exist
    assert!(account::intents(&account).contains(key), 6);
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

/// Test cleanup via entry functions
#[test]
fun test_cleanup_entry_functions() {
    let mut scenario = test_scenario::begin(@0x1);
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create account
    let mut account = create_test_account(&mut scenario);
    
    // Create an intent
    let mut intent = intents::new_intent<FutarchyConfig, TestWitness>(
        &mut account,
        scenario.ctx()
    );
    
    // Add action
    memo_actions::new_memo(&mut intent,
        string::utf8(b"Entry test"),
        TestWitness {}
    );
    
    // Set execution time in the past
    intent.add_execution_time(100);
    let key = intent.key();
    
    // Add intent to account
    account::add_intent(&mut account, intent, TestWitness {});
    
    // Fast forward time
    clock::set_for_testing(&mut clock, 1000);
    
    // Call entry function to cleanup
    gc_janitor::cleanup_expired_intent(&mut account, key, &clock);
    
    // Verify intent was removed
    assert!(!account::intents(&account).contains(key), 7);
    
    clock::destroy_for_testing(clock);
    test_utils::destroy(account);
    test_scenario::end(scenario);
}

// === Helper Functions ===

fun create_test_account(scenario: &mut Scenario): Account<FutarchyConfig> {
    let ctx = scenario.ctx();
    
    // Create FutarchyConfig
    let config = futarchy_config::new_for_testing(ctx);
    
    // Create Account with the config
    let account = account::new(
        config,
        version::current(),
        ctx
    );
    
    account
}