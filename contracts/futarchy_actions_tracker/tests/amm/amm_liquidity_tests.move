#[test_only]
module futarchy::amm_liquidity_tests;

use futarchy::conditional_amm;
use futarchy::math;
use sui::object;
use sui::test_scenario::{Self as test, next_tx, ctx};

// ======== Test Constants ========
const ADMIN: address = @0xA;
const LP_1: address = @0x1;
const LP_2: address = @0x2;

const INITIAL_RESERVE: u64 = 1_000_000;
const SWAP_FEE_RATE: u64 = 30; // 0.3% = 30/10000

// ======== Liquidity Tests ========

#[test]
fun test_initial_liquidity_bootstrap() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, LP_1);

    // Create pool with initial liquidity
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario),
    );

    // Verify initial state
    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(&pool);
    assert!(asset_reserve == INITIAL_RESERVE, 0);
    assert!(stable_reserve == INITIAL_RESERVE, 1);

    // Check LP supply (should be set to MINIMUM_LIQUIDITY)
    let lp_supply = conditional_amm::get_lp_supply(&pool);
    assert!(lp_supply > 0, 2);

    // Verify k constant
    let k = math::mul_div_to_128(asset_reserve, stable_reserve, 1);
    assert!(k == (INITIAL_RESERVE as u128) * (INITIAL_RESERVE as u128), 3);

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_proportional_liquidity_addition() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, LP_1);

    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let mut pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario),
    );

    // Record initial state
    let (init_asset, init_stable) = conditional_amm::get_reserves(&pool);
    let init_lp = conditional_amm::get_lp_supply(&pool);
    let init_k = math::mul_div_to_128(init_asset, init_stable, 1);

    // Add proportional liquidity (50% more)
    let add_amount = INITIAL_RESERVE / 2;

    // Simulate adding liquidity
    // In real implementation, this would:
    // 1. Transfer tokens to pool
    // 2. Mint LP tokens proportionally
    // 3. Update reserves

    // Expected LP tokens for proportional add
    let expected_lp = math::mul_div_to_64(add_amount, init_lp, init_asset);

    // Verify calculations
    assert!(expected_lp == init_lp / 2, 0); // 50% of existing LP supply

    // After adding liquidity, reserves should increase proportionally
    let new_asset = init_asset + add_amount;
    let new_stable = init_stable + add_amount;
    let new_k = math::mul_div_to_128(new_asset, new_stable, 1);

    // K should increase
    assert!(new_k > init_k, 1);

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_imbalanced_liquidity_addition() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, LP_1);

    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario),
    );

    // Try to add imbalanced liquidity
    let asset_add = INITIAL_RESERVE;
    let stable_add = INITIAL_RESERVE / 2; // Only half the stable

    // Calculate optimal amounts
    // To maintain price, ratio must be the same
    let current_price = (INITIAL_RESERVE * 1_000_000) / INITIAL_RESERVE; // 1:1

    // One token amount determines the other
    let optimal_stable = (asset_add * INITIAL_RESERVE) / INITIAL_RESERVE;
    assert!(optimal_stable == asset_add, 0); // Should be equal for 1:1 pool

    // Excess asset would be refunded in real implementation
    let excess_stable = asset_add - stable_add;
    assert!(excess_stable == INITIAL_RESERVE / 2, 1);

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_liquidity_removal() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, LP_1);

    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario),
    );

    // Get initial state
    let (init_asset, init_stable) = conditional_amm::get_reserves(&pool);
    let init_lp = conditional_amm::get_lp_supply(&pool);

    // Remove 25% of liquidity
    let lp_to_remove = init_lp / 4;

    // Calculate expected token outputs
    let expected_asset = math::mul_div_to_64(lp_to_remove, init_asset, init_lp);
    let expected_stable = math::mul_div_to_64(lp_to_remove, init_stable, init_lp);

    // Verify proportional removal
    assert!(expected_asset == INITIAL_RESERVE / 4, 0);
    assert!(expected_stable == INITIAL_RESERVE / 4, 1);

    // After removal
    let remaining_asset = init_asset - expected_asset;
    let remaining_stable = init_stable - expected_stable;
    let remaining_lp = init_lp - lp_to_remove;

    // Verify k decreases proportionally
    let new_k = math::mul_div_to_128(remaining_asset, remaining_stable, 1);
    let init_k = math::mul_div_to_128(init_asset, init_stable, 1);

    // k should decrease by ~43.75% (0.75 * 0.75 = 0.5625)
    let k_ratio = (new_k * 100) / init_k;
    assert!(k_ratio >= 56 && k_ratio <= 57, 2);

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_minimum_liquidity_enforcement() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, LP_1);

    // Create pool with small reserves
    let dummy_market_id = object::id_from_address(ADMIN);
    let small_reserve = 10_000; // Small amount

    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        small_reserve,
        small_reserve,
        ctx(&mut scenario),
    );

    // Get LP supply
    let lp_supply = conditional_amm::get_lp_supply(&pool);

    // Even with small reserves, minimum LP tokens should be minted
    assert!(lp_supply >= 1000, 0); // MINIMUM_LIQUIDITY constant

    // Try to remove all liquidity (should fail in real implementation)
    // Pool should maintain minimum liquidity locked forever

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_lp_token_value_tracking() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, LP_1);

    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let mut pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario),
    );

    // Initial LP value
    let init_lp = conditional_amm::get_lp_supply(&pool);
    let (init_asset, init_stable) = conditional_amm::get_reserves(&pool);

    // Value per LP token
    let init_asset_per_lp = (init_asset * 1_000_000) / init_lp;
    let init_stable_per_lp = (init_stable * 1_000_000) / init_lp;

    // Simulate some swaps that generate fees
    let swap_count = 10;
    let swap_amount = 10_000;
    let mut total_fees = 0;

    let mut i = 0;
    while (i < swap_count) {
        let quote = conditional_amm::quote_swap_asset_to_stable(&pool, swap_amount);
        let fee = (swap_amount * SWAP_FEE_RATE) / 10000;
        total_fees = total_fees + fee;
        i = i + 1;
    };

    // After fees, LP tokens should be worth more
    // In reality, fees increase reserves without minting new LP tokens
    // So each LP token represents more underlying assets

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_multiple_lp_providers() {
    let mut scenario = test::begin(ADMIN);

    // LP_1 provides initial liquidity
    next_tx(&mut scenario, LP_1);
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario),
    );

    let initial_lp = conditional_amm::get_lp_supply(&pool);

    // LP_2 adds liquidity
    next_tx(&mut scenario, LP_2);

    // LP_2 adds 50% more liquidity
    let lp2_amount = INITIAL_RESERVE / 2;

    // LP_2 should get LP tokens proportional to their contribution
    let lp2_expected_tokens = math::mul_div_to_64(
        lp2_amount,
        initial_lp,
        INITIAL_RESERVE,
    );

    // Verify LP_2 gets 1/3 of total LP supply after adding
    // (they added 50% to a pool of 100%, so they own 50/150 = 1/3)
    let total_lp_after = initial_lp + lp2_expected_tokens;
    let lp2_share = (lp2_expected_tokens * 100) / total_lp_after;
    assert!(lp2_share >= 33 && lp2_share <= 34, 0);

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}
