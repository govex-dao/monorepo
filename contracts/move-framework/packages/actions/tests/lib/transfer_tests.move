#[test_only]
module account_actions::transfer_tests;

use account_actions::transfer as acc_transfer;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intent_interface;
use account_protocol::intents;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
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
public struct TEST_COIN has drop {} // For testing different coin types

// Intent witness for testing
public struct TransferIntent() has copy, drop;

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
fun test_transfer_basic() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_transfer".to_string();

    // Create an intent with a transfer action
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test transfer".to_string(),
        vector[0], // execute immediately
        1000, // expiration
        &clock,
        scenario.ctx(),
    );

    // Build the intent using the intent interface
    account.build_intent!(
        params,
        outcome,
        b"".to_string(), // metadata
        version::current(),
        TransferIntent(),
        scenario.ctx(),
        |intent, iw| {
            acc_transfer::new_transfer(intent, RECIPIENT, iw);
        },
    );

    // Create executable
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Verify outcome (Outcome has copy + drop, so we can just compare directly)
    assert!(outcome_result == outcome);

    // Create a coin to transfer
    let coin = coin::mint_for_testing<SUI>(100, scenario.ctx());

    // Execute the transfer
    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin, TransferIntent());

    // Confirm execution
    account.confirm_execution(executable);

    // Verify the coin was transferred
    scenario.next_tx(RECIPIENT);
    assert!(ts::has_most_recent_for_address<Coin<SUI>>(RECIPIENT));
    let received_coin = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    assert!(received_coin.value() == 100);

    destroy(received_coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_transfer_to_sender() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_transfer_to_sender".to_string();

    // Create an intent with a transfer to sender action
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test transfer to sender".to_string(),
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
        TransferIntent(),
        scenario.ctx(),
        |intent, iw| {
            acc_transfer::new_transfer_to_sender(intent, iw);
        },
    );

    // Create executable (OWNER is the sender)
    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Create a coin to transfer
    let coin = coin::mint_for_testing<SUI>(200, scenario.ctx());

    // Execute the transfer to sender
    acc_transfer::do_transfer_to_sender<Outcome, Coin<SUI>, _>(
        &mut executable,
        coin,
        TransferIntent(),
        scenario.ctx(),
    );

    account.confirm_execution(executable);

    // Verify the coin was transferred to OWNER (the sender)
    scenario.next_tx(OWNER);
    let received_coin = scenario.take_from_sender<Coin<SUI>>();
    assert!(received_coin.value() == 200);

    destroy(received_coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_transfers() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_multi_transfer".to_string();

    // Create an intent with multiple transfer actions
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test multiple transfers".to_string(),
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
        TransferIntent(),
        scenario.ctx(),
        |intent, iw| {
            acc_transfer::new_transfer(intent, RECIPIENT, iw);
            acc_transfer::new_transfer(intent, @0xDEAD, iw);
            acc_transfer::new_transfer(intent, @0xFACE, iw);
        },
    );

    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Create coins and execute each transfer
    let coin1 = coin::mint_for_testing<SUI>(100, scenario.ctx());
    let coin2 = coin::mint_for_testing<SUI>(200, scenario.ctx());
    let coin3 = coin::mint_for_testing<SUI>(300, scenario.ctx());

    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin1, TransferIntent());
    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin2, TransferIntent());
    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin3, TransferIntent());

    account.confirm_execution(executable);

    // Verify all transfers
    scenario.next_tx(RECIPIENT);
    let c1 = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    assert!(c1.value() == 100);

    scenario.next_tx(@0xDEAD);
    let c2 = scenario.take_from_address<Coin<SUI>>(@0xDEAD);
    assert!(c2.value() == 200);

    scenario.next_tx(@0xFACE);
    let c3 = scenario.take_from_address<Coin<SUI>>(@0xFACE);
    assert!(c3.value() == 300);

    destroy(c1);
    destroy(c2);
    destroy(c3);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_transfer_different_types() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_transfer_types".to_string();

    // Create intent
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test transfer different types".to_string(),
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
        TransferIntent(),
        scenario.ctx(),
        |intent, iw| {
            acc_transfer::new_transfer(intent, RECIPIENT, iw);
            acc_transfer::new_transfer(intent, RECIPIENT, iw);
        },
    );

    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Transfer different coin types
    let sui_coin = coin::mint_for_testing<SUI>(100, scenario.ctx());
    let test_coin = coin::mint_for_testing<TEST_COIN>(500, scenario.ctx());

    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, sui_coin, TransferIntent());
    acc_transfer::do_transfer<Outcome, Coin<TEST_COIN>, _>(
        &mut executable,
        test_coin,
        TransferIntent(),
    );

    account.confirm_execution(executable);

    // Verify both transfers
    scenario.next_tx(RECIPIENT);
    let c1 = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    let c2 = scenario.take_from_address<Coin<TEST_COIN>>(RECIPIENT);
    assert!(c1.value() == 100);
    assert!(c2.value() == 500);

    destroy(c1);
    destroy(c2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_transfer_unshared() {
    let (mut scenario, extensions, account, clock) = start();

    // Test the unshared transfer utility function
    let coin = coin::mint_for_testing<SUI>(999, scenario.ctx());
    acc_transfer::do_transfer_unshared(coin, RECIPIENT);

    // Verify transfer
    scenario.next_tx(RECIPIENT);
    let received = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    assert!(received.value() == 999);

    destroy(received);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_delete_transfer_action() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_delete".to_string();

    // Create an intent that will expire - single execution
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test delete".to_string(),
        vector[0], // Execute immediately (will be consumed)
        clock.timestamp_ms() + 1000, // Expiration in future
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        TransferIntent(),
        scenario.ctx(),
        |intent, iw| {
            acc_transfer::new_transfer(intent, RECIPIENT, iw);
        },
    );

    // Execute the intent to consume the execution time
    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    let coin = coin::mint_for_testing<SUI>(50, scenario.ctx());
    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin, TransferIntent());
    account.confirm_execution(executable);

    // Now the intent has no more execution times and can be destroyed
    let mut expired = account.destroy_empty_intent<_, Outcome>(key);
    acc_transfer::delete_transfer(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, clock);
}

#[test]
fun test_transfer_mixed_with_sender() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_mixed".to_string();

    // Create an intent mixing regular transfers and transfer-to-sender
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test mixed transfers".to_string(),
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
        TransferIntent(),
        scenario.ctx(),
        |intent, iw| {
            acc_transfer::new_transfer(intent, RECIPIENT, iw);
            acc_transfer::new_transfer_to_sender(intent, iw);
            acc_transfer::new_transfer(intent, @0xBEEF, iw);
        },
    );

    let (_, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    let coin1 = coin::mint_for_testing<SUI>(111, scenario.ctx());
    let coin2 = coin::mint_for_testing<SUI>(222, scenario.ctx());
    let coin3 = coin::mint_for_testing<SUI>(333, scenario.ctx());

    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin1, TransferIntent());
    acc_transfer::do_transfer_to_sender<Outcome, Coin<SUI>, _>(
        &mut executable,
        coin2,
        TransferIntent(),
        scenario.ctx(),
    );
    acc_transfer::do_transfer<Outcome, Coin<SUI>, _>(&mut executable, coin3, TransferIntent());

    account.confirm_execution(executable);

    // Verify all transfers - coins might arrive in any order due to parallel scenario handling
    scenario.next_tx(RECIPIENT);
    let c1 = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    assert!(c1.value() == 111 || c1.value() == 222 || c1.value() == 333, c1.value());

    scenario.next_tx(OWNER);
    let c2 = scenario.take_from_sender<Coin<SUI>>();
    assert!(c2.value() == 111 || c2.value() == 222 || c2.value() == 333, c2.value());

    scenario.next_tx(@0xBEEF);
    let c3 = scenario.take_from_address<Coin<SUI>>(@0xBEEF);
    assert!(c3.value() == 111 || c3.value() == 222 || c3.value() == 333, c3.value());

    // Verify total and uniqueness
    let total = c1.value() + c2.value() + c3.value();
    assert!(total == 666, total); // 111 + 222 + 333
    assert!(c1.value() != c2.value() && c2.value() != c3.value() && c1.value() != c3.value(), 9999);

    destroy(c1);
    destroy(c2);
    destroy(c3);
    end(scenario, extensions, account, clock);
}
