#[test_only]
module futarchy_markets_operations::no_arb_guard_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self};
use sui::object;
use futarchy_markets_operations::no_arb_guard;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state::{Self};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::string;
use std::vector;

// === Constants ===
const INITIAL_SPOT_RESERVE: u64 = 10_000_000_000; // 10,000 tokens (9 decimals)
const INITIAL_CONDITIONAL_RESERVE: u64 = 1_000_000_000; // 1,000 tokens per outcome
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%
const PRICE_SCALE: u128 = 1_000_000_000_000; // 1e12

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
    fee_bps: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B> {
    unified_spot_pool::create_pool_for_testing(
        asset_reserve,
        stable_reserve,
        fee_bps,
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
            ctx
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

/// Add imbalanced liquidity to create price differences
#[test_only]
fun add_imbalanced_liquidity_to_conditional_pools(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    asset_reserves: vector<u64>,
    stable_reserves: vector<u64>,
    ctx: &mut TxContext,
) {
    // Initialize pools first if not already done
    initialize_amm_pools(escrow, ctx);

    let market_state = coin_escrow::get_market_state_mut(escrow);
    let outcome_count = market_state::outcome_count(market_state);

    assert!(vector::length(&asset_reserves) == outcome_count, 0);
    assert!(vector::length(&stable_reserves) == outcome_count, 0);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::borrow_amm_pool_mut(market_state, (i as u64));

        // Mint test coins for liquidity
        let asset_amt = *vector::borrow(&asset_reserves, i);
        let stable_amt = *vector::borrow(&stable_reserves, i);
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(asset_amt, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(stable_amt, ctx);

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

// === Stage 1: Basic compute_noarb_band Tests ===

#[test]
fun test_compute_noarb_band_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with balanced liquidity
    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // Create escrow with 2 outcomes, balanced pools
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Get conditional pools from escrow
    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Compute no-arb band
    let (floor, ceiling) = no_arb_guard::compute_noarb_band(&spot_pool, conditionals);

    // Verify floor and ceiling are positive and floor < ceiling
    assert!(floor > 0, 0);
    assert!(ceiling > 0, 1);
    assert!(floor < ceiling, 2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_compute_noarb_band_with_single_pool() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // Create escrow with 1 outcome
    let mut escrow = create_test_escrow_with_markets(1, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    let (floor, ceiling) = no_arb_guard::compute_noarb_band(&spot_pool, conditionals);

    // Should still work with single pool
    assert!(floor > 0, 0);
    assert!(ceiling > 0, 1);
    assert!(floor < ceiling, 2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_compute_noarb_band_with_multiple_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // Create escrow with 5 outcomes
    let mut escrow = create_test_escrow_with_markets(5, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    let (floor, ceiling) = no_arb_guard::compute_noarb_band(&spot_pool, conditionals);

    // Should work with multiple outcomes
    assert!(floor > 0, 0);
    assert!(ceiling > 0, 1);
    assert!(floor < ceiling, 2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_compute_noarb_band_with_imbalanced_pools() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // Create escrow with 2 outcomes, imbalanced pools
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Pool 0: Low price (more stable, less asset)
    // Pool 1: High price (less stable, more asset)
    let asset_reserves = vector[2_000_000_000, 500_000_000];
    let stable_reserves = vector[500_000_000, 2_000_000_000];
    add_imbalanced_liquidity_to_conditional_pools(&mut escrow, asset_reserves, stable_reserves, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    let (floor, ceiling) = no_arb_guard::compute_noarb_band(&spot_pool, conditionals);

    // With imbalanced pools, band should be wider
    assert!(floor > 0, 0);
    assert!(ceiling > 0, 1);
    assert!(floor < ceiling, 2);

    // Ceiling should be significantly higher than floor with price dispersion
    let band_width = ceiling - floor;
    assert!(band_width > floor / 2, 3); // Band width > 50% of floor

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // ENoPoolsProvided
fun test_compute_noarb_band_empty_pools_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // Create empty vector of pools
    let empty_pools = vector::empty<LiquidityPool>();

    // Should fail with ENoPoolsProvided
    let (_floor, _ceiling) = no_arb_guard::compute_noarb_band(&spot_pool, &empty_pools);

    // Cleanup (won't reach here due to expected failure, but need to keep empty_pools valid)
    empty_pools.destroy_empty();
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Stage 2: ensure_spot_in_band Tests ===

#[test]
fun test_ensure_spot_in_band_balanced_pools() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Should not panic - balanced pools should be within band
    no_arb_guard::ensure_spot_in_band(&spot_pool, conditionals);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_ensure_spot_in_band_with_fees() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        100, // 1% fee
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    // Should still be within band with higher fees
    no_arb_guard::ensure_spot_in_band(&spot_pool, conditionals);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_ensure_spot_in_band_single_outcome() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(1, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    no_arb_guard::ensure_spot_in_band(&spot_pool, conditionals);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_ensure_spot_in_band_multiple_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(5, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    let market_state = coin_escrow::get_market_state(&escrow);
    let conditionals = market_state::borrow_amm_pools(market_state);

    no_arb_guard::ensure_spot_in_band(&spot_pool, conditionals);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // ENoPoolsProvided
fun test_ensure_spot_in_band_empty_pools_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let empty_pools = vector::empty<LiquidityPool>();

    no_arb_guard::ensure_spot_in_band(&spot_pool, &empty_pools);

    // Cleanup (won't reach here due to expected failure, but need to keep empty_pools valid)
    empty_pools.destroy_empty();
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
