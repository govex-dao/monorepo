/// Comprehensive tests for fee_collection.move
/// Tests atomic updates of FeeManager (shared) and FeeState (owned)
#[test_only]
module futarchy_multisig::fee_collection_tests;

use account_extensions::extensions;
use account_protocol::account::Account;
use futarchy_markets::fee::{Self, FeeManager};
use futarchy_multisig::fee_collection;
use futarchy_multisig::fee_state;
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig};
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ADMIN: address = @0xAD;
const ALICE: address = @0xA1;

// === Constants ===
const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
const GRACE_PERIOD_MS: u64 = 432_000_000; // 5 days

// === Helper Functions ===

fun create_test_multisig(scenario: &mut ts::Scenario): Account<WeightedMultisig> {
    let members = vector[ALICE];
    let weights = vector[100u128];

    weighted_multisig::new(
        members,
        weights,
        extensions::empty(ts::ctx(scenario)),
        ts::ctx(scenario),
    )
}

fun create_test_fee_manager(scenario: &mut ts::Scenario, clock: &Clock): FeeManager {
    fee::new_for_testing(clock, ts::ctx(scenario))
}

// === Basic Integration Tests ===

#[test]
fun test_pay_fee_updates_both_states() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    // Create multisig and init fee state
    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    // Create fee manager
    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    // Set up fee configuration in fee manager
    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0, // proposal fee
        0, // reserved
        &clock,
        ts::ctx(&mut scenario),
    );

    // Register multisig in fee manager
    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(
        &mut fee_manager,
        multisig_id,
        sui_type,
        &clock,
    );

    // Create payment coin
    let payment = coin::mint_for_testing<SUI>(2000, ts::ctx(&mut scenario));

    // Pay fee (should update both states)
    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify remaining funds
    assert_eq(coin::value(&remaining), 1000u64); // 2000 - 1000 fee
    assert_eq(periods, 1u64);

    // Verify FeeState was updated
    let (last_payment, paid_until) = fee_state::get_fee_info(&account);
    assert_eq(last_payment, 1000000);
    assert_eq(paid_until, 1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);

    // Cleanup
    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_zero_periods_no_state_update() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    // Set fee to 0 (no fees configured)
    let sui_type = type_name::get<SUI>();

    let payment = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));

    // Get initial fee state
    let (initial_payment, initial_until) = fee_state::get_fee_info(&account);

    // Pay fee (should return 0 periods, no state update)
    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify no payment occurred
    assert_eq(coin::value(&remaining), 1000u64); // All returned
    assert_eq(periods, 0u64);

    // Verify FeeState was NOT updated
    let (final_payment, final_until) = fee_state::get_fee_info(&account);
    assert_eq(final_payment, initial_payment);
    assert_eq(final_until, initial_until);

    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_multiple_periods() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(&mut fee_manager, multisig_id, sui_type, &clock);

    // Pay for 3 months at once
    let payment = coin::mint_for_testing<SUI>(3000, ts::ctx(&mut scenario));

    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify 3 periods paid
    assert_eq(coin::value(&remaining), 0u64);
    assert_eq(periods, 3u64);

    // Verify FeeState reflects 3 periods
    let (last_payment, paid_until) = fee_state::get_fee_info(&account);
    assert_eq(last_payment, 1000000);
    assert_eq(paid_until, 1000000 + (3 * MONTHLY_FEE_PERIOD_MS) + GRACE_PERIOD_MS);

    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_insufficient_funds() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(&mut fee_manager, multisig_id, sui_type, &clock);

    // Pay with insufficient funds (only 500, need 1000)
    let payment = coin::mint_for_testing<SUI>(500, ts::ctx(&mut scenario));

    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify no periods paid (insufficient funds)
    assert_eq(coin::value(&remaining), 500u64); // All returned
    assert_eq(periods, 0u64);

    // Verify FeeState not updated
    let (last_payment, paid_until) = fee_state::get_fee_info(&account);
    assert_eq(last_payment, 1000000); // Initial value
    assert_eq(paid_until, 1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS); // Initial value

    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_exact_amount() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(&mut fee_manager, multisig_id, sui_type, &clock);

    // Pay exact amount
    let payment = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));

    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify exact payment
    assert_eq(coin::value(&remaining), 0u64);
    assert_eq(periods, 1u64);

    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_sequential_payments() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(&mut fee_manager, multisig_id, sui_type, &clock);

    // First payment
    let payment1 = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
    let (remaining1, periods1) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment1,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert_eq(periods1, 1u64);
    coin::burn_for_testing(remaining1);

    // Move forward 1 month
    clock.set_for_testing(1000000 + MONTHLY_FEE_PERIOD_MS);

    // Second payment
    let payment2 = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
    let (remaining2, periods2) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment2,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert_eq(periods2, 1u64);
    coin::burn_for_testing(remaining2);

    // Verify cumulative state
    let (last_payment, paid_until) = fee_state::get_fee_info(&account);
    assert_eq(last_payment, 1000000 + MONTHLY_FEE_PERIOD_MS);
    assert_eq(paid_until, 1000000 + (2 * MONTHLY_FEE_PERIOD_MS) + GRACE_PERIOD_MS);

    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_with_overpayment() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(&mut fee_manager, multisig_id, sui_type, &clock);

    // Overpay (3500 for 1000/month fee = 3 periods with 500 remaining)
    let payment = coin::mint_for_testing<SUI>(3500, ts::ctx(&mut scenario));

    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify partial payment (3 periods, 500 remaining)
    assert_eq(coin::value(&remaining), 500u64);
    assert_eq(periods, 3u64);

    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_pay_fee_consistency_check() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock.set_for_testing(1000000);

    let mut account = create_test_multisig(&mut scenario);
    fee_state::init_fee_state(&mut account, &clock);

    let mut fee_manager = create_test_fee_manager(&mut scenario, &clock);

    let sui_type = type_name::get<SUI>();
    let monthly_fee = 1000u64;
    fee::add_coin_fee_config_for_testing(
        &mut fee_manager,
        sui_type,
        monthly_fee,
        0,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let multisig_id = object::id(&account);
    fee::register_multisig_for_testing(&mut fee_manager, multisig_id, sui_type, &clock);

    // Pay 2 periods
    let payment = coin::mint_for_testing<SUI>(2000, ts::ctx(&mut scenario));
    let (remaining, periods) = fee_collection::pay_multisig_fee_and_update_state(
        &mut account,
        &mut fee_manager,
        sui_type,
        vector[sui_type],
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify consistency between FeeManager and FeeState
    assert_eq(periods, 2u64);

    let (last_payment, paid_until) = fee_state::get_fee_info(&account);
    // FeeState should reflect 2 periods extension
    assert_eq(paid_until, 1000000 + (2 * MONTHLY_FEE_PERIOD_MS) + GRACE_PERIOD_MS);

    coin::burn_for_testing(remaining);
    fee::destroy_for_testing(fee_manager);
    weighted_multisig::destroy_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
