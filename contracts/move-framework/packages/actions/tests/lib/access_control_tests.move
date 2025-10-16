#[test_only]
module account_actions::access_control_tests;

use account_actions::access_control;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intent_interface;
use account_protocol::intents;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Macros ===

use fun intent_interface::build_intent as Account.build_intent;

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// Test capability that needs to be locked
public struct TestCap has key, store {
    id: UID,
    value: u64,
}

// Intent witness for testing
public struct AccessControlIntent() has copy, drop;

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
fun test_lock_cap_basic() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Create a test capability
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 42,
    };

    // Get auth and lock the capability
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    // Verify the cap is locked
    assert!(access_control::has_lock<Config, TestCap>(&account), 0);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_borrow_and_return_cap() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_borrow_return".to_string();

    // Create and lock a test capability
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 100,
    };
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    // Create an intent with borrow and return actions
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test borrow and return".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        AccessControlIntent(),
        scenario.ctx(),
        |intent, iw| {
            access_control::new_borrow<_, TestCap, _>(intent, iw);
            access_control::new_return<_, TestCap, _>(intent, iw);
        },
    );

    // Create executable
    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Borrow the capability
    let borrowed_cap = access_control::do_borrow<Config, Outcome, TestCap, _>(
        &mut executable,
        &mut account,
        version::current(),
        AccessControlIntent(),
    );

    // Verify the capability was borrowed (has the expected value)
    assert!(borrowed_cap.value == 100, 1);

    // Return the capability
    access_control::do_return<Config, Outcome, TestCap, _>(
        &mut executable,
        &mut account,
        borrowed_cap,
        version::current(),
        AccessControlIntent(),
    );

    // Confirm execution
    account.confirm_execution(executable);

    // Verify the cap is still locked
    assert!(access_control::has_lock<Config, TestCap>(&account), 2);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = access_control::ENoReturn)]
fun test_borrow_without_return_fails() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_borrow_no_return".to_string();

    // Create and lock a test capability
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 50,
    };
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    // Create an intent with ONLY borrow (no return) - this should fail
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test borrow without return".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        AccessControlIntent(),
        scenario.ctx(),
        |intent, iw| {
            access_control::new_borrow<_, TestCap, _>(intent, iw);
            // Missing new_return - should fail at execution
        },
    );

    // Create executable
    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // This should abort with ENoReturn
    let borrowed_cap = access_control::do_borrow<Config, Outcome, TestCap, _>(
        &mut executable,
        &mut account,
        version::current(),
        AccessControlIntent(),
    );

    // Cleanup (won't reach here)
    let TestCap { id, value: _ } = borrowed_cap;
    object::delete(id);
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_cap_unshared() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Create a test capability
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 999,
    };

    // Lock the cap using the unshared function (for init-time locking)
    access_control::do_lock_cap_unshared(&mut account, test_cap);

    // Verify the cap is locked
    assert!(access_control::has_lock<Config, TestCap>(&account), 0);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_delete_borrow_action() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_delete_borrow".to_string();

    // Create an intent with a borrow action
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test delete borrow".to_string(),
        vector[0],
        clock.timestamp_ms() + 1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        AccessControlIntent(),
        scenario.ctx(),
        |intent, iw| {
            access_control::new_borrow<_, TestCap, _>(intent, iw);
            access_control::new_return<_, TestCap, _>(intent, iw);
        },
    );

    // Execute the intent first
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 77,
    };
    let auth = account.new_auth(version::current(), Witness());
    access_control::lock_cap(auth, &mut account, test_cap);

    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    let borrowed = access_control::do_borrow<Config, Outcome, TestCap, _>(
        &mut executable,
        &mut account,
        version::current(),
        AccessControlIntent(),
    );
    access_control::do_return<Config, Outcome, TestCap, _>(
        &mut executable,
        &mut account,
        borrowed,
        version::current(),
        AccessControlIntent(),
    );
    account.confirm_execution(executable);

    // Now destroy the empty intent
    let mut expired = account.destroy_empty_intent<_, Outcome>(key, scenario.ctx());
    access_control::delete_borrow<TestCap>(&mut expired);
    access_control::delete_return<TestCap>(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, clock);
}
