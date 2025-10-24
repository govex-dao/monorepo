#[test_only]
module account_actions::package_upgrade_digest_tests;

use account_actions::package_upgrade as pkg_upgrade;
use account_actions::version;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use sui::clock::{Self, Clock};
use sui::package::{Self, UpgradeCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Constants ===

const OWNER: address = @0xCAFE;
const SIX_MONTHS_MS: u64 = 15552000000;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

// OTW for creating UpgradeCap
public struct PACKAGE_UPGRADE_DIGEST_TESTS has drop {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();

    package_registry::add_for_testing(&mut extensions, &cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountActions".to_string(), @account_actions, 1);

    let deps = deps::new_latest_extensions(
        &extensions,
        vector[b"AccountProtocol".to_string(), b"AccountActions".to_string()],
    );
    let account = account::new(Config {}, deps, &extensions, version::current(), Witness(), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

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
    let publisher = package::test_claim(PACKAGE_UPGRADE_DIGEST_TESTS {}, scenario.ctx());
    let upgrade_cap = package::test_publish(object::id(&publisher), scenario.ctx());
    destroy(publisher);
    upgrade_cap
}

// === Tests ===

#[test]
fun test_propose_and_approve_digest() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let package_name = b"test_package".to_string();
    let digest = b"0123456789abcdef0123456789abcdef";

    // Lock upgrade cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, &extensions, upgrade_cap, package_name, 1000, SIX_MONTHS_MS);

    // Propose upgrade digest
    let execution_time = clock.timestamp_ms() + 7 * 86400000; // 7 days
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::propose_upgrade_digest(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        execution_time,
        &clock,
    );

    // Verify proposal exists
    assert!(pkg_upgrade::has_upgrade_proposal(&account, package_name, digest));
    assert!(!pkg_upgrade::is_upgrade_approved(&account, &extensions, package_name, digest));

    // Approve proposal (simulating governance vote passed)
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::approve_upgrade_proposal<Config>(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        &clock,
    );

    // Verify approved
    assert!(pkg_upgrade::is_upgrade_approved(&account, &extensions, package_name, digest));

    // Get proposal details
    let (prop_digest, _proposed_time, exec_time, approved) = pkg_upgrade::get_upgrade_proposal(
        &account,
        &extensions,
        package_name,
        digest,
    );
    assert!(prop_digest == digest);
    assert!(exec_time == execution_time);
    assert!(approved);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeTooEarly)]
fun test_cannot_propose_without_timelock() {
    let (mut scenario, extensions, mut account, clock) = start();
    let package_name = b"test_package".to_string();
    let digest = b"0123456789abcdef0123456789abcdef";

    // Lock upgrade cap with 1000ms delay
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, &extensions, upgrade_cap, package_name, 1000, SIX_MONTHS_MS);

    // Try to propose with execution time too soon (less than 1000ms)
    let execution_time = clock.timestamp_ms() + 500; // Only 500ms - should fail
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::propose_upgrade_digest(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        execution_time,
        &clock,
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EProposalNotApproved)]
fun test_cannot_execute_unapproved_proposal() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let package_name = b"test_package".to_string();
    let digest = b"0123456789abcdef0123456789abcdef";

    // Lock upgrade cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, &extensions, upgrade_cap, package_name, 1000, SIX_MONTHS_MS);

    // Propose but don't approve
    let execution_time = clock.timestamp_ms() + 7 * 86400000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::propose_upgrade_digest(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        execution_time,
        &clock,
    );

    // Fast forward to execution time
    clock.set_for_testing(execution_time);

    // Try to execute without approval - should fail
    let _ticket = pkg_upgrade::execute_approved_upgrade_dao_only<Config>(
        &mut account,
        &extensions,
        package_name,
        digest,
        &clock,
        version::current(),
    );

    abort 999 // Should not reach here
}

#[test]
fun test_execute_approved_upgrade_dao_only() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let package_name = b"test_package".to_string();
    let mut digest = vector::empty<u8>();
    // Create 32-byte digest
    let mut i = 0;
    while (i < 32) {
        digest.push_back((i as u8));
        i = i + 1;
    };

    // Lock upgrade cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, &extensions, upgrade_cap, package_name, 1000, SIX_MONTHS_MS);

    // Propose and approve
    let execution_time = clock.timestamp_ms() + 7 * 86400000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::propose_upgrade_digest(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        execution_time,
        &clock,
    );

    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::approve_upgrade_proposal<Config>(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        &clock,
    );

    // Fast forward to execution time
    clock.set_for_testing(execution_time);

    // Execute - creates UpgradeTicket
    let ticket = pkg_upgrade::execute_approved_upgrade_dao_only<Config>(
        &mut account,
        &extensions,
        package_name,
        digest,
        &clock,
        version::current(),
    );

    // In real flow, ticket would be consumed by sui upgrade command
    // For testing, we use test_upgrade
    let receipt = package::test_upgrade(ticket);

    // Complete upgrade - use test version that skips package validation
    pkg_upgrade::complete_approved_upgrade_dao_only_for_testing<Config>(
        &mut account,
        &extensions,
        package_name,
        digest,
        receipt,
        version::current(),
    );

    // Verify proposal was cleaned up
    assert!(!pkg_upgrade::has_upgrade_proposal(&account, package_name, digest));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_execute_with_commit_cap() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let package_name = b"test_package".to_string();
    let mut digest = vector::empty<u8>();
    let mut i = 0;
    while (i < 32) {
        digest.push_back((i as u8));
        i = i + 1;
    };

    // Lock upgrade cap
    let upgrade_cap = create_test_upgrade_cap(&mut scenario);
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::lock_cap(auth, &mut account, &extensions, upgrade_cap, package_name, 1000, SIX_MONTHS_MS);

    // Lock commit cap in account (nonce=0)
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::lock_commit_cap(auth, &mut account, &extensions, package_name, scenario.ctx());

    // Propose and approve
    let execution_time = clock.timestamp_ms() + 7 * 86400000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::propose_upgrade_digest(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        execution_time,
        &clock,
    );

    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    pkg_upgrade::approve_upgrade_proposal<Config>(
        auth,
        &mut account,
        &extensions,
        package_name,
        digest,
        &clock,
    );

    // Fast forward
    clock.set_for_testing(execution_time);

    // Borrow commit cap
    let commit_cap = pkg_upgrade::borrow_commit_cap<Config>(&mut account, &extensions, package_name, version::current());

    // Execute with cap
    let ticket = pkg_upgrade::execute_approved_upgrade_with_cap<Config>(
        &mut account,
        &extensions,
        package_name,
        digest,
        &commit_cap,
        &clock,
        version::current(),
    );

    let receipt = package::test_upgrade(ticket);

    // Complete with cap
    pkg_upgrade::complete_approved_upgrade_with_cap<Config>(
        &mut account,
        &extensions,
        package_name,
        digest,
        receipt,
        &commit_cap,
        version::current(),
    );

    // Return cap
    pkg_upgrade::return_commit_cap<Config>(&mut account, &extensions, commit_cap, version::current());

    // Verify proposal cleaned up
    assert!(!pkg_upgrade::has_upgrade_proposal(&account, package_name, digest));

    end(scenario, extensions, account, clock);
}
