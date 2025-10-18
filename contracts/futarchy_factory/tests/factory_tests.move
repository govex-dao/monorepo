// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::factory_tests;

use futarchy_factory::factory;
use futarchy_factory::launchpad;
use futarchy_markets_core::fee;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

// === Test Coin Types ===

// OTW (One-Time Witness) types for coin creation - must have only `drop` ability
public struct TEST_ASSET has drop {}
public struct TEST_STABLE has drop {}

// Launchpad asset types - require `drop + store` which is incompatible with OTW
// These cannot use coin::create_currency since that requires a true OTW (only `drop`)
public struct TEST_ASSET_REGULAR has drop, store {}
public struct TEST_ASSET_REGULAR_2 has drop, store {}
public struct TEST_ASSET_REGULAR_3 has drop, store {}
public struct TEST_STABLE_REGULAR has drop, store {}
public struct UNALLOWED_STABLE has drop, store {}

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

    // Create a new DAO
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create payment for DAO creation (10_000 MIST = 0.00001 SUI)
        let payment = create_payment(10_000, &mut scenario);

        // Create DAO with test parameters
        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
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
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify DAO was created
        assert!(factory::dao_count(&factory) == 1, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
fun test_multiple_dao_creation() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Create first DAO
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
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
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(factory::dao_count(&factory) == 1, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    // Create second DAO
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        factory::create_dao_test<TEST_ASSET, TEST_STABLE_REGULAR>(
            &mut factory,
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
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(factory::dao_count(&factory) == 2, 1);

        clock::destroy_for_testing(clock);
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

    // Try to create DAO with TEST_STABLE (not added to factory - only TEST_STABLE_REGULAR was added)
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let payment = create_payment(10_000, &mut scenario);

        factory::create_dao_test<TEST_ASSET, TEST_STABLE>(
            &mut factory,
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
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

// === Launchpad Tests ===
// NOTE: These tests are disabled due to fundamental incompatibility:
// - coin::create_currency requires a type with ONLY `drop` ability (true OTW)
// - Launchpad type parameters require `drop + store` abilities
// - These constraints are mutually exclusive
//
// The Sui framework doesn't provide test utilities to create CoinMetadata without a proper OTW.
// To enable these tests, the launchpad would need to be refactored to not require `store` ability,
// or a different testing approach would be needed (e.g., integration tests with published modules).


#[test]
fun test_basic_launchpad_creation() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Create a launchpad raise
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create TreasuryCap for testing (metadata is now optional)
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));

        // Create payment for launchpad creation (10 SUI)
        let payment = create_payment(10_000_000_000, &mut scenario);

        // Setup 2D auction parameters
        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000); // 1 USDC per token
        vector::push_back(&mut allowed_prices, 2_000_000); // 2 USDC per token
        vector::push_back(&mut allowed_prices, 5_000_000); // 5 USDC per token

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 10_000_000_000); // 10k USDC
        vector::push_back(&mut allowed_total_raises, 50_000_000_000); // 50k USDC
        vector::push_back(&mut allowed_total_raises, 100_000_000_000); // 100k USDC

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(), // CoinMetadata is optional
            b"test-affiliate".to_string(), // affiliate_id
            option::some(1_000_000_000_000), // max_tokens_for_sale (1M tokens)
            10_000_000_000, // min_raise_amount (10k USDC)
            option::some(100_000_000_000), // max_raise_amount (100k USDC)
            allowed_prices,
            allowed_total_raises,
            true, // allow_early_completion
            b"Test launchpad raise for new token".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    // Verify raise was created
    ts::next_tx(&mut scenario, sender);
    {
        // Should have a CreatorCap transferred to sender
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        ts::return_to_sender(&scenario, creator_cap);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = launchpad::EStableTypeNotAllowed)]
fun test_launchpad_with_unallowed_stable() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create treasury cap for testing (metadata is now optional)
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR_2>(ts::ctx(&mut scenario));

        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 10_000_000_000);

        // This should fail because UNALLOWED_STABLE is not in the factory's allowed list
        launchpad::create_raise_2d<TEST_ASSET_REGULAR_2, UNALLOWED_STABLE>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(), // CoinMetadata is optional
            b"test".to_string(),
            option::some(1_000_000_000_000),
            10_000_000_000,
            option::some(100_000_000_000),
            allowed_prices,
            allowed_total_raises,
            true,
            b"Should fail".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    ts::end(scenario);
}

#[test]
fun test_launchpad_bid_placement() {
    let sender = @0xA;
    let bidder = @0xB;
    let mut scenario = setup_test(sender);

    // Step 1: Create a launchpad raise
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create treasury cap for testing (metadata is now optional)
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR_3>(ts::ctx(&mut scenario));

        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000);
        vector::push_back(&mut allowed_prices, 2_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 10_000_000_000);
        vector::push_back(&mut allowed_total_raises, 100_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(), // CoinMetadata is optional
            b"test-affiliate".to_string(),
            option::some(1_000_000_000_000),
            10_000_000_000,
            option::some(100_000_000_000),
            allowed_prices,
            allowed_total_raises,
            true,
            b"Test launchpad for bid placement".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(fee_manager);
        ts::return_shared(factory);
    };

    // Step 2: Get raise and lock intents
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);

        launchpad::lock_intents_and_start_raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise,
            &creator_cap,
            ts::ctx(&mut scenario)
        );

        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Step 3: Place a bid
    ts::next_tx(&mut scenario, bidder);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Bid payment: 2 USDC per token * 1000 tokens = 2000 USDC
        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(2_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            2_000_000, // price_cap: 2 USDC (with 6 decimals)
            1_000, // min_tokens: 1000 tokens (base units, not micro units)
            10_000_000_000, // min_total_raise: 10k USDC
            100_000_000_000, // max_total_raise: 100k USDC
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify contributor count increased
        assert!(launchpad::contributor_count(&raise) == 1, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    ts::end(scenario);
}


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

    // Try to create a DAO - this should fail with EPermanentlyDisabled
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let payment = create_payment(100_000_000, &mut scenario);

        factory::create_dao_test<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut factory,
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
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
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
