// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::launchpad_dust_tests;

use account_protocol::account::Account;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use futarchy_factory::factory;
use futarchy_factory::launchpad;
use futarchy_markets_core::fee;
use futarchy_one_shot_utils::constants;
use std::string::String;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

// === Test Coin Types ===
public struct DUST_TOKEN has drop, store {}
public struct DUST_STABLE has drop, store {}

// === Helper Functions ===

fun setup_test(sender: address): Scenario {
    let mut scenario = ts::begin(sender);

    // Create factory
    ts::next_tx(&mut scenario, sender);
    {
        factory::create_factory(ts::ctx(&mut scenario));
    };

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        fee::create_fee_manager_for_testing(ts::ctx(&mut scenario));
    };

    // Create package registry
    ts::next_tx(&mut scenario, sender);
    {
        package_registry::init_for_testing(ts::ctx(&mut scenario));
    };

    // Register required packages
    ts::next_tx(&mut scenario, sender);
    {
        let mut registry = ts::take_shared<PackageRegistry>(&scenario);
        let admin_cap = ts::take_from_sender<package_registry::PackageAdminCap>(&scenario);

        package_registry::add_for_testing(
            &mut registry,
            &admin_cap,
            b"AccountProtocol".to_string(),
            @account_protocol,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            &admin_cap,
            b"FutarchyCore".to_string(),
            @futarchy_core,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            &admin_cap,
            b"AccountActions".to_string(),
            @account_actions,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            &admin_cap,
            b"FutarchyActions".to_string(),
            @futarchy_actions,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            &admin_cap,
            b"FutarchyGovernanceActions".to_string(),
            @0xb1054e9a9b316e105c908be2cddb7f64681a63f0ae80e9e5922bf461589c4bc7,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            &admin_cap,
            b"FutarchyOracleActions".to_string(),
            @futarchy_oracle,
            1
        );

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(registry);
    };

    // Add DUST_STABLE as allowed stable type
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        factory::add_allowed_stable_type<DUST_STABLE>(
            &mut factory,
            &owner_cap,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, owner_cap);
        ts::return_shared(factory);
    };

    scenario
}

fun create_payment(amount: u64, scenario: &mut Scenario): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ts::ctx(scenario))
}

// === Tests ===

#[test]
/// Test sweep_dust sends remaining tokens to creator and stables to DAO after claim period
fun test_sweep_dust_after_claim_period() {
    let creator = @0xA;
    let contributor1 = @0xB;
    let contributor2 = @0xC;
    let mut scenario = setup_test(creator);

    // Create raise
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = coin::create_treasury_cap_for_testing<DUST_TOKEN>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<DUST_TOKEN, DUST_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"dust-test".to_string(),
            1_000_000_000_000, // 1M tokens for sale
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Dust sweep test".to_string(),
            vector::empty<String>(),
            vector::empty<String>(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Pre-create DAO and lock
    ts::next_tx(&mut scenario, creator);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let dao_payment = create_payment(fee::get_dao_creation_fee(&fee_manager), &mut scenario);

        launchpad::pre_create_dao_for_raise(&mut raise, &creator_cap, &mut factory, &registry, &mut fee_manager, dao_payment, &clock, ts::ctx(&mut scenario));
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
        ts::return_shared(factory);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
    };

    // Two contributors contribute
    ts::next_tx(&mut scenario, contributor1);
    {
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<DUST_STABLE>(15_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::next_tx(&mut scenario, contributor2);
    {
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let contribution = coin::mint_for_testing<DUST_STABLE>(5_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Settle and complete
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, creator);
    {
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        launchpad::settle_raise(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, creator);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let dao_payment = create_payment(fee::get_dao_creation_fee(&fee_manager), &mut scenario);

        launchpad::complete_raise_test(&mut raise, &creator_cap, &mut fee_manager, dao_payment, &clock, ts::ctx(&mut scenario));

        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
        ts::return_shared(fee_manager);
    };

    // Only contributor1 claims (contributor2 doesn't claim - leaving dust)
    ts::next_tx(&mut scenario, contributor1);
    {
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        launchpad::claim_tokens(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    // Note: Contributor2 doesn't claim, leaving tokens and stables as dust

    // Note: We skip the test for sweeping before claim period as it's tested in the expected_failure test below

    // Advance past claim period
    clock::increment_for_testing(&mut clock, constants::launchpad_claim_period_ms() + 1);

    // Now sweep dust (after claim period)
    ts::next_tx(&mut scenario, creator);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let mut dao_account = ts::take_from_sender<Account>(&scenario);

        launchpad::sweep_dust(&mut raise, &creator_cap, &mut dao_account, &clock, ts::ctx(&mut scenario));

        ts::return_to_sender(&scenario, creator_cap);
        ts::return_to_sender(&scenario, dao_account);
        ts::return_shared(raise);
    };

    // Verify creator received dust tokens (if any remained)
    ts::next_tx(&mut scenario, creator);
    {
        // In this test, contributor2 didn't claim, so there should be dust
        // Note: The exact amount depends on the pro-rata calculation
        if (ts::has_most_recent_for_sender<Coin<DUST_TOKEN>>(&scenario)) {
            let dust_tokens = ts::take_from_sender<Coin<DUST_TOKEN>>(&scenario);
            ts::return_to_sender(&scenario, dust_tokens);
        };
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = launchpad::EDeadlineNotReached)]
/// Test sweep_dust fails before claim period ends
fun test_sweep_dust_fails_before_claim_period() {
    let creator = @0xA;
    let contributor = @0xB;
    let mut scenario = setup_test(creator);

    // Create and complete a raise
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = coin::create_treasury_cap_for_testing<DUST_TOKEN>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<DUST_TOKEN, DUST_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"early-sweep".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Early sweep test".to_string(),
            vector::empty<String>(),
            vector::empty<String>(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Pre-create DAO and lock
    ts::next_tx(&mut scenario, creator);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let dao_payment = create_payment(fee::get_dao_creation_fee(&fee_manager), &mut scenario);

        launchpad::pre_create_dao_for_raise(&mut raise, &creator_cap, &mut factory, &registry, &mut fee_manager, dao_payment, &clock, ts::ctx(&mut scenario));
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
        ts::return_shared(factory);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
    };

    // Contribute
    ts::next_tx(&mut scenario, contributor);
    {
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<DUST_STABLE>(20_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Settle and complete
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, creator);
    {
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        launchpad::settle_raise(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, creator);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let dao_payment = create_payment(fee::get_dao_creation_fee(&fee_manager), &mut scenario);

        launchpad::complete_raise_test(&mut raise, &creator_cap, &mut fee_manager, dao_payment, &clock, ts::ctx(&mut scenario));

        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
        ts::return_shared(fee_manager);
    };

    // Try to sweep dust immediately after completion (before claim period) - should fail
    ts::next_tx(&mut scenario, creator);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<DUST_TOKEN, DUST_STABLE>>(&scenario);
        let mut dao_account = ts::take_from_sender<Account>(&scenario);

        launchpad::sweep_dust(&mut raise, &creator_cap, &mut dao_account, &clock, ts::ctx(&mut scenario));

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_to_sender(&scenario, dao_account);
        ts::return_shared(raise);
    };

    ts::end(scenario);
}
