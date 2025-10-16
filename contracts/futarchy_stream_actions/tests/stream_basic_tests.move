#[test_only]
module futarchy_stream_actions::stream_basic_tests;

use account_actions::vault;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use futarchy_stream_actions::stream_actions;
use std::string;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT: address = @0xBEEF;
const ALICE: address = @0xA11CE;

// === Test Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

// === Helper Functions ===

fun start(): (Scenario, Extensions, Account<Config>, Clock) {
    let mut scenario = ts::begin(OWNER);

    // Initialize extensions
    extensions::init_for_testing(scenario.ctx());

    // Get extensions and cap
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();

    // Add dependencies
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @account_actions, 1);
    extensions.add(&cap, b"FutarchyCore".to_string(), @futarchy_core, 1);
    extensions.add(&cap, b"FutarchyStreams".to_string(), @futarchy_stream_actions, 1);

    // Create account with dependencies
    let deps = deps::new_latest_extensions(
        &extensions,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountActions".to_string(),
            b"FutarchyCore".to_string(),
            b"FutarchyStreams".to_string(),
        ],
    );

    let mut account = account::new(Config {}, deps, version::current(), Witness(), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    // Setup treasury vault with funds
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, b"treasury".to_string(), scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let initial_funds = coin::mint_for_testing<SUI>(10_000_000, scenario.ctx());
    vault::deposit(auth, &mut account, b"treasury".to_string(), initial_funds);

    destroy(cap);
    (scenario, extensions, account, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<Config>, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

// === Basic Tests ===

#[test]
fun test_create_vault_stream_directly() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let auth = account.new_auth(version::current(), Witness());

    // Create stream directly in vault
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000, // total_amount
        clock.timestamp_ms(), // start_time
        clock.timestamp_ms() + 1_000_000, // end_time (1000 seconds)
        std::option::none(), // no cliff
        0, // max_per_withdrawal (unlimited)
        0, // min_interval_ms (no minimum)
        1, // max_beneficiaries
        &clock,
        scenario.ctx(),
    );

    // Verify stream was created
    let (_, total_amount, claimed_amount, start_time, end_time, _, _) = vault::stream_info(
        &account,
        string::utf8(b"treasury"),
        stream_id,
    );

    assert!(total_amount == 100_000, 0);
    assert!(claimed_amount == 0, 1);
    assert!(start_time == clock.timestamp_ms(), 2);
    assert!(end_time == clock.timestamp_ms() + 1_000_000, 3);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_claim_from_vault_stream() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create stream
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000,
        clock.timestamp_ms(),
        clock.timestamp_ms() + 1_000_000,
        std::option::none(),
        0,
        0,
        1,
        &clock,
        scenario.ctx(),
    );

    // Advance time by 500 seconds (50% vested)
    clock.increment_for_testing(500_000);

    // Calculate claimable
    let claimable = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );

    // Should be approximately 50,000 (50% vested)
    assert!(claimable >= 49_000 && claimable <= 51_000, 0);

    // Switch to recipient to withdraw
    scenario.next_tx(RECIPIENT);

    // Withdraw from stream
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        stream_id,
        claimable,
        &clock,
        scenario.ctx(),
    );

    assert!(coin.value() == claimable, 1);

    // Verify claimed amount updated
    let (_, _, claimed_amount, _, _, _, _) = vault::stream_info(
        &account,
        string::utf8(b"treasury"),
        stream_id,
    );

    assert!(claimed_amount == claimable, 2);

    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_cancel_vault_stream() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create stream
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000,
        clock.timestamp_ms(),
        clock.timestamp_ms() + 1_000_000,
        std::option::none(),
        0,
        0,
        1,
        &clock,
        scenario.ctx(),
    );

    // Advance time slightly
    clock.increment_for_testing(100_000);

    // Cancel the stream
    let auth = account.new_auth(version::current(), Witness());
    let (refund_coin, refund_amount) = vault::cancel_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
        scenario.ctx(),
    );

    // Should get refund for unclaimed portion
    assert!(refund_amount >= 80_000, 0);
    assert!(refund_coin.value() == refund_amount, 1);

    destroy(refund_coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_stream_with_cliff() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let current_time = clock.timestamp_ms();
    let cliff_time = current_time + 500_000; // 500 seconds cliff

    // Create stream with cliff
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000,
        current_time,
        current_time + 1_000_000,
        std::option::some(cliff_time),
        0,
        0,
        1,
        &clock,
        scenario.ctx(),
    );

    // Try to claim before cliff - should get 0
    clock.increment_for_testing(250_000); // 250 seconds (before cliff)
    let claimable_before = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );

    assert!(claimable_before == 0, 0);

    // Advance past cliff
    clock.increment_for_testing(300_000); // Now at 550 seconds (past cliff)
    let claimable_after = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );

    // Should have vested amount now
    assert!(claimable_after > 0, 1);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_withdrawals() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create stream
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000,
        clock.timestamp_ms(),
        clock.timestamp_ms() + 1_000_000,
        std::option::none(),
        0,
        0,
        1,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(RECIPIENT);

    // First withdrawal at 25%
    clock.increment_for_testing(250_000);
    let claimable1 = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        stream_id,
        claimable1,
        &clock,
        scenario.ctx(),
    );

    // Second withdrawal at 50%
    clock.increment_for_testing(250_000);
    let claimable2 = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        stream_id,
        claimable2,
        &clock,
        scenario.ctx(),
    );

    // Third withdrawal at 75%
    clock.increment_for_testing(250_000);
    let claimable3 = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );
    let coin3 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        stream_id,
        claimable3,
        &clock,
        scenario.ctx(),
    );

    // Verify progressive claiming
    assert!(claimable1 > 0, 0);
    assert!(claimable2 > 0, 1);
    assert!(claimable3 > 0, 2);
    assert!(coin1.value() + coin2.value() + coin3.value() <= 100_000, 3);

    destroy(coin1);
    destroy(coin2);
    destroy(coin3);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_full_vesting() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create stream
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000,
        clock.timestamp_ms(),
        clock.timestamp_ms() + 1_000_000,
        std::option::none(),
        0,
        0,
        1,
        &clock,
        scenario.ctx(),
    );

    // Advance to 100% vested
    clock.increment_for_testing(1_000_000);

    scenario.next_tx(RECIPIENT);

    // Claim all
    let claimable = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );
    assert!(claimable == 100_000, 0);

    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        stream_id,
        claimable,
        &clock,
        scenario.ctx(),
    );

    assert!(coin.value() == 100_000, 1);

    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_stream_end_time() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let start_time = clock.timestamp_ms();
    let end_time = start_time + 1_000_000;

    // Create stream
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        string::utf8(b"treasury"),
        RECIPIENT,
        100_000,
        start_time,
        end_time,
        std::option::none(),
        0,
        0,
        1,
        &clock,
        scenario.ctx(),
    );

    // Advance past end time
    clock.increment_for_testing(2_000_000);

    // Claimable should be capped at 100% (100,000)
    let claimable = vault::calculate_claimable(
        &account,
        string::utf8(b"treasury"),
        stream_id,
        &clock,
    );
    assert!(claimable == 100_000, 0);

    end(scenario, extensions, account, clock);
}
