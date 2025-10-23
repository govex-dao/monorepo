#[test_only]
module account_protocol::config_intents_tests;

use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::config;
use account_protocol::deps;
use account_protocol::intents;
use account_protocol::version;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has copy, drop;

public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock, PackageAdminCap) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    account::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    // add core deps
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountConfig".to_string(), @0x1, 1);
    package_registry::update_for_testing(&mut extensions, &cap, b"AccountConfig".to_string(), @0x11, 2);
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountActions".to_string(), @0x2, 1);
    // add external dep
    package_registry::add_for_testing(&mut extensions, &cap, b"External".to_string(), @0xABC, 1);

    let deps = deps::new_latest_extensions(
        &extensions,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
    );
    let account = account::new(Config {}, deps, version::current(), Witness(), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    // create world
    (scenario, extensions, account, clock, cap)
}

fun end(scenario: Scenario, extensions: PackageRegistry, account: Account, clock: Clock, cap: PackageAdminCap) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    destroy(cap);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_edit_config_metadata() {
    let (scenario, extensions, mut account, clock, cap) = start();
    assert!(account.metadata().size() == 0);

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    config::edit_metadata<Config>(
        auth,
        &mut account,
        vector[b"name".to_string()],
        vector[b"New Name".to_string()],
    );

    assert!(account.metadata().get(b"name".to_string()) == b"New Name".to_string());
    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_update_extensions_to_latest() {
    let (scenario, mut extensions, mut account, clock, cap) = start();
    assert!(account.deps().get_by_name(b"AccountProtocol".to_string()).version() == 1);
    extensions.update_for_testing(&cap, b"AccountProtocol".to_string(), @0x3, 2);

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    config::update_extensions_to_latest<Config>(
        auth,
        &mut account,
        &extensions,
    );
    assert!(account.deps().get_by_name(b"AccountProtocol".to_string()).version() == 2);

    end(scenario, extensions, account, clock, cap);
}

// TODO: This test needs to be rewritten since Deps no longer has drop ability
// and cannot be directly replaced. The test should use the proper config actions
// to add unverified dependencies.
// #[test]
// fun test_update_extensions_to_latest_with_unverified() {
//     let (scenario, mut extensions, mut account, clock, cap) = start();
//     assert!(account.deps().get_by_name(b"AccountProtocol".to_string()).version() == 1);
//     extensions.update_for_testing(&cap, b"AccountProtocol".to_string(), @0x3, 2);

//     account.deps_mut(version::current()).toggle_unverified_allowed_for_testing();
//     // Need to use proper config actions to add unverified deps
//     let auth = account.new_auth<Config, Witness>(version::current(), Witness());
//     config::update_extensions_to_latest(
//         auth,
//         &mut account,
//         &extensions,
//     );

//     assert!(account.deps().get_by_name(b"AccountConfig".to_string()).version() == 2);
//     assert!(account.deps().get_by_name(b"AccountProtocol".to_string()).version() == 2);

//     end(scenario, extensions, account, clock, cap);
// }

#[test]
fun test_request_execute_config_deps() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let key = b"dummy".to_string();

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let params = intents::new_params(
        key,
        b"".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    config::request_config_deps<Config, Outcome>(
        auth,
        &mut account,
        params,
        Outcome {},
        &extensions,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"External".to_string(),
        ],
        vector[@account_protocol, @0x11, @0xABC],
        vector[1, 2, 1],
        scenario.ctx(),
    );
    assert!(!account.deps().contains_name(b"External".to_string()));

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    config::execute_config_deps<Config, Outcome>(&mut executable, &mut account, &extensions, version::current());
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<Outcome>(key, scenario.ctx());
    config::delete_config_deps(&mut expired);
    expired.destroy_empty();

    let package = account.deps().get_by_name(b"External".to_string());
    assert!(package.addr() == @0xABC);
    assert!(package.version() == 1);

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_config_deps_expired() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let params = intents::new_params(
        key,
        b"".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    config::request_config_deps<Config, Outcome>(
        auth,
        &mut account,
        params,
        Outcome {},
        &extensions,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x11],
        vector[1, 2],
        scenario.ctx(),
    );

    let mut expired = account.delete_expired_intent<Outcome>(key, &clock, scenario.ctx());
    config::delete_config_deps(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_request_execute_toggle_unverified_allowed() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let key = b"dummy".to_string();

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let params = intents::new_params(
        key,
        b"".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    config::request_toggle_unverified_allowed<Config, Outcome>(
        auth,
        &mut account,
        params,
        Outcome {},
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    config::execute_toggle_unverified_allowed<Config, Outcome>(&mut executable, &mut account, version::current());
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<Outcome>(key, scenario.ctx());
    config::delete_toggle_unverified_allowed(&mut expired);
    expired.destroy_empty();

    assert!(account.deps().unverified_allowed() == true);

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_toggle_unverified_allowed_expired() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let params = intents::new_params(
        key,
        b"".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    config::request_toggle_unverified_allowed<Config, Outcome>(
        auth,
        &mut account,
        params,
        Outcome {},
        scenario.ctx(),
    );

    let mut expired = account.delete_expired_intent<Outcome>(key, &clock, scenario.ctx());
    config::delete_toggle_unverified_allowed(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, clock, cap);
}
