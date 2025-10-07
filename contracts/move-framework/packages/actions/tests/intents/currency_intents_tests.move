#[test_only]
module account_actions::currency_intents_tests;

// === Imports ===

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    sui::SUI,
};
use std::option;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::{Self, Account},
    intents,
    deps,
};
use account_actions::{
    currency,
    currency_intents,
    version,
};

// === Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT1: address = @0xBEEF;
const RECIPIENT2: address = @0xDEAD;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// === Helpers ===

fun start(): (Scenario, Extensions, Account<Config>, Clock) {
    let mut scenario = ts::begin(OWNER);
    extensions::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @account_actions, 1);

    let deps = deps::new_latest_extensions(&extensions, vector[b"AccountProtocol".to_string(), b"AccountActions".to_string()]);
    let account = account::new(Config {}, deps, version::current(), Witness(), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    destroy(cap);
    (scenario, extensions, account, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<Config>, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

fun create_test_treasury_cap<T>(ctx: &mut TxContext): TreasuryCap<T> {
    coin::create_treasury_cap_for_testing<T>(ctx)
}

// === Tests ===

#[test]
fun test_request_disable_rules() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Create disable rules intent
    let key = b"disable".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Disable".to_string(), vector[0], 1000, &clock, scenario.ctx());

    let auth2 = account.new_auth(version::current(), Witness());
    currency_intents::request_disable_rules<_, _, SUI>(
        auth2,
        &mut account,
        params,
        outcome,
        true,  // mint
        true,  // burn
        false, // update_symbol
        false, // update_name
        false, // update_description
        false, // update_icon
        scenario.ctx()
    );

    // Execute
    let (_, mut executable) = account.create_executable<_, Outcome, _>(key, &clock, version::current(), Witness(), scenario.ctx());
    currency_intents::execute_disable_rules<Config, Outcome, SUI>(&mut executable, &mut account);
    account.confirm_execution(executable);

    // Verify
    let rules = currency::borrow_rules<Config, SUI>(&account);
    assert!(!currency::can_mint(rules), 0);
    assert!(!currency::can_burn(rules), 1);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency_intents::ENoLock)]
fun test_request_disable_rules_without_lock() {
    let (mut scenario, extensions, mut account, clock) = start();

    let key = b"disable".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Disable".to_string(), vector[0], 1000, &clock, scenario.ctx());

    let auth = account.new_auth(version::current(), Witness());

    // Should abort - no treasury cap locked
    currency_intents::request_disable_rules<_, _, SUI>(
        auth,
        &mut account,
        params,
        outcome,
        true, false, false, false, false, false,
        scenario.ctx()
    );

    end(scenario, extensions, account, clock);
}

#[test]
fun test_request_mint_and_transfer_single() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Create mint and transfer intent
    let key = b"mint_transfer".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Mint and Transfer".to_string(), vector[0], 1000, &clock, scenario.ctx());

    let auth2 = account.new_auth(version::current(), Witness());
    currency_intents::request_mint_and_transfer<_, _, SUI>(
        auth2,
        &mut account,
        params,
        outcome,
        vector[100],
        vector[RECIPIENT1],
        scenario.ctx()
    );

    // Execute
    let (_, mut executable) = account.create_executable<_, Outcome, _>(key, &clock, version::current(), Witness(), scenario.ctx());
    currency_intents::execute_mint_and_transfer<Config, Outcome, SUI>(&mut executable, &mut account, scenario.ctx());
    account.confirm_execution(executable);

    // Verify recipient received coin
    scenario.next_tx(RECIPIENT1);
    assert!(ts::has_most_recent_for_address<Coin<SUI>>(RECIPIENT1), 0);
    let received = scenario.take_from_address<Coin<SUI>>(RECIPIENT1);
    assert!(received.value() == 100, 1);

    destroy(received);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_request_mint_and_transfer_multiple() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock treasury cap
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Create mint and transfer intent with multiple recipients
    let key = b"mint_multi".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Mint Multiple".to_string(), vector[0], 1000, &clock, scenario.ctx());

    let auth2 = account.new_auth(version::current(), Witness());
    currency_intents::request_mint_and_transfer<_, _, SUI>(
        auth2,
        &mut account,
        params,
        outcome,
        vector[100, 200, 300],
        vector[RECIPIENT1, RECIPIENT2, OWNER],
        scenario.ctx()
    );

    // Execute all three mints
    let (_, mut executable) = account.create_executable<_, Outcome, _>(key, &clock, version::current(), Witness(), scenario.ctx());
    currency_intents::execute_mint_and_transfer<Config, Outcome, SUI>(&mut executable, &mut account, scenario.ctx());
    currency_intents::execute_mint_and_transfer<Config, Outcome, SUI>(&mut executable, &mut account, scenario.ctx());
    currency_intents::execute_mint_and_transfer<Config, Outcome, SUI>(&mut executable, &mut account, scenario.ctx());
    account.confirm_execution(executable);

    // Verify all recipients
    scenario.next_tx(RECIPIENT1);
    let c1 = scenario.take_from_address<Coin<SUI>>(RECIPIENT1);
    assert!(c1.value() == 100, 0);

    scenario.next_tx(RECIPIENT2);
    let c2 = scenario.take_from_address<Coin<SUI>>(RECIPIENT2);
    assert!(c2.value() == 200, 1);

    scenario.next_tx(OWNER);
    let c3 = scenario.take_from_sender<Coin<SUI>>();
    assert!(c3.value() == 300, 2);

    destroy(c1);
    destroy(c2);
    destroy(c3);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency_intents::EAmountsRecipentsNotSameLength)]
fun test_request_mint_and_transfer_length_mismatch() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    let key = b"mismatch".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Mismatch".to_string(), vector[0], 1000, &clock, scenario.ctx());

    let auth2 = account.new_auth(version::current(), Witness());

    // Should abort - different lengths
    currency_intents::request_mint_and_transfer<_, _, SUI>(
        auth2,
        &mut account,
        params,
        outcome,
        vector[100, 200],  // 2 amounts
        vector[RECIPIENT1], // 1 recipient
        scenario.ctx()
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency_intents::EMintDisabled)]
fun test_request_mint_and_transfer_mint_disabled() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock and disable mint
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Disable mint first
    let key1 = b"disable".to_string();
    let outcome = Outcome {};
    let params1 = intents::new_params(key1, b"Disable".to_string(), vector[0], 1000, &clock, scenario.ctx());
    let auth1 = account.new_auth(version::current(), Witness());
    currency_intents::request_disable_rules<_, _, SUI>(auth1, &mut account, params1, outcome, true, false, false, false, false, false, scenario.ctx());
    let (_, mut exec1) = account.create_executable<_, Outcome, _>(key1, &clock, version::current(), Witness(), scenario.ctx());
    currency_intents::execute_disable_rules<Config, Outcome, SUI>(&mut exec1, &mut account);
    account.confirm_execution(exec1);

    // Try to mint (should fail)
    let key2 = b"mint".to_string();
    let params2 = intents::new_params(key2, b"Mint".to_string(), vector[0], 2000, &clock, scenario.ctx());
    let auth2 = account.new_auth(version::current(), Witness());

    // Should abort - mint is disabled
    currency_intents::request_mint_and_transfer<_, _, SUI>(
        auth2,
        &mut account,
        params2,
        outcome,
        vector[100],
        vector[RECIPIENT1],
        scenario.ctx()
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency_intents::EMaxSupply)]
fun test_request_mint_and_transfer_exceeds_max_supply() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock with max supply of 50
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::some(50));

    let key = b"mint".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Mint".to_string(), vector[0], 1000, &clock, scenario.ctx());
    let auth2 = account.new_auth(version::current(), Witness());

    // Should abort - total exceeds max supply
    currency_intents::request_mint_and_transfer<_, _, SUI>(
        auth2,
        &mut account,
        params,
        outcome,
        vector[30, 30],  // Total 60 > max 50
        vector[RECIPIENT1, RECIPIENT2],
        scenario.ctx()
    );

    end(scenario, extensions, account, clock);
}

#[test]
fun test_request_withdraw_and_burn() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Create treasury cap, mint a coin, then lock it
    let mut treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let coin = coin::mint(&mut treasury_cap, 100, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, account.addr());

    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Create withdraw and burn intent
    scenario.next_tx(OWNER);
    let key = b"burn".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(key, b"Burn".to_string(), vector[0], 1000, &clock, scenario.ctx());

    let auth2 = account.new_auth(version::current(), Witness());
    currency_intents::request_withdraw_and_burn<_, _, SUI>(
        auth2,
        &mut account,
        params,
        outcome,
        coin_id,
        100,
        scenario.ctx()
    );

    // Execute
    scenario.next_tx(OWNER);
    let (_, mut executable) = account.create_executable<_, Outcome, _>(key, &clock, version::current(), Witness(), scenario.ctx());
    let receiving = ts::most_recent_receiving_ticket<Coin<SUI>>(&object::id(&account));
    currency_intents::execute_withdraw_and_burn<Config, Outcome, SUI>(&mut executable, &mut account, receiving);
    account.confirm_execution(executable);

    // Verify burn was recorded
    let rules = currency::borrow_rules<Config, SUI>(&account);
    assert!(currency::total_burned(rules) == 100, 0);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency_intents::EBurnDisabled)]
fun test_request_withdraw_and_burn_disabled() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock and disable burn
    let treasury_cap = create_test_treasury_cap<SUI>(scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    currency::lock_cap(auth, &mut account, treasury_cap, option::none());

    // Disable burn
    let key1 = b"disable".to_string();
    let outcome = Outcome {};
    let params1 = intents::new_params(key1, b"Disable".to_string(), vector[0], 1000, &clock, scenario.ctx());
    let auth1 = account.new_auth(version::current(), Witness());
    currency_intents::request_disable_rules<_, _, SUI>(auth1, &mut account, params1, outcome, false, true, false, false, false, false, scenario.ctx());
    let (_, mut exec1) = account.create_executable<_, Outcome, _>(key1, &clock, version::current(), Witness(), scenario.ctx());
    currency_intents::execute_disable_rules<Config, Outcome, SUI>(&mut exec1, &mut account);
    account.confirm_execution(exec1);

    // Try to burn (should fail)
    let coin_id = object::id_from_address(@0x1);
    let key2 = b"burn".to_string();
    let params2 = intents::new_params(key2, b"Burn".to_string(), vector[0], 2000, &clock, scenario.ctx());
    let auth2 = account.new_auth(version::current(), Witness());

    // Should abort - burn is disabled
    currency_intents::request_withdraw_and_burn<_, _, SUI>(
        auth2,
        &mut account,
        params2,
        outcome,
        coin_id,
        100,
        scenario.ctx()
    );

    end(scenario, extensions, account, clock);
}
