// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::factory_tests;

use account_protocol::package_registry;
use futarchy_factory::factory;
use futarchy_factory::test_asset::{Self, TEST_ASSET};
use futarchy_factory::test_asset_regular::{Self, TEST_ASSET_REGULAR};
use futarchy_factory::test_stable::{Self, TEST_STABLE};
use futarchy_factory::test_stable_regular::{Self, TEST_STABLE_REGULAR};
use futarchy_markets_core::fee;
use sui::clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
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

    // Add TEST_STABLE_REGULAR as allowed stable type
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        factory::add_allowed_stable_type<TEST_STABLE_REGULAR>(
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

// === DAO Creation Tests ===

#[test]
fun test_basic_dao_creation() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Initialize test asset coin
    ts::next_tx(&mut scenario, sender);
    test_asset::init_for_testing(ts::ctx(&mut scenario));

    // Create a new DAO
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<package_registry::PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create payment for DAO creation (10_000 MIST = 0.00001 SUI)
        let payment = create_payment(10_000, &mut scenario);

        // Take treasury cap and metadata from sender
        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<TEST_ASSET>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<TEST_ASSET>>(&scenario);

        // Create DAO with test parameters
        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
            &registry,
            &mut fee_manager,
            payment,
            100_000, // min_asset_amount
            100_000, // min_stable_amount
            b"Test DAO".to_ascii_string(),
            b"https://example.com/icon.png".to_ascii_string(),
            86400000, // review_period_ms (1 day)
            259200000, // trading_period_ms (3 days)
            60000, // twap_start_delay (1 minute)
            10, // twap_step_max
            1_000_000_000_000, // twap_initial_observation
            500_000, // twap_threshold_magnitude (0.5 or 50% increase)
            false, // twap_threshold_negative
            30, // amm_total_fee_bps (0.3%)
            b"Test DAO for basic creation".to_string(),
            3, // max_outcomes
            vector::empty(), // agreement_lines
            vector::empty(), // agreement_difficulties
            treasury_cap,
            coin_metadata,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify DAO was created
        assert!(factory::dao_count(&factory) == 1, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
fun test_multiple_dao_creation() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Initialize test asset coin
    ts::next_tx(&mut scenario, sender);
    test_asset::init_for_testing(ts::ctx(&mut scenario));

    // Create first DAO
    ts::next_tx(&mut scenario, sender);
    {
        let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_ASSET>>(&scenario);
        let coin_metadata = ts::take_from_sender<CoinMetadata<TEST_ASSET>>(&scenario);
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<package_registry::PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
            &registry,
            &mut fee_manager,
            payment,
            100_000, 100_000,
            b"DAO 1".to_ascii_string(),
            b"https://example.com/icon1.png".to_ascii_string(),
            86400000, 259200000, 60000, 10,
            1_000_000_000_000,
            500_000, // twap_threshold_magnitude
            false, // twap_threshold_negative
            30,
            b"First DAO".to_string(),
            3,
            vector::empty(), vector::empty(),
            treasury_cap,
            coin_metadata,
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(factory::dao_count(&factory) == 1, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    // Initialize test asset coin for second DAO
    ts::next_tx(&mut scenario, sender);
    test_asset::init_for_testing(ts::ctx(&mut scenario));

    // Create second DAO
    ts::next_tx(&mut scenario, sender);
    {
        let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_ASSET>>(&scenario);
        let coin_metadata = ts::take_from_sender<CoinMetadata<TEST_ASSET>>(&scenario);
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<package_registry::PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
            &registry,
            &mut fee_manager,
            payment,
            200_000, 200_000,
            b"DAO 2".to_ascii_string(),
            b"https://example.com/icon2.png".to_ascii_string(),
            172800000, 432000000, 120000, 20,
            2_000_000_000_000,
            750_000, // twap_threshold_magnitude
            false, // twap_threshold_negative
            50,
            b"Second DAO".to_string(),
            5,
            vector::empty(), vector::empty(),
            treasury_cap,
            coin_metadata,
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(factory::dao_count(&factory) == 2, 1);

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = factory::EStableTypeNotAllowed)]
fun test_dao_creation_with_unallowed_stable() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Initialize test asset coin
    ts::next_tx(&mut scenario, sender);
    test_asset::init_for_testing(ts::ctx(&mut scenario));

    // Try to create DAO with TEST_STABLE (not added to factory - only TEST_STABLE_REGULAR was added)
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<package_registry::PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<TEST_ASSET>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<TEST_ASSET>>(&scenario);

        factory::create_dao_test<TEST_ASSET, TEST_STABLE>(
            &mut factory,
            &registry,
            &mut fee_manager,
            payment,
            100_000, 100_000,
            b"Invalid DAO".to_ascii_string(),
            b"https://example.com/icon.png".to_ascii_string(),
            86400000, 259200000, 60000, 10,
            1_000_000_000_000,
            500_000, // twap_threshold_magnitude
            false, // twap_threshold_negative
            30,
            b"Should fail".to_string(),
            3,
            vector::empty(), vector::empty(),
            treasury_cap,
            coin_metadata,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

// === Factory Control Tests ===

#[test]
#[expected_failure(abort_code = factory::EPermanentlyDisabled)]
fun test_permanent_disable_prevents_dao_creation() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Permanently disable the factory
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Verify not disabled initially
        assert!(!factory::is_permanently_disabled(&factory), 0);

        // Permanently disable
        factory::disable_permanently(&mut factory, &owner_cap, &clock, ts::ctx(&mut scenario));

        // Verify it is now disabled
        assert!(factory::is_permanently_disabled(&factory), 1);

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, owner_cap);
        ts::return_shared(factory);
    };

    // Initialize test asset regular coin
    ts::next_tx(&mut scenario, sender);
    test_asset_regular::init_for_testing(ts::ctx(&mut scenario));

    // Try to create a DAO - this should fail with EPermanentlyDisabled
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<package_registry::PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let payment = create_payment(100_000_000, &mut scenario);

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<TEST_ASSET_REGULAR>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<TEST_ASSET_REGULAR>>(&scenario);

        factory::create_dao_test<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut factory,
            &registry,
            &mut fee_manager,
            payment,
            1_000_000,
            1_000_000,
            b"Test DAO".to_ascii_string(),
            b"https://example.com/icon.png".to_ascii_string(),
            86_400_000, // 1 day review
            86_400_000, // 1 day trading
            60_000,     // 1 minute delay
            10,         // twap_step_max
            1_000_000_000_000, // twap_initial_observation
            100_000,    // twap_threshold_magnitude (0.1 = 10%)
            false,      // twap_threshold_negative
            30,         // 0.3% AMM fee
            b"Test DAO Description".to_string(),
            2,          // max_outcomes
            vector::empty(),
            vector::empty(),
            treasury_cap,
            coin_metadata,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
fun test_pause_is_reversible_but_disable_is_not() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);

        // Test pause/unpause (reversible)
        assert!(!factory::is_paused(&factory), 0);
        factory::toggle_pause(&mut factory, &owner_cap);
        assert!(factory::is_paused(&factory), 1);
        factory::toggle_pause(&mut factory, &owner_cap);
        assert!(!factory::is_paused(&factory), 2);

        // Test permanent disable (not reversible)
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        assert!(!factory::is_permanently_disabled(&factory), 3);
        factory::disable_permanently(&mut factory, &owner_cap, &clock, ts::ctx(&mut scenario));
        assert!(factory::is_permanently_disabled(&factory), 4);

        // Verify there is no way to reverse it - the flag stays true
        // (No function exists to set it back to false)

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, owner_cap);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
fun test_otw_coin_compatibility() {
    // This test verifies that OTW-compliant coin types (with only 'drop' ability)
    // work correctly with the factory API
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Initialize OTW-compliant test asset (has only 'drop', not 'store')
    ts::next_tx(&mut scenario, sender);
    test_asset::init_for_testing(ts::ctx(&mut scenario));

    // Create a DAO with OTW coin - should succeed
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let registry = ts::take_shared<package_registry::PackageRegistry>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        let treasury_cap = ts::take_from_sender<coin::TreasuryCap<TEST_ASSET>>(&scenario);
        let coin_metadata = ts::take_from_sender<coin::CoinMetadata<TEST_ASSET>>(&scenario);

        // This should succeed with OTW-compliant coins (only 'drop' ability)
        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
            &registry,
            &mut fee_manager,
            payment,
            100_000,
            100_000,
            b"OTW Test DAO".to_ascii_string(),
            b"https://example.com/icon.png".to_ascii_string(),
            86400000,
            259200000,
            60000,
            10,
            1_000_000_000_000,
            500_000,
            false,
            30,
            b"Testing OTW compatibility".to_string(),
            3,
            vector::empty(),
            vector::empty(),
            treasury_cap,
            coin_metadata,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify DAO was created successfully
        assert!(factory::dao_count(&factory) == 1, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = factory::EAlreadyDisabled)]
fun test_disable_twice_fails() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let owner_cap = ts::take_from_sender<factory::FactoryOwnerCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // First disable - should succeed
        factory::disable_permanently(&mut factory, &owner_cap, &clock, ts::ctx(&mut scenario));
        assert!(factory::is_permanently_disabled(&factory), 0);

        // Second disable - should fail with EAlreadyDisabled
        factory::disable_permanently(&mut factory, &owner_cap, &clock, ts::ctx(&mut scenario));

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, owner_cap);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}
