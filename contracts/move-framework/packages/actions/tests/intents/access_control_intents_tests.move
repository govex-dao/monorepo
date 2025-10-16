#[test_only]
module account_actions::access_control_intents_tests;

use account_actions::access_control;
use account_actions::access_control_intents;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intents;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// Test capability
public struct TestCap has key, store {
    id: UID,
    value: u64,
}

// === Helpers ===

fun start(): (Scenario, Extensions, Account<Config>, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    extensions::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @account_actions, 1);

    let deps = deps::new_latest_extensions(
        &extensions,
        vector[b"AccountProtocol".to_string(), b"AccountActions".to_string()],
    );
    let account = account::new(Config {}, deps, version::current(), Witness(), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    // create world
    destroy(cap);
    (scenario, extensions, account, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<Config>, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_request_borrow_cap_basic() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock a capability first
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 42,
    };
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    // Create a borrow cap intent
    let key = b"test_borrow".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test borrow cap".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    let auth2 = account.new_auth(version::current(), Witness());
    access_control_intents::request_borrow_cap<_, _, TestCap>(
        auth2,
        &mut account,
        params,
        outcome,
        scenario.ctx(),
    );

    // Execute the intent
    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Borrow the cap
    let borrowed_cap = access_control_intents::execute_borrow_cap<Config, Outcome, TestCap>(
        &mut executable,
        &mut account,
    );

    assert!(borrowed_cap.value == 42, 0);

    // Return the cap
    access_control_intents::execute_return_cap<Config, Outcome, TestCap>(
        &mut executable,
        &mut account,
        borrowed_cap,
    );

    // Confirm execution
    account.confirm_execution(executable);

    // Verify cap is still locked
    assert!(access_control::has_lock<Config, TestCap>(&account), 1);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = access_control_intents::ENoLock)]
fun test_request_borrow_cap_without_lock() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Try to create borrow intent without locking cap first (should fail)
    let key = b"test_no_lock".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test no lock".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    let auth = account.new_auth(version::current(), Witness());

    // This should abort with ENoLock
    access_control_intents::request_borrow_cap<_, _, TestCap>(
        auth,
        &mut account,
        params,
        outcome,
        scenario.ctx(),
    );

    end(scenario, extensions, account, clock);
}

#[test]
fun test_execute_borrow_and_return_separately() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Setup: Lock cap and create intent
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 100,
    };
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    let key = b"test_separate".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    let auth2 = account.new_auth(version::current(), Witness());
    access_control_intents::request_borrow_cap<_, _, TestCap>(
        auth2,
        &mut account,
        params,
        outcome,
        scenario.ctx(),
    );

    // Create executable
    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Execute borrow
    let cap = access_control_intents::execute_borrow_cap<Config, Outcome, TestCap>(
        &mut executable,
        &mut account,
    );

    // Do something with the cap
    assert!(cap.value == 100, 0);

    // Execute return
    access_control_intents::execute_return_cap<Config, Outcome, TestCap>(
        &mut executable,
        &mut account,
        cap,
    );

    // Confirm
    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_borrow_return_cycles() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock cap
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 999,
    };
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    // Create first intent
    let key1 = b"cycle1".to_string();
    let outcome = Outcome {};
    let params1 = intents::new_params(
        key1,
        b"Cycle 1".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );
    let auth1 = account.new_auth(version::current(), Witness());
    access_control_intents::request_borrow_cap<_, _, TestCap>(
        auth1,
        &mut account,
        params1,
        outcome,
        scenario.ctx(),
    );

    // Execute first cycle
    let (_, mut exec1) = account.create_executable<_, Outcome, _>(
        key1,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    let cap1 = access_control_intents::execute_borrow_cap<Config, Outcome, TestCap>(
        &mut exec1,
        &mut account,
    );
    assert!(cap1.value == 999, 0);
    access_control_intents::execute_return_cap<Config, Outcome, TestCap>(
        &mut exec1,
        &mut account,
        cap1,
    );
    account.confirm_execution(exec1);

    // Create second intent
    let key2 = b"cycle2".to_string();
    let params2 = intents::new_params(
        key2,
        b"Cycle 2".to_string(),
        vector[0],
        2000,
        &clock,
        scenario.ctx(),
    );
    let auth2 = account.new_auth(version::current(), Witness());
    access_control_intents::request_borrow_cap<_, _, TestCap>(
        auth2,
        &mut account,
        params2,
        outcome,
        scenario.ctx(),
    );

    // Execute second cycle
    let (_, mut exec2) = account.create_executable<_, Outcome, _>(
        key2,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    let cap2 = access_control_intents::execute_borrow_cap<Config, Outcome, TestCap>(
        &mut exec2,
        &mut account,
    );
    assert!(cap2.value == 999, 1);
    access_control_intents::execute_return_cap<Config, Outcome, TestCap>(
        &mut exec2,
        &mut account,
        cap2,
    );
    account.confirm_execution(exec2);

    // Verify cap still locked
    assert!(access_control::has_lock<Config, TestCap>(&account), 2);

    end(scenario, extensions, account, clock);
}
