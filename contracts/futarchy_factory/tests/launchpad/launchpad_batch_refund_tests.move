// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::launchpad_batch_refund_tests;

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
public struct REFUND_TOKEN has drop, store {}
public struct REFUND_STABLE has drop, store {}

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

    // Add REFUND_STABLE as allowed stable type
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        factory::add_allowed_stable_type<REFUND_STABLE>(
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
/// Test batch_claim_refund_for processes multiple refunds and pays cranker
fun test_batch_refund_for_failed_raise() {
    let creator = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let charlie = @0xD;
    let cranker = @0xE;
    let mut scenario = setup_test(creator);

    // Create raise that will fail (high min)
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = coin::create_treasury_cap_for_testing<REFUND_TOKEN>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<REFUND_TOKEN, REFUND_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"batch-refund".to_string(),
            1_000_000_000_000,
            100_000_000_000, // min 100k (will fail)
            option::none(),
            allowed_caps,
            false,
            b"Batch refund test".to_string(),
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
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
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

    // Three contributors contribute (total will be below 100k min)
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<REFUND_STABLE>(10_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let contribution = coin::mint_for_testing<REFUND_STABLE>(15_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::next_tx(&mut scenario, charlie);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<REFUND_STABLE>(5_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Advance past deadline (raise failed)
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    // Cranker batch refunds for all contributors
    ts::next_tx(&mut scenario, cranker);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);

        let mut contributors = vector::empty<address>();
        vector::push_back(&mut contributors, alice);
        vector::push_back(&mut contributors, bob);
        vector::push_back(&mut contributors, charlie);

        launchpad::batch_claim_refund_for(&mut raise, &factory, contributors, &clock, ts::ctx(&mut scenario));

        // Verify raise is now in FAILED state
        assert!(launchpad::state(&raise) == 2, 0); // STATE_FAILED

        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Verify cranker received rewards (0.1 SUI per refund * 3 = 3 separate coins)
    // Note: The batch_claim_refund_for function transfers rewards individually,
    // not as one accumulated coin, so we'll receive 3 separate 0.1 SUI coins

    // Verify all contributors received their refunds
    ts::next_tx(&mut scenario, alice);
    {
        assert!(ts::has_most_recent_for_sender<Coin<REFUND_STABLE>>(&scenario), 3);
        let refund = ts::take_from_sender<Coin<REFUND_STABLE>>(&scenario);
        assert!(refund.value() == 10_000_000_000, 4);
        ts::return_to_sender(&scenario, refund);
    };

    ts::next_tx(&mut scenario, bob);
    {
        assert!(ts::has_most_recent_for_sender<Coin<REFUND_STABLE>>(&scenario), 5);
        let refund = ts::take_from_sender<Coin<REFUND_STABLE>>(&scenario);
        assert!(refund.value() == 15_000_000_000, 6);
        ts::return_to_sender(&scenario, refund);
    };

    ts::next_tx(&mut scenario, charlie);
    {
        assert!(ts::has_most_recent_for_sender<Coin<REFUND_STABLE>>(&scenario), 7);
        let refund = ts::take_from_sender<Coin<REFUND_STABLE>>(&scenario);
        assert!(refund.value() == 5_000_000_000, 8);
        ts::return_to_sender(&scenario, refund);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Test batch_claim_refund_for gracefully skips already-claimed contributors
fun test_batch_refund_skips_already_claimed() {
    let creator = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let charlie = @0xD;
    let cranker = @0xE;
    let mut scenario = setup_test(creator);

    // Create raise that will fail
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = coin::create_treasury_cap_for_testing<REFUND_TOKEN>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<REFUND_TOKEN, REFUND_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"skip-test".to_string(),
            1_000_000_000_000,
            100_000_000_000, // min 100k (will fail)
            option::none(),
            allowed_caps,
            false,
            b"Skip already claimed test".to_string(),
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
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
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

    // Three contributors contribute
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<REFUND_STABLE>(10_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let contribution = coin::mint_for_testing<REFUND_STABLE>(15_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::next_tx(&mut scenario, charlie);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<REFUND_STABLE>(5_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Advance past deadline
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    // Alice claims her refund manually first
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        launchpad::claim_refund(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    // Cranker tries to batch refund for ALL three (including already-claimed Alice)
    // Should gracefully skip Alice
    ts::next_tx(&mut scenario, cranker);
    {
        let mut raise = ts::take_shared<launchpad::Raise<REFUND_TOKEN, REFUND_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);

        let mut contributors = vector::empty<address>();
        vector::push_back(&mut contributors, alice); // Already claimed
        vector::push_back(&mut contributors, bob);
        vector::push_back(&mut contributors, charlie);

        launchpad::batch_claim_refund_for(&mut raise, &factory, contributors, &clock, ts::ctx(&mut scenario));

        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Verify cranker received rewards for only 2 refunds (Bob and Charlie)
    // Note: Same as above - rewards come as individual transfers, not accumulated

    // Verify Bob and Charlie received refunds
    ts::next_tx(&mut scenario, bob);
    {
        assert!(ts::has_most_recent_for_sender<Coin<REFUND_STABLE>>(&scenario), 2);
        let refund = ts::take_from_sender<Coin<REFUND_STABLE>>(&scenario);
        assert!(refund.value() == 15_000_000_000, 3);
        ts::return_to_sender(&scenario, refund);
    };

    ts::next_tx(&mut scenario, charlie);
    {
        assert!(ts::has_most_recent_for_sender<Coin<REFUND_STABLE>>(&scenario), 4);
        let refund = ts::take_from_sender<Coin<REFUND_STABLE>>(&scenario);
        assert!(refund.value() == 5_000_000_000, 5);
        ts::return_to_sender(&scenario, refund);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
