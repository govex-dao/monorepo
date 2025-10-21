#[test_only]
module account_actions::currency_tests;

use account_actions::currency;
use account_actions::version;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intent_interface;
use account_protocol::intents;
use std::option;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Macros ===

use fun intent_interface::build_intent as Account.build_intent;

// === Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT: address = @0xBEEF;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// Intent witness for testing
public struct CurrencyIntent() has copy, drop;

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

// Helper to create a TreasuryCap for testing without CoinMetadata
// Since we can't use create_currency in tests (requires OTW), we'll use test utilities
fun create_test_treasury_cap<T>(ctx: &mut TxContext): TreasuryCap<T> {
    coin::create_treasury_cap_for_testing<T>(ctx)
}

// === Tests ===

#[test]
fun test_lock_cap_basic() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Create a treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());

    // Lock the cap with no max supply
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Verify the cap is locked
    assert!(currency::has_cap<SUI>(&account), 0);

    // Check rules
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::can_mint(rules), 1);
    assert!(currency::can_burn(rules), 2);
    assert!(currency::total_minted(rules) == 0, 3);
    assert!(currency::total_burned(rules) == 0, 4);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_cap_with_max_supply() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());

    // Lock the cap with max supply of 1_000_000
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::some(1_000_000));

    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::max_supply(rules) == option::some(1_000_000), 0);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_mint_and_burn_basic() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_mint_burn".to_string();

    // Setup: Lock treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Create intent with mint action
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test mint".to_string(),
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
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_mint<_, SUI, _>(intent, 100, iw);
        },
    );

    // Execute mint
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    let minted_coin = currency::do_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable,
        &mut account,
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
    );

    assert!(minted_coin.value() == 100, 0);

    account.confirm_execution(executable);

    // Verify total_minted updated
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::total_minted(rules) == 100, 1);

    // Now test burn
    let key2 = b"test_burn".to_string();
    let params2 = intents::new_params(
        key2,
        b"Test burn".to_string(),
        vector[0],
        2000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params2,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_burn<_, SUI, _>(intent, 100, iw);
        },
    );

    let (_, mut executable2) = account.create_executable<Config, Outcome, Witness>(
        key2,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    currency::do_burn<Outcome, SUI, CurrencyIntent>(
        &mut executable2,
        &mut account,
        minted_coin,
        version::current(),
        CurrencyIntent(),
    );

    account.confirm_execution(executable2);

    // Verify total_burned updated
    let rules2 = currency::borrow_rules<SUI>(&account);
    assert!(currency::total_burned(rules2) == 100, 2);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EMaxSupply)]
fun test_mint_exceeds_max_supply() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_max_supply".to_string();

    // Lock cap with max supply of 50
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::some(50));

    // Try to mint 100 (exceeds max supply)
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test max supply".to_string(),
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
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_mint<_, SUI, _>(intent, 100, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // This should abort with EMaxSupply
    let coin = currency::do_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable,
        &mut account,
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
    );

    destroy(coin);
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_disable_permissions() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_disable".to_string();

    // Lock treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Create intent to disable mint and burn
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test disable".to_string(),
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
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_disable<_, SUI, _>(
                intent,
                true, // mint
                true, // burn
                false, // update_symbol
                false, // update_name
                false, // update_description
                false, // update_icon
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    currency::do_disable<Outcome, SUI, CurrencyIntent>(
        &mut executable,
        &mut account,
        version::current(),
        CurrencyIntent(),
    );

    account.confirm_execution(executable);

    // Verify mint and burn are disabled
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(!currency::can_mint(rules), 0);
    assert!(!currency::can_burn(rules), 1);
    assert!(currency::can_update_symbol(rules), 2); // Still enabled
    assert!(currency::can_update_name(rules), 3); // Still enabled

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EMintDisabled)]
fun test_mint_when_disabled() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock and disable mint
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    let key1 = b"disable".to_string();
    let outcome = Outcome {};
    let params1 = intents::new_params(
        key1,
        b"Disable".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params1,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_disable<_, SUI, _>(intent, true, false, false, false, false, false, iw);
        },
    );

    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        key1,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    currency::do_disable<Outcome, SUI, CurrencyIntent>(
        &mut exec1,
        &mut account,
        version::current(),
        CurrencyIntent(),
    );
    account.confirm_execution(exec1);

    // Now try to mint (should fail)
    let key2 = b"mint".to_string();
    let params2 = intents::new_params(
        key2,
        b"Mint".to_string(),
        vector[0],
        2000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params2,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_mint<_, SUI, _>(intent, 50, iw);
        },
    );

    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        key2,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // This should abort with EMintDisabled
    let coin = currency::do_mint<Outcome, SUI, CurrencyIntent>(
        &mut exec2,
        &mut account,
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
    );

    destroy(coin);
    account.confirm_execution(exec2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_public_burn() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock treasury cap with burn enabled
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Mint a coin first
    let key = b"mint".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Mint".to_string(),
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
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_mint<_, SUI, _>(intent, 200, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    let coin = currency::do_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable,
        &mut account,
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Now anyone can burn it using public_burn
    currency::public_burn<Config, SUI>(&mut account, coin);

    // Verify burn was recorded
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::total_burned(rules) == 200, 0);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_cap_unshared() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Create treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());

    // Lock using unshared function (for init-time locking)
    currency::do_lock_cap_unshared(&mut account, treasury_cap);

    // Verify the cap is locked
    assert!(currency::has_cap<SUI>(&account), 0);

    // Check default rules
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::can_mint(rules), 1);
    assert!(currency::can_burn(rules), 2);
    assert!(currency::max_supply(rules).is_none(), 3);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_mint_unshared() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock cap and mint using unshared functions
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    currency::do_lock_cap_unshared(&mut account, treasury_cap);

    // Mint directly to recipient
    currency::do_mint_unshared<SUI>(&mut account, 500, RECIPIENT, scenario.ctx());

    // Verify total_minted
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::total_minted(rules) == 500, 0);

    // Verify recipient received coin
    scenario.next_tx(RECIPIENT);
    assert!(ts::has_most_recent_for_address<Coin<SUI>>(RECIPIENT), 1);
    let received = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    assert!(received.value() == 500, 2);

    destroy(received);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_mint_to_coin_unshared() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    currency::do_lock_cap_unshared(&mut account, treasury_cap);

    // Mint and get coin object
    let coin = currency::do_mint_to_coin_unshared<SUI>(&mut account, 750, scenario.ctx());

    assert!(coin.value() == 750, 0);

    // Verify total_minted
    let rules = currency::borrow_rules<SUI>(&account);
    assert!(currency::total_minted(rules) == 750, 1);

    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EWrongValue)]
fun test_burn_wrong_value() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Setup
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Mint a coin
    let key1 = b"mint".to_string();
    let outcome = Outcome {};
    let params1 = intents::new_params(
        key1,
        b"Mint".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        params1,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_mint<_, SUI, _>(intent, 100, iw);
        },
    );
    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        key1,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    let coin = currency::do_mint<Outcome, SUI, CurrencyIntent>(
        &mut exec1,
        &mut account,
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(exec1);

    // Try to burn with wrong amount (50 instead of 100)
    let key2 = b"burn".to_string();
    let params2 = intents::new_params(
        key2,
        b"Burn".to_string(),
        vector[0],
        2000,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        params2,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_burn<_, SUI, _>(intent, 50, iw);
        },
    );
    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        key2,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // This should abort with EWrongValue
    currency::do_burn<Outcome, SUI, CurrencyIntent>(
        &mut exec2,
        &mut account,
        coin,
        version::current(),
        CurrencyIntent(),
    );

    account.confirm_execution(exec2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_delete_actions() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create intents with all action types
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    let outcome = Outcome {};

    // Create multiple intents to test all delete functions
    let key1 = b"disable".to_string();
    let params1 = intents::new_params(
        key1,
        b"".to_string(),
        vector[0],
        clock.timestamp_ms() + 100,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        params1,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_disable<_, SUI, _>(intent, true, false, false, false, false, false, iw);
        },
    );

    let key2 = b"mint".to_string();
    let params2 = intents::new_params(
        key2,
        b"".to_string(),
        vector[0],
        clock.timestamp_ms() + 100,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        params2,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_mint<_, SUI, _>(intent, 10, iw);
        },
    );

    let key3 = b"burn".to_string();
    let params3 = intents::new_params(
        key3,
        b"".to_string(),
        vector[0],
        clock.timestamp_ms() + 100,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        params3,
        outcome,
        b"".to_string(),
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
        |intent, iw| {
            currency::new_burn<_, SUI, _>(intent, 10, iw);
        },
    );

    // Execute each to consume execution time
    // Execute mint first before disable
    let (_, mut e2) = account.create_executable<Config, Outcome, Witness>(
        key2,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    let c = currency::do_mint<Outcome, SUI, CurrencyIntent>(
        &mut e2,
        &mut account,
        version::current(),
        CurrencyIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(e2);

    let (_, mut e3) = account.create_executable<Config, Outcome, Witness>(
        key3,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    currency::do_burn<Outcome, SUI, CurrencyIntent>(
        &mut e3,
        &mut account,
        c,
        version::current(),
        CurrencyIntent(),
    );
    account.confirm_execution(e3);

    let (_, mut e1) = account.create_executable<Config, Outcome, Witness>(
        key1,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    currency::do_disable<Outcome, SUI, CurrencyIntent>(
        &mut e1,
        &mut account,
        version::current(),
        CurrencyIntent(),
    );
    account.confirm_execution(e1);

    // Now delete all expired intents
    let mut exp1 = account.destroy_empty_intent<Outcome>(key1, scenario.ctx());
    currency::delete_disable<SUI>(&mut exp1);
    exp1.destroy_empty();

    let mut exp2 = account.destroy_empty_intent<Outcome>(key2, scenario.ctx());
    currency::delete_mint<SUI>(&mut exp2);
    exp2.destroy_empty();

    let mut exp3 = account.destroy_empty_intent<Outcome>(key3, scenario.ctx());
    currency::delete_burn<SUI>(&mut exp3);
    exp3.destroy_empty();

    end(scenario, extensions, account, clock);
}
