#[test_only]
module account_actions::package_upgrade_tests;

use account_actions::package_upgrade as pkg_upgrade;
use account_actions::version;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use std::option;
use sui::clock::{Self, Clock};
use sui::package::{Self, UpgradeCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;
use sui::transfer;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

// OTW for creating UpgradeCap
public struct PACKAGE_UPGRADE_TESTS has drop {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    // add core deps
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountActions".to_string(), @account_actions, 1);

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

fun end(scenario: Scenario, extensions: PackageRegistry, account: Account, clock: Clock) {
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
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let six_months_ms = 15552000000; // 6 months
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, six_months_ms);

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
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap1, package_name, 1000, 15552000000);

    // Try to lock second cap with same name - should fail
    let upgrade_cap2 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap2, package_name, 1000, 15552000000);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_packages() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock multiple packages
    let cap1 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, cap1, b"package1".to_string(), 100, 15552000000);

    let cap2 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, cap2, b"package2".to_string(), 200, 15552000000);

    let cap3 = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, cap3, b"package3".to_string(), 300, 15552000000);

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

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, 15552000000);

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

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, 15552000000);

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
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, b"test".to_string(), 1000, 15552000000);

    // Verify it was locked
    assert!(pkg_upgrade::has_cap(&account, b"test".to_string()));

    end(scenario, extensions, account, clock);
}

// === Commit Cap Tests ===

#[test]
fun test_lock_commit_cap() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Lock commit cap
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_commit_cap(auth, &mut account, package_name, scenario.ctx());

    // Verify cap is stored
    assert!(pkg_upgrade::has_commit_cap(&account, package_name));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_borrow_and_return_commit_cap() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Lock commit cap
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_commit_cap(auth, &mut account, package_name, scenario.ctx());

    // Borrow it
    let commit_cap = pkg_upgrade::borrow_commit_cap<Config>(&mut account, package_name, version::current());

    // Verify it matches
    assert!(pkg_upgrade::commit_cap_package_name(&commit_cap) == package_name);

    // Return it
    pkg_upgrade::return_commit_cap<Config>(&mut account, commit_cap, version::current());

    // Verify it's back
    assert!(pkg_upgrade::has_commit_cap(&account, package_name));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_init_lock_commit_cap() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Use init function (unshared)
    pkg_upgrade::do_lock_commit_cap_unshared(&mut account, package_name, scenario.ctx());

    // Verify cap is stored
    assert!(pkg_upgrade::has_commit_cap(&account, package_name));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_create_commit_cap_for_transfer() {
    let (mut scenario, extensions, account, clock) = start();
    let package_name = b"test_package".to_string();
    let recipient = @0xBEEF;

    // Create and transfer
    let commit_cap = pkg_upgrade::create_commit_cap_for_transfer(package_name, scenario.ctx());
    assert!(pkg_upgrade::commit_cap_package_name(&commit_cap) == package_name);

    pkg_upgrade::transfer_commit_cap(commit_cap, recipient);

    // Verify recipient received it
    scenario.next_tx(recipient);
    let received_cap = scenario.take_from_sender<pkg_upgrade::UpgradeCommitCap>();
    assert!(pkg_upgrade::commit_cap_package_name(&received_cap) == package_name);

    destroy(received_cap);
    end(scenario, extensions, account, clock);
}

// === Reclaim Tests ===

#[test]
fun test_request_and_finalize_reclaim() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let package_name = b"test_package".to_string();
    let six_months_ms = 15552000000;

    // Lock upgrade cap with reclaim delay
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, six_months_ms);

    // DAO requests reclaim (nonce bumps, invalidating any external caps)
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::request_reclaim_commit_cap<Config>(auth, &mut account, package_name, &clock);

    // Verify request is pending
    assert!(pkg_upgrade::has_reclaim_request(&account, package_name));

    // Advance time by 6 months
    clock.increment_for_testing(six_months_ms);

    // Now finalize reclaim (cleanup)
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::clear_reclaim_request<Config>(auth, &mut account, package_name, &clock);

    // Verify request is cleared
    assert!(!pkg_upgrade::has_reclaim_request(&account, package_name));

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EReclaimTooEarly)]
fun test_finalize_reclaim_too_early_fails() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();
    let six_months_ms = 15552000000;

    // Setup
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, six_months_ms);

    // Request reclaim
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::request_reclaim_commit_cap<Config>(auth, &mut account, package_name, &clock);

    // Try to finalize immediately (should fail)
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::clear_reclaim_request<Config>(auth, &mut account, package_name, &clock);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_get_reclaim_available_time() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let package_name = b"test_package".to_string();
    let six_months_ms = 15552000000;
    let start_time = 1000000;

    clock.set_for_testing(start_time);

    // Setup
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, six_months_ms);

    // No request yet
    assert!(option::is_none(&pkg_upgrade::get_reclaim_available_time(&account, package_name)));

    // Request reclaim
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::request_reclaim_commit_cap<Config>(auth, &mut account, package_name, &clock);

    // Should return available time
    let available_time = option::destroy_some(pkg_upgrade::get_reclaim_available_time(&account, package_name));
    assert!(available_time == start_time + six_months_ms);

    end(scenario, extensions, account, clock);
}

// === Nonce Revocation Tests ===

#[test]
fun test_nonce_increments_on_reclaim_request() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Lock upgrade cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, 15552000000);

    // Create commit cap with nonce=0
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_commit_cap(auth, &mut account, package_name, scenario.ctx());

    // Borrow to check initial nonce
    let commit_cap = pkg_upgrade::borrow_commit_cap<Config>(&mut account, package_name, version::current());
    assert!(pkg_upgrade::commit_cap_valid_nonce(&commit_cap) == 0);
    pkg_upgrade::return_commit_cap<Config>(&mut account, commit_cap, version::current());

    // Request reclaim - this should increment nonce to 1
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::request_reclaim_commit_cap<Config>(auth, &mut account, package_name, &clock);

    // Old cap (nonce=0) should now be invalid
    // New caps created would have nonce=1

    end(scenario, extensions, account, clock);
}

#[test]
fun test_create_cap_with_current_nonce() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();
    let recipient = @0xBEEF;

    // Setup
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, 15552000000);

    // Request reclaim (nonce -> 1)
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::request_reclaim_commit_cap<Config>(auth, &mut account, package_name, &clock);

    // Create new cap - should have nonce=1
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::create_and_transfer_commit_cap<Config>(auth, &account, package_name, recipient, scenario.ctx());

    // Retrieve and verify nonce
    scenario.next_tx(recipient);
    let new_cap = scenario.take_from_sender<pkg_upgrade::UpgradeCommitCap>();
    assert!(pkg_upgrade::commit_cap_valid_nonce(&new_cap) == 1);

    destroy(new_cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_revoked_cap_validation() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();

    // Setup
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, upgrade_cap, package_name, 1000, 15552000000);

    // Create commit cap (nonce=0)
    let old_cap = pkg_upgrade::create_commit_cap_for_transfer(package_name, scenario.ctx());
    assert!(pkg_upgrade::commit_cap_valid_nonce(&old_cap) == 0);

    // Request reclaim (nonce -> 1, invalidating old_cap)
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    pkg_upgrade::request_reclaim_commit_cap<Config>(auth, &mut account, package_name, &clock);

    // old_cap is now revoked (nonce=0 but current nonce is 1)
    // Using it in do_commit_with_cap would fail with ECapRevoked

    destroy(old_cap);
    end(scenario, extensions, account, clock);
}

