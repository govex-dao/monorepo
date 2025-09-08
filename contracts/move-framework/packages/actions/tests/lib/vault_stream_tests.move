#[test_only]
module account_actions::vault_stream_tests;

// === Imports ===

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    object,
};
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::{Self, Account},
    deps,
};
use account_actions::{
    version,
    vault,
};
use std::option;

// === Constants ===

const OWNER: address = @0xCAFE;
const BENEFICIARY: address = @0xBEEF;
const UNAUTHORIZED: address = @0xDEAD;

// === Structs ===

public struct VAULT_STREAM_TESTS has drop {}

public struct DummyIntent() has copy, drop;
public struct WrongWitness() has copy, drop;

public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

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

    let deps = deps::new_latest_extensions(&extensions, vector[b"AccountProtocol".to_string(), b"AccountActions".to_string()]);
    let account = account::new(Config {}, deps, version::current(), DummyIntent(), scenario.ctx());
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

fun setup_vault_with_funds(
    account: &mut Account<Config>,
    vault_name: vector<u8>,
    amount: u64,
    ctx: &mut TxContext
) {
    let auth = account.new_auth(version::current(), DummyIntent());
    vault::open(auth, account, vault_name.to_string(), ctx);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    vault::deposit<Config, SUI>(
        auth, 
        account, 
        vault_name.to_string(), 
        coin::mint_for_testing<SUI>(amount, ctx)
    );
}

// === Stream Creation Tests ===

#[test]
fun test_create_stream_happy_path() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    // Set initial time
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,  // total_amount
        1000, // start_time
        2000, // end_time
        option::none(), // no cliff
        100,  // max_per_withdrawal
        100,  // min_interval_ms
        &clock,
        scenario.ctx()
    );
    
    // Verify stream was created
    let (beneficiary, total, claimed, start, end_time, max_withdraw, cliff) = 
        vault::stream_info(&account, b"treasury".to_string(), stream_id);
    
    assert!(beneficiary == BENEFICIARY);
    assert!(total == 500);
    assert!(claimed == 0);
    assert!(start == 1000);
    assert!(end_time == 2000);
    assert!(max_withdraw == 100);
    assert!(cliff.is_none());
    
    end(scenario, extensions, account, clock);
}

#[test]
fun test_create_stream_with_cliff() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        600,
        1000,
        3000,
        option::some(1500), // cliff at 1500
        50,
        200,
        &clock,
        scenario.ctx()
    );
    
    let (_, _, _, _, _, _, cliff) = 
        vault::stream_info(&account, b"treasury".to_string(), stream_id);
    assert!(cliff.is_some());
    assert!(*cliff.borrow() == 1500);
    
    end(scenario, extensions, account, clock);
}

// === Stream Withdrawal Tests ===

#[test]
fun test_withdraw_from_stream_happy_path() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        200,
        100,
        &clock,
        scenario.ctx()
    );
    
    // Move time to 25% vesting
    clock.set_for_testing(1250);
    
    // Withdraw as beneficiary
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        200, // withdraw 200 (max allowed)
        &clock,
        scenario.ctx()
    );
    
    assert!(coin.value() == 200);
    
    // Check updated stream state
    let (_, _, claimed, _, _, _, _) = 
        vault::stream_info(&account, b"treasury".to_string(), stream_id);
    assert!(claimed == 200);
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_withdraw_respects_vesting_schedule() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        500,
        0, // no interval limit for this test
        &clock,
        scenario.ctx()
    );
    
    // At 50% vesting
    clock.set_for_testing(1500);
    
    scenario.next_tx(BENEFICIARY);
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        400,
        &clock,
        scenario.ctx()
    );
    assert!(coin1.value() == 400);
    
    // Try to withdraw more - should only get 100 more (500 total vested)
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100, // Exactly what's available
        &clock,
        scenario.ctx()
    );
    assert!(coin2.value() == 100); // Got exactly 100
    
    destroy(coin1);
    destroy(coin2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_withdraw_after_full_vesting() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        2000,
        option::none(),
        500,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Move past end time
    clock.set_for_testing(3000);
    
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        500,
        &clock,
        scenario.ctx()
    );
    
    assert!(coin.value() == 500); // Full amount available
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

// === Stream Cancellation Tests ===

#[test]
fun test_cancel_stream_before_start() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(500);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        600,
        1000,
        2000,
        option::none(),
        100,
        100,
        &clock,
        scenario.ctx()
    );
    
    // Cancel before start - should get full refund
    let auth = account.new_auth(version::current(), DummyIntent());
    let (refund, unvested_amount) = vault::cancel_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        stream_id,
        &clock,
        scenario.ctx()
    );
    
    assert!(refund.value() == 600);
    assert!(unvested_amount == 600);
    
    destroy(refund);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_cancel_stream_partial_vesting() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        200,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Withdraw some first
    clock.set_for_testing(1200);
    scenario.next_tx(BENEFICIARY);
    let withdrawn = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    destroy(withdrawn);
    
    // Cancel at 40% vesting (400 vested, 100 already claimed)
    clock.set_for_testing(1400);
    scenario.next_tx(OWNER);
    let auth = account.new_auth(version::current(), DummyIntent());
    let (refund, unvested_amount) = vault::cancel_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        stream_id,
        &clock,
        scenario.ctx()
    );
    
    // Should refund 600 unvested
    assert!(refund.value() == 600);
    assert!(unvested_amount == 600);
    
    // Beneficiary should have received the remaining 300 vested
    scenario.next_tx(BENEFICIARY);
    let final_payment = scenario.take_from_address<Coin<SUI>>(BENEFICIARY);
    assert!(final_payment.value() == 300);
    
    destroy(refund);
    destroy(final_payment);
    end(scenario, extensions, account, clock);
}

// === Permissionless Deposit Tests ===

#[test]
fun test_deposit_permissionless_existing_coin() {
    let (mut scenario, extensions, mut account, clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 100, scenario.ctx());
    
    // Anyone can deposit to existing coin type
    scenario.next_tx(UNAUTHORIZED);
    vault::deposit_permissionless<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        coin::mint_for_testing<SUI>(50, scenario.ctx())
    );
    
    let vault_ref = vault::borrow_vault(&account, b"treasury".to_string());
    assert!(vault::coin_type_value<SUI>(vault_ref) == 150);
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EWrongCoinType)]
fun test_deposit_permissionless_new_coin_fails() {
    let (mut scenario, extensions, mut account, clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 100, scenario.ctx());
    
    // Try to deposit new coin type without permission
    scenario.next_tx(UNAUTHORIZED);
    vault::deposit_permissionless<Config, VAULT_STREAM_TESTS>(
        &mut account,
        b"treasury".to_string(),
        coin::mint_for_testing<VAULT_STREAM_TESTS>(50, scenario.ctx())
    );
    
    end(scenario, extensions, account, clock);
}

// === Error Cases ===

#[test, expected_failure(abort_code = vault::EStreamNotFound)]
fun test_withdraw_nonexistent_stream() {
    let (mut scenario, extensions, mut account, clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    scenario.next_tx(BENEFICIARY);
    let fake_id = object::id_from_address(@0x999);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        fake_id,
        100,
        &clock,
        scenario.ctx()
    );
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EUnauthorizedBeneficiary)]
fun test_withdraw_wrong_beneficiary() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    clock.set_for_testing(1500);
    
    // Wrong person tries to withdraw
    scenario.next_tx(UNAUTHORIZED);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EStreamNotStarted)]
fun test_withdraw_before_start() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(500);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Try to withdraw before start
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EStreamCliffNotReached)]
fun test_withdraw_before_cliff() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        2000,
        option::some(1500), // cliff
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Try to withdraw before cliff
    clock.set_for_testing(1400);
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EWithdrawalLimitExceeded)]
fun test_withdraw_exceeds_max_per_withdrawal() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        50, // max 50 per withdrawal
        0,
        &clock,
        scenario.ctx()
    );
    
    clock.set_for_testing(1500);
    scenario.next_tx(BENEFICIARY);
    
    // Try to withdraw more than max
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100, // exceeds max of 50
        &clock,
        scenario.ctx()
    );
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EWithdrawalTooSoon)]
fun test_withdraw_too_soon_after_last() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        100,
        500, // 500ms minimum interval
        &clock,
        scenario.ctx()
    );
    
    clock.set_for_testing(1500);
    scenario.next_tx(BENEFICIARY);
    
    // First withdrawal
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    destroy(coin1);
    
    // Try again too soon
    clock.set_for_testing(1700); // only 200ms later
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        50,
        &clock,
        scenario.ctx()
    );
    
    destroy(coin2);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInsufficientVestedAmount)]
fun test_withdraw_exceeds_vested() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        1000,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Only 10% vested
    clock.set_for_testing(1100);
    scenario.next_tx(BENEFICIARY);
    
    // Try to withdraw more than vested
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        200, // only 100 vested
        &clock,
        scenario.ctx()
    );
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInvalidStreamParameters)]
fun test_create_stream_invalid_zero_amount() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        0, // invalid zero amount
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInvalidStreamParameters)]
fun test_create_stream_invalid_end_before_start() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        2000,
        1000, // end before start
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInvalidStreamParameters)]
fun test_create_stream_invalid_start_in_past() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(2000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000, // start in past
        3000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInvalidStreamParameters)]
fun test_create_stream_invalid_cliff_before_start() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        2000,
        3000,
        option::some(1500), // cliff before start
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInvalidStreamParameters)]
fun test_create_stream_invalid_cliff_after_end() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        2000,
        option::some(2500), // cliff after end
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EWrongCoinType)]
fun test_create_stream_wrong_coin_type() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, VAULT_STREAM_TESTS>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = vault::EInsufficientVestedAmount)]
fun test_create_stream_insufficient_balance() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 100, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500, // more than vault has
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

// === Calculate Claimable Tests ===

#[test]
fun test_calculate_claimable_various_states() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        2000,
        4000,
        option::some(2500), // cliff at 2500
        200,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Before start - should be 0
    clock.set_for_testing(1500);
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 0);
    
    // After start but before cliff - should be 0
    clock.set_for_testing(2200);
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 0);
    
    // After cliff, 50% vested (3000/4000)
    clock.set_for_testing(3000);
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 500);
    
    // Withdraw some
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        200,
        &clock,
        scenario.ctx()
    );
    destroy(coin);
    
    // Check claimable reduced
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 300);
    
    // After full vesting
    clock.set_for_testing(5000);
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 800); // 1000 - 200 already claimed
    
    end(scenario, extensions, account, clock);
}

// === Additional Edge Case Tests ===

// === Overflow/Underflow Protection Tests ===

#[test, expected_failure(abort_code = vault::EInsufficientVestedAmount)]
fun test_stream_exceeds_vault_balance() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 100, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    // Try to create stream for more than vault contains
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000, // More than vault has (100)
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

#[test]
fun test_large_amount_vesting_calculations() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let large_amount = 1_000_000_000_000; // 1 trillion
    setup_vault_with_funds(&mut account, b"treasury", large_amount, scenario.ctx());
    
    clock.set_for_testing(0);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        large_amount,
        0,
        1_000_000, // 1 million ms duration
        option::none(),
        large_amount / 10, // 10% max per withdrawal
        0,
        &clock,
        scenario.ctx()
    );
    
    // Test at 50% vesting
    clock.set_for_testing(500_000);
    
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        large_amount / 10, // Max withdrawal
        &clock,
        scenario.ctx()
    );
    
    assert!(coin.value() == large_amount / 10);
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

// === Multiple Concurrent Streams Tests ===

#[test]
fun test_multiple_streams_same_beneficiary() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 10000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    // Create 3 streams for same beneficiary with different schedules
    let auth1 = account.new_auth(version::current(), DummyIntent());
    let stream_id1 = vault::create_stream<Config, SUI>(
        auth1,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    let auth2 = account.new_auth(version::current(), DummyIntent());
    let stream_id2 = vault::create_stream<Config, SUI>(
        auth2,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        2000,
        1500,
        2500,
        option::none(),
        200,
        0,
        &clock,
        scenario.ctx()
    );
    
    let auth3 = account.new_auth(version::current(), DummyIntent());
    let stream_id3 = vault::create_stream<Config, SUI>(
        auth3,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        3000,
        2000,
        3000,
        option::some(2200), // With cliff
        300,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Move to time when all are active (stream 3 past cliff)
    clock.set_for_testing(2300);
    
    // Withdraw from each stream
    scenario.next_tx(BENEFICIARY);
    
    // Stream 1: fully vested (ended at 2000)
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id1,
        100, // respecting max
        &clock,
        scenario.ctx()
    );
    
    // Stream 2: 80% vested ((2300-1500)/(2500-1500) = 0.8)
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id2,
        200, // respecting max
        &clock,
        scenario.ctx()
    );
    
    // Stream 3: 30% vested ((2300-2000)/(3000-2000) = 0.3)
    let coin3 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id3,
        300, // respecting max, but only 900 vested
        &clock,
        scenario.ctx()
    );
    
    assert!(coin1.value() == 100);
    assert!(coin2.value() == 200);
    assert!(coin3.value() == 300);
    
    destroy(coin1);
    destroy(coin2);
    destroy(coin3);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_streams_different_beneficiaries() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 5000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let beneficiary2 = @0xBEEF2;
    
    // Create streams for different beneficiaries
    let auth1 = account.new_auth(version::current(), DummyIntent());
    let stream_id1 = vault::create_stream<Config, SUI>(
        auth1,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::none(),
        500,
        0,
        &clock,
        scenario.ctx()
    );
    
    let auth2 = account.new_auth(version::current(), DummyIntent());
    let stream_id2 = vault::create_stream<Config, SUI>(
        auth2,
        &mut account,
        b"treasury".to_string(),
        beneficiary2,
        1500,
        1000,
        2000,
        option::none(),
        750,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Move to 50% vesting
    clock.set_for_testing(1500);
    
    // Each beneficiary withdraws from their stream
    scenario.next_tx(BENEFICIARY);
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id1,
        500,
        &clock,
        scenario.ctx()
    );
    assert!(coin1.value() == 500);
    
    scenario.next_tx(beneficiary2);
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id2,
        750,
        &clock,
        scenario.ctx()
    );
    assert!(coin2.value() == 750);
    
    destroy(coin1);
    destroy(coin2);
    end(scenario, extensions, account, clock);
}

// === Precision and Rounding Tests ===

#[test]
fun test_odd_amount_vesting_precision() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 10000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    // Create stream with amount that doesn't divide evenly
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        999, // Odd amount
        1000,
        4000, // 3000ms duration
        option::none(),
        1000,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Test at 33.33% vesting (2000ms into 3000ms duration)
    clock.set_for_testing(2000);
    
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        333, // Floor of 999 * 0.3333
        &clock,
        scenario.ctx()
    );
    
    assert!(coin.value() == 333);
    
    // Test at 66.66% vesting
    clock.set_for_testing(3000);
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        333, // Another 333 (total 666)
        &clock,
        scenario.ctx()
    );
    assert!(coin2.value() == 333);
    
    // Test at 100% - should get remaining
    clock.set_for_testing(4000);
    let coin3 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        333, // Remaining 333 (999 - 666)
        &clock,
        scenario.ctx()
    );
    assert!(coin3.value() == 333);
    
    destroy(coin);
    destroy(coin2);
    destroy(coin3);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_small_duration_large_amount() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1_000_000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    // Large amount over very short duration
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1_000_000,
        1000,
        1010, // Only 10ms duration
        option::none(),
        1_000_000,
        0,
        &clock,
        scenario.ctx()
    );
    
    // At 50% (5ms)
    clock.set_for_testing(1005);
    
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        500_000,
        &clock,
        scenario.ctx()
    );
    
    assert!(coin.value() == 500_000);
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}

// === Concurrent Operations Tests ===

#[test]
fun test_cancel_stream_after_partial_withdrawal() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        3000,
        option::none(),
        200,
        100, // 100ms min interval
        &clock,
        scenario.ctx()
    );
    
    // Beneficiary withdraws at 25% vesting
    clock.set_for_testing(1500);
    scenario.next_tx(BENEFICIARY);
    
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        200, // Withdraw 200 of 250 vested
        &clock,
        scenario.ctx()
    );
    assert!(coin1.value() == 200);
    destroy(coin1);
    
    // Owner cancels stream immediately after
    scenario.next_tx(OWNER);
    clock.set_for_testing(1501);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let (refund_coin, refund_amount) = vault::cancel_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        stream_id,
        &clock,
        scenario.ctx()
    );
    
    // Should refund unvested portion: 1000 - 250 vested = 750
    // But 200 was already withdrawn, so refund is 1000 - 200 = 800
    // Actually, at time 1501, vested is ~250.5, claimed is 200
    // So refund should be total - vested_at_cancel = 1000 - 250 = 750
    // The function returns the unvested amount
    assert!(refund_amount >= 749 && refund_amount <= 751); // Allow for rounding
    
    destroy(refund_coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_withdrawals_rate_limiting() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 2000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        2000,
        1000,
        3000,
        option::none(),
        100, // Max 100 per withdrawal
        500, // 500ms minimum interval
        &clock,
        scenario.ctx()
    );
    
    // Move to 50% vested
    clock.set_for_testing(2000);
    scenario.next_tx(BENEFICIARY);
    
    // First withdrawal
    let coin1 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    assert!(coin1.value() == 100);
    destroy(coin1);
    
    // Wait exactly the minimum interval
    clock.set_for_testing(2500);
    
    // Second withdrawal should succeed
    let coin2 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    assert!(coin2.value() == 100);
    destroy(coin2);
    
    // Move to 75% vested
    clock.set_for_testing(2500);
    
    // Third withdrawal right after should respect the interval
    clock.set_for_testing(3000);
    let coin3 = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        100,
        &clock,
        scenario.ctx()
    );
    assert!(coin3.value() == 100);
    destroy(coin3);
    
    end(scenario, extensions, account, clock);
}

// === Zero Duration Edge Case ===

#[test, expected_failure(abort_code = vault::EInvalidStreamParameters)]
fun test_stream_with_zero_duration() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    // Start and end at same time (zero duration)
    let _stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        500,
        1000,
        1000, // Same as start time
        option::none(),
        100,
        0,
        &clock,
        scenario.ctx()
    );
    
    end(scenario, extensions, account, clock);
}

// === Cliff Edge Cases ===

#[test]
fun test_cliff_at_exact_end_time() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    setup_vault_with_funds(&mut account, b"treasury", 1000, scenario.ctx());
    
    clock.set_for_testing(1000);
    
    let auth = account.new_auth(version::current(), DummyIntent());
    // Cliff at exactly the end time - should vest everything at once
    let stream_id = vault::create_stream<Config, SUI>(
        auth,
        &mut account,
        b"treasury".to_string(),
        BENEFICIARY,
        1000,
        1000,
        2000,
        option::some(2000), // Cliff at end
        1000,
        0,
        &clock,
        scenario.ctx()
    );
    
    // Before cliff - nothing vested
    clock.set_for_testing(1999);
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 0);
    
    // At cliff/end - everything vested
    clock.set_for_testing(2000);
    let claimable = vault::calculate_claimable(&account, b"treasury".to_string(), stream_id, &clock);
    assert!(claimable == 1000);
    
    scenario.next_tx(BENEFICIARY);
    let coin = vault::withdraw_from_stream<Config, SUI>(
        &mut account,
        b"treasury".to_string(),
        stream_id,
        1000,
        &clock,
        scenario.ctx()
    );
    assert!(coin.value() == 1000);
    
    destroy(coin);
    end(scenario, extensions, account, clock);
}