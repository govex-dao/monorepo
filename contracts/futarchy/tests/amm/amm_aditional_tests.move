#[test_only]
module futarchy::amm_additional_tests;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::market_state::{Self, MarketState};
use futarchy::math;
use std::debug;
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as test, Scenario, ctx};
use sui::object::{Self, ID, UID};

// ======== Constants ========
const ADMIN: address = @0xAD;

const INITIAL_ASSET: u64 = 1000000000; // 1000 units
const INITIAL_STABLE: u64 = 1000000000; // 1000 units
const SWAP_AMOUNT: u64 = 100000000; // 100 units (10% of pool)
const LARGE_SWAP_AMOUNT: u64 = 500000000; // 500 units (50% of pool)
const SMALL_SWAP_AMOUNT: u64 = 1000000; // 1 unit (0.1% of pool)
const VERY_SMALL_SWAP_AMOUNT: u64 = 100; // 0.0001 units (testing fee rounding)
const VERY_LARGE_SWAP_AMOUNT: u64 = 900000000; // 900 units (90% of pool - extreme slippage)
const FEE_SCALE: u64 = 10000;
const DEFAULT_FEE: u64 = 30; // 0.3%

const BASIS_POINTS: u64 = 1_000_000_000_000;
const TWAP_START_DELAY: u64 = 60_000;
const TWAP_STEP_MAX: u64 = 1000;
const OUTCOME_COUNT: u64 = 2;

// ======== Test Setup Functions ========
// Reusing the setup functions from additional_amm_tests
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
    amm::new_pool(
        state,
        0, // outcome_idx
        INITIAL_ASSET,
        INITIAL_STABLE,
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(scenario),
    )
}

// ======== K-Invariant Tests ========
#[test]
fun test_k_invariant_maintenance() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Get initial k value
    let (initial_asset, initial_stable) = amm::get_reserves(&pool);
    let initial_k = math::mul_div_to_128(initial_asset, initial_stable, 1);
    
    // Perform swap (asset to stable)
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );
    
    // Check k value after swap
    let (asset_reserve_1, stable_reserve_1) = amm::get_reserves(&pool);
    let k_after_swap_1 = math::mul_div_to_128(asset_reserve_1, stable_reserve_1, 1);
    
    // The k value should be maintained (or slightly higher due to fees)
    // Fees are collected outside the pool, so k should be maintained
    debug::print(&b"Initial k:");
    debug::print(&initial_k);
    debug::print(&b"K after swap 1:");
    debug::print(&k_after_swap_1);
    
    // Check if k is maintained (allowing for some minimal rounding errors)
    // The relative difference should be extremely small (< 0.001%)
    assert!(initial_k <= k_after_swap_1, 0); // K should never decrease
    let k_diff = k_after_swap_1 - initial_k; // Fixed subtraction order
    let k_diff_percent = math::mul_div_to_128((k_diff as u64), 10000000, (initial_k as u64)); // Diff in 0.0001%
    debug::print(&b"K difference percent (in 0.0001%):");
    debug::print(&k_diff_percent);
    assert!(k_diff_percent < 10, 1); // Difference should be < 0.001%
    
    // Perform another swap (stable to asset)
    let _ = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );
    
    // Check k value again
    let (asset_reserve_2, stable_reserve_2) = amm::get_reserves(&pool);
    let k_after_swap_2 = math::mul_div_to_128(asset_reserve_2, stable_reserve_2, 1);
    
    debug::print(&b"K after swap 2:");
    debug::print(&k_after_swap_2);
    
    // Verify k is maintained after second swap
    assert!(k_after_swap_1 <= k_after_swap_2, 2); // K should never decrease
    let k_diff_2 = k_after_swap_2 - k_after_swap_1; // Fixed subtraction order
    let k_diff_percent_2 = math::mul_div_to_128((k_diff_2 as u64), 10000000, (k_after_swap_1 as u64));
    debug::print(&b"K difference percent after second swap (in 0.0001%):");
    debug::print(&k_diff_percent_2);
    assert!(k_diff_percent_2 < 10, 3); // Difference should be < 0.001%

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Fee Calculation Edge Cases ========
#[test]
fun test_fee_calculation_edge_cases() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let mut pool = setup_pool(&mut scenario, &state, &clock);

    // Initial protocol fees should be zero
    let initial_fees = amm::get_protocol_fees(&pool);
    assert!(initial_fees == 0, 0);

    // Test with very small amount (testing fee rounding)
    // For tiny amounts, fee should be at least 1 (per calculate_fee implementation)
    let _ = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        VERY_SMALL_SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );
    
    let fees_after_small_swap = amm::get_protocol_fees(&pool);
    debug::print(&b"Fees after very small swap:");
    debug::print(&fees_after_small_swap);
    
    // Even for tiny amounts, fee should be at least 1
    assert!(fees_after_small_swap >= 1, 1);
    
    // Reset fees
    amm::reset_protocol_fees(&mut pool);
    
    // Test with large amount
    let _ = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        LARGE_SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );
    
    let fees_after_large_swap = amm::get_protocol_fees(&pool);
    let expected_large_fee = (LARGE_SWAP_AMOUNT * DEFAULT_FEE) / FEE_SCALE;
    
    debug::print(&b"Fees after large swap:");
    debug::print(&fees_after_large_swap);
    debug::print(&b"Expected fee for large swap:");
    debug::print(&expected_large_fee);
    
    assert!(fees_after_large_swap == expected_large_fee, 2);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Price Calculation Tests ========
#[test]
fun test_price_calculation_accuracy() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    
    // Test price with 1:1 ratio (equal reserves)
    {
        let pool = setup_pool(&mut scenario, &state, &clock);
        let price = amm::get_current_price(&pool);
        debug::print(&b"Price with 1:1 ratio (should be 1.0 * BASIS_POINTS):");
        debug::print(&price);
        assert!(price == (BASIS_POINTS as u128), 0);
        amm::destroy_for_testing(pool);
    };
    
    // Test price with 2:1 ratio (more asset than stable)
    {
        let pool = amm::new_pool(
            &state,
            0,
            INITIAL_ASSET * 2, // Double asset
            INITIAL_STABLE,
            (BASIS_POINTS as u128),
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            ctx(&mut scenario),
        );
        
        let price = amm::get_current_price(&pool);
        let expected_price = (BASIS_POINTS as u128) / 2; // Should be 0.5 * BASIS_POINTS
        
        debug::print(&b"Price with 2:1 asset:stable ratio:");
        debug::print(&price);
        debug::print(&b"Expected price (0.5 * BASIS_POINTS):");
        debug::print(&expected_price);
        
        assert!(price == expected_price, 1);
        amm::destroy_for_testing(pool);
    };
    
    // Test price with 1:2 ratio (more stable than asset)
    {
        let pool = amm::new_pool(
            &state,
            0,
            INITIAL_ASSET,
            INITIAL_STABLE * 2, // Double stable
            (BASIS_POINTS as u128),
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            ctx(&mut scenario),
        );
        
        let price = amm::get_current_price(&pool);
        let expected_price = (BASIS_POINTS as u128) * 2; // Should be 2.0 * BASIS_POINTS
        
        debug::print(&b"Price with 1:2 asset:stable ratio:");
        debug::print(&price);
        debug::print(&b"Expected price (2.0 * BASIS_POINTS):");
        debug::print(&expected_price);
        
        assert!(price == expected_price, 2);
        amm::destroy_for_testing(pool);
    };

    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Output Calculation Tests ========
#[test]
fun test_output_calculation() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let pool = setup_pool(&mut scenario, &state, &clock);

    // Test calculate_output function directly
    // Formula: dx * y / (x + dx)
    
    // Case 1: Small swap
    let small_output = amm::calculate_output(
        SMALL_SWAP_AMOUNT,
        INITIAL_ASSET,
        INITIAL_STABLE
    );
    
    // Manual calculation for verification
    let expected_small_output = math::mul_div_to_64(
        SMALL_SWAP_AMOUNT,
        INITIAL_STABLE,
        INITIAL_ASSET + SMALL_SWAP_AMOUNT
    );
    
    debug::print(&b"Small swap output:");
    debug::print(&small_output);
    debug::print(&b"Expected small output:");
    debug::print(&expected_small_output);
    
    assert!(small_output == expected_small_output, 0);
    
    // Case 2: Large swap
    let large_output = amm::calculate_output(
        LARGE_SWAP_AMOUNT,
        INITIAL_ASSET,
        INITIAL_STABLE
    );
    
    // Manual calculation for verification
    let expected_large_output = math::mul_div_to_64(
        LARGE_SWAP_AMOUNT,
        INITIAL_STABLE,
        INITIAL_ASSET + LARGE_SWAP_AMOUNT
    );
    
    debug::print(&b"Large swap output:");
    debug::print(&large_output);
    debug::print(&b"Expected large output:");
    debug::print(&expected_large_output);
    
    assert!(large_output == expected_large_output, 1);
    
    // Case 3: Very large swap (extreme slippage)
    let very_large_output = amm::calculate_output(
        VERY_LARGE_SWAP_AMOUNT,
        INITIAL_ASSET,
        INITIAL_STABLE
    );
    
    // Verify slippage increases with swap size
    let small_slippage_percent = math::mul_div_to_64(
        SMALL_SWAP_AMOUNT - small_output,
        10000,
        SMALL_SWAP_AMOUNT
    );
    
    let large_slippage_percent = math::mul_div_to_64(
        LARGE_SWAP_AMOUNT - large_output,
        10000,
        LARGE_SWAP_AMOUNT
    );
    
    let very_large_slippage_percent = math::mul_div_to_64(
        VERY_LARGE_SWAP_AMOUNT - very_large_output,
        10000,
        VERY_LARGE_SWAP_AMOUNT
    );
    
    debug::print(&b"Small swap slippage % (basis points):");
    debug::print(&small_slippage_percent);
    debug::print(&b"Large swap slippage % (basis points):");
    debug::print(&large_slippage_percent);
    debug::print(&b"Very large swap slippage % (basis points):");
    debug::print(&very_large_slippage_percent);
    
    // Verify slippage increases with swap size
    assert!(small_slippage_percent < large_slippage_percent, 2);
    assert!(large_slippage_percent < very_large_slippage_percent, 3);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Multiple Consecutive Swaps Tests ========
#[test]
fun test_multiple_consecutive_swaps() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let mut pool = setup_pool(&mut scenario, &state, &clock);
    
    // Record initial reserves and price
    let (initial_asset, initial_stable) = amm::get_reserves(&pool);
    let initial_price = amm::get_current_price(&pool);
    
    // Perform 5 consecutive swaps buying asset (stable to asset)
    let mut i = 0;
    while (i < 5) {
        let _ = amm::swap_stable_to_asset(
            &mut pool,
            &state,
            SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario),
        );
        
        let price_after = amm::get_current_price(&pool);
        debug::print(&b"Price after buy swap #");
        debug::print(&i);
        debug::print(&b":");
        debug::print(&price_after);
        
        i = i + 1;
    };
        
    // Check reserves and price after buy swaps
    let (mid_asset, mid_stable) = amm::get_reserves(&pool);
    let mid_price = amm::get_current_price(&pool);
    
    // Price should increase after buying asset
    assert!(mid_price > initial_price, 0);
    
    // Asset reserve should decrease
    assert!(mid_asset < initial_asset, 1);
    
    // Stable reserve should increase
    assert!(mid_stable > initial_stable, 2);
    
    // Now perform 5 consecutive swaps selling asset (asset to stable)
    let mut i = 0;
    while (i < 5) {
        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario),
        );
        
        let price_after = amm::get_current_price(&pool);
        debug::print(&b"Price after sell swap #");
        debug::print(&i);
        debug::print(&b":");
        debug::print(&price_after);
        
        i = i + 1;
    };

    
    // Check final reserves and price
    let (final_asset, final_stable) = amm::get_reserves(&pool);
    let final_price = amm::get_current_price(&pool);
    
    // Price should decrease after selling asset
    assert!(final_price < mid_price, 3);
    
    // Check how price compares to initial
    debug::print(&b"Initial price:");
    debug::print(&initial_price);
    debug::print(&b"Mid price (after buys):");
    debug::print(&mid_price);
    debug::print(&b"Final price (after sells):");
    debug::print(&final_price);
    
    // Accumulated fees should be significant
    let accumulated_fees = amm::get_protocol_fees(&pool);
    debug::print(&b"Accumulated protocol fees:");
    debug::print(&accumulated_fees);
    assert!(accumulated_fees > 0, 4);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== TWAP Accuracy Tests ========
#[test]
fun test_twap_price_accuracy() {
    let (mut scenario, mut clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let mut pool = setup_pool(&mut scenario, &state, &clock);
    
    // Set initial time after TWAP_START_DELAY
    clock::set_for_testing(&mut clock, 100_000);
    
    // Get initial spot price and TWAP
    let initial_spot_price = amm::get_current_price(&pool);
    let initial_twap = amm::get_twap(&mut pool, &clock);
    
    debug::print(&b"Initial spot price:");
    debug::print(&initial_spot_price);
    debug::print(&b"Initial TWAP:");
    debug::print(&initial_twap);
    
    // Initially, TWAP should be approximately equal to spot price
    let twap_diff = if (initial_twap > initial_spot_price) {
        initial_twap - initial_spot_price
    } else {
        initial_spot_price - initial_twap
    };
    
    let twap_diff_percent = math::mul_div_to_128((twap_diff as u64), 10000, (initial_spot_price as u64));
    debug::print(&b"Initial TWAP diff (basis points):");
    debug::print(&twap_diff_percent);
    assert!(twap_diff_percent < 10, 0); // Less than 0.1% difference
    
    // Make a significant price change with a large swap
    let _ = amm::swap_asset_to_stable(
        &mut pool,
        &state,
        LARGE_SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );
    
    let new_spot_price = amm::get_current_price(&pool);
    
    // Move time forward a bit
    clock::increment_for_testing(&mut clock, 4000);
    
    // Get TWAP after price change but with minimal time elapsed
    let twap_short_time = amm::get_twap(&mut pool, &clock);
    
    debug::print(&b"New spot price after large swap:");
    debug::print(&new_spot_price);
    debug::print(&b"TWAP shortly after price change:");
    debug::print(&twap_short_time);
    
    // TWAP should be between initial and new spot price
    assert!(twap_short_time < initial_spot_price, 1);
    assert!(twap_short_time > new_spot_price, 2);
    
    // Move time forward significantly
    clock::increment_for_testing(&mut clock, 10000); // Much later
    
    // Get TWAP after significant time has passed
    let twap_long_time = amm::get_twap(&mut pool, &clock);
    
    debug::print(&b"TWAP after significant time:");
    debug::print(&twap_long_time);
    
    // TWAP should now be closer to the new spot price
    let diff_from_new_price_short = twap_short_time - new_spot_price;
    let diff_from_new_price_long = twap_long_time - new_spot_price;
    
    debug::print(&b"Diff from new price (short time):");
    debug::print(&diff_from_new_price_short);
    debug::print(&b"Diff from new price (long time):");
    debug::print(&diff_from_new_price_long);
    
    // The difference should decrease over time
    assert!(diff_from_new_price_long < diff_from_new_price_short, 3);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Pool ID and Outcome Tests ========
#[test]
fun test_pool_id_and_outcome() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    
    // Create pools with different outcome indexes
    let pool_0 = amm::new_pool(
        &state,
        0, // outcome_idx 0
        INITIAL_ASSET,
        INITIAL_STABLE,
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(&mut scenario),
    );
    
    let pool_1 = amm::new_pool(
        &state,
        1, // outcome_idx 1
        INITIAL_ASSET,
        INITIAL_STABLE,
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(&mut scenario),
    );
    
    // Verify outcome indexes
    let outcome_0 = amm::get_outcome_idx(&pool_0);
    let outcome_1 = amm::get_outcome_idx(&pool_1);
    
    assert!(outcome_0 == 0, 0);
    assert!(outcome_1 == 1, 1);
    
    // Verify IDs are different
    let id_0 = amm::get_id(&pool_0);
    let id_1 = amm::get_id(&pool_1);
    
    debug::print(&b"Pool 0 ID:");
    debug::print(&id_0);
    debug::print(&b"Pool 1 ID:");
    debug::print(&id_1);
    
    assert!(id_0 != id_1, 2);

    amm::destroy_for_testing(pool_0);
    amm::destroy_for_testing(pool_1);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Very Small Liquidity Tests ========
#[test]
fun test_minimal_liquidity() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    
    // Create a pool with minimal reserves
    let pool = amm::new_pool(
        &state,
        0,
        1000, // Very small amount
        1000, // Very small amount
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(&mut scenario),
    );
    
    // Verify reserves
    let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
    assert!(asset_reserve == 1000, 0);
    assert!(stable_reserve == 1000, 1);
    
    // Test a tiny swap
    // Due to the small pool size, even a tiny swap should have noticeable impact
    let tiny_swap = 10; // 1% of the pool
    
    // Quote the outcome
    let quoted_output = amm::quote_swap_asset_to_stable(&pool, tiny_swap);
    debug::print(&b"Quoted output for tiny swap:");
    debug::print(&quoted_output);
    
    // Ensure output is reasonable
    assert!(quoted_output > 0, 2);
    assert!(quoted_output < tiny_swap, 3); // Output should be less due to price impact
    
    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Max Price Test ========
#[test]
fun test_max_price() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    
    // Create a pool with extreme ratio to cause high price
    // This should cause the check_price_under_max function to fail
    let pool = amm::new_pool(
        &state,
        0,
        1, // Tiny asset amount
        (18446744073709551615), // u64::MAX
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(&mut scenario),
    );
    
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Test Pool Creation with Different Fee Settings ========
// Note: This test would require modifying the amm module to expose a way to set custom fees.
// For now, we'll just test the default fee behavior.
#[test]
fun test_default_fee_behavior() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let mut pool = setup_pool(&mut scenario, &state, &clock);
    
    // Calculate the theoretical fee amount for a swap
    let theoretical_fee = (SWAP_AMOUNT * DEFAULT_FEE) / FEE_SCALE;
    
    // Perform a swap
    let _ = amm::swap_stable_to_asset(
        &mut pool,
        &state,
        SWAP_AMOUNT,
        0,
        &clock,
        ctx(&mut scenario),
    );
    
    // Check collected fees
    let actual_fee = amm::get_protocol_fees(&pool);
    
    debug::print(&b"Theoretical fee:");
    debug::print(&theoretical_fee);
    debug::print(&b"Actual collected fee:");
    debug::print(&actual_fee);
    
    // Fees should match theoretical calculation
    assert!(actual_fee == theoretical_fee, 0);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Min Liquidity Requirement Test ========
#[test]
#[expected_failure(abort_code = futarchy::amm::ELOW_LIQUIDITY)]
fun test_min_liquidity_requirement() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    
    // Try to create a pool with too little liquidity
    // The minimum liquidity constant is 1000 (as u128)
    let pool = amm::new_pool(
        &state,
        0,
        10, // Very small amount
        10, // Very small amount
        (BASIS_POINTS as u128),
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx(&mut scenario),
    );
    
    // Should never reach here
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Oracle Access Test ========
#[test]
fun test_oracle_access() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let pool = setup_pool(&mut scenario, &state, &clock);
    
    // Get oracle reference
    let oracle_ref = amm::get_oracle(&pool);
    
    // Verify we can access the oracle's last price
    let oracle_price = amm::get_price(&pool);
    debug::print(&b"Oracle's last price:");
    debug::print(&oracle_price);
    
    // Price should match the initial pool price
    let pool_price = amm::get_current_price(&pool);
    assert!(oracle_price == pool_price, 0);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

// ======== Large Number of Small Swaps Test ========
#[test]
fun test_many_small_swaps() {
    let (mut scenario, clock) = setup_test();
    let (state) = setup_market(&mut scenario, &clock);
    let mut pool = setup_pool(&mut scenario, &state, &clock);
    
// Perform 20 small swaps
let small_amount = 1000000; // 1 unit
let mut total_fees = 0;

    let mut i = 0;
    while (i < 20) {
        let _ = amm::swap_stable_to_asset(
            &mut pool,
            &state,
            small_amount,
            0,
            &clock,
            ctx(&mut scenario),
        );
        
        // Track accumulated fees
        let current_fees = amm::get_protocol_fees(&pool);
        debug::print(&b"Fees after swap #");
        debug::print(&i);
        debug::print(&b":");
        debug::print(&current_fees);
        
        // Reset fees after checking to simplify tracking
        total_fees = total_fees + current_fees;
        amm::reset_protocol_fees(&mut pool);
        
        i = i + 1;
    };
    
    // Calculate theoretical fees
    let single_fee = (small_amount * DEFAULT_FEE) / FEE_SCALE;
    let theoretical_total = single_fee * 20;
    
    debug::print(&b"Total accumulated fees:");
    debug::print(&total_fees);
    debug::print(&b"Theoretical fees (20 swaps):");
    debug::print(&theoretical_total);
    
    // Actual fees might differ slightly due to compounding effects of price changes
    let diff = if (total_fees > theoretical_total) {
        total_fees - theoretical_total
    } else {
        theoretical_total - total_fees
    };
    
    let diff_percent = math::mul_div_to_64(diff, 10000, theoretical_total);
    debug::print(&b"Difference (basis points):");
    debug::print(&diff_percent);
    
    // Difference should be relatively small (< 5%)
    assert!(diff_percent < 500, 0);

    amm::destroy_for_testing(pool);
    market_state::destroy_for_testing(state);
    clock::destroy_for_testing(clock);
    test::end(scenario);
}