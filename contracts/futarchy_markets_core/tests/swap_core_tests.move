#[test_only]
module futarchy_markets_core::swap_core_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object;
use futarchy_markets_core::swap_core::{Self, SwapSession};
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_markets_primitives::conditional_amm;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::string;
use std::option;

// === Constants ===
const INITIAL_RESERVE: u64 = 1_000_000_000; // 1,000 tokens per outcome
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%

// === Test Helpers ===

/// Create a test clock
#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Create token escrow with market state and conditional pools
#[test_only]
fun create_test_escrow_with_markets(
    outcome_count: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = object::id_from_address(@0xABC);
    let dao_id = object::id_from_address(@0xDEF);

    // Create market state with pools
    let mut outcome_messages = vector::empty();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome"));
        i = i + 1;
    };

    let market_state = market_state::new(
        proposal_id,
        dao_id,
        outcome_count,
        outcome_messages,
        clock,
        ctx,
    );

    // Create escrow with market state
    coin_escrow::create_test_escrow_with_market_state(
        outcome_count,
        market_state,
        ctx,
    )
}

/// Add liquidity to all conditional pools in escrow
#[test_only]
fun add_liquidity_to_pools(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    reserve_per_outcome: u64,
    ctx: &mut TxContext,
) {
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let outcome_count = market_state::outcome_count(market_state);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::borrow_amm_pool_mut(market_state, (i as u64));
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(reserve_per_outcome, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(reserve_per_outcome, ctx);
        conditional_amm::add_liquidity_for_testing(pool, asset_coin, stable_coin, DEFAULT_FEE_BPS, ctx);
        i = i + 1;
    };
}

/// Create proposal in TRADING state
#[test_only]
fun create_test_proposal_trading(
    outcome_count: u64,
    ctx: &mut TxContext,
): Proposal<TEST_COIN_A, TEST_COIN_B> {
    let mut proposal = proposal::new_for_testing<TEST_COIN_A, TEST_COIN_B>(
        @0xDEF, // dao_id
        @0x1, // proposer
        option::none(), // liquidity_provider
        string::utf8(b"Test Proposal"),
        string::utf8(b"metadata"),
        vector[string::utf8(b"Accept"), string::utf8(b"Reject")],
        vector[string::utf8(b"Detail 1"), string::utf8(b"Detail 2")],
        vector[@0x1, @0x1],
        outcome_count,
        86400000, // review_period_ms
        604800000, // trading_period_ms
        1000000, // min_asset_liquidity
        1000000, // min_stable_liquidity
        0, // twap_start_delay
        500000, // twap_initial_observation
        100000, // twap_step_max
        500000, // twap_threshold
        30, // amm_total_fee_bps
        option::none(), // winning_outcome
        sui::balance::zero(),
        @0xC, // treasury_address
        vector[option::none(), option::none()],
        ctx
    );

    // Transition to TRADING state
    proposal::set_state_for_testing(&mut proposal, 2); // STATE_TRADING = 2

    proposal
}

// === begin_swap_session() Tests ===

#[test]
fun test_begin_swap_session_creates_valid_session() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Begin session
    let session = swap_core::begin_swap_session(&escrow);

    // Session created successfully (hot potato must be consumed)
    swap_core::destroy_test_swap_session(session);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_begin_swap_session_multiple_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Test with 5 outcomes
    let escrow = create_test_escrow_with_markets(5, &clock, ctx);

    let session = swap_core::begin_swap_session(&escrow);

    swap_core::destroy_test_swap_session(session);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === finalize_swap_session() Tests ===

#[test]
fun test_finalize_swap_session_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    let mut proposal = create_test_proposal_trading(2, ctx);

    // Initialize early resolve metrics in market state
    let market_state = coin_escrow::get_market_state_mut(&mut escrow);
    let metrics = futarchy_markets_core::early_resolve::new_metrics(0, 1000000);
    market_state::set_early_resolve_metrics(market_state, metrics);

    let session = swap_core::begin_swap_session(&escrow);

    // Finalize session (updates metrics)
    swap_core::finalize_swap_session(session, &mut proposal, &mut escrow, &clock);

    // Cleanup
    sui::test_utils::destroy(proposal);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)] // ESessionMismatch
fun test_finalize_swap_session_wrong_market() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create two different markets
    let mut escrow1 = create_test_escrow_with_markets(2, &clock, ctx);
    let mut escrow2 = create_test_escrow_with_markets(2, &clock, ctx);
    let mut proposal = create_test_proposal_trading(2, ctx);

    // Session from escrow1
    let session = swap_core::begin_swap_session(&escrow1);

    // Try to finalize with escrow2 (should fail)
    swap_core::finalize_swap_session(session, &mut proposal, &mut escrow2, &clock);

    sui::test_utils::destroy(proposal);
    coin_escrow::destroy_for_testing(escrow1);
    coin_escrow::destroy_for_testing(escrow2);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === swap_balance_asset_to_stable() Tests ===

#[test]
fun test_swap_balance_asset_to_stable_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    // Create balance and add asset
    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(
        market_id,
        2,
        ctx,
    );
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);

    let session = swap_core::begin_swap_session(&escrow);

    // Swap 10000 asset → stable in outcome 0
    let amount_out = swap_core::swap_balance_asset_to_stable(
        &session,
        &mut escrow,
        &mut balance,
        0, // outcome_idx
        10000, // amount_in
        0, // min_amount_out (no slippage protection for test)
        &clock,
        ctx,
    );

    // Verify output amount
    assert!(amount_out > 0, 0);

    // Verify balance updated
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 1); // Asset depleted
    assert!(conditional_balance::get_balance(&balance, 0, false) == amount_out, 2); // Stable received

    // Cleanup
    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_swap_balance_asset_to_stable_multiple_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Test with 3 outcomes
    let mut escrow = create_test_escrow_with_markets(3, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(
        market_id,
        3,
        ctx,
    );

    // Add asset to all outcomes
    let mut i = 0u8;
    while ((i as u64) < 3) {
        conditional_balance::add_to_balance(&mut balance, i, true, 5000);
        i = i + 1;
    };

    let session = swap_core::begin_swap_session(&escrow);

    // Swap in each outcome
    let mut i = 0u8;
    while ((i as u64) < 3) {
        let amount_out = swap_core::swap_balance_asset_to_stable(
            &session,
            &mut escrow,
            &mut balance,
            i,
            5000,
            0,
            &clock,
            ctx,
        );
        assert!(amount_out > 0, (i as u64));
        i = i + 1;
    };

    // All asset balances should be zero
    let mut i = 0u8;
    while ((i as u64) < 3) {
        assert!(conditional_balance::get_balance(&balance, i, true) == 0, (i as u64) + 10);
        assert!(conditional_balance::get_balance(&balance, i, false) > 0, (i as u64) + 20);
        i = i + 1;
    };

    // Cleanup
    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // EInsufficientOutput
fun test_swap_balance_asset_to_stable_insufficient_output() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);

    let session = swap_core::begin_swap_session(&escrow);

    // Set impossibly high min_amount_out
    swap_core::swap_balance_asset_to_stable(
        &session,
        &mut escrow,
        &mut balance,
        0,
        10000,
        999_999_999, // Impossibly high
        &clock,
        ctx,
    );

    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)] // ESessionMismatch
fun test_swap_balance_asset_to_stable_session_mismatch() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create two different markets
    let mut escrow1 = create_test_escrow_with_markets(2, &clock, ctx);
    let mut escrow2 = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow2, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow2);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);

    // Session from escrow1
    let session = swap_core::begin_swap_session(&escrow1);

    // Try to swap with escrow2 (should fail)
    swap_core::swap_balance_asset_to_stable(
        &session,
        &mut escrow2,
        &mut balance,
        0,
        10000,
        0,
        &clock,
        ctx,
    );

    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow1);
    coin_escrow::destroy_for_testing(escrow2);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 7)] // EProposalMismatch
fun test_swap_balance_asset_to_stable_balance_mismatch() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    // Create balance for DIFFERENT market
    let wrong_market_id = object::id_from_address(@0xWRONG);
    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(
        wrong_market_id,
        2,
        ctx,
    );
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);

    let session = swap_core::begin_swap_session(&escrow);

    // Try to swap with wrong balance (should fail - security check)
    swap_core::swap_balance_asset_to_stable(
        &session,
        &mut escrow,
        &mut balance,
        0,
        10000,
        0,
        &clock,
        ctx,
    );

    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EInvalidOutcome
fun test_swap_balance_asset_to_stable_invalid_outcome() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);

    let session = swap_core::begin_swap_session(&escrow);

    // Try to swap in outcome 5 (only 0 and 1 exist)
    swap_core::swap_balance_asset_to_stable(
        &session,
        &mut escrow,
        &mut balance,
        5, // Invalid outcome
        10000,
        0,
        &clock,
        ctx,
    );

    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === swap_balance_stable_to_asset() Tests ===

#[test]
fun test_swap_balance_stable_to_asset_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    // Create balance and add stable
    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, false, 8000);

    let session = swap_core::begin_swap_session(&escrow);

    // Swap 8000 stable → asset in outcome 0
    let amount_out = swap_core::swap_balance_stable_to_asset(
        &session,
        &mut escrow,
        &mut balance,
        0,
        8000,
        0,
        &clock,
        ctx,
    );

    assert!(amount_out > 0, 0);
    assert!(conditional_balance::get_balance(&balance, 0, false) == 0, 1); // Stable depleted
    assert!(conditional_balance::get_balance(&balance, 0, true) == amount_out, 2); // Asset received

    // Cleanup
    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_swap_balance_stable_to_asset_multiple_swaps_same_outcome() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 1, false, 20000);

    let session = swap_core::begin_swap_session(&escrow);

    // Perform multiple swaps in same outcome
    let out1 = swap_core::swap_balance_stable_to_asset(
        &session, &mut escrow, &mut balance, 1, 5000, 0, &clock, ctx
    );
    let out2 = swap_core::swap_balance_stable_to_asset(
        &session, &mut escrow, &mut balance, 1, 5000, 0, &clock, ctx
    );
    let out3 = swap_core::swap_balance_stable_to_asset(
        &session, &mut escrow, &mut balance, 1, 5000, 0, &clock, ctx
    );

    assert!(out1 > 0, 0);
    assert!(out2 > 0, 1);
    assert!(out3 > 0, 2);

    // Total asset received
    let total_asset = conditional_balance::get_balance(&balance, 1, true);
    assert!(total_asset == out1 + out2 + out3, 3);

    // Remaining stable
    assert!(conditional_balance::get_balance(&balance, 1, false) == 5000, 4);

    // Cleanup
    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // EInsufficientOutput
fun test_swap_balance_stable_to_asset_insufficient_output() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, false, 10000);

    let session = swap_core::begin_swap_session(&escrow);

    // Set impossibly high min_amount_out
    swap_core::swap_balance_stable_to_asset(
        &session,
        &mut escrow,
        &mut balance,
        0,
        10000,
        999_999_999,
        &clock,
        ctx,
    );

    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Integration Tests ===

#[test]
fun test_complete_swap_session_workflow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);
    let mut proposal = create_test_proposal_trading(2, ctx);

    // Initialize early resolve metrics
    let market_state = coin_escrow::get_market_state_mut(&mut escrow);
    let market_id = market_state::market_id(market_state);
    let metrics = futarchy_markets_core::early_resolve::new_metrics(0, 1000000);
    market_state::set_early_resolve_metrics(market_state, metrics);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);
    conditional_balance::add_to_balance(&mut balance, 1, false, 15000);

    // 1. Begin session
    let session = swap_core::begin_swap_session(&escrow);

    // 2. Perform multiple swaps
    swap_core::swap_balance_asset_to_stable(&session, &mut escrow, &mut balance, 0, 10000, 0, &clock, ctx);
    swap_core::swap_balance_stable_to_asset(&session, &mut escrow, &mut balance, 1, 15000, 0, &clock, ctx);

    // 3. Finalize session (updates metrics once)
    swap_core::finalize_swap_session(session, &mut proposal, &mut escrow, &clock);

    // Cleanup
    sui::test_utils::destroy(proposal);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_swap_with_5_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Test with 5 outcomes (key architecture feature!)
    let mut escrow = create_test_escrow_with_markets(5, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 5, ctx);

    // Add both asset and stable to all 5 outcomes
    let mut i = 0u8;
    while ((i as u64) < 5) {
        conditional_balance::add_to_balance(&mut balance, i, true, 3000);
        conditional_balance::add_to_balance(&mut balance, i, false, 4000);
        i = i + 1;
    };

    let session = swap_core::begin_swap_session(&escrow);

    // Swap in all 5 outcomes
    let mut i = 0u8;
    while ((i as u64) < 5) {
        swap_core::swap_balance_asset_to_stable(&session, &mut escrow, &mut balance, i, 3000, 0, &clock, ctx);
        swap_core::swap_balance_stable_to_asset(&session, &mut escrow, &mut balance, i, 4000, 0, &clock, ctx);
        i = i + 1;
    };

    // Cleanup
    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_swap_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);
    add_liquidity_to_pools(&mut escrow, INITIAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);

    let mut balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, true, 10000);

    let session = swap_core::begin_swap_session(&escrow);

    // Swap zero amount (should work but return 0)
    let amount_out = swap_core::swap_balance_asset_to_stable(
        &session,
        &mut escrow,
        &mut balance,
        0,
        0, // zero amount
        0,
        &clock,
        ctx,
    );

    assert!(amount_out == 0, 0);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 10000, 1); // Unchanged

    // Cleanup
    swap_core::destroy_test_swap_session(session);
    conditional_balance::destroy_for_testing(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
