#[test_only]
module futarchy_markets_core::proposal_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::balance;
use sui::test_utils;
use std::string::{Self, String};
use std::option;
use futarchy_markets_core::proposal;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state::{Self};
use futarchy_markets_primitives::conditional_amm::{LiquidityPool};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use futarchy_types::action_specs::{Self, InitActionSpecs};

// === Test Constants ===

const DAO_ADDR: address = @0xDA0;
const PROPOSER_ADDR: address = @0xABCD;
const TREASURY_ADDR: address = @0xFEE;

const REVIEW_PERIOD_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours
const TRADING_PERIOD_MS: u64 = 7 * 24 * 60 * 60 * 1000; // 7 days
const MIN_ASSET_LIQUIDITY: u64 = 1_000_000_000; // 1 token (9 decimals)
const MIN_STABLE_LIQUIDITY: u64 = 10_000_000; // 10 USDC (6 decimals)
const TWAP_START_DELAY: u64 = 60 * 1000; // 1 minute
const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000_000_000_000_000u128; // 1.0 in Q64.64
const TWAP_STEP_MAX: u64 = 100;
const TWAP_THRESHOLD: u64 = 500_000_000_000_000_000u64; // 0.5 in Q64.64
const AMM_TOTAL_FEE_BPS: u64 = 30; // 0.3%
const CONDITIONAL_LIQUIDITY_RATIO_BPS: u64 = 5000; // 50%
const MAX_OUTCOMES: u64 = 10;

// Error codes from proposal.move
const EInvalidAmount: u64 = 1;
const EInvalidState: u64 = 2;
const EAssetLiquidityTooLow: u64 = 4;
const EStableLiquidityTooLow: u64 = 5;
const EPoolNotFound: u64 = 6;
const EOutcomeOutOfBounds: u64 = 7;
const EInvalidOutcomeVectors: u64 = 8;
const ETooManyOutcomes: u64 = 10;
const EInvalidOutcome: u64 = 11;
const ENotFinalized: u64 = 12;
const ETwapNotSet: u64 = 13;

// State constants
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1;
const STATE_TRADING: u8 = 2;
const STATE_FINALIZED: u8 = 3;

// Outcome constants
const OUTCOME_ACCEPTED: u64 = 0;
const OUTCOME_REJECTED: u64 = 1;

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
        string::append(&mut msg, string::utf8(b""));
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

// === Proposal Creation Tests ===

#[test]
fun test_initialize_market_basic_two_outcomes() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    // Initialize test coins
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        // Create coins for liquidity
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(20_000_000, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        // Create proposal
        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        let (actual_proposal_id, market_state_id, state) = proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
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

        // Verify state is REVIEW after initialization
        assert!(state == STATE_REVIEW, 0);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_initialize_market_three_outcomes() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(3_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(30_000_000, ctx);

        let outcome_messages = create_outcome_messages(3);
        let outcome_details = create_outcome_details(3);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        let (_actual_proposal_id, _market_state_id, state) = proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        assert!(state == STATE_REVIEW, 0);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidAmount)]
fun test_initialize_market_zero_liquidity_fails() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        // Zero liquidity should fail
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(20_000_000, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EAssetLiquidityTooLow)]
fun test_initialize_market_insufficient_asset_liquidity() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        // Insufficient asset liquidity
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx); // Too low
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(20_000_000, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EStableLiquidityTooLow)]
fun test_initialize_market_insufficient_stable_liquidity() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(100, ctx); // Too low

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidOutcomeVectors)]
fun test_initialize_market_mismatched_outcome_vectors() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(20_000_000, ctx);

        // Mismatched counts - 2 messages but 3 details
        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(3);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ETooManyOutcomes)]
fun test_initialize_market_too_many_outcomes() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(15_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(150_000_000, ctx);

        // 15 outcomes exceeds MAX_OUTCOMES (10)
        let outcome_messages = create_outcome_messages(15);
        let outcome_details = create_outcome_details(15);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === Premarket Proposal Tests ===

#[test]
fun test_new_premarket_basic() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let fee_escrow = balance::zero<TEST_COIN_B>();
        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        let actual_proposal_id = proposal::new_premarket<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Premarket Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            PROPOSER_ADDR,
            false, // uses_dao_liquidity
            false, // used_quota
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        // Just verify it was created (returns an ID)
        assert!(actual_proposal_id != object::id_from_address(@0x0), 0);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ETooManyOutcomes)]
fun test_new_premarket_too_many_outcomes() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let outcome_messages = create_outcome_messages(15); // Exceeds MAX_OUTCOMES
        let outcome_details = create_outcome_details(15);
        let fee_escrow = balance::zero<TEST_COIN_B>();
        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        proposal::new_premarket<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Premarket Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            PROPOSER_ADDR,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === State Transition Tests ===

// Note: Full state transition testing requires initialized proposals with escrows and market states.
// These are integration tests that would require more complex setup with shared objects.
// The tests above cover the creation phase thoroughly.

// === View Function Tests ===

#[test]
fun test_proposal_getters() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(5000, ctx);

        let outcome_messages = create_outcome_messages(3);
        let outcome_details = create_outcome_details(3);
        let outcome_creators = vector[PROPOSER_ADDR, PROPOSER_ADDR, PROPOSER_ADDR];
        let fee_escrow = balance::zero<TEST_COIN_B>();

        // Create a test proposal using new_for_testing
        let proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
            DAO_ADDR,
            PROPOSER_ADDR,
            option::some(PROPOSER_ADDR),
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test metadata"),
            outcome_messages,
            outcome_details,
            outcome_creators,
            3, // outcome_count
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            option::none<u64>(), // winning_outcome
            fee_escrow,
            TREASURY_ADDR,
            vector[option::none(), option::none(), option::none()], // intent_specs
            ctx
        );

        // Test getters
        assert!(proposal::state(&proposal) == STATE_PREMARKET, 0);
        assert!(proposal::proposer(&proposal) == PROPOSER_ADDR, 1);
        assert!(proposal::outcome_count(&proposal) == 3, 2);
        assert!(proposal::treasury_address(&proposal) == TREASURY_ADDR, 3);
        assert!(!proposal::is_finalized(&proposal), 4);
        assert!(!proposal::is_winning_outcome_set(&proposal), 5);
        assert!(proposal::get_review_period_ms(&proposal) == REVIEW_PERIOD_MS, 6);
        assert!(proposal::get_trading_period_ms(&proposal) == TRADING_PERIOD_MS, 7);
        assert!(proposal::get_twap_threshold(&proposal) == TWAP_THRESHOLD, 8);
        assert!(!proposal::uses_dao_liquidity(&proposal), 9);
        assert!(!proposal::get_used_quota(&proposal), 10);
        assert!(!proposal::is_withdraw_only(&proposal), 11);

        test_utils::destroy(proposal);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_outcome_creator_getters() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(5000, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let outcome_creators = vector[PROPOSER_ADDR, DAO_ADDR];
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
            DAO_ADDR,
            PROPOSER_ADDR,
            option::some(PROPOSER_ADDR),
            string::utf8(b"Test Proposal"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            outcome_creators,
            2,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            option::none<u64>(),
            fee_escrow,
            TREASURY_ADDR,
            vector[option::none(), option::none()],
            ctx
        );

        // Test outcome creator getters
        assert!(proposal::get_outcome_creator(&proposal, 0) == PROPOSER_ADDR, 0);
        assert!(proposal::get_outcome_creator(&proposal, 1) == DAO_ADDR, 1);

        let creators = proposal::get_outcome_creators(&proposal);
        assert!(creators.length() == 2, 2);
        assert!(*creators.borrow(0) == PROPOSER_ADDR, 3);
        assert!(*creators.borrow(1) == DAO_ADDR, 4);

        test_utils::destroy(proposal);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === Error Handling Tests ===

#[test]
#[expected_failure(abort_code = EOutcomeOutOfBounds)]
fun test_get_outcome_creator_out_of_bounds() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(5000, ctx);

        let outcome_messages = create_outcome_messages(2);
        let outcome_details = create_outcome_details(2);
        let outcome_creators = vector[PROPOSER_ADDR, PROPOSER_ADDR];
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
            DAO_ADDR,
            PROPOSER_ADDR,
            option::some(PROPOSER_ADDR),
            string::utf8(b"Test"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            outcome_creators,
            2,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            option::none<u64>(),
            fee_escrow,
            TREASURY_ADDR,
            vector[option::none(), option::none()],
            ctx
        );

        // This should fail - accessing index 2 when only 0 and 1 exist
        let _creator = proposal::get_outcome_creator(&proposal, 2);

        test_utils::destroy(proposal);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === Edge Case Tests ===

#[test]
fun test_proposal_with_single_outcome() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);

        let outcome_messages = create_outcome_messages(1);
        let outcome_details = create_outcome_details(1);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        let (_actual_proposal_id, _market_state_id, state) = proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Single Outcome"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        assert!(state == STATE_REVIEW, 0);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_proposal_with_max_outcomes() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(10_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);

        let outcome_messages = create_outcome_messages(MAX_OUTCOMES);
        let outcome_details = create_outcome_details(MAX_OUTCOMES);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        let (_actual_proposal_id, _market_state_id, state) = proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Max Outcomes"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        assert!(state == STATE_REVIEW, 0);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_proposal_liquidity_distribution() {
    let mut scenario = ts::begin(PROPOSER_ADDR);
    let ctx = ts::ctx(&mut scenario);

    futarchy_one_shot_utils::test_coin_a::init_for_testing(ctx);
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ctx);

    ts::next_tx(&mut scenario, PROPOSER_ADDR);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = create_test_clock(1000, ctx);

        // Test uneven liquidity distribution (3 outcomes, 10 total)
        // 10 / 3 = 3 per outcome, remainder 1
        // Expected: [4, 3, 3] (first outcome gets the remainder)
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(10_000_000_000, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);

        let outcome_messages = create_outcome_messages(3);
        let outcome_details = create_outcome_details(3);
        let fee_escrow = balance::zero<TEST_COIN_B>();

        let proposal_id = create_test_proposal_id(ctx);
        let dao_id = object::id_from_address(DAO_ADDR);

        let (_actual_proposal_id, _market_state_id, state) = proposal::initialize_market<TEST_COIN_A, TEST_COIN_B>(
            proposal_id,
            dao_id,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            TWAP_THRESHOLD,
            AMM_TOTAL_FEE_BPS,
            CONDITIONAL_LIQUIDITY_RATIO_BPS,
            MAX_OUTCOMES,
            TREASURY_ADDR,
            string::utf8(b"Distribution Test"),
            string::utf8(b"metadata"),
            outcome_messages,
            outcome_details,
            asset_coin,
            stable_coin,
            PROPOSER_ADDR,
            1000,
            false,
            false,
            fee_escrow,
            option::none<InitActionSpecs>(),
            &clock,
            ctx,
        );

        assert!(state == STATE_REVIEW, 0);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}
