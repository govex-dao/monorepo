#[test_only]
module account_actions::vault_tests;

use account_actions::vault;
use account_actions::version;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackagePackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
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
public struct Config has copy, drop, store {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account<Config>, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
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

fun end(scenario: Scenario, extensions: PackageRegistry, account: Account<Config>, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_open_close_vault() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault".to_string();

    // Open a vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());

    // Verify vault exists
    assert!(vault::has_vault(&account, vault_name));

    // Close the vault
    let auth = account.new_auth(version::current(), Witness());
    vault::close(auth, &mut account, vault_name);

    // Verify vault no longer exists
    assert!(!vault::has_vault(&account, vault_name));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_deposit_and_withdraw() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault".to_string();

    // Open vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());

    // Deposit coins
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Check vault has the coins
    let vault_ref = vault::borrow_vault(&account, vault_name);
    assert!(vault::coin_type_exists<SUI>(vault_ref));
    assert!(vault::coin_type_value<SUI>(vault_ref) == 1000);

    end(scenario, extensions, account, clock);
}


#[test]
fun test_create_and_withdraw_from_stream() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault".to_string();
    let beneficiary = @0xBEEF;

    // Setup vault with funds
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Create stream
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        beneficiary,
        1000,
        start_time,
        end_time,
        option::none(),
        500, // max_per_withdrawal
        1000, // min_interval_ms
        10, // max_beneficiaries
        &clock,
        scenario.ctx(),
    );

    // Verify stream exists
    assert!(vault::has_stream(&account, vault_name, stream_id));

    // Advance time to 50% vested
    clock.increment_for_testing(50_000);

    // Calculate claimable
    let claimable = vault::calculate_claimable(&account, vault_name, stream_id, &clock);
    assert!(claimable == 500);

    // Withdraw from stream (must be beneficiary)
    scenario.next_tx(beneficiary);
    let withdrawn_coin = vault::withdraw_from_stream<_, SUI>(
        &mut account,
        vault_name,
        stream_id,
        500,
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn_coin.value() == 500);

    destroy(withdrawn_coin);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EStreamNotStarted)]
fun test_withdraw_before_start() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault".to_string();
    let beneficiary = @0xBEEF;

    // Setup vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Create stream that starts in the future
    let start_time = clock.timestamp_ms() + 10_000;
    let end_time = start_time + 100_000;
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        beneficiary,
        1000,
        start_time,
        end_time,
        option::none(),
        500,
        1000,
        10,
        &clock,
        scenario.ctx(),
    );

    // Try to withdraw before start - should fail
    scenario.next_tx(beneficiary);
    let coin = vault::withdraw_from_stream<_, SUI>(
        &mut account,
        vault_name,
        stream_id,
        100,
        &clock,
        scenario.ctx(),
    );

    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EStreamCliffNotReached)]
fun test_withdraw_before_cliff() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault".to_string();
    let beneficiary = @0xBEEF;

    // Setup vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Create stream with cliff
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let cliff_time = start_time + 50_000;
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        beneficiary,
        1000,
        start_time,
        end_time,
        option::some(cliff_time),
        500,
        1000,
        10,
        &clock,
        scenario.ctx(),
    );

    // Advance time but not past cliff
    clock.increment_for_testing(25_000);

    // Try to withdraw before cliff - should fail
    scenario.next_tx(beneficiary);
    let coin = vault::withdraw_from_stream<_, SUI>(
        &mut account,
        vault_name,
        stream_id,
        100,
        &clock,
        scenario.ctx(),
    );

    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_cancel_stream() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault".to_string();
    let beneficiary = @0xBEEF;

    // Setup vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Create stream
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        beneficiary,
        1000,
        start_time,
        end_time,
        option::none(),
        500,
        1000,
        10,
        &clock,
        scenario.ctx(),
    );

    // Advance time to 30% vested
    clock.increment_for_testing(30_000);

    // Cancel stream
    let auth = account.new_auth(version::current(), Witness());
    let (refund_coin, refund_amount) = vault::cancel_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        stream_id,
        &clock,
        scenario.ctx(),
    );

    // Should refund unvested amount (70% = 700)
    assert!(refund_amount == 700);
    assert!(refund_coin.value() == 700);

    // Stream should no longer exist
    assert!(!vault::has_stream(&account, vault_name, stream_id));

    destroy(refund_coin);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EWithdrawalLimitExceeded)]
fun test_withdrawal_limit() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault".to_string();
    let beneficiary = @0xBEEF;

    // Setup vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Create stream with low max_per_withdrawal
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        beneficiary,
        1000,
        start_time,
        end_time,
        option::none(),
        100, // max_per_withdrawal = 100
        1000,
        10,
        &clock,
        scenario.ctx(),
    );

    // Advance time to fully vested
    clock.increment_for_testing(100_000);

    // Try to withdraw more than limit - should fail
    scenario.next_tx(beneficiary);
    let coin = vault::withdraw_from_stream<_, SUI>(
        &mut account,
        vault_name,
        stream_id,
        200, // More than limit
        &clock,
        scenario.ctx(),
    );

    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EWithdrawalTooSoon)]
fun test_min_interval() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault".to_string();
    let beneficiary = @0xBEEF;

    // Setup vault
    let auth = account.new_auth(version::current(), Witness());
    vault::open(auth, &mut account, vault_name, scenario.ctx());
    let auth = account.new_auth(version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit(auth, &mut account, vault_name, coin);

    // Create stream with min interval
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth(version::current(), Witness());
    let stream_id = vault::create_stream<_, SUI>(
        auth,
        &mut account,
        vault_name,
        beneficiary,
        1000,
        start_time,
        end_time,
        option::none(),
        100,
        10_000, // min_interval_ms = 10 seconds
        10,
        &clock,
        scenario.ctx(),
    );

    // Advance time to vested
    clock.increment_for_testing(50_000);

    // First withdrawal
    scenario.next_tx(beneficiary);
    let coin1 = vault::withdraw_from_stream<_, SUI>(
        &mut account,
        vault_name,
        stream_id,
        100,
        &clock,
        scenario.ctx(),
    );
    destroy(coin1);

    // Try to withdraw again immediately - should fail
    let coin2 = vault::withdraw_from_stream<_, SUI>(
        &mut account,
        vault_name,
        stream_id,
        100,
        &clock,
        scenario.ctx(),
    );

    destroy(coin2);
    end(scenario, extensions, account, clock);
}
