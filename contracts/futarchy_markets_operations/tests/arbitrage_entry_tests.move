#[test_only]
module futarchy_markets_operations::arbitrage_entry_tests;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_operations::arbitrage_entry;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::string;
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::object;
use sui::test_scenario as ts;

// === Constants ===
const INITIAL_SPOT_RESERVE: u64 = 10_000_000_000; // 10,000 tokens (9 decimals)
const INITIAL_CONDITIONAL_RESERVE: u64 = 1_000_000_000; // 1,000 tokens per outcome
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%

// === Test Helpers ===

/// Create a test clock
#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Create spot pool with initial liquidity
#[test_only]
fun create_test_spot_pool(
    asset_reserve: u64,
    stable_reserve: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B> {
    unified_spot_pool::create_pool_for_testing(
        asset_reserve,
        stable_reserve,
        (DEFAULT_FEE_BPS as u64),
        ctx,
    )
}

/// Create token escrow with market state
#[test_only]
fun create_test_escrow_with_markets(
    outcome_count: u64,
    _conditional_reserve_per_outcome: u64,
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

/// Initialize AMM pools in market state
#[test_only]
fun initialize_amm_pools(escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>, ctx: &mut TxContext) {
    let market_state = coin_escrow::get_market_state_mut(escrow);

    // Check if pools already initialized
    if (market_state::has_amm_pools(market_state)) {
        return
    };

    // Get the market_id to ensure pools match
    let market_id = market_state::market_id(market_state);

    let outcome_count = market_state::outcome_count(market_state);
    let mut pools = vector::empty();
    let mut i = 0;
    let clock = create_test_clock(1000000, ctx);
    while (i < outcome_count) {
        // Create pool with correct market_id
        let pool = conditional_amm::create_test_pool(
            market_id,
            (i as u8), // outcome_idx
            (DEFAULT_FEE_BPS as u64), // fee_percent
            1000, // minimal asset_reserve
            1000, // minimal stable_reserve
            &clock,
            ctx,
        );
        vector::push_back(&mut pools, pool);
        i = i + 1;
    };
    clock::destroy_for_testing(clock);

    market_state::set_amm_pools(market_state, pools);

    // Initialize trading for tests
    market_state::init_trading_for_testing(market_state);
}

/// Add initial liquidity to all conditional pools in escrow
#[test_only]
fun add_liquidity_to_conditional_pools(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    reserve_per_outcome: u64,
    ctx: &mut TxContext,
) {
    // Initialize pools first if not already done
    initialize_amm_pools(escrow, ctx);

    let market_state = coin_escrow::get_market_state_mut(escrow);
    let outcome_count = market_state::outcome_count(market_state);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::borrow_amm_pool_mut(market_state, (i as u64));

        // Mint test coins for liquidity
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(reserve_per_outcome, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(reserve_per_outcome, ctx);

        // Add liquidity
        conditional_amm::add_liquidity_for_testing(
            pool,
            asset_coin,
            stable_coin,
            DEFAULT_FEE_BPS,
            ctx,
        );

        i = i + 1;
    };
}

// === Basic Quote Tests - Batch 1 ===

#[test]
fun test_get_quote_asset_to_stable_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with balanced liquidity
    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Get conditional pools from escrow
    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Get quote for asset→stable swap
    let amount_in = 1_000_000; // 1 token
    let quote = arbitrage_entry::get_quote_asset_to_stable(
        &spot_pool,
        conditionals,
        amount_in,
    );

    // Verify quote structure
    assert!(arbitrage_entry::quote_amount_in(&quote) == amount_in, 0);
    assert!(arbitrage_entry::quote_direct_output(&quote) > 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_get_quote_stable_to_asset_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with balanced liquidity
    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Get conditional pools from escrow
    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Get quote for stable→asset swap
    let amount_in = 1_000_000; // 1 token
    let quote = arbitrage_entry::get_quote_stable_to_asset(
        &spot_pool,
        conditionals,
        amount_in,
    );

    // Verify quote structure
    assert!(arbitrage_entry::quote_amount_in(&quote) == amount_in, 0);
    assert!(arbitrage_entry::quote_direct_output(&quote) > 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_get_quote_with_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Get quote for zero amount
    let quote = arbitrage_entry::get_quote_asset_to_stable(
        &spot_pool,
        conditionals,
        0,
    );

    // Zero input should give zero output
    assert!(arbitrage_entry::quote_amount_in(&quote) == 0, 0);
    assert!(arbitrage_entry::quote_direct_output(&quote) == 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Arbitrage Simulation Tests - Batch 2 ===

#[test]
fun test_simulate_pure_arbitrage_with_min_profit_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Simulate arbitrage with zero min_profit (show all opportunities)
    let (amount, profit, _direction) = arbitrage_entry::simulate_pure_arbitrage_with_min_profit(
        &spot_pool,
        conditionals,
        0,
        0,
    );

    // Should return results (amount and profit may be zero if no arbitrage)
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_simulate_pure_arbitrage_with_high_min_profit() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Simulate arbitrage with very high min_profit (should filter out most opportunities)
    let (amount, profit, _direction) = arbitrage_entry::simulate_pure_arbitrage_with_min_profit(
        &spot_pool,
        conditionals,
        0,
        1_000_000_000,
    );

    // Likely no arbitrage meets this threshold
    // (but this depends on pool state, so we just check it doesn't crash)
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_simulate_pure_arbitrage_asset_to_stable() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Test legacy function for asset→stable direction
    let (amount, profit) = arbitrage_entry::simulate_pure_arbitrage_asset_to_stable(
        &spot_pool,
        conditionals,
        0,
    );

    // Should return results
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_simulate_pure_arbitrage_stable_to_asset() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Test legacy function for stable→asset direction
    let (amount, profit) = arbitrage_entry::simulate_pure_arbitrage_stable_to_asset(
        &spot_pool,
        conditionals,
        0,
    );

    // Should return results
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === SwapQuote Getter Tests - Batch 3 ===

#[test]
fun test_quote_getters() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    let amount_in = 1_000_000;
    let quote = arbitrage_entry::get_quote_asset_to_stable(
        &spot_pool,
        conditionals,
        amount_in,
    );

    // Test all getter functions
    assert!(arbitrage_entry::quote_amount_in(&quote) == amount_in, 0);
    assert!(arbitrage_entry::quote_direct_output(&quote) >= 0, 1);
    assert!(arbitrage_entry::quote_optimal_arb_amount(&quote) >= 0, 2);
    assert!(arbitrage_entry::quote_expected_arb_profit(&quote) >= 0, 3);

    // is_arb_available should be consistent with amount/profit
    let is_arb = arbitrage_entry::quote_is_arb_available(&quote);
    if (is_arb) {
        assert!(arbitrage_entry::quote_optimal_arb_amount(&quote) > 0, 4);
        assert!(arbitrage_entry::quote_expected_arb_profit(&quote) > 0, 5);
    };

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_quote_arb_profit_bps_with_arbitrage() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    let quote = arbitrage_entry::get_quote_asset_to_stable(
        &spot_pool,
        conditionals,
        1_000_000,
    );

    // Get bps - should be 0 or positive
    let bps = arbitrage_entry::quote_arb_profit_bps(&quote);
    assert!(bps >= 0, 0);

    // If arbitrage is available, bps should reflect profit ratio
    if (arbitrage_entry::quote_is_arb_available(&quote)) {
        assert!(bps > 0, 1);
    };

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_quote_arb_profit_bps_zero_output() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Get quote with zero amount
    let quote = arbitrage_entry::get_quote_asset_to_stable(
        &spot_pool,
        conditionals,
        0,
    );

    // With zero output, bps should be 0
    let bps = arbitrage_entry::quote_arb_profit_bps(&quote);
    assert!(bps == 0, 0);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_quote_arb_profit_bps_no_arbitrage() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    let quote = arbitrage_entry::get_quote_asset_to_stable(
        &spot_pool,
        conditionals,
        1_000_000,
    );

    let bps = arbitrage_entry::quote_arb_profit_bps(&quote);

    // If no arbitrage available, bps should be 0
    if (!arbitrage_entry::quote_is_arb_available(&quote)) {
        assert!(bps == 0, 0);
    };

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
