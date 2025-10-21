#[test_only]
module account_protocol::owned_tests;

use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intents::{Self, Intent};
use account_protocol::owned;
use account_protocol::version;
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct DummyIntent() has drop;
public struct WrongWitness() has drop;

public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
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
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountMultisig".to_string(), @0x1, 1);
    package_registry::add_for_testing(&mut extensions, &cap, b"AccountActions".to_string(), @0x2, 1);
    // Account generic types are dummy types (bool, bool)
    let deps = deps::new_latest_extensions(&extensions, vector[b"AccountProtocol".to_string()]);
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

fun send_coin(addr: address, amount: u64, scenario: &mut Scenario): ID {
    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let id = object::id(&coin);
    transfer::public_transfer(coin, addr);

    scenario.next_tx(OWNER);
    id
}

fun create_dummy_intent(
    scenario: &mut Scenario,
    account: &Account,
    clock: &Clock,
): Intent<Outcome> {
    let params = intents::new_params(
        b"dummy".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        clock,
        scenario.ctx(),
    );
    account.create_intent(
        params,
        Outcome {},
        b"Degen".to_string(),
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    )
}

fun keep_coin(addr: address, amount: u64, scenario: &mut Scenario): ID {
    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let id = object::id(&coin);
    transfer::public_transfer(coin, addr);

    scenario.next_tx(OWNER);
    id
}

// === Tests ===

#[test]
fun test_withdraw_flow() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"dummy".to_string();

    let id = send_coin(account.addr(), 5, &mut scenario);

    let mut intent = create_dummy_intent(&mut scenario, &account, &clock);
    let coin_type = type_name::with_defining_ids<SUI>().into_string().to_string();
    owned::new_withdraw_coin<Outcome, DummyIntent>(&mut intent, &account, coin_type, 5, DummyIntent());
    account.insert_intent(intent, version::current(), DummyIntent());

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    let coin = owned::do_withdraw_coin<Outcome, SUI, DummyIntent>(
        &mut executable,
        &mut account,
        ts::receiving_ticket_by_id<Coin<SUI>>(id),
        DummyIntent(),
    );
    account.confirm_execution(executable);

    assert!(coin.value() == 5);
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_withdraw_expired() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    let id = send_coin(account.addr(), 5, &mut scenario);

    let mut intent = create_dummy_intent(&mut scenario, &account, &clock);
    let coin_type = type_name::with_defining_ids<SUI>().into_string().to_string();
    owned::new_withdraw_coin<Outcome, DummyIntent>(&mut intent, &account, coin_type, 5, DummyIntent());
    account.insert_intent(intent, version::current(), DummyIntent());

    let mut expired = account.delete_expired_intent<Outcome>(key, &clock, scenario.ctx());
    owned::delete_withdraw_coin(&mut expired, &mut account);
    expired.destroy_empty();

    end(scenario, extensions, account, clock);
}

#[test]
fun test_merge_and_split_2_coins() {
    let (mut scenario, extensions, mut account, clock) = start();

    let coin_to_split = coin::mint_for_testing<SUI>(100, scenario.ctx());
    transfer::public_transfer(coin_to_split, account.addr());

    scenario.next_tx(OWNER);
    let receiving_to_split = ts::most_recent_receiving_ticket<Coin<SUI>>(&object::id(&account));
    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let split_coin_ids = owned::merge_and_split<Config, SUI>(
        auth,
        &mut account,
        vector[receiving_to_split],
        vector[40, 30],
        scenario.ctx(),
    );

    scenario.next_tx(OWNER);
    let split_coin0 = scenario.take_from_address_by_id<Coin<SUI>>(
        account.addr(),
        split_coin_ids[0],
    );
    let split_coin1 = scenario.take_from_address_by_id<Coin<SUI>>(
        account.addr(),
        split_coin_ids[1],
    );
    assert!(split_coin0.value() == 40);
    assert!(split_coin1.value() == 30);

    destroy(split_coin0);
    destroy(split_coin1);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_merge_2_coins_and_split() {
    let (mut scenario, extensions, mut account, clock) = start();
    let account_address = account.addr();

    let id1 = keep_coin(account_address, 60, &mut scenario);
    let id2 = keep_coin(account_address, 40, &mut scenario);

    let auth = account.new_auth<Config, Witness>(version::current(), Witness());
    let merge_coin_id = owned::merge_and_split<Config, SUI>(
        auth,
        &mut account,
        vector[ts::receiving_ticket_by_id(id1), ts::receiving_ticket_by_id(id2)],
        vector[100],
        scenario.ctx(),
    );

    scenario.next_tx(OWNER);
    let merge_coin = scenario.take_from_address_by_id<Coin<SUI>>(
        account_address,
        merge_coin_id[0],
    );
    assert!(merge_coin.value() == 100);

    destroy(merge_coin);
    end(scenario, extensions, account, clock);
}

// REMOVED: test_error_do_withdraw_wrong_object - new API doesn't validate specific object IDs, only type and amount
// REMOVED: test_error_merge_locked_coins - no locking in new design
// Conflicts are natural and resolved at execution time

// sanity checks as these are tested in AccountProtocol tests

#[test, expected_failure(abort_code = intents::EWrongAccount)]
fun test_error_do_withdraw_from_wrong_account() {
    let (mut scenario, extensions, mut account, clock) = start();

    let deps = deps::new_latest_extensions(&extensions, vector[b"AccountProtocol".to_string()]);
    let mut account2 = account::new(Config {}, deps, version::current(), Witness(), scenario.ctx());
    let key = b"dummy".to_string();

    let id = send_coin(account.addr(), 5, &mut scenario);

    // intent is submitted to other account
    let mut intent = create_dummy_intent(&mut scenario, &account2, &clock);
    let coin_type = type_name::with_defining_ids<SUI>().into_string().to_string();
    owned::new_withdraw_coin<Outcome, DummyIntent>(&mut intent, &account, coin_type, 5, DummyIntent());
    account2.insert_intent(intent, version::current(), DummyIntent());

    let (_, mut executable) = account2.create_executable<Config, Outcome, Witness>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );
    // try to disable from the account that didn't approve the intent
    let coin = owned::do_withdraw_coin<Outcome, SUI, DummyIntent>(
        &mut executable,
        &mut account,
        ts::receiving_ticket_by_id<Coin<SUI>>(id),
        DummyIntent(),
    );

    destroy(coin);
    destroy(account2);
    destroy(executable);
    end(scenario, extensions, account, clock);
}

// REMOVED: test_error_do_withdraw_from_wrong_constructor_witness
// Witness is validated at intent creation time, not execution time

#[test, expected_failure(abort_code = intents::EWrongAccount)]
fun test_error_delete_withdraw_from_wrong_account() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let deps = deps::new_latest_extensions(&extensions, vector[b"AccountProtocol".to_string()]);
    let mut account2 = account::new(Config {}, deps, version::current(), Witness(), scenario.ctx());

    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    let id = send_coin(account.addr(), 5, &mut scenario);

    let mut intent = create_dummy_intent(&mut scenario, &account, &clock);
    let coin_type = type_name::with_defining_ids<SUI>().into_string().to_string();
    owned::new_withdraw_coin<Outcome, DummyIntent>(&mut intent, &account, coin_type, 5, DummyIntent());
    account.insert_intent(intent, version::current(), DummyIntent());

    let mut expired = account.delete_expired_intent<Outcome>(key, &clock, scenario.ctx());
    owned::delete_withdraw_coin(&mut expired, &mut account2);
    expired.destroy_empty();

    destroy(account2);
    end(scenario, extensions, account, clock);
}
