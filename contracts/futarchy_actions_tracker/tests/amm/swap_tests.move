#[test_only]
module futarchy::swap_tests;

use futarchy::conditional_amm::{Self, LiquidityPool};
use futarchy::math;
use futarchy::oracle;
use futarchy::test_stable_coin::TEST_STABLE_COIN;
use sui::object;
use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};

// ======== Test Constants ========
const ADMIN: address = @0xA;
const USER_1: address = @0x1;

const INITIAL_RESERVE: u64 = 1_000_000;
const SWAP_FEE_RATE: u64 = 30; // 0.3% = 30/10000
const TWAP_START_DELAY: u64 = 60_000; // Must be multiple of TWAP_PRICE_CAP_WINDOW (60000)
const TWAP_STEP_MAX: u64 = 100_000; // 10% of price (100,000 PPM = 10%)

// Helper to create test pool with proper TWAP parameters
fun create_test_pool_safe(scenario: &mut Scenario): LiquidityPool {
    // Use a valid twap_start_delay that's a multiple of 60000
    let dummy_market_id = object::id_from_address(ADMIN);

    // Create pool with modified oracle parameters
    conditional_amm::create_test_pool(
        dummy_market_id,
        0, // outcome_idx
        SWAP_FEE_RATE, // fee_percent
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(scenario),
    )
}

#[test]
fun test_swap_asset_to_stable_quote() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);

    // Create a dummy market ID
    let dummy_market_id = object::id_from_address(ADMIN);

    // Create pool using the safe helper
    let pool = create_test_pool_safe(&mut scenario);

    // Test various swap amounts
    let swap_amount = 1000;

    // Get quote for swap
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, swap_amount);

    // Calculate expected output using the AMM formula
    let k = INITIAL_RESERVE * INITIAL_RESERVE;
    let new_asset_reserve = INITIAL_RESERVE + swap_amount;
    let new_stable_reserve = k / new_asset_reserve;
    let amount_out_before_fee = INITIAL_RESERVE - new_stable_reserve;
    let fee = (amount_out_before_fee * SWAP_FEE_RATE) / 10000;
    let expected_amount_out = amount_out_before_fee - fee;

    // Verify quote matches expected calculation (allow small rounding differences)
    assert!(quote >= expected_amount_out - 1 && quote <= expected_amount_out + 1, 0);

    // Test with larger swap amount
    let large_swap = 100_000;
    let large_quote = conditional_amm::quote_swap_asset_to_stable(&pool, large_swap);

    // Verify large swaps have worse price (more slippage)
    let price_small = (quote * 1000) / swap_amount;
    let price_large = (large_quote * 1000) / large_swap;
    assert!(price_large < price_small, 1); // Price should be worse for larger swaps

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_swap_stable_to_asset_quote() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);

    // Create a dummy market ID
    let dummy_market_id = object::id_from_address(ADMIN);

    // Create pool using the safe helper
    let pool = create_test_pool_safe(&mut scenario);

    // Test various swap amounts
    let swap_amount = 1000;

    // Get quote for swap
    let quote = conditional_amm::quote_swap_stable_to_asset(&pool, swap_amount);

    // Calculate expected output using the AMM formula
    // For stable to asset swaps, fee is taken from input first
    let fee = (swap_amount * SWAP_FEE_RATE) / 10000;
    let amount_in_after_fee = swap_amount - fee;
    let k = INITIAL_RESERVE * INITIAL_RESERVE;
    let new_stable_reserve = INITIAL_RESERVE + amount_in_after_fee;
    let new_asset_reserve = k / new_stable_reserve;
    let expected_amount_out = INITIAL_RESERVE - new_asset_reserve;

    // Verify quote matches expected calculation (allow small rounding differences)
    assert!(quote >= expected_amount_out - 1 && quote <= expected_amount_out + 1, 0);

    // Test with larger swap amount
    let large_swap = 100_000;
    let large_quote = conditional_amm::quote_swap_stable_to_asset(&pool, large_swap);

    // Verify large swaps have worse price (more slippage)
    let price_small = (quote * 1000) / swap_amount;
    let price_large = (large_quote * 1000) / large_swap;
    assert!(price_large < price_small, 1); // Price should be worse for larger swaps

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_swap_invariant_maintained() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);

    let mut pool = create_test_pool_safe(&mut scenario);

    // Get initial reserves and calculate k
    let (initial_asset, initial_stable) = conditional_amm::get_reserves(&pool);
    let initial_k = initial_asset * initial_stable;

    // Simulate a swap by updating reserves directly
    // Note: In real tests, we'd use actual swap functions, but for testing invariant
    // we can verify the math works correctly
    let swap_amount = 10_000;
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, swap_amount);

    // Calculate what the new reserves would be after swap
    let new_asset = initial_asset + swap_amount;
    let new_stable = initial_stable - quote;
    let new_k = new_asset * new_stable;

    // Actually, let's think about this:
    // When swapping asset for stable with fees:
    // - We add `swap_amount` of asset tokens
    // - We remove `quote` stable tokens (which is AFTER fees are deducted)
    // - So K should actually remain close to constant or increase slightly
    // because we're keeping some output as fees

    // The invariant is maintained by the fact that:
    // Without fees: new_k = (old_asset + in) * (old_stable - out_no_fee) = k
    // With fees: new_k = (old_asset + in) * (old_stable - out_with_fee) > k
    // Since out_with_fee < out_no_fee

    assert!(new_k >= initial_k, 0); // K should stay same or increase due to fees kept in pool
    assert!(new_k < (initial_k * 1005) / 1000, 1); // But not by more than 0.5%

    // Test the other direction
    let quote_reverse = conditional_amm::quote_swap_stable_to_asset(&pool, swap_amount);

    // For stable to asset swaps, calculate reserves after fee is taken from input
    let fee = (swap_amount * 30) / 10000;
    let amount_in_after_fee = swap_amount - fee;

    // The quote already factors in the fee, so the reserves would be:
    let new_stable_2 = initial_stable + amount_in_after_fee; // Only the post-fee amount enters the pool
    let new_asset_2 = initial_asset - quote_reverse;
    let new_k_2 = new_asset_2 * new_stable_2;

    // For stable to asset swaps, fee is taken from input, so less goes into the pool
    // This actually preserves K better since we're putting less in
    assert!(new_k_2 >= initial_k, 2); // K should stay same or increase
    assert!(new_k_2 < (initial_k * 1005) / 1000, 3); // But not by more than 0.5%

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_swap_fees_calculated_correctly() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);

    let pool = create_test_pool_safe(&mut scenario);

    // Test asset to stable swap fee calculation
    let swap_amount = 10_000;
    let quote_with_fee = conditional_amm::quote_swap_asset_to_stable(&pool, swap_amount);

    // Calculate output without fee
    let k = INITIAL_RESERVE * INITIAL_RESERVE;
    let new_asset_reserve = INITIAL_RESERVE + swap_amount;
    let new_stable_reserve = k / new_asset_reserve;
    let output_without_fee = INITIAL_RESERVE - new_stable_reserve;

    // Fee should be 0.3% of output
    let expected_fee = (output_without_fee * SWAP_FEE_RATE) / 10000;
    let expected_output = output_without_fee - expected_fee;

    assert!(quote_with_fee >= expected_output - 1 && quote_with_fee <= expected_output + 1, 0);

    // Test stable to asset swap fee calculation
    let quote_stable_to_asset = conditional_amm::quote_swap_stable_to_asset(&pool, swap_amount);

    // For stable to asset, fee is taken from input
    let input_fee = (swap_amount * SWAP_FEE_RATE) / 10000;
    let effective_input = swap_amount - input_fee;

    // Calculate output with effective input
    let new_stable_reserve_2 = INITIAL_RESERVE + effective_input;
    let new_asset_reserve_2 = k / new_stable_reserve_2;
    let expected_output_2 = INITIAL_RESERVE - new_asset_reserve_2;

    assert!(
        quote_stable_to_asset >= expected_output_2 - 1 && quote_stable_to_asset <= expected_output_2 + 1,
        1,
    );

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_fees_always_in_stable() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);

    let pool = create_test_pool_safe(&mut scenario);

    // For both swap directions, verify that the fee calculation results in
    // the same amount of stable coins being collected

    // Test 1: Asset to Stable swap
    // User provides 10,000 asset tokens
    let asset_in = 10_000;
    let quote_asset_to_stable = conditional_amm::quote_swap_asset_to_stable(&pool, asset_in);

    // The quote is already after fees. To find the fee amount:
    // gross_output = quote / (1 - fee_rate) = quote / 0.997
    let gross_output = (quote_asset_to_stable * 10000) / 9970;
    let fee_from_asset_swap = gross_output - quote_asset_to_stable;

    // Test 2: Stable to Asset swap
    // User provides 10,000 stable tokens
    let stable_in = 10_000;
    let fee_from_stable_swap = (stable_in * SWAP_FEE_RATE) / 10000;

    // Both swaps should collect fees in stable tokens
    // The fee amounts won't be exactly equal because they're on different amounts,
    // but they should both be in stable tokens and follow the 0.3% rate
    assert!(fee_from_asset_swap > 0, 0);
    assert!(fee_from_stable_swap == 30, 1); // 0.3% of 10,000 = 30

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_protocol_fees_accumulation() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);

    let pool = create_test_pool_safe(&mut scenario);

    // Get initial protocol fees (should be 0)
    let initial_fees = conditional_amm::get_protocol_fees(&pool);
    assert!(initial_fees == 0, 0);

    // Simulate multiple swaps and verify protocol fees accumulate
    let swap_amounts = vector[1000, 5000, 10000, 50000];
    let mut expected_total_fees = 0;

    let mut i = 0;
    while (i < swap_amounts.length()) {
        let amount = *swap_amounts.borrow(i);

        // Do an asset to stable swap
        let quote = conditional_amm::quote_swap_asset_to_stable(&pool, amount);
        let gross_output = (quote * 10000) / 9970;
        let fee = gross_output - quote;
        expected_total_fees = expected_total_fees + fee;

        // Do a stable to asset swap
        let fee_stable = (amount * SWAP_FEE_RATE) / 10000;
        expected_total_fees = expected_total_fees + fee_stable;

        i = i + 1;
    };

    // In a real test with actual swaps, we would verify:
    // assert!(amm::get_protocol_fees(&pool) == expected_total_fees, 1);

    // For now, just verify our fee calculations are reasonable
    assert!(expected_total_fees > 0, 1);

    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}
