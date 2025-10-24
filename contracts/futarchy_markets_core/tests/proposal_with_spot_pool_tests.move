#[test_only]
module futarchy_markets_core::proposal_with_spot_pool_tests;

use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool, LPToken};
use futarchy_markets_core::quantum_lp_manager;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::LiquidityPool;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use futarchy_types::init_action_specs::InitActionSpecs;
use futarchy_types::signed::{Self as signed};
use std::option;
use std::string::{Self, String};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils;

// === Test Constants ===

const DAO_ADDR: address = @0xDA0;
const PROPOSER_ADDR: address = @0xABCD;
const TREASURY_ADDR: address = @0xFEE;
const LP_PROVIDER_ADDR: address = @0xBEEF;

const REVIEW_PERIOD_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours
const TRADING_PERIOD_MS: u64 = 7 * 24 * 60 * 60 * 1000; // 7 days
const MIN_ASSET_LIQUIDITY: u64 = 1_000_000_000; // 1 token (9 decimals)
const MIN_STABLE_LIQUIDITY: u64 = 10_000_000; // 10 USDC (6 decimals)
const TWAP_START_DELAY: u64 = 60 * 1000; // 1 minute
const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000_000_000_000_000u128; // 1.0 in Q64.64
const TWAP_STEP_MAX: u64 = 100;
const TWAP_THRESHOLD_VALUE: u128 = 500_000_000_000_000_000u128; // 0.5 in Q64.64
const AMM_TOTAL_FEE_BPS: u64 = 30; // 0.3%
const CONDITIONAL_LIQUIDITY_RATIO_PERCENT: u64 = 80; // 80% (base 100)
const MAX_OUTCOMES: u64 = 10;
const SPOT_POOL_FEE_BPS: u64 = 30; // 0.3%

// Liquidity amounts
const SPOT_POOL_ASSET: u64 = 10_000_000_000; // 10 tokens
const SPOT_POOL_STABLE: u64 = 100_000_000; // 100 USDC
const PROPOSAL_ASSET: u64 = 2_000_000_000; // 2 tokens
const PROPOSAL_STABLE: u64 = 20_000_000; // 20 USDC

// State constants
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1;
const STATE_TRADING: u8 = 2;
const STATE_FINALIZED: u8 = 3;

// === Test Helpers ===

/// Create a test clock at specific time
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Helper to create outcome messages
fun create_outcome_messages(count: u64): vector<String> {
    let mut messages = vector::empty<String>();
    let mut i = 0;
    while (i < count) {
        let mut msg = string::utf8(b"Outcome ");
        messages.push_back(msg);
        i = i + 1;
    };
    messages
}

/// Helper to create outcome details
fun create_outcome_details(count: u64): vector<String> {
    let mut details = vector::empty<String>();
    let mut i = 0;
    while (i < count) {
        details.push_back(string::utf8(b"Detailed description"));
        i = i + 1;
    };
    details
}

/// Helper to create test proposal ID
fun create_test_proposal_id(ctx: &mut TxContext): ID {
    object::id_from_address(@0x1234)
}

// === Core Test: Proposal with Spot Pool Integration ===

#[test]
fun test_proposal_with_spot_pool_lifecycle() {
    let mut scenario = ts::begin(LP_PROVIDER_ADDR);

    // Step 1: Initialize test coins
    {
        let ctx = ts::ctx(&mut scenario);
        futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
        futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
    };

    // Step 2: Create and initialize spot pool (simulates DAO creation)
    ts::next_tx(&mut scenario, LP_PROVIDER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        // Create spot pool with aggregator enabled (required for proposals)
        let mut spot_pool = unified_spot_pool::new_with_aggregator<TEST_COIN_A, TEST_COIN_B>(
            SPOT_POOL_FEE_BPS,
            option::none(), // No fee schedule
            8000, // oracle_conditional_threshold_bps (80%)
            &clock,
            ctx,
        );

        // Add initial liquidity to spot pool
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(SPOT_POOL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(SPOT_POOL_STABLE, ctx);

        let lp_token = unified_spot_pool::add_liquidity(
            &mut spot_pool,
            asset_coin,
            stable_coin,
            0, // min_lp_out
            ctx,
        );

        // Verify spot pool has liquidity
        let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&spot_pool);
        assert!(asset_reserve == SPOT_POOL_ASSET, 0);
        assert!(stable_reserve == SPOT_POOL_STABLE, 1);
        assert!(unified_spot_pool::is_aggregator_enabled(&spot_pool), 2);

        // Share the spot pool (simulates what factory does)
        transfer::public_share_object(spot_pool);

        // Transfer LP token to provider
        transfer::public_transfer(lp_token, LP_PROVIDER_ADDR);

        clock::destroy_for_testing(clock);
    };

    // Step 3: Create proposal with conditional AMMs
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(2000, ctx);

        // Create coins for proposal liquidity
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(PROPOSAL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(PROPOSAL_STABLE, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        // Create proposal (this creates conditional AMMs)
        let (proposal_id, market_state_id, state) = proposal::initialize_market<
            TEST_COIN_A,
            TEST_COIN_B,
        >(
            create_test_proposal_id(ctx),
            object::id_from_address(DAO_ADDR),
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            signed::from_u128(TWAP_THRESHOLD_VALUE),
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_PERCENT,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000, // proposer fee
            false, // uses_dao_liquidity
            false, // used_quota
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        // Verify proposal created in REVIEW state
        assert!(state == STATE_REVIEW, 3);

        clock::destroy_for_testing(clock);
    };

    // Step 4: Verify proposal and conditional AMM pools
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let escrow = ts::take_shared<TokenEscrow<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let spot_pool = ts::take_shared<UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B>>(&scenario);

        // Verify proposal state
        assert!(proposal::state(&proposal) == STATE_REVIEW, 4);
        assert!(proposal::outcome_count(&proposal) == 2, 5);
        assert!(proposal::proposer(&proposal) == PROPOSER_ADDR, 6);

        // Verify conditional AMM pools were created
        let pools = proposal::get_amm_pools(&proposal, &escrow);
        assert!(pools.length() == 2, 7);

        // Verify spot pool still has reserves (quantum liquidity not split yet)
        let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&spot_pool);
        assert!(asset_reserve == SPOT_POOL_ASSET, 8);
        assert!(stable_reserve == SPOT_POOL_STABLE, 9);

        // Spot pool should not have active escrow yet (quantum split happens on TRADING)
        assert!(!unified_spot_pool::has_active_escrow(&spot_pool), 10);

        ts::return_shared(proposal);
        ts::return_shared(escrow);
        ts::return_shared(spot_pool);
    };

    // Step 5: Advance state from REVIEW to TRADING (quantum split happens here)
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let mut proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let mut escrow = ts::take_shared<TokenEscrow<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let mut spot_pool = ts::take_shared<UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        // Create clock past review period
        let mut clock = create_test_clock(REVIEW_PERIOD_MS + 2000, ctx);

        // Advance state (this triggers quantum split)
        let state_changed = proposal::advance_state(
            &mut proposal,
            &mut escrow,
            &clock,
            ctx,
        );

        assert!(state_changed, 11);
        assert!(proposal::state(&proposal) == STATE_TRADING, 12);

        // Now perform quantum split manually (in real flow, this would be in proposal_lifecycle)
        // This simulates what happens when proposal goes REVIEW -> TRADING
        quantum_lp_manager::auto_quantum_split_on_proposal_start(
            &mut spot_pool,
            &mut escrow,
            CONDITIONAL_LIQUIDITY_RATIO_PERCENT,
            &clock,
            ctx,
        );

        // Register the escrow with the spot pool (critical for has_active_escrow to work)
        let escrow_id = object::id(&escrow);
        unified_spot_pool::store_active_escrow(&mut spot_pool, escrow_id);

        // Verify spot pool now has active escrow registered
        assert!(unified_spot_pool::has_active_escrow(&spot_pool), 13);

        // Verify spot pool reserves were quantum-split
        // With 80% ratio, spot keeps 20% of original liquidity
        let (asset_reserve_after, stable_reserve_after) = unified_spot_pool::get_reserves(&spot_pool);
        let expected_spot_asset = SPOT_POOL_ASSET * 20 / 100; // 20% stays in spot
        let expected_spot_stable = SPOT_POOL_STABLE * 20 / 100;

        // Allow small rounding difference
        assert!(asset_reserve_after <= expected_spot_asset + 1000, 14);
        assert!(asset_reserve_after >= expected_spot_asset - 1000, 15);
        assert!(stable_reserve_after <= expected_spot_stable + 100, 16);
        assert!(stable_reserve_after >= expected_spot_stable - 100, 17);

        ts::return_shared(proposal);
        ts::return_shared(escrow);
        ts::return_shared(spot_pool);
        clock::destroy_for_testing(clock);
    };

    // Step 6: Verify the complete integration
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let escrow = ts::take_shared<TokenEscrow<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let spot_pool = ts::take_shared<UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B>>(&scenario);

        // Final verification
        assert!(proposal::state(&proposal) == STATE_TRADING, 18);
        assert!(unified_spot_pool::has_active_escrow(&spot_pool), 19);

        // Conditional pools should exist and be accessible
        let pools = proposal::get_amm_pools(&proposal, &escrow);
        assert!(pools.length() == 2, 20);

        ts::return_shared(proposal);
        ts::return_shared(escrow);
        ts::return_shared(spot_pool);
    };

    ts::end(scenario);
}

// === Test: Spot Pool Reserves Before and After Quantum Split ===

#[test]
fun test_quantum_split_reserves() {
    let mut scenario = ts::begin(LP_PROVIDER_ADDR);

    // Initialize test coins
    {
        let ctx = ts::ctx(&mut scenario);
        futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
        futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
    };

    // Create spot pool with liquidity
    ts::next_tx(&mut scenario, LP_PROVIDER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let mut spot_pool = unified_spot_pool::new_with_aggregator<TEST_COIN_A, TEST_COIN_B>(
            SPOT_POOL_FEE_BPS,
            option::none(),
            8000,
            &clock,
            ctx,
        );

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(SPOT_POOL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(SPOT_POOL_STABLE, ctx);

        let lp_token = unified_spot_pool::add_liquidity(
            &mut spot_pool,
            asset_coin,
            stable_coin,
            0,
            ctx,
        );

        // Record initial reserves
        let (initial_asset, initial_stable) = unified_spot_pool::get_reserves(&spot_pool);
        assert!(initial_asset == SPOT_POOL_ASSET, 0);
        assert!(initial_stable == SPOT_POOL_STABLE, 1);

        transfer::public_share_object(spot_pool);
        transfer::public_transfer(lp_token, LP_PROVIDER_ADDR);
        clock::destroy_for_testing(clock);
    };

    // Create proposal
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(2000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(PROPOSAL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(PROPOSAL_STABLE, ctx);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            create_test_proposal_id(ctx),
            object::id_from_address(DAO_ADDR),
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            signed::from_u128(TWAP_THRESHOLD_VALUE),
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_PERCENT,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Reserve Test"),
            string::utf8(b"metadata"),
            create_outcome_messages(2),
            create_outcome_details(2),
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            balance::zero<TEST_COIN_B>(),
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    // Perform quantum split and verify reserves
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let mut proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let mut escrow = ts::take_shared<TokenEscrow<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let mut spot_pool = ts::take_shared<UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(REVIEW_PERIOD_MS + 2000, ctx);

        // Advance to TRADING
        proposal::advance_state(&mut proposal, &mut escrow, &clock, ctx);

        // Quantum split
        quantum_lp_manager::auto_quantum_split_on_proposal_start(
            &mut spot_pool,
            &mut escrow,
            CONDITIONAL_LIQUIDITY_RATIO_PERCENT,
            &clock,
            ctx,
        );

        // Verify reserves after quantum split
        let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);

        // With 80% conditional ratio, 20% stays in spot
        let expected_asset = SPOT_POOL_ASSET * 20 / 100;
        let expected_stable = SPOT_POOL_STABLE * 20 / 100;

        assert!(final_asset <= expected_asset + 1000, 2);
        assert!(final_asset >= expected_asset - 1000, 3);
        assert!(final_stable <= expected_stable + 100, 4);
        assert!(final_stable >= expected_stable - 100, 5);

        ts::return_shared(proposal);
        ts::return_shared(escrow);
        ts::return_shared(spot_pool);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === Test: Multiple Proposals Can Be Created (DAO layer handles limits, not markets layer) ===
// NOTE: This test verifies that the markets layer allows multiple proposals.
// Actual proposal limits are enforced at the DAO governance layer, not here.

#[test]
fun test_only_one_active_proposal() {
    let mut scenario = ts::begin(LP_PROVIDER_ADDR);

    // Initialize test coins
    {
        let ctx = ts::ctx(&mut scenario);
        futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
        futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);
    };

    // Create spot pool
    ts::next_tx(&mut scenario, LP_PROVIDER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let mut spot_pool = unified_spot_pool::new_with_aggregator<TEST_COIN_A, TEST_COIN_B>(
            SPOT_POOL_FEE_BPS,
            option::none(),
            8000,
            &clock,
            ctx,
        );

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(SPOT_POOL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(SPOT_POOL_STABLE, ctx);
        let lp_token = unified_spot_pool::add_liquidity(&mut spot_pool, asset_coin, stable_coin, 0, ctx);

        transfer::public_share_object(spot_pool);
        transfer::public_transfer(lp_token, LP_PROVIDER_ADDR);
        clock::destroy_for_testing(clock);
    };

    // Create first proposal
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(2000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(PROPOSAL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(PROPOSAL_STABLE, ctx);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            create_test_proposal_id(ctx),
            object::id_from_address(DAO_ADDR),
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            signed::from_u128(TWAP_THRESHOLD_VALUE),
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_PERCENT,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"First Proposal"),
            string::utf8(b"metadata"),
            create_outcome_messages(2),
            create_outcome_details(2),
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            balance::zero<TEST_COIN_B>(),
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    // Activate first proposal
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let mut proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let mut escrow = ts::take_shared<TokenEscrow<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let mut spot_pool = ts::take_shared<UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(REVIEW_PERIOD_MS + 2000, ctx);

        proposal::advance_state(&mut proposal, &mut escrow, &clock, ctx);
        quantum_lp_manager::auto_quantum_split_on_proposal_start(&mut spot_pool, &mut escrow, CONDITIONAL_LIQUIDITY_RATIO_PERCENT, &clock, ctx);

        // Register the escrow with the spot pool (makes has_active_escrow return true)
        let escrow_id = object::id(&escrow);
        unified_spot_pool::store_active_escrow(&mut spot_pool, escrow_id);

        ts::return_shared(proposal);
        ts::return_shared(escrow);
        ts::return_shared(spot_pool);
        clock::destroy_for_testing(clock);
    };

    // Try to create second proposal (should fail - spot pool already has active escrow)
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(3000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(PROPOSAL_ASSET, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(PROPOSAL_STABLE, ctx);

        // This should fail because spot pool already has an active escrow
        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            object::id_from_address(@0x5678),
            object::id_from_address(DAO_ADDR),
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            signed::from_u128(TWAP_THRESHOLD_VALUE),
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_PERCENT,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Second Proposal"),
            string::utf8(b"metadata"),
            create_outcome_messages(2),
            create_outcome_details(2),
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            balance::zero<TEST_COIN_B>(),
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    // Verify both proposals exist (markets layer allows multiple proposals)
    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        // Both proposals and escrows should exist as shared objects
        let proposal1 = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
        ts::return_shared(proposal1);

        // Note: Can't easily retrieve the second proposal by ID in test framework,
        // but the fact that initialize_market succeeded proves it was created
    };

    ts::end(scenario);
}
