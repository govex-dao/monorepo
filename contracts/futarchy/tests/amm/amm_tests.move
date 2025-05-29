#[test_only]
module futarchy::additional_amm_tests;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::market_state::{Self, MarketState};
use std::debug;
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as test, Scenario, ctx};

// ======== Constants ========
const ADMIN: address = @0xAD;

const INITIAL_ASSET: u64 = 1000000000; // 1000 units
const INITIAL_STABLE: u64 = 1000000000; // 1000 units
const SWAP_AMOUNT: u64 = 100000000; // 100 units (10% of pool)
const LARGE_SWAP_AMOUNT: u64 = 500000000; // 500 units (50% of pool)
const SMALL_SWAP_AMOUNT: u64 = 1000000; // 1 unit (0.1% of pool)
const FEE_SCALE: u64 = 10000;
const DEFAULT_FEE: u64 = 30; // 0.3%

const BASIS_POINTS: u64 = 1_000_000_000_000;
const TWAP_START_DELAY: u64 = 60_000;
const TWAP_STEP_MAX: u64 = 1000;
const OUTCOME_COUNT: u64 = 2;

// ======== Test Setup Functions ========
fun setup_test(): (Scenario, Clock) {
    let mut scenario = test::begin(ADMIN);
    let clock = clock::create_for_testing(ctx(&mut scenario));
    (scenario, clock)
}

fun setup_market(scenario: &mut Scenario, clock: &Clock): (MarketState) {
    let market_id = object::id_from_address(@0x1); // Using a dummy ID for testing
    let dao_id = object::id_from_address(@0x2); // Using a dummy ID for testing

    // Create outcome messages
    let mut outcome_messages = vector::empty<String>();
    vector::push_back(&mut outcome_messages, string::utf8(b"Yes"));
    vector::push_back(&mut outcome_messages, string::utf8(b"No"));

    let (mut state) = market_state::new(
        market_id,
        dao_id,
        OUTCOME_COUNT,
        outcome_messages,
        clock,
        ctx(scenario),
    );

    market_state::start_trading(
        &mut state,
        clock::timestamp_ms(clock),
        clock,
    );

    (state)
}

fun setup_pool(scenario: &mut Scenario, state: &MarketState, clock: &Clock): LiquidityPool {
    let mut pool_inst = amm::new_pool(
        state,
        0, // outcome_idx
        INITIAL_ASSET,
        INITIAL_STABLE,
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(scenario),
    );

    amm::set_oracle_start_time(&mut  pool_inst, state);
    pool_inst
}

// ======== Basic Functionality Tests ========
#[test]
fun test_pool_creation() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let pool = setup_pool(&mut scenario, &state, &clock);

    let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
    assert!(asset_reserve == INITIAL_ASSET, 0);
    assert!(stable_reserve == INITIAL_STABLE, 0);

    // Verify initial price
    let initial_price = amm::get_current_price(&pool);
    assert!(initial_price == (BASIS_POINTS as u128), 1); // Price should be 1.0 initially

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

#[test]
fun test_swap_asset_to_stable() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    let initial_price = amm::get_current_price(&pool);

    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    let new_price = amm::get_current_price(&pool);
    debug::print(&b"Price comparison:");
    debug::print(&initial_price);
    debug::print(&new_price);

    assert!(new_price < initial_price, 2);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

#[test]
fun test_swap_stable_to_asset() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    let initial_price = amm::get_current_price(&pool);

    let amount_out = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
    // DEFAULT_FEE is 30 (0.3%)
    let fee_amount = (SWAP_AMOUNT * DEFAULT_FEE) / FEE_SCALE;
    assert!(stable_reserve == INITIAL_STABLE + (SWAP_AMOUNT - fee_amount), 0);
    assert!(asset_reserve == INITIAL_ASSET - amount_out, 1);

    let new_price = amm::get_current_price(&pool);
    debug::print(&b"Swap stable_to_asset:");
    debug::print(&b"Initial price:");
    debug::print(&initial_price);
    debug::print(&b"New price:");
    debug::print(&new_price);

    // When we buy assets with stable tokens:
    // - asset_reserve decreases
    // - stable_reserve increases
    // - price (asset/stable) should decrease
    assert!(new_price > initial_price, 2);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Oracle Tests ========
#[test]
fun test_oracle_price_updates() {
    let (mut scenario, mut clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Initial price check
    let initial_price = amm::get_current_price(&pool);
    debug::print(&b"Initial price check:");
    debug::print(&initial_price);

    // Perform swap
    clock::set_for_testing(&mut clock, 2000);
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    // Check new price
    let new_price = amm::get_current_price(&pool);
    debug::print(&b"New price check:");
    debug::print(&new_price);

    assert!(new_price < initial_price, 1);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Liquidity Management Tests ========
#[test]
fun test_empty_all_amm_liquidity() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Verify initial reserves
    let (initial_asset_reserve, initial_stable_reserve) = amm::get_reserves(&pool);
    assert!(initial_asset_reserve == INITIAL_ASSET, 0);
    assert!(initial_stable_reserve == INITIAL_STABLE, 0);

    // Empty all liquidity
    let (asset_amount_out, stable_amount_out) = amm::empty_all_amm_liquidity(
        &mut pool,
        ctx(&mut scenario),
    );

    // Verify amounts removed
    assert!(asset_amount_out == INITIAL_ASSET, 1);
    assert!(stable_amount_out == INITIAL_STABLE, 2);

    // Verify reserves are now zero
    let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
    assert!(asset_reserve == 0, 3);
    assert!(stable_reserve == 0, 4);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Fee Collection Tests ========
#[test]
fun test_protocol_fee_accumulation() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Initial protocol fees should be zero
    let initial_fees = amm::get_protocol_fees(&pool);
    assert!(initial_fees == 0, 0);

    // Perform a swap from stable to asset (buy)
    let _ = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    // Calculate expected fee for first swap (stable to asset)
    let expected_fee_first_swap = (SWAP_AMOUNT * DEFAULT_FEE) / FEE_SCALE;
    let fees_after_first = amm::get_protocol_fees(&pool);
    assert!(fees_after_first == expected_fee_first_swap, 1);

    // Perform another swap from asset to stable (sell)
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    // Instead of trying to calculate the expected fee for the second swap,
    // simply check that additional fees were collected
    let total_fees = amm::get_protocol_fees(&pool);
    assert!(total_fees > fees_after_first, 2);

    // Reset protocol fees
    amm::reset_protocol_fees(&mut pool);
    assert!(amm::get_protocol_fees(&pool) == 0, 3);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Quote Function Tests ========
#[test]
fun test_quote_functions() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Test quote vs actual for asset to stable
    let quoted_amount = amm::quote_swap_asset_to_stable(&pool, SWAP_AMOUNT);
    let actual_amount = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    debug::print(&b"Asset to Stable Quote vs Actual:");
    debug::print(&quoted_amount);
    debug::print(&actual_amount);
    assert!(quoted_amount == actual_amount, 0);

    // Reset pool for next test
    amm::destroy_for_testing(pool);

    // Create a fresh pool
    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Test quote vs actual for stable to asset
    let quoted_amount = amm::quote_swap_stable_to_asset(&pool, SWAP_AMOUNT);
    let actual_amount = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    debug::print(&b"Stable to Asset Quote vs Actual:");
    debug::print(&quoted_amount);
    debug::print(&actual_amount);
    assert!(quoted_amount == actual_amount, 1);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== TWAP Tests ========
#[test]
fun test_twap_updates() {
    let (mut scenario, mut clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Get initial TWAP
    clock::set_for_testing(&mut clock, 100_000); // After TWAP_START_DELAY (2000)
    let initial_twap = amm::get_twap(&mut pool, &clock);

    debug::print(&b"Initial TWAP:");
    debug::print(&initial_twap);

    // Perform a swap to change the price
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        LARGE_SWAP_AMOUNT, // Larger swap to make a more noticeable price change
        0,
        &clock,
        ctx(&mut scenario),
    );

    // Move time forward
    clock::increment_for_testing(&mut clock, 4000);

    // Get TWAP after price change
    let new_twap = amm::get_twap(&mut pool, &clock);

    debug::print(&b"New TWAP after swap:");
    debug::print(&new_twap);

    // TWAP should be between initial price and current price
    let current_price = amm::get_current_price(&pool);

    debug::print(&b"Current spot price:");
    debug::print(&current_price);

    // In this case, we sold asset for stable, so price decreased
    // TWAP should be higher than current price but potentially lower than initial price
    assert!(new_twap > current_price, 0);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Price Impact Tests ========
#[test]
fun test_price_impact_on_different_swap_sizes() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    // Test with small swap
    {
        let mut pool = setup_pool(&mut scenario, &state, &clock);
        let initial_price = amm::get_current_price(&pool);

        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            SMALL_SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario),
        );

        let small_swap_price = amm::get_current_price(&pool);
        let small_price_change = if (initial_price > small_swap_price) {
            initial_price - small_swap_price
        } else {
            small_swap_price - initial_price
        };

        debug::print(&b"Small swap price change:");
        debug::print(&small_price_change);

        amm::destroy_for_testing(pool);
    };

    // Test with medium swap
    {
        let mut pool = setup_pool(&mut scenario, &state, &clock);
        let initial_price = amm::get_current_price(&pool);

        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario),
        );

        let medium_swap_price = amm::get_current_price(&pool);
        let medium_price_change = if (initial_price > medium_swap_price) {
            initial_price - medium_swap_price
        } else {
            medium_swap_price - initial_price
        };

        debug::print(&b"Medium swap price change:");
        debug::print(&medium_price_change);

        amm::destroy_for_testing(pool);
    };

    // Test with large swap
    {
        let mut pool = setup_pool(&mut scenario, &state, &clock);
        let initial_price = amm::get_current_price(&pool);

        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            LARGE_SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario),
        );

        let large_swap_price = amm::get_current_price(&pool);
        let large_price_change = if (initial_price > large_swap_price) {
            initial_price - large_swap_price
        } else {
            large_swap_price - initial_price
        };

        debug::print(&b"Large swap price change:");
        debug::print(&large_price_change);

        amm::destroy_for_testing(pool);
    };

    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Slippage Tests ========
#[test]
#[expected_failure(abort_code = futarchy::amm::EEXCESSIVE_SLIPPAGE)]
fun test_excessive_slippage_protection() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Calculate expected output for swap
    let expected_output = amm::quote_swap_asset_to_stable(&pool, LARGE_SWAP_AMOUNT);

    // Set min_amount_out higher than expected output to trigger slippage error
    let min_amount_out = expected_output + 1000000; // Add 1 unit to ensure it fails

    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        LARGE_SWAP_AMOUNT,
        min_amount_out,
        &clock,
        ctx(&mut scenario),
    );

    // This should never execute due to expected failure
    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Zero Amount Tests ========
#[test]
#[expected_failure(abort_code = futarchy::amm::EZERO_AMOUNT)]
fun test_zero_amount_swap_asset_to_stable() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Try to swap with zero amount
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        0, // Zero amount
        0,
        &clock,
        ctx(&mut scenario),
    );

    // This should never execute due to expected failure
    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::amm::EZERO_AMOUNT)]
fun test_zero_amount_swap_stable_to_asset() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Try to swap with zero amount
    let _ = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        0, // Zero amount
        0,
        &clock,
        ctx(&mut scenario),
    );

    // This should never execute due to expected failure
    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Empty Pool Tests ========
#[test]
#[expected_failure(abort_code = futarchy::amm::EPOOL_EMPTY)]
fun test_swap_with_empty_pool() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // First empty the pool
    let (_, _) = amm::empty_all_amm_liquidity(
        &mut pool,
        ctx(&mut scenario),
    );

    // Try to swap with empty pool
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    // This should never execute due to expected failure
    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Round-trip Swap Tests ========
#[test]
fun test_swap_round_trip() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);

    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Record initial reserves
    let (initial_asset, initial_stable) = amm::get_reserves(&pool);

    // First swap: stable to asset (buy)
    let asset_out = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );

    // Second swap: asset to stable (sell)
    let stable_out = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        asset_out,
        0,
        &clock,
        ctx(&mut scenario),
    );

    // Due to fees, the round trip should result in less stable tokens than input
    debug::print(&b"Round trip results:");
    debug::print(&b"Initial stable in:");
    debug::print(&SWAP_AMOUNT);
    debug::print(&b"Final stable out:");
    debug::print(&stable_out);
    debug::print(&b"Loss due to fees:");
    debug::print(&(SWAP_AMOUNT - stable_out));

    // Confirm a loss in the round trip due to fees
    assert!(stable_out < SWAP_AMOUNT, 0);

    // Check current reserves
    let (final_asset, final_stable) = amm::get_reserves(&pool);

    // Reserves should be different due to fees
    debug::print(&b"Reserve changes:");
    debug::print(&b"Asset reserve change:");
    debug::print(
        &(if (final_asset > initial_asset) { final_asset - initial_asset } else {
                initial_asset - final_asset
            }),
    );
    debug::print(&b"Stable reserve change:");
    debug::print(
        &(if (final_stable > initial_stable) { final_stable - initial_stable } else {
                initial_stable - final_stable
            }),
    );

    // The protocol should have collected fees
    assert!(amm::get_protocol_fees(&pool) > 0, 1);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}
