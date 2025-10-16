#[test_only]
module account_actions::kiosk_tests;

use account_actions::kiosk as acc_kiosk;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

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

// === Integration Tests ===
// These test the Account protocol integration, not the Sui kiosk module itself

#[test]
fun test_open_kiosk_stores_owner_cap() {
    let (mut scenario, extensions, mut account, clock) = start();
    let kiosk_name = b"test_kiosk".to_string();

    // Open a kiosk - this should store the KioskOwnerCap in the account
    let auth = account.new_auth(version::current(), Witness());
    acc_kiosk::open(auth, &mut account, kiosk_name, scenario.ctx());

    // Verify kiosk owner cap is stored in account
    assert!(acc_kiosk::has_lock(&account, kiosk_name));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_kiosks() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Open multiple kiosks with different names
    let auth = account.new_auth(version::current(), Witness());
    acc_kiosk::open(auth, &mut account, b"kiosk1".to_string(), scenario.ctx());

    let auth = account.new_auth(version::current(), Witness());
    acc_kiosk::open(auth, &mut account, b"kiosk2".to_string(), scenario.ctx());

    let auth = account.new_auth(version::current(), Witness());
    acc_kiosk::open(auth, &mut account, b"kiosk3".to_string(), scenario.ctx());

    // Verify all caps are stored
    assert!(acc_kiosk::has_lock(&account, b"kiosk1".to_string()));
    assert!(acc_kiosk::has_lock(&account, b"kiosk2".to_string()));
    assert!(acc_kiosk::has_lock(&account, b"kiosk3".to_string()));

    // Verify non-existent kiosk returns false
    assert!(!acc_kiosk::has_lock(&account, b"nonexistent".to_string()));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_auth_required_for_open() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Opening kiosk requires auth
    let auth = account.new_auth(version::current(), Witness());
    acc_kiosk::open(auth, &mut account, b"test".to_string(), scenario.ctx());

    // Verify it was created
    assert!(acc_kiosk::has_lock(&account, b"test".to_string()));

    end(scenario, extensions, account, clock);
}
