#[test_only]
module futarchy_markets_primitives::conditional_amm_tests;

use futarchy_markets_primitives::conditional_amm;
use sui::clock::{Self, Clock};
use sui::test_scenario as ts;
use sui::test_utils::destroy;

// === Test Helpers ===

fun start(): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(@0x0);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    (scenario, clock)
}

fun end(scenario: ts::Scenario, clock: Clock) {
    destroy(clock);
    ts::end(scenario);
}

// === Stage 1: Pool Creation & Basic Getters ===

#[test]
fun test_new_pool() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let outcome_idx = 0u8;
    let fee_percent = 30u64; // 0.3%
    let initial_asset = 1000000u64;
    let initial_stable = 1000000u64;
    let twap_initial_observation = 1_000_000_000_000u128; // 1:1 price scaled
    let twap_start_delay = 0u64;
    let twap_step_max = 1000u64;

    let pool = conditional_amm::new_pool(
        market_id,
        outcome_idx,
        fee_percent,
        initial_asset,
        initial_stable,
        twap_initial_observation,
        twap_start_delay,
        twap_step_max,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify basic properties
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == initial_asset, 0);
    assert!(stable == initial_stable, 1);
    assert!(conditional_amm::get_lp_supply(&pool) == 0, 2);
    assert!(conditional_amm::get_fee_bps(&pool) == fee_percent, 3);
    assert!(conditional_amm::get_outcome_idx(&pool) == outcome_idx, 4);
    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 5);
    assert!(conditional_amm::get_ms_id(&pool) == market_id, 6);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_new_pool_zero_asset_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::new_pool(
        object::id_from_address(@0x1),
        0,
        30,
        0, // Zero asset
        1000000,
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_new_pool_zero_stable_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::new_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        0, // Zero stable
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::ELowLiquidity)]
fun test_new_pool_below_minimum_liquidity_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Very low liquidity (k < MINIMUM_LIQUIDITY = 1000)
    let pool = conditional_amm::new_pool(
        object::id_from_address(@0x1),
        0,
        30,
        10, // Very small
        10, // Very small (k = 100 < 1000)
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EInvalidFeeRate)]
fun test_new_pool_excessive_fee_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Fee > 100% (10000 basis points)
    let pool = conditional_amm::new_pool(
        object::id_from_address(@0x1),
        0,
        10001, // > 100%
        1000000,
        1000000,
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_reserves() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        5000000,
        3000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 5000000, 0);
    assert!(stable == 3000000, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_lp_supply() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Test pool starts with MINIMUM_LIQUIDITY (1000) in lp_supply
    assert!(conditional_amm::get_lp_supply(&pool) == 1000, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_fee_bps() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        50, // 0.5% fee
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(conditional_amm::get_fee_bps(&pool) == 50, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_outcome_idx() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        5, // outcome 5
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(conditional_amm::get_outcome_idx(&pool) == 5, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_id() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Just verify it returns a valid ID
    let _id = conditional_amm::get_id(&pool);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_k() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        2000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // k = asset * stable = 1000000 * 2000000 = 2000000000000
    let k = conditional_amm::get_k(&pool);
    assert!(k == 2000000000000, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_protocol_fees() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Starts at zero
    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_ms_id() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0xABCD);

    let pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(conditional_amm::get_ms_id(&pool) == market_id, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_current_price() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Equal reserves: 1:1 ratio
    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Price = stable * BASIS_POINTS / asset
    // = 1000000 * 1_000_000_000_000 / 1000000
    // = 1_000_000_000_000
    let price = conditional_amm::get_current_price(&pool);
    assert!(price == 1_000_000_000_000, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_current_price_different_ratio() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // 2:1 ratio (2 stable per 1 asset)
    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        2000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Price = 2000000 * 1_000_000_000_000 / 1000000 = 2_000_000_000_000
    let price = conditional_amm::get_current_price(&pool);
    assert!(price == 2_000_000_000_000, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroLiquidity)]
fun test_get_current_price_zero_asset_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Create pool with valid reserves
    let mut pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Manually drain asset reserve (simulating extreme scenario)
    let (_asset, _stable) = conditional_amm::empty_all_amm_liquidity(
        &mut pool,
        ts::ctx(&mut scenario),
    );

    // Should fail with EZeroLiquidity
    let _price = conditional_amm::get_current_price(&pool);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_check_price_under_max() {
    // Valid price
    conditional_amm::check_price_under_max(1_000_000_000_000);
    conditional_amm::check_price_under_max(1_000_000_000_000_000_000);
}

#[test]
fun test_reset_protocol_fees() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Initially zero
    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 0);

    // Reset should work (keeps it at zero)
    conditional_amm::reset_protocol_fees(&mut pool);
    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_oracle() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Just verify we can get the oracle
    let _oracle = conditional_amm::get_oracle(&pool);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_simple_twap() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Just verify we can get the SimpleTWAP
    let _simple_twap = conditional_amm::get_simple_twap(&pool);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

// === Stage 2: Swap Operations ===

#[test]
fun test_swap_asset_to_stable() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30, // 0.3% fee
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let amount_in = 10000u64;
    let min_out = 0u64;

    let amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        amount_in,
        min_out,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify reserves changed
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset > 1000000, 0); // Asset reserve increased
    assert!(stable < 1000000, 1); // Stable reserve decreased
    assert!(amount_out > 0, 2);

    // Verify protocol fees accumulated (asset_to_stable swap generates asset fees)
    assert!(conditional_amm::get_protocol_fees_asset(&pool) > 0, 3);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_swap_stable_to_asset() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let amount_in = 10000u64;
    let min_out = 0u64;

    let amount_out = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        amount_in,
        min_out,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify reserves changed
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset < 1000000, 0); // Asset reserve decreased
    assert!(stable > 1000000, 1); // Stable reserve increased
    assert!(amount_out > 0, 2);

    // Verify protocol fees accumulated
    assert!(conditional_amm::get_protocol_fees(&pool) > 0, 3);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_swap_asset_to_stable_zero_amount_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let _amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        0, // Zero amount
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EExcessiveSlippage)]
fun test_swap_asset_to_stable_slippage_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Set unreasonably high min_out
    let _amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000,
        999999, // Way too high
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EMarketIdMismatch)]
fun test_swap_wrong_market_id_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let wrong_id = object::id_from_address(@0x2);

    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let _amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        wrong_id, // Wrong market ID
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_swap_preserves_k_invariant() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let k_before = conditional_amm::get_k(&pool);

    // Do a swap
    let _amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let k_after = conditional_amm::get_k(&pool);

    // K should increase due to fees
    assert!(k_after >= k_before, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_quote_swap_asset_to_stable() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let amount_in = 10000u64;
    let quoted = conditional_amm::quote_swap_asset_to_stable(&pool, amount_in);

    // Should return non-zero output
    assert!(quoted > 0, 0);
    // Should be less than amount_in due to fees
    assert!(quoted < amount_in, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_quote_swap_stable_to_asset() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let amount_in = 10000u64;
    let quoted = conditional_amm::quote_swap_stable_to_asset(&pool, amount_in);

    // Should return non-zero output
    assert!(quoted > 0, 0);
    // Should be less than amount_in due to fees
    assert!(quoted < amount_in, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_simulate_swap_asset_to_stable() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let simulated = conditional_amm::simulate_swap_asset_to_stable(&pool, 10000);
    assert!(simulated > 0, 0);

    // Verify pool state unchanged after simulation
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 1000000, 1);
    assert!(stable == 1000000, 2);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_simulate_swap_stable_to_asset() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let simulated = conditional_amm::simulate_swap_stable_to_asset(&pool, 10000);
    assert!(simulated > 0, 0);

    // Verify pool state unchanged
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 1000000, 1);
    assert!(stable == 1000000, 2);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_simulate_zero_amount_returns_zero() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(conditional_amm::simulate_swap_asset_to_stable(&pool, 0) == 0, 0);
    assert!(conditional_amm::simulate_swap_stable_to_asset(&pool, 0) == 0, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_calculate_output() {
    // Simple test: equal reserves, small swap
    // With 1000 in, 1000 out reserves, adding 100 should give ~90 out (with fee)
    let output = conditional_amm::calculate_output(100, 1000, 1000);

    // Output should be less than 100 due to price impact
    assert!(output < 100, 0);
    assert!(output > 0, 1);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EPoolEmpty)]
fun test_calculate_output_zero_reserve_fails() {
    let _output = conditional_amm::calculate_output(100, 0, 1000);
}

#[test]
fun test_swap_increases_protocol_fees() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 0);

    // First swap (asset_to_stable) should generate asset protocol fees
    let _out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let asset_fees_after_first = conditional_amm::get_protocol_fees_asset(&pool);
    assert!(asset_fees_after_first > 0, 1);

    // Second swap (stable_to_asset) should generate stable protocol fees
    let _out2 = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let stable_fees_after_second = conditional_amm::get_protocol_fees_stable(&pool);
    assert!(stable_fees_after_second > 0, 2);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_large_swap_price_impact() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Large swap relative to pool size
    let large_amount = 100000u64; // 10% of pool
    let small_amount = 10000u64; // 1% of pool

    let large_output = conditional_amm::quote_swap_asset_to_stable(&pool, large_amount);
    let small_output = conditional_amm::quote_swap_asset_to_stable(&pool, small_amount);

    // Large swap should have worse rate (more slippage)
    // large_output / large_amount < small_output / small_amount
    let large_rate = (large_output as u128) * 1000000 / (large_amount as u128);
    let small_rate = (small_output as u128) * 1000000 / (small_amount as u128);

    assert!(large_rate < small_rate, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_roundtrip_swap_loses_to_fees() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30, // 0.3% fee each way
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let initial_amount = 10000u64;

    // Swap asset -> stable
    let stable_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        initial_amount,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Swap stable -> asset (reverse)
    let asset_back = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        stable_out,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should get back less than started with (due to fees both ways)
    assert!(asset_back < initial_amount, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

// === Stage 2.5: Feeless Swaps (Arbitrage Helpers) ===

#[test]
fun test_feeless_swap_asset_to_stable() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);
    let k_before = conditional_amm::get_k(&pool);

    let amount_in = 10000u64;
    let amount_out = conditional_amm::feeless_swap_asset_to_stable(
        &mut pool,
        amount_in,
    );

    // Should return non-zero output
    assert!(amount_out > 0, 0);

    // Reserves should have changed
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset > 1000000, 1); // Asset increased
    assert!(stable < 1000000, 2); // Stable decreased

    // K should be approximately preserved (within tolerance)
    let k_after = conditional_amm::get_k(&pool);
    // K should be very close to k_before (within 0.0001% tolerance)
    let k_delta = if (k_after > k_before) { k_after - k_before } else { k_before - k_after };
    let tolerance = k_before / 1000000;
    assert!(k_delta <= tolerance, 3);

    // No protocol fees should be collected (feeless)
    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 4);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_feeless_swap_stable_to_asset() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);
    let k_before = conditional_amm::get_k(&pool);

    let amount_in = 10000u64;
    let amount_out = conditional_amm::feeless_swap_stable_to_asset(
        &mut pool,
        amount_in,
    );

    // Should return non-zero output
    assert!(amount_out > 0, 0);

    // Reserves should have changed
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset < 1000000, 1); // Asset decreased
    assert!(stable > 1000000, 2); // Stable increased

    // K should be approximately preserved (within tolerance)
    let k_after = conditional_amm::get_k(&pool);
    let k_delta = if (k_after > k_before) { k_after - k_before } else { k_before - k_after };
    let tolerance = k_before / 1000000;
    assert!(k_delta <= tolerance, 3);

    // No protocol fees should be collected (feeless)
    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 4);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_feeless_swap_asset_to_stable_zero_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Zero amount should fail
    let _out = conditional_amm::feeless_swap_asset_to_stable(
        &mut pool,
        0,
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_feeless_swap_stable_to_asset_zero_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Zero amount should fail
    let _out = conditional_amm::feeless_swap_stable_to_asset(
        &mut pool,
        0,
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EPoolEmpty)]
fun test_feeless_swap_empty_pool_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Empty the pool
    let (_asset, _stable) = conditional_amm::empty_all_amm_liquidity(
        &mut pool,
        ts::ctx(&mut scenario),
    );

    // Swap should fail on empty pool
    let _out = conditional_amm::feeless_swap_asset_to_stable(
        &mut pool,
        10000,
    );

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_feeless_vs_normal_swap_output() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Create two identical pools
    let mut pool1 = create_test_pool(&mut scenario, &mut clock);
    let market_id = object::id_from_address(@0x1);
    let mut pool2 = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let amount_in = 10000u64;

    // Feeless swap should give more output than normal swap
    let feeless_out = conditional_amm::feeless_swap_asset_to_stable(
        &mut pool1,
        amount_in,
    );

    let normal_out = conditional_amm::swap_asset_to_stable(
        &mut pool2,
        market_id,
        amount_in,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Feeless swap gives more output (no fees deducted)
    assert!(feeless_out > normal_out, 0);

    conditional_amm::destroy_for_testing(pool1);
    conditional_amm::destroy_for_testing(pool2);
    end(scenario, clock);
}

#[test]
fun test_feeless_swap_roundtrip() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    let initial_amount = 10000u64;
    let k_initial = conditional_amm::get_k(&pool);

    // Swap asset -> stable
    let stable_out = conditional_amm::feeless_swap_asset_to_stable(
        &mut pool,
        initial_amount,
    );

    // Swap stable -> asset (reverse)
    let asset_back = conditional_amm::feeless_swap_stable_to_asset(
        &mut pool,
        stable_out,
    );

    // Should get back approximately the same amount (within rounding)
    // Allow small difference due to rounding in integer math
    let diff = if (asset_back > initial_amount) {
        asset_back - initial_amount
    } else {
        initial_amount - asset_back
    };

    // Difference should be very small (< 1%)
    assert!(diff < initial_amount / 100, 0);

    // K should be approximately the same
    let k_final = conditional_amm::get_k(&pool);
    let k_delta = if (k_final > k_initial) { k_final - k_initial } else { k_initial - k_final };
    let tolerance = k_initial / 1000000;
    assert!(k_delta <= tolerance, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

// === Stage 3: Liquidity Operations ===

#[test]
fun test_add_liquidity_first_provider() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Create an empty pool with zero lp_supply to test first provider logic
    let market_id = object::id_from_address(@0xABCD);
    let outcome_idx = 0;
    let fee_percent = 30;

    let mut pool = conditional_amm::new_pool(
        market_id,
        outcome_idx,
        fee_percent,
        1000000,
        1000000,
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // First provider adds liquidity
    let asset_amount = 1000000;
    let stable_amount = 1000000;
    let min_lp_out = 0;

    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        asset_amount,
        stable_amount,
        min_lp_out,
        &clock,
        ts::ctx(&mut scenario),
    );

    // First provider gets sqrt(k) - MINIMUM_LIQUIDITY tokens
    // k = 1000000 * 1000000 = 1e12
    // sqrt(1e12) = 1e6
    // lp_minted = 1e6 - 1000 = 999000
    assert!(lp_minted == 999000, 0);

    // Total LP supply should be sqrt(k) = 1000000
    assert!(conditional_amm::get_lp_supply(&pool) == 1000000, 1);

    // Reserves should be doubled (initial 1M + added 1M)
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 2000000, 2);
    assert!(stable == 2000000, 3);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::ELowLiquidity)]
fun test_add_liquidity_first_provider_low_liquidity_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0xABCD);
    let outcome_idx = 0;
    let fee_percent = 30;

    let mut pool = conditional_amm::new_pool(
        market_id,
        outcome_idx,
        fee_percent,
        100,
        100, // Very low liquidity for initial pool
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to add very low liquidity
    // sqrt(100 * 100) = 100, which is < MINIMUM_LIQUIDITY (1000)
    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100,
        100,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with ELowLiquidity
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_add_liquidity_subsequent_provider() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);
    let market_id = conditional_amm::get_ms_id(&pool);

    // Initial state: 1M asset, 1M stable, 1000 LP supply (from create_test_pool)
    let k_before = conditional_amm::get_k(&pool);

    // Second provider adds proportional liquidity (10%% of pool)
    let asset_amount = 100000; // 10%% of 1M
    let stable_amount = 100000; // 10%% of 1M

    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        asset_amount,
        stable_amount,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // LP tokens should be proportional: 10%% of 1000 = 100
    assert!(lp_minted == 100, 0);

    // Total LP supply increased by 100
    assert!(conditional_amm::get_lp_supply(&pool) == 1100, 1);

    // Reserves increased by 10%%
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 1100000, 2);
    assert!(stable == 1100000, 3);

    // K should have increased
    let k_after = conditional_amm::get_k(&pool);
    assert!(k_after > k_before, 4);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EImbalancedLiquidity)]
fun test_add_liquidity_imbalanced_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Try to add highly imbalanced liquidity
    // 100k asset but only 1k stable = 99%% imbalance (way over 1%% tolerance)
    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100000,
        1000, // Massive imbalance
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with EImbalancedLiquidity
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EExcessiveSlippage)]
fun test_add_liquidity_slippage_protection() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Add liquidity but set unrealistic min_lp_out
    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100000,
        100000,
        1000000, // Expect way more LP tokens than possible
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with EExcessiveSlippage
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_add_liquidity_zero_amount_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Try to add zero liquidity
    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        0, // Zero amount
        100000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with EZeroAmount
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_add_liquidity_k_invariant_increases() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    let k_before = conditional_amm::get_k(&pool);

    // Add liquidity
    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100000,
        100000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let k_after = conditional_amm::get_k(&pool);

    // K must strictly increase when adding liquidity
    assert!(k_after > k_before, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_remove_liquidity_proportional() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Initial state: 1M asset, 1M stable, 1000 LP supply
    let initial_lp_supply = conditional_amm::get_lp_supply(&pool);
    let k_before = conditional_amm::get_k(&pool);

    // Remove 10%% of liquidity
    let lp_to_burn = 100;
    let (asset_removed, stable_removed) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        lp_to_burn,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should remove 10%% of reserves
    // 10%% of 1M = 100k
    assert!(asset_removed == 100000, 0);
    assert!(stable_removed == 100000, 1);

    // LP supply decreased
    assert!(conditional_amm::get_lp_supply(&pool) == initial_lp_supply - lp_to_burn, 2);

    // Reserves decreased
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 900000, 3);
    assert!(stable == 900000, 4);

    // K should have decreased
    let k_after = conditional_amm::get_k(&pool);
    assert!(k_after < k_before, 5);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::ELowLiquidity)]
fun test_remove_liquidity_below_minimum_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Create a much smaller pool: 2000 reserves, 1000 LP supply
    // Removing 999 LP will leave 2 asset, 2 stable
    // Remaining k = 2 * 2 = 4 < MINIMUM_LIQUIDITY (1000)
    let mut pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        2000, // Small reserves
        2000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to remove almost all liquidity (leaving k < MINIMUM_LIQUIDITY)
    // LP supply is 1000, removing 999 leaves only 1 LP = 2 reserves each
    // k = 2 * 2 = 4 << MINIMUM_LIQUIDITY (1000)
    let (asset_removed, stable_removed) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        999, // Remove 99.9%% of liquidity
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with ELowLiquidity because remaining k < MINIMUM_LIQUIDITY
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EZeroAmount)]
fun test_remove_liquidity_zero_amount_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Try to remove zero liquidity
    let (asset_removed, stable_removed) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        0, // Zero amount
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with EZeroAmount
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EPoolEmpty)]
fun test_remove_liquidity_more_than_supply_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    let lp_supply = conditional_amm::get_lp_supply(&pool);

    // Try to remove more LP tokens than exist
    // This fails with EPoolEmpty because proportional calculation tries to remove
    // more reserves than exist: (lp_supply+1) * reserves / lp_supply > reserves
    let (asset_removed, stable_removed) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        lp_supply + 1, // More than total supply
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail with EPoolEmpty (checked before EInsufficientLPTokens)
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_remove_liquidity_k_invariant_decreases() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    let k_before = conditional_amm::get_k(&pool);

    // Remove liquidity
    let (asset_removed, stable_removed) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        100, // Remove 10%%
        &clock,
        ts::ctx(&mut scenario),
    );

    let k_after = conditional_amm::get_k(&pool);

    // K must strictly decrease when removing liquidity
    assert!(k_after < k_before, 0);

    // But k should still be above minimum
    assert!(k_after >= 1000, 1); // MINIMUM_LIQUIDITY = 1000

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_empty_all_amm_liquidity() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Get initial reserves
    let (initial_asset, initial_stable) = conditional_amm::get_reserves(&pool);

    // Empty all liquidity
    let (asset_out, stable_out) = conditional_amm::empty_all_amm_liquidity(
        &mut pool,
        ts::ctx(&mut scenario),
    );

    // Should return all reserves
    assert!(asset_out == initial_asset, 0);
    assert!(stable_out == initial_stable, 1);

    // Reserves should be zero
    let (final_asset, final_stable) = conditional_amm::get_reserves(&pool);
    assert!(final_asset == 0, 2);
    assert!(final_stable == 0, 3);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

fun create_test_pool(
    scenario: &mut ts::Scenario,
    clock: &mut Clock,
): conditional_amm::LiquidityPool {
    conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000000,
        1000000,
        clock,
        ts::ctx(scenario),
    )
}

// === Stage 4: Oracle & TWAP ===

#[test]
fun test_update_twap_observation() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Initial price recorded
    let initial_price = conditional_amm::get_current_price(&pool);

    // Update TWAP observation
    conditional_amm::update_twap_observation(&mut pool, &clock);

    // Price should still be the same
    let new_price = conditional_amm::get_current_price(&pool);
    assert!(new_price == initial_price, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_twap_after_swap() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Do a swap to change the price
    let _amount_out = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        100000, // Large swap to change price significantly
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance time
    clock.set_for_testing(2000);

    // Get TWAP (should reflect the price change)
    let twap = conditional_amm::get_twap(&mut pool, &clock);
    assert!(twap > 0, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_set_oracle_start_time() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);

    // Use new_pool instead of create_test_pool to avoid pre-initialized oracle
    let mut pool = conditional_amm::new_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        1_000_000_000_000,
        0,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Set oracle start time (oracle not yet initialized in new_pool)
    let trading_start_time = 5000u64;
    conditional_amm::set_oracle_start_time(&mut pool, market_id, trading_start_time);

    // Oracle should be set (no way to verify directly, but shouldn't fail)
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = conditional_amm::EMarketIdMismatch)]
fun test_set_oracle_start_time_wrong_market_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let wrong_id = object::id_from_address(@0x2);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to set oracle start time with wrong market ID
    conditional_amm::set_oracle_start_time(&mut pool, wrong_id, 5000);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_oracle_updates_on_swap() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let price_before = conditional_amm::get_current_price(&pool);

    // Swap should update oracle
    let _amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let price_after = conditional_amm::get_current_price(&pool);

    // Price should have changed
    assert!(price_after != price_before, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_multiple_swaps_update_twap() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Do multiple swaps over time
    let _out1 = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(2000);

    let _out2 = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        5000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(3000);

    let _out3 = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        8000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(4000);

    // Get TWAP - should be time-weighted average of all prices
    let twap = conditional_amm::get_twap(&mut pool, &clock);
    assert!(twap > 0, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_oracle_reference() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = create_test_pool(&mut scenario, &mut clock);

    // Get oracle reference
    let _oracle = conditional_amm::get_oracle(&pool);

    // Should not fail
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_get_simple_twap_reference() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let pool = create_test_pool(&mut scenario, &mut clock);

    // Get SimpleTWAP reference
    let _simple_twap = conditional_amm::get_simple_twap(&pool);

    // Should not fail
    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_liquidity_changes_update_twap() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    let price_before = conditional_amm::get_current_price(&pool);

    // Add liquidity (should update TWAP)
    let _lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100000,
        100000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Price should remain same (proportional liquidity)
    let price_after_add = conditional_amm::get_current_price(&pool);
    assert!(price_after_add == price_before, 0);

    // Remove liquidity (should update TWAP)
    let (_asset, _stable) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        50,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Price should still be same (proportional removal)
    let price_after_remove = conditional_amm::get_current_price(&pool);
    assert!(price_after_remove == price_before, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_twap_time_weighted() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Price at t=1000
    let initial_price = conditional_amm::get_current_price(&pool);

    // Large swap to significantly change price
    let _out = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        200000, // 20%% of pool
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let new_price = conditional_amm::get_current_price(&pool);

    // Price should have changed significantly
    assert!(new_price != initial_price, 0);

    // Wait a long time
    clock.set_for_testing(10000);

    // TWAP should be somewhere between initial and new price
    // (time-weighted, so closer to new price since it lasted longer)
    let twap = conditional_amm::get_twap(&mut pool, &clock);
    assert!(twap > 0, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

// === Stage 6: Edge Cases & Extreme Scenarios ===

#[test]
fun test_swap_very_large_amount() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to swap 50% of pool (very large)
    let large_amount = 500000u64;
    let amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        large_amount,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should work but with high slippage
    assert!(amount_out > 0, 0);
    assert!(amount_out < large_amount, 1); // High slippage

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_extreme_price_ratio() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Create pool with 100:1 price ratio
    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        10000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Price should be 100x higher
    let price = conditional_amm::get_current_price(&pool);
    assert!(price > 50_000_000_000_000, 0); // Much higher than 1:1

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_minimum_liquidity_boundary() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    // Create pool with exactly minimum liquidity (sqrt(k) = 1000)
    // k = 1,000,000, so asset = stable = 1000
    let pool = conditional_amm::create_test_pool(
        object::id_from_address(@0x1),
        0,
        30,
        1000,
        1000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let k = conditional_amm::get_k(&pool);
    assert!(k == 1000000, 0); // k = 1000 * 1000

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_tiny_swap_amount() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Swap just 1 unit (minimal amount)
    let amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        1,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should still work (may be 0 due to fees)
    assert!(amount_out == 0, 0); // Fee might consume entire amount

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_precision_rounding() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    // Multiple small swaps to test rounding
    let k_initial = conditional_amm::get_k(&pool);

    // Do 10 tiny swaps
    let market_id = object::id_from_address(@0x1);
    let mut i = 0;
    while (i < 10) {
        let _out = conditional_amm::swap_asset_to_stable(
            &mut pool,
            market_id,
            100,
            0,
            &clock,
            ts::ctx(&mut scenario),
        );
        i = i + 1;
    };

    // K should have grown due to fees
    let k_after = conditional_amm::get_k(&pool);
    assert!(k_after > k_initial, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_alternating_swaps() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    let initial_price = conditional_amm::get_current_price(&pool);

    // Alternate between buying and selling
    let _out1 = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );
    let _out2 = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );
    let _out3 = conditional_amm::swap_stable_to_asset(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );
    let _out4 = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    let final_price = conditional_amm::get_current_price(&pool);

    // Price may have moved slightly but should be relatively close
    let price_diff = if (final_price > initial_price) {
        final_price - initial_price
    } else {
        initial_price - final_price
    };

    // Allow up to 10% price movement
    assert!(price_diff < initial_price / 10, 0);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_liquidity_add_remove_cycle() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut pool = create_test_pool(&mut scenario, &mut clock);

    let (initial_asset, initial_stable) = conditional_amm::get_reserves(&pool);
    let initial_lp = conditional_amm::get_lp_supply(&pool);

    // Add liquidity
    let lp_minted = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100000,
        100000,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Remove the same amount
    let (asset_removed, stable_removed) = conditional_amm::remove_liquidity_proportional(
        &mut pool,
        lp_minted,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should get back similar amounts (within rounding)
    assert!(asset_removed >= 99000 && asset_removed <= 101000, 0);
    assert!(stable_removed >= 99000 && stable_removed <= 101000, 1);

    // LP supply should be back to initial
    assert!(conditional_amm::get_lp_supply(&pool) == initial_lp, 2);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_swap_huge_amount_never_empties_reserve() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to swap way more than the reserve
    // Due to constant product formula, this should never empty the reserve
    let amount_out = conditional_amm::swap_asset_to_stable(
        &mut pool,
        market_id,
        10000000, // 10x the reserve
        0,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should get close to the entire reserve, but never all of it
    let (_, stable) = conditional_amm::get_reserves(&pool);
    assert!(stable > 0, 0); // Reserve should never be completely empty
    assert!(amount_out < 1000000, 1); // Should be less than initial reserve

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}

#[test]
fun test_fee_accumulation_over_many_swaps() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let mut pool = conditional_amm::create_test_pool(
        market_id,
        0,
        30, // 0.3% fee
        1000000,
        1000000,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(conditional_amm::get_protocol_fees(&pool) == 0, 0);

    // Do 100 small swaps
    let mut i = 0;
    while (i < 100) {
        let _out = conditional_amm::swap_asset_to_stable(
            &mut pool,
            market_id,
            1000,
            0,
            &clock,
            ts::ctx(&mut scenario),
        );
        i = i + 1;
    };

    // Protocol fees should have accumulated significantly (asset_to_stable generates asset fees)
    let fees = conditional_amm::get_protocol_fees_asset(&pool);
    assert!(fees > 0, 1);

    conditional_amm::destroy_for_testing(pool);
    end(scenario, clock);
}
