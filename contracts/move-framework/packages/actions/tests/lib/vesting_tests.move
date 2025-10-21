// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module account_actions::vesting_tests;

use account_actions::version;
use account_actions::vesting;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry, PackagePackageAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intent_interface;
use account_protocol::intents;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

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
public struct VestingIntent() has copy, drop;

// === Helper Functions ===

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
fun test_vesting_basic() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_vesting".to_string();

    // Test parameters
    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;

    // Create an intent with a vesting action
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test vesting".to_string(),
        vector[0], // execute immediately
        10000, // expiration
        &clock,
        scenario.ctx(),
    );

    // Build the intent using the intent interface
    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(), // metadata
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(), // no cliff
                10, // max_beneficiaries
                0, // no max per withdrawal
                0, // no min interval
                false, // not transferable
                true, // is cancelable
                option::none(), // no metadata
                iw,
            );
        },
    );

    // Execute the vesting action
    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    // Verify outcome
    assert!(outcome_result == outcome);

    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );

    // Confirm execution
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_with_cliff() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_vesting_cliff".to_string();

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let cliff_timestamp = 1500u64;
    let end_timestamp = 2000u64;

    // Create an intent with a vesting action that has a cliff
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test vesting with cliff".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::some(cliff_timestamp), // With cliff
                10,
                0,
                0,
                false,
                true,
                option::none(),
                iw,
            );
        },
    );

    // Execute the vesting action
    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);

    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );

    account.confirm_execution(executable);

    // Vesting should now exist - verify we can check claimable amount
    scenario.next_tx(RECIPIENT);
    let vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();

    // Before cliff - should be 0 claimable
    clock.set_for_testing(1400);
    assert!(vesting::claimable_now(&vesting_obj, &clock) == 0);

    // After cliff but before end - should have partial amount claimable
    clock.set_for_testing(1750); // 75% through (250 / 1000)
    let claimable = vesting::claimable_now(&vesting_obj, &clock);
    assert!(claimable > 0 && claimable < amount);

    // After end - should have full amount claimable
    clock.set_for_testing(2500);
    assert!(vesting::claimable_now(&vesting_obj, &clock) == amount);

    ts::return_shared(vesting_obj);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_claim() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_vesting_claim".to_string();

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;

    // Create and execute vesting
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test vesting claim".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(),
                10,
                0,
                0,
                false,
                true,
                option::none(),
                iw,
            );
        },
    );

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);
    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Claim vested funds
    scenario.next_tx(RECIPIENT);
    let mut vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();

    // Set time to 50% through vesting period
    clock.set_for_testing(1500);
    let claimable = vesting::claimable_now(&vesting_obj, &clock);
    assert!(claimable == 500); // 50% of 1000

    // Claim the vested amount
    let claimed_coin = vesting::claim_vesting<SUI>(
        &mut vesting_obj,
        claimable,
        &clock,
        scenario.ctx(),
    );

    assert!(claimed_coin.value() == 500);
    assert!(vesting::balance(&vesting_obj) == 500);

    // Claim remaining at end
    clock.set_for_testing(2500);
    let final_claimable = vesting::claimable_now(&vesting_obj, &clock);
    assert!(final_claimable == 500);

    let final_coin = vesting::claim_vesting<SUI>(
        &mut vesting_obj,
        final_claimable,
        &clock,
        scenario.ctx(),
    );

    assert!(final_coin.value() == 500);
    assert!(vesting::balance(&vesting_obj) == 0);

    destroy(claimed_coin);
    destroy(final_coin);
    ts::return_shared(vesting_obj);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_pause_resume() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_vesting_pause".to_string();

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;

    // Create and execute vesting
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test vesting pause".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(),
                10,
                0,
                0,
                false,
                true,
                option::none(),
                iw,
            );
        },
    );

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);
    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Test pause and resume
    scenario.next_tx(RECIPIENT);
    let mut vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();

    // Pause the vesting for 500ms
    clock.set_for_testing(1200);
    vesting::pause_vesting(&mut vesting_obj, 500, &clock, scenario.ctx());
    assert!(vesting::is_paused(&vesting_obj));

    // Try to claim while paused - should get 0
    let claimable_during_pause = vesting::claimable_now(&vesting_obj, &clock);
    assert!(claimable_during_pause == 0);

    // Resume the vesting
    clock.set_for_testing(1300);
    vesting::resume_vesting(&mut vesting_obj, &clock, scenario.ctx());
    assert!(!vesting::is_paused(&vesting_obj));

    // Now can claim again
    clock.set_for_testing(2100); // Past adjusted end time
    let claimable_after_resume = vesting::claimable_now(&vesting_obj, &clock);
    assert!(claimable_after_resume == amount);

    ts::return_shared(vesting_obj);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_cancel() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let create_key = b"test_vesting_cancel_create".to_string();
    let cancel_key = b"test_vesting_cancel_do".to_string();

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;

    // Create vesting
    let outcome = Outcome {};
    let params = intents::new_params(
        create_key,
        b"Test vesting cancel".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(),
                10,
                0,
                0,
                false,
                true, // is cancelable
                option::none(),
                iw,
            );
        },
    );

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        create_key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);
    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Get vesting ID
    scenario.next_tx(RECIPIENT);
    let vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();
    let vesting_id = object::id(&vesting_obj);
    assert!(vesting::is_cancelable(&vesting_obj));
    ts::return_shared(vesting_obj);

    // Create cancel intent
    scenario.next_tx(OWNER);
    let cancel_params = intents::new_params(
        cancel_key,
        b"Cancel vesting".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref2 = &account;
    account.build_intent!(
        cancel_params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_cancel_vesting<Outcome, VestingIntent>(
                intent,
                vesting_id,
                iw,
            );
        },
    );

    // Execute cancellation at 50% through vesting period
    clock.set_for_testing(1500);
    let (cancel_outcome, mut cancel_executable) = account.create_executable<_, Outcome, _>(
        cancel_key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(cancel_outcome == outcome);

    let vesting_to_cancel = scenario.take_shared<vesting::Vesting<SUI>>();
    vesting::cancel_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut cancel_executable,
        &mut account,
        vesting_to_cancel,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );

    account.confirm_execution(cancel_executable);

    // Verify recipient got vested portion
    scenario.next_tx(RECIPIENT);
    assert!(ts::has_most_recent_for_address<Coin<SUI>>(RECIPIENT));
    let recipient_coin = scenario.take_from_address<Coin<SUI>>(RECIPIENT);
    // Should receive approximately 50% (500 coins) as vested amount
    assert!(recipient_coin.value() >= 450 && recipient_coin.value() <= 550);

    destroy(recipient_coin);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_multiple_beneficiaries() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_vesting_multi_beneficiaries".to_string();

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;
    let additional_beneficiary = @0xDEAD;

    // Create vesting
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test multiple beneficiaries".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(),
                10,
                0,
                0,
                false,
                true,
                option::none(),
                iw,
            );
        },
    );

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);
    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Add additional beneficiary
    scenario.next_tx(RECIPIENT);
    let mut vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();

    assert!(vesting::beneficiaries_count(&vesting_obj) == 1);
    vesting::add_beneficiary(&mut vesting_obj, additional_beneficiary, scenario.ctx());
    assert!(vesting::beneficiaries_count(&vesting_obj) == 2);

    // Additional beneficiary can claim
    clock.set_for_testing(1500);
    ts::return_shared(vesting_obj);

    scenario.next_tx(additional_beneficiary);
    let mut vesting_obj2 = scenario.take_shared<vesting::Vesting<SUI>>();
    let claimable = vesting::claimable_now(&vesting_obj2, &clock);
    assert!(claimable == 500); // 50% vested

    let claimed = vesting::claim_vesting<SUI>(
        &mut vesting_obj2,
        claimable,
        &clock,
        scenario.ctx(),
    );
    assert!(claimed.value() == 500);

    // Remove beneficiary
    ts::return_shared(vesting_obj2);
    scenario.next_tx(RECIPIENT);
    let mut vesting_obj3 = scenario.take_shared<vesting::Vesting<SUI>>();
    vesting::remove_beneficiary(&mut vesting_obj3, additional_beneficiary, scenario.ctx());
    assert!(vesting::beneficiaries_count(&vesting_obj3) == 1);

    destroy(claimed);
    ts::return_shared(vesting_obj3);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_transfer_ownership() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_vesting_transfer".to_string();
    let new_beneficiary = @0xDEAD;

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;

    // Create transferable vesting
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test vesting transfer".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(),
                10,
                0,
                0,
                true, // is transferable
                true,
                option::none(),
                iw,
            );
        },
    );

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);
    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Transfer to new beneficiary
    scenario.next_tx(RECIPIENT);
    let mut vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();

    assert!(vesting::is_transferable(&vesting_obj));
    vesting::transfer_vesting(&mut vesting_obj, new_beneficiary, scenario.ctx());

    ts::return_shared(vesting_obj);

    // New beneficiary can now claim
    scenario.next_tx(new_beneficiary);
    let mut vesting_obj2 = scenario.take_shared<vesting::Vesting<SUI>>();

    clock.set_for_testing(1500);
    let claimable = vesting::claimable_now(&vesting_obj2, &clock);
    assert!(claimable == 500);

    let claimed = vesting::claim_vesting<SUI>(
        &mut vesting_obj2,
        claimable,
        &clock,
        scenario.ctx(),
    );
    assert!(claimed.value() == 500);

    destroy(claimed);
    ts::return_shared(vesting_obj2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_emergency_freeze() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let key = b"test_vesting_freeze".to_string();

    let amount = 1000u64;
    let start_timestamp = 1000u64;
    let end_timestamp = 2000u64;

    // Create vesting
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test vesting freeze".to_string(),
        vector[0],
        10000,
        &clock,
        scenario.ctx(),
    );

    let account_ref = &account;
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingIntent(),
        scenario.ctx(),
        |intent, iw| {
            vesting::new_vesting<Config, Outcome, SUI, VestingIntent>(
                intent,
                account_ref,
                vector[RECIPIENT],
                vector[amount],
                start_timestamp,
                end_timestamp,
                option::none(),
                10,
                0,
                0,
                false,
                true,
                option::none(),
                iw,
            );
        },
    );

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let (outcome_result, mut executable) = account.create_executable<_, Outcome, _>(
        key,
        &clock,
        version::current(),
        Witness(),
        scenario.ctx(),
    );

    assert!(outcome_result == outcome);
    vesting::do_vesting<Config, Outcome, SUI, VestingIntent>(
        &mut executable,
        &mut account,
        coin,
        &clock,
        VestingIntent(),
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Emergency freeze
    scenario.next_tx(OWNER); // Governance can freeze
    let mut vesting_obj = scenario.take_shared<vesting::Vesting<SUI>>();

    clock.set_for_testing(1200);
    vesting::emergency_freeze(&mut vesting_obj, &clock);

    // Verify frozen - can't claim
    clock.set_for_testing(1500);
    let claimable = vesting::claimable_now(&vesting_obj, &clock);
    assert!(claimable == 0);

    // Unfreeze
    clock.set_for_testing(1600);
    vesting::emergency_unfreeze(&mut vesting_obj, &clock);

    // Beneficiary still needs to unpause after unfreeze
    ts::return_shared(vesting_obj);
    scenario.next_tx(RECIPIENT);
    let mut vesting_obj2 = scenario.take_shared<vesting::Vesting<SUI>>();

    vesting::resume_vesting(&mut vesting_obj2, &clock, scenario.ctx());

    // Now can claim - use a time well past the adjusted end time
    // The pause duration extends the vesting period
    clock.set_for_testing(3000);
    let claimable_after = vesting::claimable_now(&vesting_obj2, &clock);
    // Should be able to claim full amount after accounting for pause
    assert!(claimable_after == amount);

    ts::return_shared(vesting_obj2);
    end(scenario, extensions, account, clock);
}
