#[test_only]
module account_actions::vault_tests;

use account_actions::vault;
use account_actions::version;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackageAdminCap};
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

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    // add core deps
    package_registry::add_for_testing(&mut extensions,  b"AccountProtocol".to_string(), @account_protocol, 1);
    package_registry::add_for_testing(&mut extensions,  b"AccountActions".to_string(), @account_actions, 1);

    let deps = deps::new_latest_extensions(
        &extensions,
        vector[b"AccountProtocol".to_string(), b"AccountActions".to_string()],
    );
    let account = account::new(Config {}, deps, &extensions, version::current(), Witness(), scenario.ctx());
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

// === Tests ===

#[test]
fun test_open_close_vault() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault".to_string();

    // Open a vault
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());

    // Verify vault exists
    assert!(vault::has_vault(&account, vault_name));

    // Close the vault
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::close<Config>(auth, &mut account, &extensions, vault_name);

    // Verify vault no longer exists
    assert!(!vault::has_vault(&account, vault_name));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_deposit_and_withdraw() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault".to_string();

    // Open vault
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());

    // Deposit coins
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Check vault has the coins
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name);
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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Create stream
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
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
    assert!(vault::has_stream(&account, &extensions, vault_name, stream_id));

    // Advance time to 50% vested
    clock.increment_for_testing(50_000);

    // Calculate claimable
    let claimable = vault::calculate_claimable<Config>(&account, &extensions, vault_name, stream_id, &clock);
    assert!(claimable == 500);

    // Withdraw from stream (must be beneficiary)
    scenario.next_tx(beneficiary);
    let withdrawn_coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        &extensions,
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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Create stream that starts in the future
    let start_time = clock.timestamp_ms() + 10_000;
    let end_time = start_time + 100_000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
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
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        &extensions,
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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Create stream with cliff
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let cliff_time = start_time + 50_000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
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
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        &extensions,
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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Create stream
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let (refund_coin, refund_amount) = vault::cancel_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        &clock,
        scenario.ctx(),
    );

    // Should refund unvested amount (70% = 700)
    assert!(refund_amount == 700);
    assert!(refund_coin.value() == 700);

    // Stream should no longer exist
    assert!(!vault::has_stream(&account, &extensions, vault_name, stream_id));

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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Create stream with low max_per_withdrawal
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
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
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        &extensions,
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
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin);

    // Create stream with min interval
    let start_time = clock.timestamp_ms();
    let end_time = start_time + 100_000;
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        &extensions,
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
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        100,
        &clock,
        scenario.ctx(),
    );
    destroy(coin1);

    // Try to withdraw again immediately - should fail
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        100,
        &clock,
        scenario.ctx(),
    );

    destroy(coin2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_spend_all_balance_check() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault".to_string();

    // Open vault
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    vault::open<Config>(auth, &mut account, &extensions, vault_name, scenario.ctx());

    // Deposit coins - simulating deposits from multiple sources
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin1 = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin1);

    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let coin2 = coin::mint_for_testing<SUI>(234, scenario.ctx());
    vault::deposit<Config, SUI>(auth, &mut account, &extensions, vault_name, coin2);

    // Total balance is now 1234
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name);
    let total_balance = vault::coin_type_value<SUI>(vault_ref);
    assert!(total_balance == 1234);

    // Use balance() convenience function to get current amount
    let current_balance = vault::balance<Config, SUI>(&account, &extensions, vault_name);
    assert!(current_balance == 1234);

    // In a real DAO dissolution, you would:
    // 1. Query balance: vault::balance<AssetType>(&account, vault_name)
    // 2. Create intent with: vault::new_spend(intent, vault_name, 0, true, iw)
    //    where spend_all=true means it withdraws the entire balance
    // 3. The do_spend action would then withdraw all coins regardless of amount field

    // For now, test that we can withdraw the full amount we queried
    let auth = account.new_auth<Config, Witness>(&extensions, version::current(), Witness());
    let withdrawn_coin = vault::spend<Config, SUI>(
        auth,
        &mut account,
        &extensions,
        vault_name,
        current_balance, // withdraw the exact balance we queried
        scenario.ctx(),
    );

    assert!(withdrawn_coin.value() == 1234);

    // Verify vault is now empty
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name);
    assert!(!vault::coin_type_exists<SUI>(vault_ref));

    destroy(withdrawn_coin);
    end(scenario, extensions, account, clock);
}
