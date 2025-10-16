#[test_only]
module account_actions::package_upgrade_tests;

use account_actions::package_upgrade as pkg_upgrade;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use sui::clock::{Self, Clock};
use sui::package::{Self, UpgradeCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

// OTW for creating UpgradeCap
public struct PACKAGE_UPGRADE_TESTS has drop {}

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

fun create_test_upgrade_cap(scenario: &mut Scenario): UpgradeCap {
    let publisher = package::test_claim(PACKAGE_UPGRADE_TESTS {}, scenario.ctx());
    let upgrade_cap = package::test_publish(object::id(&publisher), scenario.ctx());
    destroy(publisher);
    upgrade_cap
}

// === Integration Tests ===
// These test the Account protocol integration for package upgrades

#[test]
fun test_lock_cap_stores_in_account() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Create upgrade cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);

    // Lock it in the account
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000);

    // Verify cap is stored
    assert!(pkg_upgrade::has_cap(&account, package_name));

    // Verify time delay is set
    assert!(pkg_upgrade::get_time_delay(&account, package_name) == 1000);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::ELockAlreadyExists)]
fun test_cannot_lock_same_package_twice() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Lock first cap
    let upgrade_cap1 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap1, package_name, 1000);

    // Try to lock second cap with same name - should fail
    let upgrade_cap2 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap2, package_name, 1000);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_packages() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock multiple packages
    let cap1 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, cap1, b"package1".to_string(), 100);

    let cap2 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, cap2, b"package2".to_string(), 200);

    let cap3 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, cap3, b"package3".to_string(), 300);

    // Verify all caps are stored with correct delays
    assert!(pkg_upgrade::has_cap(&account, b"package1".to_string()));
    assert!(pkg_upgrade::has_cap(&account, b"package2".to_string()));
    assert!(pkg_upgrade::has_cap(&account, b"package3".to_string()));

    assert!(pkg_upgrade::get_time_delay(&account, b"package1".to_string()) == 100);
    assert!(pkg_upgrade::get_time_delay(&account, b"package2".to_string()) == 200);
    assert!(pkg_upgrade::get_time_delay(&account, b"package3".to_string()) == 300);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_get_cap_info() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Create and lock cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let package_addr = upgrade_cap.package().to_address();
    let version_num = upgrade_cap.version();
    let policy_num = upgrade_cap.policy();

    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000);

    // Verify we can retrieve cap info
    assert!(pkg_upgrade::get_cap_package(&account, package_name) == package_addr);
    assert!(pkg_upgrade::get_cap_version(&account, package_name) == version_num);
    assert!(pkg_upgrade::get_cap_policy(&account, package_name) == policy_num);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_package_index() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock a package
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let package_addr = upgrade_cap.package().to_address();
    let package_name = b"test_package".to_string();

    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000);

    // Verify package is in index
    assert!(pkg_upgrade::is_package_managed(&account, package_addr));
    assert!(pkg_upgrade::get_package_addr(&account, package_name) == package_addr);
    assert!(pkg_upgrade::get_package_name(&account, package_addr) == package_name);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_package_not_managed() {
    let (scenario, extensions, account, clock) = start();

    // Check that a random address is not managed
    assert!(!pkg_upgrade::is_package_managed(&account, @0xDEADBEEF));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_auth_required_for_lock() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Locking requires auth
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, b"test".to_string(), 1000);

    // Verify it was locked
    assert!(pkg_upgrade::has_cap(&account, b"test".to_string()));

    end(scenario, extensions, account, clock);
}
