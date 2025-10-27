// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::launchpad_admin_validation_tests;

use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use futarchy_factory::admin_token::{Self, ADMIN_TOKEN};
use futarchy_factory::admin_stable::{Self, ADMIN_STABLE};
use futarchy_factory::factory;
use futarchy_factory::launchpad;
use futarchy_markets_core::fee;
use futarchy_one_shot_utils::constants;
use std::string::String;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

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
            b"AccountProtocol".to_string(),
            @account_protocol,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            b"FutarchyCore".to_string(),
            @futarchy_core,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            b"AccountActions".to_string(),
            @account_actions,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            b"FutarchyActions".to_string(),
            @futarchy_actions,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            b"FutarchyGovernanceActions".to_string(),
            @0xb1054e9a9b316e105c908be2cddb7f64681a63f0ae80e9e5922bf461589c4bc7,
            1
        );
        package_registry::add_for_testing(
            &mut registry,
            b"FutarchyOracleActions".to_string(),
            @futarchy_oracle,
            1
        );

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(registry);
    };

    // Add ADMIN_STABLE as allowed stable type
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        factory::add_allowed_stable_type<ADMIN_STABLE>(
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

// === Admin Tests ===

#[test]
/// Test set_admin_trust_score sets trust score and review text
fun test_set_admin_trust_score() {
    let creator = @0xA;
    let mut scenario = setup_test(creator);

    // Create test coin using test module
    ts::next_tx(&mut scenario, creator);
    admin_token::init_for_testing(ts::ctx(&mut scenario));

    // Create raise
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<ADMIN_TOKEN>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<ADMIN_TOKEN>>(&scenario);
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<ADMIN_TOKEN, ADMIN_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            coin_metadata,
            b"admin-test".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Admin test".to_string(),
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

    // Admin sets trust score
    ts::next_tx(&mut scenario, creator);
    {
        let mut raise = ts::take_shared<launchpad::Raise<ADMIN_TOKEN, ADMIN_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let validator_cap = ts::take_from_sender<factory::ValidatorAdminCap>(&scenario);

        // Verify trust score is none before setting
        assert!(launchpad::admin_trust_score(&raise).is_none(), 0);
        assert!(launchpad::admin_review_text(&raise).is_none(), 1);

        // Set trust score and review
        launchpad::set_admin_trust_score(
            &mut raise,
            &validator_cap,
            85, // trust score out of 100
            b"Verified team, solid project plan".to_string()
        );

        // Verify trust score is set
        assert!(launchpad::admin_trust_score(&raise).is_some(), 2);
        assert!(*launchpad::admin_trust_score(&raise).borrow() == 85, 3);

        assert!(launchpad::admin_review_text(&raise).is_some(), 4);

        ts::return_to_sender(&scenario, validator_cap);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

// === Validation Error Tests ===

#[test]
#[expected_failure(abort_code = launchpad::EAllowedCapsEmpty)]
/// Test create_raise fails with empty allowed_caps
fun test_create_raise_empty_caps_error() {
    let creator = @0xA;
    let mut scenario = setup_test(creator);

    // Create test coin using test module
    ts::next_tx(&mut scenario, creator);
    admin_token::init_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<ADMIN_TOKEN>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<ADMIN_TOKEN>>(&scenario);
        let payment = create_payment(10_000_000_000, &mut scenario);

        let allowed_caps = vector::empty<u64>(); // EMPTY - should fail

        launchpad::create_raise<ADMIN_TOKEN, ADMIN_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            coin_metadata,
            b"empty-caps".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Empty caps test".to_string(),
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

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = launchpad::EAllowedCapsNotSorted)]
/// Test create_raise fails with unsorted allowed_caps
fun test_create_raise_unsorted_caps_error() {
    let creator = @0xA;
    let mut scenario = setup_test(creator);

    // Create test coin using test module
    ts::next_tx(&mut scenario, creator);
    admin_token::init_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<ADMIN_TOKEN>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<ADMIN_TOKEN>>(&scenario);
        let payment = create_payment(10_000_000_000, &mut scenario);

        // Unsorted caps - should fail
        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, 50_000_000_000); // 50k
        vector::push_back(&mut allowed_caps, 10_000_000_000); // 10k (OUT OF ORDER)
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<ADMIN_TOKEN, ADMIN_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            coin_metadata,
            b"unsorted-caps".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"Unsorted caps test".to_string(),
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

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = launchpad::EInvalidStateForAction)]
/// Test create_raise fails if last cap is not UNLIMITED_CAP
fun test_create_raise_last_cap_not_unlimited() {
    let creator = @0xA;
    let mut scenario = setup_test(creator);

    // Create test coin using test module
    ts::next_tx(&mut scenario, creator);
    admin_token::init_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<ADMIN_TOKEN>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<ADMIN_TOKEN>>(&scenario);
        let payment = create_payment(10_000_000_000, &mut scenario);

        // Last cap is NOT unlimited - should fail
        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, 10_000_000_000);
        vector::push_back(&mut allowed_caps, 50_000_000_000); // Last is NOT UNLIMITED_CAP

        launchpad::create_raise<ADMIN_TOKEN, ADMIN_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            coin_metadata,
            b"no-unlimited".to_string(),
            1_000_000_000_000,
            10_000_000_000,
            option::none(),
            allowed_caps,
            false,
            b"No unlimited cap test".to_string(),
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

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = launchpad::EInvalidMaxRaise)]
/// Test create_raise fails if max_raise_amount < min_raise_amount
fun test_create_raise_invalid_max_raise() {
    let creator = @0xA;
    let mut scenario = setup_test(creator);

    // Create test coin using test module
    ts::next_tx(&mut scenario, creator);
    admin_token::init_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<ADMIN_TOKEN>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<ADMIN_TOKEN>>(&scenario);
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        // max (5k) < min (10k) - should fail
        launchpad::create_raise<ADMIN_TOKEN, ADMIN_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            coin_metadata,
            b"invalid-max".to_string(),
            1_000_000_000_000,
            10_000_000_000, // min 10k
            option::some(5_000_000_000), // max 5k (INVALID)
            allowed_caps,
            false,
            b"Invalid max raise test".to_string(),
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

    ts::end(scenario);
}

#[test]
/// Test max_raise_amount caps the final settlement amount
fun test_max_raise_caps_settlement() {
    let creator = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let mut scenario = setup_test(creator);

    // Create test coin using test module
    ts::next_tx(&mut scenario, creator);
    admin_token::init_for_testing(ts::ctx(&mut scenario));

    // Create raise with max_raise_amount = 30k
    ts::next_tx(&mut scenario, creator);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<ADMIN_TOKEN>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<ADMIN_TOKEN>>(&scenario);
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_caps = vector::empty<u64>();
        vector::push_back(&mut allowed_caps, launchpad::unlimited_cap());

        launchpad::create_raise<ADMIN_TOKEN, ADMIN_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            coin_metadata,
            b"max-cap-test".to_string(),
            1_000_000_000_000,
            10_000_000_000, // min 10k
            option::some(30_000_000_000), // max 30k
            allowed_caps,
            false,
            b"Max raise capping test".to_string(),
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
        let mut raise = ts::take_shared<launchpad::Raise<ADMIN_TOKEN, ADMIN_STABLE>>(&scenario);
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

    // Contribute total of 50k (above 30k max)
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<ADMIN_TOKEN, ADMIN_STABLE>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let contribution = coin::mint_for_testing<ADMIN_STABLE>(30_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<ADMIN_TOKEN, ADMIN_STABLE>>(&scenario);
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let contribution = coin::mint_for_testing<ADMIN_STABLE>(20_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);
        launchpad::contribute(&mut raise, &factory, contribution, launchpad::unlimited_cap(), crank_fee, &clock, ts::ctx(&mut scenario));
        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
        ts::return_shared(factory);
    };

    // Settle
    ts::next_tx(&mut scenario, creator);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, creator);
    {
        let mut raise = ts::take_shared<launchpad::Raise<ADMIN_TOKEN, ADMIN_STABLE>>(&scenario);
        launchpad::settle_raise(&mut raise, &clock, ts::ctx(&mut scenario));

        // Verify final_raise_amount is capped at max (30k), not the contributed amount (50k)
        assert!(launchpad::final_raise_amount(&raise) == 30_000_000_000, 0);

        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
