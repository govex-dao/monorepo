#[test_only]
module futarchy_markets_core::unified_spot_pool_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::balance;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool, LPToken};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::option;

// === Constants ===
const INITIAL_LIQUIDITY: u64 = 100_000_000; // 100 tokens
const DEFAULT_FEE_BPS: u64 = 30; // 0.3%

// === Test Helpers ===

#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

// === Pool Creation Tests ===

#[test]
fun test_new_basic_pool() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Verify initial state
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == 0, 0);
    assert!(stable_reserve == 0, 1);
    assert!(unified_spot_pool::lp_supply(&pool) == 0, 2);
    assert!(!unified_spot_pool::is_aggregator_enabled(&pool), 3);

    // Cleanup
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
fun test_new_with_aggregator() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let pool = unified_spot_pool::new_with_aggregator<TEST_COIN_A, TEST_COIN_B>(
        DEFAULT_FEE_BPS,
        8000, // oracle_conditional_threshold_bps
        &clock,
        ctx,
    );

    // Verify aggregator is enabled
    assert!(unified_spot_pool::is_aggregator_enabled(&pool), 0);
    assert!(!unified_spot_pool::has_active_escrow(&pool), 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_enable_aggregator_on_basic_pool() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);
    assert!(!unified_spot_pool::is_aggregator_enabled(&pool), 0);

    // Enable aggregator
    unified_spot_pool::enable_aggregator(&mut pool, 8000, &clock, ctx);

    // Verify aggregator is now enabled
    assert!(unified_spot_pool::is_aggregator_enabled(&pool), 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === LP Token Tests ===

#[test]
fun test_lp_token_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add initial liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let lp_token = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0, // min_lp_out
        ctx,
    );

    // Verify LP token amount
    assert!(unified_spot_pool::lp_token_amount(&lp_token) > 0, 0);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
fun test_lp_token_unlocked() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // LP token should be unlocked by default
    assert!(!unified_spot_pool::is_locked(&lp_token, &clock), 0);
    assert!(option::is_none(&unified_spot_pool::get_lock_time(&lp_token)), 1);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_lp_token_set_lock() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let mut lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // Set lock time
    let lock_until = 2000000;
    unified_spot_pool::set_lock_time(&mut lp_token, lock_until);

    // Verify lock
    assert!(unified_spot_pool::is_locked(&lp_token, &clock), 0);
    assert!(option::is_some(&unified_spot_pool::get_lock_time(&lp_token)), 1);
    assert!(*option::borrow(&unified_spot_pool::get_lock_time(&lp_token)) == lock_until, 2);

    // Advance time past lock
    clock::set_for_testing(&mut clock, 3000000);
    assert!(!unified_spot_pool::is_locked(&lp_token, &clock), 3);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Add Liquidity Tests ===

#[test]
fun test_add_liquidity_initial() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // Verify reserves updated
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == INITIAL_LIQUIDITY, 0);
    assert!(stable_reserve == INITIAL_LIQUIDITY, 1);

    // Verify LP token minted
    let lp_amount = unified_spot_pool::lp_token_amount(&lp_token);
    assert!(lp_amount > 0, 2);

    // Verify LP supply increased
    assert!(unified_spot_pool::lp_supply(&pool) > 0, 3);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
fun test_add_liquidity_proportional() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Initial liquidity
    let asset1 = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    let stable1 = coin::mint_for_testing<TEST_COIN_B>(100_000, ctx);
    let lp1 = unified_spot_pool::add_liquidity(&mut pool, asset1, stable1, 0, ctx);

    let initial_lp_supply = unified_spot_pool::lp_supply(&pool);

    // Add more liquidity (proportional)
    let asset2 = coin::mint_for_testing<TEST_COIN_A>(50_000, ctx);
    let stable2 = coin::mint_for_testing<TEST_COIN_B>(50_000, ctx);
    let lp2 = unified_spot_pool::add_liquidity(&mut pool, asset2, stable2, 0, ctx);

    // Verify reserves
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == 150_000, 0);
    assert!(stable_reserve == 150_000, 1);

    // Verify LP supply increased proportionally
    assert!(unified_spot_pool::lp_supply(&pool) > initial_lp_supply, 2);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp1);
    unified_spot_pool::destroy_lp_token_for_testing(lp2);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_add_liquidity_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    let asset_coin = coin::zero<TEST_COIN_A>(ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)] // EMinimumLiquidityNotMet
fun test_add_liquidity_below_minimum() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity below minimum (1000)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(10, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(10, ctx);

    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // ESlippageExceeded
fun test_add_liquidity_slippage_exceeded() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    // Set impossibly high min_lp_out
    let lp_token = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        999_999_999_999, // Impossibly high
        ctx,
    );

    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

// === Remove Liquidity Tests ===

#[test]
fun test_remove_liquidity_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // Remove liquidity
    let (asset_out, stable_out) = unified_spot_pool::remove_liquidity(
        &mut pool,
        lp_token,
        0, // min_asset_out
        0, // min_stable_out
        ctx,
    );

    // Verify output amounts
    assert!(coin::value(&asset_out) > 0, 0);
    assert!(coin::value(&stable_out) > 0, 1);

    // Cleanup
    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(stable_out);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_remove_liquidity_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Create LP token with zero amount
    let lp_token = unified_spot_pool::create_lp_token_for_testing<TEST_COIN_A, TEST_COIN_B>(0, ctx);

    let (asset_out, stable_out) = unified_spot_pool::remove_liquidity(&mut pool, lp_token, 0, 0, ctx);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(stable_out);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

// === Swap Tests ===

#[test]
fun test_swap_asset_for_stable() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_liq, stable_liq, 0, ctx);

    // Swap asset for stable
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(10_000, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_in,
        0, // min_stable_out
        &clock,
        ctx,
    );

    // Verify output
    assert!(coin::value(&stable_out) > 0, 0);

    // Cleanup
    coin::burn_for_testing(stable_out);
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_swap_stable_for_asset() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_liq, stable_liq, 0, ctx);

    // Swap stable for asset
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(10_000, ctx);
    let asset_out = unified_spot_pool::swap_stable_for_asset(
        &mut pool,
        stable_in,
        0, // min_asset_out
        &clock,
        ctx,
    );

    // Verify output
    assert!(coin::value(&asset_out) > 0, 0);

    // Cleanup
    coin::burn_for_testing(asset_out);
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_swap_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_liq, stable_liq, 0, ctx);

    // Try to swap zero amount
    let asset_in = coin::zero<TEST_COIN_A>(ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);

    coin::burn_for_testing(stable_out);
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // ESlippageExceeded
fun test_swap_slippage_exceeded() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_liq, stable_liq, 0, ctx);

    // Swap with impossibly high min_out
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(10_000, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_in,
        999_999_999, // Impossibly high
        &clock,
        ctx,
    );

    coin::burn_for_testing(stable_out);
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === View Function Tests ===

#[test]
fun test_get_reserves() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Initially zero
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == 0, 0);
    assert!(stable_reserve == 0, 1);

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(50_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(75_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // Check reserves updated
    let (asset_reserve2, stable_reserve2) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve2 == 50_000, 2);
    assert!(stable_reserve2 == 75_000, 3);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
fun test_get_spot_price() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Zero price when no liquidity
    assert!(unified_spot_pool::get_spot_price(&pool) == 0, 0);

    // Add liquidity (1:1 ratio)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // Price should be approximately 1:1 (with precision)
    let price = unified_spot_pool::get_spot_price(&pool);
    assert!(price > 0, 1);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

#[test]
fun test_simulate_swap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_coin, stable_coin, 0, ctx);

    // Simulate swap asset to stable
    let simulated_out = unified_spot_pool::simulate_swap_asset_to_stable(&pool, 10_000);
    assert!(simulated_out > 0, 0);

    // Simulate swap stable to asset
    let simulated_out2 = unified_spot_pool::simulate_swap_stable_to_asset(&pool, 10_000);
    assert!(simulated_out2 > 0, 1);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    ts::end(scenario);
}

// === Integration Tests ===

#[test]
fun test_complete_pool_lifecycle() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // 1. Create pool
    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // 2. Add initial liquidity
    let asset1 = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable1 = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp1 = unified_spot_pool::add_liquidity(&mut pool, asset1, stable1, 0, ctx);

    // 3. Perform swaps
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(10_000, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // 4. Add more liquidity
    let asset2 = coin::mint_for_testing<TEST_COIN_A>(500_000, ctx);
    let stable2 = coin::mint_for_testing<TEST_COIN_B>(500_000, ctx);
    let lp2 = unified_spot_pool::add_liquidity(&mut pool, asset2, stable2, 0, ctx);

    // 5. Remove liquidity
    let (asset_out, stable_out) = unified_spot_pool::remove_liquidity(&mut pool, lp2, 0, 0, ctx);
    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(stable_out);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp1);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_multiple_swaps_same_direction() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(DEFAULT_FEE_BPS, ctx);

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(&mut pool, asset_liq, stable_liq, 0, ctx);

    // Perform multiple swaps
    let mut i = 0;
    while (i < 5) {
        let asset_in = coin::mint_for_testing<TEST_COIN_A>(1_000, ctx);
        let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
        coin::burn_for_testing(stable_out);
        i = i + 1;
    };

    // Verify pool still functional
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve > 0, 0);
    assert!(stable_reserve > 0, 1);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
