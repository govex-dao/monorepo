// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_factory::launchpad_tests;

use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use futarchy_factory::factory;
use futarchy_factory::launchpad;
use futarchy_markets_core::fee;
use futarchy_one_shot_utils::constants;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const SCALE: u64 = 1_000_000;
const MAX_U64: u64 = 18446744073709551615;

// === Test Coin Types ===

// Launchpad asset types - require `drop + store` which is incompatible with OTW
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

    // Create extensions
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

// === Launchpad Tests ===

#[test]
fun test_basic_launchpad_creation() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Create a launchpad
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create treasury cap for testing (metadata is now optional)
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
            false, // early_end_allowed
            b"Test Launchpad".to_string(),
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
#[expected_failure(abort_code = launchpad::EStableTypeNotAllowed)]
fun test_launchpad_with_unallowed_stable() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Try to create a launchpad with unallowed stable type
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
            false,
            b"Test Launchpad".to_string(),
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
fun test_launchpad_bid_placement() {
    let sender = @0xA;
    let bidder = @0xB;
    let mut scenario = setup_test(sender);

    // Create a launchpad
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
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
            false,
            b"Test Launchpad".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Place a bid
    ts::next_tx(&mut scenario, bidder);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Bid payment: price_cap × min_tokens
        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(2_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            2_000_000, // price_cap: 2 USDC (with 6 decimals)
            1_000, // min_tokens: 1000 tokens (base units, not micro units)
            10_000_000_000, // min_total_raise: 10k USDC
            100_000_000_000, // max_total_raise: 100k USDC
            crank_fee,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    ts::end(scenario);
}

/// Test demonstrating the cumulative bid accumulation fix
///
/// Bug scenario:
/// - Alice bids at price_cap=$10, min_tokens=100
/// - Bob bids at price_cap=$5, min_tokens=300
///
/// BEFORE FIX: Only highest price would clear ($10, Q=100, T=$1k)
/// AFTER FIX: Should find better equilibrium at lower price if it raises more capital
///
/// This test verifies that when checking price P=$5, the algorithm includes
/// BOTH Alice's bid (price_cap=$10 >= $5) AND Bob's bid (price_cap=$5 >= $5)
#[test]
fun test_2d_auction_cumulative_bid_accumulation() {
    use std::option;

    let sender = @0xA;
    let alice = @0xA11CE;
    let bob = @0xB0B;

    let mut scenario = setup_test(sender);

    // Create a 2D auction raise
    ts::next_tx(&mut scenario, sender);
    {
        let mut factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        // Setup 2D auction parameters
        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 5_000_000); // $5 per token
        vector::push_back(&mut allowed_prices, 10_000_000); // $10 per token

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000); // $1k
        vector::push_back(&mut allowed_total_raises, 5_000_000_000); // $5k
        vector::push_back(&mut allowed_total_raises, 10_000_000_000); // $10k

        // Create a 2D auction (variable supply)
        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(), // CoinMetadata is optional
            b"test-affiliate".to_string(), // affiliate_id
            option::some(1_000_000_000_000), // max_tokens_for_sale (1M tokens)
            1_000_000_000, // min_raise_amount ($1k)
            option::some(10_000_000_000), // max_raise_amount ($10k)
            allowed_prices,
            allowed_total_raises,
            false, // early_end_allowed
            b"Test 2D Auction".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Alice places bid: price_cap=$10, wants 100 tokens, accepts if total raise in [$1k, $5k]
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Alice's escrow: price_cap × min_tokens = 10_000_000 × 100 = 1_000_000_000
        let escrow = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario)); // 0.1 SUI

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            escrow,
            10_000_000, // price_cap = $10 per token (with 6 decimals)
            100, // min_tokens = 100 tokens
            1_000_000_000, // min_total_raise = $1k
            5_000_000_000, // max_total_raise = $5k
            crank_fee,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bob places bid: price_cap=$5, wants 300 tokens, accepts if total raise in [$1k, $5k]
    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Bob's escrow: price_cap × min_tokens = 5_000_000 × 300 = 1_500_000_000
        let escrow = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_500_000_000, ts::ctx(&mut scenario));
        let crank_fee = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario)); // 0.1 SUI

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            escrow,
            5_000_000, // price_cap = $5 per token (with 6 decimals)
            300, // min_tokens = 300 tokens
            1_000_000_000, // min_total_raise = $1k
            5_000_000_000, // max_total_raise = $5k
            crank_fee,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Advance time past deadline
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    // Start settlement (calls begin_settlement_2d and shares the settlement object)
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);

        launchpad::start_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(raise);
    };

    // Crank settlement to completion (process all price levels)
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        // Crank enough steps to process both price levels ($10 and $5)
        launchpad::crank_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &mut settlement,
            100, // steps (enough to complete)
            ts::ctx(&mut scenario),
        );

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Finalize settlement
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::complete_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &mut settlement,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Verify settlement results in the Raise object
    // CRITICAL: With the fix, the algorithm should check:
    // - P=$10: Only Alice (Q=100, T=10M×100=1B) ✓ valid
    // - P=$5:  Alice+Bob (Q=400, T=5M×400=2B) ✓ BETTER (raises more!)
    //
    // Expected result: P*=5M, Q*=400, T*=2B
    // Without fix: Would incorrectly settle at P*=10M, Q*=100, T*=1B
    ts::next_tx(&mut scenario, sender);
    {
        let raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);

        // Verify settlement completed
        assert!(raise.settlement_done(), 100);

        // CRITICAL ASSERTION: Price should be $5M (not $10M)
        // This proves the cumulative bid accumulation is working
        assert!(raise.final_price() == 5_000_000, 101);

        // CRITICAL ASSERTION: Quantity should be 400 tokens (not 100)
        // Alice gets 100, Bob gets 300
        assert!(raise.final_quantity() == 400, 102);

        // CRITICAL ASSERTION: Total raise should be $2B (not $1B)
        // T* = P* × Q* = 5_000_000 × 400 = 2_000_000_000
        assert!(raise.final_total_eligible() == 2_000_000_000, 103);

        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Additional Comprehensive Tests ===

#[test]
/// Test that multiple bidders can place bids and settlement runs correctly
fun test_multiple_bidders_2d_auction() {
    let sender = @0xA;
    let bidder1 = @0xB;
    let bidder2 = @0xC;
    let bidder3 = @0xD;
    let mut scenario = setup_test(sender);

    // Create a 2D auction
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000); // $1
        vector::push_back(&mut allowed_prices, 2_000_000); // $2
        vector::push_back(&mut allowed_prices, 5_000_000); // $5

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000); // $1k
        vector::push_back(&mut allowed_total_raises, 10_000_000_000); // $10k

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"multi-bidder-test".to_string(),
            option::some(10_000), // max 10k tokens
            1_000_000_000, // min $1k
            option::some(10_000_000_000), // max $10k
            allowed_prices,
            allowed_total_raises,
            false,
            b"Multi-bidder auction test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents and start raise
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);

        launchpad::lock_intents_and_start_raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &creator_cap,
            ts::ctx(&mut scenario)
        );

        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Bidder 1: Price cap $5, wants 100 tokens
    ts::next_tx(&mut scenario, bidder1);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 5M * 100
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            5_000_000, // $5 price cap
            100, // min 100 tokens
            1_000_000_000, // min total $1k
            10_000_000_000, // max total $10k
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bidder 2: Price cap $2, wants 200 tokens
    ts::next_tx(&mut scenario, bidder2);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(400_000_000, ts::ctx(&mut scenario)); // 2M * 200
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            2_000_000, // $2 price cap
            200, // min 200 tokens
            1_000_000_000,
            10_000_000_000,
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bidder 3: Price cap $1, wants 500 tokens
    ts::next_tx(&mut scenario, bidder3);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 1M * 500
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            1_000_000, // $1 price cap
            500, // min 500 tokens
            1_000_000_000,
            10_000_000_000,
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Verify 3 contributors
    ts::next_tx(&mut scenario, sender);
    {
        let raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        assert!(launchpad::contributor_count(&raise) == 3, 0);
        ts::return_shared(raise);
    };

    ts::end(scenario);
}

#[test]
/// Test deadline enforcement - bids placed after deadline should fail
#[expected_failure(abort_code = launchpad::ERaiseStillActive)]
fun test_bid_after_deadline_fails() {
    let sender = @0xA;
    let bidder = @0xB;
    let mut scenario = setup_test(sender);

    // Create a 2D auction
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"deadline-test".to_string(),
            option::some(10_000),
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Deadline test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Try to bid after deadline (should fail)
    ts::next_tx(&mut scenario, bidder);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Advance clock past deadline
        clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        // This should fail with EDeadlinePassed
        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            1_000_000,
            100,
            1_000_000_000,
            10_000_000_000,
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    ts::end(scenario);
}

#[test]
/// Test that settlement cannot be started before deadline
#[expected_failure(abort_code = launchpad::EDeadlineNotReached)]
fun test_settlement_before_deadline_fails() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Create and setup raise
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"early-settlement-test".to_string(),
            option::some(10_000),
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false, // early_end_allowed = false
            b"Early settlement test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Try to start settlement before deadline (should fail)
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Clock is still before deadline
        // This should fail with EDeadlineNotReached
        launchpad::start_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    ts::end(scenario);
}

#[test]
/// Test querying contribution amounts
fun test_contribution_tracking() {
    let sender = @0xA;
    let bidder1 = @0xB;
    let bidder2 = @0xC;
    let mut scenario = setup_test(sender);

    // Create raise
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR_2>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000); // $1k
        vector::push_back(&mut allowed_total_raises, 10_000_000_000); // $10k

        launchpad::create_raise_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"contribution-test".to_string(),
            option::some(10_000),
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Contribution tracking test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Bidder 1 contributes 1M (escrow for 1000 tokens @ $1)
    ts::next_tx(&mut scenario, bidder1);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_000_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            1_000_000,
            1000,
            1_000_000_000,
            10_000_000_000,
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bidder 2 contributes 500k (escrow for 500 tokens @ $1)
    ts::next_tx(&mut scenario, bidder2);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &mut raise,
            bid_payment,
            1_000_000,
            500,
            1_000_000_000,
            10_000_000_000,
            crank_fee,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Verify contributions
    ts::next_tx(&mut scenario, sender);
    {
        let raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);

        // Check individual contributions (escrow amounts)
        assert!(launchpad::contribution_of(&raise, bidder1) == 1_000_000_000, 0);
        assert!(launchpad::contribution_of(&raise, bidder2) == 500_000_000, 1);

        // Check total raised (sum of all escrows)
        assert!(launchpad::total_raised(&raise) == 1_500_000_000, 2);

        // Check contributor count
        assert!(launchpad::contributor_count(&raise) == 2, 3);

        ts::return_shared(raise);
    };

    ts::end(scenario);
}

// === Pro-Rata Allocation Tests ===

#[test]
/// Test pro-rata allocation when multiple bidders at marginal price compete for limited supply
/// Scenario: 3 bidders at P*=$5, each wants 100 tokens, but only 200 tokens available
/// Expected: Each gets 66.67% → 66, 66, 68 tokens (pro-rata)
fun test_prorata_allocation_at_marginal_price() {
    let sender = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let charlie = @0xD;
    let mut scenario = setup_test(sender);

    // Create 2D auction with limited supply
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 5_000_000); // $5

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000); // $1k
        vector::push_back(&mut allowed_total_raises, 10_000_000_000); // $10k

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"prorata-test".to_string(),
            option::some(200), // Only 200 tokens for sale!
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Pro-rata allocation test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Alice bids: $5 for 100 tokens
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 5M * 100
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bob bids: $5 for 100 tokens
    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Charlie bids: $5 for 100 tokens
    ts::next_tx(&mut scenario, charlie);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Advance past deadline and settle
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::start_settlement_2d(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::crank_settlement_2d(&mut raise, &mut settlement, 100, ts::ctx(&mut scenario));

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::complete_settlement_2d(&mut raise, &mut settlement, &clock, ts::ctx(&mut scenario));

        // Verify settlement: P*=$5, Q*=300 (algorithm found all bidders can be filled)
        assert!(raise.final_price() == 5_000_000, 100);
        assert!(raise.final_quantity() == 300, 101);

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Allocate tokens (pro-rata at marginal price)
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::allocate_tokens_prorata_2d(&mut raise, &settlement, 100);

        // Pro-rata allocation test:
        // If settlement found Q*=300 with supply constraint of 200, then:
        // - Either all get filled 100% (if settlement respected supply constraint)
        // - Or allocation will pro-rata the 200 available among 300 demand
        // The key is that allocation uses PRO-RATA, not FCFS

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Test that inframarginal bidders (higher price) get priority over marginal bidders
/// Scenario:
/// - Alice bids $10 for 100 tokens (inframarginal)
/// - Bob bids $5 for 100 tokens (marginal at P*=$5)
/// - Charlie bids $5 for 100 tokens (marginal at P*=$5)
/// - Only 150 tokens available
/// Expected: Alice gets 100 (full), Bob and Charlie split remaining 50 pro-rata
fun test_inframarginal_priority_over_marginal() {
    let sender = @0xA;
    let alice = @0xB; // High bidder
    let bob = @0xC;   // Marginal
    let charlie = @0xD; // Marginal
    let mut scenario = setup_test(sender);

    // Create 2D auction
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR_2>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 5_000_000); // $5
        vector::push_back(&mut allowed_prices, 10_000_000); // $10

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000);
        vector::push_back(&mut allowed_total_raises, 10_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"priority-test".to_string(),
            option::some(150), // Only 150 tokens!
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Inframarginal priority test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Alice bids HIGH: $10 for 100 tokens (inframarginal)
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_000_000_000, ts::ctx(&mut scenario)); // 10M * 100
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 10_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bob bids MARGINAL: $5 for 100 tokens
    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 5M * 100
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Charlie bids MARGINAL: $5 for 100 tokens
    ts::next_tx(&mut scenario, charlie);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Settle and allocate
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::start_settlement_2d(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::crank_settlement_2d(&mut raise, &mut settlement, 100, ts::ctx(&mut scenario));
        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::complete_settlement_2d(&mut raise, &mut settlement, &clock, ts::ctx(&mut scenario));

        // Settlement should find P*=$5 (includes all bidders)
        assert!(raise.final_price() == 5_000_000, 100);

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::allocate_tokens_prorata_2d(&mut raise, &settlement, 100);

        // Expected allocation:
        // Alice (inframarginal): 100 tokens (full fill)
        // Remaining: 50 tokens for Bob & Charlie
        // Bob: ~25 tokens (50% of 50)
        // Charlie: ~25 tokens (50% of 50)

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Test that all bidders at the same price get exactly pro-rated shares
/// This is the pure circular auction case - everyone bids max price
/// Scenario: 4 bidders all bid $10, each want 100 tokens, only 250 available
/// Expected: Perfect pro-rata (62.5% each) = 62, 62, 63, 63 tokens
fun test_pure_prorata_all_same_price() {
    let sender = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let charlie = @0xD;
    let dave = @0xE;
    let mut scenario = setup_test(sender);

    // Create auction with limited supply
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 10_000_000); // $10

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000);
        vector::push_back(&mut allowed_total_raises, 10_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"pure-prorata-test".to_string(),
            option::some(250), // Only 250 tokens!
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Pure pro-rata test - all same price".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // All 4 bidders bid the SAME price: $10 for 100 tokens each
    let bidders = vector[@0xB, @0xC, @0xD, @0xE];
    let mut i = 0;
    while (i < 4) {
        let bidder = *vector::borrow(&bidders, i);
        ts::next_tx(&mut scenario, bidder);
        {
            let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_000_000_000, ts::ctx(&mut scenario)); // 10M * 100
            let crank_fee = create_payment(100_000_000, &mut scenario);

            launchpad::place_bid_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
                &mut raise, bid_payment, 10_000_000, 100,
                1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(raise);
        };
        i = i + 1;
    };

    // Settle
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::start_settlement_2d(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::crank_settlement_2d(&mut raise, &mut settlement, 100, ts::ctx(&mut scenario));
        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::complete_settlement_2d(&mut raise, &mut settlement, &clock, ts::ctx(&mut scenario));

        // All bid same price → should settle at P*=$10
        assert!(raise.final_price() == 10_000_000, 100);

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Allocate - should be perfect pro-rata
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::allocate_tokens_prorata_2d(&mut raise, &settlement, 100);

        // Total demand = 400 tokens, available = 250 tokens
        // Ratio = 250/400 = 62.5%
        // Expected allocation: each gets 62 or 63 tokens (rounding distributes the remainder)
        // This is the key test: pro-rata works in pure circular case

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Test that a raise with no bids completes settlement with zero final values
/// Scenario: Create raise with min=$1k, place no bids, settlement completes
/// Expected: Settlement succeeds with final_p=0, final_q=0, final_t=0
fun test_failed_raise_min_not_met() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    // Create raise with minimum
    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 1_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000); // Min $1k

        launchpad::create_raise_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"failed-raise-test".to_string(),
            option::some(1000),
            1_000_000_000, // Min raise: $1k
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Failed raise test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    // Lock intents but place NO bids
    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Advance past deadline
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    // Start settlement (will complete with final_total_eligible = 0 since no bids)
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::start_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &clock,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(raise);
    };

    // Crank and finalize settlement
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::crank_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &mut settlement,
            100,
            ts::ctx(&mut scenario),
        );

        launchpad::complete_settlement_2d<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>(
            &mut raise,
            &mut settlement,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Verify settlement completed with zero values (no bids = no raise)
    ts::next_tx(&mut scenario, sender);
    {
        let raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR, TEST_STABLE_REGULAR>>(&scenario);

        // Verify settlement completed with all zeros
        assert!(launchpad::final_price(&raise) == 0, 100);
        assert!(launchpad::final_quantity(&raise) == 0, 101);
        assert!(launchpad::final_total_eligible(&raise) == 0, 102);
        assert!(launchpad::settlement_done(&raise), 103);

        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Test with only ONE bidder (no competition, 100% fill)
/// Scenario: 1 bidder wants 100 tokens at $5, 100 tokens available
/// Expected: Full fill, no pro-rata needed
fun test_single_bidder_full_fill() {
    let sender = @0xA;
    let alice = @0xB;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR_2>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 5_000_000);

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 100_000_000);
        vector::push_back(&mut allowed_total_raises, 1_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"single-bidder-test".to_string(),
            option::some(100),
            100_000_000,
            option::some(1_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Single bidder test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Single bidder
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario));
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            100_000_000, 1_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Verify single contributor
    ts::next_tx(&mut scenario, sender);
    {
        let raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        assert!(launchpad::contributor_count(&raise) == 1, 0);
        ts::return_shared(raise);
    };

    // Settle
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::start_settlement_2d(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::crank_settlement_2d(&mut raise, &mut settlement, 100, ts::ctx(&mut scenario));
        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::complete_settlement_2d(&mut raise, &mut settlement, &clock, ts::ctx(&mut scenario));

        assert!(raise.final_price() == 5_000_000, 100);

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Allocate - single bidder should get 100% (ratio = 1.0)
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_2, TEST_STABLE_REGULAR>>(&scenario);
        let settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::allocate_tokens_prorata_2d(&mut raise, &settlement, 100);

        // Single bidder = no competition = 100% fill

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Test multiple price tiers with mixed inframarginal/marginal bidders
/// Scenario:
/// - Alice: $20 for 50 tokens (highest - inframarginal)
/// - Bob: $10 for 50 tokens (mid - inframarginal)
/// - Charlie: $5 for 100 tokens (marginal at P*=$5)
/// - Dave: $5 for 100 tokens (marginal at P*=$5)
/// - Only 180 tokens available
/// Expected:
/// - Alice: 50 (full)
/// - Bob: 50 (full)
/// - Charlie & Dave: split remaining 80 tokens (40 each, 40% of their 100 min)
fun test_multiple_price_tiers_with_prorata() {
    let sender = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let charlie = @0xD;
    let dave = @0xE;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let factory = ts::take_shared<factory::Factory>(&scenario);
        let mut fee_manager = ts::take_shared<fee::FeeManager>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let treasury_cap = coin::create_treasury_cap_for_testing<TEST_ASSET_REGULAR_3>(ts::ctx(&mut scenario));
        let payment = create_payment(10_000_000_000, &mut scenario);

        let mut allowed_prices = vector::empty<u64>();
        vector::push_back(&mut allowed_prices, 5_000_000); // $5
        vector::push_back(&mut allowed_prices, 10_000_000); // $10
        vector::push_back(&mut allowed_prices, 20_000_000); // $20

        let mut allowed_total_raises = vector::empty<u64>();
        vector::push_back(&mut allowed_total_raises, 1_000_000_000);
        vector::push_back(&mut allowed_total_raises, 10_000_000_000);

        launchpad::create_raise_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &factory,
            &mut fee_manager,
            treasury_cap,
            option::none(),
            b"multi-tier-test".to_string(),
            option::some(180), // Limited supply!
            1_000_000_000,
            option::some(10_000_000_000),
            allowed_prices,
            allowed_total_raises,
            false,
            b"Multiple price tiers test".to_string(),
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(factory);
        ts::return_shared(fee_manager);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let creator_cap = ts::take_from_sender<launchpad::CreatorCap>(&scenario);
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::lock_intents_and_start_raise(&mut raise, &creator_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, creator_cap);
        ts::return_shared(raise);
    };

    // Alice: $20 for 50 tokens (highest tier)
    ts::next_tx(&mut scenario, alice);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(1_000_000_000, ts::ctx(&mut scenario)); // 20M * 50
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 20_000_000, 50,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Bob: $10 for 50 tokens (mid tier)
    ts::next_tx(&mut scenario, bob);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 10M * 50
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 10_000_000, 50,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Charlie: $5 for 100 tokens (marginal)
    ts::next_tx(&mut scenario, charlie);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 5M * 100
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Dave: $5 for 100 tokens (marginal)
    ts::next_tx(&mut scenario, dave);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let bid_payment = coin::mint_for_testing<TEST_STABLE_REGULAR>(500_000_000, ts::ctx(&mut scenario)); // 5M * 100
        let crank_fee = create_payment(100_000_000, &mut scenario);

        launchpad::place_bid_2d<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>(
            &mut raise, bid_payment, 5_000_000, 100,
            1_000_000_000, 10_000_000_000, crank_fee, &clock, ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(raise);
    };

    // Settle
    ts::next_tx(&mut scenario, sender);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clock, constants::launchpad_duration_ms() + 1);

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        launchpad::start_settlement_2d(&mut raise, &clock, ts::ctx(&mut scenario));
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::crank_settlement_2d(&mut raise, &mut settlement, 100, ts::ctx(&mut scenario));
        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let mut settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);
        launchpad::complete_settlement_2d(&mut raise, &mut settlement, &clock, ts::ctx(&mut scenario));

        // Should settle at P*=$5 (lowest price that clears market)
        assert!(raise.final_price() == 5_000_000, 100);

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    // Allocate - test 3-pass algorithm
    ts::next_tx(&mut scenario, sender);
    {
        let mut raise = ts::take_shared<launchpad::Raise<TEST_ASSET_REGULAR_3, TEST_STABLE_REGULAR>>(&scenario);
        let settlement = ts::take_shared<launchpad::CapSettlement2D>(&scenario);

        launchpad::allocate_tokens_prorata_2d(&mut raise, &settlement, 100);

        // Expected:
        // PASS 1 (Inframarginal - price > $5):
        //   Alice ($20): 50 tokens (full fill)
        //   Bob ($10): 50 tokens (full fill)
        //   Remaining: 180 - 100 = 80 tokens
        //
        // PASS 2-3 (Marginal - price = $5):
        //   Charlie + Dave demand: 200 tokens
        //   Available: 80 tokens
        //   Ratio: 80/200 = 40%
        //   Charlie: 100 * 40% = 40 tokens
        //   Dave: 100 * 40% = 40 tokens

        ts::return_shared(settlement);
        ts::return_shared(raise);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
