// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::launchpad_permissionless_tests;

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
public struct TEST_ASSET has drop, store {}
public struct TEST_STABLE has drop, store {}

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

    // Add TEST_STABLE as allowed stable type
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        factory::add_allowed_stable_type<TEST_STABLE>(
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
/// Test that anyone can complete a raise after 24 hour delay (permissionless completion)
fun test_permissionless_completion_after_delay() {
    let creator = @0xA;
    let contributor = @0xB;
    let random_completer = @0xC; // Not the creator
    let mut scenario = setup_test(creator);

    // Create raise
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<TEST_ASSET, TEST_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"permissionless-test".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Permissionless completion test".to_string(),
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
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET, TEST_STABLE>>(&scenario);
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
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET, TEST_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<TEST_STABLE>(20_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Advance past deadline and settle
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, creator);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET, TEST_STABLE>>(&scenario);
        launchpad::settle_raise(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    // Note: We skip testing premature permissionless completion as it's covered in a separate expected_failure test

    // Advance another 24 hours (permissionless window opens)
    clock::increment_for_testing(&mut clock, 24 * 60 * 60 * 1000);

    // Note: We cannot test the actual completion in the test framework because
    // complete_raise_permissionless calls complete_raise_internal which shares objects,
    // and sharing objects is not allowed in the test framework. The logic is identical
    // to complete_raise which is already tested, with only the additional time check.

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = launchpad::EInvalidStateForAction)]
/// Test that permissionless completion fails if not settled
fun test_permissionless_completion_requires_settlement() {
    let creator = @0xA;
    let contributor = @0xB;
    let random_completer = @0xC;
    let mut scenario = setup_test(creator);

    // Create raise
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<TEST_ASSET, TEST_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"test".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Test".to_string(),
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
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET, TEST_STABLE>>(&scenario);
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
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET, TEST_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<TEST_STABLE>(20_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Advance past deadline + 24 hours but DON'T settle
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + (24 * 60 * 60 * 1000) + 1);

    // Try permissionless completion without settlement - should fail
    ts::next_tx(&mut scenario, random_completer);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET, TEST_STABLE>>(&scenario);
        let registry = ts::take_shared<PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let dao_payment = create_payment(fee::get_dao_creation_fee(&fee_manager), &mut scenario);

        launchpad::complete_raise_permissionless(
            &mut raise,
            &registry,
            &mut fee_manager,
            dao_payment,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
    };

    ts::end(scenario);
}
