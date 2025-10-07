#[test_only]
module futarchy_markets::conditional_amm_tests;

use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_markets::market_state::{Self, MarketState};
use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::object;

// === Test Helpers ===

fun setup_test(sender: address): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(sender);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    (scenario, clock)
}

fun create_test_market_state(ctx: &mut TxContext): (MarketState, ID) {
    let mut state = market_state::create_for_testing(2, ctx);
    market_state::init_trading_for_testing(&mut state);
    let id = market_state::market_id(&state);
    (state, id)
}

// === Pool Creation Tests ===

#[test]
fun test_create_pool_basic() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);

    let pool = conditional_amm::create_test_pool(
        market_id,
        0,                         // outcome_idx
        30,                        // fee_percent (0.3%)
        1_000_000,                 // asset_reserve
        10_000_000,                // stable_reserve (1:10 ratio)
        ctx
    );

    // Verify pool creation
    let (asset_res, stable_res) = conditional_amm::get_reserves(&pool);
    assert!(asset_res == 1_000_000, 0);
    assert!(stable_res == 10_000_000, 1);
    assert!(conditional_amm::get_outcome_idx(&pool) == 0, 2);

    // Verify price calculation (price = stable/asset = 10)
    let price = conditional_amm::get_price(&pool);
    assert!(price > 0, 3);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_create_pool_different_ratios() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    // Test 1:1 ratio
    let pool1 = conditional_amm::create_test_pool(market_id, 0, 30, 1000, 1000, ctx);
    let (a1, s1) = conditional_amm::get_reserves(&pool1);
    assert!(a1 == 1000 && s1 == 1000, 0);

    // Test 1:100 ratio
    let pool2 = conditional_amm::create_test_pool(market_id, 1, 30, 100_000, 10_000_000, ctx);
    let (a2, s2) = conditional_amm::get_reserves(&pool2);
    assert!(a2 == 100_000 && s2 == 10_000_000, 1);

    // Cleanup
    conditional_amm::destroy_for_testing(pool1);
    conditional_amm::destroy_for_testing(pool2);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Swap Tests - Asset to Stable ===

#[test]
fun test_swap_asset_to_stable_basic() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,                        // fee_percent
        1_000_000,                 // 1M asset
        10_000_000,                // 10M stable (1:10 ratio)
        ctx
    );

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // Swap 100k asset for stable
    let amount_in = 100_000;
    let amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        &market_state,
        amount_in,
        0,                         // min_amount_out (no slippage check)
        &clock,
        ctx
    );

    // Verify output is reasonable
    // With x*y=k: (1M)(10M) = (1M+100k)(10M-out)
    // out ≈ 909k (before fees)
    assert!(amount_out > 800_000, 0);  // At least 800k after fees
    assert!(amount_out < 910_000, 1);  // Not more than 910k

    // Verify reserves updated (approximate due to fees)
    let (asset_res, stable_res) = conditional_amm::get_reserves(&pool);
    assert!(asset_res == 1_000_000 + 100_000, 2);  // Asset in is exact
    // Stable out includes fees, so reserves decrease more than amount_out
    assert!(stable_res < 10_000_000, 3);
    assert!(stable_res > 10_000_000 - 1_000_000, 4);  // Less than 1M decrease (sanity check)

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_swap_asset_to_stable_multiple_swaps() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let mut pool = conditional_amm::create_test_pool(
        market_id, 0, 30, 1_000_000, 10_000_000, ctx
    );

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // First swap
    let out1 = conditional_amm::swap_asset_to_stable(&mut pool, &market_state, 10_000, 0, &clock, ctx);
    assert!(out1 > 0, 0);

    // Second swap (price should be worse due to first swap)
    let out2 = conditional_amm::swap_asset_to_stable(&mut pool, &market_state, 10_000, 0, &clock, ctx);
    assert!(out2 > 0, 1);
    assert!(out2 < out1, 2);  // Second swap gets worse price

    // Third swap
    let out3 = conditional_amm::swap_asset_to_stable(&mut pool, &market_state, 10_000, 0, &clock, ctx);
    assert!(out3 > 0, 3);
    assert!(out3 < out2, 4);  // Third swap even worse

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Swap Tests - Stable to Asset ===

#[test]
fun test_swap_stable_to_asset_basic() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let mut pool = conditional_amm::create_test_pool(
        market_id, 0, 30, 1_000_000, 10_000_000, ctx
    );

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // Swap 1M stable for asset
    let amount_in = 1_000_000;
    let amount_out = conditional_amm::swap_stable_to_asset(
        &mut pool,
        &market_state,
        amount_in,
        0,
        &clock,
        ctx
    );

    // Verify output is reasonable
    // With x*y=k: (1M)(10M) = (1M-out)(10M+1M)
    // out ≈ 90.9k (before fees)
    assert!(amount_out > 80_000, 0);
    assert!(amount_out < 91_000, 1);

    // Verify reserves (approximate due to fees)
    let (asset_res, stable_res) = conditional_amm::get_reserves(&pool);
    // Stable in minus fee taken
    assert!(stable_res < 10_000_000 + 1_000_000, 2);  // Less than full amount (fee taken)
    assert!(stable_res > 10_000_000, 3);  // But more than original
    // Asset out decreases reserves
    assert!(asset_res < 1_000_000, 4);
    assert!(asset_res > 1_000_000 - 100_000, 5);  // Reasonable decrease

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Quote Tests ===

#[test]
fun test_quote_swap_asset_to_stable() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let pool = conditional_amm::create_test_pool(
        market_id, 0, 30, 1_000_000, 10_000_000, ctx
    );

    // Quote swap without executing
    let quote1 = conditional_amm::quote_swap_asset_to_stable(&pool, 100_000);
    assert!(quote1 > 0, 0);

    // Multiple quotes should return same result (no state change)
    let quote2 = conditional_amm::quote_swap_asset_to_stable(&pool, 100_000);
    assert!(quote1 == quote2, 1);

    // Different amounts should give different quotes
    let quote3 = conditional_amm::quote_swap_asset_to_stable(&pool, 200_000);
    assert!(quote3 > quote1, 2);
    assert!(quote3 < quote1 * 2, 3);  // Non-linear due to slippage

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_quote_swap_stable_to_asset() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let pool = conditional_amm::create_test_pool(
        market_id, 0, 30, 1_000_000, 10_000_000, ctx
    );

    // Quote stable -> asset swap
    let quote1 = conditional_amm::quote_swap_stable_to_asset(&pool, 1_000_000);
    assert!(quote1 > 0, 0);

    // Verify idempotence
    let quote2 = conditional_amm::quote_swap_stable_to_asset(&pool, 1_000_000);
    assert!(quote1 == quote2, 1);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Price Tests ===

#[test]
fun test_get_price() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    // Pool with 1:10 ratio should have price ≈ 10
    let pool1 = conditional_amm::create_test_pool(market_id, 0, 30, 1_000_000, 10_000_000, ctx);
    let price1 = conditional_amm::get_price(&pool1);
    assert!(price1 > 0, 0);

    // Pool with 1:1 ratio should have price ≈ 1
    let pool2 = conditional_amm::create_test_pool(market_id, 1, 30, 1_000_000, 1_000_000, ctx);
    let price2 = conditional_amm::get_price(&pool2);
    assert!(price2 > 0, 1);
    assert!(price1 > price2, 2);  // 1:10 ratio has higher price than 1:1

    // Cleanup
    conditional_amm::destroy_for_testing(pool1);
    conditional_amm::destroy_for_testing(pool2);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_price_changes_after_swap() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);


    let mut pool = conditional_amm::create_test_pool(market_id, 0, 30, 1_000_000, 10_000_000, ctx);

    // Get initial reserves
    let (asset_before, stable_before) = conditional_amm::get_reserves(&pool);
    // Calculate price as stable/asset
    let price_before = (stable_before as u128) * 1_000_000 / (asset_before as u128);

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // Buy asset with stable (adds stable, removes asset → increases asset price)
    conditional_amm::swap_stable_to_asset(&mut pool, &market_state, 1_000_000, 0, &clock, ctx);

    // Get new reserves
    let (asset_after, stable_after) = conditional_amm::get_reserves(&pool);
    // Calculate new price
    let price_after = (stable_after as u128) * 1_000_000 / (asset_after as u128);

    // Price should have increased (asset became more expensive)
    // stable/asset ratio increased because: stable increased, asset decreased
    assert!(price_after > price_before, 0);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);

    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Getter Tests ===

#[test]
fun test_getters() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let pool = conditional_amm::create_test_pool(market_id, 5, 30, 1_000_000, 10_000_000, ctx);

    // Test outcome_idx getter
    assert!(conditional_amm::get_outcome_idx(&pool) == 5, 0);

    // Test reserves getter
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 1_000_000, 1);
    assert!(stable == 10_000_000, 2);

    // Test K constant (should be asset * stable)
    let k = conditional_amm::get_k(&pool);
    assert!(k == (1_000_000 as u128) * (10_000_000 as u128), 3);

    // Test market ID getter
    assert!(conditional_amm::get_ms_id(&pool) == market_id, 4);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_small_swap_amounts() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let mut pool = conditional_amm::create_test_pool(market_id, 0, 30, 1_000_000, 10_000_000, ctx);

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // Very small swap (1 token)
    let out1 = conditional_amm::swap_asset_to_stable(&mut pool, &market_state, 1, 0, &clock, ctx);
    assert!(out1 > 0, 0);  // Should still get output

    // Slightly larger
    let out2 = conditional_amm::swap_asset_to_stable(&mut pool, &market_state, 100, 0, &clock, ctx);
    assert!(out2 > out1, 1);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_large_swap_amounts() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let mut pool = conditional_amm::create_test_pool(market_id, 0, 30, 10_000_000, 100_000_000, ctx);

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // Large swap (50% of pool)
    let amount_in = 5_000_000;
    let amount_out = conditional_amm::swap_asset_to_stable(&mut pool, &market_state, amount_in, 0, &clock, ctx);

    // Should still work but with significant slippage
    assert!(amount_out > 0, 0);
    assert!(amount_out < 50_000_000, 1);  // Due to slippage, gets less than 50%

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_xyk_invariant_maintained() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let (market_state, market_id) = create_test_market_state(ctx);
    

    let mut pool = conditional_amm::create_test_pool(market_id, 0, 30, 1_000_000, 10_000_000, ctx);

    // Get initial K
    let k_before = conditional_amm::get_k(&pool);

    // Initialize oracle
    conditional_amm::set_oracle_start_time(&mut pool, &market_state);
    // Do a swap
    conditional_amm::swap_asset_to_stable(&mut pool, &market_state, 100_000, 0, &clock, ctx);

    // Get K after swap
    let k_after = conditional_amm::get_k(&pool);

    // K should increase or stay same (fees increase K)
    assert!(k_after >= k_before, 0);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    
    market_state::destroy_for_testing(market_state);
    clock.destroy_for_testing();
    ts::end(scenario);
}
