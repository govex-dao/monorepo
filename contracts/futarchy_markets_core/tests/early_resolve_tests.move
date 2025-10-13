#[test_only]
module futarchy_markets_core::early_resolve_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::object::{Self, ID};
use futarchy_markets_core::early_resolve;
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_core::futarchy_config::{Self, EarlyResolveConfig};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::string;

// === Constants ===
const SECONDS_IN_DAY: u64 = 86400000; // milliseconds
const MIN_DURATION: u64 = 604800000; // 7 days
const MAX_DURATION: u64 = 2592000000; // 30 days
const MIN_TIME_SINCE_FLIP: u64 = 86400000; // 1 day

// === Test Helpers ===

/// Create a test clock at specific time
#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Create a simple early resolve config for testing
#[test_only]
fun create_test_config(
    enabled: bool,
    min_duration: u64,
    max_duration: u64,
    min_time_since_flip: u64,
): EarlyResolveConfig {
    futarchy_config::new_early_resolve_config(
        enabled,
        min_duration,
        max_duration,
        min_time_since_flip,
        100_000, // min_spread (0.01%)
    )
}

/// Create a test market state with pools
#[test_only]
fun create_test_market_state_with_pools(
    proposal_id: ID,
    dao_id: ID,
    outcome_count: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): MarketState {
    let mut outcome_messages = vector::empty();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcome_messages, string::utf8(b"Test outcome"));
        i = i + 1;
    };

    market_state::new(
        proposal_id,
        dao_id,
        outcome_count,
        outcome_messages,
        clock,
        ctx,
    )
}

// === new_metrics() Tests ===

#[test]
fun test_new_metrics_creates_valid_metrics() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let metrics = early_resolve::new_metrics(0, clock.timestamp_ms());

    // Verify metrics are created (can't inspect internals, but shouldn't abort)
    market_state::destroy_early_resolve_metrics_for_testing(metrics);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_new_metrics_different_winners() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(2000000, ctx);

    // Test with different initial winners
    let metrics0 = early_resolve::new_metrics(0, clock.timestamp_ms());
    let metrics1 = early_resolve::new_metrics(1, clock.timestamp_ms());
    let metrics2 = early_resolve::new_metrics(2, clock.timestamp_ms());

    market_state::destroy_early_resolve_metrics_for_testing(metrics0);
    market_state::destroy_early_resolve_metrics_for_testing(metrics1);
    market_state::destroy_early_resolve_metrics_for_testing(metrics2);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === check_eligibility() Tests ===

#[test]
fun test_check_eligibility_disabled_config() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(MIN_DURATION + 1000000, ctx);

    // Create disabled config
    let config = create_test_config(false, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    // Create proposal and market state
    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Initialize metrics
    let metrics = early_resolve::new_metrics(0, 0);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    // Create minimal proposal for testing
    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, // dao_id
        @0x1, // proposer
        option::none(), // liquidity_provider
        string::utf8(b"Test"), // title
        string::utf8(b"metadata"), // metadata
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")], // outcome_messages
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")], // outcome_details
        vector[@0x1, @0x1], // outcome_creators
        2, // outcome_count
        86400000, // review_period_ms (1 day)
        604800000, // trading_period_ms (7 days)
        1000000, // min_asset_liquidity
        1000000, // min_stable_liquidity
        0, // twap_start_delay
        500000, // twap_initial_observation (0.5)
        100000, // twap_step_max
        500000, // twap_threshold (0.5)
        30, // amm_total_fee_bps (0.3%)
        option::none(), // winning_outcome
        sui::balance::zero(), // fee_escrow
        @0xC, // treasury_address
        vector[option::none(), option::none()], // intent_specs
        ctx
    );

    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(!eligible, 0);
    assert!(reason == string::utf8(b"Early resolution not enabled"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_check_eligibility_no_metrics() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(MIN_DURATION + 1000000, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Create proposal
    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Check eligibility without metrics initialized
    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(!eligible, 0);
    assert!(reason == string::utf8(b"Early resolve metrics not initialized"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_check_eligibility_too_young() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Start at time 0
    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Initialize metrics at start time
    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance time but not enough (only 1 day, need 7 days)
    clock::set_for_testing(&mut clock, SECONDS_IN_DAY);

    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(!eligible, 0);
    assert!(reason == string::utf8(b"Proposal too young for early resolution"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_check_eligibility_exceeded_max_duration() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance time beyond max duration (31 days)
    clock::set_for_testing(&mut clock, MAX_DURATION + SECONDS_IN_DAY);

    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(!eligible, 0);
    assert!(reason == string::utf8(b"Proposal exceeded max duration"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_check_eligibility_winner_changed_recently() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Initialize metrics with recent flip
    let flip_time = MIN_DURATION + 100000; // Just passed min duration
    let metrics = early_resolve::new_metrics(0, flip_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance to just past min duration, but flip was recent
    clock::set_for_testing(&mut clock, MIN_DURATION + 200000);

    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(!eligible, 0);
    assert!(reason == string::utf8(b"Winner changed too recently"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_check_eligibility_passes_all_checks() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Initialize metrics with old flip time
    let flip_time = start_time;
    let metrics = early_resolve::new_metrics(0, flip_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance time: past min duration and min time since flip, but before max duration
    let eligible_time = MIN_DURATION + MIN_TIME_SINCE_FLIP + SECONDS_IN_DAY;
    clock::set_for_testing(&mut clock, eligible_time);

    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(eligible, 0);
    assert!(reason == string::utf8(b"Eligible for early resolution"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === time_until_eligible() Tests ===

#[test]
fun test_time_until_eligible_disabled() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let config = create_test_config(false, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    let time_until = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);

    assert!(time_until == 0, 0); // Returns 0 when disabled

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_time_until_eligible_needs_min_duration() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance time by 3 days (need 7 days minimum)
    let current_time = 3 * SECONDS_IN_DAY;
    clock::set_for_testing(&mut clock, current_time);

    let time_until = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);

    // Should return remaining time until min duration
    let expected = MIN_DURATION - current_time;
    assert!(time_until == expected, 0);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_time_until_eligible_needs_time_since_flip() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Flip happened recently
    let flip_time = MIN_DURATION + 10000;
    let metrics = early_resolve::new_metrics(0, flip_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance past min duration, but not enough time since flip
    let current_time = MIN_DURATION + 50000;
    clock::set_for_testing(&mut clock, current_time);

    let time_until = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);

    // Should return remaining time since last flip
    let time_since_flip = current_time - flip_time;
    let expected = MIN_TIME_SINCE_FLIP - time_since_flip;
    assert!(time_until == expected, 0);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_time_until_eligible_already_eligible() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Advance well past both requirements
    let current_time = MIN_DURATION + MIN_TIME_SINCE_FLIP + SECONDS_IN_DAY;
    clock::set_for_testing(&mut clock, current_time);

    let time_until = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);

    assert!(time_until == 0, 0); // Already eligible

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Getter Functions Tests ===

#[test]
fun test_current_winner_from_state() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    // Initialize with winner index 1
    let metrics = early_resolve::new_metrics(1, 0);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let winner = early_resolve::current_winner_from_state(&market_state);
    assert!(winner == 1, 0);

    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_last_flip_time_from_state() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let flip_time = 123456789u64;
    let metrics = early_resolve::new_metrics(0, flip_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let last_flip = early_resolve::last_flip_time_from_state(&market_state);
    assert!(last_flip == flip_time, 0);

    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_check_eligibility_at_exact_min_duration() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Set time to exactly min duration + min time since flip
    clock::set_for_testing(&mut clock, MIN_DURATION + MIN_TIME_SINCE_FLIP);

    let (eligible, _reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(eligible, 0); // Should be eligible at exact boundary

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_check_eligibility_at_exact_max_duration() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    // Set time to exactly max duration
    clock::set_for_testing(&mut clock, MAX_DURATION);

    let (eligible, reason) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);

    assert!(!eligible, 0); // Should NOT be eligible at exact max (exceeded)
    assert!(reason == string::utf8(b"Proposal exceeded max duration"), 1);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_time_until_eligible_zero_when_no_metrics() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 2, &clock, ctx
    );

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1], 2,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none()], ctx
    );

    let time_until = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);

    assert!(time_until == 0, 0); // Returns 0 when no metrics

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Integration Tests ===

#[test]
fun test_complete_eligibility_workflow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let start_time = 0u64;
    let clock = create_test_clock(start_time, ctx);

    let config = create_test_config(true, MIN_DURATION, MAX_DURATION, MIN_TIME_SINCE_FLIP);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 3, &clock, ctx
    );

    let metrics = early_resolve::new_metrics(0, start_time);
    market_state::set_early_resolve_metrics(&mut market_state, metrics);

    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xB, @0x1, option::none(),
        string::utf8(b"Test"), string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject"), string::utf8(b"Abstain")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2"), string::utf8(b"Detail 3")],
        vector[@0x1, @0x1, @0x1], 3,
        86400000, 604800000, 1000000, 1000000, 0,
        500000, 100000, 500000, 30,
        option::none(), sui::balance::zero(), @0xC,
        vector[option::none(), option::none(), option::none()], ctx
    );

    // Phase 1: Too young
    clock::set_for_testing(&mut clock, SECONDS_IN_DAY);
    let (eligible1, _) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);
    assert!(!eligible1, 0);

    let time_until1 = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);
    assert!(time_until1 > 0, 1);

    // Phase 2: Past min duration but flip too recent
    clock::set_for_testing(&mut clock, MIN_DURATION + 100000);
    market_state::update_last_flip_time_for_testing(&mut market_state, MIN_DURATION + 50000);

    let (eligible2, _) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);
    assert!(!eligible2, 2);

    // Phase 3: Now eligible
    clock::set_for_testing(&mut clock, MIN_DURATION + MIN_TIME_SINCE_FLIP + SECONDS_IN_DAY);

    let (eligible3, reason3) = early_resolve::check_eligibility(&proposal, &market_state, &config, &clock);
    assert!(eligible3, 3);
    assert!(reason3 == string::utf8(b"Eligible for early resolution"), 4);

    let time_until3 = early_resolve::time_until_eligible(&proposal, &market_state, &config, &clock);
    assert!(time_until3 == 0, 5);

    sui::test_utils::destroy(proposal);
    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_outcomes_different_winners() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);

    let proposal_id = object::id_from_address(@0xA);
    let dao_id = object::id_from_address(@0xB);

    // Test with 5 outcomes
    let mut market_state = create_test_market_state_with_pools(
        proposal_id, dao_id, 5, &clock, ctx
    );

    // Test with different winner indices
    let mut i = 0;
    while (i < 5) {
        let metrics = early_resolve::new_metrics(i, 0);
        let winner = market_state::get_current_winner_index_for_testing(&metrics);
        assert!(winner == i, i);
        market_state::destroy_early_resolve_metrics_for_testing(metrics);
        i = i + 1;
    };

    market_state::destroy_for_testing(market_state);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
