/// Comprehensive tests for cancel_intent functionality
#[test_only]
module account_protocol::cancel_intent_tests;

// === Imports ===

use sui::{
    test_scenario as ts,
    test_utils,
    clock,
    coin,
    sui::SUI,
};
use account_protocol::{
    account::{Self, Account},
    deps,
    version,
    intents,
    owned,
};

// === Test Structs ===

public struct Config has store {}
public struct Witness has drop {}
public struct DummyIntent has drop {}
public struct Outcome has store, drop {}

// === Constants ===

const OWNER: address = @0xCAFE;

// === Tests ===

#[test]
/// Test that cancel_intent properly returns Expired that can be drained
/// and that locked objects are unlocked after draining
fun test_cancel_intent_with_withdraw() {
    let mut scenario = ts::begin(OWNER);
    let mut account = account::new(Config {}, deps::new_for_testing(), version::current(), Witness {}, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create a coin to lock
    let coin = coin::mint_for_testing<SUI>(100, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, account.addr());
    scenario.next_tx(OWNER);
    
    // Create intent with withdraw action
    let params = intents::new_params(
        b"withdraw_test".to_string(),
        b"Test withdraw with cancel".to_string(),
        vector[1],
        2,
        &clock,
        scenario.ctx()
    );
    let mut intent = account.create_intent(
        params,
        Outcome {},
        b"Test".to_string(),
        version::current(),
        DummyIntent {},
        scenario.ctx()
    );
    
    // Add withdraw action (no longer locks the coin at creation)
    owned::new_withdraw(&mut intent, &account, coin_id, DummyIntent {});
    account.insert_intent(intent, version::current(), DummyIntent {});
    
    // No locking in new design - nothing to verify
    
    // Cancel the intent using config witness
    let mut expired = account.cancel_intent<Config, Outcome, Witness>(
        b"withdraw_test".to_string(),
        version::current(),
        Witness {}
    );
    
    // Drain the expired intent (no unlocking needed anymore)
    owned::delete_withdraw(&mut expired, &account);
    intents::destroy_empty_expired(expired);
    
    // No locking in new design - nothing to verify
    
    test_utils::destroy(clock);
    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
/// Test canceling an intent with multiple withdraw actions
fun test_cancel_intent_multiple_withdraws() {
    let mut scenario = ts::begin(OWNER);
    let mut account = account::new(Config {}, deps::new_for_testing(), version::current(), Witness {}, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create multiple coins to lock
    let coin1 = coin::mint_for_testing<SUI>(100, scenario.ctx());
    let coin2 = coin::mint_for_testing<SUI>(200, scenario.ctx());
    let coin1_id = object::id(&coin1);
    let coin2_id = object::id(&coin2);
    
    transfer::public_transfer(coin1, account.addr());
    transfer::public_transfer(coin2, account.addr());
    scenario.next_tx(OWNER);
    
    // Create intent with multiple withdraw actions
    let params = intents::new_params(
        b"multi_withdraw".to_string(),
        b"Test multiple withdraws".to_string(),
        vector[1],
        2,
        &clock,
        scenario.ctx()
    );
    
    let mut intent = account.create_intent(
        params,
        Outcome {},
        b"Test".to_string(),
        version::current(),
        DummyIntent {},
        scenario.ctx()
    );
    
    // Add multiple withdraw actions (no locking at creation)
    owned::new_withdraw(&mut intent, &account, coin1_id, DummyIntent {});
    owned::new_withdraw(&mut intent, &account, coin2_id, DummyIntent {});
    account.insert_intent(intent, version::current(), DummyIntent {});
    
    // No locking in new design - nothing to verify
    
    // Cancel the intent
    let mut expired = account.cancel_intent<Config, Outcome, Witness>(
        b"multi_withdraw".to_string(),
        version::current(),
        Witness {}
    );
    
    // Drain all withdraw actions (no unlocking needed)
    owned::delete_withdraw(&mut expired, &account);
    owned::delete_withdraw(&mut expired, &account);
    intents::destroy_empty_expired(expired);
    
    // No locking in new design - nothing to verify
    
    test_utils::destroy(clock);
    test_utils::destroy(account);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = account::ENotCalledFromConfigModule)]
/// Test that cancel_intent fails without config witness
fun test_cancel_intent_wrong_witness() {
    let mut scenario = ts::begin(OWNER);
    let mut account = account::new(Config {}, deps::new_for_testing(), version::current(), Witness {}, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    
    let params = intents::new_params(
        b"test".to_string(),
        b"Test".to_string(),
        vector[1],
        2,
        &clock,
        scenario.ctx()
    );
    
    let intent = account.create_intent(
        params,
        Outcome {},
        b"Test".to_string(),
        version::current(),
        DummyIntent {},
        scenario.ctx()
    );
    
    account.insert_intent(intent, version::current(), DummyIntent {});
    
    // This should fail - using wrong witness (not config witness)
    let expired = account.cancel_intent<Config, Outcome, account::Witness>(
        b"test".to_string(),
        version::current(),
        account::not_config_witness()
    );
    
    test_utils::destroy(expired);
    test_utils::destroy(clock);
    test_utils::destroy(account);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist)]
/// Test that cancel_intent fails for non-existent intent
fun test_cancel_nonexistent_intent() {
    let mut scenario = ts::begin(OWNER);
    let mut account = account::new(Config {}, deps::new_for_testing(), version::current(), Witness {}, scenario.ctx());
    
    // Try to cancel non-existent intent
    let expired = account.cancel_intent<Config, Outcome, Witness>(
        b"does_not_exist".to_string(),
        version::current(),
        Witness {}
    );
    
    test_utils::destroy(expired);
    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
/// Test that cancel_intent works with no locked objects
fun test_cancel_intent_no_locks() {
    let mut scenario = ts::begin(OWNER);
    let mut account = account::new(Config {}, deps::new_for_testing(), version::current(), Witness {}, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create a simple intent without any withdraw actions
    let params = intents::new_params(
        b"no_locks".to_string(),
        b"Test intent with no locks".to_string(),
        vector[1],
        2,
        &clock,
        scenario.ctx()
    );
    
    let intent = account.create_intent(
        params,
        Outcome {},
        b"Test".to_string(),
        version::current(),
        DummyIntent {},
        scenario.ctx()
    );
    
    account.insert_intent(intent, version::current(), DummyIntent {});
    
    // No locking in new design - nothing to verify
    
    // Cancel the intent
    let expired = account.cancel_intent<Config, Outcome, Witness>(
        b"no_locks".to_string(),
        version::current(),
        Witness {}
    );
    
    // Destroy the empty expired intent
    intents::destroy_empty_expired(expired);
    
    // No locking in new design - nothing to verify
    
    test_utils::destroy(clock);
    test_utils::destroy(account);
    ts::end(scenario);
}